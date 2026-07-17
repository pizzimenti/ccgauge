#!/usr/bin/env python3
"""Claude Code subscription usage probe.

Fetches the 5-hour (session) and 7-day (weekly) utilisation that the
interactive `/usage` command shows, via the undocumented OAuth usage
endpoint, using the OAuth token Claude Code already stores on disk.

Reverse-engineered endpoint (community-sourced, undocumented by Anthropic):
    GET https://api.anthropic.com/api/oauth/usage
    Authorization: Bearer <accessToken>
    anthropic-beta: oauth-2025-04-20
    User-Agent: claude-code/<version>

Response shape:
    {"five_hour": {"utilization": 37.0, "resets_at": "...Z"},
     "seven_day": {"utilization": 26.0, "resets_at": "...Z"}, ...}

Design constraints:
  * The endpoint 429s hard if polled too fast -> only fetch when the cache is
    older than TTL_SECONDS. After a 429, honor the server's Retry-After header
    when present; otherwise back off exponentially (BACKOFF_BASE, doubling per
    consecutive 429, capped at BACKOFF_CAP) so we stop knocking long enough for
    the token's usage bucket to drain instead of re-arming the lockout.
  * Never raise: every command path swallows errors and exits 0 so this can
    never disrupt a hook or the status line.

Modes (argv[1]):
    refresh  (default) -- fetch only if cache is stale & not in cooldown
    line                -- one-line snapshot for the UserPromptSubmit hook
    status [plain]      -- short fragment (5h/7d bars) for the status line;
                           `plain` drops ANSI so the caller owns the colour
    bar <pct>           -- a standalone 0-100 progress bar (e.g. for context %)
    show                -- force a synchronous refresh, print a human block
    log [N]             -- print the last N history events (default 20)
"""

import json
import math
import os
import re
import subprocess
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone

try:
    import fcntl
except ImportError:  # non-POSIX: degrade to unlocked best-effort appends
    fcntl = None

HOME = os.path.expanduser("~")
BASE = os.environ.get("CLAUDE_CONFIG_DIR", os.path.join(HOME, ".claude"))
CRED = os.path.join(BASE, ".credentials.json")
CACHE = os.path.join(BASE, "usage-cache.json")
COOLDOWN = os.path.join(BASE, "usage-429-cooldown")
LOG = os.path.join(BASE, "usage-log.jsonl")
LOCK = os.path.join(BASE, "usage-refresh.lock")

URL = "https://api.anthropic.com/api/oauth/usage"
BETA = "oauth-2025-04-20"

# The User-Agent is load-bearing: the endpoint requires a `claude-code/*` UA or
# it drops the request into an aggressive rate-limit bucket. We derive the
# version from the installed CLI at runtime so it tracks Claude Code updates,
# falling back to this pin if `claude --version` is unavailable.
DEFAULT_UA = "claude-code/2.1.185"

TTL_SECONDS = 600        # do not refetch within this window (background telemetry: low request rate)
BACKOFF_BASE = 600       # first 429 backs off this long (fallback when no Retry-After header)...
BACKOFF_CAP = 7200       # ...doubling per consecutive 429, capped here (2h) so the token's usage
                         # bucket can actually drain instead of us re-arming the server-side lockout
STALE_SECONDS = 1800     # mark the readout as stale (endpoint likely unreachable) past this
HTTP_TIMEOUT = 6
ACT_PCT = 95             # session window at/above this: inject wind-down directive
LOG_MAX_BYTES = 1 << 20  # trim the history log once it outgrows this...
LOG_KEEP_LINES = 4000    # ...keeping at most this many of the newest events

_UA_CACHE = None


def user_agent():
    """`claude-code/<installed version>`, or DEFAULT_UA if it can't be read.

    Cached per process. `claude --version` prints e.g. '2.1.185 (Claude Code)'.
    """
    global _UA_CACHE
    if _UA_CACHE is not None:
        return _UA_CACHE
    ua = DEFAULT_UA
    try:
        out = subprocess.run(
            ["claude", "--version"],
            capture_output=True, text=True, timeout=5, check=False,
        ).stdout
        m = re.search(r"(\d+\.\d+\.\d+)", out)
        if m:
            ua = "claude-code/" + m.group(1)
    except Exception:
        pass
    _UA_CACHE = ua
    return ua


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def _now():
    return time.time()


def load_token():
    """Return (access_token, expires_at_seconds) or (None, None)."""
    try:
        with open(CRED) as fh:
            data = json.load(fh)
    except Exception:
        return None, None
    oauth = data.get("claudeAiOauth", data)  # tolerate either nesting
    token = oauth.get("accessToken")
    exp = oauth.get("expiresAt")  # milliseconds in Claude Code's format
    exp_s = (exp / 1000.0) if isinstance(exp, (int, float)) else None
    return token, exp_s


def cache_age():
    try:
        return _now() - os.path.getmtime(CACHE)
    except Exception:
        return None


def _read_cooldown():
    """Return (until_epoch, consecutive_429_count); (0.0, 0) if absent/unreadable.

    The cooldown file is JSON ({"until": <epoch>, "consecutive": <n>}); a bare
    float is tolerated so a file written by an older version still parses.
    """
    try:
        with open(COOLDOWN) as fh:
            raw = fh.read().strip()
    except Exception:
        return 0.0, 0
    try:
        data = json.loads(raw)
        return float(data.get("until", 0)), int(data.get("consecutive", 0))
    except Exception:
        try:
            return float(raw), 0
        except Exception:
            return 0.0, 0


def in_cooldown():
    until, _ = _read_cooldown()
    return until > _now()


def set_cooldown(retry_after=None):
    """Arm the 429 back-off and return the chosen delay in seconds.

    Honors the server's Retry-After (retry_after, in seconds) when provided so we
    wait exactly as long as the endpoint asks; otherwise backs off exponentially
    on the consecutive-429 count. Either way the consecutive counter advances, so
    a run of header-less 429s keeps stretching the wait instead of knocking every
    fixed interval and re-arming the server-side lockout.
    """
    _, prev = _read_cooldown()
    consecutive = prev + 1
    if retry_after and retry_after > 0:
        delay = max(int(retry_after), 60)          # trust the server; floor at 60s
    else:
        delay = min(BACKOFF_BASE * (2 ** (consecutive - 1)), BACKOFF_CAP)
    try:
        with open(COOLDOWN, "w") as fh:
            json.dump({"until": _now() + delay, "consecutive": consecutive}, fh)
    except Exception:
        pass
    return delay


def clear_cooldown():
    try:
        os.remove(COOLDOWN)
    except Exception:
        pass


def log_event(event, **fields):
    """Append one JSONL record to the history log. Best-effort, never raises.

    None-valued fields are dropped. The append and any trim run under one
    exclusive flock on the log fd, and the trim rewrites in place (no rename),
    so concurrent writers (foreground `line` + detached `refresh`) can neither
    interleave mid-line nor lose an append that races a trim. The lock is held
    for at most one ~1 MiB read+write (milliseconds). Without fcntl
    (non-POSIX) it degrades to unlocked appends.
    """
    try:
        rec = {
            "ts": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
            "event": event,
        }
        rec.update((k, v) for k, v in fields.items() if v is not None)
        with open(LOG, "a+") as fh:
            if fcntl:
                fcntl.flock(fh, fcntl.LOCK_EX)  # released when fh closes
            fh.write(json.dumps(rec) + "\n")
            fh.flush()
            if fh.tell() > LOG_MAX_BYTES:
                fh.seek(0)
                keep = fh.readlines()[-LOG_KEEP_LINES:]
                # Bound by bytes too: oversized records (e.g. a very long cwd)
                # could otherwise leave LOG_KEEP_LINES lines still over the
                # cap, re-triggering this rewrite on every append. Targeting
                # half the cap gives the same hysteresis in the normal case.
                total = sum(len(line) for line in keep)
                while keep and total > LOG_MAX_BYTES // 2:
                    total -= len(keep.pop(0))
                fh.seek(0)
                fh.truncate()
                fh.writelines(keep)
    except Exception:
        pass


def _hook_payload():
    """Parse the JSON Claude Code pipes to a hook's stdin ({} when absent).

    Guarded by isatty so a manual `usage.py line` at a terminal never blocks
    waiting for input. The prompt text in the payload is never logged.
    """
    try:
        if sys.stdin is not None and not sys.stdin.isatty():
            raw = sys.stdin.read()
            if raw.strip():
                return json.loads(raw)
    except Exception:
        pass
    return {}


def _retry_after_seconds(err):
    """Back-off duration (seconds) parsed from a 429's headers, or None.

    Prefers the standard `Retry-After` (delta-seconds or an HTTP-date), then
    falls back to Anthropic's `anthropic-ratelimit-*-reset` (epoch or ISO time).
    """
    try:
        hdrs = err.headers
    except Exception:
        hdrs = None
    if not hdrs:
        return None
    ra = hdrs.get("retry-after")
    if ra:
        ra = ra.strip()
        if ra.isdigit():
            return int(ra)
        try:
            from email.utils import parsedate_to_datetime
            dt = parsedate_to_datetime(ra)
            if dt is not None:
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
                return max(0, int((dt - datetime.now(timezone.utc)).total_seconds()))
        except Exception:
            pass
    for key in ("anthropic-ratelimit-unified-reset",
                "anthropic-ratelimit-unified-5h-reset",
                "anthropic-ratelimit-requests-reset",
                "anthropic-ratelimit-tokens-reset"):
        val = hdrs.get(key)
        if not val:
            continue
        val = val.strip()
        if val.isdigit():
            secs = int(val) - int(_now())
            if secs > 0:
                return secs
        secs = _secs_until(val)
        if secs and secs > 0:
            return secs
    return None


def _http_get(token):
    """Return (status_code_or_None, body_dict_or_None, retry_after_seconds_or_None)."""
    req = urllib.request.Request(
        URL,
        headers={
            "Authorization": "Bearer " + token,
            "anthropic-beta": BETA,
            "User-Agent": user_agent(),
            "Accept": "application/json",
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return resp.status, json.load(resp), None
    except urllib.error.HTTPError as e:
        return e.code, None, _retry_after_seconds(e)
    except Exception:
        return None, None, None


def _pct(window):
    if not isinstance(window, dict):
        return None
    u = window.get("utilization")
    try:
        return round(float(u))
    except (TypeError, ValueError):
        return None


def normalise(body):
    out = {
        "five_hour_pct": _pct(body.get("five_hour")),
        "five_hour_reset": (body.get("five_hour") or {}).get("resets_at"),
        "seven_day_pct": _pct(body.get("seven_day")),
        "seven_day_reset": (body.get("seven_day") or {}).get("resets_at"),
        "seven_day_opus_pct": _pct(body.get("seven_day_opus")),
        "fetched_at": _now(),
    }
    return out


def read_cache():
    try:
        with open(CACHE) as fh:
            return json.load(fh)
    except Exception:
        return None


def _secs_until(iso):
    """Seconds from now until an ISO timestamp, or None on failure."""
    if not iso:
        return None
    try:
        dt = datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
        return int((dt - datetime.now(timezone.utc)).total_seconds())
    except Exception:
        return None


def fmt_reset(iso):
    """ISO timestamp -> 'in 4h 1m' (or '' on failure)."""
    secs = _secs_until(iso)
    if secs is None:
        return ""
    if secs <= 0:
        return "now"
    h, m = secs // 3600, (secs % 3600) // 60
    return f"in {h}h {m}m" if h else f"in {m}m"


# --------------------------------------------------------------------------- #
# core
# --------------------------------------------------------------------------- #
_NO_LOCK = object()  # sentinel: proceed with refresh but without a real lock


def _acquire_refresh_lock():
    """Grab the cross-process refresh lock, non-blocking.

    Returns the held lock fd on success; None if another refresh already holds
    it (the caller should serve cache rather than fire a duplicate request); the
    _NO_LOCK sentinel when fcntl is unavailable, so refresh proceeds unlocked
    exactly as it did before locking existed.
    """
    if not fcntl:
        return _NO_LOCK
    try:
        fd = open(LOCK, "w")
    except Exception:
        return _NO_LOCK  # can't create the lock file; don't block refresh
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        fd.close()
        return None      # genuinely contended: another refresh is in flight
    except OSError:
        # filesystem doesn't support advisory locks (some NFS/FUSE homes) —
        # proceed unlocked rather than serve cache forever
        fd.close()
        return _NO_LOCK
    return fd


def _release_refresh_lock(handle):
    if handle is _NO_LOCK:
        return
    try:
        fcntl.flock(handle, fcntl.LOCK_UN)
    except Exception:
        pass
    try:
        handle.close()
    except Exception:
        pass


def refresh(force=False):
    if not force:
        age = cache_age()
        if age is not None and age < TTL_SECONDS:
            return read_cache()
    if in_cooldown():
        return read_cache()
    token, exp_s = load_token()
    if not token:
        return read_cache()
    if exp_s and exp_s < _now() + 30:
        # token is expired or about to expire; let Claude Code refresh it
        return read_cache()
    # Serialize the fetch+cooldown update across processes. Two overlapping
    # UserPromptSubmit hooks each spawn a detached refresh, and both can clear
    # in_cooldown() above before either fires — without this guard they double-
    # hit the endpoint and, reading the same consecutive-429 count, fail to
    # escalate the backoff. A non-blocking lock means the refresh that loses the
    # race serves cache instead of sending a duplicate request.
    lock = _acquire_refresh_lock()
    if lock is None:
        return read_cache()
    try:
        if in_cooldown():
            # whoever won the lock may have just armed the cooldown; re-check
            return read_cache()
        if not force:
            age = cache_age()
            if age is not None and age < TTL_SECONDS:
                # a refresh that beat us to the lock already refreshed the
                # cache; don't fire a now-redundant request
                return read_cache()
        status, body, retry_after = _http_get(token)
        if status == 200 and body:
            data = normalise(body)
            try:
                with open(CACHE, "w") as fh:
                    json.dump(data, fh)
            except Exception:
                pass
            else:
                # only if the write landed: a "fetch" event means the cache (the
                # single source of truth every reader serves from) really updated
                log_event("fetch",
                          five_hour_pct=data.get("five_hour_pct"),
                          seven_day_pct=data.get("seven_day_pct"))
            clear_cooldown()
            return data
        if status == 429:
            delay = set_cooldown(retry_after)
            log_event("cooldown_429", backoff_s=int(delay),
                      retry_after=int(retry_after) if retry_after else None)
        return read_cache()
    finally:
        _release_refresh_lock(lock)


# --------------------------------------------------------------------------- #
# output modes
# --------------------------------------------------------------------------- #
def cmd_line():
    hook = _hook_payload()
    cwd = hook.get("cwd")
    if isinstance(cwd, str) and cwd.startswith(HOME):
        cwd = "~" + cwd[len(HOME):]
    session = hook.get("session_id")
    c = read_cache()
    if not c:
        log_event("prompt", cwd=cwd, session_id=session)
        print("[usage] no data yet (warming up — will populate next turn)")
        return
    p5, p7 = c.get("five_hour_pct"), c.get("seven_day_pct")
    if p5 is None and p7 is None:
        log_event("prompt", cwd=cwd, session_id=session)
        print("[usage] unavailable")
        return
    r5 = fmt_reset(c.get("five_hour_reset"))
    r7 = fmt_reset(c.get("seven_day_reset"))
    age = int(_now() - c.get("fetched_at", _now()))
    log_event("prompt", five_hour_pct=p5, seven_day_pct=p7, cache_age_s=age,
              cwd=cwd, session_id=session)
    stale = age > STALE_SECONDS
    parts = []
    if p5 is not None:
        parts.append(f"session(5h) last-known {p5}% (NOT live)" if stale
                     else f"session(5h) {p5}% used (resets {r5})")
    if p7 is not None:
        parts.append(f"week(7d) last-known {p7}% (NOT live)" if stale
                     else f"week(7d) {p7}% used (resets {r7})")
    line = "[usage] " + " · ".join(parts)
    if stale:
        line += (f"  ⚠ STALE {age // 60}m — endpoint unreachable/rate-limited."
                 f" The values above are the last successful read, NOT current;"
                 f" do not trust them. Run `/usage` in-app for live numbers.")
    else:
        line += f" [cache {age}s old]"
        # Claude Code already warns natively near a limit, so a bare "at N%"
        # marker is redundant. At ACT_PCT on the session window we instead
        # hand the assistant a wind-down protocol. Suppressed while stale:
        # an old percentage may describe a window that has already reset.
        wake = _secs_until(c.get("five_hour_reset"))
        if p5 is not None and p5 >= ACT_PCT and wake is not None and wake > 0:
            line += (
                f"  ⚠ SESSION AT {p5}% — wind down now:"
                f" (1) offer the user the chance to cue up work for after the reset ({r5});"
                f" (2) suggest /compact to shrink context before the pause;"
                f" (3) start `sleep {wake + 60}` as a harness-tracked background task"
                f" (run_in_background — NOT a detached `&` child, which nothing observes);"
                f" its completion notification re-invokes you ~1m after the reset —"
                f" resume the queued work then."
            )
    print(line)


def _color(pct):
    if pct is None:
        return "\033[2m"
    if pct >= 90:
        return "\033[0;31m"   # red
    if pct >= 70:
        return "\033[0;33m"   # yellow
    return "\033[0;32m"       # green


def _bar(pct, cells=10):
    """A `cells`-segment progress bar — one filled segment per (100/cells)%, so
    10 cells = 10% each: `[░░░░░░░░░░]` at 0, `[██░░░░░░░░]` at ~20, `[██████████]`
    at 100. The percentage is deliberately NOT drawn inside the bar (it would
    occlude segments) — render the number alongside it.
    """
    try:
        p = max(0.0, min(100.0, float(pct)))
    except (TypeError, ValueError):
        p = 0.0
    filled = max(0, min(cells, round(p / 100 * cells)))
    return "[" + "█" * filled + "░" * (cells - filled) + "]"


def cmd_status(plain=False):
    c = read_cache()
    if not c:
        return
    p5, p7 = c.get("five_hour_pct"), c.get("seven_day_pct")

    # In plain mode emit NO ANSI: the caller (e.g. a status-line snippet) owns
    # the color and can render the whole fragment in one hue. The default keeps
    # the per-window severity colors (green/yellow/red) for standalone use.
    def seg(label, pct, reset_iso, unit, denom):
        core = f"{label} {_bar(pct)} {pct}%"
        frag = core if plain else f"{_color(pct)}{core}\033[0m"
        secs = _secs_until(reset_iso)
        if secs is not None and secs > 0:
            # ceil to one decimal: a live countdown must never show 0.0
            # (nor understate the wait) while the window is still limiting
            span = f"({math.ceil(secs / denom) / 10:.1f}{unit})"
            frag += span if plain else f"\033[2m{span}\033[0m"
        return frag

    bits = []
    if p5 is not None:
        bits.append(seg("5h", p5, c.get("five_hour_reset"), "h", 360))
    if p7 is not None:
        bits.append(seg("7d", p7, c.get("seven_day_reset"), "d", 8640))
    if not bits:
        return
    age = _now() - c.get("fetched_at", _now())
    if age > STALE_SECONDS:
        # A clear word beats the old cryptic '?': this fragment is the last
        # successful read, NOT live, whenever the endpoint is unreachable.
        bits.append("stale" if plain else "\033[2mstale\033[0m")
    if plain:
        sys.stdout.write(" · ".join(bits))
    else:
        sys.stdout.write(" " + " ".join(bits))


def cmd_show():
    c = refresh(force=True)
    if not c:
        if in_cooldown():
            print("usage: in 429 cooldown — endpoint was rate-limited, retry shortly")
        else:
            print("usage: unavailable (no token, expired token, or endpoint error)")
        return
    p5, p7 = c.get("five_hour_pct"), c.get("seven_day_pct")
    age = int(_now() - c.get("fetched_at", _now()))
    print("Claude subscription usage")
    print(f"  Session (5h): {p5}% used — resets {fmt_reset(c.get('five_hour_reset'))}")
    print(f"  Weekly  (7d): {p7}% used — resets {fmt_reset(c.get('seven_day_reset'))}")
    if c.get("seven_day_opus_pct") is not None:
        print(f"  Weekly Opus : {c['seven_day_opus_pct']}% used")
    # Be honest when the forced refresh could NOT reach the endpoint: a live
    # `show` that silently returns hour-old cache is exactly how a stale 0% gets
    # mistaken for current. Flag the cache age and any active back-off.
    if age > STALE_SECONDS or in_cooldown():
        until, consec = _read_cooldown()
        wait = int(until - _now())
        note = f"  ⚠ NOT live — cached {age // 60}m ago"
        if in_cooldown() and wait > 0:
            note += (f"; endpoint rate-limited, next retry in "
                     f"{wait // 60}m{wait % 60:02d}s (after {consec} consecutive 429s)")
        note += ". Check `/usage` in-app for current numbers."
        print(note)


def cmd_log():
    try:
        n = max(1, int(sys.argv[2]))
    except (IndexError, ValueError):
        n = 20
    try:
        with open(LOG) as fh:
            if fcntl:
                fcntl.flock(fh, fcntl.LOCK_SH)  # don't read mid-trim
            lines = fh.readlines()
    except Exception:
        lines = []
    if not lines:
        print("usage log: no events recorded yet")
        return
    for raw in lines[-n:]:
        try:
            r = json.loads(raw)
        except Exception:
            continue
        ts = str(r.get("ts", ""))[:16].replace("T", " ")
        vals = " ".join(
            f"{label}:{r[key]}%"
            for label, key in (("5h", "five_hour_pct"), ("7d", "seven_day_pct"))
            if r.get(key) is not None
        )
        line = f"{ts}  {r.get('event', '?'):<12} {vals:<14} {r.get('cwd', '')}"
        print(line.rstrip())


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "refresh"
    try:
        if mode == "refresh":
            refresh()
        elif mode == "line":
            cmd_line()
        elif mode == "status":
            cmd_status(plain=(len(sys.argv) > 2 and sys.argv[2] == "plain"))
        elif mode == "bar":
            # Render a standalone progress bar for an arbitrary 0-100 value, so
            # callers (e.g. a status line showing Claude Code's own context %)
            # can reuse the exact same bar as the 5h/7d fragments.
            if len(sys.argv) > 2:
                try:
                    sys.stdout.write(_bar(float(sys.argv[2])))
                except ValueError:
                    pass
        elif mode == "show":
            cmd_show()
        elif mode == "log":
            cmd_log()
    except Exception:
        pass  # never disrupt a hook or status line
    sys.exit(0)


if __name__ == "__main__":
    main()

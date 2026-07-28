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
    line                -- one-line snapshot for the UserPromptSubmit hook;
                           does one synchronous fetch first if the cache is
                           stale (missing / idle past STALE_SECONDS), so the
                           first prompt after a break shows live numbers
    status [plain]      -- short fragment (5h/7d bars) for the status line;
                           `plain` emits no ANSI at all, so the caller can colour
                           the fragment itself or measure its display width
    bar <pct> [pace]    -- a standalone 0-100 progress bar (e.g. for context %),
                           with the pace shadow when a second value is given
    show                -- force a synchronous refresh, print a human block
    log [N]             -- print the last N history events (default 20)
"""

import contextlib
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
PACE_MAX_AGE = TTL_SECONDS   # drop the pace mark past this; see pace_for()
FIVE_HOUR_SECS = 5 * 3600    # span of the session window — the denominator for its pace mark
SEVEN_DAY_SECS = 7 * 86400   # ...and of the weekly window
# Segment counts chosen so one segment is a round slice of wall-clock time: on the
# 5h window 10 segments is half an hour each, on the 7d window 14 is half a day.
# That makes the pace mark readable as a position in the window, not just a
# fraction — a 7d mark sitting on segment 9 is "we're into the fifth day".
FIVE_HOUR_CELLS = 10
SEVEN_DAY_CELLS = 14
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
    with contextlib.suppress(Exception):
        out = subprocess.run(
            ["claude", "--version"],
            capture_output=True, text=True, timeout=5, check=False,
        ).stdout
        m = re.search(r"(\d+\.\d+\.\d+)", out)
        if m:
            ua = "claude-code/" + m.group(1)
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
    with contextlib.suppress(Exception):
        with open(COOLDOWN, "w") as fh:
            json.dump({"until": _now() + delay, "consecutive": consecutive}, fh)
    return delay


def clear_cooldown():
    with contextlib.suppress(Exception):
        os.remove(COOLDOWN)


def log_event(event, **fields):
    """Append one JSONL record to the history log. Best-effort, never raises.

    None-valued fields are dropped. The append and any trim run under one
    exclusive flock on the log fd, and the trim rewrites in place (no rename),
    so concurrent writers (foreground `line` + detached `refresh`) can neither
    interleave mid-line nor lose an append that races a trim. The lock is held
    for at most one ~1 MiB read+write (milliseconds). Without fcntl
    (non-POSIX) it degrades to unlocked appends.
    """
    with contextlib.suppress(Exception):
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


def _hook_payload():
    """Parse the JSON Claude Code pipes to a hook's stdin ({} when absent).

    Guarded by isatty so a manual `usage.py line` at a terminal never blocks
    waiting for input. The prompt text in the payload is never logged.
    """
    with contextlib.suppress(Exception):
        if sys.stdin is not None and not sys.stdin.isatty():
            raw = sys.stdin.read()
            if raw.strip():
                return json.loads(raw)
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
        with contextlib.suppress(Exception):
            from email.utils import parsedate_to_datetime
            dt = parsedate_to_datetime(ra)
            if dt is not None:
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
                return max(0, int((dt - datetime.now(timezone.utc)).total_seconds()))
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


def pace_pct(reset_iso, window_secs):
    """Where an evenly-paced spend would sit right now, 0-100 (None if unknown).

    A window that resets at T started at T - window_secs, so the fraction of it
    already elapsed is exactly the fraction of the allowance you could have
    spent and still land on 100% at the reset. Half-way through the 5h window
    (2.5h in) the pace mark is 50%.

    Returns None once the reset has passed, rather than clamping to 100. A
    already-elapsed `resets_at` means the window has rolled over and the cached
    percentage describes a window that no longer exists — clamping would draw a
    nearly-full bar with a sliver of headroom at the exact moment the truth is a
    fresh window with everything still to spend. No mark is the honest answer.
    """
    secs = _secs_until(reset_iso)
    if secs is None or not window_secs or secs <= 0:
        return None
    elapsed = window_secs - secs
    return max(0.0, min(100.0, elapsed / float(window_secs) * 100.0))


def pace_for(reset_iso, window_secs, age):
    """The pace mark to draw for a window, or None to draw no mark at all.

    The mark is computed from the live clock while the percentage beside it comes
    from the cache, so the two drift apart as the cache ages — and the drift is
    directional: the mark advances while the percentage stands still, so an old
    cache renders *more* `▒` headroom than you really have. It under-reports
    overspend, which is the dangerous direction, so the mark is held to a much
    tighter age budget than the readout as a whole (PACE_MAX_AGE, one refresh
    interval — about a third of a segment of drift on the 5h window — against the
    30 minutes it takes to flag the numbers themselves as stale).

    Gating on age rather than on any particular refresh failure also covers the
    cases where `show`'s forced refresh silently returns cache: a 429 cooldown, a
    contended lock, a rotating token. What matters for the mark is how old the
    percentage is, not why it could not be renewed.
    """
    if age is None or age > PACE_MAX_AGE:
        return None
    return pace_pct(reset_iso, window_secs)


def fmt_reset(iso):
    """ISO timestamp -> 'in 4h 1m' (or '' on failure)."""
    secs = _secs_until(iso)
    if secs is None:
        return ""
    if secs <= 0:
        return "now"
    h, m = secs // 3600, (secs % 3600) // 60
    return f"in {h}h {m}m" if h else f"in {m}m"


def fmt_clock(epoch):
    """Epoch seconds -> local wall-clock 'HH:MM' (or '' on failure).

    Used to show *when* the last successful refresh landed, so a stale readout
    reads as "as of 17:52" instead of a bare "stale".
    """
    try:
        return datetime.fromtimestamp(epoch).strftime("%H:%M")
    except Exception:
        return ""


def _stale_why(reason):
    """Human cause for a stale readout, from a refresh() outcome reason.

    Named straight from what refresh() actually did, so lock contention and
    credential rotation don't get mislabeled as the endpoint being down.
    """
    if reason in ("cooldown", "429"):
        until, _ = _read_cooldown()
        wait = max(0, int(until - _now()))
        return (f"endpoint rate-limited (429) — next retry in "
                f"{wait // 60}m{wait % 60:02d}s")
    if reason in ("no_token", "expiring_token"):
        return ("auth token unavailable (login expired or refreshing) —"
                " Claude Code renews it on its own, retry next turn")
    if reason == "lock_contended":
        return ("another refresh is already in flight (a second session or"
                " `usage.py show`) — retry next turn")
    # http_error, or an unexpected/unknown reason: treat as a real failure to
    # reach the endpoint.
    return "endpoint unreachable"


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
    with contextlib.suppress(Exception):
        fcntl.flock(handle, fcntl.LOCK_UN)
    with contextlib.suppress(Exception):
        handle.close()


def refresh(force=False, outcome=None):
    """Refresh the cache if stale; return the cache dict (fresh or last-known).

    When `outcome` is a dict, records *why* this call resolved the way it did in
    outcome["reason"] — one of: "fresh" (cache still within TTL), "ok" (fetched
    and wrote a new value), "cooldown" (a 429 back-off is active), "no_token" /
    "expiring_token" (credentials unusable — Claude Code rotates them), "429"
    (this call hit a 429 and armed the back-off), "lock_contended" (another
    refresh holds the lock — the endpoint was never contacted here), or
    "http_error" (a genuine non-200/non-429/network failure). Readers use this
    to name a stale cause precisely instead of guessing after the fact, which
    both mislabels lock contention and opens a check-after-refresh TOCTOU race.
    """
    def _out(reason):
        if outcome is not None:
            outcome["reason"] = reason

    if not force:
        age = cache_age()
        if age is not None and age < TTL_SECONDS:
            _out("fresh")
            return read_cache()
    if in_cooldown():
        _out("cooldown")
        return read_cache()
    token, exp_s = load_token()
    if not token:
        _out("no_token")
        return read_cache()
    if exp_s and exp_s < _now() + 30:
        # token is expired or about to expire; let Claude Code refresh it
        _out("expiring_token")
        return read_cache()
    # Serialize the fetch+cooldown update across processes. Two overlapping
    # UserPromptSubmit hooks each spawn a detached refresh, and both can clear
    # in_cooldown() above before either fires — without this guard they double-
    # hit the endpoint and, reading the same consecutive-429 count, fail to
    # escalate the backoff. A non-blocking lock means the refresh that loses the
    # race serves cache instead of sending a duplicate request.
    lock = _acquire_refresh_lock()
    if lock is None:
        _out("lock_contended")
        return read_cache()
    try:
        if in_cooldown():
            # whoever won the lock may have just armed the cooldown; re-check
            _out("cooldown")
            return read_cache()
        if not force:
            age = cache_age()
            if age is not None and age < TTL_SECONDS:
                # a refresh that beat us to the lock already refreshed the
                # cache; don't fire a now-redundant request
                _out("fresh")
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
            _out("ok")
            return data
        if status == 429:
            delay = set_cooldown(retry_after)
            log_event("cooldown_429", backoff_s=int(delay),
                      retry_after=int(retry_after) if retry_after else None)
            _out("429")
            return read_cache()
        _out("http_error")
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
    # Freshen synchronously when the readout would otherwise be stale: no cache
    # yet, or we've been idle long enough (> STALE_SECONDS) that the per-turn
    # background warm-refresh hasn't run. Without this, the first prompt after a
    # break prints a last-known/STALE line even though the endpoint is reachable
    # and a good value lands ~1s later (on the *next* turn) — the exact "we're
    # stale again" false alarm. refresh() self-throttles (returns instantly in a
    # 429 cooldown or with a missing/expiring token, bounded by HTTP_TIMEOUT
    # otherwise), and the gate keeps this off the hot path: an active session's
    # cache is well under STALE_SECONDS, so this never fires and `line` stays
    # instant. We capture refresh()'s outcome so a still-stale readout can name
    # its real cause rather than re-deriving it afterward (which mislabels lock
    # contention and races token/cooldown state).
    reason = None
    prev_age = (_now() - c.get("fetched_at", 0)) if c else None
    if prev_age is None or prev_age > STALE_SECONDS:
        outcome = {}
        fresh = refresh(outcome=outcome)
        reason = outcome.get("reason")
        if fresh:
            c = fresh
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
        # Name the real cause from refresh()'s own outcome (captured above), not
        # a re-derivation: an expired login token after an idle gap, or another
        # process holding the refresh lock, must not read as "endpoint
        # unreachable". If refresh() wasn't called this turn (reason is None —
        # e.g. the cache was under STALE_SECONDS by fetched_at but flagged stale
        # by mtime), fall back to a plain endpoint-unreachable label.
        why = _stale_why(reason)
        clk = fmt_clock(c.get("fetched_at"))
        since = f" (last good {clk})" if clk else ""
        line += (f"  ⚠ STALE {age // 60}m{since} — {why}."
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


UNDER_PACE = "▒"  # allowance you could have spent by now but haven't
OVER_PACE = "▓"   # spend that has already run past the pace mark

# The bar is deliberately calm. It paints itself in the terminal's own foreground
# instead of a green/yellow/red severity ramp, and lets the glyphs carry the three
# zones that aren't warnings: `█` solid for spend, `▒` half-tint for headroom you
# could still spend and stay on pace, `░` faint for the part of the window not yet
# earned. That's a clean luminance ramp in whatever colour the terminal already
# uses, which leaves orange as the single colour the bar introduces — so the one
# thing that *is* a warning is the only thing that pulls the eye.
#
# Orange from the 256-colour cube rather than a bright red or magenta from the
# 16-colour set: those resolve to whatever the user's theme says they mean (some
# themes alias bright back to normal, landing the tint on a colour already on
# screen; Solarized remaps bright red to orange outright), whereas 208 is a fixed
# point and lands identically everywhere. The usual objection to it — that orange
# sits next to the yellow severity band — doesn't apply now that the bar has no
# severity colours in it at all.
BAR_BASE = "\033[39m"          # the terminal's default foreground
DIM_ON, DIM_OFF = "\033[2m", "\033[22m"
OVER_TINT = "\033[38;5;208m"   # orange — the bar's only warning colour
RESET = "\033[0m"

# Every escape the bar emits is an *absolute* SGR state, because ANSI has no
# save/restore: `39m` means "default foreground", not "whatever you had", and
# `22m` means "normal intensity", not "the intensity you were at". A coloured bar
# therefore closes with a full reset and is self-contained — it can be dropped
# into a fragment without disturbing anything downstream — and callers that need
# to own the colouring, or to measure the fragment's display width, ask for the
# escape-free form instead.


def _finite(pct):
    """`pct` as a finite float, or None if it is not a usable number.

    Non-finite values are rejected rather than clamped. `min(100.0, nan)` returns
    100.0 in Python — every comparison against NaN is False, so the running
    minimum survives — which would quietly promote a NaN into the *worst
    possible* reading instead of bounding it. `usage.py bar nan` drawing a full
    bar is the visible form of that.
    """
    try:
        p = float(pct)
    except (TypeError, ValueError):
        return None
    return p if math.isfinite(p) else None


def _clamped(pct):
    """A value coerced to a finite 0-100 float; 0.0 for anything unusable."""
    p = _finite(pct)
    return 0.0 if p is None else max(0.0, min(100.0, p))


def _cells(pct, cells):
    """A 0-100 value as a whole number of bar segments (0..cells).

    Rounds half away from zero, not with Python's built-in `round` (which is
    banker's rounding, ties-to-even). The bar shows two rounded values at once —
    the spend and the pace mark — and the eye reads the *distance* between them,
    so their rounding has to be consistent: under ties-to-even, 4.5 and 3.5 both
    land on 4, and a full segment of overspend disappears. Half-away-from-zero
    makes a gap of exactly one segment always render as exactly one segment.
    """
    p = _clamped(pct) / 100 * cells
    return max(0, min(cells, int(math.floor(p + 0.5))))


def _bar(pct, cells=10, pace=None, ansi=False):
    """A `cells`-segment progress bar — one filled segment per (100/cells)%, so
    10 cells = 10% each: `[░░░░░░░░░░]` at 0, `[██░░░░░░░░]` at ~20, `[██████████]`
    at 100. The percentage is deliberately NOT drawn inside the bar (it would
    occlude segments) — render the number alongside it.

    Given `pace` (0-100 — where an evenly-paced spend would sit right now, from
    pace_pct()), the bar also carries a shadow of that mark, so you can see at a
    glance whether you are ahead of or behind the window's refill rate:

        [██▒▒▒░░░░░]  20% used, 50% pace — three segments of unspent headroom
        [█████▓░░░░]  60% used, 50% pace — one segment already past the mark

    The two shades never co-occur, and the invariant reads both ways: `█`+`▓` is
    always what you have used, `█`+`▒` is always where the pace mark sits.

    With `ansi`, the bar colours itself per the scheme above: the terminal's own
    default foreground for the spend and headroom glyphs, dim for the unearned
    tail, and orange for any overspend. It asserts the default foreground rather
    than inheriting, so a caller painting its fragment a warm hue cannot collide
    with the orange — ANSI yellow renders as amber on most themes, which would
    make an inherited bar indistinguishable from the one thing on it that means
    something is wrong. It closes with a full reset, so nothing leaks downstream.

    Without `ansi` — the default — it emits no escape codes whatsoever. That is
    what a caller wanting to own the colouring needs, and what any caller
    measuring the fragment's display width needs.
    """
    used = _cells(pct, cells)
    # An unusable value on *either* side means no mark at all, never a mark at
    # zero. Both fallbacks would have the bar assert something about a number it
    # does not have: an unusable pace draws the whole spend as overspend, and an
    # unusable percentage draws the entire pace mark as untouched headroom.
    mark = (None if _finite(pct) is None or _finite(pace) is None
            else _cells(pace, cells))
    if mark is None or mark == used:
        head, mid, tail = used, "", cells - used
    elif mark > used:
        head, mid, tail = used, UNDER_PACE * (mark - used), cells - mark
    else:
        head, mid, tail = mark, OVER_PACE * (used - mark), cells - used
    if not ansi:
        return "[" + "█" * head + mid + "░" * tail + "]"
    if mid and mark < used:
        mid = OVER_TINT + mid + BAR_BASE
    return (BAR_BASE + "[" + "█" * head + mid
            + DIM_ON + "░" * tail + DIM_OFF + "]" + RESET)


def cmd_status(plain=False):
    c = read_cache()
    if not c:
        return
    p5, p7 = c.get("five_hour_pct"), c.get("seven_day_pct")

    # Decide staleness up front: the per-window countdowns are computed from the
    # cached reset timestamps, so when the cache is stale they'd render as if
    # live (and a window may already have reset). Suppress them while stale and
    # show only the last-good wall-clock marker. A missing/invalid fetched_at
    # counts as stale so the fallback marker still appears.
    fetched_at = c.get("fetched_at")
    age = _now() - fetched_at if isinstance(fetched_at, (int, float)) else None
    stale = age is None or age > STALE_SECONDS

    # `plain` means exactly what it says: not one escape byte. A caller asking for
    # it wants to own the colouring, or to measure the fragment's display width to
    # pad or truncate it, and either is broken by a stray escape it cannot see or
    # undo. Colour mode does the reverse and is fully self-contained: every span
    # closes itself, so the fragment can be dropped anywhere without leaking.
    def seg(label, pct, reset_iso, unit, denom, window, cells):
        pace = pace_for(reset_iso, window, age)
        bar = _bar(pct, cells=cells, pace=pace, ansi=not plain)
        pct_txt = f"{pct}%" if plain else f"{_color(pct)}{pct}%{RESET}"
        frag = f"{label} {bar} {pct_txt}"
        if not stale:
            secs = _secs_until(reset_iso)
            if secs is not None and secs > 0:
                # ceil to one decimal: a live countdown must never show 0.0
                # (nor understate the wait) while the window is still limiting
                span = f"({math.ceil(secs / denom) / 10:.1f}{unit})"
                frag += span if plain else f"{DIM_ON}{span}{RESET}"
        return frag

    bits = []
    if p5 is not None:
        bits.append(seg("5h", p5, c.get("five_hour_reset"), "h", 360,
                        FIVE_HOUR_SECS, FIVE_HOUR_CELLS))
    if p7 is not None:
        bits.append(seg("7d", p7, c.get("seven_day_reset"), "d", 8640,
                        SEVEN_DAY_SECS, SEVEN_DAY_CELLS))
    if not bits:
        return
    # Always show the wall-clock time of the last successful read (e.g. "@17:52").
    # Fresh, it confirms the gauge is actually updating (and how recently); stale,
    # it's how old the frozen number is — and since the per-window countdowns are
    # suppressed while stale, this marker is then the only time signal. fetched_at
    # is the last successful fetch in both cases, so "@HH:MM" reads consistently as
    # "data as of HH:MM". Fall back to a bare "stale" only when the readout IS
    # stale and the timestamp is somehow unreadable; when it's fresh but the clock
    # can't be formatted, show nothing rather than a misleading "stale".
    clk = fmt_clock(fetched_at)
    marker = f"@{clk}" if clk else ("stale" if stale else "")
    if marker:
        bits.append(marker if plain else f"\033[2m{marker}\033[0m")
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
    # Guard the timestamp the same way cmd_status does. A present-but-non-numeric
    # `fetched_at` (a null in a half-written cache) would otherwise raise here,
    # before the first print — and main()'s blanket except would turn the one
    # command whose whole job is to report status into silent output.
    fetched_at = c.get("fetched_at")
    age = int(_now() - fetched_at) if isinstance(fetched_at, (int, float)) else None
    stale = age is None or age > STALE_SECONDS
    # Colour only when a terminal is going to interpret it: `show` is routinely
    # redirected to a file or captured by tooling, where escapes are noise.
    try:
        ansi = sys.stdout.isatty()
    except Exception:
        ansi = False

    def row(label, pct, reset_iso, window, cells):
        if _finite(pct) is None:
            # No bar at all: _cells() coerces an unusable value to zero, so
            # drawing one would assert "nothing spent, all this headroom" about a
            # number we do not have — and the bar is the more legible of the two
            # claims. Checked with _finite rather than `is None` so a malformed
            # cache holding a string or a NaN takes this path too, instead of
            # reaching the subtraction below and raising.
            return f"  {label}: no data — resets {fmt_reset(reset_iso)}"
        pace = pace_for(reset_iso, window, age)
        line = (f"  {label}: {_bar(pct, cells=cells, pace=pace, ansi=ansi)} {pct}% used"
                f" — resets {fmt_reset(reset_iso)}")
        if pace is not None:
            gap = round(pct - pace)
            n = abs(gap)
            drift = (f"{n} pt{'' if n == 1 else 's'} {'over' if gap > 0 else 'under'} pace"
                     if gap else "on pace")
            line += f"  (pace {round(pace)}%, {drift})"
        return line

    print("Claude subscription usage")
    print(row("Session (5h)", p5, c.get("five_hour_reset"), FIVE_HOUR_SECS, FIVE_HOUR_CELLS))
    print(row("Weekly  (7d)", p7, c.get("seven_day_reset"), SEVEN_DAY_SECS, SEVEN_DAY_CELLS))
    opus = c.get("seven_day_opus_pct")
    if opus is not None:
        # Carries a bar too, pace-less (the payload has no reset for it), so the
        # percentage column stays aligned with the two rows above — which is the
        # whole reason the three labels are padded to a common width.
        print(f"  Weekly Opus : {_bar(opus, cells=SEVEN_DAY_CELLS, ansi=ansi)} {opus}% used")
    # Be honest when the forced refresh could NOT reach the endpoint: a live
    # `show` that silently returns hour-old cache is exactly how a stale 0% gets
    # mistaken for current. Flag the cache age and any active back-off.
    if stale or in_cooldown():
        until, consec = _read_cooldown()
        wait = int(until - _now())
        note = ("  ⚠ NOT live — cache timestamp unreadable" if age is None
                else f"  ⚠ NOT live — cached {age // 60}m ago")
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
    # The never-raise contract, enforced at the one place every mode passes
    # through: whatever happens below, this exits 0 and disrupts nothing.
    with contextlib.suppress(Exception):
        if mode == "refresh":
            refresh()
        elif mode == "line":
            cmd_line()
        elif mode == "status":
            cmd_status(plain=(len(sys.argv) > 2 and sys.argv[2] == "plain"))
        elif mode == "bar":
            # Render a standalone progress bar for an arbitrary 0-100 value, so
            # callers (e.g. a status line showing Claude Code's own context %)
            # can reuse the exact same bar as the 5h/7d fragments. An optional
            # second value draws the pace shadow, for callers that know their
            # own budget line (a context window has no clock, so it has none).
            if len(sys.argv) > 2:
                pace = None
                if len(sys.argv) > 3:
                    # unparseable shadow: draw the bar without one
                    with contextlib.suppress(ValueError):
                        pace = float(sys.argv[3])
                # Colour only once a pace mark is in play: a bare value has
                # nothing to warn about, and callers already wrap it in a
                # hue of their own.
                with contextlib.suppress(ValueError):
                    sys.stdout.write(_bar(float(sys.argv[2]), pace=pace,
                                          ansi=pace is not None))
        elif mode == "show":
            cmd_show()
        elif mode == "log":
            cmd_log()
    sys.exit(0)


if __name__ == "__main__":
    main()

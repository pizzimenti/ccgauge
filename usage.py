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
                           missing or past TTL_SECONDS, so the first prompt
                           after a break shows live numbers rather than the
                           value the previous turn's background refresh left
    hookline            -- `line`, then a detached background `refresh` to warm
                           the cache for the next turn: the whole hook in one
                           command, for platforms without usage-line.sh (the
                           registered hook on Windows)
    status [plain]      -- short fragment (5h/7d bars) for the status line;
                           `plain` emits no ANSI at all, so the caller can colour
                           the fragment itself or measure its display width
    statusline          -- a complete example status line (cwd, model, context
                           bar, usage fragment) from Claude Code's status-line
                           JSON on stdin — statusline-snippet.sh without bash
    bar <pct> [pace]    -- a standalone 0-100 progress bar (e.g. for context %),
                           with the pace shadow when a second value is given
    show                -- force a synchronous refresh, print a human block
    log [N]             -- print the last N history events (default 20)

Runs on POSIX and native Windows: locking degrades from flock to msvcrt
byte-range locks, stdio is forced to UTF-8 where the ANSI code page would eat
the bar glyphs, and legacy consoles get virtual-terminal processing enabled.
"""

import contextlib
import errno
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

# urllib is imported lazily in _http_get: it drags in the whole http/email
# stack (~80-110 ms on Windows), which is half the start-up of the read-only
# modes — and `status`/`statusline` run on every status-line repaint.

try:
    import fcntl
except ImportError:  # non-POSIX: Windows fills the role with msvcrt below
    fcntl = None
try:
    import msvcrt  # Windows byte-range locks stand in for flock
except ImportError:  # neither module: degrade to unlocked best-effort I/O
    msvcrt = None

HOME = os.path.expanduser("~")
BASE = os.environ.get("CLAUDE_CONFIG_DIR", os.path.join(HOME, ".claude"))
CRED = os.path.join(BASE, ".credentials.json")
CACHE = os.path.join(BASE, "usage-cache.json")
COOLDOWN = os.path.join(BASE, "usage-429-cooldown")
LOG = os.path.join(BASE, "usage-log.jsonl")
LOCK = os.path.join(BASE, "usage-refresh.lock")
ERRBACKOFF = os.path.join(BASE, "usage-error-backoff")

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
ERROR_BACKOFF = TTL_SECONDS  # after a non-429 fetch failure, wait this long before retrying:
                         # a failed attempt writes no cache, so without it nothing advances the
                         # TTL clock and a synchronous caller retries (and blocks) every prompt
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
        # Resolve the CLI path ourselves: on Windows an npm-installed claude is
        # a `claude.cmd` shim, and CreateProcess's PATH search only finds
        # `.exe`s — shutil.which honors PATHEXT and finds either. On POSIX this
        # resolves to the same thing PATH search would. CREATE_NO_WINDOW stops
        # the .cmd shim's cmd.exe from flashing a console when this runs from
        # the console-less detached refresh.
        exe = shutil.which("claude")
        kwargs = {}
        if os.name == "nt":
            kwargs["creationflags"] = 0x08000000  # CREATE_NO_WINDOW
            # Refuse a `claude` resolved from the *current directory*: hooks
            # run with cwd inside the user's project — untrusted content — and
            # shutil.which on Windows before 3.12 unconditionally searches cwd
            # first (3.12+ only when the machine config asks for it). A repo
            # cannot be allowed to plant a claude.cmd that a hook then runs.
            # No probe (and the pinned UA) beats running it.
            if exe and (os.path.normcase(os.path.dirname(os.path.abspath(exe)))
                        == os.path.normcase(os.getcwd())):
                exe = None
        else:
            exe = exe or "claude"
        if exe:
            # Not subprocess.run(timeout=...): on Windows its TimeoutExpired
            # path kills the direct child (the .cmd shim's cmd.exe) and then
            # re-reads the pipes with NO timeout — and the shim's node
            # grandchild, still holding the inherited write handles, blocks
            # that read until it exits on its own. A hook that "times out in
            # 5s" hanging for a minute is exactly that. Kill and *abandon*
            # instead: the pipe-reader threads are daemonic, so nothing keeps
            # the process alive, and the fallback UA covers the gap.
            proc = subprocess.Popen(
                [exe, "--version"], stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                text=True, **kwargs,
            )
            try:
                out, _ = proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(Exception):
                    proc.kill()
                out = ""
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


def _init_windows_console():
    """Windows-only, best-effort stream/console setup; a no-op elsewhere.

    Closes two gaps that would otherwise void the gauge *silently* (the
    never-raise contract turns an encoding error into empty output):

    * Piped stdio defaults to the ANSI code page (cp1252 on US installs),
      which cannot encode the bar glyphs (█ ▒ ▓ ░) or ⚠ — and hook and
      status-line output is always piped. Claude Code decodes that output as
      UTF-8 on every platform, so re-encode the streams to UTF-8. stdin gets
      the same treatment for the hook payload it pipes to us.
    * Legacy conhost prints ANSI escapes as literal text until virtual
      terminal processing is switched on. Windows Terminal — the Win11
      default — has it always-on and ignores this. GetConsoleMode fails when
      stdout is a pipe, which is exactly the case where the escapes are the
      consumer's business, so a failure means skip, not force.
    """
    if os.name != "nt":
        return
    for stream in (sys.stdout, sys.stderr, sys.stdin):
        with contextlib.suppress(Exception):
            if stream and (stream.encoding or "").lower().replace("-", "") != "utf8":
                try:
                    stream.reconfigure(encoding="utf-8")
                except Exception:
                    # Can't change the encoding (exotic replaced stream):
                    # settle for lossy output — ? for █ is a readable gauge,
                    # an UnicodeEncodeError eaten by the never-raise umbrella
                    # is a blank one.
                    stream.reconfigure(errors="replace")
    with contextlib.suppress(Exception):
        import ctypes
        kernel32 = ctypes.windll.kernel32
        for handle_id in (-11, -12):  # STD_OUTPUT_HANDLE, STD_ERROR_HANDLE
            handle = kernel32.GetStdHandle(handle_id)
            mode = ctypes.c_uint32()
            if kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
                # 0x0004 = ENABLE_VIRTUAL_TERMINAL_PROCESSING
                kernel32.SetConsoleMode(handle, mode.value | 0x0004)


def _tilde(path):
    """Abbreviate a path under HOME to ~, or return it unchanged.

    Compared case-insensitively where the filesystem is (normcase), and only at
    a path-component boundary, so on Windows a hook cwd of `c:\\users\\...`
    still abbreviates and `/home/brad` never claims `/home/bradley2`.

    A trailing separator on HOME (a hand-set USERPROFILE often has one) is
    ignored for the comparison; a HOME that *is* a filesystem root is not
    abbreviated at all — `~` in front of everything on the drive is noise,
    not a shorthand.
    """
    norm = os.path.normcase
    home = HOME.rstrip("/\\")
    if not home or home.endswith(":"):
        return path
    if norm(path).startswith(norm(home)):
        rest = path[len(home):]
        if not rest or rest[0] in (os.sep, os.altsep or os.sep):
            return "~" + rest
    return path


def load_token():
    """Return (access_token, expires_at_seconds) or (None, None).

    Read as UTF-8 (with an optional BOM): the file is written by Claude Code
    — JSON on disk is UTF-8 — and Windows' locale default (cp1252) would both
    misread any non-ASCII byte and reject a hand-editor's BOM. Non-dict JSON
    anywhere in the shape degrades to "no token" like every other defect here.
    """
    try:
        with open(CRED, encoding="utf-8-sig") as fh:
            data = json.load(fh)
    except Exception:
        return None, None
    if not isinstance(data, dict):
        return None, None
    oauth = data.get("claudeAiOauth", data)  # tolerate either nesting
    if not isinstance(oauth, dict):
        return None, None
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


# A network failure is not a 429 and must not arm the 429 ladder: that escalates
# to BACKOFF_CAP (2h) and exists to let a server-side quota drain, which is the
# wrong response to a dropped Wi-Fi link. But an unreachable endpoint writes no
# cache, so nothing advances the TTL clock either — and a synchronous caller that
# gates on that clock will retry on every single prompt, paying HTTP_TIMEOUT each
# time. One failed attempt therefore parks the next one a full TTL out: the same
# cadence a successful fetch would have set, so an outage costs no more attempts
# than normal operation.
def in_error_backoff():
    """True if a recent non-429 fetch failure asked us to wait."""
    try:
        with open(ERRBACKOFF) as fh:
            return _now() < float(fh.read().strip())
    except Exception:
        return False


def set_error_backoff():
    with contextlib.suppress(Exception):
        with open(ERRBACKOFF, "w") as fh:
            fh.write(str(_now() + ERROR_BACKOFF))


def clear_error_backoff():
    with contextlib.suppress(Exception):
        os.remove(ERRBACKOFF)


def _lock_fh(fh, shared=False):
    """Best-effort cross-process lock on an open file object; True if held.

    POSIX: a blocking flock, exactly as before locking was portable. Windows:
    msvcrt.locking on the file's first byte — it has no shared mode, so readers
    take the exclusive lock too, and instead of msvcrt's blocking mode (which
    polls once per second and then *raises*) contention is retried every 50 ms
    for ~1 s, after which the caller proceeds unlocked: for a telemetry log, a
    torn line beats a stalled prompt hook. The byte-range lock does not block
    I/O through the *holding* handle, so the append/trim below works while the
    lock is held, and the OS drops the lock with the handle just as flock does.
    False (from contention, absence of both modules, or any error) means
    "proceed unlocked" — the caller must skip the unlock.
    """
    if fcntl:
        try:
            fcntl.flock(fh, fcntl.LOCK_SH if shared else fcntl.LOCK_EX)
            return True
        except Exception:
            return False
    if msvcrt:
        try:
            pos = fh.tell()
            fh.seek(0)
            got = False
            for _ in range(20):
                try:
                    msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
                    got = True
                    break
                except OSError:
                    time.sleep(0.05)
            fh.seek(pos)
            return got
        except Exception:
            return False
    return False


def _unlock_fh(fh):
    """Release a _lock_fh lock; never raises. Closing the file releases it on
    both platforms anyway — the explicit release just makes the window
    deterministic instead of waiting on the close."""
    with contextlib.suppress(Exception):
        if fcntl:
            fcntl.flock(fh, fcntl.LOCK_UN)
        elif msvcrt:
            pos = fh.tell()
            fh.seek(0)
            msvcrt.locking(fh.fileno(), msvcrt.LK_UNLCK, 1)
            fh.seek(pos)


def log_event(event, **fields):
    """Append one JSONL record to the history log. Best-effort, never raises.

    None-valued fields are dropped. The append and any trim run under one
    exclusive cross-process lock on the log fd (flock on POSIX, a byte-range
    lock on Windows — see _lock_fh), and the trim rewrites in place (no
    rename), so concurrent writers (foreground `line` + detached `refresh`)
    can neither interleave mid-line nor lose an append that races a trim. The
    lock matters *more* on Windows: POSIX O_APPEND writes are atomic on their
    own, but the CRT emulates append with a seek-then-write, which isn't. The
    lock is held for at most one ~1 MiB read+write (milliseconds). If no lock
    can be taken, degrade to an unlocked append.

    CCGAUGE_NO_LOG suppresses the write entirely. install.sh sets it while it
    exercises the real hook to prove the install works: that run is synthetic,
    and without this it appends a fabricated prompt event that `usage.py log`
    then reports back as genuine session history — every install, every update.
    """
    if os.environ.get("CCGAUGE_NO_LOG") == "1":
        return
    with contextlib.suppress(Exception):
        rec = {
            "ts": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
            "event": event,
        }
        rec.update((k, v) for k, v in fields.items() if v is not None)
        with open(LOG, "a+") as fh:
            locked = _lock_fh(fh)
            try:
                fh.write(json.dumps(rec) + "\n")
                fh.flush()
                if fh.tell() > LOG_MAX_BYTES:
                    fh.seek(0)
                    keep = fh.readlines()[-LOG_KEEP_LINES:]
                    # Bound by bytes too: oversized records (e.g. a very long
                    # cwd) could otherwise leave LOG_KEEP_LINES lines still
                    # over the cap, re-triggering this rewrite on every
                    # append. Targeting half the cap gives the same hysteresis
                    # in the normal case.
                    total = sum(len(line) for line in keep)
                    while keep and total > LOG_MAX_BYTES // 2:
                        total -= len(keep.pop(0))
                    fh.seek(0)
                    fh.truncate()
                    fh.writelines(keep)
            finally:
                if locked:
                    _unlock_fh(fh)


def _hook_payload():
    """Parse the JSON Claude Code pipes to a hook's stdin ({} when absent).

    Guarded by isatty so a manual `usage.py line` at a terminal never blocks
    waiting for input. The prompt text in the payload is never logged.
    """
    with contextlib.suppress(Exception):
        if sys.stdin is not None and not sys.stdin.isatty():
            raw = sys.stdin.read()
            if raw.strip():
                data = json.loads(raw)
                if isinstance(data, dict):  # non-dict JSON is not a payload
                    return data
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
    import urllib.error
    import urllib.request
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
    if reason == "error_backoff":
        return ("endpoint unreachable on the last try — waiting out a short"
                " back-off before retrying (`usage.py show` retries now)")
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
    _NO_LOCK sentinel when no locking primitive exists, so refresh proceeds
    unlocked exactly as it did before locking existed.

    POSIX locks with flock; Windows with msvcrt.locking on the file's first
    byte. Both are released by the OS when the handle goes away, so a crashed
    refresh cannot wedge future ones.
    """
    if not (fcntl or msvcrt):
        return _NO_LOCK
    try:
        fd = open(LOCK, "w")
    except Exception:
        return _NO_LOCK  # can't create the lock file; don't block refresh
    if fcntl:
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
    try:
        msvcrt.locking(fd.fileno(), msvcrt.LK_NBLCK, 1)
    except OSError as e:
        fd.close()
        # EACCES is how msvcrt spells "someone else holds the lock" (EDEADLK
        # is its blocking-mode cousin); anything else means locking itself
        # misbehaved, and unlocked beats never-refreshing.
        return None if e.errno in (errno.EACCES, errno.EDEADLK) else _NO_LOCK
    except Exception:
        fd.close()
        return _NO_LOCK
    return fd


def _release_refresh_lock(handle):
    if handle is _NO_LOCK:
        return
    with contextlib.suppress(Exception):
        if fcntl:
            fcntl.flock(handle, fcntl.LOCK_UN)
        elif msvcrt:
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
    with contextlib.suppress(Exception):
        handle.close()


def refresh(force=False, outcome=None):
    """Refresh the cache if stale; return the cache dict (fresh or last-known).

    When `outcome` is a dict, records *why* this call resolved the way it did in
    outcome["reason"] — one of: "fresh" (cache still within TTL), "ok" (fetched
    and wrote a new value), "cooldown" (a 429 back-off is active), "no_token" /
    "expiring_token" (credentials unusable — Claude Code rotates them), "429"
    (this call hit a 429 and armed the back-off), "lock_contended" (another
    refresh holds the lock — the endpoint was never contacted here),
    "error_backoff" (a recent non-429 failure parked the next attempt), or
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
    # `force` (i.e. `show`) bypasses this the same way it bypasses the TTL: the
    # user asked for a live read and can wait out one timeout.
    if not force and in_error_backoff():
        _out("error_backoff")
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
        if not force and in_error_backoff():
            # ...and may equally have just armed the error back-off, having hit
            # the same unreachable endpoint we are about to reach for
            _out("error_backoff")
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
            clear_error_backoff()
            _out("ok")
            return data
        if status == 429:
            delay = set_cooldown(retry_after)
            log_event("cooldown_429", backoff_s=int(delay),
                      retry_after=int(retry_after) if retry_after else None)
            _out("429")
            return read_cache()
        # Park the next attempt. Without this the cache is never written, so the
        # TTL clock never advances, so a synchronous caller gating on it retries
        # on every prompt — turning an endpoint outage into HTTP_TIMEOUT of
        # latency per turn instead of the documented one-off after an idle gap.
        set_error_backoff()
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
    if isinstance(cwd, str):
        cwd = _tilde(cwd)
    session = hook.get("session_id")
    c = read_cache()
    # Freshen synchronously whenever the cache is refetchable — no cache yet, or
    # older than TTL_SECONDS. The hook prints this line *before* it spawns the
    # background warm-refresh, so without this gate the number shown is always
    # one fetched on some earlier turn. Gating on STALE_SECONDS instead left a
    # dead band between TTL_SECONDS and STALE_SECONDS: a 10-30 minute gap between
    # prompts (a long agent turn, reading a diff, stepping away) printed data up
    # to STALE_SECONDS old with no staleness marker, because the background
    # refresh that would have fixed it lands *after* this line is already in
    # context. Matching the gate to the TTL closes that band.
    #
    # This does not raise the request rate: refresh() self-throttles on the same
    # TTL, the same 429 cooldown and the same lock, so the ceiling stays one
    # request per TTL_SECONDS — the fetch just moves ahead of the print instead
    # of trailing it. Cost is up to HTTP_TIMEOUT of prompt latency on the first
    # prompt after an idle gap; during active back-and-forth the cache stays
    # under TTL and this never fires, so `line` stays instant. We capture
    # refresh()'s outcome so a still-stale readout can name its real cause
    # rather than re-deriving it afterward (which mislabels lock contention and
    # races token/cooldown state).
    #
    # The gate reads cache_age() — the file's mtime — because that is the clock
    # refresh() throttles on. Gating on the payload's fetched_at instead let the
    # two disagree: a cache restored from a backup, or copied between machines,
    # carries an old fetched_at on a new mtime, so every prompt decided a refresh
    # was due and refresh() then declined it as premature, printing the same
    # stale numbers this gate exists to prevent. One clock, one decision.
    reason = None
    prev_age = cache_age()
    if prev_age is None or prev_age > TTL_SECONDS:
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
    # A non-numeric fetched_at (a hand-damaged cache) counts as stale-with-
    # unknown-age rather than raising: the percentages beside it may still be
    # real, and one bad field must not void the whole line.
    fa = c.get("fetched_at")
    age = int(_now() - fa) if isinstance(fa, (int, float)) else None
    log_event("prompt", five_hour_pct=p5, seven_day_pct=p7, cache_age_s=age,
              cwd=cwd, session_id=session)
    stale = age is None or age > STALE_SECONDS
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
        for_txt = f"{age // 60}m" if age is not None else "(age unknown)"
        line += (f"  ⚠ STALE {for_txt}{since} — {why}."
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


def _spawn_detached_refresh():
    """Kick a background `refresh` and return without waiting. Never raises.

    The cross-platform equivalent of usage-line.sh's `refresh ... & disown`:
    stdio on devnull and the child in its own session (POSIX) or its own
    console-less process group (Windows — DETACHED_PROCESS rather than
    CREATE_NO_WINDOW, which would still allocate a hidden console), so Claude
    Code never waits on it and nothing flashes. The child self-throttles via
    TTL, cooldown and the refresh lock, so firing one per prompt is cheap.
    """
    with contextlib.suppress(Exception):
        kwargs = {}
        if os.name == "nt":
            # 0x8 DETACHED_PROCESS | 0x200 CREATE_NEW_PROCESS_GROUP (the
            # parent console's Ctrl+C must not reach the child)
            kwargs["creationflags"] = 0x00000008 | 0x00000200
        else:
            kwargs["start_new_session"] = True
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "refresh"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, close_fds=True, **kwargs,
        )


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


def cmd_statusline():
    """A complete status line: cwd, model, context bar, then the 5h/7d gauges.

    The Python twin of statusline-snippet.sh, for platforms where bash isn't on
    the render path — on Windows a PowerShell start-up per render would cost
    more than the render itself, and this is one Python process instead of
    python-inside-bash. Reads Claude Code's status-line JSON from stdin and
    composes the same fragment the snippet does: blue cwd, dim model, a
    pace-less context bar (a context window has no clock), then cmd_status's
    self-contained colour fragment straight from the cache. Anything missing
    from the payload simply doesn't render — same contract as everything else.
    """
    payload = _hook_payload()

    # Every extraction is type-checked, not just null-checked: the docstring's
    # "anything missing simply doesn't render" has to hold for *malformed* too.
    # One wrong-typed field raising here would blank the whole line — including
    # the usage gauges, which don't depend on the payload at all.
    def sub(key, inner):
        d = payload.get(key)
        v = d.get(inner) if isinstance(d, dict) else None
        return v

    cwd = sub("workspace", "current_dir") or payload.get("cwd")
    cwd = _tilde(cwd) if isinstance(cwd, str) else ""
    model = sub("model", "display_name")
    model = model if isinstance(model, str) else ""
    sys.stdout.write(f"\033[0;34m{cwd}\033[0m \033[2m{model}\033[0m")
    pct = _finite(sub("context_window", "used_percentage"))
    if pct is not None:
        # _cells with 100 cells *is* the display rounding (clamped 0-100,
        # half away from zero) — reuse it so the number and the bar agree.
        pct = _cells(pct, 100)
        sys.stdout.write(f" ctx {_bar(pct)} {pct}%")
    cmd_status()


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
            locked = _lock_fh(fh, shared=True)  # don't read mid-trim
            try:
                lines = fh.readlines()
            finally:
                if locked:
                    _unlock_fh(fh)
    except FileNotFoundError:
        lines = []
    except Exception:
        # Windows byte-range locks are mandatory: losing the lock race and
        # reading anyway raises. "No events recorded yet" would be a lie —
        # the log is full, just briefly unreadable.
        print("usage log: unreadable right now (another process holds it) — try again")
        return
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
    _init_windows_console()  # internally best-effort; no-op off Windows
    # The never-raise contract, enforced at the one place every mode passes
    # through: whatever happens below, this exits 0 and disrupts nothing.
    with contextlib.suppress(Exception):
        if mode == "refresh":
            refresh()
        elif mode == "line":
            cmd_line()
        elif mode == "hookline":
            # `line` plus the detached cache-warmer, in one command — the hook
            # entry point for platforms that can't run usage-line.sh. Order
            # matters: line goes first so its synchronous freshen (when the
            # cache is stale) wins the refresh lock deterministically. Its own
            # suppress keeps the two as independent as the shell wrapper's two
            # processes: a raise inside cmd_line must not also kill the
            # warm-refresh, or one bad cache value silences the gauge forever.
            with contextlib.suppress(Exception):
                cmd_line()
            _spawn_detached_refresh()
        elif mode == "statusline":
            cmd_statusline()
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

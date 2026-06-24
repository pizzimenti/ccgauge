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
  * The endpoint 429s hard if polled too fast -> only fetch when the cache
    is older than TTL_SECONDS, and back off COOLDOWN_SECONDS after any 429.
  * Never raise: every command path swallows errors and exits 0 so this can
    never disrupt a hook or the status line.

Modes (argv[1]):
    refresh  (default) -- fetch only if cache is stale & not in cooldown
    line                -- one-line snapshot for the UserPromptSubmit hook
    status              -- short coloured fragment for the status line
    show                -- force a synchronous refresh, print a human block
"""

import json
import os
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
BASE = os.environ.get("CLAUDE_CONFIG_DIR", os.path.join(HOME, ".claude"))
CRED = os.path.join(BASE, ".credentials.json")
CACHE = os.path.join(BASE, "usage-cache.json")
COOLDOWN = os.path.join(BASE, "usage-429-cooldown")

URL = "https://api.anthropic.com/api/oauth/usage"
UA = "claude-code/2.1.185"
BETA = "oauth-2025-04-20"

TTL_SECONDS = 180        # do not refetch within this window (matches safe poll rate)
COOLDOWN_SECONDS = 600   # back off this long after a 429
HTTP_TIMEOUT = 6
WARN_PCT = 80            # at/above this, flag it for the assistant to surface


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


def in_cooldown():
    try:
        with open(COOLDOWN) as fh:
            return float(fh.read().strip()) > _now()
    except Exception:
        return False


def set_cooldown():
    try:
        with open(COOLDOWN, "w") as fh:
            fh.write(str(_now() + COOLDOWN_SECONDS))
    except Exception:
        pass


def clear_cooldown():
    try:
        os.remove(COOLDOWN)
    except Exception:
        pass


def _http_get(token):
    """Return (status_code_or_None, body_dict_or_None)."""
    req = urllib.request.Request(
        URL,
        headers={
            "Authorization": "Bearer " + token,
            "anthropic-beta": BETA,
            "User-Agent": UA,
            "Accept": "application/json",
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return resp.status, json.load(resp)
    except urllib.error.HTTPError as e:
        return e.code, None
    except Exception:
        return None, None


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


def fmt_reset(iso):
    """ISO timestamp -> 'in 4h 1m' (or '' on failure)."""
    if not iso:
        return ""
    try:
        dt = datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
        secs = int((dt - datetime.now(timezone.utc)).total_seconds())
        if secs <= 0:
            return "now"
        h, m = secs // 3600, (secs % 3600) // 60
        return f"in {h}h {m}m" if h else f"in {m}m"
    except Exception:
        return ""


# --------------------------------------------------------------------------- #
# core
# --------------------------------------------------------------------------- #
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
    status, body = _http_get(token)
    if status == 200 and body:
        data = normalise(body)
        try:
            with open(CACHE, "w") as fh:
                json.dump(data, fh)
        except Exception:
            pass
        clear_cooldown()
        return data
    if status == 429:
        set_cooldown()
    return read_cache()


# --------------------------------------------------------------------------- #
# output modes
# --------------------------------------------------------------------------- #
def cmd_line():
    c = read_cache()
    if not c:
        print("[usage] no data yet (warming up — will populate next turn)")
        return
    p5, p7 = c.get("five_hour_pct"), c.get("seven_day_pct")
    if p5 is None and p7 is None:
        print("[usage] unavailable")
        return
    r5 = fmt_reset(c.get("five_hour_reset"))
    r7 = fmt_reset(c.get("seven_day_reset"))
    age = int(_now() - c.get("fetched_at", _now()))
    parts = []
    if p5 is not None:
        parts.append(f"session(5h) {p5}% used (resets {r5})")
    if p7 is not None:
        parts.append(f"week(7d) {p7}% used (resets {r7})")
    line = "[usage] " + " · ".join(parts) + f" [cache {age}s old]"
    hi = max(x for x in (p5, p7) if x is not None)
    if hi >= WARN_PCT:
        line += f"  ⚠ AT {hi}% — surface this to the user now."
    print(line)


def _color(pct):
    if pct is None:
        return "\033[2m"
    if pct >= 90:
        return "\033[0;31m"   # red
    if pct >= 70:
        return "\033[0;33m"   # yellow
    return "\033[0;32m"       # green


def cmd_status():
    c = read_cache()
    if not c:
        return
    p5, p7 = c.get("five_hour_pct"), c.get("seven_day_pct")
    bits = []
    if p5 is not None:
        bits.append(f"{_color(p5)}5h:{p5}%\033[0m")
    if p7 is not None:
        bits.append(f"{_color(p7)}7d:{p7}%\033[0m")
    if bits:
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
    print("Claude subscription usage")
    print(f"  Session (5h): {p5}% used — resets {fmt_reset(c.get('five_hour_reset'))}")
    print(f"  Weekly  (7d): {p7}% used — resets {fmt_reset(c.get('seven_day_reset'))}")
    if c.get("seven_day_opus_pct") is not None:
        print(f"  Weekly Opus : {c['seven_day_opus_pct']}% used")


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "refresh"
    try:
        if mode == "refresh":
            refresh()
        elif mode == "line":
            cmd_line()
        elif mode == "status":
            cmd_status()
        elif mode == "show":
            cmd_show()
    except Exception:
        pass  # never disrupt a hook or status line
    sys.exit(0)


if __name__ == "__main__":
    main()

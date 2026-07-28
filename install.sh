#!/usr/bin/env bash
# ccgauge installer.
#
# Installs everything ccgauge needs and then *proves* it works, exiting non-zero
# with a specific message if any part of it doesn't. A silent half-install is
# the failure mode worth designing against here: usage.py deliberately swallows
# its own errors so it can never disrupt a hook or a status line, which means a
# broken install shows up as a blank gauge rather than a complaint. The
# installer is the one place allowed to be loud.
#
#   ./install.sh              install (or update) and verify
#   ./install.sh --statusline install, taking over an existing status line
#   ./install.sh --check      verify an existing install; makes no network call
#   ./install.sh --help
#
# Updating is the same command: `git pull && ./install.sh`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONFIG_DIR/settings.json"
HOOK_DST="$CONFIG_DIR/hooks/usage-line.sh"
USAGE_DST="$CONFIG_DIR/usage.py"
STATUSLINE_DST="$CONFIG_DIR/statusline.sh"

CHECK_ONLY=0
TAKE_STATUSLINE=0
for arg in "$@"; do
  case "$arg" in
    --check)      CHECK_ONLY=1 ;;
    --statusline) TAKE_STATUSLINE=1 ;;
    --help|-h)
      # Print the header block, stopping before `set -euo pipefail`.
      sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
      exit 0 ;;
    *) echo "ccgauge: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
  esac
done

FAILURES=0
ok()   { printf '  \033[0;32mok\033[0m    %s\n' "$1"; }
warn() { printf '  \033[0;33mwarn\033[0m  %s\n' "$1"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# --------------------------------------------------------------------------- #
# prerequisites
# --------------------------------------------------------------------------- #
echo "ccgauge: checking prerequisites"
if command -v python3 > /dev/null 2>&1; then
  ok "python3 ($(python3 --version 2>&1))"
else
  fail "python3 not found — ccgauge is pure standard-library Python and needs it"
  echo
  echo "ccgauge: cannot continue without python3." >&2
  exit 1
fi
if command -v claude > /dev/null 2>&1; then
  ok "claude CLI ($(claude --version 2>&1 | head -1))"
else
  # Only used to derive the User-Agent; usage.py falls back to a pinned version.
  warn "claude CLI not on PATH — usage.py will fall back to its pinned User-Agent"
fi

# Platform. ccgauge reads the OAuth token straight off disk, and Claude Code only
# keeps it there on Linux and Windows — on macOS it lives in the Keychain, so
# there is no file for us to read and no amount of logging in will create one.
# Say so plainly here rather than letting the credentials check further down
# report a missing file and send you off to re-authenticate for nothing.
PLATFORM="$(uname -s 2>/dev/null || echo unknown)"
case "$PLATFORM" in
  Linux)  ok "platform: Linux" ;;
  Darwin)
    # Exit here, before touching anything. `fail` only increments a counter that
    # is read at the very end, so using it would install all three files and
    # replace the user's status line on a platform we have just declared
    # unsupported — leaving behind a gauge that can never populate.
    fail "platform: macOS — not supported"
    printf '        Claude Code stores its OAuth token in the macOS Keychain, not in\n'
    printf '        %s/.credentials.json, so ccgauge cannot read it.\n' "$CONFIG_DIR"
    printf '        Reading the Keychain is not implemented.\n\n'
    printf '\033[0;31mccgauge: nothing was installed or changed.\033[0m\n' >&2
    exit 1
    ;;
  MINGW*|MSYS*|CYGWIN*)
    ok "platform: Windows (Git Bash)"
    warn "Claude Code runs hooks and the status line through Git Bash when it is"
    warn "installed and PowerShell when it is not — these are bash scripts, so keep"
    warn "Git for Windows installed or they will not run"
    ;;
  *) warn "platform: $PLATFORM — untested; ccgauge is developed on Linux" ;;
esac

# --------------------------------------------------------------------------- #
# install
# --------------------------------------------------------------------------- #
if [ "$CHECK_ONLY" -eq 0 ]; then
  echo
  echo "ccgauge: installing into $CONFIG_DIR"
  mkdir -p "$CONFIG_DIR/hooks"

  cp "$HERE/usage.py"           "$USAGE_DST"
  cp "$HERE/hooks/usage-line.sh" "$HOOK_DST"
  cp "$HERE/statusline.sh"      "$STATUSLINE_DST"
  chmod +x "$USAGE_DST" "$HOOK_DST" "$STATUSLINE_DST"
  ok "copied usage.py, hooks/usage-line.sh, statusline.sh"

  if [ ! -f "$SETTINGS" ]; then
    printf '{\n  "hooks": {}\n}\n' > "$SETTINGS"
    ok "created $SETTINGS"
  fi

  # Register the UserPromptSubmit hook and the status line, backing up first.
  #
  # The backup is timestamped and is written ONLY on a run that actually changes
  # something. A single fixed settings.json.bak overwritten every run is a trap:
  # install, notice your status line changed, re-run the installer while working
  # out how to undo it, and the second run's backup — now identical to the
  # modified file — has destroyed the only copy of your original. Nothing here
  # ever overwrites an existing backup, and a no-op run leaves no litter.
  HOOK_PATH="$HOOK_DST" STATUSLINE_PATH="$STATUSLINE_DST" \
  TAKE_STATUSLINE="$TAKE_STATUSLINE" \
  python3 - "$SETTINGS" <<'PY' || settings_write_failed=1
import datetime, json, os, shlex, shutil, sys

G, Y, R, X = "\033[0;32m", "\033[0;33m", "\033[0;31m", "\033[0m"
path = sys.argv[1]

# Both values are *shell command strings*, so both get quoted. Quoting only the
# status line (as an earlier revision did) leaves a config dir containing a
# space producing a hook command the shell splits in half — and the hook then
# never fires, silently.
hook_path = os.environ["HOOK_PATH"]
sl_path = os.environ["STATUSLINE_PATH"]
hook_cmd = shlex.quote(hook_path)
statusline_cmd = "bash " + shlex.quote(sl_path)
take_statusline = os.environ.get("TAKE_STATUSLINE") == "1"

try:
    with open(path) as fh:
        original = fh.read()
    cfg = json.loads(original)
    if not isinstance(cfg, dict):
        raise ValueError("top level is not a JSON object")
except Exception as exc:
    # Without this, an unparseable settings.json aborts the whole installer
    # under `set -e` with a raw traceback, before the verification phase that
    # would have explained it.
    print(f"  {R}FAIL{X}  could not read settings.json: {exc}")
    print( "        fix it, or restore the newest settings.json.*.bak beside it")
    sys.exit(1)


def refers_to(cmd, target):
    """Does this command string invoke `target`, however it was quoted?"""
    try:
        words = shlex.split(cmd or "")
    except ValueError:
        words = (cmd or "").split()
    return any(os.path.realpath(w) == os.path.realpath(target)
               for w in words if w)


hooks = cfg.setdefault("hooks", {})
if not isinstance(hooks, dict):
    print(f"  {R}FAIL{X}  settings.json 'hooks' is not an object")
    sys.exit(1)
groups = hooks.setdefault("UserPromptSubmit", [])

# Compare by resolved path, not by exact string: a trailing slash or a symlink
# in CLAUDE_CONFIG_DIR spells the same hook differently and would otherwise
# append a *second* live registration, firing the hook twice per turn.
existing = [h for g in groups if isinstance(g, dict)
            for h in g.get("hooks", []) if isinstance(h, dict)
            and refers_to(h.get("command"), hook_path)]
if len(existing) > 1:
    print(f"  {Y}warn{X}  {len(existing)} duplicate hook registrations found — pruning to one")
    for g in groups:
        if isinstance(g, dict):
            g["hooks"] = [h for h in g.get("hooks", [])
                          if not (isinstance(h, dict)
                                  and refers_to(h.get("command"), hook_path))]
    groups[:] = [g for g in groups if isinstance(g, dict) and g.get("hooks")]
    existing = []
if existing:
    print(f"  {G}ok{X}    UserPromptSubmit hook already registered")
else:
    groups.append({"hooks": [{"type": "command", "command": hook_cmd}]})
    print(f"  {G}ok{X}    registered UserPromptSubmit hook")

# The status line is only taken over when it is absent, already ours, or the
# user explicitly asked. Replacing a foreign one by default means the documented
# "keep your own" setup cannot survive the documented `git pull && ./install.sh`
# update — every update would silently clobber it again.
sl = cfg.get("statusLine")
sl = sl if isinstance(sl, dict) else None
current = (sl or {}).get("command")
if current and refers_to(current, sl_path):
    print(f"  {G}ok{X}    status line already registered")
elif current and not take_statusline:
    print(f"  {Y}warn{X}  leaving your existing status line alone:")
    print(f"          {current}")
    print( "          add ccgauge to it yourself (see the README), or take it over with:")
    print( "              ./install.sh --statusline")
else:
    replacing = current
    # Set only the keys we own, so any sibling key in an existing statusLine
    # block (padding, refreshInterval, whatever Claude Code adds next) survives.
    block = sl if sl is not None else {}
    block["type"] = "command"
    block["command"] = statusline_cmd
    cfg["statusLine"] = block
    print(f"  {G}ok{X}    registered status line")

updated = json.dumps(cfg, indent=2) + "\n"
if updated == original:
    print(f"  {G}ok{X}    settings.json already correct — not rewritten")
    sys.exit(0)

stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
backup = f"{path}.{stamp}.bak"
try:
    shutil.copy2(path, backup)
except Exception as exc:
    print(f"  {R}FAIL{X}  could not write a backup ({exc}) — refusing to modify settings.json")
    sys.exit(1)
print(f"  {G}ok{X}    backed up settings.json -> {os.path.basename(backup)}")
if 'replacing' in dir() and replacing:
    print(f"  {Y}warn{X}  replaced your existing status line:")
    print(f"          {replacing}")
    print(f"          restore it from {os.path.basename(backup)}")

# Write via a temp file in the same directory, then rename: an interrupted write
# must not leave a truncated settings.json, which Claude Code would refuse.
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    fh.write(updated)
os.replace(tmp, path)
PY
  if [ "${settings_write_failed:-0}" -eq 1 ]; then
    echo
    printf '\033[0;31mccgauge: could not update settings.json — see above.\033[0m\n' >&2
    exit 1
  fi
fi

# --------------------------------------------------------------------------- #
# verify — this is the part that makes a broken install say so
# --------------------------------------------------------------------------- #
echo
echo "ccgauge: verifying"

for f in "$USAGE_DST" "$HOOK_DST" "$STATUSLINE_DST"; do
  if [ -x "$f" ]; then ok "present and executable: ${f#$CONFIG_DIR/}"
  elif [ -f "$f" ]; then fail "not executable: $f  (chmod +x it)"
  else fail "missing: $f  (re-run ./install.sh without --check)"
  fi
done

# usage.py must import and run. `bar` touches no state and no network, so it is
# the cheapest possible end-to-end proof that the interpreter can run the file.
if bar_out=$(python3 "$USAGE_DST" bar 50 2>&1) && [ -n "$bar_out" ]; then
  ok "usage.py runs               $bar_out"
else
  fail "usage.py produced no output — run: python3 $USAGE_DST bar 50"
fi

# Its never-raise contract: every mode must exit 0 even with no cache at all.
#
# Which modes get exercised depends on the mode we are in, because two of them
# touch the network. `show` always forces a refresh past the cache TTL, and
# `refresh` fetches whenever the cache is cold — and the endpoint 429s hard when
# polled too fast, so an installer that ran them per-step would trip the exact
# rate limit the tool exists to respect. `--check` is meant to be safe to run
# repeatedly while diagnosing a problem, including a rate-limit problem, so it
# runs neither: firing a request to diagnose a lockout is how you extend one.
MODES="status log"
[ "$CHECK_ONLY" -eq 0 ] && MODES="refresh $MODES"
for mode in $MODES; do
  if python3 "$USAGE_DST" "$mode" > /dev/null 2>&1 < /dev/null; then
    ok "usage.py $mode exits cleanly"
  else
    fail "usage.py $mode exited non-zero — it must never disrupt a hook"
  fi
done

# One pass over settings.json: prints its own findings and exits non-zero on the
# conditions that mean the install is incomplete, so the shell can fold that into
# the failure count. A status line pointing somewhere *else* is a warning rather
# than a failure — the README documents keeping your own — but no status line at
# all means half of ccgauge has nowhere to render.
settings_report=$(
  SETTINGS="$SETTINGS" HOOK_DST="$HOOK_DST" STATUSLINE_DST="$STATUSLINE_DST" \
  python3 <<'PY'
import json, os, shlex, sys

G, Y, R, X = "\033[0;32m", "\033[0;33m", "\033[0;31m", "\033[0m"
try:
    cfg = json.load(open(os.environ["SETTINGS"]))
except Exception as exc:
    print(f"  {R}FAIL{X}  settings.json is not valid JSON ({exc})")
    print("        restore it from the newest settings.json.*.bak beside it")
    sys.exit(1)
print(f"  {G}ok{X}    settings.json is valid JSON")

hook, sl = os.environ["HOOK_DST"], os.environ["STATUSLINE_DST"]


def refers_to(cmd, target):
    """Does this command string invoke `target`, however it was quoted?

    Both commands are shell strings and both are shlex.quote'd on the way in, so
    an exact string comparison against the bare path fails the moment the config
    dir contains a space — which is exactly when getting this right matters.
    """
    try:
        words = shlex.split(cmd or "")
    except ValueError:
        words = (cmd or "").split()
    return any(os.path.realpath(w) == os.path.realpath(target)
               for w in words if w)


groups = (cfg.get("hooks") or {}).get("UserPromptSubmit") or []
matches = [h for g in groups if isinstance(g, dict)
           for h in g.get("hooks", []) if isinstance(h, dict)
           and refers_to(h.get("command"), hook)]
registered = bool(matches)
if len(matches) > 1:
    print(f"  {Y}warn{X}  hook is registered {len(matches)} times — it will fire "
          f"{len(matches)}x per turn")
    print( "        re-run ./install.sh (without --check) to prune the duplicates")
print(f"  {G}ok{X}    UserPromptSubmit hook is registered" if registered
      else f"  {R}FAIL{X}  UserPromptSubmit hook is NOT registered")

cmd = (cfg.get("statusLine") or {}).get("command") or ""
ours = refers_to(cmd, sl)
if ours:
    print(f"  {G}ok{X}    status line is registered")
elif cmd:
    print(f"  {Y}warn{X}  status line points elsewhere: {cmd}")
    print( "        (fine if that is deliberate — see the README)")
else:
    print(f"  {R}FAIL{X}  no status line configured — the gauges have nowhere to render")
    print( "        re-run ./install.sh without --check")

sys.exit(0 if registered and (ours or cmd) else 1)
PY
) && settings_ok=1 || settings_ok=0
printf '%s\n' "$settings_report"
[ "$settings_ok" -eq 1 ] || \
  fail "settings.json is unreadable, or is missing the hook or the status line"

# The hook and the status line must both produce output for a realistic payload.
#
# Built with json.dumps rather than string splicing: a repo path containing a
# quote or backslash would otherwise produce invalid JSON that both parsers
# silently swallow, leaving these checks passing while testing nothing.
SAMPLE=$(PWD_VAL="$PWD" python3 -c '
import json, os
print(json.dumps({"workspace": {"current_dir": os.environ["PWD_VAL"]},
                  "model": {"display_name": "install-check"},
                  "context_window": {"used_percentage": 31.4},
                  "session_id": "install-check"}))')

# Run the scripts the way Claude Code will: through the *command string* stored
# in settings.json, not by invoking the path directly with the shell doing the
# quoting for us. Invoking directly is what let an unquoted, word-splittable
# hook command pass verification while being unusable in practice.
#
# CCGAUGE_USAGE_PY is cleared so these exercise the usage.py we just installed
# rather than whatever an ambient environment points at.
hook_cmd_stored=$(SETTINGS="$SETTINGS" python3 -c '
import json, os
cfg = json.load(open(os.environ["SETTINGS"]))
groups = (cfg.get("hooks") or {}).get("UserPromptSubmit") or []
print(next((h.get("command", "") for g in groups if isinstance(g, dict)
            for h in g.get("hooks", []) if isinstance(h, dict)), ""))' 2>/dev/null || echo "")
sl_cmd_stored=$(SETTINGS="$SETTINGS" python3 -c '
import json, os
cfg = json.load(open(os.environ["SETTINGS"]))
print(((cfg.get("statusLine") or {}).get("command")) or "")' 2>/dev/null || echo "")

hook_err=$(mktemp); sl_err=$(mktemp)
trap 'rm -f "$hook_err" "$sl_err"' EXIT

if [ -z "$hook_cmd_stored" ]; then
  fail "no hook command in settings.json to exercise"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  # Running the hook is not a read-only act: it logs a prompt event and detaches
  # a background refresh that can hit the endpoint. --check has to stay safe to
  # run repeatedly while diagnosing a rate-limit problem, so it stops at "the
  # hook is present, executable and registered".
  ok "hook registered (not executed — --check makes no network call)"
elif hook_out=$(printf '%s' "$SAMPLE" | env -u CCGAUGE_USAGE_PY sh -c "$hook_cmd_stored" 2>"$hook_err") \
     && printf '%s' "$hook_out" | grep -q '\[usage\]'; then
  ok "hook produces a context line"
else
  fail "hook did not produce a [usage] line — run: echo '{}' | sh -c $hook_cmd_stored"
  [ -s "$hook_err" ] && printf '        %s\n' "$(head -2 "$hook_err")"
fi

# Assert on ccgauge's own glyphs, not merely on non-emptiness: statusline.sh
# always emits ANSI escapes, so "is the output non-empty" can never fail, and
# folding stderr in would make an error message look like a successful render.
if [ -z "$sl_cmd_stored" ]; then
  warn "no status line command in settings.json to exercise"
elif sl_out=$(printf '%s' "$SAMPLE" | env -u CCGAUGE_USAGE_PY sh -c "$sl_cmd_stored" 2>"$sl_err") \
     && printf '%s' "$sl_out" | grep -q '[█░]'; then
  ok "status line renders a gauge"
  printf '        %s\n' "$(printf '%b' "$sl_out" | tail -1)"
else
  fail "status line did not render a gauge — run: echo '{}' | sh -c $sl_cmd_stored"
  [ -s "$sl_err" ] && printf '        %s\n' "$(head -2 "$sl_err")"
fi

# Credentials and the endpoint are best-effort: no network in a container, or a
# logged-out CLI, is not a broken install. Report, don't fail.
if [ ! -r "$CONFIG_DIR/.credentials.json" ]; then
  warn "no $CONFIG_DIR/.credentials.json — log in with the claude CLI, then re-run"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  ok "OAuth credentials readable"
  # --check makes no network call at all, so report the cache rather than fetch.
  cache_age=$(CACHE="$CONFIG_DIR/usage-cache.json" python3 -c '
import os, time
try:
    print(int(time.time() - os.path.getmtime(os.environ["CACHE"])))
except Exception:
    print(-1)' 2>/dev/null || echo -1)
  if [ "$cache_age" -lt 0 ]; then
    warn "no usage cache yet — run ./install.sh (without --check) or wait a turn"
  else
    ok "usage cache present (${cache_age}s old)"
  fi
else
  ok "OAuth credentials readable"
  # Exactly one forced refresh per run, its output reused for both the check and
  # the display. See the note on the mode loop above.
  show_out=$(python3 "$USAGE_DST" show 2>/dev/null || true)
  # `show` prints the cached percentages *and* a "NOT live" note when the forced
  # refresh could not land, so grepping for '%' would call an active 429
  # cooldown "endpoint reachable". Ask the question the other way round.
  if printf '%s' "$show_out" | grep -q 'NOT live'; then
    warn "endpoint did NOT respond — the numbers below are cached, not live"
    printf '%s\n' "$show_out" | sed 's/^/        /'
  elif printf '%s' "$show_out" | grep -q '%'; then
    ok "endpoint reachable — live numbers below"
    printf '%s\n' "$show_out" | sed 's/^/        /'
  else
    warn "could not read live usage yet (endpoint, rate limit, or token refresh)"
    warn "this is normal right after install; check again with: ./install.sh --check"
  fi
fi

# --------------------------------------------------------------------------- #
echo
if [ "$FAILURES" -gt 0 ]; then
  printf '\033[0;31mccgauge: %d check(s) FAILED — see above.\033[0m\n' "$FAILURES" >&2
  exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  printf '\033[0;32mccgauge: all checks passed.\033[0m\n'
  exit 0
fi

cat <<EOF
$(printf '\033[0;32mccgauge: installed and verified.\033[0m')

  Restart Claude Code (or start a new session) so the hook and status line load.

  Update later with:   git pull && ./install.sh
  Re-verify any time:  ./install.sh --check

The hook injects a [usage] line into the assistant's context each turn. At 95%
of the session window it directs the assistant to queue work, compact, and set
a wake-up alarm — add the standing note from the README's "Wind-down behavior"
section to your CLAUDE.md so the assistant treats that as policy.
EOF

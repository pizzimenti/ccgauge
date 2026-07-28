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
#   ./install.sh           install (or update) and verify
#   ./install.sh --check   verify an existing install, change nothing
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
case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  --help|-h)
    sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  "") ;;
  *) echo "ccgauge: unknown argument '$1' (try --help)" >&2; exit 2 ;;
esac

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
    fail "platform: macOS — not supported yet"
    printf '        Claude Code stores its OAuth token in the macOS Keychain, not in\n'
    printf '        %s/.credentials.json, so ccgauge cannot read it.\n' "$CONFIG_DIR"
    printf '        Reading the Keychain is not implemented. Nothing below will show\n'
    printf '        live numbers on this machine.\n'
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
  HOOK_CMD="$HOOK_DST" STATUSLINE_PATH="$STATUSLINE_DST" \
  python3 - "$SETTINGS" <<'PY'
import datetime, json, os, shlex, shutil, sys

path = sys.argv[1]
hook_cmd = os.environ["HOOK_CMD"]
# shlex.quote, because settings.json stores a *shell command string*: a
# CLAUDE_CONFIG_DIR containing a space would otherwise be split into two
# arguments and bash would try to open the first half.
statusline_cmd = "bash " + shlex.quote(os.environ["STATUSLINE_PATH"])
G, Y, X = "\033[0;32m", "\033[0;33m", "\033[0m"

with open(path) as fh:
    original = fh.read()
cfg = json.loads(original)

groups = cfg.setdefault("hooks", {}).setdefault("UserPromptSubmit", [])
if any(h.get("command") == hook_cmd for g in groups for h in g.get("hooks", [])):
    print(f"  {G}ok{X}    UserPromptSubmit hook already registered")
else:
    groups.append({"hooks": [{"type": "command", "command": hook_cmd}]})
    print(f"  {G}ok{X}    registered UserPromptSubmit hook")

current = (cfg.get("statusLine") or {}).get("command")
replacing = current if current and current != statusline_cmd else None
if current == statusline_cmd:
    print(f"  {G}ok{X}    status line already registered")
else:
    cfg["statusLine"] = {"type": "command", "command": statusline_cmd}
    print(f"  {G}ok{X}    registered status line")

updated = json.dumps(cfg, indent=2) + "\n"
if updated == original:
    print(f"  {G}ok{X}    settings.json already correct — not rewritten")
    sys.exit(0)

stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
backup = f"{path}.{stamp}.bak"
shutil.copy2(path, backup)
print(f"  {G}ok{X}    backed up settings.json -> {os.path.basename(backup)}")
if replacing:
    print(f"  {Y}warn{X}  replaced your existing status line:")
    print(f"          {replacing}")
    print(f"          restore it from {os.path.basename(backup)}")

with open(path, "w") as fh:
    fh.write(updated)
PY
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
# `show` is deliberately NOT in this loop. It is the one mode that calls
# refresh(force=True), bypassing the cache TTL, and the endpoint 429s hard when
# polled too fast — an installer that fires it once per verification step would
# trip the exact rate limit the tool exists to respect. It is run once, below,
# and its output reused.
for mode in refresh status log; do
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
groups = (cfg.get("hooks") or {}).get("UserPromptSubmit") or []
registered = any(h.get("command") == hook
                 for g in groups for h in g.get("hooks", []))
print(f"  {G}ok{X}    UserPromptSubmit hook is registered" if registered
      else f"  {R}FAIL{X}  UserPromptSubmit hook is NOT registered")

cmd = (cfg.get("statusLine") or {}).get("command") or ""
# Match the path however it was quoted: shlex.split understands both the quoted
# form we write and an unquoted one a user may have typed by hand.
try:
    words = shlex.split(cmd)
except ValueError:
    words = cmd.split()
ours = sl in words
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
SAMPLE='{"workspace":{"current_dir":"'"$PWD"'"},"model":{"display_name":"Test"},"context_window":{"used_percentage":31.4},"session_id":"install-check"}'

if hook_out=$(printf '%s' "$SAMPLE" | bash "$HOOK_DST" 2>&1) && [ -n "$hook_out" ]; then
  ok "hook produces a context line"
else
  fail "hook produced nothing — run: echo '{}' | bash $HOOK_DST"
fi

if sl_out=$(printf '%s' "$SAMPLE" | bash "$STATUSLINE_DST" 2>&1) && [ -n "$sl_out" ]; then
  ok "status line renders"
  printf '        %s\n' "$(printf '%b' "$sl_out" | head -2 | tail -1)"
else
  fail "status line produced nothing — run: echo '{}' | bash $STATUSLINE_DST"
fi

# Credentials and the endpoint are best-effort: no network in a container, or a
# logged-out CLI, is not a broken install. Report, don't fail.
if [ -r "$CONFIG_DIR/.credentials.json" ]; then
  ok "OAuth credentials readable"
  # Exactly one forced refresh per run, its output reused for both the check and
  # the display. See the note on the mode loop above.
  show_out=$(python3 "$USAGE_DST" show 2>/dev/null || true)
  if printf '%s' "$show_out" | grep -q '%'; then
    ok "endpoint reachable — live numbers below"
    printf '%s\n' "$show_out" | sed 's/^/        /'
  else
    warn "could not read live usage yet (endpoint, rate limit, or token refresh)"
    warn "this is normal right after install; check again with: ./install.sh --check"
  fi
elif [ "$PLATFORM" = "Darwin" ]; then
  # Already failed loudly up top; don't repeat the advice to log in, which would
  # be wrong here — the file is absent by design on macOS, not because you're
  # logged out.
  warn "no credentials file (expected on macOS — see the platform note above)"
else
  warn "no $CONFIG_DIR/.credentials.json — log in with the claude CLI, then re-run --check"
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

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
  cp "$SETTINGS" "$SETTINGS.bak"
  ok "backed up settings.json -> settings.json.bak"

  # Register the UserPromptSubmit hook and the status line. Both are idempotent;
  # an existing statusLine pointing elsewhere is reported (loudly) rather than
  # replaced silently, and the .bak above is the way back.
  HOOK_CMD="$HOOK_DST" STATUSLINE_CMD="bash $STATUSLINE_DST" \
  python3 - "$SETTINGS" <<'PY'
import json, os, sys

path = sys.argv[1]
hook_cmd = os.environ["HOOK_CMD"]
statusline_cmd = os.environ["STATUSLINE_CMD"]

with open(path) as fh:
    cfg = json.load(fh)

groups = cfg.setdefault("hooks", {}).setdefault("UserPromptSubmit", [])
registered = any(h.get("command") == hook_cmd
                 for g in groups for h in g.get("hooks", []))
if registered:
    print("  \033[0;32mok\033[0m    UserPromptSubmit hook already registered")
else:
    groups.append({"hooks": [{"type": "command", "command": hook_cmd}]})
    print("  \033[0;32mok\033[0m    registered UserPromptSubmit hook")

current = (cfg.get("statusLine") or {}).get("command")
if current == statusline_cmd:
    print("  \033[0;32mok\033[0m    status line already registered")
else:
    if current:
        print(f"  \033[0;33mwarn\033[0m  replacing your existing status line:")
        print(f"          {current}")
        print( "          the previous settings.json is at settings.json.bak")
    cfg["statusLine"] = {"type": "command", "command": statusline_cmd}
    print("  \033[0;32mok\033[0m    registered status line")

with open(path, "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
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
for mode in refresh status show log; do
  if python3 "$USAGE_DST" "$mode" > /dev/null 2>&1 < /dev/null; then
    ok "usage.py $mode exits cleanly"
  else
    fail "usage.py $mode exited non-zero — it must never disrupt a hook"
  fi
done

# One pass over settings.json: prints its own findings, and exits non-zero only
# for the one condition that is genuinely broken (an unregistered hook), so the
# shell can fold that into the failure count.
settings_report=$(
  SETTINGS="$SETTINGS" HOOK_DST="$HOOK_DST" STATUSLINE_DST="$STATUSLINE_DST" \
  python3 <<'PY'
import json, os, sys

G, Y, R, X = "\033[0;32m", "\033[0;33m", "\033[0;31m", "\033[0m"
try:
    cfg = json.load(open(os.environ["SETTINGS"]))
except Exception as exc:
    print(f"  {R}FAIL{X}  settings.json is not valid JSON ({exc})")
    print("        restore it from settings.json.bak")
    sys.exit(1)
print(f"  {G}ok{X}    settings.json is valid JSON")

hook, sl = os.environ["HOOK_DST"], os.environ["STATUSLINE_DST"]
groups = (cfg.get("hooks") or {}).get("UserPromptSubmit") or []
registered = any(h.get("command") == hook
                 for g in groups for h in g.get("hooks", []))
print(f"  {G}ok{X}    UserPromptSubmit hook is registered" if registered
      else f"  {R}FAIL{X}  UserPromptSubmit hook is NOT registered")

cmd = (cfg.get("statusLine") or {}).get("command") or ""
if sl in cmd:
    print(f"  {G}ok{X}    status line is registered")
elif cmd:
    print(f"  {Y}warn{X}  status line points elsewhere: {cmd}")
else:
    print(f"  {Y}warn{X}  no status line configured")

sys.exit(0 if registered else 1)
PY
) && settings_ok=1 || settings_ok=0
printf '%s\n' "$settings_report"
[ "$settings_ok" -eq 1 ] || \
  fail "settings.json is unreadable, or is missing the UserPromptSubmit hook"

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
  if python3 "$USAGE_DST" show 2>/dev/null | grep -q '%'; then
    ok "endpoint reachable — live numbers below"
    python3 "$USAGE_DST" show 2>/dev/null | sed 's/^/        /'
  else
    warn "could not read live usage yet (endpoint, rate limit, or token refresh)"
    warn "this is normal right after install; check again with: ./install.sh --check"
  fi
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

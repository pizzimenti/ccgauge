#!/usr/bin/env bash
# ccgauge installer.
#
# Copies usage.py + the UserPromptSubmit hook into your Claude Code config
# directory and registers the hook in settings.json (idempotently, with a
# backup). The status line is left to you — see statusline-snippet.sh.
#
# Usage:  ./install.sh            (installs into ~/.claude or $CLAUDE_CONFIG_DIR)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONFIG_DIR/settings.json"
HOOK_CMD="$CONFIG_DIR/hooks/usage-line.sh"

echo "ccgauge: installing into $CONFIG_DIR"
mkdir -p "$CONFIG_DIR/hooks"

cp "$HERE/usage.py" "$CONFIG_DIR/usage.py"
cp "$HERE/hooks/usage-line.sh" "$CONFIG_DIR/hooks/usage-line.sh"
chmod +x "$CONFIG_DIR/usage.py" "$CONFIG_DIR/hooks/usage-line.sh"
echo "ccgauge: copied usage.py and hooks/usage-line.sh"

if [ ! -f "$SETTINGS" ]; then
  printf '{\n  "hooks": {}\n}\n' > "$SETTINGS"
  echo "ccgauge: created $SETTINGS"
fi

cp "$SETTINGS" "$SETTINGS.bak"
echo "ccgauge: backed up settings.json -> settings.json.bak"

HOOK_CMD="$HOOK_CMD" python3 - "$SETTINGS" <<'PY'
import json, os, sys

path = sys.argv[1]
hook_cmd = os.environ["HOOK_CMD"]

with open(path) as fh:
    cfg = json.load(fh)

hooks = cfg.setdefault("hooks", {})
ups = hooks.setdefault("UserPromptSubmit", [])

def already_registered(groups):
    for g in groups:
        for h in g.get("hooks", []):
            if h.get("command") == hook_cmd:
                return True
    return False

if already_registered(ups):
    print("ccgauge: hook already registered — leaving settings.json unchanged")
else:
    ups.append({"hooks": [{"type": "command", "command": hook_cmd}]})
    with open(path, "w") as fh:
        json.dump(cfg, fh, indent=2)
        fh.write("\n")
    print("ccgauge: registered UserPromptSubmit hook in settings.json")
PY

cat <<EOF

ccgauge: done. Next steps:
  1. Verify it works:   python3 "$CONFIG_DIR/usage.py" show
  2. Status line:       see statusline-snippet.sh (append the 'usage.py status'
                        call to your existing status line, or use the example).
  3. Restart Claude Code (or just start a new session) so the hook loads.

The hook injects a [usage] line into the assistant's context each turn. At 95%
of the session window it directs the assistant to queue work, compact, and set
a wake-up alarm — add the standing note from the README's "Wind-down behavior"
section to your CLAUDE.md so the assistant treats that as policy.
EOF

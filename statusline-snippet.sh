#!/usr/bin/env bash
# Example Claude Code status line that appends ccgauge's usage indicator.
#
# Claude Code feeds the status-line command a JSON blob on stdin. This minimal
# example shows the cwd, the model, and the live 5h/7d usage fragment. If you
# already have a status line, just append the final `usage.py status` call to
# your existing printf — that one call only reads ccgauge's cache (no network),
# so it is safe to run on every render.
#
# Wire it up in settings.json:
#   "statusLine": { "type": "command", "command": "bash /path/to/statusline-snippet.sh" }

input=$(cat)
USAGE_PY="${CCGAUGE_USAGE_PY:-$HOME/.claude/usage.py}"

# Parse cwd + model from the status JSON with python3 (no jq dependency).
parsed=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
cwd = (d.get("workspace") or {}).get("current_dir") or d.get("cwd") or ""
model = (d.get("model") or {}).get("display_name") or ""
sys.stdout.write("\x1f".join([cwd, model]))
')
IFS=$'\x1f' read -r cwd model <<< "$parsed"

short_cwd="${cwd/#$HOME/\~}"
usage_str=$(python3 "$USAGE_PY" status 2>/dev/null)

printf "\033[0;34m%s\033[0m \033[2m%s\033[0m%b" "$short_cwd" "$model" "$usage_str"

#!/usr/bin/env bash
# Example Claude Code status line that appends ccgauge's usage indicator.
#
# Claude Code feeds the status-line command a JSON blob on stdin. This minimal
# example shows the cwd, the model, a context-window bar, and the live 5h/7d
# usage fragment. If you already have a status line, just append the final
# `usage.py status` call to your existing printf — that one call only reads
# ccgauge's cache (no network), so it is safe to run on every render.
#
# Wire it up in settings.json:
#   "statusLine": { "type": "command", "command": "bash /path/to/statusline-snippet.sh" }

input=$(cat)
USAGE_PY="${CCGAUGE_USAGE_PY:-$HOME/.claude/usage.py}"

# Parse cwd + model + context-window % from the status JSON with python3 (no jq).
parsed=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
cwd = (d.get("workspace") or {}).get("current_dir") or d.get("cwd") or ""
model = (d.get("model") or {}).get("display_name") or ""
ctx = (d.get("context_window") or {}).get("used_percentage")
sys.stdout.write("\x1f".join([cwd, model, "" if ctx is None else str(ctx)]))
')
IFS=$'\x1f' read -r cwd model used_pct <<< "$parsed"

short_cwd="${cwd/#$HOME/\~}"

# Context-window bar — reuse ccgauge's `bar` so it matches the 5h/7d bars.
ctx_str=""
if [ -n "$used_pct" ]; then
  # LC_NUMERIC=C so printf parses the JSON float (dot decimal) regardless of
  # the user's locale — a comma-decimal locale would otherwise error on "11.5".
  used_int=$(LC_NUMERIC=C printf "%.0f" "$used_pct")
  ctx_str=" ctx $(python3 "$USAGE_PY" bar "$used_int" 2>/dev/null) ${used_int}%"
fi

# 5h / 7d usage fragment (reads ccgauge's cache only).
usage_str=$(python3 "$USAGE_PY" status 2>/dev/null)

printf "\033[0;34m%s\033[0m \033[2m%s\033[0m%b%b" "$short_cwd" "$model" "$ctx_str" "$usage_str"

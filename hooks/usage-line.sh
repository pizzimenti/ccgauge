#!/usr/bin/env bash
# UserPromptSubmit hook: emit the current usage snapshot into the assistant's
# context, and kick off a background refresh for next turn. The refresh is
# detached with stdout/stderr/stdin closed so Claude Code never waits on it,
# and usage.py self-throttles (TTL + 429 cooldown), so this is cheap.
#
# Resolve usage.py relative to this script so it works wherever ccgauge is
# installed (default: ~/.claude/usage.py).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USAGE_PY="${CCGAUGE_USAGE_PY:-$HERE/../usage.py}"
[ -f "$USAGE_PY" ] || USAGE_PY="$HOME/.claude/usage.py"

python3 "$USAGE_PY" refresh >/dev/null 2>&1 </dev/null &
disown 2>/dev/null

python3 "$USAGE_PY" line
exit 0

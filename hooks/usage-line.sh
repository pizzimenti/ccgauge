#!/usr/bin/env bash
# UserPromptSubmit hook: emit the current usage snapshot into the assistant's
# context, then warm the cache for next turn.
#
# `line` runs FIRST and in the foreground. In the common case (active session,
# warm cache) it prints instantly. When the cache has gone stale — the first
# prompt after an idle gap — `line` does one bounded, self-throttled synchronous
# fetch so it shows live numbers instead of a STALE marker that a good value
# would replace on the very next turn. Running it before the background refresh
# lets it win the refresh lock, so the freshen is deterministic (no race with a
# detached sibling).
#
# The trailing background refresh keeps the cache fresh within its TTL for the
# *next* turn without adding prompt latency: detached with stdout/stderr/stdin
# closed so Claude Code never waits on it, and usage.py self-throttles (TTL +
# 429 cooldown), so it no-ops whenever `line` already refreshed.
#
# Resolve usage.py relative to this script so it works wherever ccgauge is
# installed (default: ~/.claude/usage.py).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USAGE_PY="${CCGAUGE_USAGE_PY:-$HERE/../usage.py}"
[ -f "$USAGE_PY" ] || USAGE_PY="$HOME/.claude/usage.py"

python3 "$USAGE_PY" line

python3 "$USAGE_PY" refresh >/dev/null 2>&1 </dev/null &
disown 2>/dev/null
exit 0

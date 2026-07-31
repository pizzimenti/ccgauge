#!/usr/bin/env bash
# UserPromptSubmit hook: emit the current usage snapshot into the assistant's
# context, then warm the cache for next turn.
#
# `line` runs FIRST and in the foreground. In the common case (active session,
# cache still within its TTL) it prints instantly. Once the cache is past the
# TTL — the first prompt after any idle gap — `line` does one bounded,
# self-throttled synchronous fetch, so it shows live numbers rather than
# whatever the previous turn's background refresh happened to leave behind.
# That matters because this line lands in context *before* the refresh below
# runs: without the synchronous fetch the number shown is always one turn
# behind. Running `line` before the background refresh also lets it win the
# refresh lock, so the freshen is deterministic (no race with a detached
# sibling).
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

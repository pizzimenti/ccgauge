#!/usr/bin/env bash
# ccgauge's status line for Claude Code.
#
# Two lines: working directory, git branch, context-window bar and model on the
# first; the 5h/7d subscription gauges on the second.
#
#   ~/Code/ccgauge (main) ctx [███░░░░░░░] 31% Opus 5
#   5h [██▒▒░░░░░░] 20%(2.5h) · 7d [███▒░░░░░░░░░░] 24%(5.1d) · @14:05
#
# install.sh registers this in settings.json for you. Claude Code feeds it a
# JSON blob on stdin; python3 parses it, because jq is not guaranteed to be
# installed and ccgauge already depends on python3.
#
# Everything here reads ccgauge's cache only — no network — so it is safe to run
# on every render.
#
# ccgauge-statusline-marker
#   Verification looks for this string to tell ccgauge's own copy of this file
#   from something else sitting at the same path — $CONFIG_DIR/statusline.sh is
#   also where Claude Code's own /statusline command writes, so the name alone
#   proves nothing.
#
#   It no longer decides whether the file may be written: an install always
#   installs this one. Edit this file in place and the next update overwrites
#   you, keeping your copy beside it as a timestamped .bak. To run a status line
#   of your own, put it somewhere else and point settings.json at that.

input=$(cat)

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# Same fallback shape as hooks/usage-line.sh: a stale CCGAUGE_USAGE_PY left in
# the environment must not be fatal at render time, especially since install.sh
# strips the variable when verifying and so would never see the breakage.
USAGE_PY="${CCGAUGE_USAGE_PY:-$CONFIG_DIR/usage.py}"
[ -f "$USAGE_PY" ] || USAGE_PY="$CONFIG_DIR/usage.py"
[ -f "$USAGE_PY" ] || USAGE_PY="$HOME/.claude/usage.py"

# --- parse the status JSON (cwd / model / context-used%) --------------------
parsed=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
# Newlines are flattened before the record is emitted: the shell consumes this
# with `read`, which stops at the first one, so a newline anywhere in cwd or the
# model name would truncate the record and silently drop every later field.
flat = lambda s: " ".join(str(s).split()) if s else ""
cwd = flat((d.get("workspace") or {}).get("current_dir") or d.get("cwd") or "")
model = flat((d.get("model") or {}).get("display_name") or "")
# Round to a whole percent here rather than in the shell. bash printf parses
# floats through the *ambient* locale, and prefixing LC_NUMERIC=C does not
# reach the builtin — in any comma-decimal locale (de_DE, fr_FR, ...) it stops
# at the "." and returns non-zero, so a shell-side conversion is either wrong
# or, if you trust the exit status, silently drops the whole indicator. Python
# is already a hard dependency and is locale-independent here.
ctx = (d.get("context_window") or {}).get("used_percentage")
try:
    # Broad except on purpose: round() on a float large enough to overflow int
    # raises OverflowError, which is neither TypeError nor ValueError — and
    # because this runs before the single write below, an escape here loses the
    # *whole* record, taking cwd, branch and model down with the percentage.
    ctx = str(max(0, min(100, round(float(ctx)))))
except Exception:
    ctx = ""
sys.stdout.write("\x1f".join([cwd, model, ctx]))
' 2>/dev/null)
IFS=$'\x1f' read -r cwd model used_pct <<< "$parsed"

# Shorten the home directory to ~
#
# Matched on a path-component boundary, not as a bare string prefix.
# `${cwd/#$HOME/\~}` replaces any cwd whose *characters* begin with $HOME, so
# with HOME=/home/ada a session in /home/ada2/proj renders as "~2/proj" — a path
# that is wrong and not copy-pasteable. Quoting $HOME in the case patterns also
# stops it being read as a glob.
short_cwd="$cwd"
if [ -n "${HOME:-}" ]; then
  case "$cwd" in
    "$HOME")   short_cwd="~" ;;
    "$HOME"/*) short_cwd="~${cwd#"$HOME"}" ;;
  esac
fi

# Git branch (skip optional locks so a busy repo can never block the prompt)
git_branch=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null \
           || GIT_OPTIONAL_LOCKS=0 git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    git_branch=" \033[0;33m($branch)\033[0m"
  fi
fi

# Context-window indicator — the same bar as the 5h/7d gauges, fed by Claude
# Code's own context_window.used_percentage. Passed without a pace mark: a
# context window has no clock, so there is no "on track" position for it.
ctx_str=""
if [ -n "$used_pct" ]; then
  # Already a clamped whole number from the parser above, but re-validate: this
  # value reaches an arithmetic comparison, and showing no indicator is always
  # better than showing a wrong one.
  used_int="$used_pct"
  case "$used_int" in
    ''|*[!0-9]*) used_int="" ;;
  esac
  if [ -n "$used_int" ]; then
    # Omit the whole segment if the bar can't be produced, rather than rendering
    # a bar-less `ctx  31%` — a missing usage.py should read as "not installed",
    # not as a subtly malformed gauge.
    ctx_bar=$(python3 "$USAGE_PY" bar "$used_int" 2>/dev/null || true)
    if [ -n "$ctx_bar" ]; then
      if   [ "$used_int" -ge 90 ]; then color="\033[0;31m"   # red
      elif [ "$used_int" -ge 70 ]; then color="\033[0;33m"   # yellow
      else                               color="\033[0;32m"  # green
      fi
      ctx_str=" ${color}ctx ${ctx_bar} ${used_int}%\033[0m"
    fi
  fi
fi

# Model name (dimmed)
model_str=""
if [ -n "$model" ]; then
  model_str=" \033[2m${model}\033[0m"
fi

# Subscription usage (5h / 7d) — reads ccgauge's cache, no network.
#
# Colour mode, NOT `status plain`. `plain` emits no ANSI at all and is for a
# caller that wants to colour the fragment itself; here usage.py owns the
# colouring. Note this line is deliberately NOT wrapped in a colour of our own:
# ANSI yellow renders as amber on most themes and would collide with the orange
# that is meant to be the only alarming thing on the bar.
usage_str=$(python3 "$USAGE_PY" status 2>/dev/null)

# Line 1: path · branch · context · model.
printf "\033[0;34m%s\033[0m%b%b%b" "$short_cwd" "$git_branch" "$ctx_str" "$model_str"
# Line 2: subscription usage, in the terminal's own foreground.
if [ -n "$usage_str" ]; then
  printf "\n%s\033[0m" "$usage_str"
fi

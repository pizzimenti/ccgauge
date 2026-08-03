#!/usr/bin/env bash
# Exit-code matrix for install.sh --check's status line verdicts.
#
# Run:  bash tests/test_check_semantics.sh     (exit 0 = pass; no arguments)
#
# Since 0.11.0 an install always installs ccgauge's status line, and --check's
# messages describe every other registration as something to restore. The exit
# code has to say the same thing: ccgauge's own registration pointing at
# ccgauge's own file is the only passing state. 0.11.0 shipped the messages but
# kept exit 0 whenever *any* command was registered — a survivor of the era
# when a foreign status line was a setup to preserve — so a scripted
# `./install.sh --check && ...` read "the gauges are not rendering" as healthy.
# Each case below pins one verdict to its exit code.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INST="$HERE/../install.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ccgauge-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

report() {  # label want_exit got_exit
    if [ "$2" = "$3" ]; then
        printf 'PASS  %-44s exit=%s\n' "$1" "$3"
        pass=$((pass + 1))
    else
        printf 'FAIL  %-44s exit=%s (want %s)\n' "$1" "$3" "$2"
        fail=$((fail + 1))
    fi
}

repoint() {  # dir command -> rewrite statusLine.command in settings.json
    python3 - "$1" "$2" <<'PY'
import json, sys
p = sys.argv[1] + "/settings.json"
cfg = json.load(open(p))
cfg["statusLine"] = {"type": "command", "command": sys.argv[2]}
json.dump(cfg, open(p, "w"), indent=2)
PY
}

# One real install, then mutate: every case below is a healthy install with
# exactly one thing changed, so the exit code isolates the verdict under test.
d="$WORK/cfg"
mkdir -p "$d"
CLAUDE_CONFIG_DIR="$d" bash "$INST" >/dev/null 2>&1 \
    || { echo "FATAL: priming install failed — cannot test --check" >&2; exit 1; }

CLAUDE_CONFIG_DIR="$d" bash "$INST" --check >/dev/null 2>&1; rc=$?
report "ours: registered, file is ours" 0 "$rc"

# Registered elsewhere, at a file that exists and runs. The old exit treated
# "some command is registered" as good enough; the gauges are not rendering.
printf '#!/bin/sh\necho mine\n' > "$WORK/mine.sh"; chmod +x "$WORK/mine.sh"
repoint "$d" "bash $WORK/mine.sh"
CLAUDE_CONFIG_DIR="$d" bash "$INST" --check >/dev/null 2>&1; rc=$?
report "points elsewhere" 1 "$rc"

# A relative path resolves against Claude Code's cwd, not the config dir, so it
# usually renders nothing — and the installer never writes one, so it is a hand
# edit, not a state to wave through.
repoint "$d" "bash statusline.sh"
CLAUDE_CONFIG_DIR="$d" bash "$INST" --check >/dev/null 2>&1; rc=$?
report "relative path" 1 "$rc"

# Registered at our path, but the file there was hand-replaced (no marker).
# Kept executable on purpose so only the settings verdict is in play, not the
# execute-bit check.
CLAUDE_CONFIG_DIR="$d" bash "$INST" >/dev/null 2>&1        # restore first
printf '#!/usr/bin/env bash\necho THEIRS\n' > "$d/statusline.sh"
chmod +x "$d/statusline.sh"
CLAUDE_CONFIG_DIR="$d" bash "$INST" --check >/dev/null 2>&1; rc=$?
report "our path, not our file" 1 "$rc"

echo
if [ "$fail" -ne 0 ]; then
    echo "check semantics: $fail of $((pass + fail)) FAILED" >&2
    exit 1
fi
echo "check semantics: all $pass checks passed"

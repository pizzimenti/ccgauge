#!/usr/bin/env bash
# Failure/success matrix for install.sh's three-phase ordering.
#
# Run:  bash tests/test_install_ordering.sh      (exit 0 = pass; no arguments)
#
# install.sh commits in three phases: back up and stage every replacement, then
# write settings.json, then rename the staged files into place. The invariant is
# that nothing a user can see changes unless everything can — a run that fails
# anywhere must leave the machine as it found it.
#
# That invariant is not visible to `bash -n`, and it is not visible to the
# installer's own --check either. It was established one review finding at a
# time, and each fix for it introduced the next problem: a probe that tested the
# wrong path, then one that followed a symlink and truncated an unrelated file,
# then an ordering that committed settings naming files it then failed to
# install. Every case below is one of those, kept so they cannot come back.
#
# Each case builds a throwaway config dir, records what must survive, runs the
# installer, and checks both the exit code and the artifact. Comparisons are on
# content, never on a byte count worked out by hand — an earlier version of this
# asserted 21 bytes for a 22-byte file and reported a false failure against a
# perfectly intact victim.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INST="$HERE/../install.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ccgauge-ordering.XXXXXX")"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

FOREIGN='#!/usr/bin/env bash
printf "USER OWN STATUS LINE"'

pass=0
fail=0

report() {  # label want_exit got_exit detail ok
    if [ "$2" = "$3" ] && [ "$5" = "ok" ]; then
        printf 'PASS  %-38s exit=%s  %s\n' "$1" "$3" "$4"
        pass=$((pass + 1))
    else
        printf 'FAIL  %-38s exit=%s (want %s)  %s\n' "$1" "$3" "$2" "$4"
        fail=$((fail + 1))
    fi
}

fresh() {  # dir -> config dir holding a foreign status line and valid settings
    rm -rf "$1"
    mkdir -p "$1/hooks"
    printf '%s\n' "$FOREIGN" > "$1/statusline.sh"
    printf '{\n  "hooks": {}\n}\n' > "$1/settings.json"
}

sum() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

# --- the happy path, and that it stays a no-op -------------------------------
d="$WORK/ordinary"; fresh "$d"
CLAUDE_CONFIG_DIR="$d" bash "$INST" >/dev/null 2>&1; rc=$?
[ "$(sum "$d/statusline.sh")" = "$(sum "$HERE/../statusline.sh")" ] && ok=ok || ok=no
report "ordinary install" 0 "$rc" "status line replaced" "$ok"

before=$(find "$d" -maxdepth 1 -name '*.bak' | wc -l)
CLAUDE_CONFIG_DIR="$d" bash "$INST" >/dev/null 2>&1; rc=$?
after=$(find "$d" -maxdepth 1 -name '*.bak' | wc -l)
[ "$before" = "$after" ] && ok=ok || ok=no
report "second run writes no new backups" 0 "$rc" "backups $before -> $after" "$ok"

# --- staging fails: settings must not have been committed --------------------
# A directory at statusline.sh makes the backup fail. Settings were previously
# written before this point, so the user's own registration was replaced with
# one naming a directory, and the run then exited 1 saying nothing was changed.
d="$WORK/dirdst"; fresh "$d"; rm -f "$d/statusline.sh"; mkdir -p "$d/statusline.sh"
python3 - "$d" <<'PY'
import json, sys
p = sys.argv[1] + "/settings.json"
cfg = json.load(open(p))
cfg["statusLine"] = {"type": "command", "command": "bash /home/me/mine.sh"}
json.dump(cfg, open(p, "w"), indent=2)
PY
CLAUDE_CONFIG_DIR="$d" bash "$INST" >/dev/null 2>&1; rc=$?
got=$(python3 -c "import json;print(json.load(open('$d/settings.json')).get('statusLine',{}).get('command'))")
[ "$got" = "bash /home/me/mine.sh" ] && ok=ok || ok=no
report "directory at statusline.sh" 1 "$rc" "registration kept" "$ok"

# --- the settings temp path must never be a lever on another file ------------
# The temp name used to be fixed and predictable. A symlink there had its target
# truncated; O_NOFOLLOW fixed that and left hard links, which share the inode.
# A random temp name closes both.
d="$WORK/symlink"; fresh "$d"
printf 'VICTIM SYMLINK TARGET\n' > "$WORK/vs.txt"; vsum=$(sum "$WORK/vs.txt")
ln -sfn "$WORK/vs.txt" "$d/settings.json.tmp"
CLAUDE_CONFIG_DIR="$d" bash "$INST" >/dev/null 2>&1; rc=$?
[ "$(sum "$WORK/vs.txt")" = "$vsum" ] && ok=ok || ok=no
report "symlink at settings temp path" 0 "$rc" "unrelated file intact" "$ok"

d="$WORK/hardlink"; fresh "$d"
printf 'VICTIM HARDLINK TARGET\n' > "$WORK/vh.txt"; hsum=$(sum "$WORK/vh.txt")
ln "$WORK/vh.txt" "$d/settings.json.tmp"
CLAUDE_CONFIG_DIR="$d" bash "$INST" >/dev/null 2>&1; rc=$?
[ "$(sum "$WORK/vh.txt")" = "$hsum" ] && ok=ok || ok=no
report "hard link at settings temp path" 0 "$rc" "unrelated file intact" "$ok"

# --- shapes the writer rejects must be rejected before anything is copied ----
for j in '[]' '{"hooks": 5}' '{"hooks": {"UserPromptSubmit": 5}}'; do
    d="$WORK/shape"; fresh "$d"; printf '%s\n' "$j" > "$d/settings.json"
    sl=$(sum "$d/statusline.sh")
    CLAUDE_CONFIG_DIR="$d" bash "$INST" >/dev/null 2>&1; rc=$?
    [ "$(sum "$d/statusline.sh")" = "$sl" ] && ok=ok || ok=no
    report "settings shape $j" 1 "$rc" "status line kept" "$ok"
done

# --- a read-only settings target ---------------------------------------------
# Failing is right when a write is needed and impossible; failing when NO write
# is needed blocks an update that would have worked, which a preflight probe
# used to do.
d="$WORK/ro"; fresh "$d"; ro="$WORK/ro-target"
mkdir -p "$ro"; printf '{\n  "hooks": {}\n}\n' > "$ro/settings.json"
rm -f "$d/settings.json"; ln -sfn "$ro/settings.json" "$d/settings.json"
sl=$(sum "$d/statusline.sh")
chmod 555 "$ro"
CLAUDE_CONFIG_DIR="$d" bash "$INST" >/dev/null 2>&1; rc=$?
[ "$(sum "$d/statusline.sh")" = "$sl" ] && ok=ok || ok=no
report "read-only target, write needed" 1 "$rc" "status line kept" "$ok"

chmod 755 "$ro"
CLAUDE_CONFIG_DIR="$d" bash "$INST" >/dev/null 2>&1     # prime: settings now correct
chmod 555 "$ro"
CLAUDE_CONFIG_DIR="$d" bash "$INST" >/dev/null 2>&1; rc=$?
report "read-only target, no write needed" 0 "$rc" "install proceeds" ok
chmod 755 "$ro"

echo
if [ "$fail" -ne 0 ]; then
    echo "install ordering: $fail of $((pass + fail)) FAILED" >&2
    exit 1
fi
echo "install ordering: all $pass checks passed"

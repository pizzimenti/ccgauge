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
#   ./install.sh              install (or update) and verify
#   ./install.sh --statusline install, taking over an existing status line
#   ./install.sh --check      verify an existing install; makes no network call
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
TAKE_STATUSLINE=0
for arg in "$@"; do
  case "$arg" in
    --check)      CHECK_ONLY=1 ;;
    --statusline) TAKE_STATUSLINE=1 ;;
    --help|-h)
      # Print the header block, stopping before `set -euo pipefail`.
      sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
      exit 0 ;;
    *) echo "ccgauge: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
  esac
done

# Shared by every python step below via exec(). Defined once on purpose: this
# predicate decides both what gets *written* to settings.json and what gets
# *recognised* there, and an earlier revision that spelled it separately in each
# place drifted — the writer quoted the path while the verifier compared it raw,
# so a correct install reported itself broken.
PY_PRELUDE='
import os, shlex

def refers_to(cmd, target):
    """Does this command string invoke `target`, however it was quoted?

    Also matches the whole string against the target, which is how ccgauge
    <= 0.7.0 wrote the hook: unquoted. In a config dir containing a space,
    shlex.split shreds that legacy value into words resolving to nothing, so an
    upgrade would not recognise its own previous registration and would append a
    second one — the duplicate this exists to prevent.
    """
    cmd = cmd or ""
    rt = os.path.realpath(target)
    if cmd and os.path.realpath(cmd) == rt:
        return True
    try:
        words = shlex.split(cmd)
    except ValueError:
        words = cmd.split()
    return any(os.path.realpath(w) == rt for w in words if w)
'
export PY_PRELUDE

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

# Platform. ccgauge reads the OAuth token straight off disk, and Claude Code only
# keeps it there on Linux and Windows — on macOS it lives in the Keychain, so
# there is no file for us to read and no amount of logging in will create one.
# Say so plainly here rather than letting the credentials check further down
# report a missing file and send you off to re-authenticate for nothing.
PLATFORM="$(uname -s 2>/dev/null || echo unknown)"
case "$PLATFORM" in
  Linux)  ok "platform: Linux" ;;
  Darwin)
    # Exit here, before touching anything. `fail` only increments a counter that
    # is read at the very end, so using it would install all three files and
    # replace the user's status line on a platform we have just declared
    # unsupported — leaving behind a gauge that can never populate.
    fail "platform: macOS — not supported"
    printf '        Claude Code stores its OAuth token in the macOS Keychain, not in\n'
    printf '        %s/.credentials.json, so ccgauge cannot read it.\n' "$CONFIG_DIR"
    printf '        Reading the Keychain is not implemented.\n\n'
    printf '\033[0;31mccgauge: nothing was installed or changed.\033[0m\n' >&2
    exit 1
    ;;
  MINGW*|MSYS*|CYGWIN*)
    ok "platform: Windows (Git Bash)"
    warn "Claude Code runs hooks and the status line through Git Bash when it is"
    warn "installed and PowerShell when it is not — these are bash scripts, so keep"
    warn "Git for Windows installed or they will not run"
    ;;
  *) warn "platform: $PLATFORM — untested; ccgauge is developed on Linux" ;;
esac

# --------------------------------------------------------------------------- #
# install
# --------------------------------------------------------------------------- #
if [ "$CHECK_ONLY" -eq 0 ]; then
  echo
  echo "ccgauge: installing into $CONFIG_DIR"
  mkdir -p "$CONFIG_DIR/hooks"

  # Back up anything at a destination that differs from what we are about to
  # write. No content marker: an earlier version keyed on "does the file contain
  # ccgauge's header comment", which reads a *customised copy of our own script*
  # as already-ours and overwrites the customisation with no backup at all — and
  # the README invites exactly that by calling statusline.sh a working reference.
  # Differing content is the only honest test.
  #
  # $CONFIG_DIR/statusline.sh matters most: that name is not ours, it is where
  # Claude Code's own /statusline command writes.
  backup_if_differs() {
    [ -e "$1" ] || return 0
    cmp -s "$2" "$1" && return 0
    b="$1.$(date +%Y%m%d-%H%M%S).bak"
    n=1
    while [ -e "$b" ]; do n=$((n + 1)); b="$1.$(date +%Y%m%d-%H%M%S)-$n.bak"; done
    cp -pL "$1" "$b" 2>/dev/null || cp -p "$1" "$b"
    warn "existing $(basename "$1") differs — backed it up to $(basename "$b")"
  }
  backup_if_differs "$STATUSLINE_DST" "$HERE/statusline.sh"
  backup_if_differs "$HOOK_DST"       "$HERE/hooks/usage-line.sh"
  backup_if_differs "$USAGE_DST"      "$HERE/usage.py"

  # Remove the destination before copying. `cp` follows a symlink and rewrites
  # its *target* in place, so installing over a $CONFIG_DIR/statusline.sh that
  # points into a dotfiles repo would silently overwrite the tracked file there
  # — the same symlink hazard the settings.json write was hardened against, in
  # the opposite and more destructive direction.
  install_file() { rm -f "$2"; cp "$1" "$2"; chmod +x "$2"; }
  install_file "$HERE/usage.py"           "$USAGE_DST"
  install_file "$HERE/hooks/usage-line.sh" "$HOOK_DST"
  install_file "$HERE/statusline.sh"      "$STATUSLINE_DST"
  ok "copied usage.py, hooks/usage-line.sh, statusline.sh"

  if [ ! -f "$SETTINGS" ]; then
    # `-f` is false for a dangling symlink too, and the redirect would then fail
    # under `set -e` with a bare shell error and no failure summary — after the
    # three files have already been copied, leaving a half-install.
    if [ -L "$SETTINGS" ]; then
      fail "settings.json is a symlink to a missing target:"
      printf '        %s -> %s\n' "$SETTINGS" "$(readlink "$SETTINGS")"
      printf '        create the target (or remove the link) and re-run.\n'
      echo
      printf '\033[0;31mccgauge: settings.json was not modified.\033[0m\n' >&2
      exit 1
    fi
    if ! printf '{\n  "hooks": {}\n}\n' > "$SETTINGS" 2>/dev/null; then
      fail "could not create $SETTINGS (is $CONFIG_DIR writable?)"
      echo
      printf '\033[0;31mccgauge: settings.json was not modified.\033[0m\n' >&2
      exit 1
    fi
    ok "created $SETTINGS"
  fi

  # Register the UserPromptSubmit hook and the status line, backing up first.
  #
  # The backup is timestamped and is written ONLY on a run that actually changes
  # something. A single fixed settings.json.bak overwritten every run is a trap:
  # install, notice your status line changed, re-run the installer while working
  # out how to undo it, and the second run's backup — now identical to the
  # modified file — has destroyed the only copy of your original. Nothing here
  # ever overwrites an existing backup, and a no-op run leaves no litter.
  HOOK_PATH="$HOOK_DST" STATUSLINE_PATH="$STATUSLINE_DST" \
  TAKE_STATUSLINE="$TAKE_STATUSLINE" \
  python3 - "$SETTINGS" <<'PY' || settings_write_failed=1
import datetime, json, os, shlex, shutil, sys

G, Y, R, X = "\033[0;32m", "\033[0;33m", "\033[0;31m", "\033[0m"
# Resolve first. The atomic write replaces a *directory entry*, so a symlinked
# settings.json — one pointed at a dotfiles repo, say — would be severed and
# replaced by a regular file, with the edits landing there and the real target
# never updated at all. Writing to the resolved target keeps the link intact.
path = os.path.realpath(sys.argv[1])

# Both values are *shell command strings*, so both get quoted. Quoting only the
# status line (as an earlier revision did) leaves a config dir containing a
# space producing a hook command the shell splits in half — and the hook then
# never fires, silently.
hook_path = os.environ["HOOK_PATH"]
sl_path = os.environ["STATUSLINE_PATH"]
hook_cmd = shlex.quote(hook_path)
statusline_cmd = "bash " + shlex.quote(sl_path)
take_statusline = os.environ.get("TAKE_STATUSLINE") == "1"

try:
    with open(path) as fh:
        original = fh.read()
    cfg = json.loads(original)
    if not isinstance(cfg, dict):
        raise ValueError("top level is not a JSON object")
except Exception as exc:
    # Without this, an unparseable settings.json aborts the whole installer
    # under `set -e` with a raw traceback, before the verification phase that
    # would have explained it.
    print(f"  {R}FAIL{X}  could not read settings.json: {exc}")
    print(f"        fix it, or restore the newest {path}.*.bak")
    sys.exit(1)


exec(os.environ["PY_PRELUDE"])   # refers_to() — single definition, see the top


hooks = cfg.setdefault("hooks", {})
if not isinstance(hooks, dict):
    print(f"  {R}FAIL{X}  settings.json 'hooks' is not an object")
    sys.exit(1)
# setdefault returns whatever is already there, so a non-list UserPromptSubmit
# would sail past the guard above and reach .append() — producing exactly the
# raw traceback the defensive parsing exists to prevent, after the three files
# have already been copied.
groups = hooks.setdefault("UserPromptSubmit", [])
if not isinstance(groups, list):
    print(f"  {R}FAIL{X}  settings.json hooks.UserPromptSubmit is not a list")
    print( "        fix it by hand, or restore a settings.json.*.bak")
    sys.exit(1)

# Compare by resolved path, not by exact string: a trailing slash or a symlink
# in CLAUDE_CONFIG_DIR spells the same hook differently and would otherwise
# append a *second* live registration, firing the hook twice per turn.
def group_hooks(g):
    """A group's hook list, or None if it is not a list we should touch.

    `hooks` is only iterated when it really is a list. Iterating a string
    rewrites it as a list of its characters, and a dict as a list of its keys —
    silently destroying a hand-edited entry and writing the wreckage back as the
    new truth.
    """
    h = g.get("hooks") if isinstance(g, dict) else None
    return h if isinstance(h, list) else None


existing = [h for g in groups
            for h in (group_hooks(g) or []) if isinstance(h, dict)
            and refers_to(h.get("command"), hook_path)]
if len(existing) > 1:
    print(f"  {Y}warn{X}  {len(existing)} duplicate hook registrations found — pruning to one")
    # Keep the FIRST of our registrations rather than deleting them all and
    # appending a fresh bare group: the existing entry may carry keys we do not
    # know about (a timeout, whatever Claude Code adds next), and its group may
    # carry a matcher. Re-creating it drops all of that.
    seen = False
    kept = []
    for g in groups:
        hs = group_hooks(g)
        if hs is None:
            kept.append(g)          # not a shape we understand; leave it be
            continue
        after = []
        for h in hs:
            if isinstance(h, dict) and refers_to(h.get("command"), hook_path):
                if seen:
                    continue        # a duplicate; drop this one
                seen = True
            after.append(h)
        # Drop a group only if *we* emptied it. A group the user left empty — a
        # matcher-scoped placeholder, say — is theirs.
        if after or not hs:
            g["hooks"] = after
            kept.append(g)
    groups[:] = kept
    existing = [True] if seen else []
if existing:
    print(f"  {G}ok{X}    UserPromptSubmit hook already registered")
else:
    groups.append({"hooks": [{"type": "command", "command": hook_cmd}]})
    print(f"  {G}ok{X}    registered UserPromptSubmit hook")

# The status line is only taken over when it is absent, already ours, or the
# user explicitly asked. Replacing a foreign one by default means the documented
# "keep your own" setup cannot survive the documented `git pull && ./install.sh`
# update — every update would silently clobber it again.
sl_raw = cfg.get("statusLine")
sl = sl_raw if isinstance(sl_raw, dict) else None
current = (sl or {}).get("command")
if sl_raw is not None and sl is None:
    # A statusLine that is not an object is still the user's configuration.
    # Coercing it to None makes the "leave a foreign one alone" branch
    # unreachable and replaces it with no warning and no --statusline.
    current = json.dumps(sl_raw)
if current and sl is not None and refers_to(current, sl_path):
    print(f"  {G}ok{X}    status line already registered")
elif current and not take_statusline:
    print(f"  {Y}warn{X}  leaving your existing status line alone:")
    print(f"          {current}")
    print( "          add ccgauge to it yourself (see the README), or take it over with:")
    print( "              ./install.sh --statusline")
else:
    replacing = current
    # Set only the keys we own, so any sibling key in an existing statusLine
    # block (padding, refreshInterval, whatever Claude Code adds next) survives.
    block = sl if sl is not None else {}
    block["type"] = "command"
    block["command"] = statusline_cmd
    cfg["statusLine"] = block
    print(f"  {G}ok{X}    registered status line")

updated = json.dumps(cfg, indent=2) + "\n"
if updated == original:
    print(f"  {G}ok{X}    settings.json already correct — not rewritten")
    sys.exit(0)

# Never overwrite an existing backup, even one made in the same second: the
# timestamp has one-second resolution, and two runs inside one second (a script,
# a fast retry) would otherwise have the second copy clobber the first — exactly
# the data loss the timestamping exists to prevent.
stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
backup = f"{path}.{stamp}.bak"
n = 1
while os.path.exists(backup):
    n += 1
    backup = f"{path}.{stamp}-{n}.bak"
try:
    shutil.copy2(path, backup)
except Exception as exc:
    print(f"  {R}FAIL{X}  could not write a backup ({exc}) — refusing to modify settings.json")
    sys.exit(1)
# Print the full path, not just the basename. `path` was realpath'd, so when
# settings.json is a symlink the backup lands beside the *target* — a message
# saying "beside it" would point at a directory that has no backup in it.
print(f"  {G}ok{X}    backed up settings.json -> {backup}")
if 'replacing' in dir() and replacing:
    print(f"  {Y}warn{X}  replaced your existing status line:")
    print(f"          {replacing}")
    print(f"          restore it from {backup}")

# Write via a temp file in the same directory, then rename: an interrupted write
# must not leave a truncated settings.json, which Claude Code would refuse.
#
# The replacement takes the *new* file's default permissions, not the original's,
# so a settings.json deliberately restricted to 0600 would silently widen to
# whatever the umask allows — a file that holds hook commands and can hold
# tokens. Carry the mode across explicitly.
tmp = path + ".tmp"
try:
    mode = os.stat(path).st_mode & 0o7777
except OSError:
    mode = None
with open(tmp, "w") as fh:
    fh.write(updated)
if mode is not None:
    try:
        os.chmod(tmp, mode)
    except OSError:
        pass
os.replace(tmp, path)
PY
  if [ "${settings_write_failed:-0}" -eq 1 ]; then
    echo
    printf '\033[0;31mccgauge: could not update settings.json — see above.\033[0m\n' >&2
    exit 1
  fi
fi

# --------------------------------------------------------------------------- #
# verify — this is the part that makes a broken install say so
# --------------------------------------------------------------------------- #
echo
echo "ccgauge: verifying"

for f in "$USAGE_DST" "$HOOK_DST" "$STATUSLINE_DST"; do
  if [ -x "$f" ]; then ok "present and executable: ${f#"$CONFIG_DIR"/}"
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
#
# Which modes get exercised depends on the mode we are in, because two of them
# touch the network. `show` always forces a refresh past the cache TTL, and
# `refresh` fetches whenever the cache is cold — and the endpoint 429s hard when
# polled too fast, so an installer that ran them per-step would trip the exact
# rate limit the tool exists to respect. `--check` is meant to be safe to run
# repeatedly while diagnosing a problem, including a rate-limit problem, so it
# runs neither: firing a request to diagnose a lockout is how you extend one.
# `refresh` is not here either: on a cold cache it fetches, and `show` further
# down forces a second fetch seconds later. It is exercised *after* that, when
# the cache is warm and it self-throttles to a no-op.
for mode in status log; do
  if python3 "$USAGE_DST" "$mode" > /dev/null 2>&1 < /dev/null; then
    ok "usage.py $mode exits cleanly"
  else
    fail "usage.py $mode exited non-zero — it must never disrupt a hook"
  fi
done

# One pass over settings.json: prints its own findings and exits non-zero on the
# conditions that mean the install is incomplete, so the shell can fold that into
# the failure count. A status line pointing somewhere *else* is a warning rather
# than a failure — the README documents keeping your own — but no status line at
# all means half of ccgauge has nowhere to render.
settings_report=$(
  SETTINGS="$SETTINGS" HOOK_DST="$HOOK_DST" STATUSLINE_DST="$STATUSLINE_DST" \
  python3 <<'PY'
import json, os, shlex, sys

G, Y, R, X = "\033[0;32m", "\033[0;33m", "\033[0;31m", "\033[0m"
try:
    cfg = json.load(open(os.environ["SETTINGS"]))
except Exception as exc:
    print(f"  {R}FAIL{X}  settings.json is not valid JSON ({exc})")
    print("        restore it from the newest settings.json.*.bak beside it")
    sys.exit(1)
print(f"  {G}ok{X}    settings.json is valid JSON")

hook, sl = os.environ["HOOK_DST"], os.environ["STATUSLINE_DST"]


exec(os.environ["PY_PRELUDE"])   # refers_to() — single definition, see the top


groups = (cfg.get("hooks") or {}).get("UserPromptSubmit") or []
matches = [h for g in groups if isinstance(g, dict)
           for h in g.get("hooks", []) if isinstance(h, dict)
           and refers_to(h.get("command"), hook)]
registered = bool(matches)
if len(matches) > 1:
    print(f"  {Y}warn{X}  hook is registered {len(matches)} times — it will fire "
          f"{len(matches)}x per turn")
    print( "        re-run ./install.sh (without --check) to prune the duplicates")
print(f"  {G}ok{X}    UserPromptSubmit hook is registered" if registered
      else f"  {R}FAIL{X}  UserPromptSubmit hook is NOT registered")

cmd = (cfg.get("statusLine") or {}).get("command") or ""
ours = refers_to(cmd, sl)
if ours:
    print(f"  {G}ok{X}    status line is registered")
elif cmd:
    print(f"  {Y}warn{X}  status line points elsewhere: {cmd}")
    print( "        (fine if that is deliberate — see the README)")
else:
    print(f"  {R}FAIL{X}  no status line configured — the gauges have nowhere to render")
    print( "        re-run ./install.sh without --check")

sys.exit(0 if registered and (ours or cmd) else 1)
PY
) && settings_ok=1 || settings_ok=0
printf '%s\n' "$settings_report"
[ "$settings_ok" -eq 1 ] || \
  fail "settings.json is unreadable, or is missing the hook or the status line"

# Do the one forced refresh HERE, before the render checks, and report it further
# down. Ordering matters for the request count: the hook runs `usage.py line`,
# which does its own synchronous fetch when the cache is cold. Warming the cache
# first means that call finds fresh data and makes no request of its own, so a
# whole install costs exactly one — against an endpoint that 429s hard when
# polled too fast, "exactly one" is worth some awkward sequencing.
show_out=""
if [ "$CHECK_ONLY" -eq 0 ] && [ -r "$CONFIG_DIR/.credentials.json" ]; then
  show_out=$(python3 "$USAGE_DST" show 2>/dev/null || true)
fi

# The hook and the status line must both produce output for a realistic payload.
#
# Built with json.dumps rather than string splicing: a repo path containing a
# quote or backslash would otherwise produce invalid JSON that both parsers
# silently swallow, leaving these checks passing while testing nothing.
SAMPLE=$(PWD_VAL="$PWD" python3 -c '
import json, os
print(json.dumps({"workspace": {"current_dir": os.environ["PWD_VAL"]},
                  "model": {"display_name": "install-check"},
                  "context_window": {"used_percentage": 31.4},
                  "session_id": "install-check"}))')

# Run the scripts the way Claude Code will: through the *command string* stored
# in settings.json, not by invoking the path directly with the shell doing the
# quoting for us. Invoking directly is what let an unquoted, word-splittable
# hook command pass verification while being unusable in practice.
#
# CCGAUGE_USAGE_PY is cleared so these exercise the usage.py we just installed
# rather than whatever an ambient environment points at.
# Select *ccgauge's own* entries, not simply the first one present. Picking the
# first UserPromptSubmit hook runs a stranger's script and then fails it for not
# printing [usage]; taking the statusLine unconditionally runs the status line we
# just deliberately preserved and fails it for not drawing our glyphs. Both
# declare a correct install broken.
hook_cmd_stored=$(SETTINGS="$SETTINGS" TARGET="$HOOK_DST" python3 -c '
import json, os
exec(os.environ["PY_PRELUDE"])
cfg = json.load(open(os.environ["SETTINGS"]))
groups = (cfg.get("hooks") or {}).get("UserPromptSubmit") or []
if not isinstance(groups, list):
    groups = []
target = os.environ["TARGET"]
print(next((h.get("command", "") for g in groups if isinstance(g, dict)
            for h in g.get("hooks", []) if isinstance(h, dict)
            and refers_to(h.get("command"), target)), ""))' 2>/dev/null || echo "")

# Empty unless the configured status line is ours; a preserved foreign one is
# reported as skipped rather than executed and judged by our criteria.
sl_cmd_stored=$(SETTINGS="$SETTINGS" TARGET="$STATUSLINE_DST" python3 -c '
import json, os
exec(os.environ["PY_PRELUDE"])
cfg = json.load(open(os.environ["SETTINGS"]))
sl = cfg.get("statusLine")
cmd = (sl.get("command") or "") if isinstance(sl, dict) else ""
print(cmd if refers_to(cmd, os.environ["TARGET"]) else "")' 2>/dev/null || echo "")

hook_err=$(mktemp); sl_err=$(mktemp)
trap 'rm -f "$hook_err" "$sl_err"' EXIT

if [ -z "$hook_cmd_stored" ]; then
  fail "no hook command in settings.json to exercise"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  # Running the hook is not a read-only act: it logs a prompt event and detaches
  # a background refresh that can hit the endpoint. --check has to stay safe to
  # run repeatedly while diagnosing a rate-limit problem, so it stops at "the
  # hook is present, executable and registered".
  ok "hook registered (not executed — --check makes no network call)"
elif hook_out=$(printf '%s' "$SAMPLE" | env -u CCGAUGE_USAGE_PY sh -c "$hook_cmd_stored" 2>"$hook_err") \
     && printf '%s' "$hook_out" | grep -q '\[usage\]'; then
  ok "hook produces a context line"
else
  fail "hook did not produce a [usage] line — run: echo '{}' | sh -c $hook_cmd_stored"
  [ -s "$hook_err" ] && printf '        %s\n' "$(head -2 "$hook_err")"
fi

# Assert on ccgauge's own glyphs, not merely on non-emptiness: statusline.sh
# always emits ANSI escapes, so "is the output non-empty" can never fail, and
# folding stderr in would make an error message look like a successful render.
if [ -z "$sl_cmd_stored" ]; then
  # Either nothing is configured (already FAILed by the settings check above) or
  # the user's own status line is configured and we left it alone on purpose.
  # Judging theirs by whether it draws ccgauge's glyphs would fail a setup the
  # README explicitly supports.
  ok "status line is not ccgauge's — not exercised"
elif ! sl_out=$(printf '%s' "$SAMPLE" | env -u CCGAUGE_USAGE_PY sh -c "$sl_cmd_stored" 2>"$sl_err"); then
  fail "status line failed to run — try: echo '{}' | sh -c $sl_cmd_stored"
  [ -s "$sl_err" ] && printf '        %s\n' "$(head -2 "$sl_err")"
# Assert on ccgauge's OWN fragment, not merely on a bar glyph. The sample payload
# carries a context-window percentage, so statusline.sh draws a `ctx` bar from it
# with no cache involved — a bare `grep '[█░]'` is satisfied by that alone and
# passes while the 5h/7d gauges render nothing whatsoever.
#
# Matched against escape-stripped output: the gauges are colourised, so `5h` and
# its bracket are separated by an SGR sequence in the raw text and a literal
# "5h [" never matches — which would fail a perfectly good install.
elif printf '%s' "$sl_out" | sed 's/\x1b\[[0-9;]*m//g' | grep -qE '(5h|7d) \['; then
  ok "status line renders the usage gauges"
  printf '        %s\n' "$(printf '%b' "$sl_out" | tail -1)"
elif ! python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)                                     # absent or unreadable
sys.exit(0 if isinstance(d, dict) and (d.get("five_hour_pct") is not None
                                       or d.get("seven_day_pct") is not None)
         else 1)' "$CONFIG_DIR/usage-cache.json" 2>/dev/null; then
  # Ask whether the cache holds *renderable data*, not merely whether the file
  # exists. Existence is the wrong proxy: an empty or truncated cache turns a
  # perfectly healthy install into a hard FAIL, because the gauges are correctly
  # absent and the check reads that as breakage.
  warn "status line runs, but there is no usable usage data cached yet"
  warn "re-check after a turn or two with: ./install.sh --check"
else
  fail "status line ran but drew no 5h/7d gauge despite usable cached data"
  printf '        %s\n' "$(printf '%b' "$sl_out" | tail -1)"
fi

# Credentials and the endpoint are best-effort: no network in a container, or a
# logged-out CLI, is not a broken install. Report, don't fail.
if [ ! -r "$CONFIG_DIR/.credentials.json" ]; then
  warn "no $CONFIG_DIR/.credentials.json — log in with the claude CLI, then re-run"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  ok "OAuth credentials readable"
  # --check makes no network call at all, so report the cache rather than fetch.
  cache_age=$(CACHE="$CONFIG_DIR/usage-cache.json" python3 -c '
import os, time
try:
    print(int(time.time() - os.path.getmtime(os.environ["CACHE"])))
except Exception:
    print(-1)' 2>/dev/null || echo -1)
  if [ "$cache_age" -lt 0 ]; then
    warn "no usage cache yet — run ./install.sh (without --check) or wait a turn"
  else
    ok "usage cache present (${cache_age}s old)"
  fi
else
  ok "OAuth credentials readable"
  # $show_out was captured before the render checks — see the note there. One
  # forced refresh per run, its output reused for both the verdict and display.
  # `show` prints the cached percentages *and* a "NOT live" note when the forced
  # refresh could not land, so grepping for '%' would call an active 429
  # cooldown "endpoint reachable". Ask the question the other way round.
  if printf '%s' "$show_out" | grep -q 'NOT live'; then
    warn "endpoint did NOT respond — the numbers below are cached, not live"
    printf '%s\n' "$show_out" | sed 's/^/        /'
  elif printf '%s' "$show_out" | grep -q '%'; then
    ok "endpoint reachable — live numbers below"
    printf '%s\n' "$show_out" | sed 's/^/        /'
  else
    warn "could not read live usage yet (endpoint, rate limit, or token refresh)"
    warn "this is normal right after install; check again with: ./install.sh --check"
  fi
  # Now that `show` has populated the cache, `refresh` self-throttles to a no-op,
  # so its never-raise contract can be checked without a second request.
  if python3 "$USAGE_DST" refresh > /dev/null 2>&1 < /dev/null; then
    ok "usage.py refresh exits cleanly"
  else
    fail "usage.py refresh exited non-zero — it must never disrupt a hook"
  fi
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

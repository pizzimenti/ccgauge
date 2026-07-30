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

# Is the file at $STATUSLINE_DST ccgauge's own copy, or a status line the user
# wrote that happens to live at that path? Claude Code's /statusline command
# writes there too, so the path settles nothing and the answer is needed twice:
# to decide whether the installer may overwrite the file, and to decide whether
# verification may run it and judge it by whether it draws ccgauge's gauges.
# Getting the second one wrong declares a perfectly good install broken.
#
# The second pattern recognises copies from versions that shipped before the
# marker existed, so an update still lands on an install that predates it.
statusline_is_ours() {
  [ -e "$STATUSLINE_DST" ] || return 1
  grep -qF -e 'ccgauge-statusline-marker' \
           -e "ccgauge's status line for Claude Code" \
           "$STATUSLINE_DST" 2>/dev/null
}

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


def _words(cmd):
    """Split a command string the way a shell would, never raising."""
    try:
        return shlex.split(cmd)
    except ValueError:
        return cmd.split()


def _resolves_to(word, rt):
    """Does this single word name `rt` (already resolved)?

    Absolute paths only. A relative word resolves against the working directory
    of whichever process asks — for the installer that is wherever it happened
    to be launched, but Claude Code runs hook and status-line commands from the
    project directory, where the same word names something else or nothing at
    all. Matching one reports a registration as ours and verifies it green while
    it is unrunnable in practice.
    """
    return bool(word) and os.path.isabs(word) and os.path.realpath(word) == rt


def invokes_solely(cmd, target):
    """Is `cmd` nothing but an invocation of `target`?

    This is the delete/rewrite criterion, and it is deliberately stricter than
    refers_to. That looseness below is right for "is ccgauge registered here"
    and wrong for "may I remove this": a command like
    `audit.sh --watch .../usage-line.sh` refers to us without being ours, and
    counting it as a duplicate deletes a hook we never owned.
    """
    if not isinstance(cmd, str) or not cmd.strip():
        return False
    rt = os.path.realpath(target)
    if _resolves_to(cmd.strip(), rt):
        return True                  # the whole string is the path (<= 0.7.0)
    words = _words(cmd)
    return len(words) == 1 and _resolves_to(words[0], rt)


def is_hook_command(cmd, hook_path, usage_py):
    """Recognise either installer spelling of the UserPromptSubmit hook.

    install.sh registers hooks/usage-line.sh; install.ps1 registers
    `python "<usage.py>" hookline`. One machine can see both — Git Bash is a
    platform install.sh supports and install.ps1 targets the same config dir —
    and a registration written by the other installer has to be recognised
    rather than appended alongside. Two live registrations fire the hook twice
    a turn, injecting two [usage] blocks and doubling the requests against an
    endpoint that rate-limits hard.

    The usage.py spelling requires the mode as the very next token, which is the
    shape install.ps1 matches too, so a command that merely mentions usage.py
    somewhere is never claimed.
    """
    if refers_to(cmd, hook_path):
        return True
    if not isinstance(cmd, str) or not usage_py:
        return False
    words = _words(cmd)
    rt = os.path.realpath(usage_py)
    return any(_resolves_to(w, rt) and words[i + 1] in ("hookline", "line")
               for i, w in enumerate(words[:-1]))


def invokes_hook_solely(cmd, hook_path, usage_py):
    """The prune criterion, spanning both installer spellings.

    Either the bare usage-line.sh path, or an interpreter running usage.py in
    its hook mode and nothing else. Requiring the leading word to be a python
    and everything before the script to be a flag keeps a user wrapper that
    chains our hook out of the deletion set.
    """
    if invokes_solely(cmd, hook_path):
        return True
    if not isinstance(cmd, str) or not usage_py:
        return False
    words = _words(cmd)
    if len(words) < 3 or words[-1] not in ("hookline", "line"):
        return False
    head = os.path.basename(words[0]).lower()
    if not (head.startswith("python") or head.startswith("py.") or head == "py"):
        return False
    if any(not w.startswith("-") for w in words[1:-2]):
        return False
    return _resolves_to(words[-2], os.path.realpath(usage_py))


def script_target(cmd):
    """The script path a command runs, if it names one.

    Used only to report on a registration, never to claim it.
    """
    if not isinstance(cmd, str):
        return ""
    for w in _words(cmd):
        if w.endswith(".sh") or w.endswith(".py"):
            return w
    return ""


def refers_to(cmd, target):
    """Does this command string invoke `target`, however it was quoted?

    Also matches the whole string against the target, which is how ccgauge
    <= 0.7.0 wrote the hook: unquoted. In a config dir containing a space,
    shlex.split shreds that legacy value into words resolving to nothing, so an
    upgrade would not recognise its own previous registration and would append a
    second one — the duplicate this exists to prevent. Callers that care whether
    the stored spelling is the *canonical* one compare against it directly.

    Anything that is not a string is simply not a match. settings.json is
    hand-editable, so `command` can be a list, a number, or an object, and
    os.path.realpath raises TypeError on all of them — crashing the writer with
    a raw traceback after the files have already been copied.
    """
    if not isinstance(cmd, str) or not cmd.strip():
        return False
    rt = os.path.realpath(target)
    if _resolves_to(cmd.strip(), rt):
        return True
    return any(_resolves_to(w, rt) for w in _words(cmd))


def dget(obj, key, default=None):
    """`obj[key]` when obj is a dict, else `default`.

    settings.json is hand-editable and every value in it is untrusted. Chained
    `(cfg.get("x") or {}).get("y")` reads look safe but raise AttributeError the
    moment "x" is a string or a list — which is exactly the shape the writer
    goes out of its way to preserve, so the two halves disagree and a correct
    install reports itself broken with a traceback.
    """
    return obj.get(key, default) if isinstance(obj, dict) else default
'
export PY_PRELUDE

# One EXIT trap for the whole script. A second `trap ... EXIT` silently replaces
# the first rather than adding to it, so anything needing cleanup appends here.
#
# An array, not a string. Iterating an unquoted string splits on whitespace, and
# CLAUDE_CONFIG_DIR containing a space is a case this installer explicitly
# supports — so the paths queued here contain spaces, and the split fragments
# would be passed to `rm -f`, deleting something that was never queued. The
# length guard keeps `set -u` happy on bash < 4.4, where expanding an empty
# array is an unbound-variable error.
CLEANUP=()
trap '[ ${#CLEANUP[@]} -eq 0 ] || rm -f "${CLEANUP[@]}"' EXIT

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
  # Guarded like every other write below. Unguarded, an uncreatable config dir
  # (read-only parent, a bad mount, a typo under a root-owned path) aborts the
  # run under `set -e` with a bare `mkdir:` line — no FAIL, no failure count, no
  # "nothing was installed" summary.
  if ! mkdir -p "$CONFIG_DIR/hooks" 2>/dev/null; then
    fail "could not create $CONFIG_DIR/hooks"
    printf '        check that %s is writable, or set CLAUDE_CONFIG_DIR.\n' "$CONFIG_DIR"
    echo
    printf '\033[0;31mccgauge: nothing was installed or changed.\033[0m\n' >&2
    exit 1
  fi

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
    local dst="$1" src="$2" b stamp n
    [ -e "$dst" ] || return 0
    cmp -s "$src" "$dst" && return 0
    stamp="$(date +%Y%m%d-%H%M%S)"
    b="$dst.$stamp.bak"
    n=1
    while [ -e "$b" ]; do n=$((n + 1)); b="$dst.$stamp-$n.bak"; done
    # A backup we could not write must stop the install, not be shrugged off:
    # the very next step overwrites this file, and proceeding would destroy the
    # only copy. Reported as a FAIL rather than left to `set -e`, which would
    # abort with a bare `cp:` line, no diagnostic and no summary.
    if ! { cp -pL "$dst" "$b" 2>/dev/null || cp -p "$dst" "$b" 2>/dev/null; }; then
      fail "could not back up $dst — refusing to overwrite it"
      return 1
    fi
    warn "existing $(basename "$dst") differs — backed it up to $(basename "$b")"
  }
  # Decide whether statusline.sh may be written at all, BEFORE anything touches
  # it. That path is not a name ccgauge owns — it is exactly where Claude Code's
  # own /statusline command writes — so being there proves nothing about who put
  # it there. Writing it unconditionally makes --statusline meaningless for
  # everyone whose status line sits at the default path, and re-clobbers it on
  # every documented `git pull && ./install.sh`.
  #
  # The marker decides *whether to write*, never whether to back up: backups stay
  # keyed on differing content, which is the honest test and the reason keying
  # the backup on a marker was wrong. The second pattern recognises copies from
  # ccgauge versions that shipped before the marker existed, so an update still
  # lands on an install that predates it.
  install_statusline=1
  if [ -e "$STATUSLINE_DST" ] && [ "$TAKE_STATUSLINE" -eq 0 ] && ! statusline_is_ours; then
    install_statusline=0
  fi

  backed_up=1
  if [ "$install_statusline" -eq 1 ]; then
    backup_if_differs "$STATUSLINE_DST" "$HERE/statusline.sh" || backed_up=0
  fi
  backup_if_differs "$HOOK_DST"       "$HERE/hooks/usage-line.sh" || backed_up=0
  backup_if_differs "$USAGE_DST"      "$HERE/usage.py" || backed_up=0
  if [ "$backed_up" -eq 0 ]; then
    echo
    printf '\033[0;31mccgauge: nothing was overwritten — see above.\033[0m\n' >&2
    exit 1
  fi

  # Copy to a sibling temp file, then rename over the destination.
  #
  # `mv` replaces the directory entry rather than writing through it, which is
  # what keeps a symlinked $CONFIG_DIR/statusline.sh from having its target — a
  # tracked file in someone's dotfiles repo — rewritten in place. But it must
  # not be preceded by `rm`: removing the destination first means a failing copy
  # leaves nothing behind, destroying a working install, and if the clone *is*
  # the config dir then source and destination are the same file and the `rm`
  # deletes the source before it can be read.
  install_file() {
    local src="$1" dst="$2" t mode
    if [ -e "$dst" ] && [ "$(readlink -f "$src" 2>/dev/null)" = "$(readlink -f "$dst" 2>/dev/null)" ]; then
      chmod +x "$dst" 2>/dev/null || true
      return 0                      # already the same file; nothing to do
    fi
    # Severing the link is the deliberate choice (see above), but it must not be
    # silent. The content-diff backup says nothing when the link already pointed
    # at identical content, so without this a dotfiles checkout is quietly
    # detached from ~/.claude and every later `git pull` there stops mattering.
    if [ -L "$dst" ]; then
      warn "$(basename "$dst") was a symlink to $(readlink "$dst")"
      warn "replaced it with a regular file — your link is gone, the target is untouched"
    fi
    t="$dst.ccgauge-tmp.$$"
    if ! cp "$src" "$t" 2>/dev/null; then
      rm -f "$t"
      fail "could not write $dst (is $CONFIG_DIR writable?)"
      return 1
    fi
    # Carry the destination permission bits across. `cp` gave the temp file the
    # *source* mode, so replacing the entry silently re-grants whatever the repo
    # ships: a usage.py deliberately kept at 0700 comes back 0755 on every
    # update. `chmod +x` with no `who` is no better — it sets the execute bit for
    # group and other as well. These files run on every turn; keep the mode the
    # user chose and add only the owner execute bit we actually need.
    mode=""
    if [ -f "$dst" ]; then
      mode=$(DST="$dst" python3 -c \
        'import os; print("%o" % (os.stat(os.environ["DST"]).st_mode & 0o7777))' \
        2>/dev/null || echo "")
    fi
    # Guarded: an unguarded chmod would abort the run under `set -e` with no
    # diagnostic and leave the temp file behind.
    if [ -n "$mode" ]; then
      if ! chmod "$mode" "$t" 2>/dev/null || ! chmod u+x "$t" 2>/dev/null; then
        rm -f "$t"
        fail "could not set permissions on $dst"
        return 1
      fi
    elif ! chmod +x "$t" 2>/dev/null; then
      rm -f "$t"
      fail "could not make $dst executable"
      return 1
    fi
    if ! mv -f "$t" "$dst" 2>/dev/null; then
      rm -f "$t"
      fail "could not replace $dst"
      return 1
    fi
  }
  # Sweep any temp file an interrupted run leaves behind (see CLEANUP above).
  CLEANUP+=("$USAGE_DST.ccgauge-tmp.$$" "$HOOK_DST.ccgauge-tmp.$$" "$STATUSLINE_DST.ccgauge-tmp.$$")
  copied=1
  install_file "$HERE/usage.py"            "$USAGE_DST" || copied=0
  install_file "$HERE/hooks/usage-line.sh" "$HOOK_DST"  || copied=0
  if [ "$install_statusline" -eq 1 ]; then
    install_file "$HERE/statusline.sh"     "$STATUSLINE_DST" || copied=0
  fi
  if [ "$copied" -eq 0 ]; then
    echo
    printf '\033[0;31mccgauge: could not install the files — see above.\033[0m\n' >&2
    exit 1
  fi
  if [ "$install_statusline" -eq 1 ]; then
    ok "copied usage.py, hooks/usage-line.sh, statusline.sh"
  else
    ok "copied usage.py, hooks/usage-line.sh"
    warn "$STATUSLINE_DST is not ccgauge's — left it exactly as it is"
    warn "take it over with: ./install.sh --statusline"
  fi

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
  USAGE_PATH="$USAGE_DST" STATUSLINE_INSTALLED="$install_statusline" \
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
usage_py = os.environ.get("USAGE_PATH", "")
hook_cmd = shlex.quote(hook_path)
statusline_cmd = "bash " + shlex.quote(sl_path)
take_statusline = os.environ.get("TAKE_STATUSLINE") == "1"
# False when the file at sl_path is the user's own script, which we refused to
# overwrite. Registering it anyway would point Claude Code's status line at
# *their* script and then report it as ccgauge's.
statusline_installed = os.environ.get("STATUSLINE_INSTALLED", "1") == "1"

try:
    # utf-8-sig, not utf-8: a BOM is routine on Windows — Notepad and
    # PowerShell's Set-Content both write one — and Git Bash is a platform this
    # installer supports. Plain open() makes json.loads fail on column 1 of a
    # perfectly valid file, and the run dies *after* the three files are copied,
    # with a message telling the user to fix JSON that was never broken.
    # install.ps1 and usage.py already read their JSON this way.
    with open(path, encoding="utf-8-sig") as fh:
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


# Whether we actually altered the config. The rewrite decision hangs on this and
# nothing else — see the note above the write below.
changed = False

# Three different questions, three different predicates, and conflating them is
# how this loses a hook that was never ours:
#   is_hook_command   — is ccgauge reached from here? (do not add a second)
#   invokes_hook_solely — is this entry nothing but ccgauge? (safe to prune)
#   invokes_solely    — is it our own script, spelled some other way? (rewrite)
existing = [h for g in groups
            for h in (group_hooks(g) or []) if isinstance(h, dict)
            and is_hook_command(h.get("command"), hook_path, usage_py)]
registered = bool(existing)
prunable = [h for h in existing
            if invokes_hook_solely(h.get("command"), hook_path, usage_py)]
if len(prunable) > 1:
    print(f"  {Y}warn{X}  {len(prunable)} duplicate hook registrations found — pruning to one")
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
            if isinstance(h, dict) \
                    and invokes_hook_solely(h.get("command"), hook_path, usage_py):
                if seen:
                    changed = True
                    continue        # a duplicate; drop this one
                seen = True
            after.append(h)
        # Drop a group only if *we* emptied it. A group the user left empty — a
        # matcher-scoped placeholder, say — is theirs.
        if after or not hs:
            g["hooks"] = after
            kept.append(g)
    groups[:] = kept
# Recognising a registration is not the same as accepting its spelling. Matching
# the whole unquoted string stops an upgrade appending a duplicate of itself, but
# on its own it also means a pre-0.8.0 unquoted path in a config dir containing a
# space is declared "already registered" and the quoting fix never lands — the
# hook stays word-split and stays broken. Recognise it, then rewrite it.
#
# Only our own script gets respelled. A registration install.ps1 wrote is left
# exactly as it is: it works, the user may well be running PowerShell too, and
# rewriting it to a bash script is a decision that belongs to whoever runs that
# installer.
rewrote = 0
for g in groups:
    for h in (group_hooks(g) or []):
        if isinstance(h, dict) and invokes_solely(h.get("command"), hook_path) \
                and h.get("command") != hook_cmd:
            h["command"] = hook_cmd
            h.setdefault("type", "command")
            rewrote += 1
if rewrote:
    changed = True
    print(f"  {G}ok{X}    rewrote {rewrote} hook registration(s) to the quoted form")

if registered:
    if not rewrote:
        if prunable:
            print(f"  {G}ok{X}    UserPromptSubmit hook already registered")
        else:
            # Reached through a command we did not write — install.ps1, or a
            # wrapper of the user's own. Recognised so we do not add a second
            # live registration; left alone because it is not ours to edit.
            print(f"  {G}ok{X}    UserPromptSubmit hook already reached from an existing entry")
else:
    groups.append({"hooks": [{"type": "command", "command": hook_cmd}]})
    changed = True
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
# A registration naming a file that is not there renders nothing, silently, on
# every turn. Pre-0.9 installs wired statusline-snippet.sh, which this version
# deletes, so the documented `git pull && ./install.sh` update walks straight
# into it — and calling that "points elsewhere, fine if deliberate" hands the
# user a dead status line over an install reported as verified.
dead_target = ""
if current and not (sl is not None and refers_to(current, sl_path)):
    t = script_target(current)
    if t and os.path.isabs(t) and not os.path.exists(t):
        dead_target = t
was_ours = os.path.basename(dead_target) in ("statusline-snippet.sh", "statusline.sh")

if current and sl is not None and refers_to(current, sl_path) and statusline_installed:
    print(f"  {G}ok{X}    status line already registered")
elif dead_target and was_ours and statusline_installed:
    # A ccgauge status line from before the rename. Repointing it is a repair
    # rather than a takeover: the file it names is gone, so there is no working
    # configuration here to preserve.
    replacing = current
    block = sl if sl is not None else {}
    block["type"] = "command"
    block["command"] = statusline_cmd
    cfg["statusLine"] = block
    changed = True
    print(f"  {G}ok{X}    repointed a ccgauge status line that named the removed "
          f"{os.path.basename(dead_target)}")
elif current and not take_statusline:
    if dead_target:
        print(f"  {Y}warn{X}  your status line names a file that does not exist:")
        print(f"          {dead_target}")
        print( "          it renders nothing at all — fix the path, or take it over with:")
        print( "              ./install.sh --statusline")
    else:
        print(f"  {Y}warn{X}  leaving your existing status line alone:")
        print(f"          {current}")
        print( "          add ccgauge to it yourself (see the README), or take it over with:")
        print( "              ./install.sh --statusline")
elif not statusline_installed:
    # The file at sl_path is the user's own script, which the copy step refused to
    # overwrite. Registering the path anyway would aim Claude Code at their
    # script and then report it as ccgauge rendering correctly.
    print(f"  {Y}warn{X}  not registering a status line: {sl_path} is your own script")
    print( "          take it over with: ./install.sh --statusline")
else:
    replacing = current
    # Set only the keys we own, so any sibling key in an existing statusLine
    # block (padding, refreshInterval, whatever Claude Code adds next) survives.
    block = sl if sl is not None else {}
    block["type"] = "command"
    block["command"] = statusline_cmd
    cfg["statusLine"] = block
    changed = True
    print(f"  {G}ok{X}    registered status line")

# Rewrite only when something actually changed, tracked as we went. Comparing
# our own rendering against the file text instead means every settings.json that
# is not already byte-identical to json.dumps(indent=2) gets rewritten, reflowed
# and re-encoded on a run that changed nothing — collapsing the formatting the
# user chose and leaving a backup behind for it.
#
# ensure_ascii=False for the same reason: the default escapes every non-ASCII
# character it passes through, so an accented word or an em dash anywhere in the
# file comes back mangled by an installer that had no business touching it.
updated = json.dumps(cfg, indent=2, ensure_ascii=False) + "\n"
if not changed:
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
# Explicit utf-8: ensure_ascii=False above means `updated` can carry non-ASCII,
# and the default encoding follows the ambient locale, which on a C/POSIX locale
# raises UnicodeEncodeError mid-write.
with open(tmp, "w", encoding="utf-8") as fh:
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
#
# stderr goes to its own file rather than being folded in, and the test is for an
# actual bar glyph rather than for non-emptiness — the same guard the status-line
# check further down explains and this one used to skip. Folded together, any
# interpreter that writes to stderr at startup (PYTHONWARNINGS, a distro
# DeprecationWarning from a .pth, a Windows console-encoding notice) satisfies
# "non-empty" on its own, so a bar that renders nothing reports ok. usage.py
# cannot be relied on to signal it either: it suppresses its own exceptions and
# exits 0 by contract.
bar_err=$(mktemp)
CLEANUP+=("$bar_err")
if bar_out=$(python3 "$USAGE_DST" bar 50 2>"$bar_err") \
   && printf '%s' "$bar_out" | grep -q '[█▓▒░]'; then
  ok "usage.py runs               $bar_out"
else
  fail "usage.py drew no bar — run: python3 $USAGE_DST bar 50"
  [ -s "$bar_err" ] && printf '        %s\n' "$(head -2 "$bar_err")"
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
if statusline_is_ours; then sl_is_ours=1; else sl_is_ours=0; fi
settings_report=$(
  SETTINGS="$SETTINGS" HOOK_DST="$HOOK_DST" STATUSLINE_DST="$STATUSLINE_DST" \
  USAGE_DST="$USAGE_DST" SL_IS_OURS="$sl_is_ours" \
  python3 <<'PY'
import json, os, shlex, sys

G, Y, R, X = "\033[0;32m", "\033[0;33m", "\033[0;31m", "\033[0m"
try:
    # utf-8-sig: a BOM is routine on Windows and is not a broken file. Reading it
    # as plain utf-8 reports a valid settings.json as invalid and sends the user
    # off to restore a backup they do not need.
    cfg = json.load(open(os.environ["SETTINGS"], encoding="utf-8-sig"))
except Exception as exc:
    print(f"  {R}FAIL{X}  settings.json is not valid JSON ({exc})")
    print("        restore it from the newest settings.json.*.bak beside it")
    sys.exit(1)
print(f"  {G}ok{X}    settings.json is valid JSON")

hook, sl = os.environ["HOOK_DST"], os.environ["STATUSLINE_DST"]
usage_py = os.environ.get("USAGE_DST", "")


exec(os.environ["PY_PRELUDE"])   # refers_to() — single definition, see the top


# Every read here goes through dget: settings.json is hand-editable, `--check`
# skips the writer entirely, and an unguarded chained .get() tracebacks on the
# very shapes the writer preserves — turning a correct install into a false FAIL
# with a Python stack trace on the terminal.
groups = dget(dget(cfg, "hooks"), "UserPromptSubmit")
if not isinstance(groups, list):
    if groups is not None:
        print(f"  {Y}warn{X}  hooks.UserPromptSubmit is not a list — cannot read it")
    groups = []
# Counted across both installer spellings. Counting only usage-line.sh misses the
# `python <usage.py> hookline` form install.ps1 writes, so a machine carrying one
# of each fires the hook twice a turn while this check reports a single clean
# registration.
matches = [h for g in groups
           for h in (dget(g, "hooks") if isinstance(dget(g, "hooks"), list) else [])
           if isinstance(h, dict) and is_hook_command(h.get("command"), hook, usage_py)]
registered = bool(matches)
if len(matches) > 1:
    print(f"  {Y}warn{X}  hook is registered {len(matches)} times — it will fire "
          f"{len(matches)}x per turn")
    print( "        re-run ./install.sh (without --check) to prune the duplicates")
for h in matches:
    rel = script_target(h.get("command"))
    if rel and not os.path.isabs(rel):
        print(f"  {Y}warn{X}  hook command uses a relative path: {rel}")
        print( "        Claude Code runs it from the project directory, not from here,")
        print( "        so it will usually not resolve — re-run ./install.sh to fix it")
print(f"  {G}ok{X}    UserPromptSubmit hook is registered" if registered
      else f"  {R}FAIL{X}  UserPromptSubmit hook is NOT registered")

sl_raw = cfg.get("statusLine") if isinstance(cfg, dict) else None
cmd = dget(sl_raw, "command") or ""
# A statusLine that is not an object is still a configured status line — the
# writer deliberately leaves it alone, so the verifier must not call it missing.
if not cmd and sl_raw is not None and not isinstance(sl_raw, dict):
    cmd = json.dumps(sl_raw)
# Registered at our path AND the file there is actually ours. The registration
# alone is not ownership: Claude Code writes its own /statusline script to that
# same path, and claiming it renders ccgauge is how a preserved user status line
# gets reported as a working ccgauge install.
sl_is_ours_file = os.environ.get("SL_IS_OURS") == "1"
ours = refers_to(cmd, sl) and isinstance(sl_raw, dict) and sl_is_ours_file
target = script_target(cmd)
sl_broken = False
if ours:
    print(f"  {G}ok{X}    status line is registered")
elif cmd and refers_to(cmd, sl) and not sl_is_ours_file:
    print(f"  {Y}warn{X}  status line at {sl} is your own script, not ccgauge's")
    print( "        left alone on purpose — take it over with: ./install.sh --statusline")
elif cmd and target and not os.path.isabs(target):
    # Cannot be verified from here and will not resolve there: this process runs
    # wherever the installer was launched, Claude Code runs the status line from
    # the project directory. Resolving it against our own cwd is what let a
    # relative registration be reported as ours and rendered green.
    print(f"  {Y}warn{X}  status line uses a relative path: {target}")
    print( "        Claude Code runs it from the project directory, not from here,")
    print( "        so it will usually render nothing — re-run ./install.sh to fix it")
elif cmd and target and os.path.isabs(target) and not os.path.exists(target):
    sl_broken = True
    print(f"  {R}FAIL{X}  status line names a file that does not exist: {target}")
    print( "        it renders nothing every turn — re-run ./install.sh without --check")
elif cmd:
    print(f"  {Y}warn{X}  status line points elsewhere: {cmd}")
    print( "        (fine if that is deliberate — see the README)")
else:
    print(f"  {R}FAIL{X}  no status line configured — the gauges have nowhere to render")
    print( "        re-run ./install.sh without --check")

sys.exit(0 if registered and (ours or cmd) and not sl_broken else 1)
PY
) && settings_ok=1 || settings_ok=0
printf '%s\n' "$settings_report"
[ "$settings_ok" -eq 1 ] || \
  fail "settings.json is unreadable, or its hook or status line is missing or broken"

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
# CCGAUGE_USAGE_PY is deliberately NOT cleared. Clearing it makes these checks
# exercise a different file from the one that will actually run: both scripts
# read the variable at render time and Claude Code inherits whatever the user
# exported, so a variable pointing at a stale checkout produced a green install
# and permanently blank gauges. Verify what will run, and say so when it is not
# the file we just copied.
#
# Select *ccgauge's own* entries, not simply the first one present. Picking the
# first UserPromptSubmit hook runs a stranger's script and then fails it for not
# printing [usage]; taking the statusLine unconditionally runs the status line we
# just deliberately preserved and fails it for not drawing our glyphs. Both
# declare a correct install broken.
hook_cmd_stored=$(SETTINGS="$SETTINGS" TARGET="$HOOK_DST" USAGE_DST="$USAGE_DST" python3 -c '
import json, os
exec(os.environ["PY_PRELUDE"])
cfg = json.load(open(os.environ["SETTINGS"], encoding="utf-8-sig"))
groups = dget(dget(cfg, "hooks"), "UserPromptSubmit")
target = os.environ["TARGET"]
usage_py = os.environ.get("USAGE_DST", "")
found = ""
# Every level type-guarded, and `hooks` iterated only when it is really a list.
# Without that guard a malformed sibling group — {"hooks": 5} — raises TypeError,
# the 2>/dev/null swallows it, and the empty result is reported as "no hook
# command to exercise": a correct install failing on someone else'"'"'s bad entry.
if isinstance(groups, list):
    for g in groups:
        hs = dget(g, "hooks")
        if not isinstance(hs, list):
            continue
        for h in hs:
            if isinstance(h, dict) and is_hook_command(h.get("command"), target, usage_py):
                found = h.get("command", "")
                break
        if found:
            break
print(found)' 2>/dev/null || echo "")

# Empty unless the configured status line is ours; a preserved foreign one is
# reported as skipped rather than executed and judged by our criteria.
#
# Both halves have to hold: the registration must name our path AND the file
# sitting there must actually be ours. Checking only the registration runs a
# user script that happens to live at the default path and then fails it for not
# drawing ccgauge's gauges — a correct install reported as broken.
if ! statusline_is_ours; then
  sl_cmd_stored=""
else
sl_cmd_stored=$(SETTINGS="$SETTINGS" TARGET="$STATUSLINE_DST" python3 -c '
import json, os
exec(os.environ["PY_PRELUDE"])
cfg = json.load(open(os.environ["SETTINGS"], encoding="utf-8-sig"))
sl = cfg.get("statusLine")
cmd = (sl.get("command") or "") if isinstance(sl, dict) else ""
print(cmd if refers_to(cmd, os.environ["TARGET"]) else "")' 2>/dev/null || echo "")
fi

hook_err=$(mktemp); sl_err=$(mktemp)
CLEANUP+=("$hook_err" "$sl_err")

# Say plainly when the checks below are exercising a file we did not install.
if [ -n "${CCGAUGE_USAGE_PY:-}" ]; then
  warn "CCGAUGE_USAGE_PY is set: $CCGAUGE_USAGE_PY"
  warn "the checks below exercise that file, because Claude Code will inherit it too"
  if [ "$CCGAUGE_USAGE_PY" != "$USAGE_DST" ]; then
    warn "it is NOT the usage.py this installer manages — unset it if that is unintended"
  fi
fi

# Whether the stored hook command runs our script (which honours
# CCGAUGE_USAGE_PY) or invokes usage.py directly, as install.ps1 registers it.
# Only the former can be exercised against a stub.
if printf '%s' "$hook_cmd_stored" | grep -qF "$HOOK_DST"; then
  hook_via_script=1
else
  hook_via_script=0
fi

if [ -z "$hook_cmd_stored" ]; then
  fail "no hook command in settings.json to exercise"
elif [ "$CHECK_ONLY" -eq 1 ] && [ "$hook_via_script" -eq 0 ]; then
  # A direct usage.py invocation ignores CCGAUGE_USAGE_PY, so there is no way to
  # run it here without the network call --check promises not to make.
  ok "hook registered (a direct usage.py call — not executed under --check)"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  # Run the real command, with usage.py stubbed out. "Present, executable and
  # registered" proves nothing about whether the shell can actually run the
  # thing: a CRLF checkout dies with `bad interpreter: ...^M` and satisfies all
  # three, so the one failure a user runs --check to diagnose was the one it
  # could not see. The stub keeps the run free of network calls and history
  # writes, which is what makes --check safe to repeat while diagnosing a
  # rate limit.
  hook_stub=$(mktemp)
  CLEANUP+=("$hook_stub")
  printf 'print("[usage] --check stub")\n' > "$hook_stub"
  if hook_out=$(printf '%s' "$SAMPLE" \
                | CCGAUGE_USAGE_PY="$hook_stub" CCGAUGE_NO_LOG=1 \
                  sh -c "$hook_cmd_stored" 2>"$hook_err") \
     && printf '%s' "$hook_out" | grep -q '\[usage\]'; then
    ok "hook runs (usage.py stubbed — --check makes no network call)"
  else
    fail "hook command failed to run — try: echo '{}' | sh -c $hook_cmd_stored"
    [ -s "$hook_err" ] && printf '        %s\n' "$(head -2 "$hook_err")"
  fi
# CCGAUGE_NO_LOG, because this run is synthetic: without it every install and
# every update appends a fabricated prompt event to usage-log.jsonl, and
# `usage.py log` then reports those install-check entries as real history.
elif hook_out=$(printf '%s' "$SAMPLE" | CCGAUGE_NO_LOG=1 sh -c "$hook_cmd_stored" 2>"$hook_err") \
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
elif ! sl_out=$(printf '%s' "$SAMPLE" | sh -c "$sl_cmd_stored" 2>"$sl_err"); then
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

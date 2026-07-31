#!/usr/bin/env python3
"""Unit tests for the command-parsing helpers embedded in install.sh.

Run:  python3 tests/test_prelude.py      (exit 0 = pass; no dependencies)

install.sh carries a block of Python in PY_PRELUDE, shared by every embedded
snippet that has to answer "what does this command actually run" — for the
UserPromptSubmit hook and for the status line. Those predicates decide whether a
registration is ours, whether a file needs its execute bit, and whether a hook
will produce output at all.

They had no coverage. `bash -n` proves the *shell* parses and says nothing about
Python living inside a single-quoted heredoc, so the only way a mistake surfaced
was a full installer run per case — slow, and lossy about which predicate was
wrong. Every assertion below stands for a way one of them was, or could be,
fooled by a command a shell would refuse to run, run differently, or run to no
effect.

The prelude is extracted from install.sh rather than duplicated, so these tests
fail if the source drifts instead of quietly passing against a stale copy.
"""
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
INSTALL_SH = HERE.parent / "install.sh"


def load_prelude():
    """exec PY_PRELUDE out of install.sh and return its namespace.

    Failures here name their cause. A bare ValueError from str.index would say
    only "substring not found" — a confusing way to learn that the block was
    renamed or the closing quote reindented, in a test whose whole point is
    tracking the real source rather than a copy.
    """
    src = INSTALL_SH.read_text()
    marker = "PY_PRELUDE='"
    pos = src.find(marker)
    if pos < 0:
        raise SystemExit(f"{INSTALL_SH}: no {marker} block found")
    start = pos + len(marker)
    end = src.find("\n'\n", start)
    if end < 0:
        raise SystemExit(f"{INSTALL_SH}: unterminated {marker} block")
    ns = {}
    # exec is deliberate: it is what keeps this testing the shipped prelude
    # rather than a second copy that can drift out from under it.
    exec(compile(src[start:end], "PY_PRELUDE", "exec"), ns)  # noqa: S102
    return ns


ns = load_prelude()
split_ok = ns["_split_ok"]
shell_assign = ns["_shell_assignment"]
env_assign = ns["_env_assignment"]
argv_of = ns["effective_argv"]
operand = ns["python_script_operand"]

U = "/abs/usage.py"
SL = "/abs/statusline.sh"
failures = []


def check(label, got, want):
    if got != want:
        failures.append(f"{label}\n     got:  {got!r}\n     want: {want!r}")


# --- shell quoting ----------------------------------------------------------
# A command the shell cannot parse must not validate. _words falls back to
# whitespace splitting for *recognition*, where being generous means declining to
# add a duplicate registration; validation has to ask this instead.
check("unterminated quote rejected", split_ok('python3 ' + U + ' hookline "'), False)
check("balanced quotes accepted", split_ok('python3 "' + U + '" hookline'), True)
check("unquoted accepted", split_ok("python3 " + U + " hookline"), True)
check("non-string rejected", split_ok(None), False)

# --- assignment prefixes ----------------------------------------------------
# A shell only treats NAME=VALUE as an assignment when NAME is a valid
# identifier; anything else it tries to execute. env is more permissive, and
# keeps its own test.
check("identifier is an assignment", shell_assign("PYTHONUTF8=1"), True)
check("leading underscore ok", shell_assign("_FOO=1"), True)
check("hyphen is not an identifier", shell_assign("bad-name=1"), False)
check("leading digit is not an identifier", shell_assign("2FOO=1"), False)
check("env stays permissive", env_assign("bad-name=1"), True)

# --- effective_argv: what the command really invokes -------------------------
check("valid prefix skipped",
      argv_of("PYTHONUTF8=1 python3 " + U + " hookline")[0], "python3")
check("invalid prefix NOT skipped",
      argv_of("bad-name=1 python3 " + U + " hookline")[0], "bad-name=1")
check("env unwrapped", argv_of("env python3 " + U)[0], "python3")
check("env -u consumes its value", argv_of("env -u FOO python3 " + U)[0], "python3")
check("env -S splits into the command",
      argv_of("env -S python3 " + U + " hookline")[0], "python3")
check("env -S attached splits into the command",
      argv_of("env -Spython3 " + U)[0], "python3")
check("env --split-string= splits into the command",
      argv_of("env --split-string=python3 " + U)[0], "python3")
check("env -C consumes its value",
      argv_of("env -C /tmp python3 " + U)[0], "python3")
check("env -- ends its options", argv_of("env -- python3 " + U)[0], "python3")
check("env bash reads the file", argv_of("env bash " + SL), ["bash", SL])
check("env bare execs the file", argv_of("env " + SL), [SL])
check("python as an argument is not the program",
      argv_of("printf python3 " + U + " hookline")[0], "printf")

# --- python_script_operand: what Python actually executes --------------------
check("plain script", operand(["python3", U, "hookline"]), U)
check("flag before script", operand(["python3", "-u", U, "hookline"]), U)
check("-W takes a value", operand(["python3", "-W", "ignore", U]), U)
check("-X takes a value", operand(["python3", "-X", "utf8", U]), U)
check("--check-hash-based-pycs takes a value",
      operand(["python3", "--check-hash-based-pycs", "always", U]), U)
check("-- ends the options", operand(["python3", "--", U, "hookline"]), U)
check("-c takes its place", operand(["python3", "-c", "pass", U, "hookline"]), "")
check("-m takes its place", operand(["python3", "-m", "mod", U, "hookline"]), "")
check("attached -c", operand(["python3", "-cpass", U]), "")
check("stdin", operand(["python3", "-", U]), "")
# These print and exit; the file named after one is never run.
check("--help", operand(["python3", "--help", U, "hookline"]), "")
check("-h", operand(["python3", "-h", U]), "")
check("-V", operand(["python3", "-V", U]), "")
check("-VV", operand(["python3", "-VV", U]), "")
check("--version", operand(["python3", "--version", U]), "")
check("--help-all", operand(["python3", "--help-all", U]), "")
check("--help-env", operand(["python3", "--help-env", U]), "")
# -v is verbose, not terminating: the script still runs.
check("-v is not terminating", operand(["python3", "-v", U]), U)

if failures:
    print(f"FAILED ({len(failures)}):", file=sys.stderr)
    for f in failures:
        print("  - " + f, file=sys.stderr)
    sys.exit(1)
print("prelude: all checks passed")

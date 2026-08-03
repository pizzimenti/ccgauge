# ccgauge installer for native Windows.
#
# The PowerShell twin of install.sh: copies usage.py into your Claude Code
# config directory and registers BOTH the UserPromptSubmit hook and the status
# line in settings.json, idempotently.
#
# The status line used to be left to the reader, with the closing message
# showing the JSON to paste. That made the visible half of the tool optional on
# Windows and automatic on Linux, for no reason a user could see — an install
# is an install on both. `usage.py statusline` is the Windows renderer: one
# Python process producing the same two lines statusline.sh produces on POSIX,
# because there is no bash here to lean on.
#
# Usage:  powershell -ExecutionPolicy Bypass -File install.ps1
#         (installs into %USERPROFILE%\.claude or $env:CLAUDE_CONFIG_DIR)
#
# Works in Windows PowerShell 5.1 and PowerShell 7+.

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$settings = Join-Path $configDir 'settings.json'
$usagePyDest = Join-Path $configDir 'usage.py'

# Find a real Python 3. `python` first (the plainest token for the hook
# command), then the py launcher, then python3 — and each candidate is
# actually run, because on a stock Windows install `python` is a Microsoft
# Store stub that opens a browser instead of running scripts.
$python = $null
$probeEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'  # 5.1 turns redirected stderr into a terminating error under Stop
try {
    foreach ($cand in @(
            @{ exe = 'python'; pre = @() },
            @{ exe = 'py'; pre = @('-3') },
            @{ exe = 'python3'; pre = @() })) {
        if (-not (Get-Command $cand.exe -ErrorAction SilentlyContinue)) { continue }
        try {
            & $cand.exe @($cand.pre + @('-c', 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)')) 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $python = $cand; break }
        } catch { }
    }
} finally {
    $ErrorActionPreference = $probeEap
}
if (-not $python) {
    throw 'ccgauge: no working Python 3 on PATH. Install it (https://python.org or `winget install Python.Python.3.13`) and re-run.'
}
$pyToken = (@($python.exe) + $python.pre) -join ' '

Write-Host "ccgauge: installing into $configDir (python: $pyToken)"
New-Item -ItemType Directory -Force -Path $configDir | Out-Null

Copy-Item -LiteralPath (Join-Path $here 'usage.py') -Destination $usagePyDest -Force
Write-Host 'ccgauge: copied usage.py'

# The hook command must survive whichever shell Claude Code picks on Windows
# (Git Bash if installed, PowerShell otherwise), so: forward slashes — Git
# Bash eats lone backslashes, every Windows API accepts slashes — and plain
# double quotes, which both shells pass through.
$usagePyFwd = $usagePyDest -replace '\\', '/'
$hookCmd = "$pyToken `"$usagePyFwd`" hookline"
# Same spelling rules as the hook, for the same reason: this string is handed to
# whichever shell Claude Code picks. `statusline` is the Windows renderer --
# cwd, model, context bar and the 5h/7d gauges in one Python process, since
# there is no bash here to run statusline.sh.
$statusLineCmd = "$pyToken `"$usagePyFwd`" statusline"

if (-not (Test-Path -LiteralPath $settings)) {
    Set-Content -LiteralPath $settings -Value "{`n  `"hooks`": {}`n}" -Encoding Ascii
    Write-Host "ccgauge: created $settings"
}

# Validate BEFORE touching the backup: if settings.json is broken JSON, a
# pre-existing good .bak must survive as the thing to restore from, not be
# clobbered by a copy of the breakage. The validator swallows its own
# exception so nothing lands on stderr — PS 5.1 under EAP=Stop turns
# redirected stderr into a terminating error, and even unredirected
# tracebacks are noise the throw below already covers.
$validatePy = "import json, sys`ntry:`n    json.load(open(sys.argv[1], encoding='utf-8-sig'))`nexcept Exception:`n    sys.exit(1)"
& $python.exe @($python.pre + @('-c', $validatePy, $settings)) | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "ccgauge: $settings is not valid JSON -- fix it (or delete it) and re-run. Nothing was changed."
}

# No backup here. It used to be taken unconditionally, to a single fixed
# settings.json.bak, with -Force -- which is the trap install.sh removed in
# 0.9.0 and this script kept: install, notice your status line changed, re-run
# the installer while working out how to undo it, and the second run's backup --
# now a copy of the modified file -- has destroyed the only copy of the original.
# A run that changes nothing overwrote it too, which is how the trap springs
# without anyone doing anything wrong.
#
# The registrar below takes a timestamped one instead, immediately before it
# writes and only if it is going to write, and never over an existing file.

# Register the hook with Python, not ConvertTo-Json: PowerShell's JSON
# round-trip re-wraps and re-types everything it touches (and 5.1 truncates
# at -Depth), while this edits one key and leaves the rest untouched — the
# same approach install.sh embeds, plus in-place update of a ccgauge hook
# registered by an earlier install (a different python token, or the POSIX
# usage-line.sh from a synced settings.json — replacements are printed, and
# the write keeps LF line endings so a synced file doesn't churn to CRLF).
$registerPy = @'
import datetime, json, os, re, sys

path = sys.argv[1]
hook_cmd = os.environ["CCGAUGE_HOOK_CMD"]
status_cmd = os.environ["CCGAUGE_STATUS_CMD"]

with open(path, encoding="utf-8-sig") as fh:
    cfg = json.load(fh)

# A ccgauge registration and nothing else: usage-line.sh as the command's
# last word, or usage.py with its mode as the *very next* token. An
# unrelated hook that merely mentions usage.py somewhere, or happens to end
# in "... line", is never claimed.
OURS = re.compile(r"(usage-line\.sh[\"']?\s*$)|(usage\.py[\"']?\s+(hookline|line)\s*$)")

hooks = cfg.get("hooks")
if hooks is None:
    hooks = cfg["hooks"] = {}
if not isinstance(hooks, dict):
    print("ccgauge: settings.json 'hooks' is not an object -- not touching it")
    sys.exit(1)
ups = hooks.get("UserPromptSubmit")
if ups is None:
    ups = hooks["UserPromptSubmit"] = []
if not isinstance(ups, list):
    print("ccgauge: settings.json hooks.UserPromptSubmit is not a list -- not touching it")
    sys.exit(1)

changed = False
notes = []

existing = [h for g in ups if isinstance(g, dict)
            for h in (g.get("hooks") or [])
            if isinstance(h, dict) and OURS.search(str(h.get("command", "")))]

stale = [h for h in existing if h.get("command") != hook_cmd]
if existing and not stale:
    notes.append("hook already registered")
elif stale:
    for h in stale:
        notes.append("replacing ccgauge hook: " + str(h.get("command", "")))
        h["command"] = hook_cmd
    changed = True
    notes.append("ccgauge hook is now: " + hook_cmd)
else:
    ups.append({"hooks": [{"type": "command", "command": hook_cmd}]})
    changed = True
    notes.append("registered UserPromptSubmit hook")

# The status line, registered rather than described. The whole block has to be
# right and not just the command: a canonical command under a wrong "type" is
# not a working registration, and testing the command alone reports it as one.
sl = cfg.get("statusLine")
if isinstance(sl, dict) and sl.get("type") == "command" and sl.get("command") == status_cmd:
    notes.append("status line already registered")
else:
    if sl is not None:
        notes.append("replaced your status line: " + json.dumps(sl))
    # Set only the keys we own, so a sibling key in an existing statusLine block
    # survives; a non-object value is not a block to preserve, so start fresh.
    block = sl if isinstance(sl, dict) else {}
    block["type"] = "command"
    block["command"] = status_cmd
    cfg["statusLine"] = block
    changed = True
    notes.append("registered status line")

# Nothing is announced until the outcome it describes is real. Printed up front,
# a failed backup produced "registered status line" immediately followed by
# "settings.json not modified" -- two lines contradicting each other, with the
# true one second. The no-op path prints here because nothing downstream can
# change it.
if not changed:
    for note in notes:
        print("ccgauge: " + note)
    print("ccgauge: settings.json already correct -- not rewritten")
    sys.exit(0)

# Timestamped, written only on a run that changes something, and never over an
# existing file -- "xb" fails rather than clobbers. The old single fixed .bak,
# copied on every run including no-op ones, is how a second run destroys the
# copy of the original you were about to restore from.
stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
backup = "%s.%s.bak" % (path, stamp)
n = 1
while os.path.exists(backup):
    backup = "%s.%s-%d.bak" % (path, stamp, n)
    n += 1
try:
    with open(path, "rb") as src, open(backup, "xb") as dst:
        dst.write(src.read())
except OSError as exc:
    print("ccgauge: could not write a backup (%s) -- settings.json not modified" % exc)
    sys.exit(1)
print("ccgauge: backed up settings.json -> " + os.path.basename(backup))

# ensure_ascii=False, matching install.sh: the default escapes every non-ASCII
# character it passes through, so an accented word or an em dash anywhere in a
# settings.json we are only editing one key of comes back mangled.
with open(path, "w", encoding="utf-8", newline="\n") as fh:
    json.dump(cfg, fh, indent=2, ensure_ascii=False)
    fh.write("\n")

# Now that it is true.
for note in notes:
    print("ccgauge: " + note)
'@

$env:CCGAUGE_HOOK_CMD = $hookCmd
$env:CCGAUGE_STATUS_CMD = $statusLineCmd
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ccgauge-register-" + [System.IO.Path]::GetRandomFileName() + ".py")
Set-Content -LiteralPath $tmp -Value $registerPy -Encoding UTF8
try {
    & $python.exe @($python.pre + @($tmp, $settings))
    if ($LASTEXITCODE -ne 0) { throw "ccgauge: could not update $settings -- it was not modified (details above)" }
} finally {
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    Remove-Item Env:CCGAUGE_HOOK_CMD -ErrorAction SilentlyContinue
    Remove-Item Env:CCGAUGE_STATUS_CMD -ErrorAction SilentlyContinue
}

Write-Host @"

ccgauge: done. Next steps:
  1. Verify it works:   $pyToken "$usagePyDest" show
  2. Restart Claude Code (or start a new session) so the hook and status line
     load.

Both halves are registered for you — the hook that feeds Claude your usage, and
the status line that shows you the gauges. If you would rather keep a status
line of your own, point statusLine back at it in
$settings
and append '$pyToken "$usagePyFwd" status' to your script to keep the numbers;
that mode only reads the cache, so it is safe on every render. Re-running this
installer will take the slot back — it always installs ccgauge's.

The hook injects a [usage] line into the assistant's context each turn. At 95%
of the session window it directs the assistant to queue work, compact, and set
a wake-up alarm — add the standing note from the README's "Wind-down behavior"
section to your CLAUDE.md so the assistant treats that as policy.
"@

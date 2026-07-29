# ccgauge installer for native Windows.
#
# The PowerShell twin of install.sh: copies usage.py into your Claude Code
# config directory and registers the UserPromptSubmit hook in settings.json
# (idempotently, with a backup). The status line is left to you — the final
# output shows the one-line wire-up.
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

Copy-Item -LiteralPath $settings "$settings.bak" -Force
Write-Host 'ccgauge: backed up settings.json -> settings.json.bak'

# Register the hook with Python, not ConvertTo-Json: PowerShell's JSON
# round-trip re-wraps and re-types everything it touches (and 5.1 truncates
# at -Depth), while this edits one key and leaves the rest untouched — the
# same approach install.sh embeds, plus in-place update of a ccgauge hook
# registered by an earlier install (a different python token, or the POSIX
# usage-line.sh from a synced settings.json — replacements are printed, and
# the write keeps LF line endings so a synced file doesn't churn to CRLF).
$registerPy = @'
import json, os, re, sys

path = sys.argv[1]
hook_cmd = os.environ["CCGAUGE_HOOK_CMD"]

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

existing = [h for g in ups if isinstance(g, dict)
            for h in (g.get("hooks") or [])
            if isinstance(h, dict) and OURS.search(str(h.get("command", "")))]

def write():
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(cfg, fh, indent=2)
        fh.write("\n")

stale = [h for h in existing if h.get("command") != hook_cmd]
if existing and not stale:
    print("ccgauge: hook already registered -- leaving settings.json unchanged")
elif stale:
    for h in stale:
        print("ccgauge: replacing ccgauge hook: " + str(h.get("command", "")))
        h["command"] = hook_cmd
    write()
    print("ccgauge: ccgauge hook is now: " + hook_cmd)
else:
    ups.append({"hooks": [{"type": "command", "command": hook_cmd}]})
    write()
    print("ccgauge: registered UserPromptSubmit hook in settings.json")
'@

$env:CCGAUGE_HOOK_CMD = $hookCmd
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ccgauge-register-" + [System.IO.Path]::GetRandomFileName() + ".py")
Set-Content -LiteralPath $tmp -Value $registerPy -Encoding UTF8
try {
    & $python.exe @($python.pre + @($tmp, $settings))
    if ($LASTEXITCODE -ne 0) { throw "ccgauge: could not update $settings -- it was not modified (details above)" }
} finally {
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    Remove-Item Env:CCGAUGE_HOOK_CMD -ErrorAction SilentlyContinue
}

$statusCmd = "$pyToken \`"$usagePyFwd\`" statusline"
Write-Host @"

ccgauge: done. Next steps:
  1. Verify it works:   $pyToken "$usagePyDest" show
  2. Status line (optional) — add to $settings :
       "statusLine": { "type": "command", "command": "$statusCmd" }
     (usage.py statusline renders a whole example status line: cwd, model,
     context bar, usage gauges. Already have a status line? Append
     '$pyToken "$usagePyFwd" status' to it instead — it only reads the
     cache, so it is safe on every render.)
  3. Restart Claude Code (or start a new session) so the hook loads.

The hook injects a [usage] line into the assistant's context each turn. At 95%
of the session window it directs the assistant to queue work, compact, and set
a wake-up alarm — add the standing note from the README's "Wind-down behavior"
section to your CLAUDE.md so the assistant treats that as policy.
"@

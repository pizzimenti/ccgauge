# Changelog

All notable changes to ccgauge are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); this project uses
[Semantic Versioning](https://semver.org/).

## [0.10.0] — 2026-07-31

Hardens the installer against the configurations it can actually meet on a real
machine — a status line the user wrote themselves, a registration written by the
other installer, a settings.json with a BOM — and closes a staleness gap in the
hook line. A minor rather than a patch bump because installer *behavior* changes:
files it used to overwrite it now refuses to touch.

### Changed

- **`install.sh` no longer overwrites `statusline.sh` unconditionally.**
  `$CONFIG_DIR/statusline.sh` is exactly where Claude Code's own `/statusline`
  command writes, so a file being at that path proved nothing about who put it
  there. The installer now writes it only when it is absent, carries ccgauge's
  marker, or `--statusline` is passed — and says so plainly when it declines.
  Previously the documented `git pull && ./install.sh` update path re-clobbered
  a hand-written status line on every run, which made `--statusline` meaningless
  for anyone whose status line sat at the default location.
- **Hook registration is matched by three separate predicates instead of one.**
  "Is ccgauge reached from here" (don't add a second), "is this entry nothing but
  ccgauge" (safe to prune), and "is this our own script spelled differently"
  (safe to rewrite) are three different questions. Conflating them meant a
  command that merely *referenced* the hook — say a wrapper that watches it —
  counted as a duplicate and got deleted. Matching is also restricted to
  absolute paths now: hook commands run from the project directory, not from
  wherever the installer happened to be launched, so a relative word that
  matched at install time names something else at run time.
- **A registration written by `install.ps1` is recognised and left alone.** One
  machine can see both installers — Git Bash is a platform `install.sh` supports
  and `install.ps1` targets the same config dir. Two live registrations fire the
  hook twice a turn, injecting two `[usage]` blocks and doubling the request rate
  against an endpoint that rate-limits hard.
- **`settings.json` is rewritten only when something actually changed.** The
  check compared the installer's own re-rendering against the file's text, so
  any `settings.json` not already byte-identical to `json.dumps(indent=2)` was
  reflowed, re-encoded and backed up on a run that changed nothing. Non-ASCII
  now survives too (`ensure_ascii=False` with an explicit UTF-8 write) instead
  of coming back escaped.

### Fixed

- **The hook line no longer shows numbers up to 30 minutes out of date.** The
  `UserPromptSubmit` hook prints its line *before* it spawns the background
  warm-refresh, so the value that reaches the model is one fetched on an earlier
  turn. `line` compensated with a synchronous fetch, but only once the cache was
  older than `STALE_SECONDS` (30 min) — leaving a dead band above `TTL_SECONDS`
  (10 min) where the cache was refetchable but nothing refetched it before
  printing. Any 10–30 minute gap between prompts — a long agent turn, reading a
  diff, stepping away — printed stale numbers with no staleness marker, since
  the readout was still inside the 30-minute window that would have flagged it.
  Observed in the wild at 24 minutes: the line reported a 5-hour window at 46%
  while the refresh it kicked off moments later wrote 87%.

  The synchronous freshen is now gated on `TTL_SECONDS` instead, matching the
  gate to the interval at which the data is actually refetchable.

  This does **not** increase the request rate. `refresh()` self-throttles on the
  same TTL, the same 429 back-off and the same non-blocking lock, so the ceiling
  stays one request per `TTL_SECONDS`; the fetch simply moves ahead of the print
  instead of trailing it. The cost is up to `HTTP_TIMEOUT` (6s) of prompt latency
  on the first prompt after an idle gap, and — because a failed fetch now parks
  the next attempt (below) — at most once per `TTL_SECONDS` while the endpoint is
  down, rather than on every turn. During active back-and-forth the cache stays
  under the TTL, the gate never fires, and `line` stays instant.

- **A failed fetch no longer costs latency on every prompt.** A non-429 failure —
  endpoint unreachable, DNS down, a timeout — writes no cache, so nothing
  advanced the TTL clock and the synchronous gate above stayed true. Every
  prompt then opened another request and blocked on it for up to `HTTP_TIMEOUT`,
  turning an outage into six seconds of latency per turn. One failure now parks
  the next attempt a full `TTL_SECONDS` out: the same cadence a *successful*
  fetch sets, so an outage costs no more attempts than normal operation. It is
  deliberately not the 429 ladder, which escalates to two hours to let a
  server-side quota drain — the wrong answer to a dropped Wi-Fi link. `usage.py
  show` bypasses it, as it already bypasses the TTL.

  The status line is unaffected — it reads the cache without refreshing, and
  `STALE_SECONDS` still governs the stale marker and the pace-mark age budget
  everywhere they applied before.

- **The status line no longer mangles home-adjacent paths.** `short_cwd` replaced
  `$HOME` as a bare character prefix, so with `HOME=/home/ada` a session in
  `/home/ada2/proj` rendered as `~2/proj` — a path that is wrong and cannot be
  pasted anywhere. It now matches on a path-component boundary, with `$HOME`
  quoted so it is not read as a glob.
- **Installing no longer fabricates session history.** `install.sh` exercises the
  real hook to prove the install works; that synthetic run appended a prompt
  event which `usage.py log` then reported back as genuine history, on every
  install and every update. `CCGAUGE_NO_LOG=1` suppresses the write.
- **A status line pointing at the removed `statusline-snippet.sh` is repaired
  rather than left dead.** Pre-0.9 installs wired that file, which 0.9.0 deleted,
  so the documented update path walked straight into a registration that renders
  nothing at all, silently, on every turn.
- **A `settings.json` with a UTF-8 BOM no longer fails the install.** A BOM is
  routine on Windows — both Notepad and PowerShell's `Set-Content` write one —
  and Git Bash is a supported platform. The run died *after* copying the three
  files, telling the user to fix JSON that was never broken.
- **Existing file permissions survive an update.** `install_file` re-granted
  whatever mode the repo shipped, so a `usage.py` deliberately kept at `0700`
  came back `0755` on every update. It now carries the destination's bits across
  and adds only the owner execute bit. It also warns when it replaces a symlink,
  which otherwise detached a dotfiles checkout from `~/.claude` silently.
- **An uncreatable config dir now fails loudly.** `mkdir -p` was unguarded, so a
  read-only parent or a bad mount aborted the run under `set -e` with a bare
  `mkdir:` line — no `FAIL`, no failure count, no "nothing was installed"
  summary.

## [0.9.0] — 2026-07-30

Makes `./install.sh` a complete install on POSIX rather than half of one, and
gives it a verification pass that fails loudly. The Windows path added in 0.8.0
is unaffected — `install.ps1` remains the installer there.

### Changed

- **`./install.sh` now installs the whole thing, not half of it.** It also
  copies a complete status line (`statusline.sh`) and registers it in
  `settings.json` alongside the `UserPromptSubmit` hook. Previously the
  installer set up only the hook and left the status line — the part you
  actually look at — as a manual step against an example file, so a fresh
  machine needed hand-editing before the gauges appeared anywhere. `git clone
  && ./install.sh` is now the entire install, and `git pull && ./install.sh`
  the entire update.
- **The installer verifies its own work and fails loudly.** It checks that the
  files are present and executable, that `usage.py` runs, that every mode exits
  cleanly, that `settings.json` is still valid JSON with both entries
  registered, and that the hook and status line each render real output —
  exiting non-zero with a specific message and a command to reproduce the
  problem. Credentials and endpoint reachability are warnings rather than
  failures, since neither a container nor a logged-out CLI is a broken install.

  This exists because `usage.py` deliberately swallows its own errors so it can
  never disrupt a hook or a status line. The cost of that guarantee is that a
  half-finished install presents as a *blank gauge* rather than a complaint;
  the installer is the one place allowed to be loud about it.
- **`./install.sh --check`** re-runs the verification against an existing
  install without changing anything.
- **An existing `statusLine` is left alone.** The installer reports what it
  found and tells you how to add ccgauge to it, or to hand it over with
  `./install.sh --statusline`. Replacing it by default would have meant the
  documented "keep your own" setup could not survive the documented `git pull
  && ./install.sh` update — every update would silently clobber it again.
  Registration also now sets only the two keys it owns, so sibling keys in an
  existing `statusLine` block survive.
- **`--check` reaches the network no more than `git status` does.** It skips
  the forced refresh and does not execute the hook (which detaches a background
  refresh of its own), reporting cache age instead. It has to stay safe to run
  repeatedly while diagnosing a rate-limit problem — firing a request to
  diagnose a lockout is how you extend one.
- **Backups of `settings.json` are timestamped and written only when something
  actually changes.** A single fixed `settings.json.bak` rewritten on every run
  is a trap: install, notice your status line changed, re-run the installer
  while working out how to undo it, and the second run's backup — now identical
  to the modified file — has destroyed the only copy of your original. Nothing
  now overwrites an existing backup, and a no-op run writes none at all.

- **The installer reports what platform you are on, and refuses macOS.** Claude
  Code stores its OAuth token in the macOS Keychain rather than in
  `~/.claude/.credentials.json`, so there is no file for ccgauge to read and no
  amount of logging in will create one. It now fails outright there with that
  explanation, instead of installing cleanly and leaving a permanently blank
  gauge behind a warning that told you to re-authenticate — advice that could
  never have helped. Windows (Git Bash) installs with a warning that Git for
  Windows is required, since Claude Code falls back to PowerShell without it and
  these are bash scripts. Linux is unchanged. On macOS it exits *before* copying
  or registering anything, rather than installing a gauge that can never
  populate and only then reporting the platform unsupported.

### Removed

- **`statusline-snippet.sh`**, superseded by `statusline.sh`. It was a toy
  example that existed only because the installer would not configure a status
  line itself; shipping both a real one and an example invited exactly the
  confusion of not knowing which one was live.

## [0.8.1] — 2026-07-29

Fixes from an adversarial three-lens review of 0.8.0 (Windows/CRT semantics,
the never-raise/never-hang contract, PowerShell on both engines), every
mechanism re-verified empirically on Windows 11.

### Fixed

- **The `claude --version` probe can no longer hang a prompt past its
  timeout.** `subprocess.run(timeout=5)` is not a hard bound on Windows: on
  timeout it kills the direct child — for an npm install that's the
  `claude.cmd` shim's `cmd.exe` — then re-reads the pipes with *no* timeout,
  and the shim's `node` grandchild, still holding the inherited write
  handles, blocks that read until it exits (reproduced: a stalling shim held
  a "5s" probe for 8s; an AV-wedged one could hold a prompt for a minute).
  The probe now uses `Popen` + `communicate(timeout=5)` and on expiry kills
  and *abandons* — the reader threads are daemonic — falling back to the
  pinned UA.
- **A `claude` binary planted in the project directory is never executed.**
  Hooks run with cwd inside the user's project, and `shutil.which` on
  Windows searches the cwd first on Python < 3.12 (and on 3.12+ where the
  machine config asks for it). A cwd-resolved `claude` is now rejected and
  the probe skipped — the pinned UA beats running untrusted content.
- **One bad cache value can no longer silence the gauge permanently.**
  `hookline` ran `line` and the detached cache-warmer under one exception
  umbrella, so a raise inside `line` (e.g. a cache with a non-numeric
  `fetched_at`, which also crashed the pre-refresh age check — both fixed)
  skipped the warm-refresh too; since `line` raised before ever fetching,
  nothing would ever repair the cache. The two now fail independently,
  matching the two-process POSIX wrapper.
- **`statusline` renders the gauges even when the payload is malformed.**
  A wrong-*typed* field (`"workspace"` as a string, `"context_window"` as a
  list) blanked the entire status line, gauges included, though they need
  nothing from the payload. Every extraction is now type-checked; a bad
  field just doesn't render, as the contract says.
- **`usage.py log` no longer claims "no events recorded yet" when it merely
  lost the lock race** (Windows byte-range locks are mandatory, so an
  unlocked read of a locked log raises). It now says the log is briefly
  unreadable and to retry — and only reports "no events" for a genuinely
  absent log.
- **`.credentials.json` is read as UTF-8 (BOM tolerated)** instead of the
  locale code page, and non-dict JSON in it degrades to "no token" instead
  of an (absorbed) crash. `~`-abbreviation now also survives a trailing
  separator on a hand-set `USERPROFILE`/`HOME`, and declines to abbreviate
  a drive-root HOME. If a stream's UTF-8 reconfigure itself fails, output
  degrades to `?`-for-glyph rather than an invisible encoding error.
- **`install.ps1`: the hook matcher is precise, migrations are loud, and
  bad states fail before the backup is touched.** The old matcher claimed
  any command containing `usage.py` plus ` line` anywhere (reproduced
  destroying an unrelated hook); it now requires the mode as the token
  immediately after `usage.py` (or a trailing `usage-line.sh`). Every
  replaced command is printed. settings.json is validated *before* the
  `.bak` is overwritten, so broken JSON can't clobber a good backup (and
  the error says so, without a traceback). A BOM'd settings.json is read
  correctly (`utf-8-sig`); writes keep LF line endings so a dotfiles-synced
  file doesn't churn to CRLF; a stale ccgauge sibling next to an exact match
  is now also rewritten instead of left to double-inject the `[usage]`
  line; `-LiteralPath` throughout for bracket-safe paths; non-object
  `hooks`/`UserPromptSubmit` shapes are refused cleanly.

### Changed

- **`urllib` is imported only when a fetch actually happens.** It drags in
  the whole `http`/`email` stack — ~80–110 ms, half the start-up of the
  read-only modes on Windows — and `status`/`statusline` run on every
  status-line repaint.

## [0.8.0] — 2026-07-29

### Added

- **Native Windows 11 support.** The same `usage.py`, the same cache files, the
  same `%USERPROFILE%\.claude\.credentials.json` token Claude Code already
  writes on Windows — no WSL, no bash. What it took:
  - **`usage.py hookline`** — the hook in one command: `line`, then a detached
    background `refresh` spawned by `usage.py` itself (`DETACHED_PROCESS` on
    Windows, its own session on POSIX), replacing `usage-line.sh`'s `&`/`disown`
    on platforms that don't have it. This is what the Windows installer
    registers.
  - **`usage.py statusline`** — a complete example status line (cwd, model,
    context bar, usage gauges) rendered from the status-line JSON on stdin.
    One Python process per render; no bash, and none of the ~200 ms a
    PowerShell start-up would cost on every repaint. Works on POSIX too.
  - **`install.ps1`** — the installer as a PowerShell twin of `install.sh`
    (Windows PowerShell 5.1 and pwsh 7+): finds a *working* Python 3 (`python`
    / `py -3` / `python3`, each actually run, because a stock Windows `python`
    is the Microsoft Store stub), copies `usage.py`, and registers the hook
    idempotently with the same `.bak` backup. The generated command uses
    forward slashes and plain double quotes so it parses identically under
    Git Bash and PowerShell — whichever Claude Code picks.
  - **Real locking on Windows.** The refresh lock and the history-log lock,
    previously `fcntl`-only (Windows silently ran unlocked), now fall back to
    `msvcrt` byte-range locks with the same semantics: non-blocking contention
    for the refresh lock, OS-released on process death, and a bounded ~1 s
    retry for the log (past which it degrades to an unlocked append rather
    than stall a prompt). The log lock matters *more* on Windows: POSIX
    `O_APPEND` writes are atomic on their own; the CRT's append emulation is
    a seek-then-write, which isn't.
  - **UTF-8 stdio + ANSI on legacy consoles.** Piped stdout on Windows
    defaults to the ANSI code page (cp1252), which cannot encode `█ ▒ ▓ ░ ⚠`
    — and under the never-raise contract that error would surface as a
    silently blank gauge. `usage.py` now re-encodes piped stdio to UTF-8
    (what Claude Code decodes on every platform) and enables
    virtual-terminal processing on legacy conhost, where Windows Terminal
    needs nothing.
  - **`claude --version` found through its npm shim.** `claude` on Windows is
    typically a `claude.cmd` shim, which a bare `CreateProcess` PATH search
    never finds; the User-Agent probe now resolves the CLI with
    `shutil.which` (honours `PATHEXT`) and runs it with `CREATE_NO_WINDOW`,
    so no console flashes out of the detached refresh.

### Fixed

- **`~`-abbreviation of the hook cwd respects path boundaries and case.**
  `/home/brad` no longer claims `/home/bradley2`'s paths, and on Windows the
  comparison is case-insensitive (a hook cwd of `c:\users\…` still
  abbreviates).
- **A non-object JSON payload on stdin (an array, a bare string) is treated as
  absent** instead of dissolving the readout into a suppressed
  `AttributeError`.

## [0.7.0] — 2026-07-28

### Added

- **Pace shadow on every gauge.** Each bar now draws the point where an
  evenly-paced spend would sit right now, derived from how much of the window
  has elapsed — half-way through the 5-hour window (2.5h in), the mark is at
  50%. It renders as a shadow behind the fill with two extra shades: `▒` is
  pace headroom you haven't spent (you're running ahead), `▓` is spend that has
  run past the mark (orange — you're burning too fast). Only one is ever
  present, and the reading works both ways: `█`+`▓` is what you've used,
  `█`+`▒` is where the mark sits. A percentage alone couldn't tell you whether
  40% used was comfortable or alarming; now the gauge does.

  ```text
  5h [██▒▒▒░░░░░] 20%(2.5h)   half-way in, a fifth spent — three segments of headroom
  5h [████▓▓░░░░] 60%(2.4h)   pace is at 40%, so two segments are past the mark
  5h [█████░░░░░] 50%(2.5h)   exactly on pace: no shadow at all
  ```

  The mark comes from the live clock while the percentage beside it comes from
  the cache, so the two drift apart as the cache ages — and the drift is
  directional: the mark advances while the percentage stands still, so an old
  cache renders *more* headroom than you really have. Because that under-reports
  overspend, the mark is held to a much tighter age budget than the readout as a
  whole, disappearing once the cache is older than one refresh interval
  (`PACE_MAX_AGE`, 10 min) against the 30 minutes it takes to flag the numbers
  themselves as stale. Gating on age also covers the cases where `show`'s forced
  refresh silently returns cache — a 429 cooldown, a contended lock, a rotating
  token — since what matters is how old the percentage is, not why it could not
  be renewed. The mark also disappears once a window's `resets_at` has passed
  rather than clamping to the end of the bar: an elapsed reset means the window
  has rolled over and the cached percentage describes a window that no longer
  exists.

### Changed

- **Bars are sized so one segment is a round slice of wall-clock time.** The
  5-hour bar keeps its 10 segments (half an hour each) and the **7-day bar is
  now 14** (half a day each), so the pace mark reads as a position *in the
  window* rather than just a fraction — a 7d mark on segment 9 means you're into
  the fifth day.
- **The bars are no longer severity-coloured.** They hold the terminal's default
  foreground for `█` and `▒`, and the zones separate by luminance: full block,
  half-tint block, faint block. Orange overspend is the only colour a bar
  introduces, so the one thing that *is* a warning is the only thing that pulls
  the eye. The green/yellow/red ramp still colours the **percentage** beside each
  bar in the non-`plain` mode, so the fullness signal is intact.

  The bar *asserts* that default foreground rather than inheriting the caller's
  colour. Inheriting is tempting — one fewer escape code, and it lets a status
  line theme the bar — but ANSI yellow renders as amber on most themes, so an
  inherited bar under a yellow-wrapped status line is indistinguishable from the
  orange it has to contrast with.
- **Cell arithmetic rounds half away from zero**, where it previously used
  Python's built-in `round` (banker's rounding, ties-to-even). The bar now shows
  two rounded values at once and the eye reads the distance between them, so
  their rounding has to be consistent: under ties-to-even, 45% and 35% both land
  on segment 4 and a full segment of overspend silently disappears. This also
  shifts the standalone `bar <pct>` by one segment for percentages ending in 5
  (`bar 45` is now five segments, not four).
- **Non-finite values no longer render as a full bar.** `min(100.0, nan)` returns
  `100.0` in Python — every comparison against NaN is False, so the running
  minimum survives — which meant the clamp promoted `nan` and `inf` to the worst
  possible reading instead of bounding them. `usage.py bar nan` now draws an
  empty bar, and a non-finite pace draws no mark rather than a mark at zero.
- **`status plain` really does emit no ANSI.** A caller asking for it wants to
  own the colouring, or to measure the fragment's display width to pad and
  truncate it, and either is broken by a stray escape it can neither see nor
  undo. Colour mode is the mirror image and is fully self-contained: every span
  closes itself, so the fragment can be dropped anywhere without leaking state
  into the text after it.
- **`usage.py show` draws bars and states the comparison in words** —
  `Session (5h): [██▒▒▒░░░░░] 20% used — resets in 2h 29m (pace 50%, 30 pts
  under pace)`. Previously it printed no bar at all. It emits ANSI only when
  stdout is a terminal, so redirecting or capturing it still yields clean text,
  and the `Weekly Opus` row gained a bar too so the percentage column stays
  aligned.
- **`usage.py bar <pct> [pace]`** takes an optional second value, so callers
  rendering their own gauge can draw a pace shadow too. Omitted, it stays
  escape-free — Claude Code's context window has no clock, so the status-line
  snippet's `ctx` bar needs none of the scheme's colours.

### Fixed

- **A window whose percentage is missing no longer renders as 0% used.** A
  partial API response leaves one window's `utilization` absent while its
  `resets_at` still lands in the cache; `show` drew a bar for it anyway, and
  since the cell arithmetic coerces `None` to zero the gauge positively asserted
  "nothing spent, all this headroom" about a number it did not have. It now
  prints `no data` for that window.
- **`show` no longer goes silent on an unreadable cache timestamp.** It computed
  the cache age without the `isinstance` guard `status` already used, so a null
  `fetched_at` raised before the first `print` — and the module's never-raise
  contract turned the one command whose whole job is to report status into zero
  output.

## [0.6.1] — 2026-07-26

### Changed
- **The last-refresh `@HH:MM` timestamp is now always on the status line**, not
  only when the readout is stale. Fresh, it trails the reset countdowns
  (`… 27%(3.0d) · @15:38`) so you can see at a glance that the gauge is actually
  updating and how recently; stale, it stays put as the sole time signal (the
  per-window countdowns remain suppressed, since they're derived from cached
  reset times that may already have passed). `fetched_at` is the last successful
  fetch in both cases, so `@HH:MM` reads consistently as "data as of HH:MM".

## [0.6.0] — 2026-07-23

### Fixed
- **No more false `STALE` on the first prompt after a break.** The context line
  printed the cached value while a detached refresh raced it, so returning after
  an idle gap always showed a `⚠ STALE … endpoint unreachable` marker for one
  turn — even though the endpoint was reachable and a good value landed a second
  later. The hook now does a single bounded, self-throttled synchronous fetch
  when (and only when) the cache is already stale, and runs before the
  background refresh so it wins the refresh lock. Active-session prompts still
  read the warm cache with zero added latency.
- **Stale readouts name their real cause.** Instead of labeling every failure
  `endpoint unreachable`, the message now distinguishes a 429 cooldown (with the
  next-retry countdown), an expired or rotating login token (`auth token
  unavailable` — Claude Code renews it on its own), another refresh already in
  flight, and a genuinely unreachable endpoint.
- **No fake-live countdowns on a stale status line.** The per-window reset
  countdowns are computed from cached timestamps that may already have reset, so
  they are now suppressed whenever the readout is stale.

### Added
- **Last-refresh timestamp on stale readouts.** The status line shows `@HH:MM`
  (the wall-clock time of the last successful read) in place of the bare
  `stale`, and the context line's `⚠ STALE Nm` marker gains `(last good HH:MM)`
  — so you can see at a glance how old the number really is.

## [0.5.0] — 2026-07-17

### Fixed
- 429 back-off no longer re-arms the lockout. On a rate-limit the fetch now
  honors the server's `Retry-After` (and `anthropic-ratelimit-*-reset`) header
  when present; absent that, it backs off exponentially (10m, doubling per
  consecutive 429, capped at 2h) instead of retrying on a fixed 10-minute
  clock. A flat retry shorter than the server's penalty kept re-tripping the
  limit and never let the token's usage bucket drain — a persistent 429 loop.

### Added
- 10-segment progress bars in the status fragment (one segment per 10%): each
  value renders as `5h [███░░░░░░░] 31%`, with the percentage shown beside the
  bar rather than inside it, so the number never occludes a segment.
- `usage.py bar <pct>` — renders a standalone 0–100 progress bar, so a status
  line can give Claude Code's own context-window `%` the same bar as 5h/7d.
- `usage.py status plain` — emits the status fragment with no ANSI, so a
  status-line snippet can render the whole thing in a single colour of its
  choosing. The default (coloured, per-window severity) output is unchanged.

### Changed
- Refetch TTL raised 180s → 600s: this is background telemetry with a low
  natural request rate, so a longer window means fewer calls against the
  shared per-token usage budget.
- Staleness is now stated, not hinted: the cryptic dim `?` marker becomes the
  word `stale`, and both the context line (`line`) and the human block (`show`)
  spell out that a stale value is the last successful read and NOT current —
  including, on `show`, when the endpoint is rate-limited and when the next
  retry is due. Keeps a frozen readout from being mistaken for a live one.

## [0.4.0] — 2026-07-17

### Added
- Status-line countdowns: the `usage.py status` fragment now shows the time
  until each window resets — `5h:69%(0.6h)` and `7d:19%(2.6d)` — rendered
  dim next to the colour-coded utilization, still reading only the cache.
  Countdowns round *up* to one decimal, so a window that hasn't reset never
  displays `0.0`.

## [0.3.0] — 2026-07-16

### Changed
- Replaced the 80% `⚠ AT N%` warning marker (redundant with Claude Code's
  native limit warnings) with a wind-down directive at ≥95% of the 5-hour
  session window. The context line now instructs the assistant to: offer to
  queue work for after the reset, suggest `/compact` before the pause, and
  start a background sleep — duration computed from the cached `resets_at` —
  that wakes the session ~1 minute after the window resets. Suppressed while
  the cache is stale, since an old percentage may describe an already-reset
  window.

## [0.2.0] — 2026-07-16

### Added
- Usage history log (`~/.claude/usage-log.jsonl`): one JSONL event per hook
  firing (`prompt`, with the percentages, cache age, cwd, and session id from
  the hook payload — never the prompt text), per successful fetch (`fetch`),
  and per rate-limit hit (`cooldown_429`). Self-trims at ~1 MiB to the newest
  ~4000 events; writes are best-effort and silent on failure.
- `usage.py log [N]` — human-readable view of the last N events (default 20).

## [0.1.0] — 2026-06-23

Initial release — an ambient fuel gauge for your Claude Max plan.

### Added
- `usage.py`: queries the undocumented `/api/oauth/usage` endpoint with the
  OAuth token Claude Code already stores on disk, caches the 5-hour-session and
  7-day-weekly utilisation to a single JSON file, and self-throttles (180s TTL,
  600s cooldown after any 429). Never raises — every path degrades to silence.
- A `UserPromptSubmit` hook (`hooks/usage-line.sh`) that injects the usage
  snapshot into the assistant's context each turn and refreshes in a detached
  background process, so prompts never wait on the network.
- A status-line fragment (`usage.py status`) showing colour-coded `5h:X% 7d:Y%`.
- Dynamic `User-Agent` derived from the installed CLI (`claude --version`) with
  a pinned fallback, so it tracks Claude Code updates automatically.
- A visible staleness marker: a dim `?` on the status line and a `⚠ STALE`
  notice on the context line once cached data is older than 30 minutes, so a
  frozen readout never masquerades as a current one.
- `install.sh` (idempotent hook registration with a `settings.json` backup),
  a `statusline-snippet.sh` example, and a design-oriented README.

[0.1.0]: https://github.com/pizzimenti/ccgauge/releases/tag/v0.1.0

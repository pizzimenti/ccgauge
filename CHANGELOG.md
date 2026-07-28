# Changelog

All notable changes to ccgauge are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); this project uses
[Semantic Versioning](https://semver.org/).

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

  ```
  5h [██▒▒▒░░░░░] 20%(2.5h)   half-way in, a fifth spent — three segments of headroom
  5h [████▓▓░░░░] 60%(2.4h)   pace is at 40%, so two segments are past the mark
  5h [█████░░░░░] 50%(2.5h)   exactly on pace: no shadow at all
  ```

  The shadow is suppressed whenever the readout goes stale, alongside the
  per-window countdowns and for the same reason: the mark comes from a live
  clock, and measuring it against a frozen percentage would manufacture
  overspend that isn't there.

### Changed
- **The bars are no longer severity-coloured.** They set no colour for `█` and
  `▒` at all, so they inherit whatever the terminal — or the status line
  wrapping them — is already using, and the zones separate by luminance: full
  block, half-tint block, faint block. Orange overspend is the only colour a
  bar introduces, so the one thing that *is* a warning is the only thing that
  pulls the eye. The green/yellow/red ramp still colours the **percentage**
  beside each bar in the non-`plain` mode, so the fullness signal is intact.
- **`status plain` now governs the text only.** It leaves the label, percentage
  and countdown uncoloured for a caller that paints the fragment one hue, but
  the bar still carries its dim tail and orange overspend, because those encode
  which segments are unearned and which are overspend — data the caller has no
  way to reconstruct. Previously `plain` stripped them, which meant a status
  line using it saw the pace shadow in a single flat colour and could not read
  it at all.
- **`usage.py show` states the comparison in words** as well as drawing the
  bar — `Session (5h): [██▒▒▒░░░░░] 20% used — resets in 2h 29m (pace 50%,
  30 pts under pace)`. Previously `show` printed no bar at all.
- **`usage.py bar <pct> [pace]`** takes an optional second value, so callers
  rendering their own gauge can draw a pace shadow too. Omitted, the bar is
  byte-identical to before — Claude Code's context window has no clock, so the
  status-line snippet's `ctx` bar is unchanged.

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

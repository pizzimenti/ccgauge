# Changelog

All notable changes to ccgauge are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); this project uses
[Semantic Versioning](https://semver.org/).

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

# Changelog

All notable changes to ccgauge are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); this project uses
[Semantic Versioning](https://semver.org/).

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

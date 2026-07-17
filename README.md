# ccgauge

A fuel gauge for your Claude Max plan.

`ccgauge` surfaces the same **5-hour session** and **7-day weekly** usage that
Claude Code's `/usage` command shows — but continuously, in two places:

- **On your status line**, as a live `5h:11%(3.7h) 7d:3%(5.2d)` readout —
  colour-coded utilization with a countdown to each window's reset.
- **In the assistant's context**, injected each turn via a `UserPromptSubmit`
  hook, so Claude itself can warn you as you approach a limit.

It reads the OAuth token Claude Code already stores on disk, queries the
(undocumented) usage endpoint, and caches the result. No API key, no password,
no browser — and the token never leaves your machine.

```
~ ctx:10% Opus 4.8 (1M context) 5h:11%(3.7h) 7d:3%(5.2d)
                                 └──────────────────────┘ ccgauge
```

## Why

On a subscription plan, the only built-in way to see how much of your rolling
window you've burned is to stop and type `/usage`. ccgauge makes it ambient:
you see it without asking, and the assistant can proactively flag it.

## Install

```sh
git clone https://github.com/pizzimenti/ccgauge ~/Code/ccgauge
cd ~/Code/ccgauge
./install.sh
```

The installer copies `usage.py` and `hooks/usage-line.sh` into your Claude
config dir (`~/.claude`, or `$CLAUDE_CONFIG_DIR`), and registers the
`UserPromptSubmit` hook in `settings.json` (idempotently, with a `.bak`
backup). Then:

1. **Verify:** `python3 ~/.claude/usage.py show`
2. **Status line:** append the usage fragment to your status line — see
   [`statusline-snippet.sh`](./statusline-snippet.sh). The one call you add,
   `python3 ~/.claude/usage.py status`, only reads the cache, so it is safe to
   run on every render.
3. **Restart** Claude Code (or start a new session) so the hook loads.

Requires `python3` (standard library only — no `pip install`, no `jq`).

## How it works

A walkthrough from the wire to the glass.

### The data source

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
User-Agent: claude-code/<version>
```

Three things make this work:

- **The token** is read from `~/.claude/.credentials.json` →
  `.claudeAiOauth.accessToken`. It's the OAuth token from your *browser* login,
  which carries the `user:profile` scope this endpoint requires. (A token from
  `claude setup-token` has only `user:inference` and will be rejected.)
- **The `anthropic-beta` header** gates the OAuth API surface.
- **The `User-Agent`** is load-bearing: without a `claude-code/*` UA you land in
  an aggressive rate-limit bucket that 429s persistently. ccgauge derives it from
  the installed CLI (`claude --version`) at runtime, falling back to a pinned
  default if that can't be read — so it tracks Claude Code updates automatically.

The response is small:

```json
{"five_hour": {"utilization": 11.0, "resets_at": "2026-06-23T...Z"},
 "seven_day": {"utilization": 3.0,  "resets_at": "2026-06-28T...Z"}}
```

`utilization` is a 0–100 float. That's the whole contract.

### One writer, many readers

```
        api.anthropic.com/api/oauth/usage
                     ▲  GET, at most every 180s
                     │
              ┌──────┴───────┐
              │   usage.py    │  the ONLY component that touches the
              │ fetch·cache·  │  network or reads the token
              │   throttle    │
              └──────┬───────┘
                     │ writes
            ~/.claude/usage-cache.json   ◄── single source of truth
                     │ reads (no network)
        ┌────────────┼────────────┐
   usage.py line  usage.py status  usage.py show
        │             │              │
  UserPromptSubmit  status line    on demand
   hook → context   → terminal
```

The key decision: **exactly one code path writes; everything else reads a cache
file.** The status line renders constantly, but reading the cache never hits the
network — so high-frequency surfaces can't melt the rate limit.

### Rate-limit safety

`usage.py refresh` is a series of cheap early-exits before the expensive call:

1. cache younger than `TTL_SECONDS` (180s) → serve cache, no network
2. inside a 429 cooldown → serve cache, no network
3. token missing or about to expire → serve cache
4. otherwise: `GET` (6s timeout)
   - `200` → normalise, write cache, clear cooldown
   - `429` → write a `COOLDOWN_SECONDS` (600s) backoff marker
   - anything else → leave cache untouched

The cache file's *mtime* is the TTL clock; a tiny `usage-429-cooldown` marker
file governs backoff. Because 429s here persist and worsen under retries, the
response to one is to **stop entirely** for the cooldown, not to retry.

### Two display paths

- **Into the assistant's context.** `hooks/usage-line.sh` is a `UserPromptSubmit`
  hook; Claude Code appends its stdout to the model's context before each turn.
  The script kicks off a *detached* background refresh (so your prompt never
  waits on the network) and prints the currently-cached snapshot. Consequence:
  the number can be one turn stale — fine for a 5-hour window, and worth it for
  zero latency.
- **Onto the status line.** `usage.py status` prints a short coloured
  `5h:X%(X.Yh) 7d:Y%(X.Yd)` fragment — utilization colour-coded (green < 70,
  yellow < 90, red ≥ 90), each followed by a dim countdown to that window's
  reset — reading only the cache.

If the cache ever stops updating (e.g. the endpoint becomes unreachable), the
readout doesn't silently keep showing a frozen number: once data is older than
`STALE_SECONDS` (30 min), the status line appends a dim `?` and the context line
says `⚠ STALE: last fetched Nm ago`. Stale is visibly distinct from fresh.

### Usage history log

Every hook firing and every successful fetch appends one JSON line to
`~/.claude/usage-log.jsonl`, so you can reconstruct where usage stood, when you
were prompting, and from which project:

```json
{"ts": "2026-07-16T14:41:23-07:00", "event": "prompt", "five_hour_pct": 31,
 "seven_day_pct": 5, "cache_age_s": 308, "cwd": "~/Code/ccgauge", "session_id": "..."}
```

Three event types: `prompt` (the `UserPromptSubmit` hook fired — one per turn,
with the cwd and session id Claude Code passes to the hook), `fetch` (new data
actually landed in the cache), and `cooldown_429` (the endpoint rate-limited
us — a history of these is how you'd notice UA/header drift). The prompt *text*
is never logged. View it with:

```sh
python3 ~/.claude/usage.py log        # last 20 events
python3 ~/.claude/usage.py log 200    # last 200
```

The log self-trims (at ~1 MiB it keeps the newest ~4000 events), and — like
everything else here — a failed write is silent.

### Wind-down behavior

Claude Code already warns natively as you approach a limit, so a bare
"you're at N%" from ccgauge would be redundant. Instead, once the **session
(5h) window reaches 95%** (and the cached data is fresh), `usage.py line`
appends a wind-down directive instructing the assistant to:

1. **Queue** — offer you the chance to cue up work for after the reset.
2. **Compact** — suggest `/compact`, so the post-reset session resumes lean.
3. **Alarm** — start the specified `sleep` (duration computed from the
   cached `resets_at`, +60s) as a *harness-tracked background task* —
   Claude Code's `run_in_background` Bash, whose completion notification
   re-invokes the assistant — not a detached shell child, which nothing
   observes. The session wakes ~1 minute after the reset and picks up the
   queued work.

The hook delivers the *directive*; your `CLAUDE.md` makes it *policy*. Add a
standing note, for example:

> A `UserPromptSubmit` hook injects a `[usage] …` line each turn. Below 95%
> it is background telemetry — stay quiet about it unless I ask, and do
> **not** silently change how you work based on the number. When the line
> carries a `⚠ SESSION AT N% — wind down` directive, follow its three steps:
> offer to queue work for after the reset, suggest `/compact`, and start the
> background sleep it specifies, resuming the queued work when it fires.

The directive is suppressed while the cache is stale — an old percentage may
describe a window that has already reset.

## Design properties

| Property | Why |
| --- | --- |
| One writer, N readers | High-frequency surfaces never cause network calls. |
| `mtime` as the TTL clock | No extra state file; survives restarts. |
| Never throws | A telemetry gadget must never break a hook or status line. Worst case: it shows nothing. |
| Detached background refresh | Zero prompt latency; accept one-turn staleness. |
| python3, not jq | `jq` is often missing; python3 is always present, with real JSON + datetime handling. |
| Secret stays in the worker | The token is read by `usage.py` and used only in the request to Anthropic's own API. The cache holds only percentages and reset times. |

## Failure modes

Every failure degrades to silence, never a crash or a stall:

| Failure | Behavior |
| --- | --- |
| Token expired | Serve stale cache; Claude Code refreshes the token during normal use. |
| 429 rate-limited | Write 600s cooldown, serve stale cache, stop polling. |
| Network down / timeout | Serve last known cache. |
| Endpoint removed / header rejected | Cache ages out; `line` prints "unavailable". |
| Malformed upstream JSON | `line`/`status` print nothing rather than crash. |
| History log unwritable | Silent — the readout is unaffected. |

## Caveats

This rests on an **undocumented, reverse-engineered endpoint** that Anthropic
has declined to officially support. It can break on any update. The most likely
break point is the `anthropic-beta` date header (the `User-Agent` is now derived
from the installed CLI). If usage goes stale — you'll see the `?` / `⚠ STALE`
marker — check that header first. The whole design degrades silently, so a break
costs you a blank or visibly-stale readout, nothing more.

Not affiliated with or endorsed by Anthropic.

## License

MIT — see [LICENSE](./LICENSE).

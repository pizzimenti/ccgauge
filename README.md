# ccgauge

A fuel gauge for your Claude Max plan.

`ccgauge` surfaces the same **5-hour session** and **7-day weekly** usage that
Claude Code's `/usage` command shows — but continuously, in two places:

- **On your status line**, as a live
  `5h [█▒▒░░░░░░░] 11%(3.7h) · 7d [▒▒▒▒░░░░░░░░░░] 3%(5.2d) · @15:38` readout — a
  progress bar per window with the percentage beside it, colour-coded,
  a pace shadow showing whether you're ahead of or behind the window's refill
  rate, a countdown to each window's reset, and the time it was last refreshed.
- **In the assistant's context**, injected each turn via a `UserPromptSubmit`
  hook, so Claude itself can warn you as you approach a limit.

It reads the OAuth token Claude Code already stores on disk, queries the
(undocumented) usage endpoint, and caches the result. No API key, no password,
no browser — and the token never leaves your machine.

```text
~ ctx:10% Opus 4.8 (1M context) 5h [█▒▒░░░░░░░] 11%(3.7h) 7d [▒▒▒▒░░░░░░░░░░] 3%(5.2d)
                                 └──────────────────────────────────────────────────┘ ccgauge
```

## Why

On a subscription plan, the only built-in way to see how much of your rolling
window you've burned is to stop and type `/usage`. ccgauge makes it ambient:
you see it without asking, and the assistant can proactively flag it.

## Install

Requires Python 3.7+ (standard library only — no `pip install`, no `jq`).

### Platform support

| | |
| :-- | :-- |
| **Linux** | Supported and developed on. Use `install.sh`. |
| **Windows 11** | Supported natively. Use `install.ps1` — see below. |
| **macOS** | **Not supported.** Claude Code stores its OAuth token in the macOS Keychain rather than in `~/.claude/.credentials.json` ([docs](https://code.claude.com/docs/en/authentication)), so there is no file for ccgauge to read and no amount of logging in will create one. Reading the Keychain isn't implemented, so `install.sh` refuses to run there rather than leaving a gauge that can never populate. |

### Linux

```sh
git clone https://github.com/pizzimenti/ccgauge ~/Code/ccgauge
cd ~/Code/ccgauge
./install.sh
```

That's the whole install. Restart Claude Code (or start a new session) and both
halves are live.

#### What it installs

The installer copies three files into your Claude config dir (`~/.claude`, or
`$CLAUDE_CONFIG_DIR`) and registers both of them in `settings.json`,
idempotently and with a timestamped backup:

| | |
| :-- | :-- |
| `usage.py` | the probe and renderer |
| `hooks/usage-line.sh` | the `UserPromptSubmit` hook — puts usage in the assistant's context |
| `statusline.sh` | the status line — puts the gauges on your screen |

**Then it proves the install works**, and exits non-zero with a specific message
if any part of it doesn't: that the files are present and executable, that
`usage.py` runs, that every one of its modes exits cleanly, that `settings.json`
is still valid JSON with both entries registered, and that the hook and status
line each render real output. Only credentials and network reachability are
treated as warnings, since neither a container nor a logged-out CLI is a broken
install.

That verification is the point. `usage.py` deliberately swallows its own errors
so it can never disrupt a hook or a status line, which means a half-finished
install shows up as a *blank gauge* rather than a complaint. The installer is
the one place allowed to be loud.

```sh
git pull && ./install.sh    # update — same command
./install.sh --check        # verify; makes no network call and mutates nothing
```

`--check` is safe to run repeatedly, including while you're diagnosing a
rate-limit problem: it skips the two things that would reach the endpoint (the
forced refresh, and executing the hook — which detaches a background refresh of
its own), and reports cache age instead. Firing a request to diagnose a lockout
is how you extend one.

#### If you already have a status line

**The installer replaces it.** An install is an install: ccgauge installs its
own status line, so the gauges look the same on every machine and after every
update. That consistency is the whole of what this tool is for, and it is not
worth trading for a flag.

What you had is not lost. Anything about to be overwritten is backed up first —
`settings.json` and the status line both, to timestamped files — and **no backup
ever overwrites an older one**, so running the installer twice cannot destroy
the copy that mattered. To go back, restore the newest `settings.json.*.bak`.

If you want ccgauge's numbers inside a status line of your own, don't fight the
installer for the slot — build your script, then point `statusLine` at it
yourself in `settings.json` and skip re-running the installer, or call ccgauge
from it:

```sh
python3 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/usage.py" status
```

That call only reads ccgauge's cache — no network — so it is safe to run on
every render. Use `status plain` instead if you want to colour the fragment
yourself; it emits no ANSI at all. Either way,
[`statusline.sh`](./statusline.sh) is a working reference.

There are two complete status lines in the repo, for two different reasons.
`statusline.sh` is the POSIX one this installer wires up: a shell script, so it
can pick up the git branch without a second process. `usage.py statusline` is
the Windows one, rendering the same information in a single Python process
because Windows has no bash to rely on. Use whichever matches your platform;
`install.sh` and `install.ps1` each pick the right one for you.

### Windows 11

```powershell
git clone https://github.com/pizzimenti/ccgauge $env:USERPROFILE\Code\ccgauge
cd $env:USERPROFILE\Code\ccgauge
powershell -ExecutionPolicy Bypass -File install.ps1
```

The installer finds a working Python 3 (`python`, `py -3`, or `python3`,
each *run* to verify it — a stock Windows `python` is the Microsoft Store
stub), copies `usage.py` into `%USERPROFILE%\.claude` (or
`$env:CLAUDE_CONFIG_DIR`), and registers the hook as

```text
python "C:/Users/you/.claude/usage.py" hookline
```

`hookline` is `line` plus the detached cache-warming `refresh` — everything
`usage-line.sh` does, with no bash on the path. The forward slashes are
deliberate: Claude Code on Windows runs hook and status-line commands through
Git Bash when it is installed and PowerShell otherwise, and that spelling
survives both. Re-running the installer is safe: an existing ccgauge
registration — including a POSIX `usage-line.sh` one from a synced
settings.json — is rewritten in place (and each replacement is printed)
rather than accumulating duplicates. Then:

1. **Verify:** `python "$env:USERPROFILE\.claude\usage.py" show` — substitute
   the interpreter the installer said it picked (`py -3` on machines where
   `python` is only the Store stub); its final output shows the exact command.
2. **Status line:** `usage.py statusline` renders a complete example status
   line — cwd, model, context bar, usage gauges — from the JSON Claude Code
   pipes in, one Python process per render:

   ```json
   "statusLine": { "type": "command",
                   "command": "python \"C:/Users/you/.claude/usage.py\" statusline" }
   ```

   Already have a status line? Append a `usage.py status` call to it instead.
3. **Restart** Claude Code (or start a new session) so the hook loads.

The cache, the credentials discovery, and the history log live in
`%USERPROFILE%\.claude` exactly as on Linux — Claude Code stores its OAuth
token in the same `.credentials.json` there. Gauges render in Windows
Terminal (the Win11 default) as-is; on a legacy conhost, `usage.py` switches
on virtual-terminal processing itself.

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
  `.claudeAiOauth.accessToken` (on Windows the same file under
  `%USERPROFILE%\.claude`). It's the OAuth token from your *browser* login,
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
                     ▲  GET, at most every 600s
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

1. cache younger than `TTL_SECONDS` (600s) → serve cache, no network
2. inside a 429 cooldown → serve cache, no network
3. token missing or about to expire → serve cache
4. otherwise: `GET` (6s timeout)
   - `200` → normalise, write cache, clear cooldown
   - `429` → write a backoff marker — its duration is the server's `Retry-After`
     (or `anthropic-ratelimit-*-reset`) header when present, else an exponential
     backoff (`BACKOFF_BASE` 600s, doubling per consecutive 429, capped at
     `BACKOFF_CAP` 2h)
   - anything else → leave cache untouched

The cache file's *mtime* is the TTL clock; a tiny `usage-429-cooldown` marker
(JSON: the backoff-until time and a consecutive-429 count) governs backoff.
Because 429s here persist and *worsen* under retries — a fixed short retry keeps
re-arming the lockout, so the token's usage bucket never drains — the response
is to wait out the server's stated cooldown, and to back off exponentially when
it states none, rather than retry on a fixed clock.

### Two display paths

- **Into the assistant's context.** `hooks/usage-line.sh` is a `UserPromptSubmit`
  hook; Claude Code appends its stdout to the model's context before each turn.
  It prints the cached snapshot — instantly, with no network wait, whenever the
  cache is still within its TTL — then kicks off a *detached* background refresh
  to keep the cache fresh for the next turn. The one exception: if the cache is
  already past the TTL (the first prompt after any idle gap), it does a single
  bounded, self-throttled synchronous fetch first, so you see live numbers
  instead of a readout that a refresh would replace one turn later. That
  exception is what keeps the line honest — it lands in context *before* the
  background refresh runs, so without it the number shown would always be one
  turn behind. It does not raise the request rate: the synchronous fetch obeys
  the same TTL, 429 cooldown and lock as any other, so the ceiling stays one
  request per TTL. (On Windows
  the registered hook is `usage.py hookline` — the same two steps, print then
  detached warm-refresh, with the detachment done by `usage.py` itself instead
  of a bash `&`.)
- **Onto the status line.** `usage.py status` prints a short
  `5h [█▒▒░░░░░░░] 11%(3.7h) · 7d [▒▒▒▒░░░░░░░░░░] 3%(5.2d) · @15:38` fragment —
  a progress bar per window with the percentage beside it, colour-coded
  (green < 70, yellow < 90, red ≥ 90), each followed by a dim countdown to that
  window's reset, then a trailing dim `@HH:MM` marking when the shown numbers
  were last refreshed — reading only the cache. `usage.py bar <pct> [pace]`
  renders a standalone bar for any 0–100 value, handy for giving Claude Code's
  own context-window `%` the same treatment.

  **Segment counts are chosen so one segment is a round slice of wall-clock
  time**: the 5-hour bar has 10 segments, half an hour each; the 7-day bar has
  14, half a day each. That makes the pace mark readable as a position *in the
  window* rather than just a fraction — a 7d mark on segment 9 means you're into
  the fifth day.

  **`usage.py status plain` emits no ANSI whatsoever**, so a caller can paint the
  fragment a hue of its own or measure its display width to pad and truncate it.
  Colour mode is the mirror image: every span closes itself, so the fragment can
  be dropped anywhere without leaking state into the text after it. The **bar is
  never severity-coloured** in either mode — see [the pace shadow](#the-pace-shadow).

If the cache still can't refresh (the endpoint is genuinely unreachable, the
login token is mid-rotation, or a 429 cooldown is active), the readout doesn't
silently keep showing a frozen number: once data is older than `STALE_SECONDS`
(30 min), the status line drops the per-window countdowns — they're derived from
cached reset times that may already have passed — and leans
on that always-present `@HH:MM` last-refresh marker as the sole time signal, while
the context line spells out both the cause — `endpoint unreachable`, `auth token
unavailable`, or `rate-limited (429) — next retry in Xm` — and that the shown
values are the last successful read, NOT current. Stale is visibly distinct from
fresh.

### The pace shadow

A percentage alone doesn't tell you whether you're *spending too fast* — 40% used
is comfortable three hours into the 5-hour window and alarming twenty minutes in.
So each bar also carries a **pace mark**: the point where an evenly-paced spend
would sit right now, given how much of the window has already elapsed. Half-way
through the 5-hour window (2.5h in), the pace mark is at 50% — half the gauge.

The mark is drawn as a shadow *behind* the fill, using two extra shades:

| | Meaning | Rendered as |
| :-- | :-- | :-- |
| `█` | Spend that is **within** pace | terminal's default foreground |
| `▒` | Pace headroom you **haven't** spent — you're running ahead | terminal's default foreground (the glyph is its own light tint) |
| `▓` | Spend that has run **past** the mark — you're burning too fast | **orange** |
| `░` | Neither spent nor yet earned | dim |

Only one of `▒`/`▓` is ever present, and the reading works both directions:
`█`+`▓` is always what you've used, `█`+`▒` is always where the pace mark sits.

```text
5h [██▒▒▒░░░░░] 20%(2.5h)   half-way in, only a fifth spent — three segments of headroom
5h [████▓▓░░░░] 60%(2.4h)   pace is at 40%, so two segments are past the mark
5h [█████░░░░░] 50%(2.5h)   exactly on pace: no shadow at all
```

Cell arithmetic rounds **half away from zero**, not with Python's built-in `round`
(which is banker's rounding, ties-to-even). The bar shows two rounded values at
once and the eye reads the *distance* between them, so their rounding has to be
consistent: under ties-to-even, 45% and 35% both land on segment 4 and a full
segment of overspend silently disappears.

### Why the bar is calm

The bar deliberately **does not** paint itself green/yellow/red. It holds the
terminal's default foreground for `█` and `▒`, and the four zones separate by
*luminance* instead: a full block, a half-tint block, a faint block. That's a
clean ramp in whatever colour the terminal is already using.

Which leaves orange as the single colour the bar introduces, so the one thing that
*is* a warning is the only thing that pulls your eye. The alternative — colouring
the whole bar by severity — spends colour on the thing the bar's own length already
tells you, and then has nothing distinctive left for the overspend.

Orange comes from the 256-colour cube (`38;5;208`) rather than a bright red or
magenta out of the 16-colour set. Those resolve to whatever the user's theme decides
they mean: some themes alias bright back to normal, landing the tint on a colour
already on screen, and Solarized remaps bright red to orange outright. `208` is a
fixed point and lands identically everywhere. The usual objection to it — that
orange sits next to the yellow severity band — doesn't apply, because there is no
yellow in the bar.

It also asserts that default foreground rather than inheriting the caller's colour.
Inheriting is tempting — one fewer escape code, and it lets a status line theme the
bar — but ANSI yellow renders as amber on most themes, so an inherited bar under a
yellow-wrapped status line becomes indistinguishable from the orange it has to
contrast with.

Every escape the bar emits is an *absolute* SGR state, because ANSI has no
save/restore: `39m` means "default foreground", not "whatever you had", and `22m`
means "normal intensity", not "the intensity you were at". So a coloured bar closes
with a full reset and is self-contained, and a caller that needs to own the
colouring — or to measure the fragment's display width — asks for `status plain`,
which emits nothing at all.

`usage.py show` spells the same comparison out in words (`(pace 50%, 30 pts under
pace)`).

### When the mark is not drawn

The mark comes from the live clock while the percentage beside it comes from the
cache, so the two drift apart as the cache ages — and **the drift is directional**.
The mark advances while the percentage stands still, so an old cache renders *more*
`▒` headroom than you really have. It under-reports overspend, which is the
dangerous direction, so the mark is held to a much tighter age budget than the
readout as a whole: it disappears once the cache is older than one refresh interval
(`PACE_MAX_AGE`, 10 min — about a third of a segment of drift on the 5-hour window),
against the 30 minutes it takes to flag the numbers themselves as stale.

Gating on age rather than on any particular refresh failure also covers the cases
where `show`'s forced refresh silently returns cache — a 429 cooldown, a contended
lock, a rotating token. What matters for the mark is how old the percentage is, not
why it couldn't be renewed.

The mark also disappears entirely once a window's `resets_at` has **passed**, rather
than being clamped to the end of the bar. An elapsed reset means the window has
rolled over and the cached percentage describes a window that no longer exists;
clamping would draw a nearly-full bar with a sliver of headroom at the exact moment
the truth is a fresh window with everything still to spend.

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
| Synchronous fetch only when stale | Warm-cache turns stay zero-latency; only the first prompt after an idle gap pays a bounded fetch, and it shows live numbers rather than a one-turn-stale value. |
| Python, not jq | `jq` is often missing; Python is always present, with real JSON + datetime handling — and it is the one interpreter this needs on Linux, macOS and Windows alike. |
| Secret stays in the worker | The token is read by `usage.py` and used only in the request to Anthropic's own API. The cache holds only percentages and reset times. |

## Failure modes

Every failure degrades to silence, never a crash or a stall:

| Failure | Behavior |
| --- | --- |
| Token expired | Serve last read, marked `auth token unavailable`; Claude Code refreshes the token during normal use. |
| 429 rate-limited | Honor `Retry-After` (else exponential backoff, capped 2h); serve last read, marked `rate-limited (429)` with the retry countdown; stop polling until it clears. |
| Network down / timeout | Serve last read, marked `endpoint unreachable`. |
| Endpoint removed / header rejected | Cache ages out; `line` prints "unavailable". |
| Malformed upstream JSON | `line`/`status` print nothing rather than crash. |
| History log unwritable | Silent — the readout is unaffected. |

## Caveats

This rests on an **undocumented, reverse-engineered endpoint** that Anthropic
has declined to officially support. It can break on any update. The most likely
break point is the `anthropic-beta` date header (the `User-Agent` is now derived
from the installed CLI). If usage goes stale — you'll see the `@HH:MM` / `⚠ STALE`
marker — check that header first. The whole design degrades silently, so a break
costs you a blank or visibly-stale readout, nothing more.

Not affiliated with or endorsed by Anthropic.

## License

MIT — see [LICENSE](./LICENSE).

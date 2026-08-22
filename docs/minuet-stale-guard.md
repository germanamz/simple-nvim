# Stale AI ghost text

Reported symptom: *"the debounce is not working, and even if I just stop typing, a
previous call to the model responds and gets placed as the suggestion instead of
the more recent call."*

In practice the screen showed things like `    returnrn a - b` — a completion
computed for `    retu` painted at the end of a line that by then read
`    return` — and it stayed there.

Two defects in minuet's virtualtext frontend combine to produce that, plus a third
that matches the report's wording literally. All line numbers are
`~/.local/share/nvim/lazy/minuet-ai.nvim/lua/minuet/virtualtext.lua` at the pinned
commit `d29dec4`.

## A — the response is painted without checking the buffer

`trigger()` stamps `internal.current_completion_timestamp` (`:249`) and its
callback compares only that stamp (`:252`). That answers *"was I superseded by a
newer request?"* — never *"did the buffer change while I was in flight?"* There is
no changedtick check and no cursor check, while `update_preview` anchors the
extmark at the **live** cursor (`:166-167`, written at `:189`).

minuet's own newer frontend does the missing check: `duet/init.lua:73` compares
`utils.get_changedtick(bufnr)` and discards on mismatch. virtualtext has no
equivalent.

## B — the throttle has no trailing edge

`schedule()` (`:288-292`) early-returns while throttled *before* `stop_timer()` and
*before* arming the debounce, so keystrokes inside the window are **discarded, not
deferred**. `schedule()` is reachable only from `:472` (InsertEnter) and `:495`
(CursorMovedI). `autocmd.on_cursor_hold_i` exists at `:499` but is **never
registered**, so nothing rescues them.

Stop typing mid-window and no corrective request is ever issued. Measured: 18 of
40 keystrokes dropped, and a misaligned suggestion left on screen for 7.1s.

## C — an empty response repaints the previous suggestion

At `:263` the `if next(data)` guard covers only the assignment; `update_preview` at
`:271` runs unconditionally. So when the *newer* request returns an empty list,
`ctx.suggestions` still holds the *older* request's text and it is repainted —
verbatim "a previous call gets placed as the suggestion instead of the more recent
call."

Empty payloads are routine, not exotic: `utils.lua:564` rejects a stop-token hit
that produced no text, `utils.lua:372` drops whitespace-only items, and the
`FIM_STOP` list in `lua/plugins/minuet.lua` includes `<|endoftext|>`, which a base
model emits the moment a statement is complete.

Contributing: `cleanup()` (`:199-204`) never resets
`current_completion_timestamp`, so a request in flight when you leave insert mode
still passes the stamp guard and writes into `ctx`.

## Why the stamp guard never saves us

`current_completion_timestamp` is written in exactly one place (`:249`), and
`schedule()` cannot fire a second trigger sooner than `throttle + debounce`. So the
stamp guard can only reject a response whose round trip **exceeds that sum**.

Measured against this config's local Ollama, the round trip is bimodal — median
433 ms, p90 1058 ms, max 1572 ms. Against stock `1000 + 400` the guard is
unreachable for roughly 96% of requests. Not unlucky: structurally unreachable.

This is why a *fast* local model makes the bug **more** frequent than a slow cloud
one. A cloud provider at 2-3s exceeds the threshold, so the next keystroke bumps
the stamp before the response lands and the stale result is correctly discarded
with `Completion items arrived, but too late, aborted`. Ollama never gets there.

minuet's defaults are sized as cost/rate-limit controls for paid APIs — its README
frames them as "increase to reduce costs and avoid rate limits" — and its own
"local model" preset uses `throttle = 400, debounce = 100`. That guidance just
does not appear in the Ollama quickstart this config was built from.

## The fix

Both halves are required, and shipping either alone is worse than shipping both:

| | fixes | leaves |
|---|---|---|
| `throttle = 0` alone | the suggestion self-corrects | ~682 ms of visible garbage per burst (measured 4 misaligned renders of 7) |
| guard alone | nothing wrong is painted | keystrokes still dropped → silence instead of suggestions |

**Pacing** — `lua/plugins/minuet.lua` sets `throttle = 0, debounce = 150`.
`throttle = 0` restores the trailing edge; it is not literally off, since `:309-312`
has no `> 0` short-circuit (unlike `blink.lua:49`), but one event-loop tick is the
intent. `debounce = 150` measured 5 requests / 0 misaligned over a 40-key run;
`75` (copilot's value) measured 29 requests with 22 SIGTERM cancellations for no
accuracy gain. Keep the debounce well under the 433 ms round-trip median — raising
it back toward the round trip is what reopens the stale window.

**Freshness guard** — `lua/config/minuet_guard.lua` wraps
`minuet.backends.openai_fim_compatible.complete`, snapshots buffer / window /
changedtick / cursor / mode-family per request, and on response drops anything
that moved. Stale results are dropped by **returning**, never by calling back with
`{}` — an empty payload lands on the `:271` path and would manufacture defect C.
Empty responses are routed to `action.dismiss()` instead, which covers C. Comparing
mode families covers the Esc-mid-flight path.

## Cost and safety

Higher request rates are safe against this Ollama: `common.terminate_all_jobs()`
runs at the head of every FIM request, so at most one job is in flight, and SIGTERM
frees the `-np 1` slot cleanly — next TTFB measured back at baseline 0.17 s. CPU on
`llama-server` rose ~46% over an identical run. The cancelled-job message is
emitted at `verbose` and stays silent under this config's `notify = 'warn'`.

**Put the defaults back if this provider is ever pointed at a paid endpoint** —
`debounce = 150` roughly doubles request volume versus 400.

## Coupling and upstream

The guard wraps a plugin internal upstream makes no promises about. A rename would
disable it **silently**, so `install()` returns false and `lua/plugins/minuet.lua`
raises a warning. Verify with:

```
:lua print(require('minuet.backends.openai_fim_compatible').__stale_guard)
```

Must print `true`. `install()` is idempotent so `:Lazy reload minuet-ai.nvim` does
not stack wrappers.

**Unreported and unfixed upstream** as of 2026-08-22. `git log -S'is_on_throttle'
--all` finds one commit in the repo's history (`223b639`, 2024-12-14) and
`schedule()` is byte-identical from there through tip, so **upgrading the pin does
not remove the need for this**. All 84 issues and 60 PRs were reviewed; no matches
for stale/outdated/race.

For contrast, `copilot.lua` — which `virtualtext.lua:1` credits as its source —
has no throttle concept at all and re-arms its timer on every keystroke
(`lua/copilot/suggestion/init.lua:494-505`), so the last keystroke always produces
a request. `llama.vim:890-899` also early-returns while rate-limited, but re-arms a
100 ms retry first.

## Verifying

`tests/spec/unit/minuet_guard_spec.lua` pins the predicate, the wrapper, and the
pacing. For end-to-end behaviour a PTY is required — headless nvim cannot enter
insert mode and `CursorMovedI` never fires in a script context. Type an incomplete
statement in ~4-character bursts with roughly half-second pauses and watch for
ghost text that does not fit the characters already on the line; with the guard in
place you may see *fewer* suggestions right after typing, which is the intended
trade.

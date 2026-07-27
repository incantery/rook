# PERF — the scoreboard

What gets written down gets defended. Rook's target audience switches from
Ghostty/Alacritty/Kitty; the bar is "nothing about rook feels like web tech"
(see the perf-strategy discussion, 2026-07-22). This file holds the canonical
numbers, how to reproduce each one, and the history per release. Update it
whenever a number moves — in either direction.

Rules:

- **Like against like.** Grid size, corpus, and machine are part of every
  number. The cat test at 163×40 flatters by ~35% over 405×113.
- **The e2e app is the arbiter, not micro-benches.** We measured a parser
  speedup that made the real app *slower* (wake-per-KB pathology, fixed by the
  gather micro-batch). Micro-benches localize; only interleaved A/B on the
  real app confirms.
- Numbers below are headless (Playwright WebKit against the `-tags server`
  build). DOM-commit latency excludes the compositor's ~frame to pixels.

## Current — 2026-07-22, post-v0.13.0 (seams + latency harness)

Machine: Apple M3 Max, 36GB. macOS. All terminal numbers at **405×113** (the
6K-fullscreen geometry the category benchmarks at) unless noted.

| metric | value | reproduce |
|---|---|---|
| keystroke → DOM commit, p50 | **3.2ms** | `make e2e ARGS=e2e/latency.spec.ts` |
| keystroke → DOM commit, p95 | **6.2ms** | (runs in the default suite) |
| `time cat` 150MB ascii | **0.91s** | `ROOK_CAT_BENCH=1 make e2e ARGS=e2e/catbench.spec.ts` |
| `time cat` 150MB unicode | **1.09s** | 〃 |
| daemon pipeline, ascii (real pty + render ticks) | 454 MB/s | `go test ./internal/host/ -bench BenchmarkPipe` |
| daemon pipeline, unicode | 148 MB/s | 〃 |
| parse, plaintext @120×40 | 400 MB/s | `go test ./internal/vt/ -bench .` |
| parse, plaintext @405×113 | 234 MB/s | 〃 |
| parse, scroll firehose | 564 MB/s | 〃 |
| parse, CSI-heavy redraw | 819 MB/s | 〃 |
| parse, unicode | 215 MB/s | 〃 |
| parse steady-state allocations | 0 B/op | 〃 (`-benchmem`) |
| idle RSS / idle CPU | *unmeasured* | TODO — next instrument |
| cold start to first prompt | *unmeasured* | TODO |
| pane switch / reveal | *unmeasured* | TODO (blank-Surface reveal should be ~1 frame) |

Context, stated honestly: Mitchell Hashimoto's 2026-07-06 numbers (M4 Max, real
displays — *different machine, different corpus*): Ghostty nightly 0.575s/0.536s
ascii/unicode, Alacritty 1.2/1.05, Ghostty 1.3.2 1.5/1.22, Kitty 1.7/1.35,
Warp 3.8/3.4, iTerm2/Terminal DNF at 60s. Rook's 0.91/1.09 sits second on
ascii and Alacritty-tier on unicode. ASCII is currently *producer-bound* (the
kernel pty path), not parse-bound.

## WebGL renderer spike — beamterm (2026-07-22)

Beamterm (`@beamterm/renderer` 1.0.0, Rust/WASM WebGL2) behind the
TermRenderer seam, opt-in via `localStorage.setItem("rook.renderer","webgl")`,
failing open to the DOM renderer. Paint crosses the JS↔WASM boundary as one
`batch.text()` per style-span (~a hundred crossings per full 405×113 frame,
not 45k) — the boundary is a non-issue at span granularity.

| metric | DOM | beamterm WebGL |
|---|---|---|
| cat ascii, **headed** (real GPU) | 0.74s | **0.72s** |
| cat unicode, **headed** | 1.07s | **1.06s** |
| cat ascii, headless | 0.91s | 2.45s ⚠ software-GL artifact |
| latency p50/p95, headless | 3.2 / 6.2ms | **1.8 / 2.1ms** |
| latency p50/p95, headed | 3.7 / 5.4ms | 5.6 / 8.8ms ⚠ see below |

Caveats that decide how to read this:
- **Headless WebKit has no GPU**: software-rasterizing the canvas at 60fps
  starves the shared machine — that 2.45s says nothing about the app (WKWebView
  has Metal). It DOES mean headless e2e cannot gate WebGL throughput.
- **The latency probes measure different pipeline points**: DOM t1 = innerHTML
  set (paint still pending); WebGL t1 = after GL submission (nearly pixels).
  The headed comparison is biased against WebGL; the headless one (1.8ms,
  tail collapsed 3×) is the apples-to-apples signal that the canvas path is
  cheaper. A key-to-pixel probe is needed to settle it.
- Spike scope gaps: scrollback view/paging, mouse forwarding, a11y (canvas
  needs a text mirror), theme-change re-read. WASM adds 1.4MB, lazy-loaded
  only when the flag is set.

## libghostty-vt as a second backend (2026-07-22)

Ghostty's terminal core (`libghostty-vt`, zero-dependency static lib built
from source with zig) behind the Go `Terminal` seam, under the `ghostty`
build tag — `make ghostty-lib`, then `go test -tags ghostty ./internal/host/`.
Adapter v1 diffs the full viewport in Go (per-row dirty flags are a later
slice), punts scrollback paging and pty query responses.

| metric @405×113 | internal/vt | libghostty-vt |
|---|---|---|
| Write-only parse, ascii | 228 MB/s | **844 MB/s** |
| Write-only parse, unicode | 165 MB/s | **596 MB/s** |
| Full-screen render snapshot | **0.78ms** | 17.1ms |
| Full pipeline (pty→parse→16ms render), ascii | **450 MB/s** | 103 MB/s |
| Full pipeline, unicode | **202 MB/s** | 65 MB/s |

(unicode numbers post the width-table + batch-decode arc below; the earlier
run measured 107 / 124.)

The three questions this was built to answer:
- **"Is cgo really that big a deal?"** No — at gather-chunk sizes, per-Write
  overhead is invisible. Ghostty's SIMD parser is genuinely 4–6× faster than
  ours; that headroom is real and worth chasing.
- **The render READ path is the whole story**, exactly as predicted: ~275k
  cgo calls per full-screen snapshot (~60ns each) = 17ms — during a firehose
  the 16ms render tick pays it while holding the emulator lock, so total
  system throughput lands 4× BELOW our backend despite their faster parser.
  A viable adapter v2 needs per-row dirty skipping and a bulk row read.
- **Differential fuzzing is the jackpot.** The oracle (33-stream table +
  `FuzzGhosttyOracle`, corpus checked in) found and we fixed, in one day:
  DEC Special Graphics charset (ncurses ACS borders rendered as "lqk"),
  alt-screen cursor preservation, invalid-UTF-8 maximal-subpart substitution,
  ESC state-machine restarts (ESC ESC, mid-CSI/OSC/DCS ESC), tab stops
  (HTS/TBC/CHT/CBT), DECALN, REP, HPB/VPB, SGR 21, combining-mark width
  classification (go-runewidth misses hundreds of Mn ranges — U+0611 broke
  real Arabic), wide-pair tearing (overlapping glyphs), Cf format-char
  clustering, pending-wrap semantics on TAB/BS/LF, malformed-CSI rejection,
  color-index clamping, single-line DECSTBM. Plus one candidate ghostty bug
  (CSI 0a/0e skip the zero-coercion CSI 0C/0B have — report upstream when
  we engage). Known-divergent classes (documented in the fuzz filter): C0
  executed inside sequences, raw/codepoint C1 handling, param-edge
  adjudications where we match xterm.

## Unicode parse arc (2026-07-22, post-v0.18.0)

The width-classification headroom item, executed: a 64KB BMP width table
built at init (from go-runewidth + every correction the oracle forced —
Mn/Me/Cf zero-join, Mc spacing, Hangul jamo joins, regional indicators
wide, soft hyphen visible) turns the per-rune binary search into one byte
load; then the UTF-8 path got the printASCII treatment (decode runs, hoist
the pen and row slice). **Unicode write-only 107→165 MB/s, unicode
pipeline 124→202 MB/s; ascii unchanged.** A second fuzzing round rode
along: SS2/SS3, LS2/LS3, UK charset, IRM, LNM, SGR colon-subparam grammar
(with ghostty's leak-through rule), 16-bit param saturation, DECSED/DECSEL,
wide-pair repair in ECH/ICH/DCH/EL, spacer-head padding, RIS clearing
DECSC/REP state, prefix-position validation, SCOSC arity. The
pending-wrap × op interaction matrix is skipped by simulation (Emulator.
WrapOps) — terminals genuinely disagree there. Fuzz runs need
`-parallel 4`: the adapter's C-side state is freed explicitly now (a
missing free once compounded into an OOM across hour-long runs).

## Renderer cost vs grid size — the wheel bench (2026-07-27)

Machine: Apple M3 **Pro**, 36GB, macOS, headless **chromium**, machine under
load (~11 load avg). Different chip and different browser from the scoreboard
above, so read this section against itself, not against that table — rule 1.

New harness: `frontend/bench/vt-wheel.{ts,spec.ts}`, run with
`cd frontend && pnpm exec playwright test -c playwright.bench.config.ts
bench/vt-wheel.spec.ts`. One macOS trackpad flick (120 momentum wheel events,
~2900px, ~154 lines) against the DOM renderer in three modes: `local` (the
wheel scrolls the viewport), `tracking` (claude owns the wheel and the presses
are forwarded to the pty), and `frame` — the control, the same full repaint
driven by host frames instead of the wheel.

Why it exists: the scoreboard measures keystroke latency on a *quiet* prompt
and frame time at *120x40*. Neither covers a scroll, and neither covers the
geometry this file calls canonical.

| grid | local p50 | local p95 | frame p50 | frame p95 | one flick, main thread |
|---|---|---|---|---|---|
| 232x41 (a split) | 9.1ms | 15.6ms | 9.2ms | 16.4ms | **0.83s** |
| 405x113 (canonical) | 41.7ms | 70.4ms | 46.7ms | 84.4ms | **4.08s** |

What it says:

- **`local` ≈ `frame` at both sizes.** The wheel handler adds nothing; the cost
  is the full-viewport repaint itself, whoever drives it. Any full-screen
  redraw — a scroll, or claude repainting its conversation view — pays this.
- **The 16ms budget is blown between a split and fullscreen.** At 405x113 one
  repaint is ~3 frames; a flick blocks the main thread for four seconds. That
  is felt as scroll lag *and* as the keystrokes queued behind it, which is why
  "typing lags for the first few letters, then clears" and "scrolling is laggy"
  are one bug, not two.
- **Cost tracks CELLS, not spans.** vt-render's firehose is 2880 spans at
  120x40 and costs 5ms; this is ~3800 spans at 405x113 and costs 47ms. Span
  count is up 1.3x, cells 9.5x, time 9.4x.
- **Forwarding to a tracking program is free** — 0.3ms of main thread for a
  whole flick. What it costs is downstream: 154 `onInput` calls for 120 wheel
  events (1.28 fan-out), each a separate `ws.send`, `pty.Write`, and TUI stdin
  read, and each provoking a repaint at the price above. Batching the per-line
  presses into one write is the cheap half of the fix.
- Minor: `getBoundingClientRect` runs once per LINE (154) rather than once per
  event, a forced layout read inside `renderer.ts`'s per-line loop that
  `beamterm.ts` already hoists out.

The spec's thresholds are today's numbers held as a ceiling, not the target.
Target is p95 < 16ms at every geometry; that needs the WebGL renderer or
row-level virtualization, not a tweak.

Also measured the same day, for context: keystroke→DOM commit p50 **1.9ms**,
p95 **2.7ms** (`make e2e ARGS=e2e/latency.spec.ts`, headless chromium) — the
quiet-prompt path is healthy and is not what anyone is feeling.

## Known headroom (in rough value order)

- **Unicode parse** (165 vs 228 ascii write-only): remaining gap is per-rune
  decode + width dispatch; SIMD-style classification like ghostty's is the
  next tier.
- **ASCII producer bound**: Ghostty spins non-blocking on the pty (costs a
  core under firehose); we declined. Revisit if the gap matters.
- **Wide-grid ring locality**: the 405-col scrollback ring is 4.9MB walked
  cyclically; content-stride storage would cut it, at real complexity.
- **Full-repaint cost at real geometries** (new, and now the top item): 47ms
  per full-screen repaint at 405x113, 9ms at 232x41, against a 16ms budget —
  see the wheel bench above. The D5 gate never caught it because it runs at
  120x40. This is the scroll lag and the typing-under-load lag both.
- **Renderer**: WebGL bake-off pending (beamterm → TinyGo/TS), judged by the
  latency harness + firehose webview CPU. The wheel bench is the other judge:
  beamterm's `repaintViewport` is one batch and one draw call, which is
  precisely the case the DOM renderer loses at.

## History

| date | release | cat ascii/unicode @405×113 | latency p50/p95 | note |
|---|---|---|---|---|
| 2026-07-27 | v0.37.2 | — | 1.9 / 2.7ms | M3 **Pro** + chromium, not comparable to the rows below; wheel bench added |
| 2026-07-22 | post-v0.13.0 | 0.91s / 1.09s | 3.2 / 6.2ms | first full scoreboard |
| 2026-07-22 | v0.13.0 | 0.90s / 1.11s | — | gather + micro-batch + high-water marks |
| 2026-07-22 | v0.12.0 | 1.21s / 1.76s | — | baseline at matched geometry |

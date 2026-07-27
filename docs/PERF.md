# PERF — the scoreboard

What gets written down gets defended. Rook's target audience switches from
Ghostty/Alacritty/Kitty; the bar is "nothing about rook feels like web tech"
(see the perf-strategy discussion, 2026-07-22). This file holds the canonical
numbers, how to reproduce each one, and the history per release. Update it
whenever a number moves — in either direction.

Rules:

- **Like against like.** Grid size, corpus, and machine are part of every
  number. The cat test at 163×40 flatters by ~35% over 405×113.
- **Headless cannot measure pixels.** It has no GPU and software-rasterizes on
  the main thread, so any number whose cost is rasterization is a number about
  Playwright. The grid-size sweep (2026-07-27) got a clean, monotonic,
  four-times-reproducible cliff out of headless that a headed run showed does
  not exist. Correctness, Go-side throughput and DOM structure gate headless;
  rendering cost must be headed.
- **State the load condition.** Keystroke latency at a quiet prompt and the
  same keystroke beside a streaming pane are different metrics, and only the
  second one resembles use.
- **The e2e app is the arbiter, not micro-benches.** We measured a parser
  speedup that made the real app *slower* (wake-per-KB pathology, fixed by the
  gather micro-batch). Micro-benches localize; only interleaved A/B on the
  real app confirms.
- Numbers below are headless (Playwright WebKit against the `-tags server`
  build) unless a row says **headed**. DOM-commit latency excludes the
  compositor's ~frame to pixels.

## Current — 2026-07-22, post-v0.13.0 (seams + latency harness)

Machine: Apple M3 Max, 36GB. macOS. All terminal numbers at **405×113** (the
6K-fullscreen geometry the category benchmarks at) unless noted.

| metric | value | reproduce |
|---|---|---|
| keystroke → DOM commit, p50 (idle, **128×36**) | **3.2ms** | `make e2e ARGS=e2e/latency.spec.ts` |
| keystroke → DOM commit, p95 (idle, **128×36**) | **6.2ms** | (runs in the default suite) |
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

⚠ The two latency rows are the **only** numbers here not at 405×113:
`latency.spec.ts` inherits the config's 1400×900 viewport, which is a 128×36
grid. That went unlabelled until the width sweep below, and it is exactly the
geometry at which the problem is invisible.

Context, stated honestly: Mitchell Hashimoto's 2026-07-06 numbers (M4 Max, real
displays — *different machine, different corpus*): Ghostty nightly 0.575s/0.536s
ascii/unicode, Alacritty 1.2/1.05, Ghostty 1.3.2 1.5/1.22, Kitty 1.7/1.35,
Warp 3.8/3.4, iTerm2/Terminal DNF at 60s. Rook's 0.91/1.09 sits second on
ascii and Alacritty-tier on unicode. ASCII is currently *producer-bound* (the
kernel pty path), not parse-bound.

## Grid-size latency sweep — the ultrawide report (2026-07-27)

Prompted by an ultrawide user reporting lag the scoreboard didn't predict.
Machine: Apple M3 Max, 120Hz display. n=120 keystrokes per point.

**The finding is negative, and the road to it is the actual lesson: a headless
run invented a 10× cliff that does not exist on real hardware.** Both are
recorded below, because the difference between them is now the strongest
statement in this file about what headless e2e can and cannot judge.

### Idle prompt — flat, headless and headed

`ROOK_LAT_SWEEP=1 make e2e ARGS=e2e/latency-width.spec.ts` (headless):

| viewport | grid | cells | p50 | p95 |
|---|---|---|---|---|
| 1400×900 (baseline) | 128×36 | 4,608 | 2.8ms | 4.1ms |
| 2560×1440 | 235×61 | 14,335 | 2.8ms | 3.5ms |
| 3440×1440 | 316×61 | 19,276 | 3.0ms | 3.5ms |
| 5120×1440 | 471×61 | 28,731 | 2.5ms | 3.0ms |
| 4400×2560 | 405×112 | 45,360 | 2.3ms | 3.1ms |

Flat across a 10× cell range — an idle echo dirties one row, so grid size
costs nothing.

### Under load — the headless cliff, and why it is not real

`ROOK_LAT_LOAD=1 make e2e ARGS=e2e/latency-load.spec.ts`: a vertical split,
the right pane streaming full-width lines at pty speed, measured on the left
pane's quiet prompt — an agent or build spewing in one half while you type in
the other. Grid is **per pane**. Headless (⚠ **artifact — do not quote**):

| viewport | grid/pane | cells/pane | p50 | p95 | rAF gap p50/p95 |
|---|---|---|---|---|---|
| 1400×900 | 63×36 | 2,268 | 1.9ms | 4.8ms | 8.3 / 9.2ms |
| 5120×760 | 235×30 | 7,050 | 2.0ms | 4.4ms | 8.3 / 9.2ms |
| 1400×2560 | 63×112 | 7,056 | 2.1ms | 5.4ms | 8.3 / 9.2ms |
| 2560×1440 | 117×61 | 7,137 | 2.1ms | 5.0ms | 8.3 / 9.2ms |
| 3440×1440 | 157×61 | 9,577 | 2.3ms | 11.6ms | 8.3 / 9.3ms |
| 5120×1440 | 235×61 | 14,335 | 3.4ms | 29.3ms | 8.8 / 25.5ms |
| 6880×1440 | 316×61 | 19,276 | 8.2ms | 40.2ms | 16.7 / 41.8ms |
| 4400×2560 | 201×112 | 22,512 | 11.8ms | 50.3ms | 24.4 / 49.9ms |

Reproducible across four runs, internally consistent (the frame clock stalls
in lockstep with the keystroke tail, so it reads as a genuine main-thread
stall above ~10k cells), and **wrong**. Headless WebKit has no GPU: it
software-rasterizes every one of those cells on the main thread. The curve
measures the software rasterizer, not rook.

### Under load, headed — flat to 32k cells, both renderers

Headed at oversized viewports is not proof either: a 6880px window on a
1512pt screen is mostly offscreen, and a compositor may skip tiles nobody can
see. So the trustworthy run holds the viewport at **1400×900 — fully on
screen — and reaches big grids by shrinking the font**
(`ROOK_LAT_MODE=density`, which rewrites the sandbox's `font-size` per point).
Every cell is really rasterized. `--headed`, DOM renderer:

| font | grid/pane | cells/pane | p50 | p95 | rAF gap p50/p95 |
|---|---|---|---|---|---|
| 18px | 63×36 | 2,268 | 4.4ms | 8.1ms | 8.3 / 9.2ms |
| 12px | 95×59 | 5,605 | 5.0ms | 8.6ms | 8.3 / 9.2ms |
| 9px | 127×76 | 9,652 | 5.1ms | 8.7ms | 8.3 / 9.2ms |
| 7px | 163×105 | 17,115 | 4.6ms | 9.1ms | 8.3 / 9.2ms |
| 6px | 190×120 | 22,800 | 4.9ms | 8.5ms | 8.3 / 9.2ms |
| 5px | 228×140 | 31,920 | 4.4ms | 8.2ms | 8.3 / 9.3ms |

Same run with `ROOK_RENDERER=webgl` (beamterm; its cell metrics come from the
WASM atlas, so the grids differ slightly at the same font size):

| font | grid/pane | cells/pane | p50 | p95 | rAF gap p50/p95 |
|---|---|---|---|---|---|
| 18px | 62×34 | 2,108 | 5.1ms | 9.0ms | 8.3 / 9.2ms |
| 12px | 98×55 | 5,390 | 4.8ms | 9.3ms | 8.3 / 9.2ms |
| 9px | 114×76 | 8,664 | 5.2ms | 9.4ms | 8.3 / 9.2ms |
| 7px | 172×93 | 15,996 | 4.8ms | 9.1ms | 8.3 / 9.3ms |
| 6px | 172×105 | 18,060 | 5.1ms | 9.3ms | 8.3 / 9.2ms |
| 5px | 229×140 | 32,060 | 5.1ms | 8.9ms | 8.3 / 9.2ms |

What this says:

- **Grid size costs the typist nothing on real hardware.** 14× the cell count,
  under a firehose, moves p50 by less than a millisecond. The knee is gone,
  and with it the ultrawide explanation.
- **The two renderers are indistinguishable here**, and both sit on the frame
  clock: rAF gap p50 8.3ms is this display's 120Hz, and a p95 of ~9ms is an
  echo waiting for the next frame. Headed, this harness is **display-bound**,
  so it cannot rank renderers — which also means the beamterm spike's headless
  "tail collapsed 3×" (below) is not evidence of anything either.
- **The ultrawide report is still unexplained.** Grid size is eliminated;
  whatever Joaquin is hitting is something else (candidates: pane count rather
  than pane size, scrollback paging while scrolled, the host's frame rate into
  a wide grid, his GPU/display rather than an M3 Max's, or something outside
  the terminal entirely). Do not close this on the numbers above.

Methodological rule this earns, stated bluntly: **headless e2e cannot measure
anything whose cost is pixels.** It can gate correctness, throughput of the Go
pipeline, and DOM structure. The moment a number depends on rasterization,
headless will lie — and it lied here in the most convincing way available, with
a clean monotonic curve, a plausible mechanism, and four reproducible runs.

## Host echo latency — the term the browser can't see (2026-07-27)

Keystroke → frame-carrying-the-echo, measured through the real framed loop
(pty, readPump, emulator, coalescer, websocket) with **no browser in it**:
`go test ./internal/host/ -run TestEchoLatency -v`. Deterministic, immune to
both the headless rasterizer and the headed frame clock — the two things that
make the browser harness blind here.

The condition that matters is typing into a session that is **itself**
producing output. `framedRenderLoop` coalesces to one frame per 16ms and
escapes that wait only after an idle gap, so a quiet prompt is free and a busy
pane is not. A firehose in the *other* pane does not exercise this — that is a
different session, idle on the typing side, which is why the whole browser
sweep missed it.

| condition @316×61 | before | after |
|---|---|---|
| quiet prompt, 90ms apart | 0.82 / 1.18ms p50/p95 | 0.79 / 1.31ms |
| quiet prompt, 20ms apart | 0.72 / 1.18ms | 0.70 / 1.09ms |
| streaming session, 90ms apart | 9.85 / 11.70ms | **1.25 / 3.77ms** |
| streaming session, 20ms apart | 13.00 / 14.29ms | **0.75 / 1.46ms** |

Before the fix this was the largest single latency term in the pipeline —
larger than paint, transport and the display's own quantum combined — and it
was pure wait, not work. The fix is an input-triggered flush with an
**interruptible** wait; see docs/render-latency.md for why the interruptible
half is the part that matters, and for the regression that is holding it back.

## Client frame profile (2026-07-27)

`ROOK_FRAME_PROFILE=1 make e2e ARGS="--headed e2e/frameprofile.spec.ts"` —
decode / grid-apply / paint per frame, read off an opt-in probe inside the
renderer. This is the only instrument here that resolves below the display's
frame clock, which is where every keystroke measurement bottoms out.

Headed, one 624x58 pane, firehose of full-width lines (~94KB/frame, ~53
rows/frame):

| stage | before | after the decode fix |
|---|---|---|
| decode (wire -> Frame) | 2.10ms | **0.40ms** |
| apply (Frame -> ClientGrid) | 0.30ms | 0.30ms |
| paint (spans -> WASM -> draw) | 1.70ms | 1.70ms |
| **total p50** | 4.10ms | **2.40ms** |
| share of a 120Hz frame | 49.2% | **28.8%** |

Ordinary output is nowhere near this: `cat` of a source file and a slow
trickle both cost 0.10-0.20ms per frame, ~2% of the budget. Only a firehose
loads the client at all.

The fix was one branch: `Reader.str()` runs once per cell (~45k for a full
screen) and called `TextDecoder.decode()` on a one-byte subarray for nearly
all of them; ASCII cells now come from an interned 128-entry table. Paint is
now the largest client cost.

## One renderer, and what it cost the harness (2026-07-27)

The DOM renderer was deleted; beamterm is the only path (docs/render-latency.md
has the reasoning and the gap list). One number belongs here, because it is a
measurement and it changes how this file gets used:

| | DOM renderer | beamterm only |
|---|---|---|
| `make e2e`, 118 specs, headless | **2.1 min** | ~4x slower |

Same cause as the phantom cliff at the top of this file, arriving as a bill:
headless WebKit has no GPU, so a canvas renderer software-rasterizes the whole
grid every frame in every spec, while the DOM renderer only repainted dirty
rows. The suite is the arbiter this project leans on, and consulting it is now
materially more expensive.

Also note the failure mode the swap exposed, since it will recur: several
specs read the screen through `innerText`, which a canvas does not have. They
did not fail loudly — they timed out at 26s each. Terminal text must be read
through `screenText()` (harness.ts), which goes via the renderer's
`__screenText()` probe.

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
| latency p50/p95, headless | 3.2 / 6.2ms | **1.8 / 2.1ms** ⚠ see 07-27 |
| latency p50/p95, headed | 3.7 / 5.4ms | 5.6 / 8.8ms ⚠ see below |

Caveats that decide how to read this:
- **The headless latency row did not survive** (grid-size sweep, 2026-07-27):
  run headed under load, the two renderers are indistinguishable and both sit
  on the display's frame clock at every grid size. Whatever the 1.8/2.1ms was,
  it was not a 3× advantage that shows up on a real GPU.
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

## Known headroom (in rough value order)

- **Unicode parse** (165 vs 228 ascii write-only): remaining gap is per-rune
  decode + width dispatch; SIMD-style classification like ghostty's is the
  next tier.
- **ASCII producer bound**: Ghostty spins non-blocking on the pty (costs a
  core under firehose); we declined. Revisit if the gap matters.
- **Wide-grid ring locality**: the 405-col scrollback ring is 4.9MB walked
  cyclically; content-stride storage would cut it, at real complexity.
- **Renderer**: WebGL bake-off pending (beamterm → TinyGo/TS). Note the
  judging instrument is missing, not just unused — headed, the latency harness
  is display-bound (both renderers land on the 8.3ms frame clock at every
  grid size, 2026-07-27), and headless measures a software rasterizer nobody
  ships. Ranking renderers needs a probe that survives both: firehose webview
  CPU, or key-to-pixel capture.

## History

| date | release | cat ascii/unicode @405×113 | latency p50/p95 | note |
|---|---|---|---|---|
| 2026-07-27 | — | — | 4.9 / 8.5ms @190×120 loaded, headed | grid-size sweep: flat to 32k cells on real hardware; the headless cliff was an artifact |
| 2026-07-27 | — | — | host echo 0.53ms quiet / 0.38-1.10ms streaming | input-flush past the coalescer + gather gate; client frame 4.10 -> 2.40ms (decode fast path) |
| 2026-07-22 | post-v0.13.0 | 0.91s / 1.09s | 3.2 / 6.2ms | first full scoreboard |
| 2026-07-22 | v0.13.0 | 0.90s / 1.11s | — | gather + micro-batch + high-water marks |
| 2026-07-22 | v0.12.0 | 1.21s / 1.76s | — | baseline at matched geometry |

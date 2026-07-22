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
| Write-only parse, ascii | 226 MB/s | **840 MB/s** |
| Write-only parse, unicode | 107 MB/s | **599 MB/s** |
| Full-screen render snapshot | **0.78ms** | 17.1ms |
| Full pipeline (pty→parse→16ms render), ascii | **441 MB/s** | 103 MB/s |
| Full pipeline, unicode | **124 MB/s** | 65 MB/s |

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

## Known headroom (in rough value order)

- **Unicode parse** (215 MB/s vs 400 ascii): `runewidth` per-rune
  classification; memoize width runs / fast-path repeated scripts.
- **ASCII producer bound**: Ghostty spins non-blocking on the pty (costs a
  core under firehose); we declined. Revisit if the gap matters.
- **Wide-grid ring locality**: the 405-col scrollback ring is 4.9MB walked
  cyclically; content-stride storage would cut it, at real complexity.
- **Renderer**: WebGL bake-off pending (beamterm → TinyGo/TS), judged by the
  latency harness + firehose webview CPU.

## History

| date | release | cat ascii/unicode @405×113 | latency p50/p95 | note |
|---|---|---|---|---|
| 2026-07-22 | post-v0.13.0 | 0.91s / 1.09s | 3.2 / 6.2ms | first full scoreboard |
| 2026-07-22 | v0.13.0 | 0.90s / 1.11s | — | gather + micro-batch + high-water marks |
| 2026-07-22 | v0.12.0 | 1.21s / 1.76s | — | baseline at matched geometry |

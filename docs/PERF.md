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

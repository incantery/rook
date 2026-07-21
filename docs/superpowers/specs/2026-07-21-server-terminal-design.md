# Server-side terminal: own the grid, the parser, the renderer

*Design spec, 2026-07-21. Ratified in conversation with Seth, on the back of a
measured spike (`spike/`, branch `spike/server-terminal`). Every load-bearing
claim here is a number from that spike, not an assertion — several of them
overturned an assumption we started with, which is why we measured.*

## Purpose

Move terminal emulation out of the browser (xterm.js, which today is the
structural owner of terminal state) and into the Go host, and own the full
stack end to end: **parser → grid → wire protocol → renderer.** The goal is not
"a faster terminal on one screen." It is the workload nobody else optimizes
for: **many background, agent-driven sessions, cheap to run, with only the
viewed one rendered** — and, downstream, a grid-aware exec primitive for
agents.

This supersedes the client-authoritative-emulator model and shelves the
`7-detach-inactive-stop-rendering` worktree (it engineers the "keep xterm
authoritative but drop-and-replay it" path, which this obsoletes).

## Why — the seam we've been paying interest on

xterm.js is two things wearing one name: a **VT emulator** (parses the pty byte
stream, owns the authoritative grid) and a **renderer** (paints it). rook runs
both in the browser. That one choice — client-authoritative terminal state — is
the shared root of a recurring tax: the AUTO_REPLY query-answering subsystem
and its `$y` bug, the ring-size-caps-scrollback bind, browser-only alt-screen
detection, `normRing`'s content-sniffing, and the detach branch's whole
machinery. Everything the human viewport, orchestration scale, and agent
legibility want fights that seam.

tmux can multi-attach cheaply because its *server* owns the emulator and
clients are dumb renderers. rook is inverted. This spec inverts it back, and
goes further: we own the parser and renderer too, because measurement showed
the reusable pieces are either too slow (x/ansi) or structurally wrong for
scale (x/vt), and because owning the whole column removes every
serialize/re-parse boundary between the pty and the pixels.

## Decisions

Each decision carries the evidence behind it. Raw numbers and the harnesses
that produced them live in `spike/README.md` and `spike/parsebench/`.

### D1 — The authoritative grid lives on the host, not the client

**Decided.** The host owns a VT emulator per session and the authoritative
cell grid. The client becomes a renderer of diffs, not the owner of state.

Rationale, and the honest scope of it: this is justified by **orchestration,
scale, and coalescing — NOT by parse speed and NOT by latency**, both of which
we measured and neither of which the server grid improves:

- **Latency is render-path-bound, not transport-bound.** Measured keystroke
  round-trip (ws.send→echo, `cat` so program latency ≈ 0): p50 **5.2 ms**, p99
  8.9 ms. The browser paint (1–2 compositor frames, ~16–33 ms) dominates
  keystroke→glyph. A server grid is latency-neutral. (This killed our earlier
  "prediction is the latency headline" claim — mosh matters at hundreds of ms;
  ours is 5, so predictive echo saves ~5 ms, a footnote.)
- **Parse is not the bottleneck for anyone.** Both emulators parse far above
  any real output rate (see D2). The server grid's wins are elsewhere: parse
  OFF the browser's single JS thread (a firehose can't jank the UI),
  coalescing render frames before the wire, zero-cost background sessions, and
  detach/orchestration.

### D2 — Build our own emulator (parser + grid); do not adopt x/vt, do not keep xterm as the emulator

**Decided.** After validating that a Go emulator *can* match xterm, we measured
the candidates and chose to own it.

- **Fidelity is achievable.** `charmbracelet/x/vt` matches xterm.js 6.0.0
  cell-for-cell on the corpus: **100%** on nvim (alt-screen + truecolor),
  git-graph, and redraw; **99.06%** on adversarial unicode — the only
  divergence being ZWJ-family-emoji / flag width, the most contested corner of
  Unicode width, tunable. So the destination is habitable.
- **But x/vt's grid model is a non-starter at scale.** It stores each cell as a
  Go string, runs grapheme segmentation per cell, and allocates a heap object
  per scrolled line: **13,000,000 allocations over 16 MiB** of git output,
  4 MB/s. GC pressure that grows with session count.
- **The parser is not the hard-to-own part; the fast path is ours anyway.**
  x/ansi's tokenizer is excellent (184 MB/s, zero-alloc, validated at 100% via
  the diff), but its byte-at-a-time `Advance` + closure-per-rune API caps
  there. A hand-written bulk-scan parser (`spike/parsebench/bulk.go`) — find
  the next control byte, blast the printable run into cells — hits **475 MB/s**
  on SGR-heavy content, **4.5× xterm.js**, rendering cell-for-cell identical to
  the reference. This is the universal fast-terminal technique (alacritty's
  vte, ghostty, kitty all do memchr/SIMD-scan + bulk-place; external survey
  confirms the 2–5× it buys).

Full throughput picture (git-graph, `go test -bench`):

| | throughput | allocations |
|---|---|---|
| memory floor (SIMD scan only) | 2426 MB/s | — |
| bulk parse-only (no cell write) | 584 MB/s | — |
| **bulk full emulator (ours)** | **475 MB/s** | ~0 |
| x/ansi path (packed grid) | 133 MB/s | 0 |
| xterm.js | 107 MB/s | — |
| x/vt | 4 MB/s | 13M |

**Cost of owning it, stated plainly:** the VT tokenizer is the fiddly,
edge-case-heavy part (DCS/OSC/APC, charsets, mouse encodings, DECRQSS, the
kitty keyboard protocol). Owning it means owning those bugs. Two mitigations
make it tractable and are part of this decision: (a) the **fidelity diff
harness** (`spike/termdiff`) validates our grid against xterm continuously on a
growing corpus; (b) the hot path owns the common ~95% (print/SGR/cursor/erase)
at 475 MB/s while **delegating the rare tail to a reference** (x/ansi) — fast
where it matters, correct where it's weird.

### D3 — Packed, zero-allocation grid — the scale property

**Decided.** Fixed-size cell in a preallocated grid, ring-buffer scroll (advance
a top offset, clear one row — no copy), single rune + table width lookup. This
is xterm's data model, in Go, and it is the whole reason to build our own.

The scale measurement (`TestScale`, N emulators concurrent, ~4 MiB each):

| | agg throughput | allocated | GC | STW pause |
|---|---|---|---|---|
| **bulk (ours), n=20** | **4002 MB/s** | **2 MB** | **0** | **0.0 ms** |
| x/vt, n=20 | 32 MB/s | 8089 MB | 9 | 5.1 ms |

At 20 sessions the zero-alloc grid is **125× the aggregate throughput,
allocates 4000× less, and pauses zero.** It scales ~8× across cores because
there's no allocator contention, and the collector never runs because nothing
is on the heap. This — not single-terminal speed — is the differentiator, and
it is why Go is arguably the *right* language here: cheap goroutine-per-session
and a good scheduler, with the one thing that would sink Go (GC) removed by
zero-alloc. Go's weakness (no SIMD intrinsics, lower single-stream peak than
Zig) sits on the axis we don't care about.

Where 475 sits externally, honestly: it is a *minimal* grid (single-rune cells,
no combining/wide) on an M-series Mac; kitty's ~135 MB/s parse-only is *full
fidelity* on their machine — apples to oranges. What holds is that Go bulk-scan
lands in the fastest-native band (100–330 MB/s parse-only, full fidelity), so a
production Go emulator realistically lands ~150–500 MB/s: competitive with the
best, faster than xterm.js, and — the point — zero per-cell allocation.

### D4 — Own the client renderer (Svelte); drop xterm.js entirely

**Decided.** xterm.js is removed as the emulator *and* as the renderer. The
client consumes structured grid-diffs and paints them itself.

The coherence argument, not just preference: once the server owns the grid,
xterm *can't cleanly consume it* — its renderer paints from its own internal
buffer, which you fill with **bytes**. Keeping it means `server grid → serialize
to ANSI → xterm re-parses → xterm buffer → xterm renders`: reintroducing the
exact serialize/re-parse boundary this whole effort removes, plus a duplicate
buffer (~63 MB/saturated-session, measured). Owning the renderer lets structured
diffs go straight to pixels.

**Start DOM/Svelte**, built to win (run-coalescing so a line is ~10 spans not
200; diff-driven updates keyed to the wire's damage; virtualized scrollback).
It aligns with rook's Svelte 5 chrome, the browser does text shaping for free
(the hard part), and the workload is bounded because coalescing already
happened server-side. "Renderer" scope includes selection/copy, scrollback
scroll, cursor, links, and a11y — xterm gives these free; we re-implement them.
Budget for that; it's the bulk of the work, not the glyphs.

Do NOT treat Svelte as a throwaway stepping stone (see D5-gate). A DOM renderer
is also *on-thesis*: agent-legible means the terminal is readable by the a11y
tree, tests, and tooling — a WebGL canvas is an opaque pixel buffer.

### D5 (gated) — WebGL is an escape hatch, not a roadmap item

**Gated on a measurement, possibly never.** The renderer sits behind a thin
interface. A GPU (canvas/WebGL) renderer fires *only if* a frame-time test
fails on the two cases DOM is weakest at — **scrollback-scroll smoothness** and
**watching a live foreground firehose** (~1000 span updates/frame at 60 fps).
Neither is driven by the orchestration workload; both are driven by the
**daily-driver quality bar**. Genuinely uncertain (~coin flip), so:

- Measure those two cases early with a synthetic scroll/firehose harness,
  before much is built on the Svelte renderer.
- If it fires, it's *later* (after the pipeline is proven) and *localized*
  (behind the interface), and almost certainly **hybrid** — GPU for glyph
  pixels *plus* the Svelte DOM layer we already built, for selection / a11y /
  inspectability (exactly xterm's own architecture). So the Svelte work
  survives regardless; it is not throwaway.

### D6 — Coalesced, structured diff wire protocol

**Decided in shape, unspecified in detail.** The server emits grid **damage**
(changed cell runs / rects) to the client at frame cadence, coalesced — parse
the firehose, emit only the net final state per frame. Not raw bytes, not an
ANSI snapshot; a structured diff the renderer consumes directly (no re-parse).
This has no production precedent (VS Code / tmate / Zed hold server grids but
ship raw bytes/snapshots), so we design it. Our emulator's damage tracking is
the primitive it's built on. Detail (binary vs JSON, run vs rect, cursor/mode
sidechannel) is deferred to the implementation plan.

### D7 (gated) — Reflow is our code, and its severity is bounded

**Decided: build it in our grid; sequencing gated.** No Go emulator reflows on
resize; xterm.js does. Measured gap (`run-reflow.sh`, content wrapped at 100
then resized): narrow→60 **59.6%** identical (x/vt truncates and LOSES the
overflow), widen→140 **80.6%**.

But the severity is bounded: on a real resize the host sends SIGWINCH and live
programs redraw (shell, nvim, htop, tmux) — the current screen self-heals. The
gap only shows on **non-redrawn content: scrollback and a finished command's
output**. tmux shipped without reflow until 2013. Once we own the grid, reflow
is *our* code — track a per-line soft-wrap bit (which ultraviolet does not
expose, one reason not to build on it) and re-wrap before emitting the repaint.
**Ship v1 without reflow** (a bounded, known regression) and add it as a
fast-follow, unless dogfooding says otherwise.

### D8 — The grid is also an agent exec primitive (downstream)

**Decided as direction, downstream of the engine.** The same server grid that
feeds the human viewport feeds a better exec primitive for agents than
pipe-capture. Concrete win, measured: the progress-bar capture is **2974 bytes
of raw stream → 61 chars on the final screen (49×)** — the grid coalesces the
`\r`-firehose into what a human sees, which is exactly what an agent wants
(final rendered state, not thousands of intermediate frames burning tokens).

Delivered as **MCP terminal tools** (`terminal_exec` returning the rendered
screen, `terminal_read`, `terminal_send_keys`, `terminal_wait_for`) that the
agents rook drives can call — a capability vanilla Claude Code's pipe-Bash
lacks. Positioned as a *second* exec mode for the commands pipe-capture handles
badly (redraw-heavy output, TUIs, interactive prompts, persistent servers),
with the raw pipe kept for machine-readable output. Not a Bash-tool replacement.

**Explicit boundary (a conflation to avoid):** this is NOT how we get structured
data about a claude *session itself*. Claude's TUI is a lossy visual projection
of already-structured data; scraping the grid to recover tool calls would be
worse than the jsonl. Structured agent state comes from the **agent's own
structured output** (`claude -p --output-format stream-json`, which
`internal/agent/claudecode.go` already consumes), not the terminal. The terminal
grid is for the human viewport, scale, and commands the agent *runs* — a
different substrate from the agent's semantic stream. Keep them distinct.

## Rejected alternatives

- **Keep xterm as the authoritative emulator, bandage the symptoms.** The
  AUTO_REPLY family, ring-caps-scrollback, and the detach machinery are all
  interest payments on this. Indefinite, growing.
- **Adopt x/vt as-is.** Clean fidelity, but 13M allocs/16 MiB — GC-thrashes a
  host running many sessions. Non-starter at the workload that matters (D3).
- **Keep xterm's renderer as a "dumb painter."** Can't cleanly consume a grid;
  reintroduces the ANSI round-trip and a duplicate buffer (D4).
- **Reuse x/ansi's parser for the hot path.** Excellent and zero-alloc, but its
  per-byte closure API caps at 184 MB/s; bulk-scan needs a hand-written loop.
  We still delegate the *rare tail* to it (D2).
- **WebGL-first renderer.** Solves a firehose problem we deleted server-side;
  costs glyph-atlas + shaping + selection + an a11y dual-layer for a benefit the
  workload largely doesn't need (D4, D5).
- **A VT parser from scratch including the tokenizer's fiddly tail.** We own the
  fast path; we do not re-solve every escape sequence — the fidelity harness +
  reference-delegation manage the tail (D2).

## Corrected assumptions (why the record is trustworthy)

Measurement overturned four things we (I) asserted before checking, recorded so
the reasoning is auditable:

1. "Go parses faster than JS" — **false.** xterm 95 MB/s vs x/vt 43 on nvim;
   x/ansi 184 vs xterm 107 on git-graph. The win is bulk-scan + zero-alloc, not
   language.
2. "Prediction is the latency headline" — **false.** Transport is 5 ms; paint
   dominates. Prediction saves ~5 ms.
3. "Use x/vt as the emulator" — **false.** Its grid model fails at scale.
4. "tmux doesn't reflow" (a starting premise) — **false**; tmux has since 2013.
   The reflow bar is real and universal; no *Go* library clears it.

## Phased plan

Each phase has a gate it must clear before the next. The fidelity harness
(`spike/termdiff`) and the scale/throughput benches (`spike/parsebench`) are
the gates' instruments and move from `spike/` into the real test suite.

- **Phase 1 — the grid engine.** A `Grid` interface; the packed, zero-alloc,
  bulk-scan emulator behind it; the reference-delegation seam for the rare tail.
  *Gate:* match xterm on the full corpus (extend it — mouse, DCS, OSC, wide
  chars, alt-screen thrash) and hold the scale/alloc numbers.
- **Phase 2 — the wire.** The coalesced structured diff protocol; the emulator's
  damage feeds it; per-session frame cadence. Host answers all terminal queries
  natively (the emulator's own responses replace `internal/host/termquery.go`).
  *Gate:* a reattaching client reconstructs the grid identically; no query ever
  reaches the client.
- **Phase 3 — the Svelte renderer.** DOM, run-coalesced, diff-driven,
  virtualized scrollback; selection/copy; cursor; a11y. Drop xterm.js. *Gate:*
  the frame-time test on scroll + foreground-firehose (this is also the D5
  WebGL trigger).
- **Phase 4 — scale wiring.** Lazy parse-on-view (background sessions keep only
  their ring; grid materialized on view — agent state already comes from
  transcripts, so background terminals need no live grid); visibility-tiered
  damage. *Gate:* N background sessions cost ring storage + ~0 CPU until viewed.
- **Phase 5 (fast-follow) — reflow**, and the **agent MCP terminal tools** (D8).

## Risks and honest caveats

- **Owning the VT tail** is the real ongoing cost (D2). Mitigated, not
  eliminated, by the harness + reference-delegation.
- **The 475 / 4002 numbers are minimal-fidelity.** Full fidelity is slower per
  cell; the *scale properties* (zero-alloc, no GC, core-scaling) are what carry
  over, and those hold for any zero-alloc design.
- **Reflow is a real v1 regression** on non-redrawn content (D7).
- **DOM renderer may not hold** the daily-driver bar on scroll/firehose (D5) —
  measured early, hybrid fallback ready.
- **The wire protocol is novel** (D6) — no precedent to copy.
- **This is a large build** touching the host, a new frontend renderer, and the
  removal of a load-bearing dependency. It is justified by the workload nobody
  else serves, not by single-terminal speed.

## Non-goals

- Beating ghostty/alacritty/kitty on single-terminal keystroke latency (the
  compositor owns that; we don't play there).
- Replacing the agent's structured stream with terminal scraping (D8 boundary).
- Reflow parity with xterm in v1 (D7).
- A general-purpose terminal library for others to embed. This is rook's engine
  for rook's workload.

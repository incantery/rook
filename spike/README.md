# spike: server-side terminal grid

Deciding whether the terminal emulator can move out of the browser (xterm.js
today, holding the authoritative grid) and into the Go host — making xterm.js
an implementation detail of the client renderer rather than the structural
owner of terminal state.

The whole spike turns on ONE question that can kill it: **can a Go VT emulator
match xterm.js on real terminal output?** Everything else (client renderer,
diff protocol, detach) is engineering with a known shape. Fidelity is the
unknown, so it goes first.

## Plan

1. **termcap** — capture raw pty byte streams from real programs (nvim, htop,
   a build log, git graphs, wide chars). Library-agnostic; the corpus both
   emulators get fed.
2. **termdiff** — feed each capture into a candidate Go emulator AND into
   headless xterm.js at the same geometry, read both grids, diff cell by cell.
   Bucket divergences: cosmetic vs corrupting. Throughput and diff-volume fall
   out of the same harness (the performance question).
3. Go/no-go on the Go emulator. If it holds, the migration is greenlit and
   proceeds behind a live parallel-shadow (both emulators run, divergence is
   logged, no cutover until the Go grid has shadowed xterm.js in real use).

This is a spike: throwaway-quality is fine, reproducibility is not. Every
capture is a committed artifact so the diff is rerunnable.

## Result so far

`sh spike/termdiff/run.sh` — charmbracelet/x/vt vs xterm.js 6.0.0:

| capture | cells | identical |
|---|---|---|
| nvim-edit (alt-screen + truecolor) | 4800 | **100.00%** |
| git-graph (SGR + graph glyphs) | 4800 | **100.00%** |
| redraw (in-place `\r`) | 1920 | **100.00%** |
| unicode (adversarial) | 1920 | **99.06%** |

**Static fidelity is essentially there.** The only divergence in the whole
corpus is 18 cells of ZWJ-family-emoji and regional-flag width: x/vt keeps
👨‍👩‍👧‍👦 as one width-2 grapheme cluster, xterm.js splits it into four
width-1 cells. x/vt is arguably the more correct of the two, but xterm is what
rook renders today, so it counts as a difference — one confined to the single
most-contested corner of Unicode width, and tunable (x/vt has a pluggable
WidthMethod).

**What this does NOT answer — the two live risks:**

1. **Reflow on resize.** Verified absent: x/vt's `Resize` pads/truncates rows,
   and ultraviolet's buffer exposes no per-line soft-wrap bit, so a reflow
   port has nothing to hang off. xterm.js reflows. This diff holds geometry
   FIXED, so it says nothing about resize — a separate test still owed, and
   the biggest open risk.
2. **The grid-diff wire protocol** to a thin client has no production
   precedent; that's ours to design. x/vt's typed `Damage` API is the right
   primitive to build it on.

Also learned: x/vt **answers DA/DSR/DECRQM itself** (writes replies to its
output, which deadlocks a synchronous `Write` if undrained — see extract-vt).
In the real host that response stream is written back to the pty, replacing
`internal/host/termquery.go`'s hand-rolled answers with the emulator's own.

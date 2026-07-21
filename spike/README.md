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

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

**The grid-diff wire protocol** to a thin client has no production precedent;
that's ours to design. x/vt's typed `Damage` API is the right primitive.

## Performance floor — measured (and it corrected two assumptions)

**Parse throughput**, same 40 MiB of realistic heavy output (the nvim capture,
SGR + alt-screen + cursor thrash), `bench-vt` vs `bench-xterm`:

| emulator | throughput |
|---|---|
| xterm.js | **95 MiB/s** |
| x/vt | **43 MiB/s** |

xterm is 2.2× FASTER — the "Go parses faster" assumption was wrong; x/vt trades
speed for grapheme correctness (uniseg per cell). But both are far above any
real output rate (a busy build log is single-digit MB/s), so **parse is not
the bottleneck for either.** The server-side-grid case does NOT rest on parse
speed. Its wins are: parse OFF the browser's single JS thread (so a firehose
can't jank the UI), coalescing render frames before the wire, zero-cost
background sessions, and detach/orchestration.

**Keystroke round-trip** in the real app (e2e sandbox), `ws.send(key) →
ws.recv(echo)`, `cat` as the program so tty echo makes program latency ~0:

| | ms |
|---|---|
| min | 0.2 |
| p50 | **5.2** |
| p90 | 8.2 |
| p99 | 8.9 |

Excludes the final paint (1–2 compositor frames, ~16–33ms at 60Hz). So the
transport is TINY — the browser paint dominates keystroke→glyph, not the
network. Two consequences, both correcting earlier claims:

- **Prediction is a minor lever here, not the headline.** Mosh matters when
  transport is hundreds of ms; ours is ~5ms, so predictive echo saves ~5ms.
  Worth doing, not the main event.
- **The latency lever is the RENDER path** — GPU rendering at high refresh
  with minimal frame latency. Server-side grid is latency-NEUTRAL; it buys
  orchestration and scale, not keystroke speed.

Net for the architecture: the case for the server-side grid is
orchestration + scale + coalescing + off-thread parse, NOT parse speed and NOT
latency. Latency is a render-path problem, addressed by a GPU client renderer
(and secondarily prediction). Measured, not assumed.

## Parser vs grid — is it worth building our own? (yes)

`go test -bench . -benchmem ./spike/parsebench` decomposes x/vt's slowness.
Same 16 MiB of git output through three paths:

| | throughput | allocations |
|---|---|---|
| x/ansi parser alone (no grid) | **184 MB/s** | **0** |
| packed grid on x/ansi (ours) | **133 MB/s** | ~0 (setup only) |
| xterm.js | 107 MB/s | — |
| x/vt | **4 MB/s** | **13,000,000** |

The verdict is unambiguous. **x/vt's problem is its grid model, not the
parser** — 13M allocations over 16 MiB, a Go string + grapheme segmentation
per cell plus a heap object per scrolled line. **x/ansi's parser is excellent**
— 184 MB/s, zero-alloc, and our fidelity diff already validated it at 100%.
And a **packed-cell grid** (fixed-size cell, preallocated grid, ring-buffer
scroll — xterm's data model, in Go) **beats xterm** at 133 MB/s, allocation-
free, and renders correct output (TestPackedProducesSaneGrid).

So "build our own" is not "write a VT parser from scratch" — that's the hard,
fiddly, correctness-critical part, and x/ansi already nails it. It's **reuse
x/ansi's parser, build the grid**, which is mechanical and where all the
performance lives. Well-scoped, and the ceiling clears xterm.

## How fast can Go actually go? (the ceiling)

184 MB/s felt low, and it was — x/ansi is a byte-at-a-time state machine with a
closure call per rune. Fast terminals don't do that: they bulk-scan the
printable run (find the next control byte, blast the whole text span into cells
at once) so the common case never touches the state machine. `bulk.go` is a
hand-written parser doing exactly that, rendering cell-for-cell identical to the
packed grid (TestBulkMatchesPacked). `go test -bench 'Bulk|MemFloor'`:

| | git-graph (SGR-heavy) | plain text |
|---|---|---|
| memory floor (SIMD `IndexByte` scan only) | **2426 MB/s** | — |
| bulk **parse only** (no cell write) | 584 MB/s | — |
| **bulk full emulator (ours)** | **475 MB/s** | 453 MB/s |
| x/ansi path (packed) | 133 | 134 |
| xterm.js | 107 | — |
| x/vt | 4 | — |

**475 MB/s — 4.5× xterm, 3.6× the x/ansi path.** So 200 was never a wall; it
was x/ansi's per-byte dispatch. And there's more headroom: the memory floor is
2426, and bulk-parse-without-writing-cells is 584, so on SGR-heavy content the
CELL WRITES cost only ~20% (584→475) — the real cost above the floor is escape
/ SGR dispatch. Plain text isn't faster than SGR-heavy (453 vs 475) because
then every byte becomes a cell write; that path is write-bound, and a leaner
cell (pack rune+style into 8 bytes instead of 16) would lift it. Routes to
higher still: SIMD-scan the escape boundary too, a tighter SGR parser, an
8-byte cell. A production Go emulator landing at **500 MB/s–1 GB/s** on real
content is realistic — several times xterm, at zero per-cell allocation.

## Grid model, not parser — building our own beats xterm

Honest caveat: the 133 is an optimistic ceiling. The prototype is minimal —
single-rune cells, drops combining marks, no wide-char continuation, no
alt-screen / scroll-regions / OSC / DCS. A production grid with full fidelity
needs xterm's overflow-table trick for grapheme clusters, which costs some
speed. But xterm proves packed + grapheme-correct + 107 MB/s is achievable, so
a Go version should still match or beat it — and, critically, stay
allocation-free, which is what lets the host run many session emulators
without GC thrash. That last property is why x/vt (13M allocs/16MiB) is a
non-starter at orchestration scale regardless of its clean fidelity.

## Reflow on resize — measured

`sh spike/termdiff/run-reflow.sh` — the `longlines` capture (six ~134-char
soft-wrapped lines) fed at 100 cols, then resized:

| resize | identical | what happens |
|---|---|---|
| 100→100 (none) | **100.00%** | same layout, both agree |
| 100→60 (narrow) | **59.6%** | xterm re-wraps; **x/vt truncates and LOSES the overflow** |
| 100→140 (widen) | **80.6%** | xterm pulls wrapped text back up; x/vt leaves it padded |

Narrowing is the bad one — it's not just different wrapping, x/vt drops the
characters that fall past the new width, because nothing re-wraps them down.

**But the practical bite is bounded.** On a real resize rook sends SIGWINCH and
live programs redraw themselves — shell prompt, nvim, htop, tmux — so the
CURRENT screen self-heals. The gap only shows on content that is NOT redrawn:
scrollback, and a finished command's output. That is exactly what xterm
reflows and x/vt would mangle until the next repaint. tmux shipped without
reflow until 1.8 (2013), so it's a lived-with regression, not a dealbreaker —
but it IS a regression from what rook users have today.

Fixing it means porting xterm's `BufferReflow.ts` onto x/vt, which first needs
ultraviolet to track a per-line soft-wrap bit (it does not). Well-defined, not
small. Options: ship v1 without reflow (bounded regression), or port it first
(delays the migration).

Also learned: x/vt **answers DA/DSR/DECRQM itself** (writes replies to its
output, which deadlocks a synchronous `Write` if undrained — see extract-vt).
In the real host that response stream is written back to the pty, replacing
`internal/host/termquery.go`'s hand-rolled answers with the emulator's own.

# Render latency — diagnosis and direction

Companion to [PERF.md](PERF.md): that file holds the numbers, this one holds the
conclusions drawn 2026-07-27 from a full pipeline audit (host output path,
frontend render path, keystroke input path). Update it when a conclusion is
overturned by a measurement, and only then.

## Diagnosis

- **Idle is already Ghostty-class.** 2.3–3.2ms p50 keystroke→commit, flat
  across a 10× grid range. Idle latency is not the problem and never was.
- ~~**The felt gap is the loaded tail.** Beside a streaming pane the DOM
  renderer's commit stalls the main thread past ~10k cells/pane (p95 4.8ms →
  40–50ms).~~ **RETRACTED 2026-07-27, same day.** That cliff was measured
  headless, where WebKit has no GPU and software-rasterizes every cell on the
  main thread. Headed, with every cell genuinely on screen, keystroke latency
  is **flat to 32k cells/pane on both renderers** (4.4–5.1ms p50, 8.1–9.4ms
  p95) and both sit on the display's frame clock. There is no paint knee. See
  PERF.md for the full retraction; the rAF corroboration was real and equally
  meaningless — it measured the same software rasterizer.
- **The felt gap is the host's coalescing wait, and it is now measured.**
  `framedRenderLoop` escapes its 16ms tick only after an *idle gap*, so typing
  into a pane that is itself producing output — a build, a test run, Claude
  streaming — pays the remainder of the tick on every keystroke. Measured
  through the real loop with no browser in it (`internal/host/echolat_test.go`,
  316×61): **p50 0.8ms at a quiet prompt vs 9.9–13.0ms into a streaming
  session**, p95 14.3ms. That is the largest single term anywhere in the
  pipeline and it is pure wait, not work. The browser sweep could never see it:
  a firehose in the *other* pane is a different session whose loop is idle on
  the typing side.
- **The Go side is innocent.** 0.78ms full-screen render, 450MB/s pipeline —
  two orders of magnitude below the stalls. The emulator's location (host-side)
  costs one loopback hop + serialization, ~0.3ms. The process split is the
  product moat (host outlives app, host scrollback, pause, remote clients) and
  is latency-compatible. Keep it.
- **The floor is the webview compositor** (WKWebView's internal composite vs
  Ghostty's owned CAMetalLayer). Same tax regardless of renderer or emulator
  placement — which is why the key-to-pixel probe matters more than more
  architecture debate.

## Item 7, executed (2026-07-27)

Promoted to the top by measurement: it was the only item backed by a number
after the knee was retracted. Input-triggered flush past the coalescer, in
`framedRenderLoop`:

| condition @316×61 | before | after |
|---|---|---|
| quiet prompt, 90ms apart | 0.82ms p50 | 0.79ms p50 |
| streaming session, 90ms apart | 9.85 / 11.70ms p50/p95 | **1.25 / 3.77ms** |
| streaming session, 20ms apart | 13.00 / 14.29ms | **0.75 / 1.46ms** |

Two things had to be true, and the first alone bought nothing:

- An echo skips the coalescing wait (`session.lastInput`, marked *before* the
  pty write so the line-discipline echo can't beat it).
- **The wait itself must be interruptible.** Under a stream the loop is nearly
  always already inside the timer when the keystroke lands, so checking only on
  the way in moved p50 13.0 → 13.0ms. It wakes on the first *dirty following*
  the keystroke — not on the keystroke, which would ship an empty frame before
  the echo is parsed and cost a whole extra tick.

Residual: p99 ~17ms in one condition (≈1% of keystrokes still eat a full tick);
mechanism not yet identified.

It surfaced a real dropped-input bug on the way in, which is the interesting
part: it flipped `editor-isolation.spec.ts` red, and the cause was not the
terminal path at all. `re file` mounts the editor pane and focuses it, but
Monaco arrives through an `await import()`, so the focus request sits in a
latch (`EditorPane.applyPendingFocus`) until it resolves. In that window the
editor is on screen with focus still on `<body>` and **every key typed into it
went nowhere** — the context leader's arming test asks the DOM target, and the
DOM target was body. Faster frames only widened a gap that was always there.
Fixed by falling back to `editorFocused()` when nothing holds the keyboard:
the manager knows which pane it means even when the DOM doesn't.

Worth stating as a principle, since the campaign will keep hitting it: input
dropped during a focus race is the worst latency there is — unbounded, and
invisible to every probe that measures echo timing, because the keystroke
never produces an echo to time.

## Top 10 (effort-to-benefit order, DOM renderer era)

Superseded in part by the beamterm-default decision below; items marked ◆
survive any renderer. **Item 1's premise is void** — it existed to fix the
retracted paint knee.

1. ~~Rotate row elements on scroll instead of full-screen `innerHTML` reparse~~
   (`grid.ts` marks all rows dirty on any scroll). Was "the knee's mechanism";
   there is no knee. Still real work if the DOM renderer survives, but it is
   no longer justified by a measurement.
2. ◆ rAF-align painting; throttle wheel + sbchunk repaints (both bypass all
   coalescing today; `queue()` in renderer.ts is dead code).
3. ◆ Close visibility-gating gaps: zoomed siblings keep painting, no
   occlusion/minimize gating, overlays don't pause.
4. ◆ Fast-path plain keystrokes in App.svelte's capture handler (~3 `closest()`
   walks + a string alloc per key before the renderer sees it; the
   no-modifier early-out sits 150 lines too late).
5. ◆ Decode fast path: one `TextDecoder.decode()` **per cell** (~45k/full
   frame), per-frame object graph, double pass into the grid.
6. ◆ Host: `correlate()` regex over 512KB rings under the **global** `bindMu`
   that every alt-screen pane's render tick also takes (attention/overview
   polls, every 3–5s) — periodic jitter injected into the render loop,
   invisible to e2e.
7. ◆ **DONE (measured, not landed) — see "Item 7, executed" above.** Was: input-
   triggered flush past the 16ms coalescer. It was the whole felt problem.
   Still open: gate the 200µs gather micro-batch off the interactive case.
8. ◆ Opaque compositor fast path when backgroundOpacity is 1.0; build the
   key-to-pixel probe (NOTES.md item) — one instrument, judges both this and
   DOM-vs-WebGL headed.
9. ◆ Pane-switch/reveal: full row-DOM rebuild + forced layout + sync
   localStorage write per focus change. Unmeasured; should be ~1 frame.
10. WebGL renderer to default — now the decision, not the tenth item; see below.

## What beamterm proves (canvas_waves)

Their demo rewrites an entire 426×106 grid (~45k cells — rook's benchmark
geometry) **every rAF frame** with zero dirty tracking and sustains sub-ms
renders. Two lessons:

- Paint capacity is effectively unlimited at terminal scale. Full-viewport
  repaint once per rAF is *affordable and simpler* than per-message dirty
  painting — the pull model collapses items 2/5's paint halves, the cursor-row
  repaint, and every sbchunk/wheel special case into one bounded repaint.
- canvas_waves has **no JS bridge** — cells are produced inside WASM. Rook's
  remaining cost is exactly the layer their demo doesn't have: wire → TS
  decode → object graph → span build. That layer is the optimization surface.
  (Beamterm's own headless latency through today's *unoptimized* bridge:
  1.8/2.1ms. The bridge is fixable, not fatal.)

Also from that repo: the game-console example composites a semi-transparent
terminal — the transparency blocker (NOTES.md) is likely a canvas
context-alpha setting, not a renderer limitation. And `measure_performance`
exists backend-side — candidate instrumentation.

## One renderer (2026-07-27)

The DOM renderer is deleted. `renderer.ts` (513 lines), the registry's
bake-off seam, the Experimental settings tab and `experimental.spec.ts` are
gone; beamterm is the only path. The justification is maintenance, not
speed — every fix, theme change and wire change used to land twice, and the
measurement that was supposed to arbitrate could not (headed, both renderers
sat on the display's frame clock; the headless cliff that seemed to favour
canvas was an artifact).

Closed on the way out:

- **Click/drag forwarding** ported into beamterm (press, drag-when-level-3,
  release, right-click menu suppression, window-level move/up so a drag that
  leaves the pane keeps reporting). Without it, click-to-position in vim and
  tmux pane select silently stopped working — the wheel path hides this,
  because scrolling still feels right.

Still open, and now shipped regressions rather than spike scope:

- **a11y**: a canvas has no readable text. `__screenText()` is an e2e probe,
  not an accessibility tree.
- **Transparency**: the pane paints opaque; `backgroundOpacity` needs a canvas
  alpha context.
- **No fallback**: a WASM load failure now means no terminal at all, so
  `registry.ts` records the reason loudly instead of swallowing it.

### The cost nobody priced: headless e2e

`make e2e` went from **2.1 minutes to over 25** on the same machine, and the
reason is the one already written at the top of PERF.md — headless WebKit has
no GPU. The DOM renderer let it repaint a few dirty rows; a canvas renderer
makes it software-rasterize the whole grid every frame, on the main thread, in
every one of 118 specs. This is the same effect that produced the phantom
cliff, arriving as a bill.

It is worth stating plainly because it changes the development loop, not just
a number: the suite is the arbiter this project leans on, and it just got an
order of magnitude more expensive to consult.

## The frame probe, and where client time actually goes (2026-07-27)

`globalThis.__rookFrameProbe` (an opt-in sink in `beamterm.applyBytes`, one
undefined check per frame when unset) stamps the three client stages;
`e2e/frameprofile.spec.ts` reads it. This is the instrument the campaign was
missing — headless lies about pixels, headed is quantized by the frame clock,
and neither can say whether the TS bridge is worth moving. This measures the
work itself, below the display's resolution.

Headed, one 624×58 pane (a 6880px window):

| load | bytes/frame | rows/frame | decode | apply | paint | total p50 |
|---|---|---|---|---|---|---|
| firehose (full-width lines at pty speed) | 95 KB | 53.2 | **2.10ms** | 0.30ms | 1.70ms | **4.10ms** |
| `cat` a source file | 290 B | 2.9 | ~0 | ~0 | 0.10ms | 0.10ms |
| slow trickle (the shape of typing) | 113 B | 7.3 | ~0 | ~0 | 0.20ms | 0.20ms |

Read it in this order:

- **Only a firehose loads the client at all.** Typing and ordinary output cost
  0.1–0.2ms per frame, ~2% of a 120Hz budget. Whatever anyone feels while
  typing at a prompt, it is not client-side frame cost.
- **Under a firehose the client spends half its frame budget** — 4.10ms of
  8.33ms. That is the headroom that disappears on a slower machine or a busier
  main thread.
- **Decode was the single largest client cost: 2.10ms, 51% of the frame.** Item
  5's premise (one `TextDecoder.decode()` per cell, a per-frame object graph, a
  double pass into the grid) was measured rather than asserted. Paint — the
  part beamterm is famous for being fast at — is 1.70ms and was never the
  problem.

### Decode, fixed (same day)

`Reader.str()` runs once per CELL — ~45k times for a full screen — and called
`TextDecoder.decode()` on a one-byte subarray for almost all of them. A
terminal cell is one ASCII byte nearly always, so the fast path returns an
interned single-character string from a 128-entry table and allocates nothing;
TextDecoder still handles everything else.

| firehose @624×58 | before | after |
|---|---|---|
| decode | 2.10ms | **0.40ms** |
| apply | 0.30ms | 0.30ms |
| paint | 1.70ms | 1.70ms |
| **total p50** | **4.10ms** | **2.40ms** |
| share of a 120Hz frame | 49.2% | **28.8%** |

5.2x on decode, 1.7x on the whole client frame, for one branch and a lookup
table. The wire format was never the cost — the per-call overhead was.

**Paint (1.70ms) is now the largest client cost**, which puts the next
question squarely on the renderer: it is one `batch.text()` per style-span
plus one draw call, so the span build (TS side) and the WASM boundary are what
remains to measure separately.

## Worker + OffscreenCanvas is blocked upstream (2026-07-27)

The plan calls thread isolation "the bigger lever than language". It is not
available: **beamterm 1.0.0 can only bind a canvas by CSS selector.** Both
entry points take a `canvas_id: string` and the JS glue resolves it with
`document.querySelector`; there is no `OffscreenCanvas` or `HTMLCanvasElement`
overload, and neither "offscreen" nor "worker" appears in its README or
CHANGELOG. A Worker has no `document`, so paint cannot move.

Stated fairly, this is not a cost of deleting the DOM renderer — a DOM
renderer could never run in a Worker at all, so beamterm is strictly better
positioned; it just needs upstream support or a fork. The options, in order of
appeal:

1. **Fix decode first.** It is 51% of client frame time and independently
   broken. A typed-array, allocation-free decode is *also* the representation
   a worker split would need to transfer cheaply, so this work is not wasted
   whichever way the worker goes.
2. **Split at decode, not at paint.** Decode + apply (2.40ms of 4.10ms) can
   move to a Worker today with paint left on the main thread — but only once
   the frame representation is transferable, or structured-clone eats the win.
   That is item 1 again, first.
3. **Fork or upstream an OffscreenCanvas constructor** for beamterm. The
   library is 1.0.0 with one maintainer (the bus-factor risk already noted
   below), so a fork is plausible but is a real ownership decision.

## Architecture verdict

- **Host-authoritative emulator + binary diff wire + client cell
  framebuffer** is the permanent architecture. Sub-ms client rendering is
  compatible with it (nearly achieved already); nothing measured argues
  against it.
- **Beamterm is aligned but temporary.** Its model — dumb GPU cell buffer,
  batch in, one instanced draw out — is exactly the right client primitive
  for this architecture. The risks are component-level: bus factor (1.0.0,
  one maintainer), and edge mismatches (alpha, CSS-var theming, a11y, DPR).
- **Invariant to defend forever:** the host is the sole authority on cell
  layout (widths, graphemes, wide pairs — the fuzzer's hard-won ground). The
  renderer must be a framebuffer, never a text engine. The day the renderer
  re-segments a span differently than the host did is the day we own the
  renderer.

## Language for the owned core (when it exists)

The core's job is decode varints → mutate a flat 45k-cell grid → fill GPU
buffers → a handful of GL calls. Data layout and allocation discipline decide
performance; language decides variance and ownership cost.

- **Go/TinyGo WASM: ruled out.** Slow `syscall/js` interop forces "Go fills
  buffers, JS draws" — leaving Go only the half JS does fine — plus GC and
  immature debugging. Code-sharing with internal/vt is hollow: the client
  needs the decoder (~hundreds of lines), not the emulator.
- **TS first, Rust on a tripwire.** Allocation-free typed-array TS is
  plausibly within budget (host parses at 234MB/s without SIMD; the client
  decodes far less) and its data layout *is* the Rust design, making a later
  port mechanical. Rust/WASM buys 2–4× headroom and a jitter-free tail — pay
  for it only if measurement demands it.
- **The bigger lever than language: thread isolation.** WebSocket + decode +
  grid + GL can all live in a Worker with OffscreenCanvas (WebKit ≥ Safari
  17) — socket-to-pixels off the main thread, Ghostty's renderer-thread
  design in web primitives. Rust on a contended main thread still queues
  behind Svelte layout; TS in a worker doesn't. Design the core
  worker-isolatable from day one.

## Plan

1. rAF-pull inversion + typed-array grid + ASCII decode fast path in the
   existing beamterm path (pure TS, days). Adapt `latency-load.spec.ts`'s t1
   for canvas (the `rook:frame` event, gated behind a harness flag).
2. Run the 316×61 loaded sweep with `rook.renderer=webgl`. This number
   arbitrates everything downstream.
3. Land the ◆ renderer-agnostic items (visibility gaps, keydown fast path,
   bindMu decoupling, input-kick flush) — they survive every renderer choice.
4. Close beamterm's default-blockers (transparency via context alpha, mouse
   forwarding, a11y mirror); flip the default.
5. **Tripwire:** if loaded p99 at ~22k cells/pane stays double-digit in the
   worker-isolated TS core and profiles to GC/JIT variance rather than
   contention → port decode+grid+buffer-fill (~500 lines) to a Rust crate
   behind the same seam. Everything around it stays TS.

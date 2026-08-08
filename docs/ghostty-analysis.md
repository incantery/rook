# rook vs Ghostty — competitive deep-dive

**2026-08-07.** Companion to `docs/zed-analysis.md`, same method: architecture
compared, patterns worth stealing, and the competitor's git history mined as a
map of paid-for bugs. Ghostty cloned with full history (12,875 non-merge
commits, HEAD `260288614` @ 2026-08-07); rook's vendored pin fetched from the
`incantery/ghostty` fork and located exactly against upstream. Every claim
cites a commit, file, or URL.

The relationship is different from Zed's, and it changes what "competitive"
means: **Ghostty is simultaneously rook's competitor, rook's supplier, and —
as of July 2026 — the substrate of a new company aimed near rook's thesis.**
rook ships Ghostty's terminal core (`ghostty-vt`) inside its own binary. Every
upstream VT improvement is rook's for free at the next vendor bump; every
upstream VT vulnerability is rook's today. And Mitchell Hashimoto's new
company, Superlogical, is building a multiplexer-for-agents on the same
library. The three sections below — performance, the VT seam, scar tissue —
are therefore not "what to imitate" but "what to inherit, when, and what to
build that they won't."

## Executive summary

### The pin, located (everything else depends on this)

`app/build.zig.zon:40-42` pins `incantery/ghostty@dc3b078`, version
`1.3.2-dev`. That commit is **upstream main @ `ab0b9da9e` (2026-07-22) plus
one rook patch** (`dc3b078`: surface OSC 9/777 as a `desktop_notification`
effect). Two consequences:

1. **rook already ships the nightly parser.** The July 5–10 perf blitz that
   produced Mitchell's "fastest terminal, 2x margin" numbers (PRs #13220,
   #13226 — see below) is *inside* rook's pin. The task's premise "rook is
   behind Ghostty nightly" is true on the clock but wrong on the mechanism:
   the gap is not the parser, it is rook's pty read loop (§performance).
2. **Upstream has moved 374 commits since the pin** (127 touching
   `src/terminal/`), including an entire kitty-graphics security-hardening
   series rook is exposed to **today** (§vt-seam). The fork patch has been
   absorbed upstream in modified form, so the next bump *deletes* rook's
   only carried diff.

### Where rook stands

**Ahead, and measured:** rook's `cat` 150MB at 0.887–0.98s vs installed
Ghostty 1.3.1's 1.610s on the same M3 Max (`app/PERF.md`); true key-to-photon
instrumentation Ghostty has no equivalent of; a 2.7MB single binary against
Ghostty's app+framework; and the entire layer Ghostty deliberately does not
build — editor, LSP, environment graph, plugins, agent visibility.

**Behind, honestly:** Ghostty nightly's cat is ~0.575s on an M4 Max
(261 MB/s; rook is at ~167 MB/s on M3 Max) and most of the residual gap is an
IO-architecture lesson Ghostty paid for in PR #13209 that rook's
`session.zig` read loop has not adopted. Ghostty's macOS scar tissue —
font fallback, IME, resize, display handling — is 3+ years deep where rook's
is 10 days deep; ~60 of their fix commits are executable specs for bugs rook
has not met yet (§scar-tissue).

**The strategic picture (§strategy):** Ghostty-the-app stays terminal-pure —
no sessions, no detach, 1.4 (Sept 2026) is scriptability + tmux *control
mode* + graphical prefs. The multiplexer ambition moved to **Superlogical**
(Mitchell's new company, announced 2026-07-29): a server-side multiplexer on
libghostty with web/macOS/iOS clients, explicitly framed by press as
infrastructure for long-running agents. That is adjacent to rook's wedge but
approaches from the opposite end: server-side, enterprise, session-sharing.
rook's local-first one-binary editor+orchestrator remains uncontested by
either — but the *attention* thesis ("which of my agents needs me") now has a
well-funded neighbor.

### Live findings in rook this analysis produced

1. **Kitty graphics attack surface, live at the pin.** `kitty_graphics` is
   compiled unconditionally into the vt module
   (`src/terminal/build_options.zig:58-70` upstream) and the handler rook
   uses executes graphics commands directly (`stream_terminal.zig` `apcEnd` →
   `Terminal.kittyGraphics` at the pin) — including **file-path
   transmission (the library opens files), shared-memory transmission, and
   PNG decoding** — with none of the 2026-08-05 hardening series:
   `ec04900ab` (validate opened image file paths), `af2faa311` (restrict
   temporary image file paths), `f766f303a` (validate shared memory ranges),
   `590d669c4` (limit png decoder allocations), `e5840bb9b`, `d866fa455`,
   `8524cb593`, plus leak fixes `b5e86a428`/`d0c516f8f`/`402b9227d`. Any
   program running in a rook pane can drive this today. rook never *renders*
   the images, which hides the feature but not the parser/executor surface.
2. **Unbounded OSC/grapheme allocations at the pin** — upstream bounded them
   in `727b8a02f` (2026-08); a hostile stream can balloon rook's emulator
   memory. Same bump fixes it.
3. **The read loop pays per-KiB.** `session.zig:406-437` does one blocking
   `read()` (`pty.zig:163-167`) per iteration into a 64KB buffer — but the
   macOS kernel caps pty-master reads at ~1KiB (Ghostty PR #13209's measured
   discovery: 6,337 consecutive reads of exactly 1024 bytes). So a 150MB cat
   is ~150k iterations of mutex acquire/release + kick + stats atomics, and
   the child sits blocked on a full 1KB kernel queue while rook parses.
   This is the same architecture Ghostty ran 2023→2026 and then measured
   +25–55% throughput from replacing.
4. **Scrollback compression is sitting unused in the pin.**
   `Terminal.compress` + `compressionActivity` (upstream
   `Terminal.zig:2564,2603`; landed in-pin via `95685afd2`/`461562ca4`) are
   caller-driven; Ghostty drives them from renderer idle (`25e624569`).
   Nightly's announcement: 70–90% less scrollback memory, default limit
   raised 10MB→50MB (PR #13264). rook calls neither — a free RSS lever.
5. **On bump, two Effects signatures change** and one new effect appears:
   `desktop_notification` becomes `Action.ShowDesktopNotification` (upstream
   `stream_terminal.zig:86` — this *is* rook's fork patch, absorbed),
   `clipboard_write` becomes multi-MIME `clipboard.Write` → `WriteResult`
   (`634ef7198`), and **`progress_report` (OSC 9;4)** arrives — the
   ConEmu progress protocol Claude Code emits, i.e. the single most
   wedge-relevant VT feature rook currently drops on the floor.
6. **Mode 2033 visibility reports** (`6c8c07981`, post-pin): a new protocol
   letting TUI programs know they're occluded. rook — whose PERF.md just
   spent two days proving occlusion dominates its own latency measurements —
   is the natural early implementer on the host side.

### The priority list

1. **Bump the vendor pin to current upstream main** [small-medium] — the
   security series alone justifies it; cost is two callback signatures plus
   deleting the fork patch (rook's Zig-module symbol surface —
   `vt.Terminal`, `vt.TerminalStream`, `vt.Terminal.vtHandler`,
   `vt.RenderState`, `vt.search`, `vt.unicode` — is intact at main; the only
   Terminal API change is additive: `setScrollbackMaxBytes/MaxLines`,
   `86f81fb5b`). Both sides are Zig 0.16, no toolchain jump.
2. **Drain-then-parse the read loop** [medium] — Ghostty #13209/#13209-fix
   as the spec; expected to close most of the cat gap (§performance).
3. **Drive scrollback compression from the frame loop's idle path** [small].
4. **Surface `progress_report` after the bump** [small] — a per-pane
   progress state the chrome and the claude plugin can read; Ghostty shipped
   the GUI version in 1.2 and it's what makes Claude Code's progress bar
   native there.
5. **Adopt the scar-tissue specs in build order** — resize/atlas generation
   rules and display-identity rules now (rook has the subsystems), IME
   commit-replay rules now (rook has NSTextInputClient), font-fallback rules
   as the font stack grows.
6. **Session restore via `vt.snapshot`** [medium] — upstream just built the
   serialization rook's restore story needs (§vt-seam); pairs with the
   zed-analysis persistence slice.

---

## The performance story: what nightly actually changed

### The three PRs behind Mitchell's table

Mitchell's 2026-07-06 claim — nightly `cat 150MB` at 575ms vs "1.3.2" 1.5s,
Alacritty 1.2s, Kitty 1.7s (https://x.com/mitchellh/status/2074167186785226899,
"These changes are directly in libghostty, too, so everyone wins") — traces
to three PRs merged that same day, all with unusually complete commit
messages:

**PR #13209 — the IO pipeline** (`2f0e6659d`, "termio: pipeline pty reads to
overlap parsing with draining", +25–55%). The discovery: **macOS caps every
read on a pty master at ~1KiB regardless of buffer size** — instrumented at
6,337 reads × exactly 1024 bytes for a 6.49MB stream. The old
one-read-one-parse loop (theirs since 2023, rook's today) therefore paid
lock + wakeup overhead per kilobyte, *and the child could never run more
than 1KiB ahead* — `cat` sat blocked on a full kernel queue while the
terminal parsed. Fix: an `io-gather` thread drains the pty into a ring of
large buffers while the parse thread consumes the previous batch;
sub-1KB payloads deliver on first EAGAIN to protect latency. Result: ascii
91→123 MB/s, unicode 116→183 MB/s, DOOM-fire 530→770fps; "IO throughput is
now within noise (1 to 3%) of our VT parsing throughput."

**PR #13220 — VT processing, ~1.5–6x** (in rook's pin). The capstone is
`47e26df60` "batch printed codepoint runs into direct row fills": a new
`print_slice` stream action emitted by the SIMD ground-state path, with
`Terminal.printSlice` hoisting every run-invariant check out of the
per-character loop and classifying destination cells with one masked u64
compare — 5.7x on plain ascii, 2.2–3.4x on unicode/CJK, verified by a
differential fuzz test against per-codepoint `print`. Around it:
`1a88f3622` (dispatch CSI finals directly from stream fast paths — kills a
~240-byte Action copy per byte, +17–18%), `253e4f9c3` (bulk-parse CSI
parameter bytes, +29–41%), `cee35cabf` (skip style-map update on no-op SGR,
+4–7% on TUI refresh). Plain ascii went **128 → 725 MB/s**; the PR contains
the exact headline number: "`time cat ascii_150MB.txt` went from 1.5s before
13209 to 1.2s on main to 566ms on this branch."

**PR #13226 — real-world corpus, ~1.2–3.4x** (in rook's pin). Profiled
against a 2.6GB asciinema recording rather than synthetic streams:
`083d9709b` (decode ASCII inline in the SIMD ESC scan), `300f42c7a` (CSI
entry bytes inline in `consumeUntilGround`), `cb2d78587` (bulk style-only
cell fills), `8d663a76e` (style refs released per run not per cell — 2.1x on
full-screen styled erase), `b5053153f` (log unsupported inputs once — +3.2%,
system time halved). 276→342 MB/s on the real-world dump.

Beside them, renderer-side: `446f80f4e` "render state update optimizations"
(~2.7x–11x less lock hold; masked vector classification, beginUpdate/
endUpdate split so accumulation happens under the lock and processing
outside it) — also **in rook's pin**, and rook consumes it: `session.zig:3`
snapshots "via RenderState.update".

### What rook already has vs what's left

Partitioned against rook's pin (`git merge-base --is-ancestor`):

| technique | where | rook status |
|---|---|---|
| print_slice run batching (`47e26df60`) | vt lib | **in pin, active** — rook uses `vt.Terminal.vtHandler()` + `vt.TerminalStream` (`session.zig:407,421`), which is the handler that implements printSlice |
| CSI fast paths, SIMD ASCII inline, style-run bulk ops (#13220/#13226) | vt lib | **in pin, active** |
| RenderState lock-hold reduction (`446f80f4e`) | vt lib | **in pin, active** |
| io-gather pipeline (#13209, `2f0e6659d`) | Ghostty termio (app code) | **absent** — rook's loop is the pre-2023-architecture equivalent |
| idle-parser bridge bypass (`bb0ac4c72`) | Ghostty termio | absent (only relevant once a gather exists) |
| scrollback compression (`95685afd2`, `461562ca4`, PR #13264) | vt lib, caller-driven | **in pin, never called** |
| reflow vectorization series (`ec5b36961`, `d4e446c48`, `c249b9de3`, `46276d046`, `4a88cc594` — resize/reflow speed) | vt lib | post-pin, inherited on bump |
| formatter speedups (`79aa256fa`, `2ed67cadd` — copy/dump path) | vt lib | post-pin, inherited on bump |
| REP through printSlice (`5b70f208b`), fast print styles (`8838c37f4`) | vt lib | post-pin, inherited on bump |

The honest arithmetic: rook's best cat is 0.887s = ~169 MB/s on M3 Max;
nightly's 0.575s = ~261 MB/s on M4 Max. Same parser on both sides. An M4 Max
is roughly 20–25% faster single-core; Ghostty's own measured gain from the
gather pipeline was +25–30% on ascii. Those two factors bracket the entire
gap. **rook does not have a parser problem; it has Ghostty's 2023 IO
architecture.**

### Patterns to steal

- **Drain-then-parse, then pipeline** [medium] — step 1 (hours): loop
  non-blocking reads until EAGAIN or the 64KB buffer fills *before* taking
  the session mutex — cuts lock/kick cycles up to 64x with zero new threads.
  Step 2 (the real win): a gather thread per Ghostty #13209 so the child
  runs ahead while rook parses — this is what unblocks `cat` itself. Spec:
  `2f0e6659d`. Target: `app/src/session.zig:406-437` readLoop +
  `app/src/pty.zig:163` readMaster.
- **The idle-parser rule, from day one** [small] — Ghostty's follow-up
  `bb0ac4c72` is the paid-for trap: their gather stage's 1ms refill poll
  added ~1.2ms to every frame of a request/response TUI (`fps -fire` frame
  times 5x worse at small grids) because a frame-synced writer *cannot*
  refill while blocked on the reply inside the held-back batch. Their rule —
  bridging is only free while the parser is busy; when it's idle, deliver
  immediately — is rook's own input-kick principle (`docs/render-latency.md`
  item 7) restated for reads. rook's key→photon p50 is the moat; a gather
  pipeline that costs it 1ms is a net loss. Bench both phases
  (`app/bench.sh` quiet-keys AND cat) on the same run, like Ghostty did.
- **Idle-time scrollback compression** [small] — call
  `Terminal.compress(...)` from the frame loop when `compressionActivity()`
  says pages are cold and the pane is quiet (Ghostty starves-proofed this in
  `25e624569`). Free memory headroom before rook raises its own scrollback
  limits. Target: the 2Hz HUD tick or the drawFrame skip branch.
- **Differential fuzz as the licence for fast paths** [process] —
  `47e26df60`'s fast path ships with a fuzz test running identical
  operations through the slow and fast paths and comparing full screen dumps
  + page integrity. This is rook's vim-oracle method applied to a hot loop;
  any rook-side fast path (fillPane batching, future wrap) should carry the
  same licence.
- **What NOT to copy:** Ghostty's renderer thread, damage model, and
  triple-layered apprt indirection. rook's 37–56µs fill and zero idle frames
  beat Ghostty's architecture on its own benchmark with one process and no
  renderer thread; PERF.md's numbers say the render side is not where
  rook's next second lives. (Ghostty's `d34b54e9b` lock-handoff fix is the
  same lesson rook already paid in week one — `os_unfair_lock` starvation,
  PERF.md "What the first run caught" #2.)

A meta-note worth recording: all three perf PRs credit LLM agents for the
discoveries (#13209: "The motivating discovery was actually found by
Fable... I decided today I would try budgeting $100 to Fable to focus on
Ghostty's IO performance"; #13220: "These findings were almost all found by
Fable 5"). The fastest terminal's throughput story was produced by exactly
the workflow rook exists to host.

---

## The VT seam: vendored ghostty-vt vs upstream main

**Pin:** `incantery/ghostty@dc3b078` = upstream `ab0b9da9e` (2026-07-22) + 1
patch. **Upstream since:** 374 commits, 127 in `src/terminal/`. rook's
consumed symbol surface (grep of `vt.*` across `app/src/*.zig`):
`Terminal`, `TerminalStream`, `Terminal.vtHandler`, `Terminal.Colors`,
`RenderState`, `Screen`, `Style`, `color.*`, `search.Screen`,
`unicode.codepointWidth/graphemeWidth`. All of it exists unchanged at main
(`src/lib_vt.zig` re-exports, verified). The C ABI churned
(`cfc19e805` removed `ghostty_terminal_mode_get/set`, marked "ABI
BREAKING") — irrelevant to rook, which imports the Zig module — but it is a
correct signal that pre-tag libghostty will keep breaking; the pin
discipline stays mandatory.

### What the next bump inherits

**Security (the reason to bump soon):**
- The kitty-graphics hardening series, 2026-08-05 (11 commits, listed in the
  executive summary). rook compiles and *executes* this protocol today:
  `build_options.zig` forces `kitty_graphics=true` on all non-wasm targets,
  and the pin's `stream_terminal.zig:875-895` `apcEnd` routes straight into
  `Terminal.kittyGraphics` with responses flowing out rook's `write_pty`.
  File-read, shm-map, and PNG-decode paths are all reachable from any
  program's stdout.
- `727b8a02f` "bound OSC and grapheme allocations" — DoS hardening for
  the paths rook parses on every byte.
- `38e891e6c` "require opt-in for title reports" — CSI 21 t answered with an
  attacker-controlled title is an injection primitive; upstream default is
  now off (`title_report: bool = false`, `stream_terminal.zig:59-62`).

**Correctness fixes rook's emulator inherits:**
- `bfd40c84b` reset wrap state on `CSI 2 K` (erase-line clearing pending
  wrap — a cursor-position class bug rook would otherwise meet via some TUI)
- `7cd2f65f5` OSC color *reset* must set override to null, not default
- `33d34cf5c` VS15 cursor underflow (variation-selector at column 0)
- `e20564791` printSlice spacer-tail vs runtime safety — affects Debug/dev
  builds of rook (`make dev`), not ReleaseFast
- `7a9c369cf` preserve cursor when formatting tabstops; `8524cb593` kitty
  point-deletion math

**API churn rook must react to (the whole bump diff, measured):**
- `desktop_notification` effect: rook's fork patch, absorbed upstream with a
  struct signature (`Action.ShowDesktopNotification`,
  `stream_terminal.zig:86`) instead of `(title, body)` slices. Delete the
  patch, adjust `session.zig:416` `effectNotify`.
- `clipboard_write` effect: now protocol-neutral multi-MIME
  (`634ef7198` — OSC 52 / kitty OSC 5522 share one path; empty content list
  = clear; returns `clipboard.WriteResult`). Adjust `session.zig`
  `effectClipboardWrite`. The read-refusal stance rook praised is now
  documented in the type itself: "Clipboard read requests are never
  forwarded" (`stream_terminal.zig:127-133`).
- New `progress_report` effect (OSC 9;4) — see priority list; rook currently
  has no slot for it and should.
- `Effects.readonly` default (`effects: Effects = .readonly`) — rook
  constructs effects explicitly, unaffected, but new fields will keep
  arriving; rook's designated-initializer style (`session.zig:408-420`)
  breaks loudly on additions, which is the right failure mode.

**New capability rook should plan around — `terminal/snapshot`:** a complete
new subsystem (~20 files, `snapshot.zig` 78KB, a Kaitai binary spec
`snapshot.ksy`, incremental decoder `e37865bed`, stream-continuation
tracking `68beeef`/`70e41e96d` so a VT stream can be resumed mid-sequence,
C API `d7bb4b863`), exported to rook's module as `vt.snapshot`
(`src/terminal/main.zig:24`). The format doc states the design goal:
"prioritizes making a terminal functional as quickly as possible — active
state, READY, then history." That is a detach/reattach and restore wire
format (and visibly the Ghostty↔Superlogical seam; the robustness series
`58e92098a`..`465488d6b` shows it being production-hardened). For rook:
session restore of *screen contents* across relaunch — the half of "shells
die with the app" that is actually recoverable — becomes an encode call at
quit and a decode at launch, plus rook's existing respawn-in-cwd. Watch it;
don't build a rival format.

**New protocol — mode 2033 visibility reports** (`6c8c07981`):
"Applications cannot infer whether an unfocused terminal remains visible, so
focus reports are insufficient for avoiding expensive rendering while a view
is hidden." rook tracks per-pane visibility already (hidden panes pause,
background tabs skip); feeding it through on bump makes rook one of the
first hosts of a protocol agents-in-terminals will want — and rook's own
occlusion saga (PERF.md 2026-08-07) is independent evidence the protocol is
needed.

**Also additive:** `setScrollbackMaxBytes/MaxLines` (`86f81fb5b`) — runtime
scrollback limits rook can wire to config; `fc5a72772` codepoint-width API
(in pin, rook already uses it).

### Bump verdict

Do it soon and whole — not cherry-picks. The cost is measured and small (one
patch deleted, two callback signatures, zero symbol renames, same Zig); the
payoff is the security series plus REP/fast-styles/reflow/formatter perf.
Then re-run `app/bench.sh` and the same-machine cat A/B per PERF.md's
standing rule. One process note: upstream is *leaving GitHub* (announced
2026-04-28, destination TBD — https://mitchellh.com/writing/ghostty-leaving-github);
the fork's fetch URL and rook's tarball pin will need re-pointing when the
migration lands. Track it.

---

## Scar tissue: Ghostty's macOS fixes as executable specs

Same method as the Zed pass. Ghostty's renderer is Metal, its font stack is
CoreText, its input path is NSTextInputClient — rook's exact exposure
surface, three years deeper. The full mined list (~60 commits) is grouped
below; each is a bug rook can have, with the fix commit as the spec. rook
targets are `app/src/macos.zig` (AppKit/IME/mouse/display), `app/src/render.zig`
(Metal/atlas/fonts), `app/src/session.zig` (paste/OSC52).

### Highest-leverage meta-lessons (each shipped as a bug ≥2 times)

1. **Atlas/grid generation, not grid dimensions, keys dirty tracking.**
   Ghostty shipped "DPI changed but cols/rows didn't → cached rows point at
   old atlas coordinates → garbled text" three times across two renderers
   (`61fd7f7fb` 2024 → `16a61c43d` 2025-02 → `1cc22f93c` 2025-10; triggers:
   sleep/wake, lid open, display move). rook's dirty-skip renderer + one
   atlas is exactly this shape. Spec: any font-grid/atlas change invalidates
   every cached cell; key caches on an atlas generation counter. (This
   compounds zed-analysis's stale-scale finding — same trigger, second
   failure mode.)
2. **Resize is a two-thread ordering contract.** `7929e0bc0`: sending resize
   to renderer and IO thread independently let the renderer clear its GPU
   buffers, then bail because terminal state was still the old size — a
   visible blank flash on every shrink. Spec: terminal state first, renderer
   told after, always from one origin. And `3b8ab1077`: the renderer clamps
   to *its own* grid defensively — any terminal/renderer size desync was
   memory corruption, not just misdraw.
3. **`NSScreen` identity is unstable; `CGDirectDisplayID`/UUID is stable.**
   Three separate bugs (`1ae932295`, `ea505ec51` — weak-keyed NSScreen maps
   drop live screens; `0274e7ad8` — stale per-display frame restored after
   replug). rook's display-link retarget + future window-frame persistence
   must key on display UUID.
4. **The IME contract:** the apprt owns translation, dead keys, and preedit;
   the core receives translated events; **any key that touches preedit state
   is consumed** (`b3cb38c3f` is the architectural statement; ~15 follow-up
   fixes are deviations from it, each user-visible).
5. **Every `CTFontCreate*/Copy*` is nullable, and descriptors carry
   non-enumerable magic** — never rebuild a descriptor from its own
   attributes (`a34740613`: rebuilt descriptors lose the private state that
   instantiates hidden system fallback fonts → Times New Roman substitution;
   `d166c05ed`, `daeed25b3`: NULL returns).

### Font fallback / emoji / CoreText (rook: render.zig font path)

- Fallback: last-resort via `CTFontCreateForString` after descriptor
  matching, rejecting the LastResort font; all CT ranges are UTF-16 units
  (`1aa932f81`). Monospace is a scoring preference, never a hard filter —
  and never applied to fallback or user-explicit faces (`2fb14eee0`..
  `224b39b86`). Variation axes applied at instantiation, not discovery
  (`e08eeb2b2`/`94542b04f`).
- Emoji/VS: presentation is a preference with a defined resolution order,
  never a hard requirement (`3d8dd0783`, `80c0ba875`); constraints apply to
  the cluster base, not every part (`f0080529c`); **exclude ZWJ from
  "one font must cover the cluster"** or the shaper walks every installed
  font per ZWJ emoji (`42c4f5271` — a stall class); VS15/16 bind to the
  immediately *preceding* codepoint (`3f11e695d`); honoring VS15 width
  means walking the cursor back (`fdd22ec78`); standalone emoji modifiers
  are width 2 even though wcwidth says 0 (`631c58a30`); emoji constrained
  to exactly 2 cells, centered (`5553f7bf6`); Apple Color Emoji ordered
  after all text faces (`19f003d7d`).
- Shaping: force LTR via typesetter embedding-level, then still check
  `CTRunGetStatus` and sort non-monotonic output (`efc6e0d67`,
  `712cc9e55`); CoreText does not emit padding cells for
  ligature-consumed cells — emit them yourself (`9b4e362a3`); shaper font
  caches invalidate on every grid/size change and key on font pointer
  identity (`12e8d96b1`); `dlig` off by default — it corrupted Japanese
  via obsolete-Kanji ligatures (`eb96ff075`).
- Metrics: split leading half-above/half-below (`947ebc069`); round cell
  width/height, never ceil (`45b8ce842`, `1fd7606db`); `USE_TYPO_METRICS`
  bit chooses typo vs win metrics (`8a5d48472`); clamp minimums *last*
  (`0557bf830`); sanity-check ic_width against measured ASCII extents
  (`6781fbda9`); recompute decoration positions after any cell-height
  adjustment and bounds-check sprite rasterization (`53b029284`,
  `81a6c2418`).
- Rasterization: do your own quantization — `kCTFontSubpixelQuantization`
  drops edge pixels (`a67b8b35f`/`579b15bef`); bitmap extent =
  ceil(bearing+bbox) or glyphs clip (`fff16bff6`); bearing errors show up
  as ±1px "wiggle" when bold toggles on a live line — test exactly that
  (`e1e2f823b`); pad the CGContext when thickening, you cannot measure it
  (`a3247366f`).
- Nerd Font: derive constraint/scale-group tables from font-patcher data,
  don't hand-curate (`4af93975e`); exempt Powerline geometry from PUA
  constraints and treat box/powerline neighbors as whitespace for the
  full-size heuristic (`fad0b9a49`, `1907c5897`) — rook ships to Nerd Font
  users (FiraCode NF is the PERF.md font); this is p10k-prompt correctness.

### Resize (rook: macos.zig viewResized + render.zig)

Beyond meta-lessons 1–2: draw nothing before first size (`4c2fbe8f7`);
publish new size metrics synchronously at the resize event (`90d24f9e8`);
`setContentSize` moves the window — apply position after it (`b4a5ddfef`);
zero `contentResizeIncrements` makes AppKit misbehave (`77114d792`); clamp
every texture to `MTLDevice.maxTextureSize` (`07b47b87f`); CSI 14 t reports
grid extents (cols×cellw), not view extents with remainder pixels
(`4f1cee8eb` — rook answers size reports via the `size` effect today);
resize failure paths must not corrupt tabstops/state on OOM (`91f0cf67d`
et al.).

### IME / NSTextInputClient (rook: macos.zig — rook ships IME + dead keys)

The big five beyond the contract:
- **IME-commit-during-keyDown must suppress the key event** for *any* key,
  not just arrows — Ghostty's `ctrl+j` bug: commit fired via `insertText:`
  AND the original key encoded LF (`d60a16c14`; iterations `fa141a726`,
  `751a60df6`).
- **Input-source change mid-key = IME consumed it**: snapshot
  `TISCopyCurrentKeyboardInputSource` around `interpretKeyEvents:`; AquaSKK
  mode-switch keys otherwise reach the pty as garbage (`4ffd281de`).
- **Binding pre-checks must be pure** — Ghostty's "would this match a
  binding" probe ran translation and fired preedit callbacks as a side
  effect, leaking characters (`730c6884f`). rook's leader/which-key arming
  test is the analogous probe.
- **`setMarkedText:` outside keyDown is real** — candidate-window mouse
  selection changes preedit with no key event (`ded9be39c`); Esc clears
  composition locally, never forwards (`9326ae363`).
- **Option-as-alt consumed for translation must not reappear as a
  modifier**: `e70ca0b9b` broke European layouts in a *release* (option+8 →
  `[` encoded as alt+[), and `5001e2c60` is the mirror (alt consumed but
  AppKit dead-key state still armed). rook's keyenc memory ("Option
  composes, it isn't Alt") is the same territory — these two commits are
  its regression suite.
- Also: filter PUA U+F700–F8FF from `NSEvent.characters` before treating as
  text (`ecda5ec32`); keys diverted to `doCommandBySelector:` never reach
  keyDown and must be replayed (`4031815a8`); `firstRectForCharacterRange`
  must return the real preedit rect + account for padding (`e8217aa00`,
  `2409d4660`); preedit cells participate in dirty tracking or they
  visually thicken (`3c074b5ae`); selection clears when preedit changes
  (`6c5c5b2ec`).

### Mouse reporting (rook: macos.zig mouseCallback + session mouse encoding)

- **Wheel reports are per-click, never per-window-height** (`34388ab5d` —
  Ghostty scaled events with grid size; every other terminal sends one), and
  the scroll multiplier applies to viewport scroll only, never to reports
  (`dbba3f1a6`). macOS pseudo-precision deltas for slow discrete wheels are
  ~0.1 — round out to magnitude ≥1 or slow scrolling does nothing
  (`6cf636b1a`).
- One coordinate transform for cell AND pixel (SGR-pixel) reports — padding
  was subtracted from one and not the other (`97db055b5`).
- Shift is a *modifier* for motion events until a button is pressed, and a
  bypass only for buttons (`1d09cdb38`); a bare modifier change generates no
  report (`ad6a5e7ae`); the focusing click is consumed (`f22893395`).
- The (-1,-1) mouse-exit sentinel needs a mouse-enter reset or button-mode
  reporting stays dead until motion (`4e47b2ab6`); reset all gesture state
  on focus loss — phantom drags otherwise (`6092c299d`); zellij-style
  title-spam synthesizes same-position mouse moves that defeat
  hide-while-typing — discard <1px motion (`2a4140146`).
- Alternate scroll (1007): off by default, arrows only up/down, DECCKM
  decides SS3 vs CSI (`d85baa463` family) — rook's alt-screen wheel path
  (zed-analysis live-bug #alt-screen-wheel) should adopt all three at once.
- NSCursor state is owned by `cursorUpdate:` alone; enter/exit only feed it
  (`954c4d7b5`, `1eb0dbb54`).

### Clipboard / OSC 52 / paste (rook: paste.zig, session.zig)

- rook already matches the two big ones: xterm control-char sanitization
  regardless of bracketed paste (`37e902d90`) and treating embedded
  `ESC[201~` as unsafe (`fb7cbd69c`) — STATUS.md claims xterm's safety rules
  and zed-analysis verified stripping. Keep the spec list: non-bracketed
  `\r\n`→`\r\r`, `\n`→`\r` (`010338354`).
- OSC 52 *reads* never answered — now upstream doctrine in the effect type
  itself (`0a410f18e`: "a VT state library has no way to mediate that with
  user consent"). rook's write-only stance is validated; keep it through the
  multi-MIME signature change.
- Empty OSC 52 payload = clear, per xterm — rejecting it was a bug
  (`d3f40d70e`).
- `NSPasteboard` is synchronous where GTK was async: a clipboard request
  satisfied re-entrantly inside the requesting call deadlocked under a held
  surface lock (`db60e981d`) — rook's clip_pending main-thread handoff
  (`session.zig:118`) is the right shape; don't ever "simplify" it into a
  direct call from the reader thread.
- Overlapping OSC 52 confirmations: completing request B inside request A's
  callback invalidated live state → crash; defer to the next main-queue turn
  (`57c1baf43`).
- Swift-side but universal: byte lengths at FFI boundaries, never character
  counts (`4b01163c7`); write exactly one `public.utf8-plain-text`
  representation (`f3352dd90`).

### Fullscreen / Spaces / displays / Metal lifetime (rook: macos.zig, render.zig)

- **Never mutate `styleMask` while fullscreen** — a title update restyling
  the titlebar dropped first responder after the first command
  (`c8243ffd9`); exiting native fullscreen recreates the window and reapplies
  default styling (`88674a195`).
- Fullscreen state machine: observe the `NSWindowDidEnter/ExitFullScreen`
  notifications as truth — menu-bar-initiated fullscreen bypassed Ghostty's
  own toggle (`f384fd038`). rook drives fullscreen for its best latency
  mode; a stale fullscreen flag would silently cost the 8.5ms→15.5ms
  direct-scan-out win.
- `windowNumber` can be ≤0 before the window has a device (`9b7891724`);
  AppKit can throw `NSInternalInconsistencyException` selecting a tab in
  native fullscreen — wrap in an ObjC exception catcher (`8696bef64`).
- **Display link:** re-target on display change or vsync against the wrong
  refresh rate (`ca9689be4` — rook's 60Hz-external finding in PERF.md's
  08-07 addendum is this exact geometry); creation *fails* with no active
  displays (screen locked, clamshell) — it's optional, fall back to
  event-driven and resync on display-config change (`a177ba90a`). rook's
  immortal-link strategy (zed-analysis) stays right; add the retarget and
  the creation-failure tolerance.
- Occlusion: recompute on view-hierarchy changes too, not just window
  occlusion notifications — Ghostty's drag-a-surface-to-another-tab left a
  surface permanently invisible-but-live (`2c6dd5940`). Freeing GPU
  resources on occlusion was tried and reverted as too disruptive
  (`b5d543705`→`e10e45a93`) — rook's pause-don't-teardown matches.
- **vsync stays on:** with vsync off, macOS 14.4/14.5 could *kernel panic*
  and DisplayLink-connected externals crawled (`d7b37a900`).
- Metal lifetime: null the layer's display callback before releasing the
  renderer — the view can hold the layer past teardown and CA will call a
  freed context (`4b4a5b241`); explicitly retain autoreleased ObjC objects
  stored from non-ARC code (`8b23e73d2` — rook is exactly this consumer via
  zig-objc); release `MTLTextureDescriptor`s (`1f733c9e7`).
- Live resize: set `CAMetalLayer.backgroundColor` so newly exposed area
  stretches the bg for free instead of flashing transparent (`34abe2ceb`).
- Blending/color: blend in one defined space; linear blending needs
  luminance-dependent alpha correction or dark text thins (`fca336c32`);
  explicit SGR backgrounds stay opaque under background-opacity while
  default-bg cells go transparent — conflating them is the bug
  (`78790f6ef`) — rook's fillPane default-bg alpha branch (PERF.md seventh
  re-run) sits on this exact line; port the distinction test.
- `Buffer.sync` arithmetic: Ghostty shipped a 64× over-allocation from
  multiplying a byte size by `sizeOf` again (`4a22eed6d`) — rook's comptime
  layout asserts (render.zig:225-229) are the right instinct; extend them to
  allocation-size math.

---

## Strategy: Ghostty, libghostty, Superlogical, and rook's wedge

Full sourcing in this section from primary posts; the four load-bearing facts:

1. **Ghostty-the-app stays a narrow native terminal.** 1.2 (2025-09) shipped
   OSC 9;4 progress bars, command palette, unified renderer
   (https://ghostty.org/docs/install/release-notes/1-2-0). 1.3 (2026-03)
   shipped scrollback search, key tables/chained keybinds ("tmux-like modal
   keybinding workflows"), rich clipboard, AFL++-fuzzed parser — and fixed
   "a major memory leak that Claude Code regularly triggered," present since
   1.0 (https://ghostty.org/docs/install/release-notes/1-3-0;
   https://mitchellh.com/writing/ghostty-memory-leak-fix). 1.4 (Sept 2026
   target, milestone 12): scriptability, **tmux control mode** — Ghostty as
   a native *client* to a tmux server, not a daemon — and graphical prefs.
   Session persistence/detach requests are explicitly deprioritized
   (https://github.com/ghostty-org/ghostty/discussions/12571). No 2.0 has
   been discussed publicly. Non-profit since 2025-12
   (https://mitchellh.com/writing/ghostty-non-profit).
2. **libghostty is the actual bet, and it has already won by adoption:**
   100+ downstream projects (https://github.com/Uzaaft/awesome-libghostty),
   including Coder (`ghostty-web`, `libghostty-vt-node`, and `boo` — a
   screen-style multiplexer), Emacs terminals, iOS SSH clients — and
   notably "over 25 tools designed for coordinating AI coding agents" — all
   before a single tagged release (API still marked unstable,
   https://libghostty.tip.ghostty.org/). The 1.3 notes state the maintainers
   expect libghostty to outgrow the app itself.
3. **Superlogical is where the multiplexer went**
   (https://mitchellh.com/writing/superlogical, 2026-07-29): a company whose
   first product is a server-side multiplexer on libghostty — server holds
   authoritative session state, clients render locally ("requires every
   connecting client be a very smart, high-functioning, compliant client" —
   which is what libghostty provides), web + macOS + iOS clients, live
   session sharing, reconnect across devices. Press framing (InfoWorld,
   2026-08-03) is explicitly agentic: tmux "was built for a human watching
   one terminal, but agents now run for hours in the background, and
   existing tools have zero awareness of whether an agent is waiting for
   your approval or still thinking." Mitchell's own post pledges to keep
   upstreaming shared terminal work — and the `terminal/snapshot` +
   continuation series in the MIT repo is visibly that pledge executing.
4. **Performance leadership is real, freshly won (2026-07-06), and lands in
   the library** — "These changes are directly in libghostty, too, so
   everyone wins" (Mitchell). rook is "everyone."

### Where Ghostty's trajectory threatens the wedge

rook's wedge is "default terminal for Claude Code" (NEXT.md thesis lineage):
multiplexer + editor + agent-orchestration in one native binary.

- **The benchmark narrative.** rook's 1.77x-over-Ghostty headline is against
  1.3.1; the honest comparison is nightly, where the remaining gap is rook's
  own IO loop. When Ghostty 1.4 ships (Sept 2026), the installed-version
  comparison collapses. rook should fix the read loop *before* 1.4 lands so
  the same-machine A/B stays a rook win against the shipping Ghostty.
- **Agent table stakes are appearing in Ghostty first.** OSC 9;4 progress
  (1.2), command-finished notifications gated on unfocused/min-duration
  (1.3), click-to-move via OSC 133, "OSC 99 desktop notifications" open in
  the 1.4 milestone. None of this is orchestration — but it is exactly the
  polish a Claude Code daily driver feels, and today Ghostty has it and rook
  doesn't. The bump delivers the VT halves (`progress_report`); rook owes
  the chrome halves.
- **Superlogical vs the phone story.** rook's remote-asks/mailbox/phone
  direction (docs/agent/VISION.md) now has a venture-shaped neighbor whose
  pitch is agent-session awareness across devices. The overlap is real at
  the "answer your agent from your phone" layer. The divergence is equally
  real: Superlogical is server-side, multi-client, enterprise,
  session-sharing; rook is local-first, one binary, and owns the *editor
  and review surface* around the sessions. Watch their beta for what
  "agent-aware" concretely means to them; do not race them on
  remote-session infrastructure — race them on attention quality at the
  glass.
- **tmux control mode in 1.4** partially answers "I want my Ghostty windows
  to be durable sessions" via tmux underneath. That's a competitor to
  rook's future pty-persistence story, with tmux's model as the ceiling.
  rook's answer (snapshot-based restore now, Zig detach later, per
  docs/OWED.md) leapfrogs it only if it actually ships.

### Where it's irrelevant

- Ghostty has no editor, no LSP, no file tree, no config graph, no plugin
  runtime, no review surface, and its governance now structurally resists
  scope growth (non-profit, narrow-mission, maintainer bandwidth visibly
  constrained by the GitHub migration). The entire environment-identity
  thesis is uncontested.
- Machine-wide Claude Code session visibility, digests, attention raising —
  neither Ghostty (out of scope) nor visibly Superlogical (server-side,
  spawn-what-you-manage) does the "see every agent on the box, including
  ones you didn't launch" trick that rook's plugins/claude does.
- libghostty's embedder ecosystem (Neovim GUIs, Emacs, iOS clients) grows
  the *library* rook already uses; every embedder normalizes the core rook
  ships. Rising tide.

### Strategic recommendations

1. **Treat the upstream repo as a supply chain, formally.** A quarterly bump
   cadence with a standing checklist (Effects diff, security grep of
   `src/terminal` log, bench re-run) — this analysis is iteration one.
   Re-point the fork before the GitHub migration completes.
2. **Fix the IO loop before Ghostty 1.4 ships** so the public
   same-machine A/B stays honest and favorable.
3. **Ship the agent-polish parity items** (progress in chrome,
   command-finished attention) as small plugin/chrome slices — they're
   cheap, they're what a Claude Code user notices in week one, and Ghostty
   has made them the baseline.
4. **Adopt `vt.snapshot` for restore rather than inventing a format** — it
   is maintained by the people building a commercial multiplexer on it,
   which makes it the most battle-tested terminal-state wire format that
   will exist.
5. **Don't chase Superlogical's layer.** Their bet is session
   infrastructure; rook's is attention + editor + local execution. The
   InfoWorld framing of their gap ("zero awareness of whether an agent is
   waiting for your approval") is a description of rook's shipped attention
   system — rook's job is to make that visibly true before their beta
   defines the category vocabulary.

---

## Appendix: reproduction

- Clone: `scratchpad/ghostty`, remotes `origin` (ghostty-org) + `fork`
  (incantery). Pin located via `git merge-base FETCH_HEAD origin/main` =
  `ab0b9da9e`.
- Perf partition: `git merge-base --is-ancestor <commit> ab0b9da9e` over the
  candidate list (table above reproduces the output).
- VT surface diff: `git diff ab0b9da9e..origin/main -- src/lib_vt.zig
  'include/ghostty*' src/terminal/stream_terminal.zig src/terminal/Terminal.zig`.
- rook-side verification: `app/src/session.zig:406-437` (readLoop),
  `app/src/pty.zig:163-167` (single read), `app/build.zig.zon:40-42` (pin),
  `app/build.zig:29-36` (module import), grep of `vt.*` symbol usage.

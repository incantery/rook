# Host integration: making the server terminal live

*Scoping plan, 2026-07-21. Companion to `2026-07-21-server-terminal-design.md`
(the ratified design) and its Phases 1–3, which are built, tested, and shipped
in v0.9.9 — but **unwired**. Nothing outside their own tests imports
`internal/vt/*` or `frontend/src/term/vt/*`. This plan is the cutover that
Phases 2 and 3 named ("Host answers all terminal queries"; "Drop xterm.js") and
deliberately deferred, because it is the first work that touches the
daily-driver daemon.*

## What "done" means

The Go emulator (`internal/vt`) runs per session inside `rook-host`, fed by the
pty. The client renders `Frame` diffs with `GridRenderer` (`frontend/src/term/vt`).
xterm.js is gone from the bundle. `termquery.go` and both frontend query-suppression
regexes are deleted. The daily-driver bar (frame-time on scroll + firehose,
already gated in Phase 3) holds on real sessions — vim, claude, git, a `yes`
firehose.

## The seam today (measured, not assumed)

The live path, end to end (from the transport map, file:line grounded):

- **Host** — `internal/host/host.go`. `spawn()` (`:250`) starts a pty via
  `creack/pty`; `readPump()` (`:308`) reads 32 KiB chunks, appends them verbatim
  to a 512 KiB per-session ring (`ringCap`, `:39`), and writes them verbatim as
  **WebSocket binary frames** (`:328`). Input is raw bytes the other way
  (`handleAttach`, `:1259`); resize is a separate `POST /sessions/{id}/resize`
  → `pty.Setsize` (`:1192`). **There is no envelope** — the only typed signal in
  the whole transport is a single text frame literally spelling `"live"`
  (`:1249`).
- **Reattach** — `handleAttach` (`:1224`) replays the ring in 32 KiB chunks
  under a lock, then sends the `"live"` sentinel. The frontend arms a 1.5s gate
  on open and lifts it on the sentinel (`manager.ts:499`, `:503`).
- **Query answering is split and fragile** — `termquery.go` answers DA1/DA2/DSR5/
  DECRQM host-side (injected as pty input, never ringed). **xterm.js answers the
  rest** (CPR, DECRQSS, OSC 4/10-12 palette) from its own `ITheme`. Two frontend
  regexes paper the seam: `HOST_ANSWERED` (`manager.ts:195`) drops what the host
  already answered; `REPLAY_ONLY` (`:197`) drops CPR/OSC/DECRQSS **only during
  replay**, because a replayed query's asker is gone but a live one must pass.
- **Theme** — `buildXtermTheme` (`theme/xterm.ts:9`) feeds one `ITheme` into
  xterm; that same palette both answers OSC queries and colors glyphs.
- **Coupling to preserve** — `focusedInAltScreen` (`manager.ts:256`) reads
  `term.buffer.active.type` to route keybinds around fullscreen TUIs. The new
  renderer must expose an equivalent.

## The two ends are ready; three gaps remain

Verified by reading both ends directly:

- `Emulator` exposes `Write`, `Render(surface)` (frame-cadence diff),
  `TakeOutput()` (drains native query replies — **this is the termquery.go
  replacement**), `ScrollbackLen/Cell`, `NewSurface`. **Gap: no `Resize`.**
  (`Render`'s `resyncSurface` already self-heals a geometry change into a full
  resend, so `Resize` is a screen/ring reallocation, not a rewrite.)
- `GridRenderer` exposes `applyBytes(wire)`, `queue()` (rAF coalescing),
  `scrollLines/scrollToBottom/scrollOffset`, selection/copy/a11y, `destroy`.
  **Gaps: no `resize()`, and no input-forwarding callback** — its `onKeyDown`
  only handles scrollback nav; nothing forwards keystrokes/paste to a pty, and
  nothing reports alt-screen state.

## Decisions to ratify

### HI-1 — Straight cutover, single code path (decided 2026-07-21)

**Decided by Seth, against the recommended dual-serve.** No `localStorage` flag,
no side-by-side endpoints. The framed path replaces the raw path in place; when
we cut over (HI-C) we delete the old path rather than keeping both. Flip-back is
`git revert` + rebuild, not a runtime toggle. Seth accepts that a cutover bug
bricks the daily-driver terminal until reverted, and that an old client cannot
talk to a new host across the cutover — in exchange for one code path and no
dual-protocol tax.

*Consequence for the phasing:* HI-A stays non-destructive **not** by a flag but
by being **additive and unwired** — the framed endpoint + emulator loop are new
code nothing calls yet, gated by a test client, so the live path is untouched
while it is built. The destructive moment is concentrated in HI-C, where the
swap is atomic: `/attach` starts serving Frames, xterm and `termquery.go` are
deleted in the same change. Contrast the standing `rook-host-protocol-skew`
lesson (fail open on new host signals) — here we consciously trade that
resilience for simplicity, so HI-C must land as one coherent, well-tested change
rather than a slow migration.

### HI-2 — A typed transport envelope, both directions

**Proposed.** Replace untyped-binary + the `"live"` text sentinel with a
1-byte-tagged envelope. Server→client: `Frame` (the wire.go payload), plus
control tags for cursor-only updates, bell, and session state (alt-screen,
title, geometry-ack). Client→server: `Input` (bytes to pty), `Resize`
(cols,rows), and `ScrollbackFetch` (the request HI-D needs). The Frame payload
is already versioned (wire v2); the envelope wraps it.

### HI-3 — Reattach becomes a blank-Surface snapshot

**Proposed.** On attach, allocate a fresh (blank) `Surface`; the first `Render`
against it *is* the snapshot (the whole non-blank screen), gap-free by
construction. This **retires**: the ring-replay loop (`host.go:1224`), the 512 KiB
byte ring for replay purposes, the `"live"` sentinel, the 1.5s replay gate, and
**both** `HOST_ANSWERED`/`REPLAY_ONLY` regexes — the entire replay-seam
machinery collapses into "new client, blank surface." This is the single largest
simplification in the cutover.

### HI-4 — The emulator owns every query answer

**Proposed.** All terminal query answers come from `Emulator.TakeOutput()`,
routed to the pty after each `Write`. This retires `termquery.go` wholesale and
lets us finally answer CPR/DECRQSS/OSC 4/10-12 natively (the boundary
`termquery.go:27` explicitly punted to xterm). The theme palette feeds the
**host** emulator now (for OSC answers); glyph coloring stays client-side CSS
vars (`style.ts` already resolves ANSI colors from `--vt-*` custom properties),
so theme flows to both — host for answers, renderer for pixels.

### HI-5 — Per-session render cadence, only when attached

**Proposed.** A per-session frame loop `Write`s pty output into the emulator as
it arrives and calls `Render` on a bounded cadence (coalesce-on-idle, ~display
rate), emitting a Frame only when non-`Empty`. A session with no attached client
runs the emulator (keeps its ring) but renders nothing — the "only the viewed
terminal costs anything" property, made concrete. (Full lazy parse-on-view is
spec Phase 4, out of scope here.)

### HI-6 — Alt-screen state travels in the protocol

**Proposed.** The session-state control message carries the alt-screen flag so
the frontend keybind router keeps working without reaching into renderer
internals — the explicit replacement for `term.buffer.active.type`.

## Phased plan

Each phase clears a gate before the next. HI-A is additive and unwired — new
code nothing calls yet, so the live path is untouched while it is built. HI-B
wires it up; HI-C is the atomic, irreversible swap-and-delete (HI-1).

- **HI-A — Protocol + emulator gaps (additive, unwired). DONE (2026-07-21).**
  Built the tagged envelope (`internal/host/termframe.go`: `msgFrame` out;
  `msgInput`/`msgResize` in) on `/sessions/{id}/framed`; `Emulator.Resize`
  (clip/pad, no reflow, shrink→scrollback); the per-session render loop feeding
  off a blank Surface (first Render = snapshot) coalescing at 16 ms; `readPump`
  feeds the emulator alongside the legacy ring, draining+discarding its query
  replies (termquery.go still owns the raw path). Frontend: `keymap.ts`
  (`keyToBytes`), `GridRenderer.resize()` + `onInput` sink + paste. Nothing in
  the live mount calls any of it. *Gate met:* `internal/host/termframe_test.go` —
  a framed client driving a real pty (pipe + real pty pair) reconstructs the
  emulator's grid byte-for-byte via `vt.DecodeFrame`+`ClientGrid` (SGR + wide
  chars survive); a resize resends the whole screen at the new geometry; input
  reaches the pty; no query reaches the client (structural — Frames never carry
  the out buffer). Race-clean. 9 keymap units + 5 input/resize browser cases.
- **HI-B — The renderer as the live pane. DONE (2026-07-21).** `GridRenderer`
  replaced xterm in the mount (manager.ts `Tab.renderer`); input forwarding via
  `onInput`→`encodeInput`; resize computed from the box + measured cell →
  `encodeResize`; keybind routing from `tab.alt` (the wire, HI-6); reattach as a
  blank-Surface snapshot (HI-3), so the replay gate / `"live"` sentinel /
  `HOST_ANSWERED`+`REPLAY_ONLY` regexes are gone. Theme flows through the
  `--term-*` CSS vars the service already writes. `readPump` now routes the
  emulator's query replies to the pty and `termquery.go` is deleted (HI-4, minus
  OSC). *Gate met:* `make e2e` 46/46 against the real app + daemon — nvim in a
  pane (alt-screen, keybind routing, full-screen redraw, input, file write) and
  reattach-without-double-typing among them.
  - **OSC follow-up — DONE (2026-07-22).** The emulator holds the theme palette
    and answers OSC 4/10/11/12 (`osc()` in query.go), seeded to a dark default so
    a program never hangs. The client pushes the palette over `msgPalette` on
    attach and on every theme change (App subscribes to `themeService.onPalette`;
    manager broadcasts). Gated by unit tests (OSC query/set) + a host test
    (msgPalette sets the bg, OSC 11 answers it).
- **HI-C — Delete the remaining dead path. DONE (2026-07-22).** Removed the raw
  `/attach` route, `handleAttach` (ring-replay + `"live"` sentinel),
  `session.attach`/`wmu`/`detach`, and `attach_test.go`; `hostapi.attach`;
  `theme/xterm.ts` (`buildXtermTheme`) + spec; `service.ts`
  `onXterm`/`xtermTheme`/`xtermSubs` + the ITheme import; and the
  `@xterm/*` dependencies. The ring stays — `correlate`/`normRing` read it.
  xterm.js is out of the tree and off the dependency list. Suites green,
  `make e2e` 47/47.
- **HI-D — Scrollback fetch.** The `ScrollbackFetch` request (HI-2) that closes
  the two gaps the scrollback commit (6071a2d) deferred here: **fresh-attach
  history** (a newly-attached pane seeing output from before it connected) and
  the **fast-scroll gap** (a burst larger than the screen leaves intermediate
  lines only in the server ring). The server already holds the data; this is the
  request path to it.

## Risks and honest caveats

- **This touches the daily-driver daemon, and HI-1 declined the flag.** The only
  mitigation is that HI-A is additive/unwired and HI-C is one atomic change; a
  cutover bug bricks the terminal until `git revert`. Accepted deliberately.
- **OSC 4/10-12 answering is new code**, not ported — `termquery.go` never did
  it (xterm did). The palette must reach the host, and the answers must match
  what programs expect (vim reading background color is the live case
  `REPLAY_ONLY` exists for).
- **Resize/reflow.** HI-A does resize as full-resend (correct, not clever);
  reflow parity is spec D7/Phase 5, still out of scope — a resize will not
  rewrap history in v1.
- **HI-C is a big-bang change** (no incremental migration, per HI-1). Mitigated
  by concentrating all deletions into one well-tested commit, not by staging.
- **Keybind routing** depends on the alt-screen signal (HI-6) being as timely as
  xterm's synchronous `term.buffer` read; a Frame-cadence signal could lag by a
  frame. Measure before trusting.

## Non-goals (this plan)

- Lazy parse-on-view / visibility-tiered damage (spec Phase 4).
- Reflow on resize (spec Phase 5 / D7).
- The agent MCP terminal tools (spec Phase 5 / D8).
- Predictive/local echo (spec D1 measured it a ~5 ms footnote).

# Threads sidebar: move the conversation out of Monaco

*Design spec, 2026-07-13. Ratified in conversation with Seth. Refines the
UI half of the threads design
([2026-07-12-threads-design.md](2026-07-12-threads-design.md)): the
conversation surface moves from Monaco view-zones into a Svelte pane. The
host thread API, anchoring, and the conversation loop are unchanged — this
is a frontend-only reshape of how threads are read and driven.*

## Why

The 2b threads UI renders conversations as **interactive Monaco
view-zones** — textareas and buttons living inside the editor's own DOM.
That is the root of the current flakiness: view-zones are not meant to be
interactive, so the widgets fight Monaco's keyboard/focus handling and the
backtick leader-key layer. The symptoms are the workarounds themselves —
the one-shot `focusReply` dance, the `zoneBusy`/`hasDraft` guards, the
disposed-refetch guarding — every one a patch over *interactive DOM living
inside the editor*.

Moving the conversation into normal Svelte DOM **outside** Monaco deletes
that entire class of bug structurally, not with more guards. It also
shrinks the framework-free island to what it should own — the code surface
— and lets the thread card become a reusable Svelte component the 2c
attention inbox will render too.

The trade we accept: we lose GitHub-style comments interleaved with code.
rook's review flow is triage (jump → read → reply → resolve → next), not
leisurely inline reading, and the gutter markers preserve *where*. Worth
it.

## Principle

**Code surface = island; conversation = chrome.** Monaco keeps only what
is code-aligned (gutter markers, a read-only anchor highlight, jump). Every
interactive affordance — history, reply, resolve/reopen, the composer —
lives in a Svelte pane. The two talk over a deliberately narrow seam. No
Svelte inside Monaco; no Monaco inside the pane.

## Architecture

The layout is a **global side-pane system** (VS Code-style) wrapping the
workbench, plus a narrow seam from the editor island up into it. Two
distinct pieces:

- **Chrome (Svelte):** `#app-screen` becomes a row —
  `[#terminals workbench] [right side pane]`. The side pane is Svelte
  chrome, a sibling of the workbench, **never inside `editor-wrap`**. The
  thread panel is a placement-agnostic tenant slotted into it.
- **Island (framework-free):** the editor pane (`term/editor.ts`) stays
  imperative DOM and loses all conversation UI, exposing only a seam.

### The seam (island ↔ chrome)

`ThreadBand` (`frontend/src/term/threads.ts`) shrinks to a **read-only
decoration layer**:

- **Keeps:** gutter glyph decorations (`markerLines` + `glyphClass`), the
  `onMouseDown` gutter-glyph hit-test, and a **new read-only range
  highlight** for the active thread's anchor.
- **Loses:** the entire view-zone machine —
  `openZone`/`closeZone`/`refreshZone`/`sizeZone`/`buildCard`/
  `buildActions`/`openComposer`, the `zones` map, `composer`,
  `zoneBusy`/`hasDraft`, and the `focusReply` one-shot. All of it becomes
  Svelte.

Three signals out, two calls in:

- **Out (island → chrome):**
  - `onMarkerClick(line, threadIds)` — a gutter glyph was clicked.
  - `onComposeSelection(startLine, endLine, side)` — ⌘⇧M / context-menu on
    a selection.
  - `activeSide` context so the pane knows which diff side it addresses.
- **In (chrome → island):**
  - `revealAndHighlight(threadId | range)` — jump Monaco into view and
    paint the read-only anchor highlight.
  - `clearHighlight()`.

`BandHooks` (reply / resolve / reopen / create) **moves up to chrome** —
the thread panel calls `hostapi` directly. The island does zero
conversation logic and does not route mutations.

**Active-editor binding.** `App.svelte` already constructs each
`EditorPane`. It holds `activeEditorPane` (the most-recently-focused
editor pane) and wires its seam to the thread panel; when a terminal is
focused instead, the panel idles (empty state). With splits, more than one
editor pane can exist — the panel tracks whichever was focused last.

### The side pane + thread panel (Svelte chrome)

Two Svelte layers, deliberately split so placement is configurable and the
panel is not:

- **`SidePane`** — the slot. A container parameterized by `side`
  (`"left" | "right"`), `visible`, and width; renders one panel. Only the
  **right** slot is mounted this slice. Open by default, **toggleable**
  via a header affordance + a keybinding in the keymap (consistent with
  the `` ` `` leader layer). Collapsing hands the width back to the
  workbench.
- **`ThreadPanel`** — the tenant. Self-contained and **placement-agnostic**:
  it knows nothing about which side hosts it. Takes the active editor
  pane's seam + `hostapi`, holds **one thread at a time** (single-select),
  and reuses `threadview.ts` (DOM-free) for its view-model. The same
  component the 2c inbox can render.

**Built with left + dynamic panes in mind (YAGNI on building them).** This
slice ships the right slot with `ThreadPanel` as its sole tenant. It does
**not** ship a left pane, a panel registry, or user-configurable
placement — but the `SidePane`/`ThreadPanel` split is exactly so a left
slot and slot-to-panel configuration drop in later without touching the
panel. `ThreadPanel` must never reference "right"; `SidePane` must never
reference threads.

## Pane state machine

Three states, driven by the seam signals:

- **empty** — nothing selected. Placeholder ("select a gutter marker, or
  select code and ⌘⇧M to comment"). Also the state after file-nav.
- **composer** — a new pending range is being written. Shows the anchor, a
  textarea, Save/Cancel. Save → `hostapi.createThread(range, side, body)`
  → refetch → transition to **thread** on the new id; the pending gutter
  marker appears. Cancel → **empty**, nothing created. (The host create
  endpoint takes range + first comment body in one call, so the composer
  collects the first comment before anything hits the host.)
- **thread** — one existing thread: state chip, comment history, reply
  box, resolve/reopen. **Outdated** threads render `anchorText` in a
  `<pre>` (the frozen snapshot) and still jump Monaco to the best-effort
  re-anchored line.

## Interactions

**Gutter ↔ pane, bidirectional, single-select:**

- Marker click → `onMarkerClick` → pane loads that line's **top-ranked**
  thread (state rank pending > open > resolved, matching today's
  `glyphClass` order) → `revealAndHighlight`.
- Loading a thread → `revealAndHighlight` paints the read-only anchor
  highlight; switching away → `clearHighlight`.

**Stacked threads on one line:** show the top-ranked thread with a
**`‹ N of Y ›`** control in the pane header to cycle within that line's
stack. Single-thread view is preserved; the indicator makes the stack
navigable instead of hidden.

**File-nav clears the pane to empty.** Threads are per-file; the new file's
markers repaint from its own threads. No stale thread lingers across a
switch.

**Composing:** select a range in Monaco → "Comment on selection" (⌘⇧M /
context-menu) → Monaco highlights + reveals the range → pane enters
**composer**.

**Submit stays in the editor head** — "submit N comments" flips all
pending → open; it is workspace-level, not thread-level, so it does not
belong in a single-thread pane. Unchanged from today.

**Draft safety, now trivial.** The textarea lives in normal Svelte DOM
outside Monaco — no focus-disarm, no leader-key fight. The one surviving
rule: auto-refetch (on focus / interval) must not clobber a thread or
composer holding unsent text. That becomes a plain "textarea is non-empty"
guard in the component, replacing the `zoneBusy`/`hasDraft`/`focusReply`
gymnastics.

## Error & edge handling

Mostly inherited from today's patterns:

- Stale-daemon **404** on any thread call → the editor pane's existing
  flash + inline error; never fatal (protocol-skew rule — fail open).
- **Create / reply / resolve failures** surface inline in the pane; the
  component keeps the unsent text (a failed reply is never an eaten
  draft).
- **Outdated / pruned blob** → render `anchorText`, jump to best-effort
  line; never an error.
- **Submit** unchanged: `typed` / `spawned` flash; 404 → "needs a newer
  rook-host."

## Testing

This slice adds **vitest** — the frontend's first committed test runner
(today's `threadview.ts` "tests" are ad-hoc scratchpad scripts). Node
environment, no jsdom; the view-model is pure so no DOM is needed.

- **`threadview.ts` unit tests** (vitest, pure view-model): stack ranking
  + `N of Y` selection, marker-line computation, active-highlight range,
  empty / composer / thread transitions, file-nav reset.
- **Manual GUI checklist** (Seth's standard for pane work, covers the
  DOM/Monaco/seam wiring vitest can't reach): marker-click loads + jumps +
  highlights; ⌘⇧M composes; save creates + transitions; cycle a stacked
  line; resolve / reopen; outdated rendering; toggle the pane closed /
  open; file-nav clears; terminal-focus idles the panel.
- **No new host/Go tests** — frontend-only; the host thread API is
  unchanged.

## Not in this slice

- The 2c attention inbox and the `rook-threads` skill (still owed from the
  original design; the shared thread-card component built here is the
  reusable piece the inbox will render).
- A **left pane**, a **panel registry**, or **user-configurable
  placement** — the `SidePane`/`ThreadPanel` split is built to accept them
  later, but only the right slot + thread tenant ship now.
- A multi-thread list view (single-thread + `N of Y` cycling is the model;
  a list can grow later if a file routinely carries many threads).
- Any host, anchoring, or rookctl change.

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

`BandHooks` (reply / resolve / reopen / create) **moves up to the pane**
and calls `hostapi` directly. The pane no longer routes conversation
mutations; the island does zero conversation logic.

### The thread pane (Svelte chrome)

A contextual **right pane** inside the `` ` g`` review/diff pane and
`` ` e`` file viewer (layout: the sidebar is a sub-region of the editor
pane, not a peer in the window strip). VS Code-style:

- **Open by default**, **toggleable** closed/open via a header affordance
  and a keybinding registered in the keymap (consistent with the existing
  `` ` `` leader layer). Collapsing hands the width back to Monaco.
- Holds **one thread at a time** (single-select). Reuses `threadview.ts`
  (already DOM-free) for its view-model and shares its thread-card
  rendering with the future 2c inbox.
- **Scope guard (YAGNI):** we build only this right thread pane. The
  open/collapse mechanism is generic enough that a future left pane (file
  tree, etc.) could reuse it, but no left pane and no general pane
  framework ship in this slice.

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

- **`threadview.ts` unit tests** (pure view-model, the existing pattern):
  stack ranking + `N of Y` selection, marker-line computation, active-
  highlight range, empty / composer / thread transitions, file-nav reset.
- **Component tests** for the pane's three states and the draft-safety
  guard (refetch must not clobber a non-empty textarea).
- **Manual GUI checklist** (Seth's standard for pane work): marker-click
  loads + jumps + highlights; ⌘⇧M composes; save creates + transitions;
  cycle a stacked line; resolve / reopen; outdated rendering; toggle the
  pane closed / open; file-nav clears.
- **No new host/Go tests** — frontend-only; the host thread API is
  unchanged.

## Not in this slice

- The 2c attention inbox and the `rook-threads` skill (still owed from the
  original design; the shared thread-card component built here is the
  reusable piece the inbox will render).
- A left pane / general pane framework.
- A multi-thread list view (single-thread + `N of Y` cycling is the model;
  a list can grow later if a file routinely carries many threads).
- Any host, anchoring, or rookctl change.

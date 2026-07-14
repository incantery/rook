# Threads panel: from one-at-a-time to a filtered list

*Design spec, 2026-07-14. Ratified in conversation with Seth. Refines the
threads sidebar
([2026-07-13-threads-sidebar-design.md](2026-07-13-threads-sidebar-design.md)):
the panel stops showing a single selected thread and instead renders the
whole file's threads as a scrollable, filterable list of collapsible cards.
Sourced from the `Rook Threads.dc.html` claude.ai/design mockup. Frontend
only — the host thread API, anchoring, and conversation loop are unchanged.*

## Why

The current `ThreadPanel.svelte` is a **single-thread view**: it shows
exactly one thread, chosen by the last gutter-marker click, and an empty
state otherwise. To read a second thread you click a different marker; the
list of what exists on this file lives only in the gutter. That is fine for
"jump to the marker I clicked" but poor for **triage across a file** — you
cannot see at a glance how many threads are open, which are resolved, or
skim their snippets without hunting markers.

The mockup answers this with a **list**: every thread for the file, as a
card, with filters (Open / Resolved / All) and counts. One card expands at
a time into the full conversation. The gutter-marker seam still drives
selection (click a marker → its card expands and the editor reveals), but
the panel is now the index, not just the reader.

## Scope

**In (Layer 1 — visual/structural, on the existing API):**

- Thread **list** for the active file, sorted by line, replacing the
  single-thread view.
- **Filter tabs** — Open / Resolved / All — client-side over the file's
  threads. Header shows total + open counts.
- **Collapsible cards**: collapsed shows state dot + label, `#num · Lxx`,
  code snippet, message count; expanded shows the conversation (avatars,
  author, relative timestamp, body), reply input + Send, and a footer with
  Resolve/Reopen + "attached to Lxx".
- **New-thread composer** at the top of the list, driven by the existing
  `onCompose` seam signal, showing the anchored snippet.
- **Empty states** — no editor bound → existing "focus a review or file
  pane" copy; empty filter → "No threads in this filter."
- **Footer hint** — "click any line to start a thread · agents reply here".
- **Ask the agent** on `pending` threads → `api.submitThreads(ws)` (the
  real nudge).

**Out (Layer 2 — deferred, no backend exists):**

- "Proposed revision" block and "Apply to working tree".
- Finer agent states (`thinking` / `answered` / `proposed`). The panel
  renders only the real backend states: `pending` / `open` / `resolved`.

## Principle

**Same seam, richer chrome.** The narrow editor seam
(`EditorSeam` in `term/editor.ts`) is unchanged: marker-click / compose /
change come up, reveal / clearHighlight go down. All new structure —
filtering, cards, expand/collapse, the conversation render — lives in the
Svelte panel and its pure view-model. No host changes, no seam changes.

**House palette, not the mockup's.** The mockup ships oklch colors and
Google-hosted IBM Plex Sans / JetBrains Mono. rook is framework-free with
no external font deps and a CSP. We take the mockup's **layout and
component structure** and render it in rook's existing tokens
(`--acc #82aaff`, `--grn #c3e88d`, `--amber #ffcb6b`, `--red #ff5370`,
`--fg`, `--dim`, `--lo`, `--mono`, system-ui). No oklch, no web fonts, no
new dependencies.

**Inline Tailwind utilities, per README decision 7.** rook is mid-migration
from `app.css` classes to Tailwind v4 utilities; the policy (stated at the
top of `app.css`) is to convert a surface to utilities when it is being
touched anyway. This full rewrite qualifies, so `ThreadPanel.svelte` is
styled with **inline Tailwind utilities in markup** — no new `.tp-*` class
block, no `@apply`. The `@theme` block exposes the palette as colour
utilities (`text-acc`, `bg-amber`, `text-grn`, `text-lo`, `font-mono`, …).
`--line`/`--raise` are not theme colours, so hairline borders/surfaces use
white-alpha (`border-white/10`, `bg-white/[0.02]`). The four small shared
classes the design still needs — `.thread-input`, `.thread-err`,
`.thread-anchor`, `.thread-active-line` — stay in `app.css`; the dead
single-thread rules (`.thread-card`, `.thread-row`, `.thread-state*`,
`.thread-meta`, `.thread-comment`, `.thread-author*`, `.thread-body`,
`.thread-reply`, `.thread-nav`) are deleted.

**SidePane owns the title.** The panel mounts inside `SidePane`, which
already renders a "Threads" header + close button and a
`overflow-y:auto` body. The panel therefore shows no redundant title —
its own top row is the filter tabs + counts — and it lays itself out as a
flex column filling the body (sticky filters, scrolling list, sticky
footer hint).

State → accent: `pending` → amber, `open` → acc (blue), `resolved` → grn.

## Architecture

Two files change; one is new logic in an existing file.

### `term/threadview.ts` — pure view-model (extended)

New pure, DOM-free helpers so the node spec (`threadview.spec.ts`) can pin
them:

- `fileThreads(all, path)` — the threads to list: this file, both sides,
  sorted by `currentStart` then `id`.
- `filterThreads(threads, filter)` — `"open"` (state ≠ resolved, i.e.
  pending + open) | `"resolved"` | `"all"`.
- `stateMeta(state)` → `{ label, tone }` where `tone ∈ {amber, acc, grn}`.
  Labels: `pending → "Pending"`, `open → "Open"`, `resolved → "Resolved"`.
- `openCount(all)` / `resolvedCount(all)` — header counts.
- `relTime(iso, nowMs)` → `"3m"` / `"2h"` / `"5d"` / `"just now"`. `nowMs`
  is injected so the helper stays pure and testable.
- `avatar(author)` → `{ initials, isAgent }` — agent → `"R"`, user →
  `"me"` (no authenticated identity exists; a fixed neutral glyph).
- `snippetOf(thread)` — the collapsed-card code line: first line of
  `anchorText`, trimmed, `"(blank line)"` when empty.

Existing helpers (`bandThreads`, `markerLines`, `glyphClass`,
`threadStack`, `pickFromStack`, `cycleStack`, `contextKey`, submit/nudge
helpers) stay — the gutter still uses them.

### `ThreadPanel.svelte` — rewritten

State:

- `threads: ThreadInfo[]` — from `editor.threads()`, resynced on
  `onChange`.
- `filter: "open" | "resolved" | "all"` — default `"open"`.
- `selectedId: number | null` — the one expanded card (mirrors the
  mockup's single `selected`).
- `composer: { startLine, endLine, side } | null` — new-thread composer,
  opened by `onCompose`.
- `draft: string` — shared text for the new-thread composer **or** the
  expanded card's reply (only one is active at a time, so one field is
  safe — same invariant the current panel relies on).
- `err`, `busy` — unchanged semantics.

Behavior:

- **Bind to seam** (`$effect` on the `editor` prop) exactly as today:
  `sync()` on mount + `onChange`; `onMarkerClick` selects+expands the
  matching thread and `reveal`s it; `onCompose` opens the composer and
  clears `selectedId`. File-context change (`contextKey`) resets
  `filter`? No — resets `selectedId`, `composer`, `draft`, `err` (filter
  persists as a user preference within the session).
- **Selecting a card** toggles `selectedId` (click header again to
  collapse) and `reveal`s the thread. Marker-click always expands (never
  collapses) so the gutter stays a "show me this" gesture.
- **Reply / Resolve / Reopen / createThread** reuse the existing `run()`
  wrapper (busy + refetch). Post-create, select the new thread as today.
- **Ask the agent** (only on `pending`) calls `api.submitThreads(ws)` via
  `run()`. It is a workspace-level batch (flips all pending → open); the
  button copy and a small caption make that honest rather than implying a
  per-thread send.
- Keyboard: `⌘⏎` submits the active composer/reply; `Esc` collapses the
  card or cancels the composer (existing `keydown` helper, retargeted).

### Styling

Inline Tailwind v4 utilities in `ThreadPanel.svelte` markup (see the
principle above). Rounded cards (`rounded-xl`), state-toned dot + label via
a static `tone → class` lookup (Tailwind scans source for literal class
names, so never `bg-${tone}`), avatar chips, filter pills, mono snippets —
all from `@theme` colour utilities + white-alpha surfaces. `app.css` change
is a **deletion** of the dead single-thread rules; the four shared classes
above stay. No `@theme` edits, no new `.tp-*` classes.

## Data mapping (mockup → real model)

| Mockup | Real source |
|---|---|
| `state: pending/thinking/answered/proposed/resolved` | `ThreadInfo.state: pending/open/resolved` (three only) |
| `messages[].author "you"/"agent · fable"` | `ThreadComment.author "user"/"agent"` → "you" / "agent" |
| `messages[].when "3m"` | `relTime(ThreadComment.created)` |
| `snippet` | `snippetOf(thread)` from `anchorText` |
| `line "L18"` | `L{currentStart}` (`–{currentEnd}` when a range) |
| `msgCount` | `comments.length` |
| Proposed revision / Apply | **omitted** (Layer 2) |
| `Ask the agent` | `api.submitThreads(ws)` |

## Testing

- `threadview.spec.ts` gains cases for the new pure helpers:
  `filterThreads` across all three filters, `stateMeta` tone/label per
  state, `relTime` boundaries (just-now / minutes / hours / days),
  `snippetOf` blank-line fallback, `fileThreads` path filter + sort,
  `openCount`/`resolvedCount`.
- Manual: build the frontend, drive a review — create, reply, resolve,
  reopen, filter, expand/collapse, marker-click sync, new-thread composer.

## Non-goals

- No host/Go changes. No new endpoints.
- No proposed-revision or apply-to-tree (deferred to a Layer 2 spec).
- No gutter-marker redesign — the seam and glyphs are untouched.
- No web fonts / oklch adoption.
- No `@theme` token additions and no `@apply` — inline utilities only.

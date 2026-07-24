# Thread buffers v2 — file-projected threads

*A thread stops being a read-only rendering with ex-command verbs bolted on
and becomes a **document you edit**: history above a scissors line, your
draft below it, `:w` to keep it, `:ThreadNote`/`:ThreadAsk` to commit it.
Truth stays structured in the DB; the buffer is a host-rendered projection.*

Ratified in conversation, 2026-07-23. Supersedes the composition half of
[2026-07-20-comment-buffers-design.md](2026-07-20-comment-buffers-design.md)
(the draft split, `,c`/`,?`, batch submit) and builds the review↔threads
bridge that [2026-07-17-rooktask-review-design.md](2026-07-17-rooktask-review-design.md)
declared but never wired (`rook_task_id`, the `pending` leaf state).

## Thesis

The comment-buffers pass proved the governing rule — *meaningful text is
edited in a buffer* — but kept the transport web-shaped: a transient draft
pane per utterance, a sidebar-era submit batch, and a thread buffer you could
read but not write. Editing a conversation through one-shot forms is the same
mistake as editing a file through a textarea per line.

The fix is the mail-file model. The thread IS a file, projected on demand:

- **A thread is a document you edit; truth stays structured.** The host
  renders the projection and, on save, diffs what it handed out against what
  came back. The DB rows (comments, state, anchors) remain the source of
  truth; the buffer is a view with one writable region.
- **Append-only history, enforced by prefix check.** Saved content must start
  byte-for-byte with the rendered history through the scissors line;
  everything below is the user's tail. Not a parser — `strings.HasPrefix`.
- **The tail is a mutable draft.** `:w` is silent (stores the draft, wakes no
  agent). `:ThreadNote` commits the tail as a comment without summoning the
  agent; `:ThreadAsk` commits it and nudges. History crystallizes only on
  those verbs.
- **Mutable state never renders into the saved document.** Current anchor
  mapping, whose-move, outdated — that lives in pane chrome and decorations.
  The prefix is therefore stable across reads, and a concurrent agent reply
  merges by re-render + tail splice. No conflicts are possible: the only
  writable region is yours alone.
- **`gt` is dual: go-to-or-create** (like `gd`). Thread under cursor → open
  it; none → create one anchored at cursor/selection, cursor lands below the
  scissors. This replaces `,c`/`,?`/`:reply` — one gesture, one model.
  And it is gd-shaped in GEOMETRY too (amended 2026-07-24, dogfood): the
  thread opens IN the pane you're standing in — no split, no transient pane
  — and `⌃O` walks back. `:ThreadAsk` and `:resolve` walk back for you (the
  thread is off your plate); `:reopen` stays. Navigating away from an
  untouched gt thread deletes it, same as `:q`.

## The thread document format (the public contract)

Rendered by the HOST (`internal/host/threaddoc.go`), not the frontend —
`renderThread` in `threadview.ts` survives only for the hover preview.

```
---
thread: 42
anchor: internal/host/reanchor.go:120-134 (modified)
created: 2026-07-23
---

## seth · 2026-07-23 14:02

Why is this named skipCache?

## claude · 2026-07-23 14:05 · session abc123

Because the call sites …

-- ✂ -- reply below · history above this line is read-only --------------------
```

- Frontmatter holds **immutable facts only**: id, the anchor *at creation*,
  created date. Anything that can change (current mapped range, state,
  outdated) would break the prefix, so it stays out.
- One `##` heading per comment: author · timestamp · agent session when
  known.
- The scissors line is a single line with a fixed prefix (`-- ✂ --`); the
  host matches the rendered prefix through and including it. Everything after
  is the tail/draft.
- Resolved threads render with **no scissors** and open read-only.
- Key hints (`:ThreadAsk` etc.) go in the pane's `noteEl` chrome, never the
  document.

### The save protocol

- `GET /threads/{id}/doc` → `{content, resolved}`; content = rendered
  history + scissors + stored draft.
- `POST /threads/{id}/doc {content}` — the host re-renders the prefix fresh
  and prefix-checks. Match → everything after the scissors is stored as the
  draft, 204. Mismatch → **409 with `{content}`** (the fresh doc) so the
  client re-renders and splices its local tail back under the new history.
  A hand-mangled history gets the same 409 — the honest error.
- `POST /threads/{id}/note` — crystallize the stored draft as a user
  comment; 400 on empty draft.
- `POST /threads/{id}/ask` — crystallize, then the existing single-thread
  submit path (submit + nudge + deliver-error bookkeeping).
- `POST /workspaces/{ws}/threads` accepts an empty body → a thread with zero
  comments (the `gt`-create path; anchor snapshot exactly as before).
- `DELETE /threads/{id}` — guarded: only comment-less, draft-empty threads
  (the `gt`-then-`:q` abort path). 409 otherwise.

## `:Command` — the ex-command bridge

Registry commands become ex commands by derivation: `thread.ask` →
`:ThreadAsk`, `review.approve` → `:ReviewApprove`. Config may declare aliases
in a `[commands]` TOML table (`Alias = "command.id"`), following the
`[keybinds]` precedent — unknown ids fail open with a warning.

Frontend-only. This is NOT the host plugin system: it's a dispatch seam in
the one shared Vim singleton, registered with each full name as its own
prefix so nothing collides with vim's abbreviations.

## Git gutter in normal buffers

`GET /workspaces/{ws}/gutter?path=&base=` diffs the base blob (HEAD, or the
active review's scope base) against the working tree through the existing
hunk machinery, and the file pane paints `linesDecorations` stripes: added
green, modified blue, a triangle at a deletion boundary. `]c`/`[c` walk
hunks. Review reading therefore needs no special diff mode — the real file,
with change context in the margin.

## Reviews jump to normal files

A review leaf opens the REAL file at the leaf's *reanchored* range (the
anchor struct is shared between `ThreadInfo` and `RookTask`; review payloads
gain `currentStart/currentEnd/outdated` computed on read). The gutter
supplies the change context the diff pane used to.

Threads created while a review is active auto-link (`rook_task_id`):

- anchored **inside a leaf's current range** → linked to that leaf, and the
  leaf flips to `pending` — which blocks the gate (`reviewtasks.go` already
  counts `pending` as blocking; now something actually sets it). Resolving
  the last open linked thread flips the leaf back to `proposed`.
- anchored **elsewhere** → linked to the review parent. The local-vs-global
  comment distinction, for free.

## What dies

- `DraftSpec`, `loadDraft`, `submitDraft`, the `kind:"draft"` pane arm, and
  `compose()`/`composeOn` as a separate flow (folded into `gt`-create).
- `,c`/`,?` keybinds and the ⌘⇧M editor action; `App.openDraft`.
- `:reply` (the tail replaces it). `:resolve`/`:reopen`/`:source` stay.
- The batch-submit UI (`submitLabel`, the threads-context submit `prepare`).
  The host batch endpoint survives for rookctl compat.
- `ThreadBand.renderZones` — the inline zone rows (glyphs, highlight rule and
  hover stay).
- Legacy `stateMeta`/`STATE_ORDER` in threadview.ts (status is the ranking).

## Deferred (revisit from dogfood)

- **Deleted-line virtual text** in the gutter (the deletion triangle is the
  only marker this round).
- **The review hero's final shape** — it stays as the analysis card;
  shrinking it further is a dogfood call.
- **Batch submit removal from rookctl** — the agent surface keeps
  `reply`/`resolve`/`threads` and the batch endpoint until the new loop has
  proven itself.
- **Nudge-string updates** — the responder prompts still speak rookctl's
  existing verbs; teaching them `thread doc` comes later.

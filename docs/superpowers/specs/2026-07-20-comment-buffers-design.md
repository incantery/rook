# Comments are buffers

*Composing a comment moves out of the sidebar and into a real Monaco document
opened in a split below its source. The governing rule: **UI may appear inside
the source editor, but meaningful text is edited in a buffer.***

## Thesis

The first commenting pass worked and felt wrong, and the wrongness was not
polish. A sidebar thread card is a web form bolted to the side of an editor:
it separates the code from the conversation about the code, it needs its own
focus handling, and it presents a half-formed thought as a formal discussion
thread. The whole-line highlight compounded it by covering the source, making
the code read as inactive — backwards, since the code is the subject and the
comment is the attachment.

Monaco content widgets and view zones can render arbitrary HTML, textareas
included, so they *could* host composition inside the editor. They shouldn't.
A textarea in a view zone is not part of the editable document, so it brings a
second editing model with its own focus, keyboard handling, undo stack,
selection and vim behaviour. Two editing models in one editor is the problem,
not the fix.

A virtual editable document is the better primary abstraction, and rook was
already shaped for it: `PaneRef` is a kind-tagged union where an arm carrying
identity is a *document*.

## The workflow

```
visual-select code
  → ,c (note) or ,? (ask)
  → a split opens below with an empty draft buffer
  → write it with normal vim
  → :w
  → thread created, split closes, focus back in the source
  → a rule in the margin and a dot in the gutter remain
```

## What this buys from machinery that already existed

- **vim, undo, registers, `:` for free.** Each `EditorPane` owns an
  independent monaco-vim instance, so the draft gets a real mode line and the
  full editing model with no new keyboard code.
- **`:w` routes itself.** Ex commands dispatch through the `paneByEditor`
  WeakMap, so `:w` in a draft reaches *that* pane's `save()` with no special
  casing at the command layer.
- **Focus returns on its own.** `removePaneLocal` hands focus to the spatial
  neighbour, and a split-below's neighbour is the source buffer. Step 8 of the
  workflow is emergent, not implemented.
- **The buffer ladder can't touch it.** `openFile`'s retarget predicate is
  `c.type === "file"`; a `draft` arm is invisible to it, so `:e` can never
  hijack a draft mid-sentence. This is the reason it's its own arm rather than
  a `file` with a synthetic path.

## What had to be built

- **`PaneRef` gains `{type: "draft"; id}`** (layout.ts) — a document, but a
  transient one: it exists until `:w` hands it off or `:q` discards it.
- **`TermManager.splitWith(dir, content, mk, frac?)`** — `splitFocused` was
  terminal-only (it unconditionally calls `api.create`), so there was no way
  to split *any* non-terminal pane into existence; the only alternative,
  `openPaneWindow`, mints a whole strip window. A draft wants neither: it
  belongs beside its code and must not take a strip digit for the ten seconds
  it lives. `frac` exists because `splitAt` divides evenly and a three-line
  comment should not get half the window (0.25).
- **`EditorPane` kind `"draft"`** — an in-memory `markdown` model on a
  `rook-draft://` URI, language *declared* rather than inferred (no filename
  to read a suffix from), editable from the start (`editable` otherwise only
  becomes true after a successful file read), and every file-assuming path
  branched: `load`, `uri`, `currentPath`, `context`, `position`, `title`,
  `save`/`doSave`.
- **`setLeafFraction`** (layout.ts) — give a leaf a share, scale its siblings.

## `:w` is the git-commit contract

`:w`, `:wq` and `:x` all create the thread and close the split. `:q` refuses
while the buffer is dirty; `:q!` discards. This is deliberately not strict vim
semantics — there is no file to keep editing, and the buffer exists to be
handed off, exactly like a commit message. Every vim user already has the
muscle memory.

An empty buffer is refused rather than silently closed: swallowing the gesture
is worse than saying so.

The draft opens in **NORMAL**, also like a commit buffer. Landing in insert
would save one keystroke and cost a worse one — a vim hand types `i` on
arrival by reflex, which in insert mode is a stray character.

## Composing must leave VISUAL

Consuming a selection has to return the editor to NORMAL, the way any operator
does, and collapse the cursor to the start of the range.

This is not tidiness. Left in VISUAL, the *next* motion extends the stale
selection instead of moving the cursor, so the following comment silently
anchors to the previous one's range. It was found by an e2e asserting the
second comment's anchor, not by reasoning about it — which is the argument for
asserting anchors rather than "a thread was created".

Monaco also keeps *painting* the old selection after vim's mode changes, and
that wash competes with the anchor rule for saying what the comment is about;
hence the explicit `setPosition`.

## The anchor mark

A 2px rule in the line-decorations margin, plus the existing gutter glyph. The
whole-line 18% wash it replaces covered the code it was pointing at.

The rule is painted while composing too — otherwise the draft names its range
only as text in a header, and the selection that made it is gone the moment
focus leaves, so you would be writing about a range you can no longer see.

## Reading: buffers and a navigation verb, not view zones

The first plan for reading was an inline view zone under the anchored line.
That was rejected, and the reasons generalize:

1. **A view zone breaks vim's line model.** It occupies screen ROWS without
   occupying buffer LINES, so `j`/`k`, `⌃D`/`⌃U`, `zz`, `H`/`M`/`L` and
   relative numbers all stop agreeing with the document — right where the code
   is densest, since that's where the anchors are.
2. **It can't be a jump target.** A thread buffer records a jump on the way in,
   so `⌃O` walks back to the code. That was the original framing — comments as
   *navigation targets* — and it only works if a thread is a real pane.
3. **Long threads.** Ten replies in a view zone shove the source apart by forty
   rows. In a buffer they scroll, search, fold and yank like anything else.
4. **It would be a third rendering model.** Source buffers, draft buffers, and
   a widget. The buffer version is one abstraction with a read-only flag —
   which is already how rook renders read-only files.

So: **`,t`** opens the thread under the cursor as a read-only markdown buffer,
and **hover** (mouse, or `K`) previews it without displacing anything.

Hover is the right home for preview because it's ephemeral, and because
`provideHover` returns an ARRAY of markdown blocks that Monaco stacks — so a
thread and the language server compose instead of competing. Threads sort
first: they're the rarer thing on a line, and an LSP hover can be long enough
to push them out of sight. This is also the concrete reason threads are NOT on
the LSP server rook exposes to nvim (see the comments-lsp spec): clients merge
diagnostics across servers but *arbitrate* hover, so only the editor owning
both sources can merge them.

The thread buffer leads with the CONVERSATION. Fencing the anchored source at
the top pushed the first comment below the fold of a short split, and it's
redundant while the thread is still anchored — that code is in the pane you
came from. The snapshot appears only when the anchor DRIFTED, which is the
whole reason `anchor_text` is stored. A reload reveals the end of the
conversation, because a reload means something was added.

Its verbs are ex commands — `:reply`, `:resolve`, `:reopen`, `:source`. They
read as what they do, need no keymap layer inside a read-only buffer, and
route per-pane through the same `paneByEditor` map `:w` uses. `:reply` opens a
draft buffer, so composition still has exactly one model.

## The sidebar is gone

Threads are a work list like review hunks, grep hits and references, so they
read through the one traversal muscle memory: **`` ` t``** opens them as a
quickfix context, `j`/`k` moves, `o` opens the thread buffer, `s` jumps to the
source, `x` resolves. `quickfix.svelte.ts` named threads as an intended tenant
from the start.

That deletes `ThreadPanel.svelte`, the right side pane, `app.threadPaneOpen`,
and `MODES` (whose only job was deciding whether the right pane opened). The
two leaders end up symmetric, which is a happy accident worth keeping:
`` ` t`` lists every thread, `,t` goes to the one under the cursor.

## Decisions

- **Composition is a buffer; display may be in-editor.** The rule that decides
  every future question here.
- **One composition model.** `,c`, `,?` and ⌘⇧M all land on `opts.onCompose`.
  The panel's composer is deleted, not hidden — two ways to write a comment is
  the thing being fixed.
- **A draft is not registered in `editorPanes`.** It is not a document the
  buffer ladder should find, retarget, or refetch.
- **A draft never calls `onActivate`.** It has no threads of its own;
  announcing it would rebind the thread panel to an empty context and blank
  the list for the source the user is still looking at.

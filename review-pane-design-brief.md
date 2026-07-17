# Design brief — the Review experience

You are redesigning the **review** surface in **rook**, a desktop workbench for
directing AI coding agents. It works and it's wired to real data; it looks
rough. Make it feel considered, calm, and legible — without changing what it
does or the design system it lives in.

**Deliverable:** revised markup + Tailwind classes for two Svelte components —
`frontend/src/ReviewItem.svelte` (the hero — the bespoke hunk detail) and
`frontend/src/ReviewPanel.svelte` (the ranked list / index). Raw CSS only where
utilities genuinely can't reach. Keep all behavior, props, state names,
keyboard handling, and host calls exactly as they are — this is a
visual/interaction-polish pass, not a rewrite. Explain your reasoning as you go.

_(Attach the current screenshots when you hand this off — they show the list on
the left and the bespoke hunk overlay filling the center.)_

---

## The idea (read this — it's the whole point)

rook's thesis: the bottleneck in software is no longer writing code, it's
**reviewing, understanding, and directing** code that agents wrote. This surface
is where a developer triages a change as a set of **hunks** and disposes of each
until a **gate** says the whole thing is ready.

**We deliberately do NOT center the diff.** Every other tool — GitHub, the IDEs,
Graphite — centers the diff, and centering it is the one thing rook has no edge
at. rook's edge is _context_: it can tell you what a hunk is _for_ and what to
_check_, not just what changed. So the frame is inverted:

> The unit of review is a **decision**, not a diff. Each hunk is a small claim —
> "this change does X; here's what to watch" — and the reviewer's job is to
> **adjudicate the claim with evidence at hand**. The diff is _evidence_ inside
> that decision, not the subject.

The feeling to design for is **attention compression**: a 40-hunk change should
_feel small_. The reviewer eliminates the boring fast (read a one-line summary,
defer), and spends real attention only on the few hunks that need a human. Every
part of the design should serve that: land the eye on what matters, make
disposing of a hunk feel like progress, make "ready to commit" feel earned.

Mechanics that should read in the design:

- **The batch is disposable; the disposition is durable.** You prepare a review
  (hunks appear `proposed`), then approve / reject / defer each. Your
  _decisions_ are the valuable, accumulating state.
- **States carry different weight.** `proposed` (untriaged), `approved` (done,
  good), `rejected` (wants change — blocks), `deferred` (set aside, non-blocking
  — the "3,000 lines of docs I'll skim later" case), `pending` (a conversation
  is open).
- **The gate is a goal, not a status.** "19 of 20 blocking" → "ready to commit."

---

## Two surfaces (both are yours to design)

### 1. `ReviewItem.svelte` — the hero: one hunk as a decision

A center overlay (fills the viewport; it is NOT the code editor). This is where
the reviewer lives. Today it stacks, top to bottom:

- **Header:** state glyph, `path:line`, the state word, a `i / n` position
  counter, prev/next (`k`/`j`) and close (`esc`) buttons.
- **Analysis card:** Haiku's read of the hunk — a `category` chip, `risk`/
  `understand` scores, a one-sentence `summary` of what the change does, and a
  short list of `concerns` ("things a human should check"). When unscored, it
  shows a prompt to run scoring.
- **The diff:** the hunk's own patch, rendered by us (added lines green-tinted,
  removed red-tinted, context muted) — evidence, sitting _below_ the intent.
- **Note box:** "drop a thought on this hunk" — the whiteboard. A free-text
  reaction the reviewer dumps without ceremony.
- **Disposition:** Approve / Reject / Defer buttons (with `a`/`r`/`d` hints).

This is the surface that has to feel like "adjudicating a claim with evidence,"
not "reading a diff in a modal." The **analysis is the star**; the diff is
supporting. Right now it's a plain vertical stack — give it real hierarchy,
rhythm, and a sense that the top (why look) and bottom (decide) frame the
evidence in the middle. It's keyboard-driven (see below); design for that, not
for hover.

### 2. `ReviewPanel.svelte` — the index: a ranked list of hunks

A left side pane (fixed `w-88` ≈ 352px), one tenant of a generic `SidePane` that
already renders the "REVIEW" title + close. Today each row is: a state glyph,
the repo-relative file path (mono), the start line, and — when scored — an
optional `category` line and a small `risk` badge. A gate line + prepare/refresh
button sit up top; keybind hints in the footer. The currently-open hunk gets a
left accent border.

It's the calm index you scan; selecting a row opens the hero. Problems to solve
here: **no file grouping** (a file with six hunks shows six identical
`frontend/src/App.svelte` rows — repetitive and hard to parse), **flat
hierarchy** (nothing guides the eye; use state + risk to create it), and the
**gate reads as a tiny status** when it's the headline. Consider grouping by
file, and using the scoring data so a risky untriaged production hunk doesn't
look like a deferred doc hunk.

---

## Interaction model (do not regress this)

Keyboard-first. In the **list**: `j`/`k` move a roving cursor, `Enter`/click
opens the hero, `a`/`r`/`d` quick-disposition the cursor hunk. In the **hero**:
`a`/`r`/`d` dispose (and auto-advance to the next hunk), `j`/`k` move between
hunks, `esc` closes, typing in the note box is never hijacked. The design must
work when there are 2 hunks and when there are 60, and read well without a
mouse.

### Data available (design around this, don't invent endpoints)

Per hunk (`RookTask`):

```ts
{
  state: "proposed" | "approved" | "rejected" | "deferred" | "pending",
  path: string,          // "frontend/src/App.svelte"
  startLine: number,
  endLine: number,
  side: "modified" | "original",
  anchorText: string,    // the hunk's unified-diff body (+/- lines) — what the hero renders
  detail?: {
    category?: string,   // "internal docs, no prod impact"   (only once scored)
    score?: { risk?: number, understand?: number },  // 1..5   (only once scored)
    summary?: string,    // one sentence: what this change does (only once scored)
    concerns?: string[], // things a human should check          (only once scored)
    note?: string,
  }
}
```

Gate: `{ ready, verb, blocking, total, counts }` where `verb` is
"commit" | "PR" | "approve" | "next steps".

Design for **both** the scored and unscored states — scoring is an async Haiku
pass that may not have run yet, so `summary`/`concerns`/`category` are often
absent. The unscored hero should still be coherent (path + diff + disposition).

---

## Design system (stay inside it)

- **Reference for quality/idiom:** `frontend/src/ThreadPanel.svelte`. Match its
  polish, density, and card conventions. Read it first.
- **Styling (hard rule):** inline Tailwind utility classes in the markup. **No
  `@apply`, no extracting components for style reuse, no new dependencies.**
  Duplication across rows/sections is fine and expected.
- **Theme-aware, dark-first.** Use the semantic color tokens, never raw hex.
  Design to the token _names_ so it survives a re-theme.

  | token | value | role |
  |---|---|---|
  | `fg` | `#d6deeb` | primary text |
  | `dim` | `#8f93a2` | secondary text |
  | `lo` | `#5b6273` | tertiary/muted |
  | `acc` | `#82aaff` | accent (selection, focus, primary) |
  | `grn` | `#c3e88d` | approved / added / ready |
  | `amber` | `#ffcb6b` | attention / deferred / blocking |
  | `red` | `#ff5370` | rejected / removed |
  | `magenta` | `#c792ea` | spare accent |
  | `bg` | `#0f111a` | base (the hero fills this) |
  | `sunken` | `#0a0c14` | recessed (the diff block, inputs) |
  | `raise` | `white/3.5%` | raised card surface (analysis card, side pane) |
  | `overlay` | `#151928` | overlays |
  | `on-acc` | `#10131c` | text on an accent fill |
  | `line` | `rgb(140,150,180)` | borders (usually `border-line/15`) |

  Patterns already in the codebase: `text-fg`, `text-lo`, `text-acc`,
  `bg-acc/15`, `border-line/15`, `bg-grn/10`, `bg-fg/[0.06]`, `text-on-acc`,
  `size-2 rounded-full bg-grn`. **Literal class strings only** — Tailwind scans
  source, so `bg-${tone}` emits nothing; map tone → literal class names (see how
  ThreadPanel does `TONE_BG`/`TONE_TEXT`, and how these two files already do).
- **Constraints:** the list is 352px, fixed. The hero fills the center viewport
  (variable, wide). Each is its own scroll region. Keyboard-first.

---

## What "good" looks like

A reviewer opens a 40-hunk change and immediately feels _this is smaller than it
looks_. The list's gate tells them where they stand; the hunks are grouped so
the shape of the change is legible; state and risk are obvious at a glance. They
open a hunk and the hero reads like a briefing: here's what this is _for_,
here's what to watch, here's the evidence, here's your call — calm, not
cramped. Disposing feels like progress. When the last blocking hunk clears,
"ready to commit" feels earned.

Propose redesigned markup for both components. You may suggest small,
data-derived additions (a file group header, a progress ratio from the gate
counts, a risk-sorted order) as long as they use the data above. **If a change
would need new host data, call it out separately** rather than assuming it —
don't design around endpoints that don't exist.

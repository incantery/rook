# The UI design system

Rook's chrome is one system: the scope bar across the top, the calm
bar across the bottom, the borders between panes, the root canvas
and its figures, the input, the gate, the inspector. They share a
theme of semantic roles and a handful of primitives, and nothing
outside `mux/src/ui.zig` names a color. This page is the intent behind
those roles; the file is the implementation; `scripts/altitude-fixture.py`
is where the result is looked at.

## Rules

- **The accent is not selection.** The accent marks scope (the
  system's chip), focus (the focused pane's edge), the selected tab's
  *edge*, and the prompt. It is a fill behind text in exactly one
  place: the global scope chip.
- **Selection is not focus.** A selected tab, row or figure is a
  raised fill with an accent edge; the focused pane is an accent
  border. They never share a treatment.
- **Activity is not unread.** Work in flight is `◐` in the working
  ink. Unseen output is `•` in the unread ink, which is not the
  accent, so it cannot be mistaken for selection.
- **Attention is the strongest state, and rare.** A program asked — a
  bell, a notification, a producer's `waiting` — is `!` in the
  attention ink, bold. Nothing else uses that ink except failure.
- **Calm wears no glyph.** A tab, pane or row with nothing to say
  draws nothing beside its name.
- **No state by color alone.** Every state has a glyph and a word;
  every fill has a shape.
- **Operational text reads over any wallpaper.** Chrome is opaque;
  the work surface keeps the terminal's own background.

## Roles

Surfaces, from the ground up:

| role | palette | used for |
|---|---|---|
| `work` | base | the terminal's own ground; panes keep it, chrome never paints it |
| `chrome` | mantle | both bars, the root canvas — opaque |
| `raised` | surface0 | one step up: a space's chip, a field, an overlay's interior, the selected tab's fill |
| `selection` | surface1 | a selected row's band, bounded to its content |

Ink:

| role | palette | used for |
|---|---|---|
| `primary` | text | the selected tab, a space's name, a row's name, typed text |
| `secondary` | subtext0 | inactive tab labels, the tool on the bar, a figure's tabs |
| `muted` | overlay0 | indices, separators, hints, placeholders, event lines |
| `disabled` | surface2 | never for words that matter |
| `on_accent` | crust | text on the accent fill |

Edges:

| role | palette | used for |
|---|---|---|
| `border_subtle` | surface0 | the dock seam |
| `border` | surface1 | inactive pane splits, figures, overlays |
| `border_focused` | accent | the focused pane, the selected figure |

The accent: `[mux] accent` in the config, mauve by default. States:

| state | ink | glyph | ascii |
|---|---|---|---|
| working | yellow | `◐` | `*` |
| waiting | peach | `◌` | `o` |
| unread | blue | `•` | `.` |
| attention | red, bold | `!` | `!` |
| failed | red | `✕` | `x` |
| success | green | `✓` | `+` |

Priority when several apply to one thing: attention, failed, working,
waiting, unread. One glyph is drawn, the strongest.

## Surfaces and opacity

Three levels, and no others: the work surface (the terminal's, which
may be translucent), chrome (opaque `chrome`), and elevated chrome
(opaque `raised`). Overlays, the input, the inspector and the gate sit
on elevated chrome. The root canvas is chrome. A pane's edge is
drawn on the work surface, so it is a color, not a fill, and its ink
is chosen to read over transparency (`border`, not `border_subtle`).

## Typography

The terminal font, one weight and bold. Bold is a role, not a
highlight: the selected tab's label, a space's name in its chip, the
system's chip, `you` on the calm bar, an attention glyph. Everything
else is regular. Indices are `muted`; inactive labels `secondary`;
hints `muted`, never `disabled`.

## Spacing

In cells. Every tab has one cell of padding either side, and one cell
between tabs. The scope chip has one cell of padding, then ` │ `. The
`+` is a tab with no index. Modules on the calm bar are separated by
` · `. Figures inset by two columns from the canvas edge; the input by
two. A pane's title, when there is one, sits inside `┤ ├`.

## The scope bar

The top row. It answers: what scope am I in, what can I move within
it, what is exceptional here.

    [main] │  1 zsh   2 implement   3 review ◐   4 logs   +      `o rook
    [ROOK] │  4 spaces · 2 agents working · 2 need you
    [ROOK] │  orbit   4 spaces · 2 agents working · 2 need you    esc rook

- In a space: the space's chip (`raised`, `primary`, bold), the
  separator, the tabs, `+`, and the corner: the way out to rook in
  the prefix's own key (or `copy`, `zoom` while those are on).
- At home: the system's chip (the accent fill), the separator, the
  summary in `secondary`, and no corner — nothing is above home.
- In a subview of the root (orbit, ledger): the subview's name as
  the tab component, selected, between the chip and the summary, and
  `esc rook` in the corner. A space named `rook` gets the space chip;
  the system gets the accent. They never look alike.

A tab is one component: ` 1 deploy · main ◐ `. Index in `muted`,
label in `secondary` (or `primary`, bold, when selected), actor after
` · ` only when one claimed a pane there, mark last. The selected tab
is a `raised` fill with the accent underline across the whole chip —
index, label and mark inside one boundary. Calm tabs have no glyph.

When the bar is too narrow, the ladder: drop actors; cut inactive
labels to eight columns (the selected label is never cut); collapse
inactive tabs to their index and mark; move the rest into `⋯ n`. The
scope chip and the selected tab are never dropped, and a tab with
attention keeps its mark at every step.

## The calm bar

The bottom row, on `chrome`. Left: who holds the focused pane's
keyboard, through what — `you ▸ claude`, or `main ▸ claude owns
input · you observe` once an actor claimed it. Middle: the pending
prefix as a chip, with the chords. Right: counts, only the nonzero
ones — `◐ 2 · !1 · •3 · ⊕g 1`. No space name (the scope bar owns
identity), no clock. It never appears or disappears on its own.

## Panes

One pane, no border. Split panes share seams: `border` for an
inactive seam, the accent for the focused pane's. Ownership is the
bar's word, never a border. Work in flight is the tab's mark, never a
border.

## The root

The canvas is `chrome`, split into the conversation and the
dashboard by one column of `border_subtle` when the glass affords
both; one view with a switcher (two dense tabs, the hidden view's
attention count on its tab) when it does not.

Region headers: one line, the region's name in `primary` bold when
it has focus and `secondary` otherwise, its status after ` · ` in the
status's ink (`working` while she thinks, `attention` while she waits
on you, `err` offline), and for the dashboard the attention count in
the attention ink.

Conversation roles, in a four-cell margin: `you` in `primary` bold;
`✦` in the accent for her; `✓` in `muted` for a receipt and in
`success` for an outcome; `✕` in `err`; `·` in `muted` for rook's
note. Prose is unboxed — yours in `primary`, hers in `secondary`,
receipts and notes in `muted`. Her reflection is a block on `raised`
across the body: the intent in `primary`, the plan numbered in
`secondary`, a question with the attention mark, the actions with
their marks. The selected turn wears the accent marker and bold on
its first line; the age sits at the right edge in `muted`. The
composer is `raised` with the accent prompt when it has focus and
`chrome` with a `muted` prompt otherwise; its hint line under it is
`muted`.

Dashboard modules: a `muted` word and a count, two rows (a blank
above), `needs you` in the attention ink, bold. Cards: the mark in
its ink and the title in `primary` (bold when selected, or when it
needs you); the space and the actor in `secondary` with `muted`
dots; the state word in the mark's ink; the current step in
`secondary` (`primary` on a needs-you card). A needs-you card wears
the attention edge (`▎`, `|` in ASCII) down its left. The selected
card is a `selection` band across its rows with the accent marker
and what ↵ does at its right edge in the accent. Recent is one flat
line; a space row is the name in `primary`, its tabs as `secondary`
labels with their marks, its age at the edge. No card has a border
of its own; the edge and the band are the only enclosures, and
content sets a card's height.

Figures (orbit) wear `border`, the selected one `border_focused`;
the space's name in the top edge is its chip; the tabs inside are
the tab component without indices. Ledger draws the same rows with
the same inks. Finding and commanding draw one `raised` field with
the accent prompt at the top of the canvas and rows under it, the
selected one banded.

## Overlays

The gate and the inspector sit on `raised` with a `border` edge; a
title in the accent; keys in `muted`; the actor's name in the working
ink. Attention (the gate's first word) is a chip in the attention ink.

## Fallbacks

`[mux] glyphs = "ascii"` swaps every mark and glyph for an ASCII
form; the inks, fills and underline are unchanged, so the hierarchy
survives. A glass without colored underlines shows a plain underline
under the selected tab. A glass without truecolor is not supported by
the chrome (it never was).

## Compatibility

`[mux] accent` still sets the accent, which now also sets the focused
edge and the selected tab's underline. The eight ANSI names still
map. No other theming existed; the roles above are the theme.

# Altitude: the layer above a space

The status bar tells you the world exists. Zooming out lets you touch
it. This page is the product model behind `prefix-o`, the calm bar,
minted tab names and input ownership — the second revision of the
design exploration, as it landed in the engine on 2026-09-06 — with
the resolutions it rests on and the parts still owed. The mockups it
implements are the Claude Design document "Rook Design Exploration
v2"; the character grids there are the acceptance test for what is
drawn here.

The product model is unchanged: no sidebar imposed, two rows of
chrome, overlays as fast paths. What this revision adds is the global
layer — continuity, living spaces, one intent input — and the honest
statement of who is driving.

## Nine resolutions

**1 · You enter rook.** The global layer has no product noun. Leaving
a space, you enter rook: the scope chip top-left reads `rook ‹ vera`
in the same slot that read `vera`. The action is *zoom out*;
internally it is root scope. "Atlas" was rejected as a second brand
competing with the scope model it should reinforce.

**2 · Semantic zoom is contraction, not scaling.** The current space
contracts into a *figure*: a box with its name and current tab in the
top edge, and the panes of that tab placed inside it by the same split
tree that places them on the glass — relative position and title
kept, at a smaller size. Other spaces resolve around it as rows; the
global pin dock does not move a column; the calm bar stays. There is
no animation in the engine (a terminal has no interpolation worth
having): the continuity is positional. Esc returns to the exact pane,
cursor and scroll, because nothing moved to get here — the panes kept
running underneath and the view was painted over them.

**3 · One input: find → command → intent.** At rook scope the cursor
is already in one input. Bare text fuzzy-finds spaces, tabs and panes.
`:` prefixes an exact command, completed as it is typed. Anything can
be handed to the companion — but only by choosing the visible
`✦ vera:` row that always closes the result list, and only while she
is open in a pane rook can see. Typing never executes; `↵` on a visible
row does. The ✦ row is never selected by rook: a hand has to move
onto it (`j`, `⇥`, a click). Choosing it types the text into her pane,
Enter included, and takes you there; what she does with it is hers.

**4 · Actor identity is never absent.** Tabs carry the actor by name,
after the stable tab name: `deploy · claude ◐`, never `[agent]`. The
calm bar's left cell always names the focused surface's input owner —
`you ▸ nvim`, or `claude·main ▸ owns input · you observe` — so a single
borderless pane still answers "who is driving". Manual control is
quiet but stated, never inferred from absence.

**5 · Focus ≠ control.** Focusing is observing; scroll, copy mode and
selection are always safe. A pane becomes agent-owned only when a
program claims it through the front door (`rook own`), and typed keys
into an owned pane are not forwarded: a one-row gate names the three
legal moves — request a handoff (the agent finishes its step, then
yields, then you confirm), take now, or send the keystrokes to the
agent as a message. Five states: `human`, `agent`, `takeover-requested`,
`handoff-pending`, `paused`. "Shared control" was rejected: arbitrary
PTYs have no safe definition of simultaneous input.

**6 · Tab names are minted, then frozen.** A tab is named once: a name
a person gave (`rook rename`, `:rename`), else the first program that
ran in it that was not the shell, with an ordinal when a sibling
already wears the name (`shell·2`). Rook never changes a minted name;
the activity glyph and the actor suffix change freely around it. A
minted name survives a server restart. Until a tab is minted it reads
the live program, which is the shell at a prompt.

**7 · Scratch work: the shelf.** Not built. Every pane in rook is in a
workspace; there are no loose surfaces to shelve. See *Owed*.

**8 · Calm bar: minimal, but present.** The space name leaves the
bar — the tab bar owns identity. The bar shows the input-owner cell on
the left and signals on the right (`◐ 2 · ● 1 · ⊕g 1`: agents
producing output, panes unread, global pins), no clock, and is
genuinely empty when nothing signals. It stays visible because
appearing and disappearing would resize every hosted TUI, the one
motion rook must never cause; `[mux] bar = false` turns it off for
good rather than per signal. While the prefix is armed the bar shows
the pending key and the chords a hand may be reaching for — the
feedback that has nowhere else to live.

**9 · Folds, and pins at altitude.** Global pins stay live PTYs at
every altitude, docked in a strip whose columns do not move through
zoom — scope taught by what refuses to move. Workspace-local pins
belong to the space and contract with it. Folding (narrow widths
auto-folding background panes into strips) is not built. See *Owed*.

## Orbit and Ledger: one design at two fidelities

Orbit renders the model spatially: the figure of the current space,
the other spaces as rows around it. Ledger renders the same rows with
no figure — a pure character-grid list that works on SSH, at 58
columns, under reduced motion, and by preference (`zoom_view =
"ledger"`, or `:ledger` up there). Identical scope model, identical
keys, identical intent grammar; the capability never depends on the
spectacle. Orbit falls back to Ledger by itself when the glass is
under 60 columns or 16 rows in the region it paints.

Undercard — the live space letterboxed above the world — was rejected
as a mode: it forces the one thing rook promises never to do, a live
resize of hosted TUIs.

## The grammar

    prefix-o     zoom out (the space contracts in place) — and back
    esc          zoom back in: exact pane, cursor, scroll
    prefix-s     direct space switcher (never via rook)
    prefix-C-o   return jump after any cross-space hop
    prefix-i     inspector: actor, authority over input, program, cwd, resume

At rook scope:

    text         fuzzy find: spaces, tabs, panes (and what a pane's title says)
    :            exact command, completed: go · new · rename · close · ledger · orbit
    ✦ row        hand the same text to the companion (⇥ jumps to it)
    ↵            act on the selected row; typing never acts
    j k ↑ ↓      move (h j k l only while nothing is typed); g G ends; q leaves
    click        a row acts; the global pins are live; the tab bar is a way out

At an agent-owned pane:

    any key      opens the gate instead of being forwarded
    ⏎            request handoff (the actor finishes its step, then yields)
    ⏎ again      take, once the actor has yielded
    T            take now
    s            send the next keystrokes, through Enter, as a message
    esc          leave it

From the front door, the same protocol:

    rook own <id> <actor>            the actor owns input
    rook own <id> --paused <actor>   attached, not operating
    rook own <id> --release          hand it back (yields, if a handoff was asked)
    rook own <id> --request          the gate's ⏎, scripted
    rook own <id> --take             the gate's T, scripted
    rook rename <name>               name the current tab

## What the feed says

- `focus.mode` gains `altitude`, `gate` and `inspect` beside `pane`,
  `copy` and `popup` — every case where the mux holds the keyboard.
- `bar` — whether the calm bar is on, so a second glass lays its rows
  out the same way.
- `workspaces[].windows[].name` is the tab's name as minted;
  `named` says whether it is; `program` is the live foreground program
  of the window's focused pane (which is what `name` used to be).
- `panes[].input` — `{"state": "human"}`, or `{"state": "agent",
  "owner": "claude·main", "sinceMs": …}` with one of the five states.
- The restore file (`<sock>.state`, still `v2`) carries a `name <n>`
  line under a window whose tab was minted.

## What the rows say, and where it comes from

Every line at altitude is a fact rook holds; nothing is inferred and
nothing is summarised by a model. A space's event line is built from:
the words a producer already spent on the space (the rail's claim,
repeated verbatim); the title of the last desktop notification an
unread pane sent; an agent pane producing output (`claude ◐ working`);
the count of unread panes; else `quiet · <age>` from the newest
output anywhere in the space. The tab row under it is the tabs, each
with its actor and its mark. Attention rows are the unread channel,
oldest first, with what the program said — its notification title,
or that it rang the bell, or that its progress bar finished.

## Owed

In the design and not in the engine, with the reason:

- **The shelf** (resolution 7). Rook has no loose surfaces: every
  pane is in a workspace, so there is nothing to shelve and nothing
  to promote. If a pane ever exists outside a workspace this is where
  it goes.
- **Folds** (resolution 9). Auto-folding background panes into
  one-row strips at narrow widths, `⊟2` in the bar, `C-a =` to unfold.
  A projection over the layout tree; nothing else needs it yet.
- **The attention peek** (`prefix-n`, M4): the oldest unread item
  docked above the bar with `↵ go · a approve · d dismiss`. `prefix-u`
  goes to the oldest unread pane, and the altitude view lists them;
  the peek's `approve` needs a structured ask to approve, which is a
  producer's (vera's) to push.
- **Moving surfaces at altitude** (`x` lift, `P` drop into the dock,
  `m`, `S`, `:organize`). Pins are moved from inside the space
  (`prefix-P`, `prefix-G`); a drag-and-place grammar over the figure
  is the next thing the figure earns.
- **Provider detail in the inspector.** Rook does not know a pane's
  model; the inspector says so and points at the rail, where a
  producer's word lives.
- **Border interpolation** (~120 ms in a rich renderer). The engine
  is a terminal; the continuity here is positional, which the design
  allows under reduced motion.
- **`rook top`** (M12): the Ledger as a program you tile. The rows
  exist; printing them to stdout is a verb away.

# Altitude: rook's outermost scope

The status bar tells you the world exists. Zooming out lets you touch
it. This page is the product model behind `prefix-o`, the frame it
replaced, the calm bar, minted tab names and input ownership — the
second revision of the design exploration, as it stands in the engine
after the corrective pass of 2026-09-06 — with the runtime ontology
it rests on, the fixture it is judged against, and the parts still
owed.

The intended feeling: *I did not open an overview page inside rook. I
changed altitude, from a space into rook itself.* So the frame is the
same in both states — one tab bar across the top, one calm bar across
the bottom, the whole width between them — and what changes is what
the frame holds: a space's work, or every space.

## The runtime ontology

One name, one meaning. These are the objects as the engine holds them
(`mux/src/server.zig` unless said otherwise), what each is called on
the glass, and where it shows.

| concept | runtime type / source | lifetime | example | visible where |
|---|---|---|---|---|
| **rook scope** | the `Server` itself, at altitude (`alt_on`) | the server process | `rook` as the accent chip | the scope slot, as the block, at altitude only; the bar's left cell |
| **space** | `Session` — a workspace: windows, pins, focus | until its last window closes; restored across restarts | `vera` (identity `rook--vera-e41…`, label `vera`) | the scope slot in a space; a figure or row at altitude; `:go` |
| **tab** | `Window` — one split tree | until its last pane exits | `deploy` | a chip on the tab bar; a tab in a figure |
| **pane** | `Pane` (`pane.zig`) — a pty and ghostty-vt | until its shell exits | the Claude pty, id 7 | a region of the space, bordered only when split |
| **tool** | `Pane.fgName()` — the foreground program, by name | moment to moment | `claude`, `nvim`, `zsh` | the bar (`you ▸ claude`); attention lines; the inspector |
| **actor** | `Pane.owner` — the name a program gave when it claimed the pane with `rook own` | claim → release | `main` | after the tab name (`deploy · main`); the bar (`main ▸ claude`) |
| **agent found** | `Pane.is_agent` — a tool the config lists under `agents` | the 2 s scan | a `claude` running unclaimed | the ◐ mark; the working count; never a name on a tab |
| **producer's word** | `chrome.Feed` items pushed on `c2s.side` (verad's `items.push`), matched by `workspace` | until the next push | "Deploy plan · needs you" | a space's event line; an ask row |
| **provider / model** | not held — a producer's vocabulary | — | Sonnet | the inspector says it is not rook's to know |
| **legacy sidebar space** | `foundSpaces()` + pushed `spaces` items | — | `rook` under "spaces" | no longer default chrome; still published on `surfaces[]`; `sidebar_mode = "open"` brings the panel back |
| **legacy sidebar agent** | `scanAgents()` found rows (named for their *workspace*) + pushed `agents` items | — | `main` under "agents" | the same: not default chrome; the found row's name was a workspace, never an actor |

The questions the old frame raised, answered from the code:

- **What were the sidebar's spaces?** Rook's own workspaces (one row
  each, labelled with the repository prefix off) plus whatever a
  producer pushed to the `spaces` surface. The same objects the
  altitude view calls spaces; the panel was a second rendering of
  them, permanently on.
- **What was `main` in the tab bar?** The scope slot: the current
  workspace's label. Rook's default workspace is named `main`, so a
  fresh install said `main` there.
- **Was the sidebar's `main` agent the same `main`?** No. A found
  agents row is *named for the workspace the agent was found in* —
  rook can say a `claude` runs in workspace `main`, and nothing more
  — so `main` there was a workspace label wearing an agent's dot. It
  was never an actor. That collision is gone with the panel.
- **What was `claude·2`?** A tab whose name was minted from the first
  program that ran in it, `claude`, with an ordinal because another
  tab in the same workspace had already minted `claude`. That is
  resolution 6 working as designed (`shell·2` in the design); what
  was wrong was the suffix.
- **Why did `· claude` follow it?** The first pass put the *tool* of
  the agent pane after the tab name. The tool is not an actor. Now
  only an actor — a name given through `rook own` — follows a tab
  name, so `claude·2 · claude` cannot occur; that tab reads `claude·2`
  with a ◐ when the agent is producing.
- **Which object is the durable semantic context the design calls a
  space?** The `Session`. It has the name, the windows, the pins, the
  focus memory, and the restore line.

The canonical grammar, everywhere:

    [rook]           the system scope: the accent chip, and only at altitude
    vera             a space (the scope slot in it; a figure or row above it)
    deploy           a tab, minted once
    deploy · main    a tab with the actor that claimed a pane in it
    you ▸ claude     the bar: who holds the keyboard, through what tool
    main ▸ claude    …an actor does, through that tool
    ◐ ● ◇            producing, unread, asked for (marks, never names)

A space literally named `rook` is a space: `rook` in the scope slot,
plain and bold, when you are in it; a row or figure at altitude; and
never the chip. The chip — the word in the accent block — is worn
only by the system scope, and only at altitude, where the tabs give
way to the world in one line and the corner says where back is. The
fixture has such a space; the frames check the chip's cells carry the
accent and a space's name never does.

## The frame

**In a space.** Row 0 is the tab bar: the space's name as the scope
slot, plain and bold; then a chip per tab, `deploy · main`, the
current one filled with the accent; the mark (`◐` producing, `●`
unread) after a chip; `+`. The work takes every column between the
top and bottom rows, bordered only where it is split. The last row is
the calm bar: `you ▸ claude` on the left, or `main ▸ claude owns
input · you observe` once an actor claimed the focused pane; the
signals on the right (`◐ 2 · ● 1 · ⊕g 1`), empty when nothing signals.
There is no sidebar. The legacy panel still exists behind
`[mux] sidebar_mode = "open"`, off by default, and does not change
the layout when it is off.

**At altitude** (`prefix-o`). The same frame. The scope slot holds
the chip, and after it, where the tabs were, the world in one line:
`rook  3 spaces · 2 agents working · 1 needs you` (only the nonzero
parts; `all quiet` otherwise). The corner says `esc ↩ vera`. The
canvas between the bars is rook's own surface (an opaque
ground, so it reads over a wallpaper), holding:

1. **the input**, a band with the prompt, already focused, the cursor
   in it. Empty, it says what it takes — `find a space, a tab, a
   pane · : for a command` — inside the band, as a placeholder, not
   as a caption elsewhere.
2. **attention**: unread panes oldest first (`● api › server  bash
   rang the bell · 1s ago`), then what a producer said needs you
   (`◇ vera — Deploy plan  needs you · 3 approvals`).
3. **the spaces**, in workspace order, always — a space is where it
   was last time whatever changed in it, and activity is shown in
   place. Each is a *figure* when rook has something to say about it,
   and one compact row when it does not.
4. **pinned everywhere**: the global pins, with where they came from.
5. a footer of keys, dim but legible.

Global pins stay live where they were, in the dock to the left, at
every altitude: scope taught by what refuses to move. Nothing is
resized to get here — the panes keep their geometry and keep running,
and the view is painted over them — which is why Esc is an exact
return: same pane, cursor, scroll, layout.

## Orbit and Ledger

One model, two fidelities. **Orbit** draws each space that has
something to say as a figure:

    ┌┤ vera ├  Deploy plan · needs you ─────────────────────────┐
    │  deploy · main    logs ●  chat ●                          │
    │ › Reading migrations/0042_session_audit.sql               │
    └───────────────────────────────────────── ↵ back in ───────┘

The top edge holds the name (the block when it is the space you
left), `●` when anything in it is unread, and the event line in its
own ink. Inside: the tabs with their actors and marks, the current
tab filled; then, for the space you left only, the last lines of the
pane you were in — read from the cells it already holds, never a
resize, never a read of anything the program did not draw. The
figure is exactly as tall as that: three rows and the excerpt. A
space with only a name and `quiet · 2d` is one row, on purpose — the
empty box the first pass drew said nothing, and a figure earns its
rows by holding something.

**Ledger** is the same spaces as two-line rows — the name and event,
then the tabs — and is what narrow glass draws (under 60 columns in
the region), what `zoom_view = "ledger"` or `:ledger` asks for, and
what orbit falls back to when the figures would not fit the rows
available. The fidelity is decided once per frame, before the bars
are composed, so the bar's word (`orbit`, `ledger`) and the canvas
agree.

## The input

Bare typing is the query. That is why the rows are walked with the
arrows (and ⇥ ⇤, C-n C-p), never with letters: `j` finds things named
j. Results replace the spaces under the input, ranked, one line each
— `api › server` for a tab, `api › server › bash` for a pane, an
attention row when it matches — with the line under the band saying
what they are. `:` leads a command, completed as it is typed:
`go`/`switch`, `new`, `rename`/`tab rename`, `close`, `ledger`,
`orbit`. The last row while finding is `✦ vera: "…"` — present only
while the companion is open in a pane, never selected by rook (a hand
must ↓ or click onto it), and choosing it types the text into her
pane, Enter included, and takes you there.

Esc peels one layer at a time: a query (with its results or
completions) first, the view second. A half-typed query never zooms
you back into the space by surprise. `prefix-o` toggles back at any
time; `prefix-C-o` returns after any cross-space hop.

## Ownership and the gate

A pane is the person's until a program says otherwise. `rook own <id>
<actor>` claims its keyboard for `actor`; the tab reads `deploy ·
main`, the bar `main ▸ claude owns input · you observe`, and a typed
key opens a gate instead of landing: ⏎ requests a handoff (the actor
sees `takeover-requested` in the feed, finishes its step, releases;
the person confirms with ⏎), `T` takes now, `s` sends the next
keystrokes through Enter as a message, Esc leaves it. `--paused`
attaches an actor without the keys; `--release`, `--request`, `--take`
are the moves from a script. Five states on `panes[].input`; `prefix-i`
shows them in a box. Focus is observing: scroll, copy mode and
selection are always safe.

## The fixture

`scripts/altitude-fixture.py` builds a deterministic rook — in a
sandbox, through the front door, never the live server — and reads
it back through a real glass:

- four spaces, `rook`, `vera`, `api`, `infra`;
- `vera`: tabs `deploy · main` (an agent pane claimed by `main`),
  `logs`, `chat` (the companion); a producer's row saying the agent
  is waiting on you;
- `api`: tabs `tests · codex` (claimed by `codex`), `server` with an
  unread bell; a producer's row saying it is working;
- `infra`: one tab, quiet; `rook`: one tab, quiet, no history;
- one global pin promoted out of `api`, so it says `from api`.

It captures the in-space frame, altitude, altitude over one quiet
space, the 58-column ledger, the input with results, and the exact
return, and asserts on each: no sidebar columns, full-width bars, the
chip only at altitude, the space named `rook` listed
as a space, actors on tabs and tools kept off them, the pin's origin,
no pane resized by altitude, and the same focus and layouts after
Esc. Run it after any change to the frame; look at the PNGs, not only
the PASS lines.

## What the feed says

- `focus.mode`: `pane`, `copy`, `popup`, `altitude`, `gate`, `inspect`.
- `bar`: whether the calm bar is on.
- `workspaces[].windows[].name` (minted), `named`, `program` (the live
  tool of the focused pane).
- `panes[].input`: `{"state": "human"}` or the actor and one of the
  five states, with `sinceMs`.
- `surfaces[]`: the legacy rail's model, still published verbatim for
  the web client and any producer; `shown` is false by default now.
- The restore file (`<sock>.state`, still `v2`) carries `name <n>`
  under a minted window and `origin <space>` under a global pin.

## Owed

Deliberately not in this pass:

- **The shelf** (resolution 7). Rook has no loose surfaces: every pane
  is in a space, so there is nothing to shelve or promote.
- **Folds** (resolution 9): background panes as one-row strips at
  narrow widths.
- **The attention peek** (`prefix-n`, M4) with `a approve`: approving
  needs a structured ask to approve, which is a producer's to push.
- **Moving surfaces at altitude** (`x` lift, `P` drop, `m`, `S`,
  `:organize`). Pins move from inside a space (`prefix-P`, `prefix-G`).
- **A live excerpt for spaces other than the one you left.** Reading
  another space's cells is as safe as reading this one's; it is left
  out until the figures earn the rows.
- **Provider detail** in the inspector: not rook's to know.
- **Border interpolation.** A terminal has no motion worth having;
  the continuity is positional, which the design allows.
- **`rook top`** (M12): the ledger as a program you tile.

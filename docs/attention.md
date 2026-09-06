# Attention: what the programs say, and what nobody has read

Rook renders attention; it does not manufacture it. Two sources feed
the chrome: what a program says to its own terminal, which rook hears
because it *is* the terminal, and what a producer pushes onto the rail
(`docs/surfaces.md`). This page is the first.

## The signals

ghostty's emulator, in-process, hands the mux every one of these as it
is parsed. Rook used to leave all five on the floor; now each is
published on the pane in the state feed, and two are passed on to the
glass.

| signal | sequence | published as | passed to the glass |
|---|---|---|---|
| bell | `BEL` | `bellMs` | yes, as `BEL` — the terminal's own bell settings apply |
| desktop notification | OSC 9, 99, 777 | `notified: {title, body, ms}` | yes, as OSC 777, when the pane was not in front of you |
| progress | OSC 9;4 | `progress: {state, percent}` while in flight; `progressDoneMs` when it stops | — |
| title | OSC 0/2 | `title` | the focused pane's, as the window title (already the case) |
| working directory | OSC 7 | `pwd` | — |

`title`, `pwd` and a moving bar are **drift**: they change with output,
so they ride the feed's 2 s cadence like `cwd` and `lastOutputMs`. A
bell, a notification and a bar *finishing* are events at human rate
and push at once.

Rook publishes the words and acts on their arrival. It never reads
them for meaning: a title that says `✳ idle` is a string in
`panes[].title`, and what it means is a producer's job — the same line
`surfaces.md` draws for the rail. That the signal came at all is
rook's fact, because rook is the terminal it was sent to.

## The unread channel

A signal that arrives while nobody is looking at its pane puts the
pane on the unread channel; looking takes it off.

**Seen** means: focused, on the glass, a glass attached, no popup over
it. A bell in the pane in front of you was heard as it rang and marks
nothing. The same bell in a background window, another workspace, or
with no client attached at all is news you missed until you look.

**Looking** is focus. Every frame, the focused pane on an attached
glass is read; `unread` there clears. Switching *to* a pane clears it,
and so does already being on it when the glass reattaches. Nothing
else does — not a producer, not time, not reading the pane through
`rook read` (a script reading a pane is not a person looking at it).

Published per pane as `unread` (bool) and `unreadMs` (wall clock of
the first signal since it was last read, 0 when read), and rolled up
where rook draws its own rows:

- **the tab** wears `!` in the attention ink when any pane in its window is
  unread. `◐` (an agent still producing output) outranks it on the
  same cell. The tab's older, softer meaning — output arrived in a
  window that was not on the glass — still wears the same dot: both
  are news you missed, and one cell has one dot.
- **the rail's found rows** (`surfaces[].found` on `agents`) carry
  `unread: true` when a pane in that workspace is; the row paints the
  accent `●` beside the state word, the same mark a pushed item's
  `unread` paints.
- **the worktree manager** shows `● claude` on a live worktree with an
  unread pane, `· claude` otherwise.

**`prefix-u`**, and `rook jump` from a script, focus the oldest unread
pane — its workspace, then its window, then the pane — so a queue of
asks is answered in the order it formed. With nothing on the channel
it falls back to the window whose unseen output is oldest, which is
what the softer dot meant all along. `rook focus <id>` does the same
for one pane by name.

## What a Claude Code pane sends

Claude Code sets the title (`✳ ` idle, a spinner glyph busy), reports
OSC 9;4 progress across a turn, and — depending on its notification
setting — rings the bell or sends OSC 9 when a turn ends or a
permission is wanted. All of it now lands in the feed; the bell and
the notification reach the glass; the pane goes unread if you were
elsewhere. Nothing needs to be installed in Claude for this. A
producer that wants *state* still reads the hook events and the pane,
as verad does.

## Coming back

A pane that told rook how to bring its program back (`rook resume`)
is restored running after the server is gone — `mux/README.md`,
"Coming back". For Claude Code it is one `SessionStart` hook; nothing
about the id is rook's to know, only the command it was handed.

## Reading rook (the other direction)

`rook state` and `rook watch` — `docs/surfaces.md`. A producer that
wants to know which panes want a person reads `panes[].unread` and
`unreadMs`, orders by the latter, and never has to see a screen.

# Shots

`rook shot` is what rook is showing, as a grid: the tab bar, the panes
and the seams between them, the rail, a popup, the calm bar. It is for
a reader that has no eyes on the terminal — a test, or an agent
iterating on one — and it needs no terminal to be there at all.

`rook read` is one pane's text. A shot is the composed glass.

## The forms

```sh
rook shot                      # plain text, one line per row
rook shot --ansi               # the same with its colours (SGR): cat it and it is the picture
rook shot --json               # runs of styled cells, for a program
rook shot --png glass.png      # a picture, for a model or a person to look at
rook shot 7 [--json|--png f]   # pane 7's own grid, wherever it is: a hidden
                               # window, the background
rook shot --size 120x40        # no terminal attached: compose for this glass
rook shot --settle 200         # how still it must be first (80 ms unless said)
```

`--json`:

```json
{"cols":100,"rows":24,"cursor":{"x":2,"y":1,"visible":true},
 "panes":[{"id":1,"x":0,"y":1,"w":100,"h":22,"focused":true}],
 "lines":[{"y":0,"text":"  main  │  1 sh   +",
           "runs":[{"x":1,"w":6,"text":" main ","fg":"#cdd6f4","bg":"#313244","bold":true}]},
          {"y":23,"text":" you ▸ sh","bg":"#181825","runs":[…]}]}
```

- A **run** is a stretch of cells in one style; `x` and `w` are in
  cells, and it is one character a cell — except a run marked
  `"cluster":true`, which is one glyph in its `w` cells: a wide
  character, or several codepoints (an accent, a flag, an emoji
  sequence). A reader never needs a width table.
- A colour that is absent is the terminal's own. Colours are what was
  resolved — `#rrggbb` — not palette numbers. A flag that is absent
  (`bold`, `faint`, `italic`, `underline`, `inverse`, `strikethrough`,
  `invisible`) is off.
- Blank stretches in the default style are left out, and a
  default-style run ends at its last glyph; runs are in order and do
  not overlap, but they do not tile the line.
- A line has a `bg` of its own when one background runs edge to edge:
  a header bar, the calm bar.
- `panes` (the whole glass only) is where each pane is, so a cell maps
  to a pane and back; a pane shot (`rook shot 7`) is in the pane's own
  coordinates and has none.

"The selected tab is filled in the accent" is a lookup: the run on
line 0 whose text is the tab, and its `bg`.

## When it is taken

A shot is taken once what it shows is still. Rook knows what was asked
of the programs on the glass — a key typed through `rook send/run/key`,
a new size — and what they last wrote:

- nothing asked since they last wrote, and nothing written for
  `--settle` ms (80): at once. A quiet glass costs nothing.
- something asked and not yet answered: they get four settles to
  answer; when they have, one settle of silence is the frame.
- `--timeout` ms (1000) at the latest, whatever is still moving.

Each pane on the glass is judged on its own, so a shell echoing next
door is not the answer of the program you asked.

So `rook key 7 down; rook shot 7` is the frame after the program
answered the key, with no sleep between — and a key the program
answers with nothing costs four settles. It is a bound, not a promise:
a program that takes longer than four settles to answer, or that
paints "working…" and the result later, is shot too early. For "the
screen says X" there is `rook expect X` (docs/play.md), which looks
again until it does. `--settle 0` is the grid as
it is this instant; raise it for a program that paints in bursts.

Named keys go in the encoding the program asked for: `rook key 7
down` is `ESC O B` to a program in application cursor mode (curses,
vim), `ESC [ B` otherwise. `rook send` is always verbatim.

## How it is made

The server composes a full frame — the same bytes it ships to a
terminal — and feeds them to a terminal of the glass's size it holds
for the length of the request (`render.Shadow`, ghostty-vt, the parser
every pane already runs on). The grid of that terminal is the shot.
So the shot is what the render path wrote, not a second description of
it: a painter that puts a cell in the wrong place puts it in the wrong
place in the shot. The frame is shipped to any attached glass as well,
since composing one takes the panes' dirty rows.

A frame composed after a layout starts from an empty glass (`CSI 2J`
inside the synchronized update): a full repaint paints where things
are now, and what the last layout left where nothing is any more — a
frame's corner, the end of a seam — would otherwise stay on a real
terminal and be absent from the shot.

A pane by id skips the frame: it is that pane's own grid, the one
`rook read` flattens to text. An attached terminal gets a repaint for
either — never a blank: a whole-glass shot ships the frame it
composed, and a pane shot of a pane on the glass owes the glass the
rows it read.

## With nobody attached

A server's geometry is its attached glass's, and 80x24 with none.
`--size WxH` (20x6 to 500x300) sets the size it composes for while
none is attached: the panes are laid out and resized for it — a pane
is the glass less the bars, 100x22 on a 100x24 glass — and the resize
is something asked, which the shot waits out as above. Saying the size
it already has costs nothing. The size is the server's, not the
shot's: it stays until it is said again, a pane shot with `--size`
resizes the glass that pane is on, and two tests that want two sizes
want two servers. A terminal that attaches takes over, and when it
leaves the panes are laid out for the size that is left. While one is
attached `--size` is refused — unless it is that glass's own size, so
a script that always says it does not fail on a desk.

For a test this is the whole harness:

```sh
export ROOK_MUX_SOCK=/tmp/mytest.sock    # a server of its own; never the person's
rook server >/dev/null 2>&1 &            # no terminal
rook shot --size 100x30 >/dev/null
rook run 1 './my-tui'; rook key 1 down; rook shot 1 --json | …
rook kill                                 # this server, by its socket
```

## The picture

`--png` is drawn by the front door from `--json`: a monospace face
(Menlo where the system has it, the Go fonts otherwise, the system's
symbol fonts for what those lack), 2x. Box lines, block elements and
the powerline caps are drawn as geometry in the cell, so segments and
seams meet the way they do in a terminal. A glyph no face has is an
outlined box — colour emoji among them: the picture says something is
there, not what. A cluster is drawn as its first codepoint and its
marks. Concealed text is not drawn.

It is a picture of rook's grid, not of a terminal. The face is not
yours, cells with no background get a fixed ground (rook does not know
the terminal's), and ligatures, font fallback and transparency are the
terminal's and are not in it. Where things are, what is filled, and
what colour it is are.

## Tests

`scripts/shot-fixture.py` — no terminal for most of it: the size, the
three forms agreeing, layout and a styled tab, panes by id, clusters
and pane rectangles, a key then a shot against a curses program, a
screen big enough to be a 300 KB answer, a reader that goes away, the
PNG.
Its last part attaches a real glass and checks the shot row for row
against a terminal (pyte) decoding the frames rook sent it — after a
workspace switch too — and that the glass leaving lays the panes out
again.
`cmd/rook/shot_test.go` draws a small grid and checks the pixels.

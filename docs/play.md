# Play

`rook play` puts a terminal program under test the way Playwright puts
a web page under test: an isolated session, verbs that act on it,
assertions that wait until they hold, a snapshot to read and a picture
to look at, and a trace of what was done. It is for an agent — or a
script, or a person — to go and *use* a tool and say whether it works.

```sh
name=$(rook play start --size 100x30 -- ./my-tui)   # a session; prints its name
export ROOK_PLAY=$name                               # every rook verb is now its

rook expect "3 items" --row 0          # wait until it is so, or fail with the screen
rook key . down                        # . is the pane under test
rook expect "second item" --bg '#f0c674'   # …the highlight moved onto it
rook click "Save"                      # for a program that takes the mouse
rook shot . --png /tmp/now.png         # look at it
rook find "error" --json               # where is it, and how is it drawn

rook play stop $name                   # ends it; prints where the trace is
```

Without `ROOK_PLAY`, the same verbs are `rook play -s $name key . down`.

## The pieces

| Playwright | rook | |
|---|---|---|
| launch a browser context | `rook play start` | a rook server of its own: no terminal, its own socket and config, the program typed into a shell in its one pane |
| `press`, `type`, `click` | `rook key`, `send`, `run`, `click` | `key` names keys and sends them the way the program asked (application cursor mode); `click` writes the mouse the way it asked (SGR or the original three bytes) |
| a locator | text | a terminal has no elements: `rook find` is where text is — cell, width, colours, weight |
| `expect(…)` | `rook expect` | retried until it holds or `--timeout` (3000 ms); on failure, the reason and the screen |
| snapshot / screenshot | `rook shot` (docs/shot.md) | text, JSON runs, PNG |
| trace viewer | `rook play trace` | one HTML page: each acting step, pass or fail, and the screen it left |

## A session

`rook play start [NAME] [--size WxH] [--cwd DIR] [--shell PATH]
[--no-trace] [-- <command…>]`

- **Its own server.** A socket under `/tmp/rook-play-<uid>/`, no
  terminal attached, the glass at `--size` (100x30 unless said; the
  pane is two rows shorter, for the bars).
- **Its own config.** Rook's defaults and nothing of the person's
  (`$ROOK_CONFIG` names the session's file; the session's engine is
  pointed at the `rook` that started it, whatever `$ROOK_FRONT_DOOR`
  said). What a test sees does not depend on whose desk it runs at —
  and a test is never typed into somebody's home. A session that did
  not come up with its own config is torn down before anything is run.
- **A plain shell.** `/bin/sh` with a `$ ` prompt unless `--shell`
  says, started in `--cwd` (here, unless said). The command after `--`
  is typed into it, so when the program ends the pane is still there:
  its last output and the prompt can be read and asserted on.
- **A name.** Said, or `p1`, `p2`, …. `rook play ls` lists what is
  running; `rook play attach NAME` puts a real terminal on one to
  watch (`prefix d` leaves it running).
- `rook play stop NAME | --all` ends it, writes the trace page, and
  removes everything but the trace.

Every rook verb works on a session — `split`, `window`, `bg run`,
`state`, `read`, `wait` — because it is a rook server like any other.
`kill`, `server` and `attach` are refused inside one: `play stop` and
`play attach` are how those are said.

## expect

```
rook expect [<pane>] [<text> | --text S | --regex RE]
            [--row N] [--fg #rrggbb|default] [--bg …] [--bold] [--inverse]
            [--count N] [--no-text S] [--line-bg #rrggbb] [--cursor X,Y]
            [--timeout MS] [--glass]
```

Everything said must hold on one look at the screen; it looks again
every 60 ms until it does. Status 0 and silence, or status 1 with one
line of why and the screen as text:

```
rook: expect: "2/4 done" is on the screen, but not drawn as asked: it is 7,0 w=8 "2/4 done" fg=#c5c8c6 bg=#81a2be bold, after 3000 ms
```

- The text is looked for a row at a time; `--row` pins the row.
- `--fg`/`--bg` are the colours every cell of the text is drawn in, as
  `rook find` reports them (resolved `#rrggbb`); `default` is the
  terminal's own. Take a `find` first to learn a colour, then assert it.
- `--count N` is how many times; `--count 0` and `--no-text` are
  absence.
- `--line-bg` is a row filled edge to edge in one colour.
- With no pane said it looks at the pane under test (`.`), else the
  whole glass; `--glass` asks for the glass, chrome and all.

Each look is a shot, and a shot waits for the screen to be still, so
`rook key . down; rook expect …` needs no sleep between.

## find, click

`rook find [<pane>] <text> | --regex RE [--row N] [--json]` prints a
line a match — `5,3 w=11 "write tests" fg=#1d1f21 bg=#f0c674` — or
JSON (`x`, `y`, `w`, `text`, `fg`, `bg`, `bold`, `faint`, `underline`,
`inverse`), and status 1 when there is none. Cells, not characters: a
wide glyph is two.

`rook click [<pane>] <text> | X,Y [--row N] [--right] [--double]
[--all]` clicks the middle of the text, or the cell. It waits for the
text like `expect` does, refuses text that is on the screen more than
once (it says where; `--row`, the cell, or `--all` for the first), and
refuses a program that has not asked for the mouse — it would not see
it.

## The trace

Each verb that acts (`run`, `send`, `key`, `click`, `expect`, `split`,
`window`, `focus`, `bg`, …) is a step: what was said, its exit status,
when, and the whole glass after it — a PNG, shared with the step
before when nothing changed. Reading (`shot`, `find`, `state`) is not
a step. `rook play trace NAME [-o FILE]` writes them as one HTML page,
pictures inline; `play stop` writes it too and prints the path. The
steps are also `steps.jsonl` beside it, each with the screen's text.

`--no-trace` at start leaves it out (a step costs a shot and a PNG,
about 25 ms).

## Tests

`scripts/play-fixture.py` — a curses to-do list driven end to end:
start under a hostile environment (a config whose home runs a program,
a `$ROOK_FRONT_DOOR` that names another binary), expect passing and
failing, find, keys with no sleeps, click, `$ROOK_PLAY`, the trace,
stop. `cmd/rook/expect_test.go` is the matching on a grid.

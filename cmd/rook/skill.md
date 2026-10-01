---
name: rook
description: "Drive rook, the terminal multiplexer this shell may be running inside: open panes beside you, type into them, read them back, wait on them, and hear which pane needs a person. Use only when the task asks for a terminal you can watch, another agent to run, or rook itself."
---

# rook

rook keeps workspaces of windows of panes on a server that outlives
the terminal, and publishes everything it knows. The `rook` binary on
`PATH` is the whole interface; every verb below is a one-shot command
that prints JSON when something is reading its stdout.

Unless you are testing a program in a session of your own (`rook
play`, below), check first that you are inside a rook pane. The
variable is the id of the pane you are running in:

```sh
test -n "${ROOK_MUX_PANE:-}"
```

If it is unset, say so and stop: nothing here should reach into a
session you cannot see. When it is set, `.` names your own pane in any
verb that takes one.

## Read before you act

```sh
rook state                 # one JSON snapshot: workspaces, windows, panes, focus
rook blocks                # one line per pane: id, workspace:window, program, cwd
rook blocks --json         # the same, as a JSON array (workspace, window, place, program, cwd)
rook read . -n 200         # your own pane's last 200 lines, history included
rook read 7                # pane 7's viewport, plain text
```

To *see* what rook is showing — the composed glass, chrome and all,
not one pane's text:

```sh
rook shot                  # the whole glass as text: tab bar, panes, seams, calm bar
rook shot --json           # the same as data, below
rook shot --png /tmp/g.png # a picture you can look at
rook shot 7 --png /tmp/p.png   # one pane's own grid, even hidden or in the background
```

`shot` prints text unless you ask for `--json`:
`{cols, rows, cursor:{x,y,visible}, panes:[{id,x,y,w,h,focused}],
lines:[{y, text, bg?, runs:[{x, w, text, fg?, bg?, bold?, faint?,
italic?, underline?, inverse?, invisible?, cluster?}]}]}`. `x` and `w`
are cells; a run is one character a cell unless `cluster` (one wide or
combined glyph in `w` cells). Colours are resolved `#rrggbb`; an
absent one is the terminal's default. A line's own `bg` means one
fill edge to edge. `panes` is only in the whole-glass shot; a pane
shot is in the pane's own coordinates.

A shot waits until what it shows is still (`--settle MS`, 80): after
`rook key`/`send`/`run` it is the frame after the program answered, so
you do not need a sleep between a key and a shot. `--settle 0` is this
instant.

To test a program with no terminal at all, use `rook play` (below):
it is this, with the server and the sizes handled.

`rook state` is the authority. Its `scope` says whether the person is
at rook's home (`home`) or in a space, and `focus.mode` whether the
mux itself holds their keyboard. Its `panes[]` carry `id`, `program`,
`cwd`, `pwd` (what the shell reported), `title`, `focused`,
`visible`, `lastOutputMs`, `progress` (an OSC 9;4 bar in flight, or
null) and the unread channel: `unread`, `unreadMs`, `bellMs`,
`progressDoneMs`, `notified` (the last desktop notification the
program sent). Parse ids out of it; never guess them from a layout.

`rook watch` prints the same snapshot, then one line per change, for
as long as you read it. Prefer it to polling.

## Open a pane, run something, wait for it

Split beside yourself, keeping the person's focus where it is, and
say which directory the new shell should start in:

```sh
id=$(rook split . --cwd "$PWD" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pane"])')
rook run "$id" 'go test ./...'                  # text plus Enter
rook wait "$id" --match 'ok  ' --timeout 120000 # exit 1 on timeout
rook wait "$id" --quiet 1500 --timeout 60000    # or: nothing changed for 1.5 s
rook read "$id" -n 120
```

`--down` splits below instead of beside. `rook window . --cwd DIR`
opens a new window in your workspace rather than a split. `--focus`
on either brings the new pane in front of the person; leave it off
for background work. `rook close-pane ID` hangs a pane up. Close only
what you opened.

## Test a terminal program

To try out a TUI or a CLI the way you would a web page in Playwright,
give it a session of its own — an isolated rook with no terminal, the
program in its pane — and drive it. This does not need you to be
inside rook, and never touches the person's session:

```sh
export ROOK_PLAY=$(rook play start --size 100x30 -- ./my-tui)   # now every rook verb is the session's
rook expect "Ready"                     # waits until it is on the screen; exit 1 + the screen if not
rook key . down                         # . is the pane under test
rook expect "second item" --bg '#f0c674'    # asserts how it is drawn, too
rook find "second item" --json          # where text is: x, y, w, fg, bg, bold
rook click "Save"                       # if the program takes the mouse
rook shot . --png /tmp/now.png          # look at it; or `rook shot .` for text
rook play stop $ROOK_PLAY               # ends it, prints the path of an HTML trace of every step
```

`expect` retries for `--timeout` ms (3000) and needs no sleep before
it: `--row N`, `--fg/--bg #rrggbb`, `--bold`, `--inverse`, `--count N`,
`--no-text S`, `--regex RE`, `--cursor X,Y`. Learn a colour with
`find`, then assert it. The command after `--` is typed into a plain
`/bin/sh`, so when the program exits you can still read what it
printed. Start as many sessions as you need (`rook play ls`), and stop
the ones you started.

## Services in the background

Something the person needs running but not on their screen — a dev
server for the worktree they are about to try, a watch that must
outlive your session — goes in the background: a pane in no window.

```sh
id=$(rook bg run --by "$YOU" --port 8081 -- npm run dev | python3 -c 'import json,sys; print(json.load(sys.stdin)["pane"])')
rook bg run --port auto -- 'vite --port $PORT'   # rook picks a free port, exports $PORT
rook bg wait "$id" --timeout 60000   # 0 once the port answers; 1 if it exited or timed out
rook read "$id" -n 80                # its log, without bringing it forward
rook bg --json                       # every row: group, health, ports, place, by, command
rook bg kill "$id"                   # or a group name
```

The group is your pane's workspace unless `-g NAME` says otherwise, and
closing that workspace stops the group. A group is a name (not a
number, no leading dash, at most 32 bytes). After `--` the words run
under one shell: quote what must stay together. `health` is `starting`,
`healthy`, `conflict` (something else holds the port you promised),
`running` (no port promised) or `exited`. A service that exits is kept
and reported (`health: exited`); read it, then `rook bg kill` it. Tell
the person what is up and where (`rook notify`), and leave bringing it
forward (`rook bg show GROUP`, their `prefix-B`) to them unless asked.

## Type into a pane

```sh
rook send 7 'some text'        # verbatim, no Enter
rook run 7 'make build'        # with Enter
rook key 7 ctrl-c              # named keys: enter esc tab up down left right
rook key 7 esc                 #   space backspace shift-tab ctrl-<letter>
```

Named arrows are sent the way the program asked for them (a curses
program gets its application-mode arrows); `send` is always verbatim.

A pane running another agent is a pane like any other: read it,
prompt it with `rook run`, answer its dialogs with `rook key`. Before
answering a permission prompt that is not yours, read it back and ask
the person.

## Where attention is owed

A pane goes **unread** when its program rang the bell, sent a desktop
notification, or finished a progress bar while nobody was looking at
it, and stays unread until a person focuses it. `rook jump` focuses the
oldest unread pane (the person's `prefix-u`); `rook focus ID` brings a
specific pane forward. Use `focus` and `jump` only when the person
asked to be taken somewhere.

## Coming back after a restart

If you are an agent with a session that can be resumed, tell rook how,
once, when you start. Claude Code does this from a `SessionStart` hook:

```sh
rook resume . "claude --resume $SESSION_ID"
```

Rook remembers it while you are the program in front, and after the
server restarts your pane comes back running that command. `rook
resume . --clear` forgets it.

## Owning a pane's keyboard

If you are driving a pane — typing into it with `rook send`, reading
it back, acting on what it shows — say so, once, and the person's
glass will show it and gate their typing behind a handoff instead of
letting keystrokes land in the middle of your work:

```sh
rook own 7 'claude·main'      # you own pane 7's input; the bar says so
rook own 7 --paused 'claude·main'   # attached, not operating: keys are theirs
rook own 7 --release          # hand it back
```

While you own it, `rook state` shows `panes[].input.state` as `agent`.
If the person asks for the keyboard it becomes `takeover-requested`:
finish the step you are on, then `--release` — that yields, and they
confirm. `human` means they took it (or never gave it); stop typing
into that pane. Never claim a pane you did not open or were not asked
to drive, and never claim the pane the person is typing in.

## Workspaces

```sh
rook ls                        # workspace names
rook new -q NAME [DIR]         # create one without moving the person
rook new -q NAME DIR -- claude # …born running a program; the pane ends when it does
rook close NAME                # close one: every pane in it is hung up
rook switch NAME               # (a person lands at home — a work navigator
                               #  and an inspector; rook . or rook --space
                               #  NAME land them in a space)
rook rename NAME               # name the current tab (a tab is named once;
                               # rook never renames it after that)
```

## Rules

- Parse ids from JSON. Do not derive them from the sidebar or the tab bar.
- Keep the person's focus unless they asked to be moved: no `--focus`,
  no `rook focus`, no `rook jump` for your own convenience.
- Never run `rook kill` against the person's server: it stops it and
  every pane in it. A server you started on your own `ROOK_MUX_SOCK`
  is yours to kill.
- Errors are one line on stderr with exit status 1; usage mistakes exit 1 too.

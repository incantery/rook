---
name: rook
description: "Drive rook, the terminal multiplexer this shell may be running inside: open panes beside you, type into them, read them back, wait on them, and hear which pane needs a person. Use only when the task asks for a terminal you can watch, another agent to run, or rook itself."
---

# rook

rook keeps workspaces of windows of panes on a server that outlives
the terminal, and publishes everything it knows. The `rook` binary on
`PATH` is the whole interface; every verb below is a one-shot command
that prints JSON when something is reading its stdout.

Check first that you are inside a rook pane. The variable is the id of
the pane you are running in:

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

`rook state` is the authority. Its `scope` says whether the person is
at rook's home (`root`) or in a space, and `focus.mode` whether the
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

## Type into a pane

```sh
rook send 7 'some text'        # verbatim, no Enter
rook run 7 'make build'        # with Enter
rook key 7 ctrl-c              # named keys: enter esc tab up down left right
rook key 7 esc                 #   space backspace shift-tab ctrl-<letter>
```

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
- Never run `rook kill`; it stops the server and every pane in it.
- Errors are one line on stderr with exit status 1; usage mistakes exit 1 too.

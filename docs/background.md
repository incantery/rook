# The background

A pane exists apart from where it is shown. Most are in a window; a
few are docked to a rail; one may float as a popup. A pane in the
background is in none of those: it runs, it keeps its screen and its
history, and it is on no glass until somebody brings it forward.

It is for what you need running and do not need to look at — the dev
server and the bundler for the worktree you are trying out, a watch on
a deploy. An agent starts them, says they are up, and your workspace
is as it was. You bring them into a window to read a log or poke at
one, and send them back with one key.

tmux does this by hand (a detached `services` session, `break-pane -d`,
`join-pane`); zellij hides a tab's floating panes. Neither has a group
that follows a worktree, or says what is listening where.

## The model

| | what it is | lives in |
|---|---|---|
| the background | pane ids placed nowhere, in the order they went back | `Server.shelf` |
| a group | a name on the pane: what goes back and comes forward together. It stays on the pane wherever the pane is | `Pane.group` |
| a service | a pane `rook bg run` started: it carries its command, who started it, and the port it promised | `Pane.svc`, `.by`, `.port` |
| a held pane | a service whose program exited: kept, with its screen, until somebody closes it | `Pane.held`, `Server.reap` |

- **A group is named for the workspace it serves.** `rook bg run` from
  a pane takes that pane's workspace as the group unless `-g` says
  otherwise; a plain pane sent back takes the workspace it was in. So
  the foreground key in a workspace brings *its* group, and `rook
  close <workspace>` — which is what removing a worktree runs — hangs
  its group up with it, wherever its panes are: in the background, or
  brought out into another workspace. A workspace whose last pane merely exited does
  not: only a close on purpose takes the services.
- **Hidden from the layout, not from you.** The calm bar's `bg` module
  counts what is back there and what has died (`bg 3 · ✕ 1 exited`);
  `rook bg` is the table; `rook blocks` lists them as `bg:<group>`; the
  state feed says `background`, `group` and `service` on every pane.
- **A group's name is a target**, so it has to be sayable as one: up
  to 32 bytes, no tab or newline, not a number (that is a pane), not
  `.`, not starting with `-`. `bg run` and `bg hide -g` refuse the
  rest. A group that took such a name from its workspace or its
  directory (a workspace called `5`) is said outright: `rook bg show
  group:5`.
- **Rook stays up for what it is keeping.** The last window closing
  ends the server — unless something is in the background, and then
  home is seeded and shown instead.
- **Rook does not supervise.** Nothing is restarted and nothing is
  probed by the engine. A service that exits is *kept* — in the
  background or in the window it was showing in — and said once on
  the bar; its last screen is the reason, and `rook read` reads it. A
  pane closed on purpose (`bg kill`, the kill key, `rook close`) is
  simply gone.
- **Health is asked of the machine, by the front door.** `rook bg`
  walks each pane's process tree for listening TCP ports (`lsof`), and
  a service that promised a port (`--port`) is `starting` until
  something answers on it and `healthy` after — when it is the
  pane's own processes listening. A promised port some other process
  holds is `conflict`, and `bg wait` fails on it at once. A port that
  answers and that no process of yours can be seen holding (a
  container's) is taken as the service's. A service that hands its
  listener to a process that leaves its tree (a daemon) reads
  `conflict` for the same reason: the port is not the pane's any more. No promise, no claim: it is
  `running`. `--port auto` picks a free port, promises it, and
  exports it to the command as `$PORT`.
- **Size.** A pane in the background keeps the size it last had, and
  is resized by the window it comes into.
- **The unread channel leaves it alone.** A background pane that rings
  a bell is not fetched into your window by `jump`.
- **Rook always has something to show.** The last pane placed anywhere
  is refused, and so is a workspace's last window pane while it has
  pinned panes; a group that is every pane there is goes back whole or
  not at all. Home, emptied, starts over as it does when closed.
- **A service that has exited is a zombie process until its pane is
  closed** — rook keeps the pid so nothing else can be mistaken for it
  — and a service that forks a daemon and exits has left rook: it
  reads `exited`, and nothing here stops the daemon.
- **It is saved.** The restore file has a `bg group\tby\tport\tcwd\t
  command` line per pane: a service is run again, in the background —
  wherever it was — and a plain pane is a shell there again. A dead
  service is not saved. A command of several lines is one line there,
  its newlines escaped; a directory whose name has a tab or a newline
  in it is not written, and the pane comes back where the server
  started.

## The verbs

```sh
rook bg                                  # the table (--json for a program)
rook bg run --port 8081 -- npm run dev   # start a service; prints its pane
rook bg run -g conferences --by vera --port auto -- 'vite --port $PORT'
rook bg wait conferences --timeout 60000 # until every pane of it is healthy;
                                         # status 1 if one exited, or on timeout
rook bg wait 12 --exit                   # until it ends: a watch
rook read 12 -n 80                       # its log, without bringing it forward
rook bg show conferences                 # into the window on the glass, focus kept
rook bg show conferences --window --focus --space main
rook bg hide conferences                 # back, whole
rook bg hide . -g scratch                # this pane, under a name
rook bg kill conferences                 # hang them up
```

A target that is a number (or `.`) is a pane; any other word is a
group. After `--` the words are joined and run under `$SHELL -c`, the
same as `rook new -- …`: quote what the shell should see as one thing.

Keys (`[keys]`, docs: `mux/src/keys.zig`): `background` (`b`) sends the
focused pane back, and with it every pane of its group that is out;
`foreground` (`B`) brings this workspace's group into the window, else
the group most lately sent back. `rook bg pick` is an fzf picker over
the groups, for a popup: `B = "popup rook bg pick"`.

## For a program

`rook bg --json` rows: `id`, `pid`, `group`, `place` (`bg`, `window`,
`pin`), `workspace`, `window`, `program`, `command`, `by`, `port`,
`cwd`, `bornMs`, `exited`, `exitMs`, `lastOutputMs`, `ports`, `health`
(`starting`, `healthy`, `conflict`, `running`, `exited`).

The state feed (`rook watch`) is the push channel: a service exiting
is a snapshot with `panes[].exited` true and `service.exitMs` set, and
because every line is the whole state, a reader that reconnects is
right on the first line it gets — there is no event to have missed.
`rook bg wait` is the one-shot form.

## Tests

`scripts/bg-fixture.py` drives a sandboxed engine through a real glass:
run, health and ports, show and hide, the keys, the last pane, death
and kill, closing a workspace, restore, `--port auto` — and what
stress testing broke: labels, a stolen port, eighty services, a group
shown elsewhere, a dead pane, the whole group or none, a pin, the last
window, a restore file past 64 KB.

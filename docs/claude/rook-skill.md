---
name: rook
description: Drive and inspect the rook terminal — the native macOS terminal/multiplexer/editor this shell may be running inside. Read any pane's screen, take pixel screenshots, send input, open files in its editor, manage workspaces and git worktrees, all via `rook <verb>`. Use when asked to interact with, verify, or automate the terminal app, when a task needs an isolated throwaway terminal, or when $ROOK_SOCK is set.
---

# Driving rook

rook is a native macOS terminal, multiplexer and editor in one binary.
Every running instance serves a control socket, and the `rook` binary is
its own client: `rook <verb> [args]` sends a verb to the running app,
prints the reply, and exits 1 on an `err` reply. You are likely running
inside rook if `$ROOK_SOCK` is set or `/tmp/rook.sock` exists.

The complete reference is `man rook-ctl` (all verbs), `man rook` (the
CLI), `man rook-config` (configuration), `man rook-plugin` (plugins).
Trust those over this summary when they disagree.

## Seeing — verify your own work instead of asking

```
rook dump              # focused pane's screen as text (dump@3 for pane 3)
rook shot /tmp/x.png   # PNG of the window — what was actually RENDERED
rook panes             # every pane: id, geometry, terminal-or-editor
rook tabs / rook workspaces / rook docs / rook statusbar / rook lsp
```

`dump` is ground truth for "what is rook showing"; `shot` needs no
screen-recording permission (rook writes its own Metal drawable).

## Driving

```
rook run <command>     # highest level: any registry command by id
rook commands          # ...and this lists every id
rook type 'text'  /  rook enter  /  rook ctrlc     # into the focused pane
rook press TAB         # one keystroke through the chrome (leader, palette)
rook key 1b5b41        # raw hex bytes to the pty (this is Up Arrow)
rook click 400 300  /  rook split right  /  rook focus left  /  rook zoom
```

Verbs act on the focused pane unless addressed: `rook dump@3`,
`rook type@3 text` (ids from `rook panes`).

## Files

`rook <file>` (or `re <file>`) opens the file in the running rook's
editor. Relative paths resolve against your cwd.

## Workspaces and worktrees

```
rook workspaces                      # declared workspaces + their git worktrees (derived live)
rook worktree add <workspace> <name>    # checkout of branch <name>, replies with the path — cd there
rook worktree remove <workspace> <name> # refuses unmerged commits and dirty checkouts
```

`worktree add` is the sanctioned way to get an isolated checkout for
parallel work on a declared workspace.

## Config, plugins, attention

```
rook env / rook env apply    # pending config diff / apply it
rook plugins                 # declared plugins, state, grants
rook attention               # the attention inbox plugins raise into
```

Configuration is a graph emitted by a program in `~/.config/rook`
(`man rook-config`). Do not hand-edit `environment.json` when a config
program exists — edit the program; rook notices, runs it, and shows the
diff.

## A throwaway rook for experiments

```
rook --config=/tmp/try win --no-activate &   # isolated instance: own socket, config, data
ROOK_SOCK=/tmp/try/rook.sock rook dump       # talk to it
rm -rf /tmp/try                              # it never happened
```

Prefer this over experimenting on the user's live instance.

## Cautions

- `rook quit` exits the app IMMEDIATELY and kills every shell in every
  pane — possibly including the one you are running in. Never send it
  to the user's instance unasked.
- The line protocol has no quoting: arguments are joined with single
  spaces, so an argument containing a space arrives as two tokens.
- The socket has no authentication; treat verbs against the user's
  instance as actions on their screen, because they are.

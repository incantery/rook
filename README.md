# rook

`rook` is what you run after starting your terminal, in place of
`tmux`: a Go front door over a multiplexer rook owns — ptys and
ghostty's terminal emulator in one Zig process, behind a server that
outlives the glass.

**The bet.** The multiplexer is solved; what is not solved is the
layer above it: N agents in N sessions, each producing turns, and no
way to route attention across them. That layer is the product. Rook
draws it, publishes everything it knows, and holds one opinion about
what an agent is: a program by name. Everything an agent is *doing* is
a producer's word, pushed in from outside — vera is the first producer
and must not be the last. `docs/surfaces.md` is that seam, in full.

**What this is not.** Not a terminal emulator, not an editor. Ghostty
and neovim are tenants. tmux is the reference implementation the
conformance corpus is diffed against, and nothing else.

**Run it.**

```sh
make install     # go build ./cmd/rook → ~/.local/bin/rook, the engine → ~/.local/libexec/rook/engine
rook             # attach; boots the server when none is listening
```

One command. The engine is off `$PATH`; `rook` execs it for every mux
verb and keeps worktrees, the picker and the web URL in Go. `mux/README.md`
is the engine's own manual: the keys, the rail, the state feed, the
build. The prefix comes from `~/.config/rook/rook.toml` (`[tmux]
prefix = "` "`", `C-b` when unset).

**Workspaces, windows, panes.** `rook ls / new / switch / pick`;
`prefix-c` a window, `prefix-v` / `prefix--` a split, `prefix-hjkl`
focus (a bare `ctrl-hjkl` too, vim-navigator style, with
`mux/nvim` handing edge moves back), `prefix-z` zoom, `prefix-[` copy
mode, `prefix-P` pin a pane to the rail, `prefix-s` the picker,
`prefix-w` worktrees, `prefix-u` the oldest thing you have not
read. The tabs are clickable: a chip is its window,
the `+` a new one. A tab is named once — the first program in it that
was not the shell, or `rook rename` — and rook never renames it; the
actor that claimed a pane in it rides after the name, `deploy · main ◐`;
the tool is the bar's word, never the tab's.

**The frame.** One tab bar across the top — the space's name in the
scope slot, then its tabs — the work at full width under it, and one
calm bar across the bottom. No sidebar: the legacy spaces/agents
panel is off unless `[mux] sidebar_mode = "open"` asks for it.

**Altitude.** `prefix-o` changes altitude, from the space into rook
itself: the scope slot becomes the system's chip, `rook` in the
accent block, with the world in one line after it (`3 spaces · 2
agents working · 1 needs you`) and the way back in the corner, and
the whole canvas holds every space —
attention first (unread panes, what a producer says needs you), then
the spaces in a stable order, each a figure of what rook can
truthfully say about it (its tabs and who drives them, an event, the
last lines you were looking at) or one row when it has nothing to
say; then the global pins, which do not move a column. The cursor is
already in one input: type to find a space, tab or pane; `:` for a
command (`:go`, `:new`, `:rename`, `:close`); the last row hands the
same text to vera when she is open. `↵` acts, typing never does; Esc
clears the query first and then puts you back exactly where you
were. `prefix-C-o` returns after any hop. Narrow glass draws the same
spaces as rows. `docs/altitude.md` is the model and the ontology;
`scripts/altitude-fixture.py` renders it deterministically.

**The calm bar.** One row at the bottom: who holds the focused pane's
keyboard on the left — `you ▸ nvim`, or `claude·main ▸ owns input ·
you observe` once an agent has claimed it with `rook own` — and the
signals on the right (`◐ 2 · !1 · •3 · ⊕g 1`). Typing at an owned pane
opens a gate instead of landing: request a handoff, take now, or send
the keys as a message. `prefix-i` inspects the pane. `[mux] bar =
false` turns the row off.

**The rail (legacy, off by default).** A left panel of *spaces* over
*agents*, a dot and two lines each, behind `[mux] sidebar_mode =
"open"`. Its model still feeds the state feed and the altitude view:
rook lists its own workspaces and the panes it can see running an
agent; a producer pushes the rest, one JSON frame per line:

```sh
rook side demo | rook side -     # the herdr design, as frames
my-producer    | rook side -     # the real thing (vera's verad does this)
```

**What the programs say.** Every pane's bell, desktop notification
(OSC 9 / 99 / 777), title, working directory (OSC 7) and progress bar
(OSC 9;4) is heard and published. A bell rings the glass; a
notification reaches it as OSC 777, so the terminal that can reach
your desktop does. A signal that arrives while nobody is looking at
its pane puts the pane on the **unread** channel — a dot on its tab
and on the rail — until you look. `prefix-u` and `rook jump` go to the
oldest one. Rook publishes the words; it never reads them for meaning.
`docs/attention.md`.

**The state feed.** Everything rook knows, as one JSON snapshot, so
anything can hold an exact replica and never has to ask:

```sh
rook state          # the snapshot
rook watch          # the snapshot, then one line per change
rook companion      # where vera is open in rook, if she is; exit 1 when not
```

**A pane, by id — for the agent inside one.** `$ROOK_MUX_PANE` is the
id of the pane a program runs in, and `.` names it:

```sh
rook split . --cwd "$PWD"        # a shell beside you; focus stays put
rook run 7 'go test ./...'       # type it, with Enter
rook wait 7 --match 'ok  ' --timeout 120000
rook read 7 -n 120               # its last 120 lines, history included
rook key 7 ctrl-c
rook skill --install             # the whole manual, for an agent, where Claude Code loads it
```

**Coming back.** The server saves its workspaces, windows and cwds,
and restores them on boot (`[mux] restore = false` to opt out). A pane
whose program told rook how to bring it back comes back *running*:

```sh
rook resume . "claude --resume $SESSION_ID"   # the program's own word, kept while it is in front
```

For Claude Code that is one `SessionStart` hook, and `claude-plugin/`
carries it (`/plugin marketplace add <repo>/claude-plugin`, then
`/plugin install rook@incantery`); by hand it is:

```json
{"hooks": {"SessionStart": [{"hooks": [{"type": "command",
  "command": "rook resume . \"claude --resume $(jq -r .session_id)\""}]}]}}
```

Outside rook the hook is silent and exits 0. After `rook kill && rook`
— or a crash, or a reboot — every Claude pane reopens its own
conversation, typed into the rebuilt shell as you would have typed it.
When Claude has quit, the pane is a shell again and comes back as one.

**Worktrees.** One agent, one branch, one checkout, one workspace —
and a lifecycle that ends with all of them gone. `rook worktree` is
the manager (`prefix-w` floats it); the verbs are plain commands from
any checkout:

```sh
rook worktree ls              # the rows, once; --json for machines
rook worktree new agent-a     # ../<repo>--agent-a on branch agent-a, workspace opened
rook worktree merge agent-a   # merge into main, then remove worktree + workspace + branch
rook worktree rm agent-a      # refuses dirty or unmerged; --force to discard
```

Files git doesn't carry but a checkout needs are conventions in
`rook.toml`, copied or linked from the main checkout into every new
worktree:

```toml
[worktree]
copy = [".env"]
link = ["node_modules"]
```

**The companion.** One resident is named in the config and rook knows
her by sight — vera by default — so "is she already open, and where"
is a question rook answers:

```toml
[companion]
command = "vera"        # or program = "vera"; program = "" turns the slot off
```

**A second glass.** `web/` is the browser as a peer client on the same
wire; `rookd` supervises the server and runs the bridge, `rook url`
prints the address for a phone.

**Pulling things back.** The previous rook — the Zig app with an
editor in it, the plugin vocabulary, the environments graph — is
intact on the `pre-tmux` branch, and the tmux-era rook on `rook/tmux`.
Take a file when it earns its place, not by default:

```sh
git checkout pre-tmux -- docs/plugins/VOCABULARY.md
```

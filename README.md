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

**Workspaces, windows, panes.** `rook ls / new / switch / close / pick`
(`rook new -q <name> <dir> -- claude` is a space born running a program);
`prefix-c` a window, `prefix-v` / `prefix--` a split, `prefix-hjkl`
focus (a bare `ctrl-hjkl` too, vim-navigator style, with
`mux/nvim` handing edge moves back), `prefix-z` zoom, `prefix-[` copy
mode, `prefix-P` pin a pane to the rail, `prefix-u` the oldest
thing you have not read. Those are defaults: every key after the
prefix is a row in `[keys]` (`v = "split-right"`, `x = ""` unbinds),
and rook binds nothing that runs a program. A picker, worktrees, an
agent — you float them yourself: `s = "popup rook pick"`,
`g = "popup 72x86@124x48 grim"` (`rook popup` is the same from a
prompt). The verbs are listed in `mux/src/keys.zig`. The tabs are clickable: a chip is its window,
the `+` a new one. A tab is named once — the first program in it that
was not the shell, or `rook rename` — and rook never renames it; the
actor that claimed a pane in it rides after the name, `deploy · main ◐`;
the tool is the bar's word, never the tab's.

**The frame.** One tab bar across the top — the space's name in the
scope slot, then its tabs — the work at full width under it, and one
calm bar across the bottom. No sidebar: the legacy spaces/agents
panel is off unless `[mux] sidebar_mode = "open"` asks for it.

**Home.** Plain `rook` lands at rook's home, not in a space: the
scope slot is the system's chip, `rook` in the accent block, then
the view and what is selected. The canvas is a work navigator on
the left — what needs you (vera's proposed actions, a pane that
rang, a task a producer says is waiting or failed), what is in
progress by goal, what finished, the spaces — and an inspector on
the right for the selected thing: the goal, the current step, the
plan with its progress, the timeline, files, commits, tests,
artifacts, usage, the last lines its pane wrote, and the controls
the producer supports (an answer to its question, pause, stop,
retry), each a command run on ↵, plus `open its pane` and `ask
vera about this`. `j k` move, `l` inspects, `h` is the list, `o`
opens the exact workspace; typing a letter summons vera. `prefix-t`
is vera's pane from anywhere — over the inspector, over a space's
panes without resizing them — and again dismisses her with her
thread and draft kept; `prefix-T` pins her. `/` finds, `:`
commands, `prefix-o` from anywhere comes back home, Esc closes one
layer at a time. Under 81 columns the navigator and the inspector
are a stack. `prefix-s` floats the picker from home too, and
`:orbit` is orbit; `rook .` and `rook --space
<name>` land in a space outright; `startup = "last-space"` makes
plain `rook` do that too. `docs/altitude.md` is the model and the
ontology; `scripts/altitude-fixture.py` renders it deterministically.

**The calm bar at home** is composed from `[mux] status_home`: `rook
· home · navigator` on the left, and on the right `agents ◐ 2
active · 1 idle`, `! 2 need you`, `✕ 1 failed`, `session $4.18 ·
812k tokens` (the producer's usage, since this server started) and
`vera ready` — warnings off at zero, usage off until someone reports
it. A space's bar (`status_space`) keeps `you ▸ tool` and the
signals, with one global `! n need you`.

**The calm bar.** One row at the bottom: who holds the focused pane's
keyboard on the left — `you ▸ nvim`, or `claude·main ▸ owns input ·
you observe` once an agent has claimed it with `rook own` — and the
signals on the right (`◐ 2 · !1 · •3 · ⊕g 1`). Typing at an owned pane
opens a gate instead of landing: request a handoff, take now, or send
the keys as a message. `prefix-i` inspects the pane. `[mux] bar =
false` turns the row off.

**The rail (legacy, off by default).** A left panel of *spaces* over
*agents*, a dot and two lines each, behind `[mux] sidebar_mode =
"open"`. Its model still feeds the state feed and home:
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
and a lifecycle that ends with all of them gone. The model is
[grove](https://github.com/incantery/grove)'s, with rook as the place
a worktree is worked in; `prefix-w` floats grove's manager, and the
verbs are plain commands from any checkout — `grove` at a prompt does
the same without rook:

```sh
rook worktree ls              # the rows, once; --json for machines
rook worktree new agent-a     # ../<repo>--agent-a on branch agent-a, workspace opened:
                              # the local branch, origin's (tracked) if origin has it,
                              # else a fresh one off main; --fetch asks origin first
rook worktree merge agent-a   # merge into main, then remove worktree + workspace + branch
rook worktree rm agent-a      # refuses dirty or unmerged; --force to discard
```

Files git doesn't carry but a checkout needs are conventions in
`rook.toml` (this person's, for every repo) or `grove.toml` at the
repo root (the repo's own), copied or linked from the main checkout
into every new worktree:

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

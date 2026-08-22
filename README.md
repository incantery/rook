# rook

A rebuild from an empty Go module, around open-source tooling instead of
under it. `rook` is what you run after starting your terminal, in place of
`tmux`.

**The bet.** The multiplexer and the jump list are solved — tmux, zoxide.
What is not solved is the layer above them: N agents in N sessions, each
producing turns, and no way to route attention across them. That layer is
the product. Everything else is a dependency and stays one — until its
data model caps the product, which is how
[sesh](https://github.com/joshmedeski/sesh)'s ideas got absorbed into
`rook ls / preview / connect` instead of staying a dependency.

**What this is not.** Not a terminal emulator, not an editor, not a
multiplexer. Ghostty and neovim are tenants. tmux is a `depends_on`, never
vendored.

**What is here.** `rook` boots a bare tmux: its own server socket (`-L
rook`) under a config rook generates — the user's `~/.tmux.conf` is
never read, their tmux is never touched. `internal/tmux.Settings` is the
proxy: one field per tmux option, rendered atomically to
`~/.local/state/rook/tmux.conf` at boot, reconciled live via
`set-option` on the socket. Colours are ANSI names on purpose: the glass
owns the palette, rook owns structure and emphasis.

**Run it.**

```sh
make install     # go build -o rook ./cmd/rook, then into ~/.local/bin
rook             # attaches to a session named for the current directory
```

One binary, over a rook-owned tmux server. `rook ls / preview / connect`
are the session manager; the bottom strip carries per-pane git and the
active pane's spend; the attention feed routes what needs you across
every session (vera is its first publisher).

**Agents.** `prefix a` (or `rook agents`) is the fleet on one board:
every agent on the server as a card — where it is, its state, the
attention headline, the tail of its screen — the ones that need you
first. Basic answers happen from the board (`y` confirms, `1-9` picks
an option, `esc` interrupts, `x` kills); Enter jumps to the agent.
`rook agents --json` is the same list for machines.

**Worktrees.** One agent, one branch, one checkout, one session — and a
lifecycle that ends with all of them gone. `rook wt` is the manager — a
TUI that draws the repo's worktrees with branch, dirty, ±distance from
main, ● live session and the agent's state in it, refreshed live.
`prefix w` runs the same program in a popup. Enter opens, `n` cuts a
new one, `m` merges it home, `d` removes (`D` to force). The same verbs
are plain commands from any checkout of the repo:

```sh
rook wt ls                # the rows, once; --json for machines
rook wt new agent-a       # ../<repo>--agent-a on branch agent-a, session opened, switched to
rook wt merge agent-a     # merge into main, then remove worktree + session + branch
rook wt rm agent-a        # refuses dirty or unmerged; --force to discard
```

Files git doesn't carry but a checkout needs are conventions in
`rook.toml`, copied or linked from the main checkout into every new
worktree:

```toml
[worktree]
copy = [".env"]
link = ["node_modules"]
```

**Pulling things back.** The previous rook — the Zig app, the plugin
vocabulary, the environments graph, the providers — is intact on the
`pre-tmux` branch. Take a file when it earns its place, not by default:

```sh
git checkout pre-tmux -- docs/plugins/VOCABULARY.md
```

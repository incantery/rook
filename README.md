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

**Worktrees.** One agent, one branch, one checkout, one session — and a
lifecycle that ends with all of them gone. `prefix w` is the manager
(Enter opens, `C-n` cuts a new one named by what you typed, `C-g` merges
it home, `C-x` removes); the same verbs are plain commands from any
checkout of the repo:

```sh
rook wt ls                # worktrees with branch, dirty, ±distance from main, ● live session
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

# rook — the tmux branch

A rebuild from an empty Go module, around open-source tooling instead of
under it. `rook` is what you run after starting your terminal, in place of
`tmux`.

**The bet.** The multiplexer, the session manager and the jump list are
solved — tmux, [sesh](https://github.com/joshmedeski/sesh), zoxide. What is
not solved is the layer above them: N agents in N sessions, each producing
turns, and no way to route attention across them. That layer is the product.
Everything else is a dependency and stays one.

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

**Pulling things back.** History is intact one branch over — the Zig app, the
plugin vocabulary, the environments graph, the providers:

```sh
git checkout main -- docs/plugins/VOCABULARY.md
```

Take a file when it earns its place, not by default.

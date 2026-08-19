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

**What is here.** An empty module and this file.

**Pulling things back.** History is intact one branch over — the Zig app, the
plugin vocabulary, the environments graph, the providers:

```sh
git checkout main -- docs/plugins/VOCABULARY.md
```

Take a file when it earns its place, not by default.

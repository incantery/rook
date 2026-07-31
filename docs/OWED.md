# What the Go core took with it

rook's core is Zig. The Go that remains is `providers/` and `sdk/` — and
that is deliberate: a provider is a separate process reaching one external
system, and Go is a fine language to write one in.

Getting there deleted four things that worked. They are listed here rather
than in a commit message because they are *owed*, not gone-and-forgotten,
and the shape each should come back in is the interesting part.

## 1. The issue queue → a plugin, not a port

> **Update, 2026-07-31: the loader, the surface and actions landed.** rook
> reads `plugin` nodes, spawns what they name, speaks the protocol, refuses
> ops the config did not grant, renders the items as a side-pane List, and
> runs `items.act` on a row — with the plugin's own `confirm` standing
> between the human and anything destructive (`app/src/plugins.zig`,
> `drawPlugin`/`pluginKeyLocked` in `app/src/macos.zig`, e2e scenario
> `plugins`).
>
> What is still owed here is the *issues* half specifically: a provider
> speaks `sdk/provider`, not the plugin protocol, so either the two grow a
> shim or a provider becomes a plugin. That is a decision, not a port.

`rookctl issues` asked the host, which spawned `rook-provider-github` /
`rook-provider-linear` and merged their answers. The provider protocol
(`sdk/provider`) is unchanged and both providers still build.

What is missing is the *caller*: something that spawns a provider, speaks
newline-delimited JSON over its stdio, and renders `provider.Issue` as a
list. That is not a port of the Go code — it is the first real plugin
surface, and it should land as `docs/plugins/VOCABULARY.md`'s List over
the item model rather than as a hardcoded issues panel.

## 2. Worktree creation

`POST /workspaces/{name}` with a `worktreeOf` carved a git worktree under
the data dir, on a branch named by the workspace. The deletion guard
(refuse to remove a worktree with dirty files or unmerged commits) was the
part with the teeth.

All of it is `git` subprocess work. It belongs in Zig beside
`workspaces.zig`, which already reads the registry.

## 3. Self-update

`rookctl update` compared the running version against the latest GitHub
release, downloaded the zip, verified the checksum, and swapped the
binary. `install.sh` is the upgrade path until this comes back.

The awkward part was never the download — it was that the running binary
rewrites itself, which is why the old one resolved symlinks first.

## 4. The keychain shim

`rookctl set-linear-token` shelled out to `/usr/bin/security` to store the
Linear API key. rook wrote it and never read it back —
`rook-provider-linear` fetches it itself, which is what kept the
credential out of rook's address space.

The provider still reads the keychain. Only the *writer* is gone, so the
key has to be put there by hand today:

    security add-generic-password -U -s rook -a linear -w

This one arguably belongs in the provider rather than in core: whoever
owns a credential should own storing it.

## 5. Syntax highlighting → a loaded grammar, not a linked one

Five tree-sitter grammars were compiled into the binary: 940k lines of
generated parse table, 4.6MB of a 7.1MB rook, with typescript and tsx
alone accounting for 3MB. Removing them took the binary to 2.7MB.

**rook was the outlier here, not the innovator.** Every other editor loads
grammars rather than linking them:

| editor | how |
|---|---|
| neovim | `.so` per grammar, `dlopen`'d; `:TSInstall <lang>` builds one |
| helix | `.so` per grammar, built by `hx --grammar build` |
| emacs | `.so`, via `treesit-install-language-grammar` |
| zed | wasm extensions |
| vscode | no parse tables at all — TextMate grammars are JSON data |

The shape to come back in is the same one: a grammar is a dylib exporting
one `tree_sitter_<name>` symbol plus a `<name>.scm` query beside it, and
rook `dlopen`s it on first use of a matching extension. `ts_parser_set_language`
takes a `*const TSLanguage` pointer and does not care where it came from,
so this is a load path, not a redesign.

Note what class of plugin that is. Everything that became a plugin in the
strip was OUT of process — a subprocess speaking newline-JSON, because it
was reaching an external system and latency did not matter. A parser runs
on the frame budget and has to be in-process. So grammars want a NATIVE
plugin seam (dylib, shared address space, no protocol) that rook does not
have, and `docs/plugins/VOCABULARY.md` does not describe. That is the real
work here — the loader itself is a hundred lines.

The mechanism survived the deletion: `editor.Editor`'s `hl_reparse` /
`hl_spans` / `hl_set_path` / `hl_destroy` are nullable function pointers,
and an editor with none set renders plain text. That is the path headless
tests have always taken, so it is proven rather than hoped. Whatever loads
grammars next fills in the same four hooks.

Half the language story already works this way: LSP servers are separate
processes rook spawns from a catalog (`lspmgr.zig`), so diagnostics,
go-to-definition and hover are unaffected by any of this. Only the grammar
was welded in.

## What is NOT owed

The daemon. `rook-host` served nobody by the end — the app owns its ptys
in-process and reads the workspace registry through sqlite directly, so
the daemon was spawned at launch, health-checked, and killed on quit
without a single call in between.

The tmux-style split (ptys that survive the app) is still wanted, and
when it is built it should be Zig, designed for that job, rather than the
HTTP host that grew around a webview.

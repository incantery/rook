# What the Go core took with it

rook's core is Zig. The Go that remains is `providers/` and `sdk/` — and
that is deliberate: a provider is a separate process reaching one external
system, and Go is a fine language to write one in.

Getting there deleted four things that worked. They are listed here rather
than in a commit message because they are *owed*, not gone-and-forgotten,
and the shape each should come back in is the interesting part.

## 1. The issue queue → a plugin, not a port

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

## What is NOT owed

The daemon. `rook-host` served nobody by the end — the app owns its ptys
in-process and reads the workspace registry through sqlite directly, so
the daemon was spawned at launch, health-checked, and killed on quit
without a single call in between.

The tmux-style split (ptys that survive the app) is still wanted, and
when it is built it should be Zig, designed for that job, rather than the
HTTP host that grew around a webview.

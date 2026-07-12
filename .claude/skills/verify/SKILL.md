---
name: verify
description: Drive rook's host API and rookctl end-to-end in an isolated environment — build, launch, curl, observe — without touching the user's live rook-host or real data dirs.
---

# Verifying rook changes at runtime

rook is three binaries around one daemon: `rook-host` (pty + registry +
HTTP API), `rookctl` (CLI client), and the Wails app (webview over the
same API). Most changes are observable at the host's HTTP surface or
through rookctl — no need to launch the GUI.

## Isolated host (never touch the live daemon)

The host discovers/publishes via XDG dirs, so isolation is just env:

```sh
S=<scratch dir>; mkdir -p $S/{state,data,shim,bin}
go build -o $S/bin/rook-host ./cmd/rook-host
go build -o $S/bin/rookctl  ./cmd/rookctl
env -i HOME=$HOME USER=$USER \
  XDG_STATE_HOME=$S/state XDG_DATA_HOME=$S/data \
  SHELL=/bin/sh PATH=$S/shim:/opt/homebrew/bin:/usr/bin:/bin \
  $S/bin/rook-host > $S/host.log 2>&1 &
cat $S/state/rook/host.json   # {"port":…,"token":…,"pid":…}
```

- Sessions spawn `$SHELL` in a pty (no tmux) — `SHELL=/bin/sh` keeps
  them inert and profile-free.
- Put a fake `claude` script first on PATH (`$S/shim/claude`, logs
  `$*` to a file) — spawned sessions and the usage prober both call
  `claude`; the shim captures what was typed and burns nothing.
- `rookctl` run with the same env finds this host via
  `$S/state/rook/host.json`. Registry is SQLite at
  `$S/data/rook/rook.db` — inspect with `sqlite3` for persistence
  evidence.
- Teardown: `kill <pid from host.json>`.

## Driving it

```sh
T="Authorization: Bearer <token>"; B=http://127.0.0.1:<port>
curl -s -H "$T" -X POST $B/workspaces -d '{"name":"src","root":"<repo>"}'
curl -s -H "$T" $B/workspaces
```

For tracker/issue flows, the workspace root must be a git repo with a
GitHub remote — a scratch repo with
`git remote add origin https://github.com/incantery/rook.git` works
(gh reads issues without pushing; gh auth comes from $HOME).

## Gotchas

- `go build ./...` fails on `build/ios` (no main — build stub) and on
  `frontend/frontend.go` until `cd frontend && npm run build` produces
  `dist/`. Scope to `./internal/... ./cmd/...`.
- Frontend check: `cd frontend && npx svelte-check --threshold error`.
- Registry migrations are `ALTER TABLE` statements run on every load;
  "duplicate column" is the expected steady-state error.

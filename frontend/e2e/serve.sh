#!/bin/sh
# Boot rook headless so Playwright can drive it (frontend/playwright.config.ts
# runs this as its webServer; `make e2e` is the entry point).
#
# The trick is Wails v3 server mode: `-tags server` builds THIS app — same Go
# services, same generated bindings, same embedded frontend — as a plain HTTP
# server instead of a native window. A browser at $E2E_PORT gets the real
# config.Service and hostclient.Service over POST /wails/runtime, so what the
# tests drive is rook, not a mock of it. The native window is the only thing
# missing; see docs/e2e.md for what that costs.
#
# Everything lands in a sandbox that never touches the daily driver or
# `make dev`: its own XDG triple means its own host daemon, sessions, config,
# and database. bin/ is gitignored and `make clean` clears it.
set -eu

cd "$(dirname "$0")/../.."
PORT="${E2E_PORT:-9333}"
SANDBOX="$PWD/bin/e2e"

mkdir -p "$SANDBOX/xdg/state" "$SANDBOX/xdg/config" "$SANDBOX/xdg/data"

# The Go binary embeds frontend/dist (frontend/frontend.go), so the bundle has
# to be current BEFORE the Go build — tests run the real production bundle.
(cd frontend && pnpm run build >/dev/null)

go build -tags server -o "$SANDBOX/rook" ./cmd/rook
# rook-host must sit next to the executable: that's where hostclient looks
# first (internal/hostclient.hostBinary). Neither binary is stamped, so both
# report Build "dev", which per internal/hostclient means this app rides its
# sandbox's daemon rather than replacing it.
go build -o "$SANDBOX/rook-host" ./cmd/rook-host
# rookctl too: the stub coder claims its window through it, the same call
# claude's SessionStart hook makes.
go build -o "$SANDBOX/rookctl" ./cmd/rookctl
# the `re` shim — a symlink whose NAME is the verb (argv[0] dispatch);
# the takeover spec drives it exactly the way a user's shell does
ln -sf "$SANDBOX/rookctl" "$SANDBOX/re"

export XDG_STATE_HOME="$SANDBOX/xdg/state"
export XDG_CONFIG_HOME="$SANDBOX/xdg/config"
export XDG_DATA_HOME="$SANDBOX/xdg/data"

# Point the sandbox's coder at the stub (frontend/e2e/stub-coder.sh explains
# why). Written every boot rather than once: the config is the only thing
# standing between a test and a real `claude` invocation with a real bill.
mkdir -p "$XDG_CONFIG_HOME/rook"
printf 'coder = %s/frontend/e2e/stub-coder.sh\n' "$PWD" > "$XDG_CONFIG_HOME/rook/config"
export WAILS_SERVER_PORT="$PORT"
exec "$SANDBOX/rook"

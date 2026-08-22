# rook web client

SvelteKit + Tailwind + xterm.js, served by `rook-web` (a dumb
websocket↔unix-socket pipe). The browser speaks the real mux protocol.

    cd web && npm install && npm run build   # -> web/build
    go run ./cmd/rook-web                    # prints a tokened URL

For the phone: `go run ./cmd/rook-web -addr 0.0.0.0:7673`, open the
printed URL (LAN IP) on the phone. Pick a block; "take resize lease"
decides whether your viewport drives the pty geometry or you observe
cropped. Desktop TUI and web clients mirror the same blocks live.

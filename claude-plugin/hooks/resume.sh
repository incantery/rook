#!/bin/sh
# SessionStart: tell rook how to bring this session back after its
# server restarts. `rook resume` is written to be a hook — outside a
# rook pane, or with no server answering, it exits 0 in silence — so
# this costs nothing in a plain terminal. The session id comes off the
# hook's stdin; no jq, since a hook that needs a tool the machine may
# not have is a hook that fails quietly on the day it matters.
[ -n "${ROOK_MUX_PANE:-}" ] || exit 0
command -v rook >/dev/null 2>&1 || exit 0
id=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$id" ] || exit 0
rook resume . "claude --resume $id" 2>/dev/null
exit 0

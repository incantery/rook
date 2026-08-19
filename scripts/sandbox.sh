#!/bin/sh
# An isolated rook for testing and screenshots: its own tmux server
# (ROOK_SOCKET), state, config and data (XDG dirs) — the live rook is
# never touched.
#
#   scripts/sandbox.sh          build, then launch in a new Ghostty window
#   scripts/sandbox.sh -env     print export lines for headless use instead
#
# Stdout ends with the socket name; drive and dispose of the sandbox:
#   tmux -L <socket> send-keys / capture-pane -p / list-sessions
#   tmux -L <socket> kill-server
#
# The sandbox launches in its own root, so the session (and the window
# title) is named rook-sandbox_<id> — greppable for screenshot tooling.
set -e
repo=$(cd "$(dirname "$0")/.." && pwd)
root=$(mktemp -d "${TMPDIR:-/tmp}/rook-sandbox.XXXXXX")
socket="rook-sbx-${root##*.}"
mkdir -p "$root/state" "$root/config" "$root/data"

if [ "$1" = "-env" ]; then
	echo "export ROOK_SOCKET='$socket'"
	echo "export XDG_STATE_HOME='$root/state' XDG_CONFIG_HOME='$root/config' XDG_DATA_HOME='$root/data'"
	exit 0
fi

(cd "$repo" && make -s build)
cat >"$root/launch.sh" <<EOF
#!/bin/sh
unset TMUX TMUX_PANE
export ROOK_SOCKET='$socket'
export XDG_STATE_HOME='$root/state' XDG_CONFIG_HOME='$root/config' XDG_DATA_HOME='$root/data'
cd '$root'
exec '$repo/rook'
EOF
chmod +x "$root/launch.sh"
open -na Ghostty --args -e "$root/launch.sh"
echo "$socket"

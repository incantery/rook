# launchd

Copies of the LaunchAgents that keep the mux server and web bridge
alive across crashes and reboots (paths are user-specific — adjust
$HOME references when installing elsewhere):

    cp *.plist ~/Library/LaunchAgents/
    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.incantery.rook-mux.plist
    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.incantery.rook-web.plist

rook-web persists its token at ~/.local/state/rook/web-token; logs in
~/.local/state/rook/logs/.

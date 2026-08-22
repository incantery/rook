# launchd

One agent keeps rook alive across crashes and reboots: rookd
supervises the mux server (adopting a live one — it never kills your
panes) and runs the web bridge in-process.

    cp com.incantery.rookd.plist ~/Library/LaunchAgents/
    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.incantery.rookd.plist

Adjust $HOME paths when installing elsewhere. The web token persists
at ~/.local/state/rook/web-token; logs in ~/.local/state/rook/logs/.

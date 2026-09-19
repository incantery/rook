#!/bin/sh
# A new rookd on disk is not a new rookd running: launchd started the
# one that is, and it holds the old binary until it is told otherwise.
# The namer lives in rookd, so an install that skips this step looks
# like an install that did nothing.
set -eu

label=com.incantery.rookd
domain="gui/$(id -u)"

if launchctl print "$domain/$label" >/dev/null 2>&1; then
	launchctl kickstart -k "$domain/$label"
	echo "rook: restarted rookd ($label)"
	exit 0
fi

if pgrep -x rookd >/dev/null 2>&1; then
	echo "rook: a rookd is running that launchd does not manage;"
	echo "      it keeps the old binary until you restart it yourself."
	exit 0
fi

echo "rook: rookd is not running — see scripts/launchd/README.md"

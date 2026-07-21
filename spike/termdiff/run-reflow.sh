#!/bin/sh
# The reflow test: feed content with long soft-wrapped lines at its capture
# width, then resize both emulators and diff. xterm.js re-wraps; x/vt does not.
# This measures how far apart they land on resize — the risk the fixed-geometry
# run.sh cannot see.
#
#   sh spike/termdiff/run-reflow.sh
set -eu
cd "$(dirname "$0")/../.."

command -v node >/dev/null || { echo "node not on PATH"; exit 1; }
go build -o /tmp/extract-vt ./spike/extract-vt

raw=spike/corpus/longlines.raw
for target in 100x30 60x30 140x30; do
	node spike/termdiff/extract-xterm.js "$raw" --resize="$target" >/tmp/reflow.xt.json 2>/dev/null
	/tmp/extract-vt "$raw" --resize="$target" >/tmp/reflow.vt.json
	[ -s /tmp/reflow.xt.json ] && [ -s /tmp/reflow.vt.json ] || { echo "empty grid at $target"; exit 1; }
	echo "### captured at 100 cols, resized to $target"
	python3 spike/termdiff/diff.py /tmp/reflow.xt.json /tmp/reflow.vt.json
done

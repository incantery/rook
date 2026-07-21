#!/bin/sh
# The fidelity go/no-go, one command: build both extractors, feed every corpus
# capture through xterm.js and through the candidate Go emulator at matching
# geometry, and diff the grids cell for cell.
#
#   sh spike/termdiff/run.sh
set -eu
cd "$(dirname "$0")/../.."

command -v node >/dev/null || { echo "node not on PATH"; exit 1; }
go build -o /tmp/extract-vt ./spike/extract-vt

for raw in spike/corpus/*.raw; do
	name=$(basename "$raw" .raw)
	node spike/termdiff/extract-xterm.js "$raw" >"/tmp/$name.xterm.json"
	/tmp/extract-vt "$raw" >"/tmp/$name.vt.json"
	# a truncated extract silently reads as "0 diffs" — refuse to diff one
	[ -s "/tmp/$name.xterm.json" ] || { echo "$name: empty xterm grid"; exit 1; }
	[ -s "/tmp/$name.vt.json" ] || { echo "$name: empty vt grid"; exit 1; }
	python3 spike/termdiff/diff.py "/tmp/$name.xterm.json" "/tmp/$name.vt.json"
done

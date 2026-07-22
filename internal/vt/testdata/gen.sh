#!/bin/sh
# Regenerate the golden reference grids from the corpus.
#
# The oracle is headless xterm.js 6.0.0 — the same emulator version the app
# ships — so whatever it renders is, by definition, what rook shows today.
# TestFidelity diffs our Go emulator against these grids. Run this whenever the
# corpus grows or the shipped xterm version changes:
#
#	cd internal/vt/testdata/oracle && pnpm install --frozen-lockfile && cd -
#	sh internal/vt/testdata/gen.sh
#
# then commit the updated testdata/golden/*.json.
set -eu
cd "$(dirname "$0")"

command -v node >/dev/null || { echo "node not on PATH"; exit 1; }
[ -d oracle/node_modules/@xterm/headless ] || {
	echo "oracle deps missing — run: (cd oracle && pnpm install)"; exit 1
}

mkdir -p golden
for raw in corpus/*.raw; do
	name=$(basename "$raw" .raw)
	node oracle/extract-xterm.js "$raw" >"golden/$name.json"
	# a truncated extract silently reads as "0 diffs" downstream — refuse it
	[ -s "golden/$name.json" ] || { echo "$name: empty grid"; exit 1; }
	echo "  $name  $(wc -c <"golden/$name.json" | tr -d ' ') bytes"
done

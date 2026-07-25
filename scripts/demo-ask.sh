#!/bin/sh
# Drive rook's ask form by hand — a demo you can watch, and the fastest way
# to see a form change without writing an e2e for it. Run it INSIDE a rook
# terminal: each ask blocks this shell while the form opens in a split to
# the right, and prints the answer JSON when you decide.
#
#   scripts/demo-ask.sh                  every payload in scripts/demos/ask
#   scripts/demo-ask.sh a.json b.json    just these, in this order
#   ROOKCTL=$(command -v rookctl) scripts/demo-ask.sh
#                                        use an installed rookctl instead of
#                                        building the working tree's
#
# By default it builds rookctl from the working tree, because the installed
# one usually trails the form you are demoing. If an ask 404s, the rook you
# are sitting in is riding a stale daemon — quit the app, then:
#   pkill -f rook-host   # the sandbox daemon respawns on relaunch
set -u

[ -n "${ROOK_SESSION:-}" ] || {
    echo "run this inside a rook terminal — this shell has no \$ROOK_SESSION" >&2
    exit 1
}

ROOT=$(cd "$(dirname "$0")/.." && pwd)

if [ -z "${ROOKCTL:-}" ]; then
    ROOKCTL="$ROOT/bin/rookctl-demo"
    echo "building rookctl from the working tree…"
    (cd "$ROOT" && go build -o "$ROOKCTL" ./cmd/rookctl) || exit 1
fi

# a payload's title is its filename, minus the ordering prefix and extension
title() {
    base=${1##*/}
    base=${base%.json}
    printf '%s' "${base#[0-9][0-9]-}" | tr '-' ' '
}

run() {
    [ -f "$1" ] || {
        echo "no such payload: $1" >&2
        return 1
    }
    echo
    echo "── $(title "$1") ─ j/k move · 1-9 pick · space toggles · Enter sends · Esc dismisses"
    if out=$("$ROOKCTL" ask <"$1"); then
        echo "answered → $out"
    else
        echo "dismissed → $out"
    fi
}

if [ "$#" -gt 0 ]; then
    for f in "$@"; do run "$f" || exit 1; done
else
    for f in "$ROOT"/scripts/demos/ask/*.json; do run "$f" || exit 1; done
fi

echo
echo "done — try Esc on one, and try reloading the app (⌘R) mid-ask:"
echo "the form should come back and still answer cleanly."

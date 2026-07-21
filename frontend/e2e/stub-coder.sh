#!/bin/sh
# A stand-in for the coder CLI, for e2e. rook types `<coder> '<task>'` into a
# fresh window and expects the thing it started to claim that window; the
# claim is what later tells rook where to deliver a thread nudge. Driving the
# real claude here would mean a network round trip, a bill, and an answer that
# differs every run — none of which the seam under test needs.
#
# What this DOES need to be faithful about is the claim lifecycle, because
# that is the part rook reasons about:
#
#   claim on start   — what claude's SessionStart hook does (rookctl claim)
#   unclaim on exit  — what its SessionEnd hook does
#
# Set ROOK_STUB_NO_UNCLAIM=1 to skip the second one. That is not a contrived
# mode: it is what a ^C, a crash, or a kill -9 leaves behind — claude gone,
# the shell alive, and rook still believing that window holds a live agent.
set -eu

# rookctl is built into the sandbox beside the other binaries; find it from
# this script's own location so nothing has to be exported to reach it.
ROOKCTL="$(cd "$(dirname "$0")/../../bin/e2e" 2>/dev/null && pwd)/rookctl"

# The transcript id claude would have generated. Unique per process so two
# stubs in one workspace are distinguishable, exactly as two claudes would be.
SESSION_ID="stub-$$"
hook() { echo "{\"session_id\":\"$SESSION_ID\"}" | "$ROOKCTL" "$1" 2>/dev/null || true; }

if [ "${ROOK_STUB_NO_UNCLAIM:-0}" != "1" ]; then
    trap 'hook unclaim' EXIT INT TERM
fi

hook claim
# Printed AFTER the claim lands, so a test that waits for this line knows the
# window is claimed rather than merely occupied.
echo "STUB CODER READY${1:+ — task: $1}"

# Sit in the foreground reading input, like a REPL. A nudge typed into this
# pty arrives here as a line, and echoing it is what lets a test assert the
# prompt was delivered to the AGENT rather than to whatever else was running.
while IFS= read -r line; do
    echo "STUB GOT: $line"
done

#!/bin/sh
# Deny the built-in AskUserQuestion inside a rook terminal and steer claude
# to the rook MCP ask tool — asked once, in the RUI split, never in both
# places. Outside rook (no $ROOK_SESSION) the hook allows the call
# untouched, so the plugin costs nothing in a plain terminal.
#
# The deny reason reaches the model; it carries the whole redirection:
# same questions, one inline pointer line, no restated options.
[ -n "${ROOK_SESSION:-}" ] || exit 0
cat >/dev/null # drain tool_input; the model re-sends it to the MCP tool
cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"This session runs inside rook, which renders questions in its own panel. Call mcp__rook__ask with the SAME questions array instead. Before that call, write one short line pointing the user right — e.g. \"Asked in rook →\" — and do NOT restate the question or options in text; the rook panel shows them."}}
EOF
exit 0

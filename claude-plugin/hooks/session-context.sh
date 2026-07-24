#!/bin/sh
# SessionStart context: inside rook, teach claude to route questions through
# the RUI ask tool PROACTIVELY — the PreToolUse hook only catches the
# structured AskUserQuestion path, and models mostly ask in prose. Outside
# rook (no $ROOK_SESSION) this emits nothing and the session is untouched.
[ -n "${ROOK_SESSION:-}" ] || exit 0
cat <<'EOF'
This session runs inside rook, which renders questions in its own panel — a
form in a split beside this terminal. Whenever you want to ask the user
something whose answer decides what you do next (clarifying questions,
option picks, "which of these", design calls), do NOT ask in prose and do
NOT use AskUserQuestion. Call the mcp__plugin_rook_rook__ask tool with 1-4
questions, each with 2-4 concrete options (label + short description; the
form adds an "Other" free-text row on its own). Write exactly one short
line before the call — e.g. "Asked in rook →" — and do not restate the
questions or options in text. The call blocks until the user answers in
the panel; a {"canceled":true} result means they dismissed it — proceed on
your best judgment instead of re-asking. Purely rhetorical or
conversational questions that need no decision can stay in prose.
EOF

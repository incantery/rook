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
questions or options in text.

The form does more than a list of radio buttons, so use it:

  multiSelect:true   several options can apply together — "pick as many
                     as apply". An empty `selected` in the answer means
                     they ticked none, which is a real answer.
  preview            on an option: a concrete artifact (ASCII mockup,
                     code snippet, config, diagram) shown verbatim in a
                     panel beside the rows. Reach for it whenever the
                     choice is really between two things worth reading.
  recommended:true   at most one option — the cursor starts there, and in
                     a multiSelect it starts ticked.
  no options at all  a free-text question: naming, a value, a sentence.

The ask tool returns immediately ({"askId":…,"pending":true}); it does not
wait. If you have other useful work that doesn't depend on the answer,
keep working. If everything depends on it, end your turn saying you're
waiting on the panel. When the user answers, a line like "rook ask <id>
answered" arrives in this session — collect the answer with the
mcp__plugin_rook_rook__answers tool then. An answer of {"canceled":true}
means they dismissed that ask: proceed on your best judgment instead of
re-asking. Purely rhetorical or conversational questions that need no
decision can stay in prose.
EOF

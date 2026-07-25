# rook plugin for Claude Code

Inside a rook terminal, claude's questions stop rendering in the TUI and
open as a form in a split beside its pane — rook's RUI. Claude writes one
line ("Asked in rook →") and keeps working: the `ask` tool returns
immediately, the human decides with j/k · 1-9 · Enter (Esc dismisses)
whenever they're ready, and rook rings a doorbell line into claude's
session — claude collects the answer with the `answers` tool. No parked
call, no timeout to outwait.

Four parts, all inert outside rook:

- **claim hooks** — `rookctl claim` on SessionStart, `rookctl unclaim` on
  SessionEnd. The claim is what lets rook deliver anything back to this
  window (the answer doorbell, thread nudges); without it every delivery
  stays silent by design. Previously these needed a separate
  `rookctl install-hooks` — the plugin now carries them.

- **`mcpServers.rook`** — `rookctl mcp`, a stdio server exposing `ask`
  (post questions, return `{askId, pending}`) and `answers` (drain decided
  asks). Needs `rookctl` on PATH and `$ROOK_SESSION` in the environment,
  which every rook pty exports. The doorbell only types into a window
  holding a LIVE claude claim — at a bare shell the answer waits in the
  drain and the line is delivered to the next claude that claims the
  window, so an answer given between agents is never stranded.
- **`hooks/session-context.sh`** — a SessionStart hook that teaches claude
  to route questions through the ask tool proactively. Without it, models
  mostly ask in prose and nothing else ever fires.
- **`hooks/ask-redirect.sh`** — a PreToolUse hook that denies the built-in
  AskUserQuestion, catching the structured path the same way.

Install (this directory is both the marketplace and its one plugin —
marketplace.json points at "./"):

    claude plugin marketplace add /path/to/rook/claude-plugin
    claude plugin install rook@incantery

After changing the plugin source, re-sync the installed copy:

    claude plugin marketplace update incantery

A dismissed ask answers `{"canceled":true}` and claude proceeds on its
own judgment. There is no timeout to configure: the ask call never waits.

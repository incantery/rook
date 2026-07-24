# rook plugin for Claude Code

Inside a rook terminal, claude's questions stop rendering in the TUI and
open as a form in a split beside its pane — rook's RUI. Claude writes one
line ("Asked in rook →"), the blocked `mcp__plugin_rook_rook__ask` call waits for the
answer, and the human decides with j/k · 1-9 · Enter (Esc dismisses).

Three parts, all inert outside rook:

- **`mcpServers.rook`** — `rookctl mcp`, a stdio server exposing the `ask`
  tool (`rookctl ask` behind a tools/call). Needs `rookctl` on PATH and
  `$ROOK_SESSION` in the environment, which every rook pty exports.
- **`hooks/session-context.sh`** — a SessionStart hook that teaches claude
  to route questions through the ask tool proactively. Without it, models
  mostly ask in prose and nothing else ever fires.
- **`hooks/ask-redirect.sh`** — a PreToolUse hook that denies the built-in
  AskUserQuestion, catching the structured path the same way.

Install (this directory is both the marketplace and its one plugin —
marketplace.json points at "./"):

    claude plugin marketplace add /path/to/rook/claude-plugin
    claude plugin install rook@rook

After changing the plugin source, re-sync the installed copy:

    claude plugin marketplace update rook

The MCP server config sets a 30-minute tool timeout. If your answers take
longer, raise `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT` too — a dismissed or
timed-out ask returns `{"canceled":true}` and claude proceeds on its own
judgment.

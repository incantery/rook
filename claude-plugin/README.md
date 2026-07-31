# rook — a Claude Code plugin

Registers rook's MCP server, which carries two tools:

- **`ask`** — pose questions to the human. They are delivered to their
  **phone**, through the relay configured in `~/.config/rook/config.toml`.
  Returns immediately with an ask id.
- **`answers`** — collect what came back. Read-once.

## What this plugin used to do, and why it stopped

It used to hijack asking entirely: a `PreToolUse` hook denied Claude Code's
built-in `AskUserQuestion` and steered every question into rook, where a
form opened in a split beside the terminal; a `SessionStart` hook taught
the model to prefer it in prose too; and `SessionStart`/`SessionEnd` hooks
ran `rookctl claim`/`unclaim` so rook could pair a transcript to a window
and type "rook ask <id> answered" into it when you decided.

All of that is gone. The form, the transcript sensor, and the claim
machinery left in the strip (see `docs/plugins/VOCABULARY.md`), so:

- **`AskUserQuestion` is the right tool when you are at the desk.** The
  hook that denied it would now be steering to a worse path, so it is
  removed rather than left to misfire.
- **`ask` is for when you are not.** With no relay configured it fails
  fast with 503 instead of parking forever.
- **Nothing announces an answer.** The doorbell that typed into your
  window needed the claim machinery. Callers poll `answers`.

The hooks file is deliberately empty rather than deleted — it is where
hooks go when there are hooks worth having again.

# rook plugin for Claude Code

One hook. On `SessionStart`, inside a rook pane, it hands rook the
command that brings this session back — `claude --resume <id>` — so
that after `rook kill && rook`, a crash, or a reboot, the pane comes
back running the same conversation (`README.md`, "Coming back"). Rook
keeps the command only while Claude is the program in front; when
Claude has quit, the pane is a shell and comes back as one.

Outside rook (`$ROOK_MUX_PANE` unset), or with no server answering,
the hook exits 0 and says nothing.

The skill that teaches Claude to drive rook from inside a pane is not
here: `rook skill --install` writes it to `~/.claude/skills/rook/`,
and `rook --skill` prints it. One source, in the binary.

Install once, from this repo:

    /plugin marketplace add /path/to/rook/claude-plugin
    /plugin install rook@incantery

The marketplace is a directory, so an update is a `/plugin` refresh
after a pull.

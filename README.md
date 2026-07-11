# rook

An AI-native terminal for the agent age — a Wails desktop app that replaces a
ghostty+tmux daily driver with something an agent can drive as fluently as you can.

The name works twice: rooks are the clever corvids — tool-users and the classic
witch's familiar, which is exactly the built-in-agent story — and the chess rook
is the castle, the home base you retreat into. Part of the
[incantery](https://github.com/incantery) suite, but deliberately its own thing:
it does not depend on, and is not depended on by, the other tools.

## What it is

A desktop terminal app with a built-in agent as the primary driver. The agent
can and will often take care of the work; the user can do everything the agent
can via clicks and shortcuts, and vice versa. Neither is a second-class citizen —
which is a structural property (see the command registry below), not a feature.

## MVP: replace the daily driver, fast

The MVP is **not** the agent. The MVP is: how fast can this replace
ghostty+tmux as the daily driver? The agent gets built afterwards, from inside
a tool that's already trusted. Parity first, magic second.

The parity bar is muscle memory, not a feature matrix: the real spec is the
contents of the existing ghostty config and tmux config — the splits, tab/window
switching, copy mode, search, scrollback, mouse reporting, clipboard (OSC 52),
true color, and fonts actually used daily. Probably 15–20 items. Anything not
in those configs doesn't exist for MVP.

**First step: audit both configs and turn them into the backlog.**

## Architecture decisions

1. **Don't write a terminal emulator.** xterm.js (WebGL addon) in the Wails
   frontend, `creack/pty` in the Go backend — the VS Code terminal
   architecture. Honest tradeoff: input latency will match VS Code, not
   ghostty. The bet is that the AI-native experience outweighs it.

2. **Separate PTY host process from day one.** A small Go process that owns
   the PTYs and speaks to the UI over a unix socket. This is the tmux server:
   the UI can crash, rebuild, and reattach without killing shells. Not
   optional-later polish — we'll be developing the app *while living in it*,
   so every rebuild would otherwise nuke every shell. A few hundred lines of
   Go, worth it immediately.

3. **A single command registry.** Every action — split pane, run command,
   switch tab, kill session — is a named command. Clicks dispatch commands,
   keybindings dispatch commands, and later the agent's tool surface *is* the
   command registry. This is the load-bearing decision that keeps "the agent
   can do everything the user can" true, and it gives us a command palette
   for free. Built from day one even though the agent isn't.

4. **Shell integration (OSC 133) from the start.** Semantic prompt marks give
   command boundaries, cwd, and exit codes as structure. The UI gets
   Warp-style block navigation; the agent (later) reads blocks, not raw
   scrollback.

5. **Wails v3** (alpha) for real multi-window support, falling back to v2
   only if it proves unstable during the spike.

6. **Agent engine (post-MVP): shell out to the `claude` CLI** in stream-json
   mode rather than building an agent loop. Interactive, human-initiated use
   fits subscription billing; the engine can swap to Agent SDK + API later
   without the app changing.

## Week one is a kill test, not a milestone

Wails v3 + xterm.js + creack/pty, one pane, then spend a real hour working in
it. Two things can't be fixed later and must be validated first:

- **Keyboard fidelity in WKWebView** — every ctrl-sequence, cmd-key, and
  key-repeat behavior used in vim/shell. Escape hatch if xterm.js input
  handling has gaps: intercept keydown directly and write to the PTY.
- **Latency feel**, coming from ghostty specifically — the best-latency
  terminal in the business. If it's intolerable, better to know on day three.

## Sequence to daily-driver

1. Spike / kill test (above).
2. Panes + tabs + personal keybindings, dispatched through the command
   registry.
3. PTY host split-out: UI restart ≠ shell death.
4. The long tail from the config audit: copy mode, search, clipboard,
   scrollback, theme.
5. Switch. Keep ghostty installed as the escape hatch; every "tmux did this
   better" moment becomes the backlog.

Estimate: a few focused weeks to "usable daily," with the long tail continuing
while living in it. Agent work starts after the switch.

## Open questions

- **Remote sessions**: is ssh + attach part of the daily flow? Local-only
  keeps the PTY host trivial; remote attach is a much bigger design surface.
  Current lean: punt — keep tmux for remote until rook earns it locally.
- **Relationship to the incantery fabric tool**: rook's PTY host overlaps
  conceptually with the planned workspace/session fabric. Deliberately
  ignored for MVP; revisit only if a real seam appears.

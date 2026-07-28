# rook

An AI-native IDE for the agent age — a native macOS app that replaces a
ghostty+tmux daily driver with something an agent can drive as fluently as you can.

> **Current state: [STATUS.md](STATUS.md).** rook was a Wails app (Go +
> Svelte + xterm.js in a WKWebView) until 2026-07-28; it is now a Zig
> app rendering through its own Metal pipeline. The architecture
> decisions below were written for that earlier design and are kept as
> the reasoning that led here — read them as history, not as a
> description of what ships today.

The name works twice: rooks are the clever corvids — tool-users and the classic
witch's familiar, which is exactly the built-in-agent story — and the chess rook
is the castle, the home base you retreat into. Part of the
[incantery](https://github.com/incantery) suite, but deliberately its own thing:
nothing depends on rook, and rook's only planned sibling dependency is
[sigil](https://github.com/incantery/sigil) as the frontend language (below).

## Demo

https://github.com/user-attachments/assets/1ebda3b9-14ca-4193-8629-ecb1871025bc

## Install

macOS (Apple Silicon):

```sh
curl -fsSL https://raw.githubusercontent.com/incantery/rook/main/install.sh | sh
```

Installs `/Applications/rook.app` and the `rookctl` CLI from the latest
[release](https://github.com/incantery/rook/releases). Upgrades are
self-managed after that: `rookctl update` (and `rookctl update --check` to
just look). Use the script or `rookctl`, not a browser download — curl skips
the quarantine attribute, so the ad-hoc-signed app launches without
Gatekeeper ceremony.

From source: `make install` (needs Go and Zig 0.16 — no longer node or
the wails3 CLI).
Maintainers cut releases with `make release VERSION=vX.Y.Z`.

## Configure

Config lives at `~/.config/rook/config` — ghostty-style `key = value` lines.
The file is optional; missing means defaults. [`docs/config.sample`](docs/config.sample)
is the complete surface: every key, each set to its default and commented out,
so you can copy it in verbatim and uncomment what you want to change. Secrets
(the OpenAI key, the Jira token) live in the keychain, not the file.

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

1. **xterm.js is the terminal engine, behind a hard seam.** xterm.js in the
   Wails frontend, `creack/pty` in the Go backend — the VS Code terminal
   architecture. The terminal runtime is an imperative island behind a small
   mount interface (decision 7); if a host-side VT + custom renderer ever
   earns its way in, it swaps behind that seam without touching the chrome.
   Honest tradeoff: input latency will match VS Code, not ghostty. The bet
   is that the AI-native experience outweighs it.

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

7. **Frontend: a single-entry Svelte app that hosts terminals — and doesn't
   render them.** (Revised 2026-07-12; the previous endgame here was sigil +
   host-side VT + zero npm.) The chrome — manager, dashboards, inbox,
   overlays, palette — becomes Svelte 5, adopted incrementally: new surfaces
   are built in it, existing ones port when a feature touches them,
   `hostapi.ts` stays the data layer throughout. The terminal is a black box
   the chrome places but never drives: a framework-free runtime owns xterm
   lifecycle, the WebSocket data plane, and the write path; Svelte mounts it
   into keyed slots that never unmount while their session lives — host-owned
   sessions outlive the UI, so visibility is CSS, never conditional render.
   Reactivity never sits between pty bytes and `xterm.write()`. Dependency
   posture: a handful of known, sane deps for specific jobs (xterm, svelte,
   maybe monaco someday) — no sprawl, but no zero-npm dogma either.
   [sigil](https://github.com/incantery/sigil) is not a rook dependency: an
   open-source app asking contributors to learn a bespoke frontend language
   would tax every UI PR. If sigil proves itself in its own repo, the
   terminal runtime's mount seam is where a sigil/host-VT renderer could
   arrive — rook doesn't wait for it and may never use it.
   Styling: Tailwind v4 (theme + utilities, no preflight) for layout,
   spacing, color, and typography; Svelte scoped styles for the genuinely
   component-local bits. The hand-tuned CSS in app.css stays authoritative
   until a surface is touched — convert opportunistically, never as a
   sweep.

8. **Extensibility: out-of-process, API-first — no plugin side doors.**
   (Starting posture, 2026-07-12 — expect refinement.) A rook plugin is a
   process speaking the authenticated host API and dispatching registry
   commands, exactly like rook-agent, agentmon, and rookctl already do —
   the Neovim/tmux model, not Hyper's inject-components-into-the-tree
   model, which fossilized its internals. Decision 3's "no agent-only side
   doors" generalizes: no plugin-only side doors either. If UI extension
   is ever demanded, plugins contribute **data contracts** (a dashboard
   tile shape, host-mediated) or at most a sandboxed webview with message
   passing — never components in rook's tree. Before anything third-party
   ships, the token model grows per-plugin scopes (read-status and
   send-input are very different powers).

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

- **Sigil grid throughput**: can sigil's fine-grained DOM updates survive
  flood output (`yes`, full-screen vim redraws) at key-echo latency? Lives
  entirely in the *sigil* repo — grow echoterm against a flood host, no
  Wails required. Since decision 7's revision this gates nothing in rook;
  if it ever passes convincingly, the terminal runtime's mount seam is the
  door it knocks on.
- **Remote sessions**: is ssh + attach part of the daily flow? Local-only
  keeps the PTY host trivial; remote attach is a much bigger design surface.
  Current lean: punt — keep tmux for remote until rook earns it locally.
- **Relationship to the incantery fabric tool**: rook's PTY host overlaps
  conceptually with the planned workspace/session fabric. Deliberately
  ignored for MVP; revisit only if a real seam appears.

## License

[MIT](LICENSE)

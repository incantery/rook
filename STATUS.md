# rook — status

Where the project actually is, as of **2026-07-28**, shipping **v0.38.2**.

This is the orientation page: what rook is now, what works, what does
not, and where the detail lives. It is deliberately blunt about the
gaps — the checklists it points at are longer than the list of things
that are done.

## What rook is now

A **native macOS terminal and agent workspace**, written in Zig,
rendering through its own Metal pipeline, with terminal emulation from
[ghostty-vt](https://github.com/ghostty-org/ghostty).

Until 2026-07-28 it was a Wails desktop app: a Go backend, a Svelte
frontend, xterm.js in a WKWebView. That version is gone —
`/Applications/rook.app` is the Zig app, and it replaced the old one
outright rather than shipping beside it. The reasoning, the migration,
and the things that broke on the way are in
[`app/PARITY.md`](app/PARITY.md).

The one-line case for the rewrite: the webview compositor was the floor
under input latency, and no amount of work above it moved that floor.
Owning the `CAMetalLayer` removed it. See
[`docs/render-latency.md`](docs/render-latency.md) for the diagnosis
that preceded the decision, and [`app/PERF.md`](app/PERF.md) for
what it bought.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/incantery/rook/main/install.sh | sh
```

Self-managing after that: `rook update` (or `rookctl update`;
`--check` just looks). Use the script or the updater rather than a
browser download — curl skips the quarantine attribute that would
otherwise make Gatekeeper block an ad-hoc-signed app.

From source: `make install`. Needs Go and Zig 0.16. It no longer needs
node or the wails3 CLI.

## Shape

Two processes, on purpose:

| | |
|---|---|
| **rook** | the app. Zig, Metal, owns its own ptys, spawns and SIGTERMs the daemon. Also the CLI: unknown verbs `exec` into the bundled `rookctl`. |
| **rook-host** | the Go daemon. Threads, review, asks, attention, transcripts, worktrees, workflows, cloud relay, LSP. Reached over localhost HTTP + bearer token. |

`internal/host` is the product, not scaffolding — it is what `rookctl`
and the MCP server talk to, and therefore how Claude touches rook.
Rewriting it in Zig buys nothing today; the plan for how the Go recedes
over time is §6 of PARITY.

`rookctl` still installs under its own name because `claude-plugin`
invokes it by name (`rookctl mcp`, `rookctl claim`). It goes when the
plugin moves to `rook`.

## What works

Terminal: splits, tabs, workspace-scoped spaces, scrollback (10MB per
pane) with copy mode and `/` search, selection and mouse reporting,
⌘V paste with xterm's safety rules, IME and dead keys, OSC 52
clipboard, bell and OSC 9/777 notifications, pane zoom, themes,
translucency and blur, live config reload, ligature-free font
fallback with color emoji.

Editor (`re`): a vim-shaped modal editor over a rope buffer, with
undo, search, tree-sitter syntax for Zig and Go, and directory
buffers. It is deliberately ranked last in the roadmap — its job today
is to get out of neovim's way.

Agent surface: `rookctl` and the MCP server work unchanged, because
they always spoke to the daemon rather than to the UI.

Perf, all measured and reproducible with `app/bench.sh`:

| metric | value |
|---|---|
| key → photon p50 | 15.5 ms windowed / **8.5 ms fullscreen** |
| `time cat` 150MB ascii | **0.90–0.92 s** (Ghostty 1.3.1: 1.610 s, same machine and corpus) |
| sustained parse→glass | 190 MB/s at a locked 120fps |
| idle frames | **0** |

## What does not work yet

Ordered by how much of rook's identity each one holds — the full list
with reasoning is [`app/PARITY.md`](app/PARITY.md).

1. **The agent layer**, which is the actual product: asks → attention
   inbox → agent deck. 14 open items, the largest single gap. The
   cutover deleted the visual agent layer and has not rebuilt it; bell
   and notifications are currently the *only* way rook can say an agent
   wants you.
2. **Command registry + ⌘K palette.** The webview app's spine: every
   action a named command, dispatched by keybinds, listed by the
   palette, and exposed as the agent's tool surface. rook has the
   palette *widget* and 13 hardcoded actions.
3. **Side panes, threads, review.** Review pulls in a diff viewer, and
   with Monaco gone it has no fallback.
4. **Terminal floor leftovers**: OSC 8 hyperlinks with ⌘-click to open
   `file:line`, copy-mode vim motions and visual yank, paste
   confirmation, tab/space rename, ligatures, a second window.
5. **Signing and notarization.** Ad-hoc signed today.

## Accepted regressions

Stated out loud because they are choices, not oversights:

- **Shells die with the app.** rook-host owned the ptys before; rook
  owns them in-process. Quitting kills every shell in every space,
  which bites hardest during exactly the rapid iteration this phase is
  made of. The strongest single argument for moving ptys behind the
  host/client split sooner.
- **Nothing happens while rook is closed.** No remote asks reaching
  your phone, no PR watcher, no usage push, no scheduled workflows.
- **No web or remote projection.** A webview could in principle be
  reached from anywhere. A Metal app cannot.

## Where the detail lives

| file | what it holds |
|---|---|
| [`app/README.md`](app/README.md) | how the app works — architecture, every subsystem, the lessons that will recur |
| [`app/PARITY.md`](app/PARITY.md) | the debt checklist and the order to pay it in |
| [`app/PERF.md`](app/PERF.md) | the scoreboard, and the rules for adding to it |
| [`docs/render-latency.md`](docs/render-latency.md) | the latency diagnosis that motivated the rewrite |
| [`docs/agent.md`](docs/agent.md) | the agent/host surface |
| [`NEXT.md`](NEXT.md) | the review-workspace thesis — product direction |
| [`app/NEXT.md`](app/NEXT.md) | Zig architecture notes — hypotheses, explicitly not decisions |
| [`README.md`](README.md) | project intro — **partly pre-cutover, read with that in mind** |

## Repo layout

```
app/            the Zig app: renderer, terminal, editor, chrome  ← the app
cmd/            rook-host, rookctl                               ← the daemon + CLI
internal/       the host: threads, review, asks, transcripts, …  ← the product
claude-plugin/  hooks + MCP wiring for Claude Code
scripts/        rook-migrate.sh and friends
docs/           design notes and diagnoses
frontend/       the retired Svelte/xterm app — `make install-web`
spike/          old experiments
```

It was `native/` until 2026-07-28. The name was a contrast with the
webview, and once the webview was gone it described nothing — everything
is native now. Renaming it was the visible half of promoting the app to
first-class; the half that mattered was CI, which had never built a line
of Zig while gating every PR on the retired frontend.

`frontend/` is kept as the way back, not as a live surface. `make
install-web` still packages it. Nothing in the shipped app depends on
it, and it no longer gates CI — `.github/workflows/web.yml` runs only
when `frontend/` itself changes.

## Building it

| | |
|---|---|
| `make build` | compile the app; what CI runs. Runs nothing — every run target has to sandbox its socket |
| `make dev` | Debug build in an isolated sandbox (own daemon, config, database) |
| `make prod` | the same sandbox at ReleaseFast — the binary `app/bench.sh` measures |
| `make install` | the daily driver into `/Applications` |

Retired-stack targets keep a `-web` suffix: `build-web`, `dev-web`,
`package-web`, `install-web`, `e2e-web`.

There is no `make e2e` any more, and that is a gap rather than a rename.
It was how an agent could *see* rook and verify its own UI work instead
of asking; it drove the webview through Playwright, and the Zig app has
no equivalent. It belongs with the agent layer in the list above.

## Branches

`main` carries everything. The Zig work happened on `rook/zig`, which
is fully merged and identical to `main` — the worktree exists for
convenience, not because anything is outstanding. `rook/rust` and
`rook/swift` are parked at the July 27 evaluation that chose Zig and
are far behind; they are history, not work in progress.

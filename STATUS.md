# rook — status

Where the project actually is, as of **2026-07-31**, shipping **v0.40.0**.

This is the orientation page: what rook is, what works, what does not,
and where the detail lives. It is deliberately blunt about the gaps.

## What rook is

A **native macOS terminal, multiplexer and editor**, written in Zig,
rendering through its own Metal pipeline, with terminal emulation from
[ghostty-vt](https://github.com/ghostty-org/ghostty).

**One binary, 2.7MB.** No daemon, no CLI companion, no web view.

It has been three things. A Wails desktop app (Go + Svelte + xterm.js in
a WKWebView) until 2026-07-28. Then a Zig app with a Go daemon behind it
carrying an agent layer — threads, review, asks, an attention inbox, a
transcript sensor. On 2026-07-31 that daemon and everything in it was
stripped, along with the tree-sitter grammars.

Both cuts were the same call for different reasons. The webview
compositor was the floor under input latency and no work above it moved
that floor ([`docs/render-latency.md`](docs/render-latency.md)). The Go
layer was a set of features that had each grown their own protocol — and
the strip's premise is that they should be **plugins over one vocabulary**
instead ([`docs/plugins/VOCABULARY.md`](docs/plugins/VOCABULARY.md)).

What that cost, and the shape each piece comes back in, is
[`docs/OWED.md`](docs/OWED.md). Read it before assuming something is
missing by accident.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/incantery/rook/main/install.sh | sh
```

Use the script rather than a browser download — curl skips the quarantine
attribute that would otherwise make Gatekeeper block an ad-hoc-signed app.
**Re-run it to upgrade**: in-app self-update left with the Go core and is
owed back in Zig.

From source: `make install`. Needs Zig 0.16, and Go only for the
providers. Full Xcode is optional — it supplies `actool` for the app icon;
without it the build falls back to a flattened icon and says so.

## Shape

One process, and two kinds of thing beside it:

| | |
|---|---|
| **rook** | the app and the CLI. Zig, Metal, owns its ptys in-process; workspaces are `workspace` nodes in the environment graph. `re` is `rook edit`. |
| **providers** | separate processes reaching one external system each, speaking newline-JSON over stdio ([`sdk/provider`](sdk/provider)). Go, and deliberately so. |
| **LSP servers** | separate processes rook spawns from a catalog (`app/src/lspmgr.zig`). |

Everything rook does that touches something outside itself is meant to be
one of the bottom two rows. That is the architectural bet.

## What works

Each line below is covered by a scenario in `make e2e`, which drives the
real app and asserts on both what the emulator holds and what the renderer
actually drew.

**Terminal**: splits, tabs, workspace-scoped spaces, scrollback with copy
mode and `/` search, selection and mouse reporting, ⌘V paste with xterm's
safety rules, IME and dead keys, OSC 52 clipboard, bell and OSC 9/777
notifications, pane zoom, themes, translucency and blur, live config
reload, color emoji and grapheme-correct wide text.

**Editor** (`re`): a vim-shaped modal editor over a rope buffer — regex
`:s`, macros, visual block, `.`, undo, marks, completion. One file open in
two panes is one document. `:w` refuses a file an agent changed underneath
it.

**LSP**: diagnostics in the gutter, `]d` to walk them, go-to-definition,
hover, `gr` for every use of a symbol — which lands in the same side
panel find-in-files uses, grouped by file and walkable with `j`/`k`/⏎ —
and `gR` to rename one everywhere. A rename validates every file before
touching any: open documents get one undoable group and stay unsaved,
files no pane has open are written. `ctrl-n` completion is served by the
buffer's own words on the keystroke and by the server a few frames
later, in one ring with a menu. `:Format`, and `editor-format-on-save`
for `:w` — off by default, and a save is never lost to it: a formatter
that does not answer inside 1.5s gets the file written unformatted and
says so. `ga` lists what the server offers to do about a line — quick
fixes, `source.organizeImports` — in the ⌘K palette, applying the edit
or resolving it first. Go, Python and TypeScript/TSX in the catalog;
adding a language is data, not code.

**Navigation and chrome**: a command registry with a ⌘K palette and `:Ex`
commands from the editor, which-key on an unanswered leader, ⌘P file
finder and ⌘⇧F find-in-files (both honouring nested `.gitignore`s), a file
tree, a per-pane buffer line, a clickable status bar, side panes, and the
environment graph — declarative chrome with `tmux-neovim` and `vscode`
presets.

**Perf**, reproducible with `app/bench.sh`:

| metric | value |
|---|---|
| key → photon p50 | 15.5 ms windowed / **8.5 ms fullscreen** |
| `time cat` 150MB ascii | **0.90–0.92 s** (Ghostty 1.3.1: 1.610 s, same machine and corpus) |
| sustained parse→glass | 190 MB/s at a locked 120fps |
| idle frames | **0** |

## What does not work

1. **Syntax highlighting.** The five tree-sitter grammars were 4.6MB of
   generated parse table in a 7.1MB binary. They are out, and the way back
   is how every other editor already does it — load a grammar rather than
   link it. `docs/OWED.md` §5.
2. **The agent layer.** No asks, no threads, no review. This was the
   product thesis and it is mostly still absent by choice: it comes back
   as plugins over the item model, not as more endpoints. The first piece
   returned 2026-08-03: `plugins/claude`, a first-party plugin that
   watches Claude Code transcripts, lists every session as an item with an
   honest state, and raises attention when a turn finishes. The second,
   same day: `plugins/agent`, an OpenAI-backed worker whose first job is
   compressing finished turns into STE digests (headline + bullets as
   children, the bill as a MONEY field); both stand on the shared scanner
   in `plugins/internal/transcript` — see `man 7 rook-plugin`,
   "THE SHIPPED PLUGINS".
3. **Providers ship but nothing calls them.** `rook-provider-github` and
   `rook-provider-linear` are built, bundled and tested; the thing that
   spawned them was `rookctl issues`, which left with the Go. The caller
   is the first real plugin surface — `docs/OWED.md` §1.
4. **Self-update and the keychain writer** — both `docs/OWED.md`.
   (Worktree creation came back 2026-08-03 as `ctl worktree add|remove`,
   with worktrees derived live from git rather than registered.)
5. **Signing and notarization.** Ad-hoc signed today.

## Accepted regressions

Choices, not oversights:

- **Shells die with the app.** rook owns its ptys in-process. Quitting
  kills every shell in every space. The tmux-style split is still wanted,
  and should be Zig when it is built — `docs/OWED.md`.
- **Nothing happens while rook is closed.** No remote asks, no PR watcher,
  no scheduled anything.
- **No web or remote projection.** A webview could in principle be reached
  from anywhere. A Metal app cannot.

## Where the detail lives

| file | what it holds |
|---|---|
| [`app/README.md`](app/README.md) | how the app works — architecture, subsystems, the lessons that recur |
| [`docs/OWED.md`](docs/OWED.md) | what the strip removed and the shape each piece returns in |
| [`docs/plugins/VOCABULARY.md`](docs/plugins/VOCABULARY.md) | the item model the plugin system is designed against |
| [`app/PERF.md`](app/PERF.md) | the scoreboard, and the rules for adding to it |
| [`docs/render-latency.md`](docs/render-latency.md) | the latency diagnosis that motivated the Zig rewrite |
| [`app/PARITY.md`](app/PARITY.md) | the webview→Zig debt checklist — **historical**, much of it now moot |
| [`NEXT.md`](NEXT.md) | the review-workspace thesis — product direction, not implementation |
| [`app/NEXT.md`](app/NEXT.md) | Zig architecture hypotheses, explicitly not decisions |

## Repo layout

```
app/           the Zig app: renderer, terminal, editor, chrome, e2e   ← rook
sdk/provider/  the provider protocol (its own Go module, zero deps)
sdk/rook/      the environments SDK — chrome and keybinds as a graph
providers/     rook-provider-github, rook-provider-linear
docs/          design notes, diagnoses, and what is owed
scripts/       rook-migrate.sh, build-icon.sh
```

`internal/` and `cmd/` are gone as of 2026-07-31 — that was rook-host,
rookctl, and everything they carried. The way back is git history, which
costs nothing to keep and nothing to carry.

## Building it

| | |
|---|---|
| `make build` | compile the app; what CI runs |
| `make dev` | Debug build in an isolated sandbox (own ctl socket, config, state) |
| `make prod` | the same sandbox at ReleaseFast — the binary `app/bench.sh` measures |
| `make providers` | the Go providers, discovered by their `main.go` |
| `make install` | the daily driver into `/Applications` |
| `make e2e` | the app driven end to end — `dump` plus decoded screenshots |

`make e2e` is how an agent verifies its own work instead of asking. Local
only: it needs a window server, a Metal device, and real shells. It flakes
about one scenario per full run under load; every one passes in isolation.

## Branches

`main` carries everything. `rook/rust` and `rook/swift` are parked at the
July 27 evaluation that chose Zig — history, not work in progress.

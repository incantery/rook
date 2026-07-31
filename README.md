# rook

A native macOS terminal, multiplexer and editor in Zig — built to replace
a ghostty+tmux daily driver, and to be driven by an agent as fluently as
by a human.

> **Current state: [STATUS.md](STATUS.md).** That page is the honest one:
> what works, what does not, and what is owed. This page is the intro and
> the reasoning.

The name works twice: rooks are the clever corvids — tool-users and the
classic witch's familiar — and the chess rook is the castle, the home base
you retreat into. Part of the [incantery](https://github.com/incantery)
suite, but deliberately its own thing: nothing depends on rook.

## Demo

https://github.com/user-attachments/assets/1ebda3b9-14ca-4193-8629-ecb1871025bc

## Install

macOS (Apple Silicon):

```sh
curl -fsSL https://raw.githubusercontent.com/incantery/rook/main/install.sh | sh
```

Installs `/Applications/rook.app` from the latest
[release](https://github.com/incantery/rook/releases). Use the script
rather than a browser download — curl skips the quarantine attribute, so
the ad-hoc-signed app launches without Gatekeeper ceremony. Re-run it to
upgrade.

From source: `make install`. Needs Zig 0.16, plus Go if you want the
providers. Maintainers cut releases with `make release VERSION=vX.Y.Z`.

## Configure

Config lives at `~/.config/rook/config.toml`.
[`docs/config.sample.toml`](docs/config.sample.toml) is the complete
surface: every key at its default, commented out, so you can copy it in
verbatim and uncomment what you want. The file is optional.

Chrome — bars, segments, keybinds — can also be declared as a graph and
built with an SDK rather than written by hand; see
[`docs/environments/`](docs/environments/) and
[`sdk/rook`](sdk/rook).

## What it is

A terminal you would use for the latency alone, with an editor and LSP in
the same binary, designed so that anything an agent might want to do is a
named command rather than a private code path.

**It is not an AI IDE today.** It was heading that way, grew an agent
layer — threads, code review, an attention inbox, asks that followed you
to your phone — and then removed all of it on 2026-07-31. Not because the
thesis was wrong, but because each feature had grown its own protocol, and
none of them could have been written by anyone outside the repo. They come
back as plugins over one vocabulary, or they do not come back.

- What was removed and what shape it returns in: [`docs/OWED.md`](docs/OWED.md)
- The vocabulary being designed against: [`docs/plugins/VOCABULARY.md`](docs/plugins/VOCABULARY.md)

## Architecture

Two decisions from the original design survived three rewrites. They are
here because they are still load-bearing.

1. **A single command registry.** Every action — split a pane, open a
   file, toggle the tree — is a named command. Clicks dispatch commands,
   keybindings dispatch commands, the ⌘K palette lists them, the editor's
   `:Ex` verbs reach them, and the ctl socket runs them by name. This is
   what keeps "an agent can do everything the user can" structurally true
   rather than aspirational, and it is why the e2e suite can drive the
   real app.

2. **Extensibility is out-of-process and API-first — no side doors.** A
   provider is a separate process reaching one external system, speaking
   newline-delimited JSON over stdio and declaring its capabilities up
   front ([`sdk/provider`](sdk/provider)). Language servers work the same
   way. The Neovim/tmux model, not Hyper's inject-components-into-the-tree
   model, which fossilized its internals.

   The open edge: parsing runs on the frame budget and cannot be
   out-of-process, so grammars want a *native* plugin class rook does not
   have yet. That is the next real design problem.

Everything else — xterm.js behind a seam, a Go PTY host, Wails, Svelte,
shelling out to the `claude` CLI — was true once and is not now. The
reasoning is worth reading as history rather than as description:

- [`docs/render-latency.md`](docs/render-latency.md) — why the webview had
  to go, measured before it was decided
- [`app/PARITY.md`](app/PARITY.md) — the webview→Zig debt list
- [`docs/vt-spike.md`](docs/vt-spike.md) — whether to build a VT or use
  one, and how that was tested

## Performance

The bar is "nothing about rook feels like web tech" — the audience is
Ghostty/Alacritty/Kitty switchers. Numbers, and how to reproduce each one,
live in [`app/PERF.md`](app/PERF.md); `app/bench.sh` runs them.

| metric | value |
|---|---|
| key → photon p50 | 15.5 ms windowed / 8.5 ms fullscreen |
| `time cat` 150MB ascii | 0.90–0.92 s (Ghostty 1.3.1: 1.610 s, same machine) |
| idle frames | 0 |

## License

[MIT](LICENSE)

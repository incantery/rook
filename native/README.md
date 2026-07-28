# rookz — native rook in Zig on libghostty-vt

Numbers live in [PERF.md](PERF.md); `./bench.sh` reproduces them.

Experimental (branch `rook/zig`). Standalone Zig desktop terminal:
pty → ghostty-vt → RenderState → instanced Metal grid in an owned
CAMetalLayer. No webview, no Swift.

The window is a SCENE: a binary split tree of panes, each its own
pty + emulator, all drawn by one pipeline (grids are uniforms + a
buffer offset; chrome is more quads). Chords match the wails app:
**⌘D** split right, **⌘⇧D** split down, **⌃HJKL** focus nav — which
yields to alternate-screen apps (vim keeps its own splits) by reading
alt-screen truth straight from the emulator, no heuristic. The cursor
and the accent-colored separator edges mark the focused pane. A pane
closes when its shell exits; the last one exiting quits the app.

```
zig build                    # needs zig 0.16
./zig-out/bin/rookz win      # the app (make dev from repo root does both)
./zig-out/bin/rookz demo     # headless: bytes → vt → screen dump
./zig-out/bin/rookz exec ls  # run a command under a pty, dump final screen
```

Flags: `win --no-activate` opens the window without stealing focus —
use this for every tooling/probe launch.

## Dev control socket (the playwright substitute)

Debug builds listen on `/tmp/rookz.sock` (`ROOKZ_SOCK` overrides).
Line protocol, drivable with plain `nc -U`:

```
printf 'dump\n'              | nc -U /tmp/rookz.sock   # screen text (vt truth)
printf 'type ls -la\n'       | nc -U /tmp/rookz.sock   # keystrokes → pty
printf 'enter\n'             | nc -U /tmp/rookz.sock
printf 'ctrlc\n'             | nc -U /tmp/rookz.sock
printf 'key 1b5b41\n'        | nc -U /tmp/rookz.sock   # raw hex bytes → pty
printf 'panes\n'             | nc -U /tmp/rookz.sock   # list panes, * = focused
printf 'split right\n'       | nc -U /tmp/rookz.sock   # split focused (or: down)
printf 'focus left\n'        | nc -U /tmp/rookz.sock   # move focus (or an id)
printf 'dump@2\n'            | nc -U /tmp/rookz.sock   # any pane-taking verb
printf 'type@2 ls\n'         | nc -U /tmp/rookz.sock   #   targets by @id
printf 'shot /tmp/s.png\n'   | nc -U /tmp/rookz.sock   # pixel truth
printf 'winsize 900 600\n'   | nc -U /tmp/rookz.sock   # resize (points)
printf 'stats\n'             | nc -U /tmp/rookz.sock   # live perf numbers
printf 'stats reset\n'       | nc -U /tmp/rookz.sock
printf 'quit\n'              | nc -U /tmp/rookz.sock
```

dump/type/enter/ctrlc/key default to the focused pane; `@<id>` targets
another. Add `-w 2` to nc in scripts — and when grepping a dump for
shell output, remember lines WRAP at the pane width (a 15-second
"stall" was once just `total` split into `t`/`otal`).

`shot` reads back our own CAMetalLayer drawable — no screen-recording
permission, works occluded or on another Space. `dump` and `shot` are
different truths: dump is what the emulator holds, shot is what the
renderer did with it. The atlas-flip bug (day two) was invisible to dump
and obvious in shot; keep both in every verification.

## Config

`~/.config/rookz/config.toml` (respects `XDG_CONFIG_HOME`). A TOML
subset: flat `key = value`, `#` comments, quoted strings; `[sections]`
skipped. Dashes and underscores in keys are interchangeable. Missing
file = defaults. Unknown keys warn on stderr.

```toml
font-size = 13
font-family = "FiraCode Nerd Font Mono"
```

## Layout

- `src/main.zig` — subcommand dispatch
- `src/pty.zig` — openpty/fork/exec, libc direct (0.16 std.posix lost these)
- `src/session.zig` — pty + vt.Terminal + reader thread, os_unfair_lock
- `src/panes.zig` — split tree: layout, geometric nav, separators
- `src/macos.zig` — AppKit window, CAMetalLayer, CVDisplayLink loop, keys,
  the scene (draw_lock serializes; lock order draw_lock → session mutex)
- `src/render.zig` — CoreText ASCII atlas + two instanced Metal passes
- `src/ctl.zig` — the dev socket
- `src/png.zig` — BGRA → PNG via ImageIO

Ghostty is pinned in build.zig.zon at the same commit as the oracle clone
(`~/go/src/github.com/ghostty-org/ghostty`); the `ghostty-vt` Zig module is
the terminal core, `zig_objc` is ghostty's own pin.

## Known debts

No scrollback view, no selection, cursor is a color swap, input is
cooked NSEvent characters (upgrade path: `vt.input.encodeKey`), no
window-close → quit delegate, grapheme-cluster emoji (flags, ZWJ,
skin tones) render blank — only a cell's first codepoint rasterizes;
the cluster sits in RenderState Cell.grapheme awaiting CTLine-style
shaping — atlas-full policy is clear-and-rebuild,
glyphs render single-style (no bold/italic faces yet — the style flags
are in `vt.Style.flags` when we want them), box-drawing sprite set
covers light/heavy/rounded lines + blocks but not doubles/diagonals
(font fallback), clipboard effects (OSC 52) unwired.

Pane debts: split ratio is fixed at 0.5 (no drag/resize), no ⌘W
close-pane chord (exit the shell), no zoom, typing into a pane while
its resize is still settling can lose a line to reflow (transient,
ctl-only in practice).

Three lessons that will recur: box/block glyphs are SPRITES, never font
glyphs (edge-to-edge or you get seams); the session must answer
terminal queries (Effects callbacks) or query-and-wait programs like
nvim stall on their response timeouts; and never encode a frame
synchronously from a caller's thread — nextDrawable contention wedged
the ctl thread once, so mutations set scene_dirty and let the display
link draw.

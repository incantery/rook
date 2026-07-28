# rookz — native rook in Zig on libghostty-vt

Experimental (branch `rook/zig`). Standalone Zig desktop terminal:
pty → ghostty-vt → RenderState → instanced Metal grid in an owned
CAMetalLayer. No webview, no Swift.

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
printf 'shot /tmp/s.png\n'   | nc -U /tmp/rookz.sock   # pixel truth
printf 'quit\n'              | nc -U /tmp/rookz.sock
```

`shot` reads back our own CAMetalLayer drawable — no screen-recording
permission, works occluded or on another Space. `dump` and `shot` are
different truths: dump is what the emulator holds, shot is what the
renderer did with it. The atlas-flip bug (day two) was invisible to dump
and obvious in shot; keep both in every verification.

## Layout

- `src/main.zig` — subcommand dispatch
- `src/pty.zig` — openpty/fork/exec, libc direct (0.16 std.posix lost these)
- `src/session.zig` — pty + vt.Terminal + reader thread, os_unfair_lock
- `src/macos.zig` — AppKit window, CAMetalLayer, CVDisplayLink loop, keys
- `src/render.zig` — CoreText ASCII atlas + two instanced Metal passes
- `src/ctl.zig` — the dev socket
- `src/png.zig` — BGRA → PNG via ImageIO

Ghostty is pinned in build.zig.zon at the same commit as the oracle clone
(`~/go/src/github.com/ghostty-org/ghostty`); the `ghostty-vt` Zig module is
the terminal core, `zig_objc` is ghostty's own pin.

## Known debts

No scrollback view, no selection, cursor is a color swap, input is
cooked NSEvent characters (upgrade path: `vt.input.encodeKey`), no
window-close → quit delegate, no color emoji (alpha-only rasterization;
needs an RGBA atlas pass), atlas-full policy is clear-and-rebuild,
glyphs render single-style (no bold/italic faces yet — the style flags
are in `vt.Style.flags` when we want them), box-drawing sprite set
covers light/heavy/rounded lines + blocks but not doubles/diagonals
(font fallback), clipboard effects (OSC 52) unwired.

Two lessons that will recur: box/block glyphs are SPRITES, never font
glyphs (edge-to-edge or you get seams), and the session must answer
terminal queries (Effects callbacks) or query-and-wait programs like
nvim stall on their response timeouts.

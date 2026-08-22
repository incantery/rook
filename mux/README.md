# rook-mux

The multiplexer, owned: ptys + ghostty-vt in-process + a server that
outlives the terminal. This is the "own it all" line — tmux is no
longer underneath, it is the reference implementation we benchmark
against.

    make                            # ReleaseSafe; a Debug build lags in vim
    ./zig-out/bin/rook-mux          # attach; boots the server if needed
    ./zig-out/bin/rook-mux server   # foreground server

The prefix comes from `~/.config/rook/rook.toml` (`[tmux] prefix`),
C-b when unset; double-tap types it literally. Then:

    v |        split side by side          c        new window
    -          split stacked               n p 1-9  switch window
    hjkl       focus pane                  z        zoom pane
    HJKL       resize split                [        scroll mode (jkudgG, q)
    x          kill pane                   d        detach

`rook-mux stats` prints input→frame p50/p99, frames, bytes. `rook-mux
kill` shuts the server down politely (HUPs every pane). `rook-mux nav
h|j|k|l` moves pane focus from the command line — it exists for
editors to call at their window edges.

## Vim-native navigation

A bare Ctrl-h/j/k/l (no prefix) moves pane focus, vim-tmux-navigator
style. When the focused pane runs vim/nvim/fzf the key is forwarded —
those programs own it — and `nvim/plugin/rook-mux-navigator.lua` (in
this repo; point your plugin manager at `mux/nvim`, gated on
`$ROOK_MUX_PANE`) makes nvim move between its own windows first and
call `rook-mux nav <dir>` when a move hits its edge. When navigation
has nowhere to go the key falls through to the pane, so Ctrl-l still
clears a lone shell. Panes are scrubbed of outer-mux identity
(`TMUX`, `HERDR_PANE_ID`) so editor plugins pick the right navigator.

Working today: dirty-row frames paced at 8ms, scrollback view, OSC 52
copy out to the glass, cursor-shape passthrough (nvim beam in insert),
tabs named live by each window's foreground program. Mouse: click
focuses the pane under it; drag selects, and release copies the
selection to the system clipboard (OSC 52); the wheel scrolls. All
three forward pane-relative instead when the program asked for mouse
(nvim, fzf). Typing snaps a scrolled pane back to live. Splits and new
windows open in the focused pane's cwd. Kitty keyboard protocol is
mirrored: ghostty-vt tracks each pane's flag stack, and the mux sets
the focused pane's flags on the glass (CSI = u), so nvim gets real
kitty input and plain shells get legacy bytes. Not yet: keyboard copy-mode selection, session
persistence across server restart.

## Shape

- `pane.zig` — pty + vt.Terminal + reader thread (pre-tmux Session,
  cut to the bone; the two-stage read pipeline returns when a
  benchmark asks for it)
- `layout.zig` — binary split tree → rects; directional navigate
- `render.zig` — RenderState grids → one full-screen VT frame,
  synchronized-output wrapped; the client just writes bytes
- `server.zig` — poll loop: panes, clients, prefix keys, reap, redraw
- `client.zig` — raw mode + alt screen; stdin up, frames down
- `proto.zig` — type/len/payload frames (placeholder for the real
  multi-client cell protocol)
- `pty.zig` — from the pre-tmux app, plus C spellings of the fd/socket
  calls Zig 0.16 moved out of std

## Next

dirty-row diffs instead of full frames; windows (tabs); copy mode +
scrollback view; the structured cell protocol (phone = second client);
session event log; benchmark vs tmux (memory, throughput, p99).

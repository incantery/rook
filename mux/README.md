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
kill` shuts the server down politely (HUPs every pane).

Working today: dirty-row frames paced at 8ms, scrollback view, OSC 52
copy out to the glass, cursor-shape passthrough (nvim beam in insert),
tabs named live by each window's foreground program. Mouse: click
focuses the pane under it; drag selects, and release copies the
selection to the system clipboard (OSC 52); the wheel scrolls. All
three forward pane-relative instead when the program asked for mouse
(nvim, fzf). Typing snaps a scrolled pane back to live. Not yet: kitty keyboard
passthrough, per-pane cwd inheritance, session persistence across
server restart.

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

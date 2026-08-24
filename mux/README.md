# rook-mux

The multiplexer, owned: ptys + ghostty-vt in-process + a server that
outlives the terminal. This is the "own it all" line — tmux is no
longer underneath, it is the reference implementation we benchmark
against.

    make                            # ReleaseSafe; a Debug build lags in vim
    ./zig-out/bin/rook-mux          # attach; boots the server if needed
    ./zig-out/bin/rook-mux server   # foreground server

The prefix comes from `~/.config/rook/rook.toml` (`[tmux] prefix`),
C-b when unset; double-tap types it literally. A `[mux]` section adds
`nav_owners = ["nvim", "fzf"]` (programs that keep bare Ctrl-hjkl),
`scrollback_mb = 4`, `accent = "#cba6f7"` (the one chrome color — tab
chip, focused borders, popup box; the eight ANSI names still work and
map into the palette), and `sidebar = false` / `sidebar_width = 30`
for the side panel. Then:

    v |        split side by side          c        new window
    -          split stacked               n p 1-9  switch window
    hjkl       focus pane                  z        zoom pane
    HJKL       resize split                [        copy mode (hjkl, v, y, q)
    x          kill pane                   d        detach
    a          toggle the side panel

Workspaces: `rook-mux ls`, `rook-mux new <name>`, `rook-mux switch
<name>` — named sessions in one server, each with its own windows;
prefix-s opens an fzf picker in a popup. The status line reads
`♜ <workspace> (n)  1:nvim* ...`. `rook-mux popup <cmd>` floats a command over the current window —
all input goes to it, it closes when the process exits (fzf pickers,
lazygit, rook's Go tools). `rook-mux stats` prints input→frame
p50/p99, frames, bytes. `rook-mux
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
kitty input and plain shells get legacy bytes. Pins (prefix-P) dock the focused pane to a left rail owned by the
workspace: visible in every window, stacked, one shared width
(prefix-H/L while focused on it). prefix-G promotes a pin to global
(follows you across workspaces) — the chrome-as-panes idea, so a
Claude agent or a log tail lives in the rail. A window's last pane
can't be pinned; the rail hides when the glass is too narrow; the
rail/window seam is a heavier line than a split. prefix-; jumps to
the last focused pane. Copy mode (prefix-[) is vim-shaped: hjkl/0/$/u/d/g/G move a cursor
through the pane and its scrollback, v anchors a selection (the
anchor is content-tracked, so it survives scrolling), y yanks to the
system clipboard. Not yet: session persistence across server restart.

## The state feed

rook-mux is the single writer of its own state and publishes it, so
anything else can hold an exact replica and never has to poll:

    rook-mux state        # the snapshot, one line of JSON
    rook-mux watch        # the snapshot, then one line per change
    rook-mux capture <id> # one pane's viewport as plain text

`watch` sends the full snapshot as its first line, so a consumer in any
language is spawn-read-lines-parse — no polling, no file watching, no
framing, and a reconnect is a resync. Whole snapshots rather than
deltas: a consumer that misses a delta is wrong forever, and dropping
an older snapshot for a newer one is always correct, which is how a
slow reader can never stall the poll loop.

`epoch` identifies the server across restarts (reconnect across a
`rook-mux kill` and you must discard, not merge); `serial` orders
changes, and mutating commands answer with the serial they produced —
`rook-mux switch foo | cat` prints `{"ok":true,"serial":N}`. Wait for
`serial >= n`, never `== n`.

Change is detected by diffing snapshots, on two cadences. Structural
change pushes within 50 ms. Drift — the foreground program, the cwd,
the per-pane `lastOutputMs` — is looked at every 2 s, because a shell
loop respawns its child faster than the poll floor and diffing on it
pushed 118 snapshots in 6 s where the split pushes 5. Idle is silent.

`rook-mux new -q <name>` creates a workspace **without** moving the
person to it — starting work on your behalf must not pull the desk —
and both forms answer with the block they made. Design and the rest of
the plan: `docs/surfaces.md`.

## The side panel

Down the left edge, above windows and workspaces: *spaces* over
*agents*, each row a name, a status dot and a second line (a branch, or
`state · tool`). It is chrome, not a pane — no pty backs it, the frame
builder paints it straight from a model in `chrome.zig`, and it costs
nothing but columns. Clicking a row moves that panel's highlight;
prefix-a folds the panel away, and it folds itself away on glass under
100 columns rather than crowd the work.

Nothing inside the mux decides what it says. The model is pushed in
from outside, one JSON frame per line, in the list shape of the plugin
protocol (`docs/surfaces.md`):

    rook side demo | rook side -     # the herdr design, as frames
    my-producer | rook side -        # the real thing

    {"v":1,"op":"items.push","params":{"surface":"spaces","items":[
      {"id":"herdr","title":"herdr","subtitle":"master","state":"working"},
      {"id":"web-dashboard","title":"web-dashboard","subtitle":"feat/usage-charts",
       "state":"blocked","current":true}]}}

`surface` is `spaces` or `agents`; a frame replaces that panel whole.
An item is `title` (or `id`), `subtitle`, `state` and `current`. Rook
owns the palette, so a model names a *state* and never a color:
`working`, `idle`, `blocked`, `done`, `failed` pick the dot, its shape
and the subtitle's color, and a name rook does not know draws a plain
row rather than costing the frame. A panel-level `title` and `note`
override the header. Unknown keys are ignored, an item without a name
is dropped, and a frame rook cannot use changes nothing on the glass
and answers with the reason — `rook side -` prints
`{"ok":true,"serial":N}` for a frame it took and the refusal on stderr
for one it did not. Until something pushes, a panel says so.

The last frame pushed to each surface comes back out of the state feed
verbatim, under `surfaces[].model`, so a second glass can draw the same
rail without talking to the producer.

## Shape

- `chrome.zig` — the palette (Catppuccin Mocha) and the side panel:
  every cell that is not a pane, plus `Feed`, which holds the last
  model pushed to each surface and owns its bytes
- `pane.zig` — pty + vt.Terminal + reader thread (pre-tmux Session,
  cut to the bone; the two-stage read pipeline returns when a
  benchmark asks for it)
- `layout.zig` — binary split tree → rects; directional navigate
- `render.zig` — RenderState grids → one full-screen VT frame,
  synchronized-output wrapped; the client just writes bytes. `Chrome`
  carries the tab bar, the side panel and the seams
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

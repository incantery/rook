# The engine

The multiplexer, owned: ptys + ghostty-vt in-process + a server that
outlives the terminal. This is the "own it all" line — tmux is no
longer underneath, it is the reference implementation we benchmark
against.

There is one command, and it is `rook`. This directory builds the Zig
engine behind it — installed off `$PATH` at
`~/.local/libexec/rook/engine`, found there by `rook` and `rookd`, and
never typed. Every verb below is spelled the way a person types it,
through the front door; the engine's own argv is identical.

    make                       # ReleaseSafe; a Debug build lags in vim
    make install               # → ~/.local/libexec/rook/engine
    rook                       # attach; boots the server if needed
    rook server                # foreground server

    ./zig-out/bin/engine       # a build you have not installed…
    ROOK_ENGINE=$PWD/zig-out/bin/engine rook ls   # …behind the front door

The prefix comes from `~/.config/rook/rook.toml` (`[tmux] prefix`),
C-b when unset; double-tap types it literally. A `[mux]` section adds
`nav_owners = ["nvim", "fzf"]` (programs that keep bare Ctrl-hjkl),
`scrollback_mb = 4`, `accent = "#cba6f7"` (the one chrome color — tab
chip, focused borders, popup box; the eight ANSI names still work and
map into the palette), `sidebar_mode = "open"|"collapsed"|"hidden"` /
`sidebar_width = 30` for the side panel (`sidebar = false` is the older
spelling of hidden), and `agents = ["claude"]` — the foreground program
names the rail treats as an agent it found. A `[companion]` table (the
same one the Go half reads) names the resident rook watches for —
`command = "vera"`, or `program = "vera"` when that command's first
word is a wrapper; vera by default, `program = ""` turns the slot off.
`bar = false` turns the calm bar off (the bottom row: who holds the
focused pane's keyboard, and the signals), `zoom_view = "ledger"`
makes prefix-s draw rows only, never figures, and `startup =
"last-space"` makes plain `rook` land in a space instead of at home.
`[companion] ask` is what bare text at home runs (`vera say -c rook`
while the companion is vera). The side panel is **off by default** —
the frame is the tab bar, the work at full width, and the calm bar —
and `sidebar_mode = "open"` is how a config asks for it back. Then:

    v |        split side by side          c        new window
    -          split stacked               n p 1-9  switch window
    hjkl       focus pane                  z        zoom pane
    HJKL       resize split                [        copy mode (hjkl, v, y, q)
    x          kill pane                  d        detach
    o          home: out to rook, from anywhere    u   the oldest unread pane
    s          orbit: the spaces as figures, a subview of home
    t  T       vera's pane, from anywhere; pinned, she stays
    a  !       home, the navigator on what is in progress / what needs you
    /  :       home, finding / a command
    C-o        return jump: the space before the last hop
    i          inspector: the focused pane's actor, input owner, program
    A          the legacy side panel away, and back

The top row is the tab bar: the space's name in the scope slot, then
a chip per window. A tab is named once — a name a person gave (`rook
rename`, `:rename` at home), else the first program in it that
was not the shell, with an ordinal when a sibling wears the name —
and rook never renames it afterwards. An actor that claimed a pane in
the window (`rook own`) rides after the name, `deploy · main`; the
tool never does, and the mark (`◐` producing, `•` unread, `!` a
program asked) changes freely. The chrome is one system —
`docs/ui-design-system.md`: roles, not colors; a tab is one
component; `glyphs = "ascii"` for a glass without the marks. The bottom row is the calm bar: `you ▸ claude` on the left —
who holds the keyboard, through what — or `main ▸ claude owns input ·
you observe` once an actor claimed it, and `◐ n · !n · •n · ⊕g n` on the
right — agents producing output, panes unread, global pins — empty
when nothing signals. While the prefix is armed the bar shows the
chords. `docs/altitude.md` is the whole model and the ontology:
home, ownership, the gate, what each word means at runtime.

Workspaces: `rook ls`, `rook new <name>`, `rook switch <name>` —
named sessions in one server, each with its own windows; `rook .` and
`rook --space <name>` attach straight into one. `rook pick` floats an
fzf picker in a popup. In it, ctrl-n/ctrl-p and
the arrows move through the list, enter switches to the row under the
cursor, and **ctrl-o creates the workspace you typed** — the same verb
as `rook new`, in the popup's cwd, so a name that already exists just
switches to it. The status line reads
`♜ <workspace> (n)  1:nvim* ...`. `rook popup <cmd>` floats a command over the current window —
all input goes to it, it closes when the process exits (fzf pickers,
lazygit, rook's Go tools). `rook stats` prints input→frame
p50/p99, frames, bytes. `rook
kill` shuts the server down politely (HUPs every pane). `rook nav
h|j|k|l` moves pane focus from the command line — it exists for
editors to call at their window edges.

## Vim-native navigation

A bare Ctrl-h/j/k/l (no prefix) moves pane focus, vim-tmux-navigator
style. When the focused pane runs vim/nvim/fzf the key is forwarded —
those programs own it — and `nvim/plugin/rook-navigator.lua` (in
this repo; point your plugin manager at `mux/nvim`, gated on
`$ROOK_MUX_PANE`, an env name on the wire that stays as it is) makes
nvim move between its own windows first and call `rook nav <dir>` when
a move hits its edge. When navigation
has nowhere to go the key falls through to the pane, so Ctrl-l still
clears a lone shell. The motion does not stop at home's door either:
at the root the same four keys walk the cockpit's regions — the
thread above the composer, the dashboard right of both — and at one
of those edges the key is the view's again (Ctrl-h in the composer is
a backspace). Panes are scrubbed of outer-mux identity
(`TMUX`, `HERDR_PANE_ID`) so editor plugins pick the right navigator.

Working today: dirty-row frames paced at 8ms, scrollback view, OSC 52
copy out to the glass, cursor-shape passthrough (nvim beam in insert),
tabs named live by each window's foreground program. **The tabs are
clickable**: a chip selects its window and the trailing `+` opens a new
one — prefix-1..9 and prefix-c for the hand already on the mouse. The
painter records each chip's columns as it spends them, so the target
is where the chip was actually drawn; the air between chips, the
`⋯ n more` tail and the corner hint are not targets and do nothing.
Mouse: click focuses the pane under it; drag selects, and release copies the
selection to the system clipboard (OSC 52); the wheel scrolls. All
three forward pane-relative instead when the program asked for mouse
(nvim, fzf). Typing snaps a scrolled pane back to live. Splits and new
windows open in the focused pane's cwd. Kitty keyboard protocol is
mirrored: ghostty-vt tracks each pane's flag stack, and the mux sets
the focused pane's flags on the glass (CSI = u), so nvim gets real
kitty input and plain shells get legacy bytes. Bracketed paste
is mirrored the same way, and a glass is told both the moment it
attaches — a glass never sent `?2004h` does not wrap Cmd-V, and an
unwrapped paste is a run of keystrokes. Between `ESC[200~` and
`ESC[201~` the server reads nothing for itself: a backtick in pasted
text is a backtick, not the prefix (`python3 scripts/paste-e2e.py`
checks that, through a real glass).

Pins (prefix-P) dock the focused pane to a left rail owned by the
workspace: visible in every window, stacked, one shared width
(prefix-H/L while focused on it). prefix-G promotes a pin to global
(follows you across workspaces) — the chrome-as-panes idea, so a
Claude agent or a log tail lives in the rail. A window's last pane
can't be pinned; the rail hides when the glass is too narrow; the
rail/window seam is a heavier line than a split. prefix-; jumps to
the last focused pane. Copy mode (prefix-[) is vim-shaped: hjkl/0/$/u/d/g/G move a cursor
through the pane and its scrollback, v anchors a selection (the
anchor is content-tracked, so it survives scrolling), y yanks to the
system clipboard. Session persistence across a server restart is on by default —
the layout, the cwds, and every program that told rook how to come
back (below); not scrollback.

## The state feed

The engine is the single writer of its own state and publishes it, so
anything else can hold an exact replica and never has to poll:

    rook state        # the snapshot, one line of JSON
    rook watch        # the snapshot, then one line per change
    rook capture <id> # one pane's viewport as plain text

`watch` sends the full snapshot as its first line, so a consumer in any
language is spawn-read-lines-parse — no polling, no file watching, no
framing, and a reconnect is a resync. Whole snapshots rather than
deltas: a consumer that misses a delta is wrong forever, and dropping
an older snapshot for a newer one is always correct, which is how a
slow reader can never stall the poll loop.

`companion` in the snapshot is when and where that resident is open —
which panes are running her, in which workspace and window, whether
she is on the glass or holding the keyboard, and since when. Only what
rook can see in its own panes: open on a phone is not open in rook.
`rook companion` reads it out as a line (`--json` for the bytes) and
exits 1 when she is not open.

`epoch` identifies the server across restarts (reconnect across a
`rook kill` and you must discard, not merge); `serial` orders
changes, and mutating commands answer with the serial they produced —
`rook switch foo | cat` prints `{"ok":true,"serial":N}`. Wait for
`serial >= n`, never `== n`.

Change is detected by diffing snapshots, on two cadences. Structural
change pushes within 50 ms. Drift — the foreground program, the cwd,
the per-pane `lastOutputMs` — is looked at every 2 s, because a shell
loop respawns its child faster than the poll floor and diffing on it
pushed 118 snapshots in 6 s where the split pushes 5. Idle is silent.

`rook new -q <name>` creates a workspace **without** moving the
person to it — starting work on your behalf must not pull the desk —
and both forms answer with the block they made. Design and the rest of
the plan: `docs/surfaces.md`.

## What the programs say

The emulator hands the mux every bell, desktop notification (OSC 9 /
99 / 777), title, pwd (OSC 7) and progress report (OSC 9;4) as it is
parsed, and every one is published on the pane: `title`, `pwd`,
`progress`, `bellMs`, `progressDoneMs`, `notified`. A bell is passed
to the glass; a notification is re-sent as OSC 777 when its pane was
not in front of you, so the terminal that can reach the desktop does.

A signal that arrives while nobody is looking at its pane puts the
pane on the **unread** channel (`unread`, `unreadMs`): a `!` on its
tab, a `●` on the rail's row for its workspace, until focus lands on
it. `prefix-u` (`rook jump`) goes to the oldest. Rook publishes the
words and acts on their arrival; it never reads them for meaning.
`docs/attention.md`.

## A pane, by id

Every pane's `$ROOK_MUX_PANE` is its id, so a program inside one can
name itself (`.`) to the front door:

    rook read <id> [-n N]          the viewport, or the last N lines with history
    rook send <id> <text>          type it; `run` adds Enter; `key` names keys
    rook wait <id> --match S | --quiet MS [--timeout MS]
    rook split <id> [--down] [--focus] [--cwd DIR]
    rook window <id> [--focus] [--cwd DIR]
    rook focus <id> | jump | close-pane <id>

Nothing here pulls the desk unless `--focus` asks. `rook --skill` is
the same, written for the agent that will read it.

## Coming back

`<sock>.state` is saved on every structural change and on `rook
kill`; `[mux] restore` (on by default) rebuilds workspaces, windows
and cwds from it on boot. v2 of the file adds two lines: `resume <cmd>`
under a pane, and `pane <cwd>` for a sibling of the window above that
has one — an agent's conversation is worth a split, the split alone is
not.

    rook resume <id> <cmd...>      how to bring this pane's program back
    rook resume <id> --clear       forget it
    rook own <id> <actor>          the actor holds the pane's keyboard
    rook own <id> --release        …and gives it back (see Owning a pane)
    rook rename <name>             name the current tab, once and for all

The command is the program's own word, published as `panes[].resume`,
and it belongs to the program that set it: rook writes down what was
in the foreground then, and saves the command only while that is
still so. A Claude that has quit leaves a shell, and a shell is what
comes back. On boot a restored pane types its command into the new
shell once the prompt is up (or after 1.5 s), Enter included — into
the shell's own environment, with the shell still there afterwards.
`rook resume` outside rook, or against a server that does not answer,
exits 0 in silence: it is written to be a hook.

## Home

Plain `rook` lands at home: the same frame, the whole width between
the bars rook's own canvas, split in two. The scope slot holds the
system's chip — `rook` in the accent block, which a space's name
never wears, so a space named `rook` is still just a space — then
the view as a tab and, muted, what is selected; no counts, no
corner. Left, the work navigator: `needs you`, `in progress`,
`recent`, `spaces`, each only when it has rows — one row per task,
by goal, with its mark and its space or age; a task's agent, pane
and space are on it, never beside it; an idle agent is not work.
Right, the inspector for the selected row: the goal, `now` (or
`waiting on you` with the question, or `what went wrong`, or the
`outcome`), the plan with `n of m`, the timeline, files, commits,
tests, artifacts, usage, the last lines its pane wrote, and
`controls` — the producer's options and actions (each a command
rook runs on ↵, never implied), vera's pending proposals about it,
`open its pane`, `ask vera about this`. `j k` walk, `l` inspects,
`h` is the list, `o` opens the exact pane or space, `g G` the ends,
Ctrl-h/l and ⇥ walk the regions. Under 81 columns the two are a
stack. Nothing is resized to get here or back.

Vera is a pane rook owns, one key away: `prefix-t` summons her over
the inspector's side (or, in a space, over the panes, holding the
keys, resizing nothing) and again dismisses her; `prefix-T` pins
her, a third column when the glass affords three. Her thread, her
scroll and your draft survive. Typing a letter from the navigator
summons her with the letter; `/` and `:` are find and command
without her. `ask vera about this` attaches the selected task as a
reference the request carries (`ROOK_ABOUT_TASK`, `ROOK_ABOUT_SPACE`
in its environment). Bare text runs `vera say -c rook <text>`; a
reply that is one JSON object (`ask.zig`: intent, plan, space, task,
question, actions) is a block in her pane and its actions are rows
under `needs you`. Without her on PATH the bar says `vera offline`
and everything but her works.

The calm bar is composed from `[mux] status_home` at home (`view -
agents attention blocked session vera`) and `status_space` in a
space (`input - working attention unread pins`): `agents ◐ 2 active
· 1 idle`, `! 2 need you`, `✕ 1 failed`, `session $4.18 · 812k
tokens` (the producer's usage since this server started; off until
someone reports it), `vera ready|thinking|waiting for you|offline`.

prefix-s is orbit, a subview of home: the scope bar reads `rook │
orbit` with `esc rook` in the corner, and every space is a figure
when rook has something to say about it (the name in the top edge
with an event line; the tabs with their actors and marks inside; for
the space you left, the last lines of the pane you were in, read from
retained cells) or one compact row when it does not. Under 60
columns, with `zoom_view = "ledger"`, or when the figures would not
fit, the same spaces draw as two-line rows, and the bar and the scope
bar say `ledger`. `scripts/altitude-fixture.py` renders all of it
deterministically; `docs/altitude.md` is the model.

## Owning a pane

A pane is the person's until a program says otherwise: `rook own <id>
<actor>` claims its keyboard. The bar then reads `<actor> ▸ owns input
· you observe`, and a typed key opens a one-row gate instead of
landing — `⏎` requests a handoff (the actor sees `takeover-requested`
in the feed, finishes its step, `rook own <id> --release`s, and the
person confirms with `⏎`), `T` takes now, `s` sends the next keystrokes
through Enter as a message, Esc leaves it. `--paused` attaches an
actor without giving it the keys; `--request` and `--take` are the
gate's moves from a script. `panes[].input` in the feed carries the
state and the owner. prefix-i shows it all in a box.

## The side panel (legacy, off by default)

Down the left edge, above windows and workspaces: *spaces* over
*agents*, each row a name, a status dot and a second line (a branch, or
`state · tool`). It is chrome, not a pane — no pty backs it, the frame
builder paints it straight from a model in `chrome.zig`, and it costs
nothing but columns. Clicking a row moves that panel's highlight, and
takes you to the workspace the row names — the agent's own pane on
*agents*, the workspace itself on *spaces*.

**It has three modes**: `open` is the panel in full; `collapsed` is
three columns of dots — the same rows in the same places with the
words taken off them, so what wants you still reaches the eye and the
panel that comes back has not moved under it; `hidden` is the work
with no chrome down its left edge. prefix-A goes between hidden and
open (prefix-a is home's now; the collapsed rail is reached by
config).
A click on a collapsed row still goes where the open one would.
`[mux] sidebar_mode` says which mode the rail starts in.

The panel folds rather than crowd the work: under 100 columns `open`
falls back to the collapsed rail, and glass too narrow even for that
(the window keeps 60 columns) hides it. What the rail is *showing*,
folding included, rides the state feed as `surfaces[].mode`, beside
the `shown` that says whether there is anything to draw at all.

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
An item is `title` (or `id`), `subtitle`, `state`, `origin`,
`workspace` and `current`. Rook owns the palette, so a model names a
*state* and never a color: `working`, `idle`, `blocked`, `done`,
`failed` pick the dot, its shape and the subtitle's color, and a name
rook does not know draws a plain row rather than costing the frame. A panel-level `title`
and `note` override the header. Unknown keys are ignored, an item
without a name is dropped, and a frame rook cannot use changes nothing
on the glass and answers with the reason — `rook side -` prints
`{"ok":true,"serial":N}` for a frame it took and the refusal on stderr
for one it did not. Until something pushes, a panel says so.

### Agents rook finds by itself

One thing on the rail is not pushed. A pane whose foreground program
is an agent — `claude` by default, `[mux] agents = [...]` to say
otherwise — is a session somebody started, and rook can see it in its
own pane table whether or not any producer knows about it. Those
sessions get rows on the *agents* panel, one per workspace, folded in
after whatever was pushed:

    agents            1 manual
    ● main                        ← pushed: a producer manages it
      working · claude
    ◌ scratch                     ← found: nobody claims it
      manual · claude

The distinction is `origin`, and it is deliberately quiet: a dim
`manual ·` ahead of the subtitle, and the loose dot ◌ for a row with
no state to report. Origin never takes a color and never overrides a
state, so a glance still reads state first. A producer can push
`"origin":"manual"` to say the same about a row of its own.

The merge is one-way and pushed rows always win: a producer that names
a workspace owns that row, so rook drops what it found there rather
than listing it twice. It names it with `workspace` on the item:

    {"id":"f356bc2c","title":"Fix the duplicate rows",
     "subtitle":"working · rook","state":"working",
     "workspace":"rook--vera-f356bc2c"}

A row's `title` is prose — a task, a sentence, whatever the producer
calls the work — so it is not an identity rook can match against its
own pane table, and matching on it anyway is what listed one agent
twice: once as the task somebody is running, once as the pane rook
found running it. `workspace` is rook's own vocabulary (the names in
`rook state`), which is why the claim is made in it. A title still
counts when there is no `workspace`, for a rail whose rows are named
after workspaces anyway.

Rook says only that the session is there — never what it is doing,
which stays a producer's job. The scan is two syscalls a pane on a 2s
timer, and only a change repaints.

**Clicking an agent goes to it.** The workspace the row names becomes
current and focus lands on the pane running the agent there, in
whichever window of it holds that pane — a found row carries its
workspace, and a pushed row names one with `workspace`. That is the
whole claim: a row whose name is prose and that names no workspace is
about work rook cannot see, so clicking it only moves the cursor, as
before.

The spaces panel works the same way for what rook holds itself: every
workspace is a row (`"origin":"found"` — no tag, no count; a workspace
is nobody's unmanaged agent), the current one highlighted, and a click
on one switches to it. A producer's row claims a workspace with
`"workspace"` and replaces rook's row for it. So an unfed rail is not
blank: it is rook's own workspaces, and a producer adds state to them.

Rook's own rows wear a **label**, not a workspace name. A worktree's
workspace is `<repo>--<worktree>` — `rook--vera-e4126385` — because
that name has to be unambiguous across every repository on the
machine. Down a 30-column dock that makes the repo the same word on
every row and pushes the part that tells the rows apart off the right
edge. So the row reads `vera-e4126385` with `rook` in its subtitle,
which is what `rook worktree ls` has always printed:

    spaces
    ● rook
    ◌ vera-e4126385
      rook

Shortening never costs uniqueness: a label two workspaces would share
gives both of them their full name back. The workspace itself is still
on the row — `workspace` in the state feed, and what a click switches
to — so a claim, a match or a `rook switch` is always made on the full
name.

A short label is still an id when the worktree was named after one,
and rook cannot invent the meaning. It may already have been told it
though: when a producer pushes an *agents* row claiming that
workspace, the space repeats that producer's own title, verbatim, and
the label falls to the subtitle:

    spaces
    ● rook
    ◌ Name the spaces Vera makes
      rook · vera-e4126385

Words only. No state is borrowed — the row is still `origin: "found"`
with nothing to report, so the dot says the space is there and the
agents panel says what is happening in it.

The last frame pushed to each surface comes back out of the state feed
verbatim, under `surfaces[].model`, so a second glass can draw the same
rail without talking to the producer. What rook found rides beside it
under `surfaces[].found` — never merged into `model`, which stays the
producer's own bytes. A found row carries both words: `title` is the
label rook paints and `workspace` is the workspace it is about. Match
on `workspace` — a title is prose, and rook shortens its own.

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

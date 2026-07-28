# rook — native, in Zig, on libghostty-vt

Numbers live in [PERF.md](PERF.md); `./bench.sh` reproduces them.

This IS rook now: `make install` puts it at `/Applications/rook.app`,
and it replaced the webview app that used to live there. `rook` is the
app and the CLI both — verbs it doesn't own are handed to the bundled
`rookctl` (see `src/main.zig`), and `re` is `rook edit`. The webview
app is still buildable with `make install-web` if this one misbehaves.

Standalone Zig desktop terminal:
pty → ghostty-vt → RenderState → instanced Metal grid in an owned
CAMetalLayer. No webview, no Swift.

The window is a SCENE: tabs of split trees, each pane its own
pty + emulator, all drawn by one pipeline (grids are uniforms + a
buffer offset; chrome is more quads). Chords match the wails app:
**⌘D** split right, **⌘⇧D** split down, **⌃HJKL** focus nav — which
yields to alternate-screen apps (vim keeps its own splits) by reading
alt-screen truth straight from the emulator, no heuristic — plus
**⌘T** new tab, **⌘1–9** select, **⌘⇧[** / **⌘⇧]** cycle. The mouse
works: clicks focus panes and select tab chips; drag selects text
(⌘C copies — a focused editor copies its visual selection or last
yank instead); the wheel scrolls editors, primary-screen viewports
(typing snaps back), and alt-screen apps (arrow keys). <leader>[
enters tmux-style copy mode: j/k/u/d/⌃B/⌃F/gg/G scroll, q/ESC exits,
an accent SCROLL chip shows in the bar.

**`/` searches the scrollback** from copy mode; `n` and `N` step
through the hits, and the bar shows the needle and `3/17` — `n` is
unusable if you can't see what you're stepping through, and `no match`
is how a search that found nothing says so. ESC abandons the prompt
without leaving copy mode, and backspacing past the first character
closes it, the way vim's `/` does. ghostty-vt does the actual searching
(`vt.search.Screen`); rook adds a lifetime, a viewport move and the
readout. The hit becomes the terminal's real SELECTION, so it
highlights and ⌘C copies it without a new render path. It lands half a
screen down, computed as an absolute row — the library clamps that at
both ends, whereas scroll-to-pin-then-up would push a hit that was
already near the bottom clean off the viewport. If a program swaps to
the alt screen while a search is live the search is dropped, because
results from the primary screen shown over the alternate are nonsense;
a resize is survivable and the library re-searches itself. This uses
the BLOCKING `searchAll` — the library also offers tick/feed so a
background thread can chew through a huge buffer incrementally, which
is what to reach for when scrollback grows past one page (it hasn't:
`Session.start` never sets `max_scrollback`, so it inherits the
embedded-library default of 10,000 *bytes*, about 930 rows in
practice).

**⌘V** pastes, by xterm's rules (`src/paste.zig`, pure data in/data out,
its own test root): bytes that could signal the foreground process —
ESC, ⌃C, ⌃Z, NUL, the tty's own control set — become spaces whether or
not the paste is framed, so a clipboard payload can never close its own
bracket and turn into commands. With bracketed paste on (DECSET 2004,
which zsh sets) the run is fenced and newlines ride through untouched;
without it, `\n` becomes `\r`, because the pty is a line discipline and
CR is what Return sends. An editor pane takes the pasteboard as a
REGISTER, not as keys — ⌘V in normal mode is `p` (linewise when the
text ends in a newline), so a stray `dd` in your clipboard inserts two
characters instead of eating a line; insert mode takes it literally.
ctl `paste` drives the identical path (bare = the real pasteboard,
`paste <text>` for a controlled payload, `\n` for a newline), which is
how the rules above are verified — ⌘V carries a modifier the `press`
verb can't express. NOT yet: a confirmation prompt for unframed
multiline pastes (`paste.isSafe` exists, nothing gates on it).

**Dead keys and IME** work now, which needed a view class of rook's
own: a stock NSView returns nil from `-inputContext`, AppKit's way of
saying "this thing does not take text", so ⌥e e and every CJK input
method were simply impossible. `RookTextView` conforms to
NSTextInputClient and the input method gets FIRST REFUSAL on every
unmodified key. Text it commits (ordinary ASCII included) is the input;
while it composes, the preedit is held and drawn at the cursor in
accent with an underline — it is not input yet, so the emulator never
sees it and `dump` can't show it (`shot` can). A key the IME reduces to
a Cocoa selector (`-insertNewline:`, `-moveUp:`) is DROPPED and encoded
by us instead: a terminal wants `\r` and `\x1b[A`, not AppKit's idea of
what a key means, which is why Return/Tab/ESC/arrows are untouched by
any of this. Modified keys never reach the IME at all — ⌃C is the
terminal's.

**BEL is an attention signal**, which is most of why it exists here: an
agent finishing in a space you left is the case rook cares about, and
until the attention inbox lands this is the only way the app can say so.
The tab that rang wears an accent dot on its chip, and the Dock bounces
once (`requestUserAttention:`, informational — the critical variant
bounces until you focus the app, which is bad manners for a shell that
finished a build). Both are suppressed when you are already watching:
frontmost, on that tab. Visiting the tab IS the acknowledgement, so
there is no dismiss. `bell` in config takes `none`, `visual` (default),
`audible` (adds NSBeep), or `all`. The emulator callback runs on the
reader thread inside the parse, so it only raises a flag — everything
the bell MEANS is AppKit's, drained on the main thread off the 2Hz HUD
tick. ctl `tabs` prints `bell` beside a tab that is holding one.

**OSC 9 / OSC 777** become real desktop notifications, so an agent that
finishes in a space you left can say so through Notification Centre
rather than only through a chip dot. This needed a fork of ghostty-vt:
the library decodes both sequences and then dropped the result, having
no effect callback to hand it to — `incantery/ghostty`, branch
`rook/vt-desktop-notification`, adds one mirroring `bell`. Permission is
requested lazily, on the first notification rather than at launch, so a
probe instance never triggers the prompt. Unbundled runs skip it with a
warning: `currentNotificationCenter` raises when the process has no
bundle identifier, which is exactly how `zig build run` runs. ctl
`notify` reports the last one posted.

**OSC 52** puts a remote yank on the local pasteboard — vim or tmux over
ssh, which silently does nothing in a terminal that ignores it. The
library hands the payload over already base64-decoded, and it never
forwards clipboard READ requests (`ESC ] 52 ; c ; ? BEL`) to an embedder
at all, so no program running in rook can exfiltrate what you copied;
the sequence is simply answered with silence. All three destinations
(`c`, `p`, `s`) collapse onto the one general pasteboard, because macOS
has no primary selection and vim already maps `*` and `+` to the same
register here — honouring `p` separately would invent a clipboard the OS
does not have. An empty payload clears, which is what the spec asks for.

`clipboard-write` takes `allow` (default) or `deny`, live-reloadable. It
is a knob at all because a clipboard write is *unprompted*: anything
that can put bytes on your screen — including `cat` of a file you did
not write — can replace what your next ⌘V pastes. Reads need no knob;
they never get here. Unlike the bell, this drains every FRAME rather
than on the 2Hz HUD tick: a yank can be followed immediately by ⌘V, and
pasting the previous clipboard would be a real bug rather than a late
notification. The common case is one atomic load per pane, so per-frame
costs nothing. The payload buffer is heap and grows — truncating a yank
at a fixed cap would hand you a corrupt paste, which is worse than
refusing — with an 8MB ceiling, since the OSC parser's own capture for
52 is allocating and unbounded. ctl `clipboard` reads the real
pasteboard back, so a blind test proves the bytes reached the system.

The cursor
and the accent-colored separator edges mark the focused pane. Only the
active tab renders: background tabs' emulators keep advancing but cost
zero frames (measured: `yes` in a hidden tab, 480 ticks, 1 draw). A
pane closes when its shell exits, an emptied tab closes, the last tab
closing quits the app.

Tabs live in a TOP bar (first-class chrome, the wails app's named
tabs): each chip is " n title " where title is the tab's focused-pane
OSC 0/2 title straight from the emulator ("shell" until something sets
one); the active chip gets a lifted background and an accent
underline. Title changes are caught by the 2Hz HUD digest — OSC
titles don't dirty the grid, so the digest is what redraws chips.

Panes hold CONTENT — a terminal or an EDITOR (the rook-buffers model:
a file is a document, panes retarget in place). The editor is vim-core
over a rope buffer (`src/rope.zig` → `src/buffer.zig` →
`src/editor.zig`): normal/insert/visual/visual-line/command modes,
h j k l w b e 0 ^ $ gg G arrows ⌃D/⌃U, operators d y c (dd yy cc D C
Y), x r J p P, counts, grouped undo (u / ⌃R), `:w :q :wq :e :<n>`.
`/` searches (literal, wrapping, n/N, hlsearch until `:noh`).
TREE-SITTER highlighting is in (slice two): the runtime and zig/go
grammars are vendored C (vendor/), highlight queries embedded; a
full reparse runs per buffer change (size-capped) and capture spans
are extracted for the visible range only, mapped to the theme's
syntax colors. Other languages = drop a grammar's parser.c + its
highlights.scm into vendor/ and add two lines to syntax.zig.
Open one with `rook edit <file>` — or just `re <file>` — from any
shell inside the app (the CLI finds this instance via ROOK_SOCK), or
ctl `edit <path>`. The editor TAKES OVER the pane like vim would: the
shell parks underneath and keeps running, `:q`/⌘W drops you back to
it, prompt and scrollback intact (a focused editor retargets in
place instead). Opening a DIRECTORY gives a netrw-style listing
buffer — j/k, Enter descends/opens, `-` climbs to the parent from
any buffer with the cursor landing on where you came from; dirs sort
first, `../` is always line one, and it lives inside the pane, so
every pane can hold its own tree. The app leader works in the editor
too (double-tap types the literal key, same as a terminal). The
editor is a pure model — keys in, a styled character grid out — so
`zig test src/editor.zig` drives the whole modal machine headless
with ZERO C linkage: the highlighter attaches through
function-pointer hooks (syntax.zig), never an import (the directory
reader is plain libc readdir, which macOS links regardless). Editor
debts: one register, no autoindent, undo doesn't track the save
point (a fully-undone buffer still reads modified), wide glyphs
count one column, 4KB line clamp on motions/render, relative :e
paths resolve against the app cwd rather than the buffer's dir.

WORKSPACES ARE SESSIONS (tmux's model): the hierarchy is space → tabs
→ panes. Each workspace owns a full tab set; switching swaps the
whole window's contents, and background spaces' shells keep running
at zero render cost (same property as background tabs). The launch
cwd names space one; a space collapses when its last tab closes (the
last space closing exits the app).

The TITLE ZONE says where you are and what you're burning: workspace
name CENTERED, the usage cluster right-aligned (`5h 27% · wk 44% ·
fable 73%` — labels compacted the wails way, colored by the worst
window: ≥70% accent, ≥90% error). In glass mode it rides the real
titlebar strip; opaque shares the tab row. Usage is rook-host's
cost-weighted prober, read from its localhost HTTP (`/usage`, port +
bearer token re-read from ~/.local/state/rook/host.json each fetch)
by a 30s background thread — fail-open: no host, no cluster, and
only a text CHANGE draws a frame. ctl `usage` replies the cluster as
drawn. Tab chips are back to bare `n title` — the space owns the
workspace identity now.

`<leader>s` (action `workspace.switch` — tmux's prefix-s
choose-session; `w` stays reserved for a choose-window picker) opens
the WORKSPACE PALETTE —
the first modal chrome tenant, and the seed of every future picker
(file finder, themes, commands): type-to-filter fuzzy list, arrows or
⌃N/⌃P, Enter, ESC. The list is rook's own registry — rook reads
`workspaces(name, root, worktree_of, last_used)` from
~/.local/share/rook/rook.db through the system libsqlite3, read-only,
re-queried each open, so it always reflects what wails-rook/rook-host
last touched (a machine without the db just gets an empty palette).
GROUPED: worktree children sit indented under their parent as
`rook/zig`, and the filter matches the combined name. Enter attaches
the workspace's session — existing space switches in with its tabs
intact, first visit creates it with one shell in the root. Inside a
space, cd stays sacred: tab chips wear the name of whatever workspace
their shell is actually IN (`1 zig · shell`), resolved from the cwd
at the 2Hz HUD tick. ctl: `workspaces`, `palette-open`, `palette`
(state dump — the modal is blind-drivable through the normal
type/press verbs); `tabs`/`panes` list all spaces.

A status bar sits under the panes — tenant one of `src/ui.zig`, the
seed of rook's own UI layer (immediate-mode quads + text runs from the
same pipelines/atlases as the grid; widgets are never their own draw
paths). Left: pane count + focused id. Right: the live perf HUD —
key→photon p50, fps, MB/s, RSS — the instrument wearing a face.
It refreshes at 2Hz but draws only when the text changes, so the
zero-idle-frames row on the scoreboard still holds. The fps number is
CAPABILITY: the display's rate, dipping only when measured frame cost
can't fit the vsync budget — demand pacing (dirty-skip drawing less
because less happened) never reads as lag.

```
zig build                    # needs zig 0.16
./zig-out/bin/rook win      # the app (make dev from repo root does both)
./zig-out/bin/rook demo     # headless: bytes → vt → screen dump
./zig-out/bin/rook exec ls  # run a command under a pty, dump final screen
make install                 # repo root: ReleaseFast → /Applications/rook.app
```

The installed app answers on the default `/tmp/rook.sock`; `make
dev`/`make prod` instances use `/tmp/rook-dev.sock` so they never
steal it (the ctl server unlinks-then-binds). App shells are login
shells (`-l`) started in `$HOME` — Dock launches have a skeleton env
and a cwd of `/`.

Flags: `win --no-activate` opens the window without stealing focus —
use this for every tooling/probe launch.

## rook-host: the daemon is ours now

`internal/host` is rook's server half — threads, review, asks,
attention, transcripts, decisions, worktrees — and `rookctl` and the MCP
server reach it over localhost HTTP with a bearer token from
`~/.local/state/rook/host.json`. `src/hostc.zig` is rook walking
through that same door: `readInfo` → `get`/`post` → JSON, hand-rolled
HTTP/1.1 over one connection per request (one origin, one hop, no TLS,
no redirects — std.http would be the bigger thing). `usage.zig` is its
first tenant.

The lifecycle is INVERTED from the wails app. That one deliberately
rides a healthy daemon and never kills it, so shells survive an app
restart; rook owns its ptys in-process, so that trade buys nothing
here. Instead: rook spawns the daemon at launch (off-thread — a cold
start costs a health poll of up to 5s and the first frame owes it
nothing) and SIGTERMs it on quit. Nothing runs while rook is closed.

We always spawn and let rook-host decide, rather than reimplementing
`shouldRide` in Zig: the daemon is idempotent, and replaces a stale
build or exits with "already running" on its own. `owned` is then just
`host.json`'s pid == the pid we forked — and we shut down only what we
own, so a rook launched beside the wails app during the cutover can
never take that app's daemon with it. Check either with `version`:

```
rook dev build=dev
host=up port=56744 pid=56341 build=a46c116.20260726142750 owned=yes
```

Fail-open like everything else: no host.json, no binary, a dead daemon
→ `host=down`, one line on stderr, and a terminal that works fine
without it. A rook that is SIGKILLed leaves its daemon behind, which
the next build change reaps — the same gap the wails app has.

## Dev control socket (the playwright substitute)

Debug builds listen on `/tmp/rook.sock` (`ROOK_SOCK` overrides).
Line protocol, drivable with plain `nc -U`:

```
printf 'dump\n'              | nc -U /tmp/rook.sock   # screen text (vt truth)
printf 'type ls -la\n'       | nc -U /tmp/rook.sock   # keystrokes → pty
printf 'enter\n'             | nc -U /tmp/rook.sock
printf 'ctrlc\n'             | nc -U /tmp/rook.sock
printf 'key 1b5b41\n'        | nc -U /tmp/rook.sock   # raw hex bytes → pty
printf 'press `\n'           | nc -U /tmp/rook.sock   # REAL key path (leader
                                                       #   machine included)
printf 'panes\n'             | nc -U /tmp/rook.sock   # all tabs' panes, * = active/focused
printf 'tabs\n'              | nc -U /tmp/rook.sock   # list tabs
printf 'tab new\n'           | nc -U /tmp/rook.sock   # also: tab <n>, tab next, tab prev
printf 'split right\n'       | nc -U /tmp/rook.sock   # split focused (or: down)
printf 'edit /abs/file\n'     | nc -U /tmp/rook.sock   # editor pane (focused editor
                                                       #   retargets; else split right)
printf 'focus left\n'        | nc -U /tmp/rook.sock   # move focus (or an id — switches tab)
printf 'click 300 800\n'      | nc -U /tmp/rook.sock   # px coords: chips select, panes focus
printf 'wheel 300 800 -5\n'   | nc -U /tmp/rook.sock   # scroll steps (+ = up) at a point
printf 'drag 99 206 319 206\n' | nc -U /tmp/rook.sock   # select: down, drag, up
printf 'copy\n'               | nc -U /tmp/rook.sock   # \u2318C's path; replies the text
printf 'paste\n'              | nc -U /tmp/rook.sock   # ⌘V's path; the real pasteboard
printf 'paste a\\nb\n'         | nc -U /tmp/rook.sock   #   or a literal payload
printf 'nskey 14 80000\n'     | nc -U /tmp/rook.sock   # a REAL NSEvent: keycode,
                                                       #   modmask hex, characters
printf 'ime\n'                | nc -U /tmp/rook.sock   # input-context state + preedit
printf 'version\n'            | nc -U /tmp/rook.sock   # build id + rook-host state
                                                       #   (owned=yes → quitting kills it)
printf 'dump@2\n'            | nc -U /tmp/rook.sock   # any pane-taking verb
printf 'type@2 ls\n'         | nc -U /tmp/rook.sock   #   targets by @id
printf 'shot /tmp/s.png\n'   | nc -U /tmp/rook.sock   # pixel truth
printf 'winsize 900 600\n'   | nc -U /tmp/rook.sock   # resize (points)
printf 'fullscreen\n'        | nc -U /tmp/rook.sock   # toggle (latency: −7ms)
printf 'stats\n'             | nc -U /tmp/rook.sock   # live perf numbers
printf 'stats reset\n'       | nc -U /tmp/rook.sock
printf 'quit\n'              | nc -U /tmp/rook.sock
```

`press` and `type` write bytes straight into the app, so they cannot
test anything AppKit does on the way IN. `nskey` posts a real NSEvent to
our own queue — NSApp dispatch, the local monitor, the input context,
the whole path minus a finger. It is how the IME above is verified
(`nskey 14 80000` is ⌥e); it drives single keys by keycode, since the
input context re-derives characters from the keycode and layout.

dump/type/enter/ctrlc/key default to the focused pane; `@<id>` targets
another. Add `-w 2` to nc in scripts — and when grepping a dump for
shell output, remember lines WRAP at the pane width (a 15-second
"stall" was once just `total` split into `t`/`otal`).

`shot` reads back our own CAMetalLayer drawable — no screen-recording
permission, works occluded or on another Space. Its PNG flattens the
alpha channel (png.zig writes BGRX), so background-opacity can't be
verified from a shot — the startup log line is the observable. `dump` and `shot` are
different truths: dump is what the emulator holds, shot is what the
renderer did with it. The atlas-flip bug (day two) was invisible to dump
and obvious in shot; keep both in every verification.

## Config

`~/.config/rook/config.toml` (respects `XDG_CONFIG_HOME`). A TOML
subset: flat `key = value`, `#` comments, quoted strings; `[sections]`
skipped. Keys may be quoted (`"background-opacity"` works); dashes and
underscores are interchangeable. Missing file = defaults. Unknown keys
warn on stderr.

```toml
font-size = 13
font-family = "FiraCode Nerd Font Mono"
theme = "nocturne"       # builtin themes: default, nocturne
background-opacity = 0.9 # <1 = translucent window; OPTS OUT of
                         # direct scan-out (~+5ms present lag) —
                         # perf tradeoff on purpose, default 1.0
window-padding = 8       # points of breathing room between chrome
                         # and panes (default 0: content runs to the
                         # window edge); the gap shows the theme bg
background-blur = "blur" # what's BEHIND a translucent window:
                         # none (raw desktop), blur (frosted,
                         # NSVisualEffectView — the recommended one),
                         # glass / glass-clear (macOS 26 Liquid
                         # Glass, NSGlassEffectView; pre-Tahoe falls
                         # back to blur). Ghostty's macos-glass-*
                         # names accepted. Needs opacity < 1.
bell = "visual"          # none | visual (default) | audible | all
clipboard-write = "allow"# OSC 52: allow (default) | deny. `true` /
                         # `false` mean the same two things.
```

Opacity < 1 is whole-window glass: the layer extends under a
transparent titlebar (fullSizeContentView — traffic lights float over
a tinted strip that stays a pure drag region, chrome shifts down
28pt), and the tab/status bars and editor status row carry the same
alpha as default-bg cells. Explicit-bg cells, selection, and accent
highlights stay solid. Opaque config keeps the stock titlebar.

background-blur inserts a backdrop view BEHIND the Metal layer (our
view becomes its subview/contentView) — no render-path change at
all; our alpha stays the mixing knob and the backdrop just decides
what shows through. `blur` is deliberately the recommendation over
`glass`: Liquid Glass is designed as a foreground material, and
whole-window use has a known backdrop-staleness bug on 26.2. Both
respect Reduce Transparency. The backdrop lives outside our drawable,
so `shot` can't see it — the startup log line (`NSVisualEffectView` /
`NSGlassEffectView`) is the observable, same as opacity.

Themes color everything at once — emulator defaults + ANSI 16,
chrome, editor, selection (src/theme.zig, one flat struct). Nocturne
is rook's own (the Claude Design boards): deep indigo grounds,
blurple accent, muted hues. The wails app's semantic theme engine
(runtime swap, VS Code import) is the eventual upgrade path.

## Keybinds

`~/.config/rook/keybinds.toml` — leader chords, tmux-shaped. The
leader arms a pending chord (an accent cell appears in the bar);
double-tap types the leader literally; an unknown chord key is
swallowed. Modified or multi-byte keys never arm or resolve chords.
Loaded at launch (no live reload yet).

```toml
[app]
leader = "`"
"<leader>v" = "pane.split-right"
'"<leader>\""' = "pane.split-down"     # tmux's %/" senses
"<leader>t" = "tab.new"
```

`<leader>1`–`<leader>9` jump to tabs by default (tmux's digits),
`<leader>[` copy mode, `<leader>s` the workspace palette, `<leader>z`
zoom; config lines rebind them like any chord.

**Zoom** (`<leader>z`, `pane.zoom`, ctl `zoom`) gives the focused pane
the whole tab. The split tree is untouched — zoom is a single `?*Pane`
on the Tab, so unzooming is exact by construction rather than by
restoring remembered ratios. Hidden panes get a ZERO rect, which the
draw, the hit test and the resize already read as "nothing here", and
relayout skips them so they keep their grid: no reflow on the way in or
out. Focusing another pane unzooms, because focus must never land
somewhere invisible — but a direction with no pane that way puts the
zoom back rather than spending it on a keystroke that did nothing else.
Splitting unzooms (the new pane has to be visible), and a zoomed pane
whose shell exits clears the zoom with it. The tab chip wears tmux's
`Z`; without it a zoomed tab is indistinguishable from a tab that only
ever had one pane, and the way out is a keystroke you'd have no reason
to reach for.

Canonical action names (the wails keymap's): `pane.split-right`,
`pane.split-down`, `pane.focus-left/right/up/down`, `pane.zoom`,
`tab.new` (alias
`session.new`), `tab.next`, `tab.prev`, `tab.select-1`…`tab.select-9`. Aliases accepted: `app.split.vertical` (=
split-right, the vim `:vsplit` sense) and `app.split.horizontal` (=
split-down). Named chord keys: `TAB`, `SPACE`, `ESC`. `[editor]` is
parsed past and noted — the editor owns its keys wholesale for now
(the app leader is disabled while an editor pane has focus, so
backticks type; ⌘ chords and ⌃HJKL nav still work). Hardcoded ⌘/⌃
chords remain alongside; config overriding them comes later.

## Layout

- `src/main.zig` — subcommand dispatch
- `src/pty.zig` — openpty/fork/exec, libc direct (0.16 std.posix lost these)
- `src/session.zig` — pty + vt.Terminal + reader thread, os_unfair_lock
- `src/panes.zig` — split tree: layout, geometric nav, separators;
  panes hold content (terminal | editor)
- `src/rope.zig` — rope text storage (byte + newline metrics, O(log n)
  line⇄offset), differential-tested against a flat array
- `src/buffer.zig` — document: rope + path + grouped undo
- `src/editor.zig` — the vim-core modal machine; pure model, tested
  headless
- `src/ui.zig` — the UI layer seed: rects + text runs (mono v1; CTLine
  shaping is the upgrade path when tabs/finder need proportional)
- `src/macos.zig` — AppKit window, CAMetalLayer, CVDisplayLink loop, keys,
  the scene (draw_lock serializes; lock order draw_lock → session mutex)
- `src/render.zig` — CoreText ASCII atlas + two instanced Metal passes
- `src/ctl.zig` — the dev socket
- `src/png.zig` — BGRA → PNG via ImageIO

Ghostty is pinned in build.zig.zon at the same commit as the oracle clone
(`~/go/src/github.com/ghostty-org/ghostty`); the `ghostty-vt` Zig module is
the terminal core, `zig_objc` is ghostty's own pin.

## Known debts

Scrollback keeps only ~930 rows — `Session.start` never passes
`max_scrollback`, so it takes ghostty-vt's embedded default of 10,000
bytes where ghostty the app sets 10MB; a one-line fix, but it moves
per-pane memory so the number wants choosing on purpose. Copy mode has
no vim motions or visual-mode yank yet (`/` search and scrolling only).
Cursor is a color swap, input is
cooked NSEvent characters (upgrade path: `vt.input.encodeKey`), no
window-close → quit delegate, grapheme-cluster emoji (flags, ZWJ,
skin tones) render blank — only a cell's first codepoint rasterizes;
the cluster sits in RenderState Cell.grapheme awaiting CTLine-style
shaping — atlas-full policy is clear-and-rebuild,
glyphs render single-style (no bold/italic faces yet — the style flags
are in `vt.Style.flags` when we want them), box-drawing sprite set
covers light/heavy/rounded lines + blocks but not doubles/diagonals
(font fallback).

Pane debts: split ratio is fixed at 0.5 (no drag/resize), no ⌘W
close-pane chord (exit the shell), typing into a pane while
its resize is still settling can lose a line to reflow (transient,
ctl-only in practice).

Lessons that will recur: box/block glyphs are SPRITES, never font
glyphs (edge-to-edge or you get seams); the session must answer
terminal queries (Effects callbacks) or query-and-wait programs like
nvim stall on their response timeouts; never encode a frame
synchronously from a caller's thread — nextDrawable contention wedged
the ctl thread once, so mutations set scene_dirty and let the display
link draw; Style.bg/fg do NOT apply the inverse flag — the fg/bg swap
is the renderer's job (claude code's input cursor is an inverse-video
space, which rendered invisible until fillPane learned this); and the
emulator's dirty tracking is row-CONTENT only — cursor-only moves
(backspace's \b, arrows, DECTCEM hide/show) dirty nothing, so a
frame-skipping renderer must diff the cursor against what it last drew
or the on-screen cursor goes stale.

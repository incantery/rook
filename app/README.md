# rook — native, in Zig, on libghostty-vt

Numbers live in [PERF.md](PERF.md); `./bench.sh` reproduces them.

This IS rook: `make install` puts it at `/Applications/rook.app`. It is
the whole app and the whole CLI — one 2.7MB binary, no daemon and no
companion process. `re` is `rook edit` by argv[0].

> Written while a Go host still stood behind the app. That host, and
> everything it carried — threads, review, asks, attention, transcripts,
> the tree-sitter grammars — left on 2026-07-31. Sections below that
> describe talking to `rook-host` or forwarding a verb to `rookctl` are
> historical. [`../STATUS.md`](../STATUS.md) is the current picture and
> [`../docs/OWED.md`](../docs/OWED.md) is what was removed.
>
> The parts about the renderer, the emulator, panes, the editor, the
> config graph and the e2e harness are all still accurate — that is most
> of this file, and it is why it is worth reading.

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
is what to reach for if the blocking scan ever shows. Measured at the
10MB default (12,408 rows), a full scan is **free** — a needle with few
or no matches finishes inside the ctl round-trip. What costs is the
number of MATCHES, not the size of the buffer: searching `bulk` when
every one of 12,408 rows contains it took ~500ms, because each hit
builds its own tracked highlight. That is a degenerate search, and it
is half a second on an explicit Enter rather than a hang, so the
blocking path stays.

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
`src/editor.zig`). The full key list lives in editor.zig's header
comment, which is the one that gets updated; the shape of it is:
normal, insert, visual, visual-line, visual-block and command modes;
the motions (including `%`, `{`/`}`, `H`/`M`/`L`, `ge`, `f`/`t` and
the `z` scrolls); operators `d y c gu gU g~ > <` with counts, doubled
line forms, and text objects; `.` repeat, `"a` and `"0`-`"9`
registers, `ma` marks, `q`/`@` macros, ⌃N completion; grouped undo
with counts; and an ex line with ranges — `:s`, `:g`, `:m`, `:t`,
`:normal`, `:d`, `:y` and the file commands.

Search and `:s` take vim-magic REGEXES (`src/regex.zig`), searching as
you type, with `&` and `\1`-`\9` in a replacement.

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
debts: case operators are ASCII-only; wide glyphs count one column;
`ctrl-a` reads decimal, not vim's hex and octal; a line past the 64KB
clamp gets its motion and render math clamped with it.

Marks are ANCHORED: they hold a byte offset, and `Buffer.on_edit`
reports every edit — offset, bytes removed, bytes added — so a mark
moves with its text rather than pointing at whatever ends up on line
12. That is one seam on purpose. A position updated by only SOME edits
is worse than one never updated at all, because it is right often
enough to be trusted. Undo and redo fire it too, and a mark inside
deleted text collapses to where that text was rather than being thrown
away. It is also the seam a git gutter and thread reanchoring want.

Registers are `"a`–`"z`, uppercase appending rather than replacing, and
`"_` is the black hole — it takes the text and leaves the unnamed
register ALONE, which is the entire point of it (`"_dd` deletes a line
without losing what you were about to paste). The unnamed register
always gets a copy of every yank and delete, because that is what makes
`p` after any `d` work. A `"a` selection survives exactly one command:
arm it, press a motion that doesn't want it, and it is spent — the
alternative is a stray `"a` leaving the next `x` quietly writing into
register a.

`f` `F` `t` `T` `;` `,` are line-local on purpose — these are the
motions you use to get somewhere you can SEE, and one that silently
walked to the next line would make `dt)` a much worse mistake than it
looks. A find that misses CANCELS a pending operator, so `dfQ` on a
line with no Q does nothing rather than deleting to somewhere
arbitrary. `f`/`t` are inclusive of the landing character for an
operator and `F`/`T` are not (`df,` eats the comma, `dF,` stops at
it), the key after `f` is taken literally so `f2` finds a `2` instead
of counting, and `;` after `t` ADVANCES — the cursor is already parked
one short of the target, so a plain re-search would find the same one
and a `;` that does nothing is worse than useless.

TEXT OBJECTS are the other half of what an operator is for: `iw`/`aw`
(and `iW`/`aW`), `i"`/`i'`/`` i` ``, and the four bracket pairs —
`i(` `i{` `i[` `i<` plus `b`/`B` — each with an `a` form. `i` and `a`
only become object prefixes when something is waiting for a range (an
operator is pending, or you are in visual mode); otherwise they are
still how you get into insert mode.

Words and quotes are line-local; brackets are not, because `di{` over
a function body is the point of having them. Sitting ON either bracket
counts as being inside that pair — the closing case is worth saying
out loud, since searching backward from past the cursor counts that
`)` as a nesting level and hands back the pair OUTSIDE it, deleting
strictly more than you asked for. Brackets inside strings and comments
count, same as vim's own `%`; doing better needs the syntax tree, and
the syntax tree is an optional hook here. Quotes are line-local for a
reason too: an unbalanced quote somewhere above would otherwise make
`ci"` eat half the file.

The rope has no cheap iterator and `copyRange` walks from the root, so
bracket matching scans in 4KB chunks — a per-byte loop would be a tree
traversal per character.

Long lines have a CLAMP (64KB), and getting it wrong used to abort the
app. `ccol` is a byte offset into the real line while `lineText` hands
back a truncated COPY of it, and every helper indexes the copy with
the offset — so a column past the clamp read off the end of a slice.
Two doors reached it in one keystroke: `A` on a long line, and a
backspace joining onto a long line ABOVE the cursor, both of which
assigned the real length. `lineCap` is the single definition of how
far the editor will go and every column derived from a length passes
through it; `prevCpStart` is total in its index as well, so a future
caller that gets it wrong draws a wrong cursor instead of killing the
process with your buffer in it. Typing at the clamp is REFUSED rather
than inserted with the cursor pinned — carrying on would drop every
further keystroke at the same offset in the middle of a line you
cannot see. A clamped line says `[long line]` in the status row,
because rendering it exactly like a line that had ended was the real
defect. 64KB was chosen by measurement, not feel: a file of 40 × 60KB
lines fills at p50 **50µs**, cheaper than a normal source file (1.1ms,
where the cost is tree-sitter, not the copy).

Text is decoded ONE CELL PER CODEPOINT through a single helper
(`decodeAt`), and undecodable bytes become U+FFFD one at a time. Two
bugs lived in not doing that: the status row laid one cell per BYTE
with the byte stored as a codepoint, so `résumé.txt` rendered as
mojibake in the name of the file you were editing; and the obvious
`utf8Decode(s[i..i+1]) catch 0xFFFD` is DEAD CODE, because `utf8Decode`
hands a one-byte slice straight back without validating it — 0xFF came
out as `ÿ`. `cpLenAt` is the single source of how far to advance
(returning 1 for an invalid start byte *and* for a sequence that runs
off the end of the line), so motions, render columns and the grid fill
cannot disagree about where a character ends.

### `:w` cannot lose your file

Saving is the one thing in rook that can destroy work nobody can get
back, so `Buffer.save` holds three properties, each of which was
absent and each of which is unit-tested by reverting it:

- **Atomic.** It was `writeFile`, which truncates in place — a crash,
  a full disk or a cancelled write halfway through leaves HALF a file
  where the source used to be, original gone. It now writes a sibling
  temp file and renames over the target, so the path holds the old
  bytes or the new ones and never a prefix of either.
- **Permissions survive.** Rename-over installs a NEW inode, so the
  mode has to be carried across by hand; truncate-in-place got this
  for free, which is exactly why nobody would notice until `:w` handed
  a shell script back non-executable.
- **Symlinks are written through, not replaced.** Renaming over a link
  turns it into a regular file — how a dotfile linked into a repo
  quietly stops tracking the repo.

And the guard that matters most here specifically: **`:w` refuses to
overwrite a file that changed underneath it.** rook's premise is that
agents are editing your files while you look at them, so "somebody
else wrote this since you opened it" is the normal case, not a corner
one. The buffer records (mtime, size, inode) at load and after each
save; a mismatch refuses the write and names both ways out — `:w!`
keeps yours, `:e!` takes theirs — because which one you want is not
something the editor can know. Deletion counts as a change: writing
would resurrect content somebody removed on purpose. No claim (a
scratch buffer, or a path that did not exist when you opened it) means
no refusal.

The stat happens BEFORE the read at load, and the order is the whole
point: a write landing between the two calls is recorded as either
newer than the bytes we hold (`save` then overwrites it silently) or
older (`save` refuses over content that was in fact current). Only the
second failure is survivable, and it costs one `:w!`.

The dirty marker is a SAVE POINT, not a flag. A stored bool can only
ever be set, so `u` all the way back to what was on disk still showed
`[+]` and still refused `:q` — which teaches the `:q!` reflex, and the
person with that reflex is the one who will `:w!` past the guard
above. Edits carry a sequence number that rides through undo and redo,
so the number on top of the undo stack identifies the buffer's content
STATE rather than how much has happened to it. `version` stays
monotonic and separate: the highlighter wants "something happened",
never "we are back where we were".

### Following a file that changes under you

`:w` catching a conflict is the last line, not the only one. One stat
per editor pane on the existing 1Hz tick asks whether the file moved,
and the two cases split by who has something to lose:

- **Unmodified buffers reload**, keeping cursor and scroll. You have no
  edits, the file is the truth, and landing back on line one every time
  an agent touches the file would make the pane useless for the thing
  it is most useful for — watching.
- **Modified buffers only say so**: `[!]` beside your `[+]`. Merging is
  yours. The only outcome worse than showing something stale is
  reloading over an edit.

Every pane in every space, not just the visible one — a background tab
holding a stale buffer is exactly the one you would not think to
distrust when you come back to it. It dirties the scene only when
something actually changed, so zero-idle-frames holds: measured at 0
frames drawn across 6 idle seconds with an editor pane open.

### The regex engine backtracks on purpose

`regex.zig` is a small vim-magic engine behind `/`, `?`, `n`, `*`, the
search highlight and `:s`. It backtracks rather than simulating a
Thompson NFA, which is the slower choice and the right one here:
captures are most of the point. `s/foo(\(.*\))/bar(\1)/` is the thing
people actually want out of a substitute, and a Thompson simulation
gives you a yes/no.

What backtracking costs is held off in two places. A repeat of a
SINGLE-WIDTH atom — `.*`, `[a-z]\+`, `x\{2,5}` — compiles to one
instruction with an internal greedy loop, so scanning a long line
costs no stack at all; only group repeats and alternation recurse, and
those are short in real patterns. And every match attempt runs on a
step budget that fails closed. `\(a\+\)\+b` against thirty a's with no
`b` has 2^29 ways to split them; with the budget it returns nothing in
microseconds, and without it the test does not finish in ninety
seconds. That is what the vacuity check for it measures.

Two zero-width traps are worth naming, because both of them hang rather
than misbehave. `:s/x*//g` matches empty, writes nothing, and would sit
at the same offset forever; so would the search highlight on `/x*`,
inside the render loop. Both advance by one when the match is empty,
and both have a test that hangs if you take the guard out.

### Real vim as the oracle

Vim ships with macOS, so the expectations in these tests are taken from
it rather than from memory: write the buffer to a temp file, run
`vim -Nu NONE -c 'normal <keys>' -c wq`, and read back what it did.
Two bugs came out of doing that instead of guessing.

`d%` measured from the BRACKET rather than the cursor, so `d%` sitting
a few characters before an open paren left those characters behind —
vim takes them.

`ge` is the first inclusive motion in this editor that runs BACKWARD,
and the operator path had been adding the inclusive byte to the target
end before taking min/max. That is right for `e`, where the target is
the far end, and wrong for `ge`, where the cursor is: `dge` deleted the
gap BETWEEN the two words instead of the span covering them. The bump
belongs to whichever end is far from the cursor, which is a sentence
worth keeping the next time a backward motion lands.

The method scaled further than one-off expectations. Where a behaviour
is a TABLE rather than a rule, the table itself is generated from vim
and pasted in as data: 45 `ctrl-a` cases, and the whole Unicode case
map, read out of vim by driving 13k codepoints through `gUU` and `guu`.

Which is where the sharpest lesson came from. Vim has more than one
answer, and the convenient source is not always the one you are
imitating: `toupper("ß")` is `ß`, but `gU` on `ß` is `ẞ`. They use
different tables. A case map built from the builtin would have been
wrong at the first character anyone would test. Ask the FEATURE you are
copying, not the function that sounds like it.

### The block is render columns, and `A` pads where `I` skips

`ctrl-v` measures its rectangle in RENDER columns rather than bytes, so
a tab in the middle of one line does not knock the block out of
alignment with the line above it. Each row resolves its own byte span
from its own text, which also means the order rows get edited in does
not matter — the usual worry with a multi-line edit, and worth saying
out loud because it is not obvious from the loop.

The one asymmetry worth knowing: block `A` PADS a line too short to
reach the column, and block `I` SKIPS it. Both are vim's, and the
reason holds up — appending to a short line is a request to reach that
far, while inserting into one is a request to insert at a position that
is not there. A blockwise paste pads for the same reason, and grows the
buffer rather than dropping rows off the bottom: losing half a paste
silently is worse than gaining a line.

### Case operators cost three letters

`gu`, `gU` and `g~` are not a new mechanism. The pending-operator field
already meant "some operator is waiting for a range", so it grew three
more letters and the two places that consume a range — the charwise
one and the linewise one — learned to transform instead of delete. That
buys `gUiw`, `gu}`, `` g~`a ``, `gUf,` and every other combination
without any of them being written down anywhere.

They leave the registers alone, which falls out of the same place:
nothing came out of the buffer, so there is nothing to put anywhere.

Case is per CODEPOINT now (`unicase.zig`), and the byte length moves
under it: `İ` is two bytes and lowercases to a one-byte `i`, `ß` is two
and uppercases to a three-byte `ẞ`. So the walk rewrites a chunk into a
second buffer and carries the range's end along by the difference,
rather than the old in-place trick that relied on one byte for one byte.
Chunk boundaries never cut a codepoint in half.

### `.` records the result, not the keys

`.` repeats the last change, and the thing worth writing down is how it
decides what a change WAS. Every key that arrives in normal or visual
mode starts (or extends) a recording; when nothing is half-typed
anymore — no pending operator, count, register, object or find — the
recording ends, and it is kept only if the buffer's version moved
while it ran.

That is the whole rule, and it is a rule about results rather than
about keys. `w` and `yy` leave the dot alone because they change
nothing. `cwfoo<esc>` and `vjd` become the dot because they do, with
the insert-mode keystrokes and the ESC recorded along the way — the
replay just types them again. Nothing in this file maintains a list of
which commands count as changes, which is precisely the list that goes
stale the next time an operator is added.

Three keys are excluded by name, because they move the buffer without
being changes of their own: `u`, ctrl-r and `.` itself. And a count
given to `.` REPLACES the recorded one — `3dd` then `5.` deletes five
lines — which is the only reason the replay bothers splitting the
leading digits off the recording.

### Indentation the file decides

`o`, `O`, `cc` and Enter inherit the leading whitespace of the line
they came from, VERBATIM — bytes copied, not a width recomputed — so a
buffer keeps indenting the way it already indents without a setting
saying which way that is.

`>>` and `<<` (counts, `>j`/`>k`, and `>`/`<` over a visual selection)
work in COLUMNS rather than bytes: the existing indent is measured with
tabs snapping to their stop, one `tab_width` step is added or removed,
and the result is respelled in whatever the buffer indents with. That
last part is why `<<` does something sensible on a line someone
indented with a mix of both. The currency is detected from the buffer —
first indent byte per line, counted until 200 indented lines have been
seen, so a Go file that opens with a licence header and an import block
is still a tab file. rook's own tree has Zig and Go side by side, so a
setting would be wrong in one of them no matter which way it pointed.

Two things are deliberately timid, and both are about diffs:

- **Blank lines don't shift.** Nobody wants a review comment about
  whitespace on an empty line.
- **An indent you never typed on is taken back.** Press `o`, change
  your mind, press ESC, and the line is empty rather than a line of
  trailing spaces. It fires only when the line is still EXACTLY the
  whitespace the editor put there — one typed character, one
  backspace, one paste, and those bytes are yours. Code that deletes
  text on a guess is code that eats someone's line. Holding Enter
  keeps handing the indent forward while leaving nothing behind on the
  lines you skipped, which is vim's behaviour and the reason for it.

The e2e (`indent`) asserts on DISK, because trailing whitespace is
invisible on screen and obvious in a diff — the worst combination for
something to ship unnoticed.

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
⌃N/⌃P, Enter, ESC. The list is the environment graph — `workspace`
nodes (name + root, `~/` expanded), declared by the config program like
everything else and re-read each open, so it always reflects what
config last applied (a machine with no graph just gets an empty
palette). This was ~/.local/share/rook/rook.db through libsqlite3
until 2026-08-03: the db's last writer left in the strip, and a
registry nobody can write is not a registry — recency ordering went
with it, owed back as ephemeral state. Worktree children came back
DERIVED the same day: each declared workspace's `.git/worktrees/`
records are read live, so children sit indented under their parent as
`rook/zig` (filter matches the combined name) with nothing stored and
nothing to go stale — `ctl worktree add|remove` are the write half,
with rook refusing unmerged commits and git refusing a dirty checkout
in its own words. Enter attaches
the workspace's session — existing space switches in with its tabs
intact, first visit creates it with one shell in the root. Inside a
space, cd stays sacred: tab chips wear the name of whatever workspace
their shell is actually IN (`1 zig · shell`), resolved from the cwd
at the 2Hz HUD tick. ctl: `workspaces`, `palette-open`, `palette`
(state dump — the modal is blind-drivable through the normal
type/press verbs); `tabs`/`panes` list all spaces.

## Side panes, and the attention inbox

A slottable left/right container — **the container every §2 panel lands
in** — with the attention inbox as its first tenant. `<leader>a` or
`attention.inbox`; `panel.flip` moves it to the other edge.

It was built WITH a tenant on purpose. "Primitives pulled by tenants,
never speculative" is the rule the whole UI layer grew under, and a
container validated against nothing is a guess about what §2's panels
will need.

What makes it a real container rather than a slab painted over the
panes: opening it **retiles**, so the terminal beside it gets a new
column count and a pty resize. The e2e asserts exactly that — `grid CxR`
from `panes` must narrow — because a decorative overlay would pass every
other check.

- **Width is in COLUMNS, not pixels** (`side_cols`), snapped to whole
  cells, so the pane beside it still lands on the character grid at any
  font size. Capped at half the window: a side pane that can squeeze the
  panes to nothing can lose you a shell.
- **It is window chrome, not a tab's.** Full content height, same inbox
  from every tab, and it never appears in `panes`.
- **Tenants are placement-agnostic** — `drawAttention` takes a rect and
  never learns which edge it came from, so `panel.flip` is a property of
  the container.
- **The tenant is an enum + a switch**, exactly like `pal_mode`, not a
  vtable. A tenant interface designed against one tenant is a guess; the
  switch is where the inbox/deck/threads/review join it.

The inbox itself (`src/attention.zig`) is a projection of the host's
`GET /attention`, shaped after `usage.zig` and fail-open the same way.
Two things it is careful about:

- **"Nothing waiting" and "host unreachable" render differently.** An
  empty list because the daemon is down would read as good news, which
  is the worst possible lie for this particular panel.
- **Idle frames stay 0.** It polls every 2s, but ONLY while open, and a
  fetch dirties the scene only when a digest changes. A poll that
  repainted unconditionally would cost 30 frames a minute forever —
  measured after the fact: 6s open, `n=0` on every frame ring.

Overflow is never silent: rows dropped for want of height and rows
dropped by the 16-item fetch cap both surface as `+N more`.

Not done: **acting** on a row. Jumping to the session and answering the
ask need `/agents/{id}` verbs and a form renderer — §2's asks item. The
inbox lists today.

## Review (`src/review.zig`)

`<leader>g` — the changes list and **the gate**. A review is a RookTask
parent whose children are anchored FINDINGS: each carries a path, a line
range, a summary and a state, and the gate is a pure function of those
states (approved and deferred clear; proposed, rejected and
conversation-pending block).

- **The gate leads**, in the accent colour when ready and the error
  colour when not. It is the answer to the only question this panel
  exists for: can I ship this yet.
- **Blocking findings sort first, riskiest first**, stably — a poll
  cannot move the row under your cursor mid-triage.
- **`a` / `r` / `d` are single letters** and the cursor advances
  immediately, without waiting for the round trip. Triaging 52 findings
  pays every extra keystroke 52 times.
- **Enter opens the file at the finding's line** — using `currentStart`,
  the stored range re-anchored onto today's file. Jumping to the line it
  was *written* against would land on whatever has since moved into its
  place.
- `State.blocks` mirrors the host's `reviewBlocking` exactly. A client
  that disagreed would render a gate the host will not honour, which is
  the worst way this panel could be wrong.

**On the diff surface.** PARITY listed review as blocked on one. It
turned out not to be: a finding says *what* is wrong and *where*, and
rook already opens a file at a line — so the thing standing between you
and a verdict was never the diff. A side-by-side view is a nicer way to
read a change and it is still worth building; it just was not the
prerequisite it looked like.

## Threads (`src/threads.zig`)

File-anchored conversations, projected as **editable buffers**.
`<leader>t` lists the active space's workspace threads; Enter opens one
as `thread:{id}`. `:w` saves your draft, and `:ThreadNote` /
`:ThreadAsk` / `:ThreadResolve` reach the host through the ex-command
bridge — which is what that bridge was built for.

The host keeps truth structured and hands out a document: rendered
history, a scissors line, your draft below. Two parts of that contract
are load-bearing for any client:

- **The prefix is `content` minus `draft`, computed exactly** — never by
  scanning for the scissors line, because a comment body could legally
  contain a scissors-shaped line. The host returns `draft` alongside the
  doc precisely so the arithmetic is possible.
- **A 409 is not an error, it is a concurrent agent reply.** The host
  answers with the fresh doc; rook splices its tail onto the grown
  history and re-saves. History is append-only, so this always merges.

`Editor.app_save` is the seam — the same function-pointer shape as the
highlighter and the ex-command bridge, so `editor.zig` still knows about
buffers and not about what is on the other end of one. The buffer NAME
carries identity (`thread:42`), so which thread a save belongs to is a
property of the pane rather than an "open thread" on the App that a
second pane would fight over.

Two things real data taught, neither visible in a sandbox:

- **Anchors are multi-line.** An anchor is a span of source, and pasting
  a newline into a single-row list breaks the row. `setOneLine` collapses
  whitespace runs.
- **An undelivered thread gets its own mark.** `deliverError` means the
  thread is open and submitted but *nobody was told* — the one failure
  the old model rendered as a normal wait.

## The session view (`src/transcript.zig`)

Enter on a deck row opens that agent's transcript **as a buffer**. That
is the whole design: rook's editor is already a renderer with scrolling,
search, motions and yank, so a timeline becomes a document rather than a
bespoke viewer. `Editor.openText` is the seam, and `synthetic` marks a
buffer with no file behind it so `:w` refuses. The same simplification
threads will want.

`GET /agents/{id}/transcript` serves whole records; rook takes the last
200 and says so when older ones exist. Records render as
`── assistant · model ──` headings, `⚒ Tool <what it names>` for calls,
`→` / `✗` for results, and `· thinking` for blocks Claude Code writes
with an encrypted signature and no text.

Three judgement calls that make it readable:

- **A tool result is not attributed to the user.** Claude Code sends
  results back as `user` records; heading them "user" makes a build log
  read as something the human said, which is the one thing this view
  must not get wrong.
- **Tool inputs show what they NAME**, not their whole payload — the
  input is often a file's entire new contents, which would bury the
  conversation in the thing it was about.
- **Results are clipped to six lines** with a `…`. The transcript is for
  seeing *what came back*, not reading it in full.

**Found while building this, and it would have bitten every later
panel**: `hostc` did not decode `Transfer-Encoding: chunked`. Go switches
to chunked once a response outgrows its write buffer, so `/usage`,
`/attention` and `/agents` all worked and the first big response did not
— and the symptom was a JSON parse error, which reads as "the host sent
garbage" rather than "we failed to decode it". `hostc.dechunk` has its
own test root now.

**Also found**: `shot` never dirtied the scene, and this app draws
nothing when idle. A screenshot of a quiet screen therefore never
happened — it timed out, and because the request stayed armed, every
later shot answered `err busy` for the life of the process. Both halves
are fixed; it made the agent-visibility story unreliable in exactly the
situation you would use it.

## The agent deck (`src/agents.zig`)

Every claude session rook can see, at once. `<leader>v` or `agent.view`.
`GET /agents` is agentwatch's snapshot — the host tails Claude Code's own
jsonl transcripts and keeps a state per session. Unlike the asks loop
this needed **no host change**: the endpoint is plain HTTP and assumes
nothing about session sockets.

The deck is the **navigation** surface — which agents exist, what each is
doing, and a way to get to one. The rendered transcript timeline is a
separate and much larger build (PARITY §2).

- **Ordered by what needs you**: needs_input, then working, then quiet.
  The sort is *stable* within a rank, so the row under your cursor does
  not move when a poll lands.
- **Opens FOCUSED**, unlike the inbox. It is a list you navigate and pick
  from, so handing it the keys is the action you asked for. ESC yields
  them back **without closing** — you want to keep looking while you work.
- **Enter goes there**, through the same `jumpToCwdLocked` the ask form's
  ⌃G uses. Panes are not host sessions, so a shared directory is the only
  correspondence there is; one notion of "go there" means the two cannot
  drift apart.
- **Rows are named workspace-relative**, not by the last path segment.
  An agent in `rook/app` read as "app" in the first version — true, and
  useless, since every repo has one.
- Same two rules as the inbox: "no agents running" and "host unreachable"
  render differently, and the poller only runs while the panel is open
  and only dirties on a digest change.

The wire mapping is pinned by a test against a **real captured `/agents`
response**, so a field renamed upstream fails a test instead of showing
up as a silently empty deck.

## The asks loop (`src/asks.zig`)

Claude asks a question, a human answers, the asker unblocks. `rookctl
ask` (and the MCP `ask` tool behind it) POSTs questions; the form takes
the side pane and the key path; Enter posts the answer and the blocked
asker exits 0 with it on stdout. ESC posts `{"canceled":true}` and the
asker exits 1.

**rook polls for asks; it is not pushed them.** The original flow pushes
a `msgAsk` onto the asking session's wire-v3 frame socket and 409s when
nothing is attached — "a question needs a screen to land on". That
assumes an app holding session sockets, which this one deliberately is
not: it owns its ptys in-process, registers no sessions, and
`$ROOK_SESSION` is unset in its shells, so **both halves of the old path
were unreachable from here**. The host gained a session-less queue
(`POST /asks`, `GET /asks`) and rook polls it the same way it polls
`/attention` and `/usage`. Session-scoped asks are untouched: they still
push, still 409 without a screen, and the queue deliberately omits them
so an app holding both paths cannot double-render one.

The tradeoff, stated plainly: a queued ask is **app-global rather than
pane-scoped**. With one window that is invisible; a second window is the
moment to revisit it.

Things worth keeping if this is ever rewritten:

- **`recommended` is load-bearing.** Pre-ticked in multi, under the
  cursor in single, so Enter alone is a complete answer to a well-formed
  ask. The e2e asserts it.
- **The Other row is always there**, so nobody is forced to pick from
  options that miss the point. Typing anywhere jumps to it — and picking
  your own words is *not* also picking an option, so `selected` stays
  empty and `other` carries the text.
- **A dismissal is a real answer.** ESC posts `{"canceled":true}` rather
  than going quiet, because silence leaves `rookctl ask` blocked until
  someone kills it.
- **JSON escaping is not optional.** A stray quote in a label produces a
  body the host rejects, which loses the answer and blocks the asker
  forever. `asks.zig` has its own test root for this.
- **Answering never blocks the key path.** The form queues a body and a
  poster thread does the HTTP.
- **ctl `ask <json>`** puts a question on screen without a host, through
  the same parse the poller uses — the role `paste <text>` plays for the
  pasteboard. **`ask-answer`** reports the last body the form produced,
  which is the thing worth asserting on.

### Provenance and ⌃G

A queued ask has no session to derive provenance from, so the asker
carries **its cwd** — the one fact it always knows — and rook resolves
the rest from it: which workspace contains it (the form says `from
rook/zig`), and which pane is sitting in it.

**⌃G jumps there.** With no host sessions to jump *to*, the link back is
the asker's cwd against each pane's shell cwd, read from the kernel.
Best match wins — an exact directory beats a parent, a deeper parent
beats a shallower one — so the pane the agent is actually running in
outranks a shell parked at the repo root. It does **not** dismiss the
question: you jump to look at what is being asked about, and the form
has to still be there when you look back.

Three things that only showed up against a real host, and that a
harness with no daemon structurally could not catch:

- **`realpath` first.** `paneCwd` is the kernel's already-resolved path;
  an asker under `/tmp` (a symlink to `/private/tmp` on macOS) reports
  the unresolved one. Without normalising, the prefix match silently
  never fires and ⌃G looks like it does nothing.
- **The app must ACK.** `rookctl ask` short-polls for an ack and gives
  up after 5s with "the app didn't pick up the ask — old rook version?".
  The push path acked from the frame handler; a polling client has to do
  it explicitly, or the asker dies on its deadline while the human is
  still reading the question.
- **A stepped-away question must be recoverable.** The form holds the
  ask while open, so the poller will not offer another one — switching
  panels or jumping to source without a way back leaves the question
  alive but unreachable, and the asker blocked with no way to answer.
  `ask.show` / `<leader>q` brings it back.

Not done: the ask still cannot name the *agent* (as opposed to the
directory) — that needs `/agents/{id}` verbs.

## The command registry (`src/registry.zig`)

Every action rook can take is a named command, in one table. **⌘K**
opens the command palette over it — the same widget as the workspace
picker, switched by `pal_mode`, so the filter, key handling and drawing
are shared and only the row text and what Enter does differ.

The point is that four surfaces agree through one table:

| surface | how |
|---|---|
| leader chords | config binds a name; `registry.specFromName` resolves it |
| ⌘ chords | `⌘D`/`⌘T`/`⌘W`/`⌘K`/`⌘1-9` all go through `dispatch` |
| the palette | lists the table, Enter dispatches |
| ctl / agents | `commands` lists, `run <id>` runs |

`App.dispatch` is the ONE switch over `Action`, which is what keeps the
table honest — adding a value fails the build until it is handled. The
⌘ chords used to call App methods directly; routing them through
`dispatch` is what makes them reachable from the palette and `run`.

Aliases live apart from the table (`session.new` → `tab.new`,
`resize-pane -Z` → `pane.zoom`) so the palette never shows one
capability twice, while a config written in tmux's or the wails keymap's
vocabulary still parses. `tab.select-N` is parameterized rather than
nine rows, and is bindable but hidden from the palette.

Ex-names are derived, not written: `pane.split-right` → `PaneSplitRight`,
capitalizing each segment, which lands on vim's user-command shape.
`commands` prints them, and the editor's `:` accepts them — `:PaneSplitRight`
in an editor pane splits it.

The bridge is a function-pointer hook (`cmd_ctx` / `app_command`), the
same shape and the same reason as the highlighter's: `editor.zig` stays
a pure model that headless tests drive with both hooks null, and never
learns what a command is. It sits in `execCommand`'s FALLTHROUGH, gated
on a leading capital — so no derived name can shadow `:w`, `:q` or
`:noh` **by construction** rather than by a list someone has to
maintain, and a lowercase typo still gets the editor's own message
instead of a confusing miss from the registry. An unknown CamelCase name
reports `not a command`; the editor's `not an editor command` is
reserved for its own namespace.

**GOTCHA, and the reason `pending_cmd` exists:** the palette's key path
runs holding `draw_lock`, and every dispatch target takes it again
(`newTab`, `selectTab`, `splitFocused`, …). Dispatching inline from
Enter is a self-deadlock. The palette queues the command instead and the
three places that release the lock drain it — `writeFocused`, ctl's
`writeTarget`, and `drainPendingCmd` itself. The e2e `commands` scenario
drives Enter through the socket specifically to keep that path honest;
if it ever times out rather than failing, suspect this.

A command is not registered until it does something. The ~15 remaining
names in PARITY §1 (`attention.inbox`, `review.changes`, `threads.toggle`,
`file.open`, …) arrive with their features — dead palette rows would
make the palette lie about what the app can do.

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

### The chrome's spatial system

`ui.Metrics` holds every distance the chrome spaces itself by — gutter,
pane padding, row height, gap, radius, elevation — derived once per
resize from the backing scale and the cell box. Points, not cells, for
anything that reads as an EDGE: an edge belongs to the window, not to
the text inside it. Before it existed the bars inset themselves by one
CELL, so the gutter moved with the font size while nothing else did,
and the numbers were computed in two places that had to agree by hand.

Panes inset their GRID from their BOX (`gridOrigin`): the box still
fills, tiles and hit-tests, only the cells move. It is one function
because four sites map pixels to cells — draw, click, cursor, resize —
and three of them agreeing is a bug you find with the mouse.

`drawRoundRect` is one signed-distance field doing three jobs: inside
it is a fill, a band at the edge is a border, a falloff outside it is a
shadow. Chips, selected rows and the palette card are all quads on the
same encoder as the grid — a widget is still never its own draw path.

Two gotchas that cost real time here:

- **Metal aligns `float4` to 16 bytes; Zig aligns `[4]f32` to 4.** A
  mixed uniform struct develops padding holes on one side only, and the
  first version of the rounded-rect pipeline drew *nothing* because
  `rect` landed 8 bytes early. `RRUniforms` is all-`float4` with a
  `comptime` offset assertion.
- **The bg pipeline does not blend.** `ui.text` lays a background cell
  under every glyph, edge to edge, so drawing it on a pill crops the
  corners off — and at alpha 0 it punches a hole. Anything sitting on a
  painted shape uses `ui.textOver`, which runs the glyph pass alone.

### Draw-under: a card behind the character grid

The encoder is immediate-mode, so call order IS z-order, and the chrome
draws AFTER the grids. That is the right layer for a modal — the palette
carries its own text with `textOver` — and the wrong one for anything
the grid has to sit on top of.

The completion menu is the case that needed the other direction. It
wanted Zed's rounded card, but moving it into the chrome would have cost
it its place in `ctl dump` and every assertion that reads it. So there
is one draw-under pass, between the pane background rects and the pane
grids, and the menu's cells carry `flag_no_bg` — bit 2, which
degenerates the quad in `bg_vs` rather than writing a transparent one
(this pass does not blend; alpha 0 is a hole, not a pass-through). The
editor publishes `cpl_geom` in CELLS and `completionCardRect` turns it
into pixels, once, for both the drawer and `ctl lsp`.

Three constraints fall out of the ordering, and they are not
negotiable:

- **The card cannot overhang its cells.** The buffer cells around it
  draw afterwards and paint their own backgrounds, so a halo is simply
  erased. Padding goes INSIDE the box — its blank first and last row and
  column — which is why they are in the box at all.
- **No shadow.** Same reason: elevation paints outside the rect.
- **A dump must not republish render geometry.** `dumpText` runs a fill
  at whatever size the caller asked for, and rook draws zero idle
  frames, so the stale coordinates would stand until the next keystroke.
  It saves and restores `cpl_geom` around the fill.

The documentation panel beside the list is the second tenant, on its own
card. Two things about it are worth keeping:

- **Where the prose comes from is the server's choice.** zls puts
  `documentation` in the completion list; gopls and rust-analyzer leave
  it out — computing prose for two hundred rows to show one is work
  nobody wants — and attach an opaque `data` for a
  `completionItem/resolve`. Both paths land in the same place. The item
  is kept WHOLE for that resolve (`Completion.raw`), because the
  protocol resolves an item and the server keys on its own `data`;
  anything reconstructed from the parsed fields comes back unresolved.
  It is kept only when the server advertised `resolveProvider`.
- **The resolve is asked from the SELECTION, never from a fill.** A fill
  runs under the draw lock and is also what `ctl dump` runs, so asking
  there would put a request behind an inspection. One is in flight at a
  time, latched on the WORD rather than a bool, so a dropped answer
  cannot wedge it — and the answer is matched back by word too, since
  the ring is rebuilt by every narrowing keystroke and an index would
  name a stranger.

The border this replaced was box-drawing arcs, `╭─╮│╰╯`. They are the
right box in a text file and the wrong one on a screen: at a cell's size
an arc is a two-pixel curve, and the font squares it off into the exact
corner it was drawn to avoid. `drawBoxLines` maps them to sharp corners
on purpose, and that is honest — a rounded corner is not a glyph
problem.

`ui.clip` fits a string to N cells with an ellipsis. Text that simply
stops reads as a rendering fault; "…" reads as "there is more", which
in a 34-column side pane is the truth most of the time. It counts
codepoints, so a cut cannot leave half of one for `initUnchecked` to
iterate.

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
printf 'commands\n'          | nc -U /tmp/rook.sock   # the registry: id, title,
                                                       #   key hint, :ExName
printf 'sidepane\n'          | nc -U /tmp/rook.sock   # container state + the
                                                       #   tenant's rows (chrome
                                                       #   is invisible to dump)
printf 'run pane.split-right\n' | nc -U /tmp/rook.sock # by name; aliases resolve
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

## e2e (`make e2e`)

The socket above is per-command. `app/e2e/` is the suite around it — the
replacement for the Playwright harness the cutover deleted, and the
answer to "verify it yourself before asking Seth".

```
make e2e                 # all scenarios (~2s)
make e2e ARGS=splits     # one, substring match on the name
make e2e-clean           # remove sandboxes a failing run kept
```

Every scenario spawns its **own** instance — own ctl socket, own config,
own `XDG_*`, own `HOME`, `/bin/sh`, and no rook-host. Scenarios cannot
see each other's tabs, panes, or shells. That is not fastidiousness: the
webview suite leaked a workspace out of one failing spec and the live
session it left behind broke unrelated renderer specs, which read as
renderer regressions for a while.

Three things the harness does that are worth keeping if it gets rewritten:

- **`start()` proves a shell is executing before any scenario types.**
  It waits for a prompt, then round-trips an `echo <marker>`. Waiting for
  the prompt alone is not enough — the pty accepts bytes the shell has
  not read yet, and that race is what made the old suite flake on a cold
  sandbox.
- **The sandbox owns `HOME`, and that is what sets `PS1`.** rook starts
  LOGIN shells, so `/etc/profile` runs and overwrites an inherited `PS1`
  before the first prompt is drawn. `~/.profile` is sourced after it, so
  the sandbox's own `.profile` is the only hook that wins. (Found by the
  first scenario failing with the developer's real hostname in the
  prompt.)
- **Screen matching joins the rows.** A pane wraps at its width, so
  `total` can land as `t` + `otal` and a naive grep reports a stall that
  is not happening — see the 15-minute lesson above.

A failing run keeps its sandbox and prints the path: the app's own
stdout/stderr is in `app.log` there, which is the difference between "a
config typo on line 3" and "every assertion timed out for no reason".
A passing run deletes them.

`shot` is decoded, not just written — `harness.zig`'s `Shot` reads the
PNG back through ImageIO, so pixel assertions are real. `distinctColors`
is the cheap one: a frame that drew nothing is one colour.

Deliberately **not** in `zig build test` and not in CI. It needs a window
server, a Metal device, and real shells; CI's value is being fast and
never flaky, and this is neither. The pure models — rope, editor, paste,
config — have headless suites that do run there.

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
scrollback = "10mb"      # per pane, in BYTES; kb/mb/gb suffixes or a
                         # bare number. 0 = none at all. Relaunch to
                         # take effect. (ghostty's scrollback-limit
                         # spelling is accepted.)
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
- `src/ui.zig` — the UI layer seed: the metrics, rects, rounded rects,
  shadows and text runs (mono v1; CTLine shaping is the upgrade path
  when tabs/finder need proportional)
- `src/macos.zig` — AppKit window, CAMetalLayer, CVDisplayLink loop, keys,
  the scene (draw_lock serializes; lock order draw_lock → session mutex)
- `src/render.zig` — CoreText ASCII atlas + two instanced Metal passes
- `src/ctl.zig` — the dev socket
- `src/png.zig` — BGRA → PNG via ImageIO

Ghostty is pinned in build.zig.zon at the same commit as the oracle clone
(`~/go/src/github.com/ghostty-org/ghostty`); the `ghostty-vt` Zig module is
the terminal core, `zig_objc` is ghostty's own pin.

## Known debts

Copy mode has no vim motions or visual-mode yank yet (`/` search and
scrolling only).
Cursor is a color swap, input is
cooked NSEvent characters (upgrade path: `vt.input.encodeKey`), no
window-close → quit delegate, a terminal splits flags/ZWJ/skin-tone
sequences across cells because the emulator only clusters those under
mode 2027 and does not enable it (combining marks DO cluster, and both
surfaces shape them with CTLine) — atlas-full policy is
clear-and-rebuild,
glyphs render single-style (no bold/italic faces yet — the style flags
are in `vt.Style.flags` when we want them), box-drawing sprite set
covers light/heavy/rounded lines + blocks but not doubles/diagonals
(font fallback).

Pane debts: split ratio is fixed at 0.5 (no drag/resize), no ⌘W
close-pane chord (exit the shell), typing into a pane while
its resize is still settling can lose a line to reflow (transient,
ctl-only in practice).

Lessons that will recur: a VACUITY CHECK must confirm the build
SUCCEEDED and the right test FAILED — `zig build test` prints a
"failed command" line on a clean run (a test writes to stderr) and
prints a per-root error count when a root does not compile, so
grepping for a test name alone reports "no failure" for a mutation
that never got compiled. That produced a false all-clear twice in one
session, and the second time the redundant branch it was hiding turned
out to have a real bug next door;
a vacuity check can ITSELF be vacuous, and the tell is a mutation that
compiles and changes nothing — swapping which character's LENGTH is
measured is invisible in ASCII, a paste at column zero never needs the
padding branch, a move to the end of a three-line file lands where the
clamp would have put it anyway, and matches on lines 1 and 3 of a
five-line buffer are the same match forwards and backwards. When a
revert produces no failure, the first suspect is the test, not the
guarantee — and a mutation that breaks the BUILD (an unused variable,
an unreachable branch) is not a check either, it is a retry;
a mutation is also the only thing that catches a test you never wrote:
a bound that survived being cut to a quarter turned out to have no test
behind it at all, and the search-highlight one had covered exactly the
case the cursor was already painting over;
a PERFORMANCE guarantee should be asserted as a COUNT and not a
stopwatch — a wall-clock threshold is flaky on a loaded box and says
nothing about what went wrong, whereas counting bytes copied per frame
named all four callers that were pulling a whole line in to ask one
question about it;
when copying another program's behaviour, ask the FEATURE and not the
function that sounds like it — vim's `toupper()` and its `gU` operator
use different tables and disagree about `ß`;
when a pixel assertion will not separate two builds, suspect the
MEASUREMENT before the feature — four attempts at one failed in four
different ways (a peak row that is equally inky either way, a band
diluted by surrounding text, and a signal that was measuring the typed
command because `waitText` matched the sentinel inside the command it
had just typed, so the screenshot preceded any output);
a RENDER bug can hide behind a green model: shaping a grapheme cluster
left the graphics context's text matrix behind it, so every plain glyph
rasterized afterwards drew outside its slot and neighbouring characters
silently stopped appearing — the cell grid was correct the whole time,
which is why the e2e for it asserts on pixel density and not on text;
NEVER call into a framework that synchronises
with the display-link thread while holding draw_lock — the query waits
for that thread, and that thread is in `drawNow` waiting for the lock,
which wedges every thread in the app behind it (a `sample` of a hung
instance is what showed this; the link answers on its own thread now
and nothing under the lock does more than read an atomic);
box/block glyphs are SPRITES, never font
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

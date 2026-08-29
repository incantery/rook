# Surfaces and state — the plugin seam

> Status: the **state feed (out) is built and shipping** — see the
> section below and `statefeed.zig`. Of the plugin protocol (in), one
> frame is built: **`items.push`**, which is what feeds the side rail
> — the mux holds one opinion about what that rail says, and only one:
> a pane running an agent nobody claimed gets a row of its own
> ([Agents rook finds by itself](#agents-rook-finds-by-itself)).
> Declared surfaces, placement, focus and plugin *processes* are still
> design. What *does*
> exist is inventoried in [What is real today](#what-is-real-today),
> and most of this document is the recovery of vocabulary that already
> existed once — `docs/config.sample.toml`, `docs/man/rook-plugin.7`
> and `docs/environments/IR.md` at `425c0f8^`, written for the Zig app
> that was deleted in the mux pivot. The names here are those names.
> Where this document invents, it says so.

rook is not herdr. rook is the thing you build herdr with — and the
test of that is whether herdr's left rail can be written by somebody
who did not write rook, deleted by somebody who does not want it, and
replaced by somebody who wants a different one.

That splits into two problems pointing in opposite directions:

- **in** — something outside rook decides what a region of the screen
  says. Rook paints it.
- **out** — something outside rook needs to know exactly what rook is
  doing. Rook publishes it.

Neither direction ever merges with the other. That is the whole design.

## The two rules

**Rook paints; plugins supply.** The frame builder never calls a
plugin, never waits on one, and never fails because of one. Plugins
push models; rook composites the most recent one it holds. A slow
plugin yields a *stale* surface, never a stalled frame. This forbids
the thing a plugin API most naturally wants to be — a synchronous
render callback — and it is the reason rook can be fast while the
things inside it are not.

**Rook is the single writer of its own state.** Consumers replicate
it; they never manipulate it. To change something you issue a command,
and rook publishes the consequence. One-way data plus commands means
no merge, no conflict, no reconciliation, and no way for two writers
to disagree about which window is current.

## Surfaces

A **surface** is a rectangle of the screen that is not a pane. The tab
bar is one. A status bar is one. herdr's left rail is one. A popup
picker is one. Today each is hand-written chrome with its content baked
in; a surface is that same thing with the content, the position and the
keyboard behaviour pulled out into configuration.

Three axes, declared independently. Every existing piece of chrome
conflates at least two of them, and every disagreement about how chrome
should behave turns out to be a disagreement about one axis leaking
into another.

### 1. Placement — where it is, and when

| key | values |
|---|---|
| `place` | `dock:left`, `dock:right`, `dock:top`, `dock:bottom`, `popup`, `overlay`, `inline` |
| `size` | columns for left/right docks, rows for top/bottom; a float is a fraction of the glass |
| `show` | `always`, `hotkey`, `auto` |
| `key` | the chord that toggles it when `show` is not `always` |
| `min` | fold the surface away below this much glass rather than crowd the panes |

A dock subtracts from everything downstream — splits, rails, other
docks — in declaration order, so two left docks nest left-to-right. A
`popup` floats centred and takes all input while it is up (what
`rook popup` does today). An `overlay` floats without taking input.
`inline` puts the surface in the window's own split tree, where it
resizes with `prefix-HJKL` like anything else.

Folding is a fold, not a collapse: below `min` the surface is *gone*
and the panes reclaim the columns. herdr collapses its rail to a
50-pixel strip of dots; that is a legitimate thing to want, but it is a
different surface with a different content model, and it should be
declared as one rather than hidden inside a width threshold.

### 2. Content — who decides what it says

Three tiers, in ascending order of what they cost rook.

**`items`** — a list model: rows with a title, a subtitle, a state, and
optional fields, actions and children. Rook owns the painting, so every
`items` surface in every configuration wears the same palette, the same
row rhythm, the same selection band. This is the `items.list` shape
from `rook-plugin(7)`, unchanged. Cheapest, most constrained, and what
the spaces/agents rail should be.

**`segments`** — a bar model: an ordered list drawn from one
vocabulary. Built-ins are `tabs`, `workspace`, `branch`, `cwd`,
`hints`, `hud`, `title`; a plugin contributes more by name. When the
bar is too narrow, segments shed from the *end* of the list backward,
and one flexible segment fills the gap and never pushes a fixed one
off. (Verbatim from the old `status-left`/`status-right` rule.)

**`pty`** — a program, with an emulator behind it. Any TUI works
unmodified. This is what a pinned pane already is. Costs a process, a
reader thread and a terminal per surface, and can die; in exchange it
can do anything.

### 3. Focus — whether the keyboard can reach it

This is the axis both prior art gets wrong. herdr says chrome is not
focusable, so its rail is unreachable from the keyboard you are already
using. Panes say focusable means there is a pty behind it, so anything
without a process is unreachable by construction. They are independent.

| `focus` | behaviour |
|---|---|
| `none` | decorative. Never in the focus graph. A status bar. |
| `nav` | joins the directional graph. `ctrl-hjkl` and `prefix-hjkl` land on it. Rook gives it a cursor and implements `j`/`k`/`g`/`G`/`Enter` over the item model itself. |
| `keys` | joins the graph and receives raw keys. For `pty` content, or a plugin that wants the whole keyboard. |

The mechanism for `nav` already exists and is one line of thinking away
from working: `navigate()` walks `self.placed`, which is why the pin
rail is reachable by `ctrl-h` and the panel I hand-wrote is not — it
was deliberately kept out. A surface joins the graph by being in it.

**The prefix is always rook's.** A focused surface never sees the
prefix key — that is how you get *out* of one, and a surface that could
swallow `prefix-hjkl` would be a trap. Pane verbs (`x` kill, `z` zoom,
`v`/`-` split, `P` pin, `G` global-pin) are **refused** while a surface
holds focus rather than falling through to the last-focused pane: a
`prefix-x` that kills something you cannot see is worse than one that
does nothing. App verbs — `hjkl`, `n`/`p`/`1-9`, `c`, `s`, `d` — work
normally. A surface declares its own bare-key chords, which apply only
while it is focused.

**Motion is rook's; action is the plugin's.** Rook moves the cursor,
because a keystroke must never wait on a process and because `j` should
mean the same thing in every surface anybody ships. Only `Enter` — or
an explicit action key — becomes an `items.act` call. A plugin that
wants every keystroke asks for `focus = "keys"` and gives up the
guarantee.

### Configuration

In `~/.config/rook/rook.toml`, as `[[surface]]` blocks — which means
teaching `parseMux` array-of-tables, about sixty lines, since every
value is a scalar or a list of strings. TOML is the no-SDK front end
and stays that way forever; when the environment graph returns it emits
`kind: "surface"` nodes with these same field names, and the loader is
the only thing that changes. One config file, no second format, and
nothing thrown away later.

Fail open, as the IR always required: an unknown key is skipped in
silence, a malformed block falls back to defaults, and a bad config
never bricks a launch.

```toml
[[surface]]
name    = "spaces"
place   = "dock:left"
size    = 30
min     = 100          # fold below 100 columns
show    = "always"
focus   = "nav"
content = "items"
plugin  = "herdr#spaces"

[[surface]]
name    = "agents"
place   = "dock:left"
size    = 30
show    = "hotkey"
key     = "<prefix>a"
focus   = "nav"
content = "items"
plugin  = "herdr#agents"
```

The bars are surfaces too, and the flat keys that already exist are
sugar for the common case:

```toml
top-bar      = ["tabs", "title"]      # → a dock:top segments surface
status-left  = ["workspace", "branch", "cwd"]
status-right = ["hints", "hud"]
tab-style    = "chips"                # chips | index-name | current
```

`top-bar = []` hides the strip and the panes reclaim the row — which is
also how you get tabs down the side instead: a `dock:left` surface with
`content = "segments"`, `segments = ["tabs"]`, `tab-style =
"index-name"`.

## The plugin protocol (in)

Version 1, unchanged from `rook-plugin(7)`: one JSON object per line
over the plugin's stdin/stdout, at most 1 MiB. Frames from the plugin
*with* an `op` are requests to rook; without one they are replies.
Every operation in both directions is gated by `grants` declared in the
environment graph — a plugin can do exactly what its declaration says.

```json
{"v":1,"id":7,"op":"items.list","deadlineMs":9750,"params":{"root":"/path","limit":128}}
{"v":1,"id":7,"ok":true,"result":{"items":[…],"truncated":false}}
```

An item is the model a `nav` surface renders:

```json
{"id":"web-dashboard","title":"web-dashboard","state":"blocked",
 "subtitle":"blocked · claude","origin":"managed",
 "workspace":"web-dashboard",
 "fields":[{"key":"branch","kind":"TEXT","value":"feat/usage-charts"}],
 "actions":[{"id":"open","label":"Open"}]}
```

`origin` is `managed` (the default: something is driving this, and can
say what it is doing) or `manual` (nobody claims it). It is the one
field on an item that is not about the work, and it is painted that
way — see [Agents rook finds by itself](#agents-rook-finds-by-itself).

`workspace` is the other field that is not about the work, and it is
never painted at all: it names the rook workspace this row's agent is
running in, which is how a producer claims the session rook can see
there. `id` and `title` are the producer's own vocabulary and rook
cannot resolve either against its pane table; `workspace` is rook's,
so it is the one identity the two sides share.

What this design needs on top of what `rook-plugin(7)` already
specifies:

- **`items.push`** — plugin → rook, the same payload as an
  `items.list` reply, unsolicited. Today rook asks and the plugin
  answers; a live rail needs the plugin to volunteer. This is the frame
  that makes the "rook never waits" rule cheap instead of merely
  possible. **Built** — `chrome.Feed`, one frame per line into
  `rook side -`, answered with a serial or with the reason it was
  refused. It arrives over the mux socket rather than a plugin's
  stdout, because there are no plugin processes yet; the frame is the
  same one either way, so growing a runner does not move the seam.
- **Surface addressing.** A plugin serving two rails (`herdr#spaces`,
  `herdr#agents`) needs a `surface` field on `items.list` params and on
  `items.push`. **Built**, for the two the rail is made of: a frame
  names `spaces` or `agents` and replaces that panel whole.
- **Selection is the plugin's.** Rook moves a cursor; it holds no
  opinion about what is *selected*. The highlight arrives in the pushed
  model. (This is a correction, not a refinement — see below.) **Built
  halfway**: `current` on an item is the highlight, and the next push
  takes it back from a click. The click itself is still not forwarded,
  because there is nothing to forward it to.

### Agents rook finds by itself

The one place rook supplies content to its own rail, and the reason
the exception is worth its own section.

A pane whose foreground program is an agent — `claude` by default,
`[mux] agents = [...]` to name others — is a session somebody started.
Rook can see it in its own pane table, which is rook's own state and
nobody else's, so it lists one row per workspace on the *agents*
panel, marked `origin: "manual"`, folded in after whatever was pushed:

    agents            1 manual
    ● main                        ← pushed: a producer manages it
      working · claude
    ◌ scratch                     ← found: nobody claims it
      manual · claude

This does **not** reopen "no agent state, no fleet vocabulary in
rook". Rook says a session is *there*; it never says what it is doing.
There is no capture, no screen scraping, no heuristic about whether an
agent is waiting on you — a found row carries no state at all, which
is exactly why it draws the loose dot instead of borrowing one.
Whoever manages that agent still owns everything else about it, and
the moment a producer pushes a row naming that workspace, rook's own
row disappears in favour of it.

Three rules keep the merge from becoming a negotiation:

- **Pushed rows win, always.** A producer that names a workspace owns
  that row. Rook drops what it found there rather than listing it
  twice, and never edits a pushed row.
- **Naming it means `workspace`.** The claim is made in rook's
  vocabulary, on the item:

      {"id":"f356bc2c","title":"Fix the duplicate rows",
       "subtitle":"working · rook","state":"working",
       "workspace":"rook--vera-f356bc2c"}

  A `title` is prose — a task, a branch, a sentence — so matching the
  claim on it worked only for a rail that happened to name its rows
  after workspaces, and listed a fleet's agent twice for every rail
  that did not: once as the task somebody is running, once as the pane
  rook found running it. A title is still taken as a claim when the
  item carries no `workspace`, so those rails keep working; an
  explicit `workspace` speaks for the row alone, and its title claims
  nothing.
- **One way, one frame.** The merge happens where the panel is
  painted. Nothing rook found is written back into a producer's model,
  and `surfaces[].model` in the state feed stays the producer's bytes,
  verbatim; what rook found rides beside it as `surfaces[].found`.
- **Nothing about the work.** Origin gets a dim word ahead of the
  subtitle and a dot shape for a row with no state. It never takes a
  palette color and never overrides a state, so a glance still reads
  state first.

The scan is two syscalls a pane (`fgName`) on a 2s timer — the drift
cadence, for the drift reason — and only a change repaints.

**One process per plugin, serving many surfaces.** `herdr#spaces` and
`herdr#agents` are one `herdr` process; requests carry a `surface`
field. Two processes would duplicate the work of reading the same
worktree and agent state, and could disagree about it — and one
`describe`, one grant set, one failure row is a simpler lifecycle than
two. `load = "lazy"` spawns on a surface's first appearance, which for
a `show = "always"` surface is effectively eager.

**A dead plugin leaves its last model on screen, marked stale** — dimmed,
not blanked, and never an empty rectangle where your chrome was. It
stays failed until relaunch, per `rook-plugin(7)`: a plugin failure is
a row in a listing, never a crash of rook.

### Workspaces rook lists by itself

The same shape, one panel up. Rook *holds* workspaces — they are its
own state, the names in `rook state` — so the spaces panel lists them
whether or not anything pushed a row: one row per workspace, in
workspace order, the current one highlighted unless a pushed row placed
`current` itself. Those rows carry `"origin":"found"`: not `manual`,
because nobody launches a workspace at an agent and there is nothing to
be unmanaged about, so the row wears no tag and the header no count.
Clicking one switches to that workspace — the row *is* the workspace,
so the click is rook's to act on, where a click on a pushed row only
moves the cursor.

A producer claims a workspace the same way it does on `agents`:
`"workspace"` on its row. The fleet's row for a repository names the
workspace open on that checkout, so what rook found for that name is
dropped in favour of the producer's row and its state. A repository
with no workspace open is not a space — it is something the picker
could open — and the producer does not push it.

In the state feed the rows ride under `surfaces[].found` for `spaces`
too, with `current`, so a second glass draws the unfed rail from the
snapshot alone.

## The state feed (out)

Everything rook knows, published so that anyone can hold an exact
replica and never has to ask.

Two doors onto one schema:

```
rook state          # the snapshot, JSON, on stdout
rook watch          # newline-delimited JSON: snapshot first, then one per change
```

`watch` emitting the full snapshot as its **first line** is what makes
consumption trivial: spawn a process, read lines, parse. No polling, no
file watching, no framing library, and reconnect is resync. It also
avoids a trap — a file published by atomic rename cannot be watched by
inode, only by watching its directory, and every consumer would get
that wrong exactly once.

`<sock>.state.json` carries the same bytes for anything that would
rather `cat` than subscribe. It is *not* `<sock>.state`, which is the
restore format and stays private: restore may change shape whenever we
like, a published feed may not, and one file cannot have two
compatibility obligations.

### Snapshots, not deltas

The whole state on every change. It is a few workspaces and a couple
dozen panes, and it changes at human rate, not frame rate. A consumer
that misses a delta is wrong forever; a consumer that misses a snapshot
is correct on the next one.

This pays twice. **Rook must never block on a slow reader** — a
consumer that stops draining its pipe would otherwise stall the poll
loop, and the whole multiplexer with it. With snapshots, coalescing is
trivially correct: drop the older one, send the newest, the replica is
still exact. Deltas would force unbounded buffering or a disconnect.

### The schema

```json
{
  "rookMuxState": 1,
  "epoch": "0f3c9a2b",
  "serial": 412,
  "pid": 48120,
  "geometry": {"cols": 180, "rows": 45},
  "focus": {"pane": 7, "mode": "pane"},

  "workspaces": [
    {"name": "main", "current": true,
     "windows": [
       {"index": 1, "name": "claude", "current": true, "zoomed": false,
        "focus": 7,
        "layout": {"split": "v", "ratio": 0.5, "a": {"pane": 7}, "b": {"pane": 9}}}
     ],
     "pins": [12]}
  ],

  "panes": [
    {"id": 7, "pid": 48213, "program": "claude",
     "cwd": "/Users/seth/src/rook", "cols": 74, "rows": 44,
     "rect": {"x": 31, "y": 1, "w": 74, "h": 44},
     "focused": true, "visible": true, "wantsMouse": false,
     "exited": false, "lastOutputMs": 1787588669907}
  ],

  "pins": [{"pane": 12, "scope": "global"}],
  "surfaces": [
    {"name": "spaces", "place": "dock:left", "size": 30, "shown": true,
     "model": {"v": 1, "op": "items.push", "params": {"surface": "spaces", "items": [
       {"id": "herdr", "title": "herdr", "subtitle": "master", "state": "working"}]}}},
    {"name": "agents", "place": "dock:left", "size": 30, "shown": true, "model": null,
     "found": [{"title": "scratch", "subtitle": "claude", "origin": "manual"}]}
  ],
  "clients": [{"cols": 180, "rows": 45, "attached": true, "block": 0}]
}
```

`focus.mode` is `pane`, `copy` or `popup` — a replica needs to know
when the mux itself is holding the keyboard. `rect` is null for a pane
that is not currently placed (another window, a hidden workspace) and
`visible` says the same in one field. `lastOutputMs` is wall clock, not
the server's uptime clock, because other processes read it. A `found`
row's `title` is the workspace it was found in (on `agents`) or the
workspace itself (on `spaces`, where `current` marks the one in front),
and `model`'s items carry the producer's `workspace` verbatim, so a
second glass drops the same rows rook does without inventing a rule of
its own.

### Two cadences, so a busy pane cannot make it chatty

Change is detected by diffing snapshots, so the diffed form has to
leave out anything that would make the diff see itself:

- **identity** (`epoch`, `serial`) is omitted when diffing. Bumping the
  serial must not read as a change, or the feed feeds itself — a 20 Hz
  loop, which is what the first cut of this did.
- **drift** (`program`, a window's `name`, `cwd`, `lastOutputMs`) is
  omitted from the fast diff and looked at every 2 s instead. These
  move with pty output: `while true; do date; done` respawns its
  foreground child faster than the poll floor, and diffing on them
  pushed 118 snapshots in 6 s. Split, it is 5 — with liveness still
  fresh.

Structural change — anything a command did — still pushes on the next
50 ms turn, and idle is silent.

Each surface publishes the last model pushed to it, verbatim and
opaque — never merged into rook's own state, never interpreted. Rook is
already holding those bytes because it paints them, so this costs no
storage, and it is what lets a second glass (the browser client, the
phone) render the rail without talking to any plugin itself. Built:
`surfaces[]` carries one entry per rail surface, each with the frame it
was last given under `model` (null until something pushes).

`epoch` is a boot id and `serial` a monotonic counter. Both are
load-bearing:

- **`serial`** lets a replica know it is current and detect a gap.
- **`epoch`** tells it *this is a different rook* — a consumer that
  reconnects across a `rook kill` must discard rather than silently
  merge two unrelated worlds.

### Read-your-writes

Mutating commands answer with `s2c.ack`, an 8-byte serial. The CLI
prints it as JSON **only when stdout is not a terminal**, so a script
gets read-your-writes while an interactive `… | fzf | xargs rook
switch` inside a popup stays silent:

```
$ rook switch web-dashboard | cat
{"ok":true,"serial":413}
```

Wait for `serial >= n`, never `== n`: anything else may have moved in
between. Without this everyone writes the same sleep-and-hope loop and
gets it slightly wrong.

### Not hooks

A hook that spawns a process per event pays exactly the cost rook is
supposed to avoid, and focus changes are frequent. Hooks are a
three-line shell loop on top of `watch`, which is the right place for
them.

## What is real today

Honest inventory, so this document is not mistaken for a description.

| piece | state |
|---|---|
| `chrome.zig` palette + list painter | real; the painter is roughly the `items` renderer |
| `chrome.Feed` + `c2s.side` / `rook side` | **built** — the rail's content comes from outside; `chrome.placeholder` is gone, and its model survives as `demo_frames`, two `items.push` frames |
| `chrome.Merge` + `Server.scanAgents` | **built** — agents rook finds in its own pane table, folded into the pushed agents panel as `origin: "manual"`, published as `surfaces[].found` |
| `tabBar()` | real, hardcoded: chips, order, the `+`, where hints ride |
| pins | real; a `pty` surface with `place` hardcoded to `dock:left` |
| `navigate()` over `self.placed` | real; the `focus = "nav"` mechanism, unused by surfaces |
| `saveState` → `<sock>.state` | real; restore format, still private |
| block table push | real; superseded by the state feed, kept for the web client |
| `rook state` / `watch` / `capture` | **built** |
| `s2c.ack`, quiet `session 'N'`, `block_created` on new | **built** |
| plugin protocol v1 | specified in `rook-plugin(7)` at `425c0f8^`; `items.push` implemented, the rest not |
| surfaces (declared, placed, focusable), plugin processes | none of it |

Two consequences worth naming:

**Pins stop being a feature.** A pin is a surface with `content =
"pty"`, `place = "dock:left"` and `focus = "keys"`. Global versus
workspace-local becomes a `scope` on the declaration. That deletes a
concept rather than adding one.

**`clickSide` was wrong** and is now half-right. It moved
`self.side.spaces.cur` — rook holding a plugin's selection state,
exactly the merge this design forbids. It now moves a *cursor* over a
pushed model, and the next push takes the highlight back, so the two
never disagree for longer than one frame. The correct shape still
forwards the click and lets the producer push back a model with the
highlight already in it; that needs a back-channel to a producer, and
there is no producer process yet.

## Decisions taken

Recorded with the reasoning, so they can be reopened on purpose rather
than by drift. This is a tool for us; none of it is expensive to change.

**The prefix never reaches a surface, and pane verbs refuse while one
is focused.** The alternative traps you inside chrome or lets
`prefix-x` destroy it. *Revisit if* a surface genuinely needs a chord
that collides with a pane verb — the answer then is a surface-local
chord table, not prefix fall-through.

**Surfaces are declared in `rook.toml` as `[[surface]]`.** One config
file, the format already in use, and the array-of-tables parser is
sixty lines that the environment graph will not obsolete — TOML stays
the no-SDK front end. *Revisit if* the SDKs come back and surface
declarations start needing computation, in which case the graph emits
the same fields and TOML keeps working.

**The state feed publishes each surface's items, opaque.** Rook already
holds them in order to paint them, so it costs nothing, and it is what
makes a second glass work without a plugin connection. Kept namespaced
under the surface and never merged, so rook still holds no opinion.
*Revisit if* a plugin surfaces something that should not leave the
machine — the fix is a `publish = false` on that surface, not a change
of default.

**One plugin process serves many surfaces.** Shared state stays
consistent, and the lifecycle is one handshake and one failure instead
of two. *Revisit if* one surface's slowness starves another; the
protocol is already multiplexed by `id`, so that would be a scheduling
fix rather than a process split.

**Rook supplies agent rows for panes nobody claimed, and nothing
else.** The rail existing to be pushed to is right; a rail that stays
empty while a Claude session runs three columns away is not, and the
pane table is rook's own state, so reading it breaks no rule. The line
is drawn at *presence*: rook says a session is there, never what it is
doing, and a pushed row for the same workspace always wins. *Revisit
if* a found row ever needs to say more than presence — that is a
producer's job, and the answer is to write the producer, not to teach
rook what a turn is.

**A producer claims a workspace by naming it, never by titling a row
after it.** The first cut of the merge matched a pushed row's name
against the workspace rook found the session in, which is true for a
rail that lists workspaces and false for every rail that lists work —
a fleet titles its rows after tasks, so its agent appeared twice, once
as the task and once as the pane. There is no honest way to guess: an
`id` and a `title` are the producer's vocabulary, and rook cannot
resolve either against its pane table. So the item gained one field in
*rook's* vocabulary, `workspace`, and the claim is made in it. *Revisit
if* one workspace ever holds two agents that different producers
manage — the claim would then have to be per pane, which rook can
address (`panes[].id` is in the state feed) and a producer that spawned
the pane already knows.

**A failed plugin's surface goes stale, not blank, and does not
respawn.** Consistent with `rook-plugin(7)`. *Revisit if* daily driving
makes manual relaunch annoying — the answer would be backoff respawn,
which is a lifecycle change and needs to be visible when it happens.

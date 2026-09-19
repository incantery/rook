# The root: rook's home, and the spaces under it

Rook lands at home. The spaces run underneath it, and you go into one
when hands-on work is useful, and come back out when it is done. This
page is the product model behind that — the inversion of 2026-09-06,
which turned the overview that `prefix-o` used to open *inside* a
space into the root the spaces hang from — with the state model as it
was and as it is, the grammar, the runtime ontology it rests on, the
data the companion provides today against what is typed and waiting,
the fixture it is judged against, and the parts still owed.

The intended feeling: *rook is where I say what should happen and see
what is happening; a space is where I go to put my hands on it.* Rook
owns the durable execution environment — terminals, spaces, panes,
processes, state, control. Vera owns intent, planning, memory,
coordination, synthesis. Home is where the two are one product.

## The model, before and after

Before this pass:

    launch rook  →  land inside a space (the restored one, or `main`)
                 →  prefix-o paints an overview over it
                 →  esc drops back into the space

The space was home; the overview was a session picker with a query
field, and its corner said `esc ↩ vera` — the space was its parent.
The state was one boolean, `alt_on`, and a query whose first
character decided whether it was a find or a `:` command; bare text
found things; the only door to interpretation was a `✦ vera:` row
that typed the text into the companion's pane. A glass attaching
carried its geometry and nothing else.

After:

    launch rook  →  land at home: say what you want, see what needs
                    you, what is running, what finished, the spaces
                 →  ↵ on a row enters its exact space, tab or pane
                 →  prefix-o comes back out, to home
                 →  esc at home does nothing: nothing is above it

The state, in one place (`altitude.zig`, `State`):

| what | field | values |
|---|---|---|
| scope | `Server.at_root` | root, or the space the server is showing (`cur_sess`) |
| view | `State.view` | `home` (the default), `orbit`, `ledger` — subviews of the root, never of a space |
| painted | `State.painted` | what the frame actually drew: `home`, `orbit`, or `ledger` when orbit fell back for room |
| input mode | `State.mode()` | derived from the draft's first character: bare text is `intent`, `/` is `find`, `:` is `command` |
| draft | `State.text` | kept across a visit to a space |
| cursor | `State.cur` | the selected row; kept too |
| request | `State.req` (`ask.zig`) | `none`, `running`, `replied`, `failed`, `offline`; the reply, the reflection, the receipts |
| landing | `State.land` | where `prefix-a` / `prefix-!` put the cursor at the next build |
| focus | `home.State.focus` | `nav`, `insp`, `vera`; `detail` on the narrow stack |
| thread | `home.State.thread` | this session's turns, a ring; `thread_scroll` |
| navigator | `home.State.rows` over `tasks` | rebuilt each frame; `nav_cur` by identity (`nav_key`), `nav_scroll` |
| inspector | `home.State.insp` | lines and controls, rebuilt each frame; `cur` and `scroll` kept per subject |
| vera's pane | `vera_open`, `vera_pinned`, `about_*` | summoned, kept, and what the next request is about |
| her terminal | `Server.vera_pane` | the pty running `[companion] chat`, sized to `home.veraBody`; null when the panel is rook's own surface |
| return jump | `Server.last_sess` | the space before the last hop, for `prefix-C-o` |

Startup destination is decided once, on the wire: `attach` carries
the geometry, then optionally where the glass lands (`r` the root,
`s<name>\t<cwd>` a space, made there if it must be). Nothing after
the geometry is the product's default: the root, unless `[mux]
startup = "last-space"`. A second glass joining a first one does not
move it. The Go front door spells the three forms `rook`, `rook .`
(the space named for the directory, seeded there) and `rook --space
<name>`, and `rook home` says the root outright.

Esc unwinds one layer, and only the current one: a request still
running (cancelled), then a typed draft (cleared, with its results or
completions), then a receipt (dismissed), then a subview (orbit or
ledger, back to home), and at home with nothing open it does nothing.
It never enters a space. `prefix-o` from anywhere is home — from
orbit too, which makes it idempotent — and the draft, cursor and
receipt survive a visit to a space, so coming back is where you were.
Entering and leaving the root moves no pane: the canvas is painted
over the window region while the ptys keep their geometry and keep
running, which is also why coming back down is the exact frame.

## The runtime ontology

One name, one meaning. These are the objects as the engine holds them
(`mux/src/server.zig` unless said otherwise), what each is called on
the glass, and where it shows.

| concept | runtime type / source | lifetime | example | visible where |
|---|---|---|---|---|
| **rook scope** | the `Server` itself, at the root (`at_root`) | the server process | `rook` as the accent chip | the scope slot, as the block, at the root only; the bar's left word |
| **space** | `Session` — a workspace: windows, pins, focus | until its last window closes; restored across restarts | `vera` (identity `rook--vera-e41…`, label `vera`) | the scope slot in a space; a row at home; a figure in orbit; `:go` |
| **tab** | `Window` — one split tree | until its last pane exits | `deploy` | a chip on the tab bar; after a space's name at home; a tab in a figure |
| **pane** | `Pane` (`pane.zig`) — a pty and ghostty-vt | until its shell exits | the Claude pty, id 7 | a region of the space, bordered only when split |
| **tool** | `Pane.fgName()` — the foreground program, by name | moment to moment | `claude`, `nvim`, `zsh` | the bar (`you ▸ claude`); attention lines; the inspector |
| **actor** | `Pane.owner` — the name a program gave when it claimed the pane with `rook own` | claim → release | `main` | after the tab name (`deploy · main`); the bar (`main ▸ claude`); a work row |
| **agent found** | `Pane.is_agent` — a tool the config lists under `agents` | the 2 s scan | a `claude` running unclaimed | the ◐ mark; the working count; a `running` row at home when no producer claims its space, `goal unknown` |
| **work item** | a producer's `agents` row (`chrome.Item`): goal, state, space, and optionally actor, event, result | until the next push | "Fix flaky auth · working · api · codex" | `needs you` (waiting, failed), `running` (working, idle), `recent` (done) at home; a space's event line |
| **request** | `ask.Request` — the text sent to the companion's command, and what came back | until the next request | `you  deploy the api` | a turn in the thread; the header (`✦ vera · thinking`); the bar |
| **turn** | `home.Turn` — one entry of the thread: a role, its words, its age, and the task or space it is about | this session (a ring of 40) | `✓ Deploy api to staging finished · staging is on 1.4.2` | vera's pane |
| **task** | `home.Task` over a rail `Item` — the projection of one task into a group, with the item's typed detail (goal, plan, events, files, commits, tests, artifacts, usage, question, options, actions) | rebuilt every frame from the rail and the pane table | `◐ Fix flaky auth` | a navigator row; the inspector |
| **control** | `home.Act` — a producer's option or action (a command), vera's pending proposal, or rook's own move | with the inspector | `◌ us-east first  $ vera task answer t1 …` | the inspector's `controls` |
| **reflection** | `ask.Reflection` — a reply that is one JSON object: intent, plan, space, question, actions | with its request | `in api · 1. run the tests…` | under the request; actions as `proposed` rows |
| **provider / model** | not held — a producer's vocabulary | — | Sonnet | the inspector says it is not rook's to know |
| **legacy sidebar** | `foundSpaces()` + pushed rows, `sidebar_mode = "open"` | — | | not default chrome; `prefix-A` toggles it for a config that asked; still on `surfaces[]` |

The canonical grammar, everywhere:

    [rook]           the system scope: the accent chip, and only at the root
    [rook] │ orbit   a subview of the root, named as a tab, with esc rook in the corner
    vera             a space (the scope slot in it; a row or figure above it)
    deploy           a tab, minted once
    deploy · main    a tab with the actor that claimed a pane in it
    you ▸ claude     the bar: who holds the keys, through what tool
    Fix flaky auth   a work item: the goal, in the producer's words
    you  …           what you said, a turn in the thread
    ✦  …             what she said, or her plan as a block

A space named `rook` is a space: it gets the space chip (`raised`
ground, primary ink) in its own scope slot and a plain row at home.
The system's chip is the accent fill and appears only at the root.
The identities differ too — the space is a `Session` with the label
`rook`; the root is the server — so nothing looks one up by the word.

## Home: the navigator and the inspector

The canvas at the root is the **work navigator** on the left (a
third) and the **inspector** on the right (the rest), split at one
quiet divider (`home.zig`, `layout` — one boundary, in cells:
`nav_pct`, `min_nav`, `min_insp`, `min_vera`). The left answers
*what needs me, what is running, what finished, where?* as a stable
index; the right answers *what is this, and what can I do about it?*
in the detail the data affords. Vera is one key away, never a
column by default.

**The navigator.** Groups in this order, each only when it has
rows, with a count: `needs you` (vera's proposed actions; a pane
that rang, notified or finished a bar while nobody looked; a task a
producer says is waiting or failed), `in progress` (a producer's
tasks by goal; then an agent rook can see producing where no
producer claims, `claude at work` — never an idle one), `recent`
(what finished), `spaces` (one row each: the name, its marks, its
tab count, its age). A row is the mark, the title, and at the edge
the space or the age — what selection needs and no more. The
selected row wears the band and the accent marker (muted when focus
is elsewhere); a needs-you row the attention edge. An empty
navigator says `all quiet · nothing needs you` once. The
selection is an identity, not an index: a task that moves between
groups stays selected; a row inserted above it does not move it;
until a hand has chosen, the cursor rests on the first row.

**The inspector.** For the selected thing, sections only where the
data is (`inspBuild`): the title with its mark; `state · in space ›
tab · actor · age`; the goal; `now` (the current step), or `waiting
on you` with the question, or `what went wrong`, or `outcome`; the
plan with `n of m`; the timeline with ages; files, commits, tests,
artifacts; usage; how many turns vera's thread holds about it; the
last lines its pane wrote, as output; then `controls`. Controls are
the producer's (`options` for a question, `actions` for lifecycle
moves — each a command rook runs on ↵, never implied), then vera's
pending proposals for that task, then rook's own two: `open its
pane` / `open the space` / `go see it`, and `ask vera about this`.
A space's detail is its work by group, its agents (producing, or
idle with the age), its tabs, and `enter the space`. Nothing
selected: a compact quiet summary and what there is to do.

**Vera's pane.** `prefix-t` summons her from home or from any
space, over the inspector's side (or over the panes, in a space,
resizing nothing); `prefix-t` again dismisses her; `prefix-T` pins
her, and a pinned pane takes a third column when all three regions
fit (`min_nav + min_insp + min_vera + 2`), else overlays with
`pinned` in its header. The thread, the scroll and the draft
survive toggling and workspace changes. `ask vera about this`
opens her with the selected task attached — the header says `about
<title>` and the request carries `ROOK_ABOUT_TASK` and
`ROOK_ABOUT_SPACE` in its environment, a reference, not words. Her
replies and rook's notes update the same tasks the navigator lists.
Typing a letter from the navigator or the inspector summons her
with the letter in the composer; `/` and `:` are find and command,
as ever, without her.

**What is inside the panel.** Her own terminal, when there is one.
`[companion] chat` — `vera chat` by default, `chat = ""` to turn it
off — runs in a real pty, started the first time she is summoned
and kept alive after: a program that is still running has not lost
the thread, the scroll or the draft, so rook does not have to keep
them. Rook draws one header row (two, with something attached) and
`home.veraBody` is the rest; the painter draws the pane into that
rect and the server sizes the pty to the same one, because the
resize a hosted TUI cannot recover from is the one where the two
disagree. Under `min_chat_cols × min_chat_rows` the panel says so
rather than handing the program a window it would truncate
everything into.

Where the two surfaces differ: the hosted terminal owns its box, so
there is no rook draft, no `↵ sends`, no reflection block, and no
door for a structured attachment into a program already running —
`ask vera about this` types the task's *id* into the box instead,
with the chip above it saying what the id names. The bar says only
what rook can see of a program it does not read: `vera open`, or
`vera working` while it is writing. It is rook's pane, not a
space's: never the window focus, never counted as an agent at work,
never a row at home, and `place: "vera"` in the state feed (which
is how the companion slot still answers *is she open in rook*).
Without a chat command, or without it on PATH, the panel is rook's
own surface below — a composer, a thread, and `[companion] ask`.

**Who owns a letter.** In the navigator and the inspector, `h j k
l o g G` are motion and never reach vera; every other printable
letter summons her with itself in the composer, so a message that
begins with one of those seven starts from her pane (`prefix-t`, or
⇥ to her) — the rule is seven letters, said once here, and her
pane's hint names the two keys. Inside her pane every letter is
hers. `/` and `:` are find and command from anywhere at home.

**Keys.** In the navigator: `j k` (↑ ↓, C-n C-p) move; `l`, ↵ or
→ focus the inspector; `g G` the ends; `o` opens the exact
workspace. In the inspector: `j k` walk the controls (or scroll
when there are none), PageUp/Down scroll, ↵ runs the selected
control, `h` (←) is the navigator, `o` opens the workspace. Ctrl-h/l
walk navigator, inspector, vera the way they walk panes; ⇥ cycles
them. In vera's pane, hosting her own terminal: every byte is the
program's — Esc, the arrows it opens, Ctrl-j for a newline, its own
history and its own paste — except the prefix, and a Ctrl-h/j/k/l
that has a region to walk to. Only Ctrl-h has one (`prefix-t`
hides her; in a space Ctrl-h gives the keys back to the panes), so
the other three fall through, which is the same bargain a pane on
the edge of a space makes. In rook's own surface: typing is the
draft, ↵ sends, ↑ ↓ scroll the thread, Esc clears the attachment,
then the draft, then closes the pane (pinned: gives the keys back).
Esc elsewhere: a running
request, a draft, focus back to the navigator, a subview, then
nothing. `prefix-a` and `prefix-!` land the navigator on the first
row in progress or needing you; `:now` and `:vera` name the regions.

**Narrow glass.** Under `min_nav + min_insp + 1` columns of canvas
the navigator and the inspector are a stack: the list, `l` to the
detail (full width, `h ‹ list` at its top), `h` back; vera is a
full-width view when up; the selection and the scrolls survive.

**The bars.** The scope bar at the root is identity, the view and
the selection: `[rook] │ home  Fix flaky auth`, or `orbit`. The calm
bar is composed from `[mux] status_home` / `status_space`, modules
by name left of `-` and right of it: `view`, `input`, `agents`
(`◐ n active · n idle` — no stale: nothing here can tell stale from
slow), `attention` (`! n need you`, off at zero), `blocked` (`✕ n
failed`, off at zero), `session` (`session $4.18 · 812k tokens`: the
producer's frame-level total when it sends one, else the sum of its
tasks' `usage`, off when nobody reported; the period is this server's
life), `vera` (`ready`, `thinking`, `waiting for you`, `offline`),
`working`, `unread`, `pins`. Home shows `view - agents attention
blocked session vera`; a space shows `input - working attention
unread pins`, so the one global count a space keeps is attention.

**What survives.** The selection, the group scroll, the inspector's
scroll and control per subject, the thread, the draft, vera's open
and pinned state and her attachment live on the root's state, so a
visit to a space and back — or to orbit and back — is home as you
left it. Her terminal survives for a different reason: it is a
process, and it is still running. Rook dismisses the panel, not the
program. Across a server restart neither survives, yet.

**When her terminal will not start.** A chat command that dies the
moment it runs — a verad that is not there, a half-installed binary
— is not started again on the next frame, because that is a hundred
programs a second and a rectangle nobody can read. The pane is
reaped, `Server.vera_dead` is set, what the program last had on its
screen goes into the thread as an error turn, and the panel falls
back to rook's own surface. `prefix-t` at her clears the flag: the
retry is a person asking, never a frame.

Finding (`/serv`) and commanding (`:`) take the canvas over as one
ranked list under one field; Esc is home again.

## Orbit and ledger

Orbit (`:orbit`) is the spatial subview: the scope bar
reads `[rook] │ orbit` with `esc rook` in the corner, and the canvas
holds every space as a figure — the name in the top edge as its chip,
the event line beside it, the tabs inside as the tab component, and
for the space you left, the last lines of the pane you were in, read
from retained cells — or one row when it has nothing to say. Ledger
is the same spaces as two-line rows: narrow glass (under 60 columns),
`zoom_view = "ledger"`, `:ledger`, and what orbit falls back to when
the figures would not fit. The fidelity is decided once per frame
before the bars are composed, so the tab in the scope bar and the
bar's word say what was painted. `↵` on a figure enters the space.
Esc is home.

## The intent boundary

Bare text goes to `[companion] ask` — `vera say -c rook` by default,
while the companion is vera — run as a child with pipes in the
server's poll loop (`ask.zig`), the text as its one argument. Its
stdout is the reply; its stderr is its commentary. Rook never scrapes
either for state, and never reads a pane to infer a task.

What vera provides today: her rail push (`agents` rows: `title`,
`state`, `workspace`, `subtitle`, `unread`, `current`) and the
one-shot `vera say`, which answers in prose. What is typed and
waiting for her: the item fields `actor`, `event`, `result` (parsed
when present, shown when present, never invented), and the reflection
— a reply that is one JSON object:

    {"intent": "…", "plan": ["…"], "space": "api", "question": "…",
     "actions": [{"label": "…", "run": "vera task new --project api '…'"}]}

Every field is optional. An action is a proposal until a hand confirms
it; then rook runs its command through the same runner and shows what
it printed. That is the confirmation policy, and the only one: nothing
a producer proposes runs unconfirmed. The fixture's fake `vera` answers
in this shape so the flow is exercised end to end; the real one answers
in words until she adopts it.

Availability is the shell's own answer — the command's first word on
PATH — asked on every entry to the root. Offline, the field says so, a
request is refused with `nothing was sent`, and `/` and `:` are
unchanged: navigation never depends on her.

## Ownership and the gate

A pane is the person's until a program says otherwise. `rook own <id>
<actor>` claims its keyboard for `actor`; the tab reads `deploy ·
main`, the bar `main ▸ claude owns input · you observe`, and a typed
key opens a gate instead of landing: ⏎ requests a handoff (the actor
sees `takeover-requested` in the feed, finishes its step, releases;
the person confirms with ⏎), `T` takes now, `s` sends the next
keystrokes through Enter as a message, Esc leaves it. `--paused`
attaches an actor without the keys; `--release`, `--request`, `--take`
are the moves from a script. Five states on `panes[].input`; `prefix-i`
shows them in a box. Focus is observing: scroll, copy mode and
selection are always safe.

## Keys

    prefix-o     home, from anywhere (idempotent at the root)
    prefix-s     the workspace picker (fzf), from a space or from home
    prefix-a     home, cursor on the first running item
    prefix-!     home, cursor on the first thing that needs you
    prefix-t     home, the field empty for a request
    prefix-/     home, finding
    prefix-:     home, a command
    prefix-C-o   the space before the last hop
    prefix-A     the legacy side panel, for a config that asked for it

At the root the space is not on the glass, so the keys that act on
one (`c`, `v`, `z`, …) are not taken there. `prefix-s` floats the fzf
picker (`rook pick`) from home as well, and picking a space enters
it; orbit, which held that key for a while, is `:orbit`. `prefix-a`
used to cycle the side panel, which `prefix-A` still toggles.

## The fixture

`scripts/altitude-fixture.py` builds a deterministic rook — in a
sandbox with its own PATH and a fake `vera`, through the front door,
never the live server — and reads it back through a real glass:

- four spaces, `rook`, `vera`, `api`, `infra`;
- `vera`: tabs `deploy · main` (an agent pane claimed by `main`),
  `logs`, `chat` (the companion); a producer's row saying the task
  there is waiting on you, with an actor and an event;
- `api`: tabs `tests · codex` (claimed by `codex`), `server` with an
  unread bell; a producer's row saying its task is working, and
  another that finished with a result;
- `infra`: one tab, quiet; `rook`: one tab, quiet, no history;
- one global pin promoted out of `api`, so it says `from api`.

It captures home over that state; a request with a reflection and a
confirmed action; a request answered in words; find; command; the
drill from a work item into the agent's pane and the return; orbit
and esc back home; a space's frame with the bar's global counts;
narrow and wide glass; the quiet home; cold starts with and without
vera; `rook .`; `startup = "last-space"`; a space named `rook`; the
tab ladder; ASCII glyphs; the inspector and the gate; a split and the
found agent it puts on home. Each frame is asserted on — cells and
attributes, and the feed's `scope`/`root` — and the PNGs are for
looking at. Run it after any change to the frame.

## What the feed says

- `focus.mode`: `pane`, `copy`, `popup`, `root`, `gate`, `inspect`.
- `scope`: `root` or `space`. `root`: `{"view": "home|orbit|ledger",
  "mode": "ask|find|command", "ask": "none|running|replied|failed|offline",
  "region": "composer|thread|dash", "wide": bool, "turns": n,
  "draft": bool}`. The draft itself is not published.
- `bar`: whether the calm bar is on.
- `workspaces[].windows[].name` (minted), `named`, `nameBy`, `program`
  (the live tool of the focused pane). `nameBy` is whose word the name
  is: `none`, `program` (the first program that spoke), `model` (a
  namer's suggestion) or `hand`. Only `hand` is final.
- `panes[].input`: `{"state": "human"}` or the actor and one of the
  five states, with `sinceMs`.
- `surfaces[]`: the rail's model, still published verbatim for the
  web client and any producer; an `agents` item may carry `actor`,
  `event` and `result` beside its rail fields.
- The restore file (`<sock>.state`, still `v2`) carries `name <n>`
  under a minted window (`name-hand` or `name-model` when that is whose
  word it was; a bare `name` reads back as a guess) and `origin <space>`
  under a global pin.

## The namer

A name minted from the first program that spoke is often the wrong
word: a tab that read `zoxide` at birth reads `zoxide` all day. So a
minted name is now a guess, and a better guess may replace it. A name
given by hand is still final.

- `rook rename --suggest <pane> <name>` offers a name for the window
  that holds `<pane>`. The engine takes it unless `nameBy` is `hand`.
  The engine runs no model and no subprocess; it only accepts a word.
- `rook rename --auto` gives a tab back: it stops being named, rook
  mints from the program again, and the namer may speak. It is the one
  way out of a name given by hand, which nothing else undoes. A flag
  is never taken as a name — `rook rename --help` prints usage.
- The namer lives in `rookd`, so `make install` installs `rookd` too
  and restarts it (`scripts/restart-rookd.sh`). A rook installed
  without that step has the new engine and the old nanny, and its tabs
  keep the names the first program gave them.
- `rookd` runs the namer (`internal/namer`). For each tab not named by
  hand it gathers the project (the repository's name, even inside a
  linked worktree), branch, program, title and the last 40 lines of
  the screen, pipes that to a command, and suggests the command's one
  line of stdout.
- It asks when a tab's facts change and have held still for 8 s: the
  directory, the branch, the program, the title (spinner glyphs
  stripped). With unchanged facts it asks again every 10 minutes if the
  pane has printed since, and then a new name must be said twice
  before it lands. The window's oldest pane speaks for it, so moving
  focus between splits renames nothing.
- The command is a seam: `[namer] command = "..."` in `rook.toml`,
  default `wisp name` (incantery/wisp: the model Apple ships on the
  Mac, about 0.4 s a call, nothing leaves the machine). `[namer] off =
  true` turns it off. No command on PATH means no namer, and tabs keep
  the names rook mints for itself.

## Owed

Deliberately not in this pass:

- **A reflection from the real vera.** `vera say` answers in words;
  the shape above is the contract for when she answers in it, and
  answering a question means asking again with the answer in it.
- **Controls from the real vera.** verad's rail push carries title,
  state, workspace, subtitle; the inspector's detail (goal, plan,
  events, files, commits, tests, artifacts, usage, question, options,
  actions, session usage) is typed and parsed, and shown when
  pushed. `vera task answer|interrupt|relaunch|stop|resume` exist as
  commands, so the rail can name them as `actions` when it chooses.
- **Agents as rows of their own.** An agent is on its task and in its
  space's detail; it is not a navigator row, so it cannot duplicate
  the task. `stale` is not said anywhere: no signal here tells stale
  from slow.
- **Durable conversation history.** The thread is this session's,
  in memory. Vera's own transcript (`vera say -c rook` keeps the
  conversation) is not read back; when there is a typed way to, the
  thread's shape takes it.
- **A live pane inside a card.** A card opens its pane; it does not
  show it.
- **Focus and scroll inside a space across a hop.** A space keeps its
  own focus (`Session.focus_pin`, `Window.focused`) and every pane its
  scroll, so returning is exact; what is not kept is *which* row the
  root's cursor lands on after the rows change under it (it is
  clamped, not tracked by identity).
- **The global pin dock's width** (40% of the glass, the older rule)
  at the root: the pins never resize, which is the point of them, so
  the canvas takes what is left.
- **The shelf** (resolution 7), **folds** (resolution 9), **moving
  surfaces from the root** (`x` lift, `P` drop, `:organize`), a live
  excerpt for spaces other than the one you left, provider detail in
  the inspector, `rook top`: as before.

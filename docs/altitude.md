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
| focus | `home.State.focus` | `composer`, `thread`, `dash`; the narrow view follows it |
| thread | `home.State.thread` | this session's turns, a ring; `thread_cur`, `thread_scroll`, `linked` |
| dashboard | `home.State.cards` over `tasks` | rebuilt each frame; `dash_cur`, `dash_scroll` survive |
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
| **turn** | `home.Turn` — one entry of the thread: a role, its words, its age, and the task or space it is about | this session (a ring of 40) | `✓ Deploy api to staging finished · staging is on 1.4.2` | the conversation |
| **card** | `home.Card` over a `home.Task` — the projection of one task into a module | rebuilt every frame from the rail and the pane table | `◐ Fix flaky auth / api · codex · working` | the dashboard |
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

## Home: the cockpit

The canvas at the root is two regions between the scope bar and the
calm bar, split at 62% when both keep a useful width (`home.zig`,
`layout` — one boundary, in cells): the conversation on the left, the
dashboard on the right, one quiet divider between them. The left
answers *what do I want, and what have vera and I decided?* The right
answers *what is happening right now?* They are one interface: a
card and a turn about the same task share the task's id, and
selecting either finds the other.

**The conversation.** A header — `✦ vera · ready`, or `thinking`,
`waiting for you`, `asked you something`, `could not answer`,
`offline — not on PATH` — then the thread, oldest to newest,
bottom-anchored, then the composer at the foot with its hint under
it. A turn is a role in the margin and its words: `you` and what you
typed; `✦` and her words, in secondary ink; her reflection as a
tinted block — the intent, the plan numbered, a question with the
attention mark, and the actions with their live state (`◌` waiting,
`◐` running, `✓ ran · what it printed`, `✕ failed`); `✓` and a
receipt when an action ran; `✓` and the outcome when a task the rail
knows finished; `✕` when something failed; `·` and one line when a
task began or came to need you. Every turn wears its age at the
edge. The composer is a raised field when it has focus (`› Ask
vera…`), flat otherwise; empty, `↵ sends · / find · : command · ⇥
dashboard`; while she is thinking, `vera thinking · esc cancels`.
An empty thread says once what the side is for.

**The dashboard.** `now`, with the attention count beside it, then
the modules that have anything, in this order: `needs you` (the
companion's proposed actions, each a card with the command it would
run; a pane that rang, notified or finished a bar while nobody
looked; a task a producer says is waiting or failed), `in progress`
(a producer's tasks by goal; then an agent rook can see producing in
a space no producer claims — one quiet card, `claude at work`, with
`no task was pushed for it`, and never an idle one), `recent` (what
finished, one flat line with the result), `spaces` (one row each:
the name, the tabs with their actors and marks, how long quiet — the
task's title is never repeated there). A card is the mark and the
title, then the space, the actor and the state, then the current
step wrapped to two lines. A needs-you card wears the attention edge
down its left; the selected card a band and what ↵ does at its edge
(`↵ runs`, `↵ open`, `↵ go see`, `↵ enter`). An empty module is left
out; an empty dashboard says `nothing running, nothing needs you`
once, above the spaces.

**Focus.** Three regions — the composer, the thread, the dashboard
— and the transient modes. Printable typing always reaches the
composer, wherever focus was. `⇥` cycles composer → dashboard →
thread; `⇤` the other way. `↑` from an empty composer walks into the
thread, on the latest turn; `↓` past the latest turn is the composer
again. In the dashboard `↑ ↓` (C-p C-n) move over the cards and the
turn about the selected card lights up in the thread; `↵` acts —
an approval runs, a task opens its agent's pane, a signal opens the
pane that rang, a space is entered. In the thread `↵` on a turn about
a task moves focus to its card; on a turn about a space, enters it.
The regions have a geometry, so they take the same vim motion the
panes inside a space take: the thread sits above the composer, the
dashboard is right of both, and `C-h` `C-j` `C-k` `C-l` walk it —
`C-l` to the dashboard, `C-h` back to the region it came from (the
thread with its turn still selected, the composer with its draft
intact), `C-k` up into the thread, `C-j` down to the composer. At an
edge the key is the view's again: `C-h` in the composer is still a
backspace, and there is nothing below the composer or beside the
dashboard.
`prefix-a` is home with the dashboard on the first card in progress,
`prefix-!` on the first that needs you; `:now` and `:vera` are the
same by name. Esc unwinds: a running request, a typed draft, focus
back to the composer, a subview, then nothing. Selection is never
activity or attention, and nothing that happens moves focus.

**Narrow glass.** Under 85 columns of canvas (`min_left + min_right
+ 1`) the cockpit shows one view at a time, `vera` or `now`, with a
switcher on its first row and the attention count on `now` while it
is hidden. The view follows focus — `⇥` to the dashboard is `now`,
`⇥` on is `vera` — and the draft, the selection and both scrolls
survive the switch. Orbit stays what it was; it never stands in for
the dashboard.

**What survives.** The thread, the draft, the focus, the selected
card, both scroll positions and the narrow view live on the root's
state, not on any space, so a visit to a space and back — or to
orbit and back — is the cockpit as you left it. Across a server
restart they do not, yet.

Finding (`/serv`) and commanding (`:`) take the canvas over as one
ranked list under one field, whatever the view; Esc is the cockpit
again. `:` completes `go`/`switch`, `new`, `rename`/`tab rename`,
`close`, `home`, `orbit`, `ledger`, `now`, `vera`.

## Orbit and ledger

Orbit (`prefix-s`, `:orbit`) is the spatial subview: the scope bar
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
    prefix-s     orbit (ledger, with zoom_view = "ledger")
    prefix-a     home, cursor on the first running item
    prefix-!     home, cursor on the first thing that needs you
    prefix-t     home, the field empty for a request
    prefix-/     home, finding
    prefix-:     home, a command
    prefix-C-o   the space before the last hop
    prefix-A     the legacy side panel, for a config that asked for it

At the root the space is not on the glass, so the keys that act on
one (`c`, `v`, `z`, …) are not taken there. `prefix-s` used to float
the fzf picker; that is still `rook pick`, and `prefix-a` used to
cycle the side panel, which `prefix-A` still toggles.

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
- `workspaces[].windows[].name` (minted), `named`, `program` (the live
  tool of the focused pane).
- `panes[].input`: `{"state": "human"}` or the actor and one of the
  five states, with `sinceMs`.
- `surfaces[]`: the rail's model, still published verbatim for the
  web client and any producer; an `agents` item may carry `actor`,
  `event` and `result` beside its rail fields.
- The restore file (`<sock>.state`, still `v2`) carries `name <n>`
  under a minted window and `origin <space>` under a global pin.

## Owed

Deliberately not in this pass:

- **A reflection from the real vera.** `vera say` answers in words;
  the shape above is the contract for when she answers in it, and
  answering a question means asking again with the answer in it.
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

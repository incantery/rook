# The plugin vocabulary

> Status: design, nothing implemented. This is the target the strip aims
> at and the spec the demos are written against. It is the result of one
> exercise — take every feature rook has, and try to express it in a
> generic system — and it is written to be *falsifiable*, so the places
> the exercise failed are recorded as prominently as the places it worked.

## The method

Rook's features look distinct and mostly are not. "The agent deck" is a
list of things with states, actions, and a detail view. So is the review
queue. So is the issue queue, which already left core and became a
provider without anybody having to design a queue abstraction — the
generic shape was there in `provider.Issue` before it was named.

So: reduce every feature to what it actually needs, keep the union, and
let the surfaces be views over one model rather than ten protocols. Where
a feature refuses to reduce, that refusal is information — it names a
primitive the model is missing, and it is much cheaper to find it here
than after the protocol ships.

## The item

Everything that is a *thing with a state that a human might act on*:

```
id            stable, plugin-scoped
title         one line
subtitle?     one line
state         semantic — "blocked", "running", "done". Never a colour.
fields[]      typed values (below) — the part badges could not carry
badges[]      semantic labels, no value
anchor?       where this lives (below)
detail?       a ref: document | diff | transcript | conversation
actions[]     id, label, confirm?, and whether it takes input
children[]?   the only structural difference between a list and a tree
provenance    which plugin, which source
created/updated
```

Core owns everything about how that renders: layout, virtualization,
selection, `j`/`k`, `/` to search, theming, density, accessibility. A
plugin supplies the values and the action ids. It never supplies frames
— that line is `docs/environments/VISION.md`'s and it is what keeps the
render path bounded by what core knows rather than by what a plugin
emitted.

### Fields, and why badges were not enough

The exercise below found numbers in three separate features, and a
badge cannot carry one: you cannot sum a badge, sort by it, or right-
align it in a column.

```
field: { key, label, kind, value, hint? }
kind:  text | number | money | duration | percent | timestamp | ratio
hint:  the column's intent — "cost", "elapsed", "progress"
```

Typed rather than pre-rendered so core can sort, aggregate, right-align
by decimal, and re-render on a theme or locale change. A plugin that
sends `"$1.24"` has already decided too much.

### Anchors

The one primitive the exercise found that has no equivalent anywhere
else, and rook's most distinctive capability:

```
anchor: { path, startLine, endLine, side, blobSha, commitSha?, text }
```

An anchor is a location in a working tree that **drifts**. The file
changes under it, and resolving it against today's content is a real
computation (`reanchor.go`, `anchor.zig`) that core already owns.
Threads, review leaves, and explore breadcrumbs are all anchored, and
none of them work if the anchor is an opaque string a plugin hands back.
So it is a field kind of its own, resolved by core, never by the plugin.

## The surfaces

| surface | what it renders | tenants |
|---|---|---|
| **List** | items, ranked | deck, attention, threads, workflow, issues |
| **Tree** | items with `children` | tasks, explore, review batches |
| **Table** | items as typed columns, sortable, summable | decisions, costs |
| **Detail** | a ref for the selected item | transcripts, diffs, documents |
| **Form** | questions out, answers in | asks |
| **Series** | a value over time, or a gauge | usage windows |
| **Decoration** | anchored items projected into an open document | gutter marks, diagnostics, thread markers |

Seven, not the five predicted. **Table** is the one the exercise added:
the decisions ledger has five numeric columns and exists to be summed
and sorted, and rendering it as a list of titles throws away the reason
anyone opens it.

**Decoration** came from a sharper reading of the same question, and it
is the one that pays for the anchor. Ask "is the diff viewer core?" and
the answer is neither yes nor no: *rendering a document with change
marks* is a primitive, and *where this particular diff comes from* is a
feature. Same for the gutter — the ability to put a mark beside a line
belongs to core; git's opinion about which lines changed does not.

Which means the gutter is not a surface of its own. It is **the List,
projected onto the document its items are anchored to** — the same items,
selected by whether their anchor falls in the open file:

| what appears in a gutter | it is |
|---|---|
| git change marks | anchored items, state = added/modified/deleted |
| LSP diagnostics | anchored items, state = error/warn/info, detail = message |
| thread markers | anchored items, state = open/resolved, detail = conversation |
| review leaves | anchored items, state = pending/resolved, actions |

Four features, one mechanism, and core is the only thing that needs to
know how a mark is drawn or how an anchor drifts. This is what the
`anchor` field is *for* — without it these are four bespoke integrations,
and with it they are one projection.

## The inbound verbs

A plugin answering questions is only half of it. The other half is a
plugin asking core to *do* something — which the provider protocol does
not have today, and whose absence is exactly why the edge protocol could
not become a provider and was stripped instead.

```
session.spawn(workspace, prompt) -> sessionId
session.send(sessionId, text)                  # refused at an interactive prompt
attention.raise(item)                          # "this needs a human"
notify(level, text)
```

`attention.raise` is the surprise. Attention is not a surface — it is a
verb any plugin may call, and core ranks and renders what it collects.
That makes "human attention is the scarce resource" a core primitive
that every plugin feeds, instead of a feature living in one of them.

**Landed, 2026-07-31: `attention.raise` and `session.spawn`.** The two
that were only ever schema. What building them cost, and what that says:

- **A pump.** A plugin that can only speak when spoken to cannot raise
  attention — the event that needs a human happens when nobody is asking,
  and a frame nobody reads sits in a pipe. So each up plugin gets a reader
  thread, exactly as a language server does, for exactly the same reason.
  This is the cost the old edge protocol never paid, and why it could not
  become a provider.
- **One grant list, both directions.** `grants` is a list of capabilities,
  not a list of things rook may do. `items.list` granted means rook may
  ask; `session.spawn` granted means the plugin may. The direction is
  inherent to the verb, and one list is what a human can read.
- **Provenance is not a parameter.** A raise records which plugin raised
  it, taken from the declaration and never from the params. A plugin that
  could name someone else as the source of an interruption is a plugin
  that can blame someone else for it.
- **`session.spawn` does not steal focus.** A plugin may put something on
  your screen; it does not get to take your keystrokes mid-sentence.

**Landed, 2026-08-04: `session.send`** — the membrane's hands, built for
the ask round trip (a phone-authored answer typed into the agent's
pane). Two gates, both non-negotiable: the target pane's foreground
must BE an agent TUI (claude by name or path — text typed into a shell
EXECUTES, and `node` is deliberately not enough, a REPL eats text as
code too), and a human who typed there in the last 5 seconds wins. The
text rides a bracketed paste and a CR submits it. Params are
`{pane, text}` — the pane id from `panes.activity`, so the caller
names a target the host re-verifies rather than a session the host
would have to resolve.

`notify` is still schema: it looks like a special case of
`attention.raise` with a level, and until something wants the
distinction it should not have one.

The Go SDK in rook-demos speaks them too, as of the same day. It needed
the same demux on the plugin side — a handler calling `Host.Raise` and
waiting would otherwise be waiting for itself, since the loop that would
read the reply is the loop running the handler. Handlers stayed
**sequential**: concurrency there would have been a silent contract change
for every plugin that keeps state, to buy throughput nothing asked for.

The shape that justifies the verb turned out to be `Plugin.Start` — a
goroutine for the life of the process, watching. A verb only reachable
from inside a handler would be a verb only usable when the human is
already looking.

## The exercise, honestly

Ten features. Five reduced cleanly; five did not, and the second column
is what each refusal bought.

| feature | fits? | what it forced |
|---|---|---|
| issue queue | ✅ | nothing — `provider.Issue` already *was* the item |
| workflow stages | ✅ | ordered list; the work is `session.spawn`, not display |
| agent deck | ⚠️ | **fields** (`costUsd`) and an interaction hint (`interactive`: wants a selection, not typed text) |
| tasks / explore | ⚠️ | **anchor** |
| attention | ⚠️ | an action carrying an editable **payload** (the drafted reply), not just an id |
| threads | ⚠️ | **anchor**, plus a conversation (fits as heterogeneous `children`) and an editable draft (a Form beside a Detail) |
| review queue | ⚠️ | **anchor**, and a gate whose state is a function of its children's |
| decisions ledger | ❌ | **Table** — five numeric columns, summed and sorted |
| asks | ❌ | **Form** |
| usage / costs | ❌ | **Series** |

**The prediction was wrong, and usefully.** Two refusals were expected
(asks → Form, usage → Series). Three were not: the ledger needs a Table,
numbers needed a type system, and anchors needed to be first-class. A
model that had shipped on the prediction would have had plugins encoding
cost as a string and code locations as opaque blobs — both unrecoverable
without a protocol break.

Nothing in the ten needed a layout language. That is the result worth
keeping: seven surfaces and a typed item covered every feature rook has,
so plugins never need to describe pixels.

### The eleventh, 2026-08-17: the start screen

The first feature since the exercise that had to be tried against the
model rather than predicted by it — and the first that refused the
**item** outright.

An item is *a thing with a state a human might act on*. A start screen
is not a list of those. Half of it is a header nobody acts on, the
sections are ordering rather than grouping, and the rows that ARE
pressable carry no state at all: they are "open this path" and "run that
command". Every way of forcing it into items was a lie about what the
payload holds — art in a `title`, a path in a `field` whose value cap is
32 bytes, a section as a parent item with a `state` of "".

So `intro.list` answers in **rows**, not items:

```
row: { kind, key?, label, detail?, path?, cmd? }
kind: art | heading | entry | blank
```

What did NOT change is the line that matters. A row says *what it is*
and *what pressing it reaches*; where it lands, how wide the column is,
what colour a jump letter wears, and what happens when the pane is too
narrow all stay core's. The refusal was about the item's SHAPE, not
about the boundary — which is the distinction that keeps "a new surface"
from becoming "a plugin drawing frames".

Two things it forced that are worth naming:

- **`cmd` as a row's payload.** The first time a plugin's answer names a
  core command instead of its own action id. It is not `items.act` in
  disguise: nothing goes back to the plugin, and the plugin cannot run
  the command — it can only put a name on a row for a human to press.
  That is a strictly weaker thing than a verb, and it is what a start
  screen needs.
- **A journal core has to keep.** Recency of *files you opened* is not
  derivable from outside: mtime knows what changed, git knows what you
  committed, and neither knows what you looked at. So core writes
  `$XDG_STATE_HOME/rook/oldfiles` and the plugin reads it — the same
  division as everywhere else, with core owning the fact and the plugin
  owning the opinion about it.

## The rule the strip follows

Every feature below reduces to *a mechanism core keeps* and *an instance
that leaves*. The strip removes instances and keeps mechanisms, which is
why it is not the same as deleting the feature list:

| kept (mechanism) | stripped (instance) |
|---|---|
| render a document with change marks | `diffdoc`, `diffsource` — where a diff comes from |
| put a mark beside a line | git's change computation, blame, branch in the bar |
| anchor and re-resolve a location | threads, review leaves, explore breadcrumbs |
| own a pty, a pane, a layout | the agent deck, the session view |
| a registry of workspaces | worktree creation and cleanup |
| the door | every endpoint behind it |

If a deletion cannot name the mechanism it leaves behind, it is removing
too much.

## Deliberately not here

- **A UI DSL.** See above: nothing needed one. Plugins that genuinely
  need custom pixels get a webview — out of process, separately
  accounted, explicitly heavier, never the default.
- **Provider-authored prompts.** A provider supplies data; rook builds
  the prompt (`buildTask`). A plugin that could write the prompt could
  write any prompt.
- **Colours, fonts, spacing.** Semantic state in, theme out.

## Open questions

1. **Detail refs.** Are `document`, `diff`, `transcript`, `conversation`
   one ref type with a kind, or four? Threads want a conversation *and*
   an editable draft on the same item, which suggests refs compose.
2. **Ranking.** The issue queue sorts mine-first-then-recent; attention
   sorts oldest-first. Does the plugin declare a sort, or supply
   signals and let core rank? Cross-source ranking (attention's actual
   job) argues for signals.
3. **Actions that take input.** "Approve" is an id; "reply with this
   text" is an id plus a payload the human edited. Does that fold into
   Form, or is it a third thing?

   **Answered, 2026-08-03, by the demo that needed it.** The agent
   plugin's "expand my reply" — type a rough answer, get back the
   polished one — forced the choice, and the answer is: **the payload
   belongs to the action, not to a Form.** Choosing an `INPUT_TEXT`
   action opens a one-line editor under the menu; the text rides
   `items.act` as an `input` param; ESC drops it and an empty Enter
   still refuses, because the refusal this replaced existed so a plugin
   never acts on nothing. Form stays reserved for what it was predicted
   for — asks, question trees, multi-field — and did not have to exist
   for a one-line payload. The interesting part: the payload's editor is
   MODAL text (`j` is a letter there, not a direction), which is the
   panel's first mode where typing beats navigation.
4. **Table vs List.** Is Table a distinct surface, or a List with a
   column projection? Cheaper if it's a projection.

Each is answered by a demo, not by argument.

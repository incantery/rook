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

Six, not the five predicted. **Table** is the one the exercise added:
the decisions ledger has five numeric columns and exists to be summed
and sorted, and rendering it as a list of titles throws away the reason
anyone opens it.

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
keeping: six surfaces and a typed item covered every feature rook has,
so plugins never need to describe pixels.

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
4. **Table vs List.** Is Table a distinct surface, or a List with a
   column projection? Cheaper if it's a projection.

Each is answered by a demo, not by argument.

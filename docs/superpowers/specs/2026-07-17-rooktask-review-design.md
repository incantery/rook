# RookTask & the Review Work-Type — Design

*A generic, per-developer unit of attention. Review is its first work-type.*

## Thesis

The bottleneck is no longer writing code; it is reviewing, understanding, and
directing work that agents wrote. Rook is the **private workspace** where a
developer figures out what they think — GitHub/Linear remain the **public
record**. This spec introduces the object that workspace is built on.

It is deliberately **not** a review tool. It is a threaded work-management
substrate. Review is the first work-type because it is the highest-value lens
and the one whose hard parts (anchoring, gating) are already solved in-repo
(`threads`, `reanchor.go`). Onboarding, ticket triage, and meeting prep are
later work-types on the same substrate — validated here by the schema seams,
not built.

---

## Two objects

**RookTask** — a unit of attention with a state and an optional anchor. It
nests (self-referential `parent_id`, arbitrary depth). Its `state` is an
opaque token the *work-type* interprets; the base object stays dumb. A task is
either **born in rook** (a crystallized review hunk, "understand these call
sites") or **mirrored from a source** (a Linear ticket, a GitHub PR) — only
born-in-rook ships now; mirroring is a schema seam (`origin`, `source_ref`).

**Thread** — the existing file-anchored conversation
(`2026-07-12-threads-design.md`). Unchanged in spirit; extended so a thread may
additionally reference a `rook_task_id`. A thread anchored to code with no task
is today's onboarding-style annotation; a thread on a review hunk is a local
conversation; a thread on a parent review task is a global/design conversation.

The relationship: **a thread attaches to a task by id (durable), or to code by
content-anchor (durable via `reanchor`).** It never attaches to a disposable
batch artifact. Local-vs-global review (the distinction NEXT.md treats as a
feature) falls out of *thread depth* in the task tree for free.

---

## Principles (the load-bearing ones)

1. **Disposable batch, durable anchored state.** A review batch is a pure
   function of the current diff — recompute it, never trust a stored copy of
   it. The only things that survive a re-diff are (a) a task's *disposition*
   (state) and (b) its *threads*, and both persist by **content-anchor**, not
   by hunk position. This is exactly `reanchor.go`'s invariant — stored anchor
   is ground truth, the mapped current range is a view, so drift cannot
   compound — applied to tasks instead of threads.

2. **The builder owns the tree shape.** Whether hunks are flat children, or
   grouped under intermediate nodes, or the tree is one level or five, is a
   decision of the tool that builds the review — not the schema. The schema
   grants arbitrary nesting for one nullable column and otherwise stays out of
   it. Slice one emits a flat tree; refinement is a builder change with no
   migration.

3. **The gate is a pure function of child states.** A review task is "ready"
   iff no descendant leaf is in a blocking state. There is no bespoke
   readiness engine — readiness is `SELECT`. The *verb* ("ready to commit" vs
   "ready to PR") is a label derived from the review's scope, not a distinct
   code path.

4. **Completeness is review's exception to "don't persist unspent attention."**
   In general you don't materialize a task for attention you haven't spent. But
   review's whole value is *proving nothing was silently skipped* — the thing
   GitHub's 5k-line PR cannot give you. So the review work-type materializes a
   child per hunk, and the cost stays cheap because (a) disposition can be
   **bulk** (defer 40 doc hunks in one action) and (b) a hunk-child is a cheap
   row with a recomputed score, **not** a thread. Threads stay sparse; task
   rows can be dense. Other work-types (onboarding) stay sparse.

5. **The host is a dumb store; inference is a claude session wielding rookctl.**
   Same architecture as threads ("the responder is a claude session … never
   host-side inference"). The host builds batches with pure git and serves
   rows. Haiku scoring runs as claude sub-agents driven by `rookctl`, writing
   scores back through the API. No model call ever originates in the host.

6. **No protobuf.** The polymorphic anchor is a `kind`-tagged discriminated
   union — the same shape `PaneRef` (`layout.ts`) already uses and round-trips.
   Code-anchor fields are promoted to real columns because `reanchor` must
   query them; rarer variant data rides a JSON `detail` bag. Proto is a
   cross-language-schema-at-scale tool; rook is one Go host + one TS frontend +
   one developer who values curling the API. Revisit only if hand-maintained
   Go/TS drift across many endpoints becomes the actual pain — not triggered by
   one union.

---

## Schema

New table, following the inline-`CREATE` + `ALTER`-migrations convention in
`registry.go`:

```sql
CREATE TABLE IF NOT EXISTS rook_tasks (
  id           INTEGER PRIMARY KEY,
  parent_id    INTEGER NOT NULL DEFAULT 0,   -- 0 = root; self-ref, arbitrary depth
  workspace    TEXT    NOT NULL,
  work_type    TEXT    NOT NULL,             -- 'review' (first); interprets `state`
  state        TEXT    NOT NULL,             -- opaque token, owned by work_type
  title        TEXT    NOT NULL DEFAULT '',

  -- Anchor: kind-tagged union. 'code' promotes the 7 threads columns so
  -- reanchor can map it; 'ref' points at an external subject; 'none' is a
  -- freeform task (meeting prep). Rare variant data rides `detail`.
  anchor_kind  TEXT    NOT NULL DEFAULT 'none', -- code | ref | none
  path         TEXT    NOT NULL DEFAULT '',
  start_line   INTEGER NOT NULL DEFAULT 0,
  end_line     INTEGER NOT NULL DEFAULT 0,
  side         TEXT    NOT NULL DEFAULT 'modified',
  blob_sha     TEXT    NOT NULL DEFAULT '',    -- content identity (anchor_blobs)
  commit_sha   TEXT    NOT NULL DEFAULT '',
  anchor_text  TEXT    NOT NULL DEFAULT '',
  anchor_ref   TEXT    NOT NULL DEFAULT '',    -- 'commit:<sha>', 'linear:INF-7', …

  origin       TEXT    NOT NULL DEFAULT 'rook', -- rook | mirror  (mirror = seam only)
  source_ref   TEXT    NOT NULL DEFAULT '',     -- foreign id when origin=mirror

  detail       TEXT    NOT NULL DEFAULT '',    -- JSON, work_type-owned (score, base, scope)
  created_at   TEXT    NOT NULL,
  updated_at   TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS rook_tasks_parent ON rook_tasks(parent_id);
CREATE INDEX IF NOT EXISTS rook_tasks_ws     ON rook_tasks(workspace, work_type);
```

Thread → task link (via the `migrations` ALTER list):

```sql
ALTER TABLE threads ADD COLUMN rook_task_id INTEGER NOT NULL DEFAULT 0; -- 0 = code-only
```

Notes:

- **The code-anchor columns are the same seven as `threads`.** A hunk-child
  reuses `anchorNow`/`mapRange` verbatim — no second anchoring implementation.
  Anchor snapshots continue to live in `anchor_blobs` (content-addressed,
  pruned when unreferenced); a hunk-child inserts its base-side blob exactly as
  `createThread` does.
- **`detail` is the fat-null-row escape hatch.** Parent review data (`base`,
  `scope`) and leaf score data live here, keyed by work-type — so the base
  table never sprouts a column that only one work-type reads. This is the
  "work-type owns role-specific data" discipline from the nesting discussion.
- **`origin`/`source_ref` are present but inert.** Slice one writes only
  `origin='rook'`. They exist so a mirrored ticket is *expressible* the day a
  connector lands, with zero migration — the aggregation vision validated by
  the schema, not built.

---

## The anchor

Three kinds, one union:

| kind   | identity                    | drift handling                         | used by            |
|--------|-----------------------------|----------------------------------------|--------------------|
| `code` | `blob_sha` + range + text   | `reanchor` maps onto today's file      | review hunk, onboarding line |
| `ref`  | `anchor_ref` (foreign id)   | reconcile against source (seam)        | parent review (`commit:<sha>`), mirrored ticket |
| `none` | —                           | none                                   | freeform task      |

The `code` kind is the one that ships with real drift handling, and it is free
because `reanchor.go` already exists. `ref` reconciliation (re-fetch the
upstream ticket, remap) is the same *shape* — stable foreign identity, computed
view, never-persisted merge — but is deferred with the connectors.

---

## Work-type contract

A work-type is defined by three things. The generic RookTask knows none of them.

1. **State machine** — the legal `state` tokens and transitions. Fixed per
   work-type in v1; **not** user-authored (that is Monday's workflow editor, the
   product we are explicitly not building).
2. **Gate** — a predicate over the task's descendants that yields readiness.
3. **Builder** — how tasks get born (a diff → children; a ticket → a mirror;
   a human → a freeform task).

---

## The review work-type

### State machine

Leaf (a hunk):

```
Proposed ──▶ Approved
   │    └──▶ Rejected          (wants change)
   │    └──▶ Deferred          (set aside without deep review; not blocking)
   └──▶ Conversation Pending ⇄ (a thread is open on it)
```

- **Blocking:** `Proposed`, `Conversation Pending`, `Rejected`.
- **Non-blocking:** `Approved`, `Deferred`.
- `Deferred` is the 3,000-doc-lines case — consciously included without deep
  review, so it does not block the commit but is recorded, so it is not *lost*
  (GitHub's actual failure). It may carry an optional **wake note**
  ("revisit after merge"); the wake does not fire in slice one, it is just
  stored — see Deferred seams.

Parent (a review) has a **derived** state, not a stored one: `Open` while any
descendant leaf is blocking, `Ready` otherwise.

### The gate verb

`Ready` resolves to a human verb by the review's `scope` (stored in the
parent's `detail`):

| scope      | subject                        | verb when Ready      |
|------------|--------------------------------|----------------------|
| `unstaged` | working-tree vs HEAD           | ready to **commit**  |
| `staged`   | index vs HEAD                  | ready to **commit**  |
| `commit`   | a specific commit (pinned SHA) | ready for **next steps** |
| `branch`   | branch vs merge-base           | ready to open **PR** |
| `pr`       | an existing PR                 | ready to **approve** |

One predicate (`no blocking descendant`), one lookup table. Not five features.

### Anchor of the parent

- `commit`, `pr`, `branch` pin to an immutable/known ref → children **never
  drift**; a re-run is idempotent.
- `unstaged`/`staged` track a **moving** working tree → children **reanchor**
  on every read via `anchorNow`, and a re-run **reconciles** (below).

State this out loud in the builder: a commit-review is frozen; an
unstaged-review is live.

### Builder — `rookctl review`

```
rookctl review --unstaged [-w ws]     prepare a review batch for the working tree
rookctl review --commit <sha> [-w ws] prepare a review of one commit
rookctl review --pr <n> [-w ws]       prepare a review of an existing PR
rookctl review show <task-id> [--json]  the batch: parent + children + scores + states
rookctl review score <child-id> <json>  write a leaf's score (called by the scorer agent)
rookctl approve <child-id>            } the disposition verbs — reuse the existing
rookctl reject  <child-id>            } approve/reject nouns where they fit; add
rookctl defer   <child-id> [note]     } `defer`, and a `--all`/glob for bulk.
```

Preparation (host-side, **pure git, no inference**):

1. Resolve the base ref for `scope`; diff it; split into hunks
   (`git diff --unified=0`, the parser already in `reanchor.go`).
2. Insert the parent review task (`work_type='review'`, `detail={base,scope}`).
3. For each hunk, insert a leaf child anchored `code` (base-side blob into
   `anchor_blobs`, exactly as `createThread`), `state='Proposed'`.
4. **Reconcile** (unstaged/staged re-run), deliberately dumb: for each fresh
   hunk, if a prior child's anchor maps to it (via `anchorNow`), carry its
   `state` and threads forward; anything with no prior match is new `Proposed`;
   a prior child whose anchor is gone is dropped (the reviewed code no longer
   exists, so its disposition is moot — not lost attention). No cleverness on
   splits/merges — a hunk that split into two becomes two `Proposed`. Reconcile
   is `reanchor` reused; we learn where the dumb version grates and add
   cleverness only there.

Scoring (a throwaway **`claude -p`** pass, spawned after prepare — same shape as
the drafter, no API key):

- Reads `rookctl review show` and scores every leaf in **one pass** — cheap,
  disposable metrics (risk, ease-of-understanding, importance-of-understanding,
  action-at-a-distance) plus a one-line category ("internal documentation, no
  production impact"). Writes back via `rookctl review score`. Per-hunk Haiku
  sub-agent fan-out is a *latency optimization* deferred until the single pass
  is measurably too slow — not built up front.
- Correlates related hunks where it cheaply can (same symbol, rename fan-out)
  and records the grouping as a hint in `detail`. Scores and grouping are
  **disposable** — recomputed every prepare, never migrated — so the metric set
  can change any week with no data problem.

The frontend then **ranks, and buckets** by category/score. It may collapse a
low-risk bucket, but hiding is a *view* decision the human drives — the batch
never withholds a hunk.

---

## rookctl surface (summary of additions)

```
rookctl review --unstaged|--staged|--commit <sha>|--branch|--pr <n> [-w ws]
rookctl review show <task-id> [--json]
rookctl review score <child-id> <json>
rookctl tasks [-w ws] [--work-type review] [--json]   list tasks (tree)
rookctl approve|reject <child-id>                      (existing verbs, extended)
rookctl defer <child-id> [note]
```

## Host API additions

- `POST /review` — prepare a batch for a scope; returns the parent task id.
- `GET  /tasks?workspace=&workType=` — the task tree; leaves carry the
  reanchored current range (computed on read, like `ThreadInfo`).
- `POST /tasks/{id}/state` — disposition (approve/reject/defer); bulk via a
  child-id list.
- `POST /tasks/{id}/score` — the scorer agent's write path.
- `GET  /review/{id}/gate` — the derived readiness + verb.

## Frontend surface

- A new `PaneRef` variant `{task}` (`layout.ts`) — restorable from its own data
  (the parent task id), per the pane-ref invariant. The review batch renders as
  a ranked, bucketed list of leaves; selecting one reveals its hunk in the
  diff (`EditorPane`) and its threads in the side pane.
- A review lives in the review `Mode` as its own `{task}` pane — **not** an
  agent-deck row (it has no pty; forcing it into the deck is a stretch we skip
  until we know how often we switch to reviews).
- Disposition and "drop a thought" are single keystrokes on a focused leaf —
  the whiteboard. A thought becomes a thread on that leaf; `rookctl` then feeds
  the whole open-thread set to a claude session that answers each, in place.

---

## What slice one ships

Connector-free, entirely born-in-rook:

- `rook_tasks` + the thread link column.
- `rookctl review --unstaged` → prepare (pure git) → scorer (`claude -p`,
  single pass) → ranked/bucketed batch.
- Disposition (approve/reject/defer, select-then-act multi-id) + the derived
  commit gate.
- Threads on leaves and on the parent; the existing "answer my notes" loop
  pointed at a review's threads.

Everything hard is deferred behind a seam that already exists in the schema.

## Deferred (seams, not built)

- **Mirroring/aggregation.** `origin`/`source_ref` + `ref` anchor reconciliation.
  First connector is GitHub (`gh` already shelled) — *after* the local loop is
  loved.
- **Deeper nesting / hunk correlation as tree structure.** Builder change only.
- **Wake conditions** beyond the two we will ever allow — *gate-passes*
  ("revisit after ready") and *anchor-changes* ("design shifted underneath",
  detectable today via `blob_sha`). Conditional approval = `Approved` + a wake.
  Slice one stores the note; firing it is v1.1. Hard-cap at these two — more and
  it is a rules engine.
- **Non-review work-types** (onboarding, ticket, meeting prep). Same substrate,
  sparse materialization, different builder/state-machine/gate.

---

## Decisions (v1 — dogfood first)

Resolved 2026-07-17, biased toward the leanest dogfoodable cut. Each carries the
signal that says "revisit now" — we adjust from use, not from guessing up front.

1. **Reconcile, dumbly.** Unstaged re-runs carry dispositions forward by
   content-anchor (`reanchor` reused); splits/merges become fresh `Proposed`; a
   vanished anchor drops. *Revisit when:* a split hunk repeatedly loses a
   disposition you wanted kept.
2. **Three dispositions, `Rejected` blocks.** No non-blocking reject; a
   "nit I'll fix later" is `Deferred` + note. *Revisit when:* you keep wanting
   to reject-without-blocking and Deferred feels like a lie.
3. **Scorer is a single `claude -p` pass.** No Haiku sub-agent fan-out.
   *Revisit when:* scoring latency on a real batch is annoying enough to
   parallelize.
4. **Select-then-act disposition**, `rookctl defer <id> <id> …` takes many ids;
   category is a ranking/bucket hint, not a filter operator. *Revisit when:*
   deferring the doc-hunk bucket by hand is tedious enough to want
   `defer --category docs`.
5. **Review is a `{task}` pane in the review `Mode`, not a deck row.**
   *Revisit when:* you context-switch to reviews often enough to want them in
   the agent deck.

Two genuinely-open threads that don't block slice one and want *use* to answer:
the wake-condition firing (conditional approval — stored now, fired in v1.1),
and whether the parent review's derived `Ready` should auto-advance a stage in
the existing `stages` workflow.

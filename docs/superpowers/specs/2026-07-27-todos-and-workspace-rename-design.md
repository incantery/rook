# Personal TODOs + workspace rename — design

**Date:** 2026-07-27
**Status:** drafted, two open choices at the end

## Problem

rook has no place to write down a thing you mean to do. Everything
task-shaped today is either machine-generated or read-only:

- The **issue queue** (`GET /workspaces/{ws}/issues`) is a live query against
  GitHub/Jira. `internal/tracker/tracker.go:1` is explicit that rook **reads,
  never mirrors** — nothing issue-shaped is persisted, so there is no row to
  add.
- **RookTask** (`rook_tasks`) is per-workspace and per-work_type, and the only
  work types are `review` and `explore` (`internal/host/tasksapi.go:169`),
  both built by machinery.
- The **attention inbox** is the one globally-scoped surface, but it is a
  derived view of sessions blocked on you. It dies with the ask.
- **Stages** are an ordered pipeline of slash commands, not a list.

So the personal, hand-authored todo — "fix the flaky replay test", "renew the
cert", "reply to Seth" — has nowhere to live.

## Decision

Add a `todo` work_type over the **existing** `rook_tasks` table, and make
`workspace = ''` a first-class value meaning *unscoped*.

Two consequences fall out, and they are the whole design:

### Scope is a real value, not a magic string

`rook_tasks.workspace` is `TEXT NOT NULL` (`internal/host/registry.go:155`).
Rather than add a scope column or reserve a sentinel name like `__global__`,
`''` means unscoped. This is already the house idiom — `decisions.workspace`
is `TEXT DEFAULT ''` for exactly this, and `decisions.rook_session` and
`decisions.cwd` alongside it. No migration, no new column, no reserved name a
user could collide with by naming a workspace badly.

### Global is the unfiltered view, not the sum of the per-workspace lists

The global list is "no workspace predicate," which equals the union of every
workspace's todos **plus** the ones with no workspace at all. Defining it as an
aggregate of per-workspace lists would leave the homeless todo with nowhere to
be filed, and would require inventing a fake workspace to hold it.

This framing also does the orphan cleanup for free — see *Workspace delete*
below.

## Data model

**No schema change.** `rook_tasks` already carries every column this needs:
`title`, the self-referential `parent_id` (so subtasks are free),
`anchor_kind = 'none'` — documented in the schema as *freeform* — and the
work_type-owned `detail` JSON bag. `internal/host/tasks.go:3` describes the
base object as "a generic, per-developer, nestable unit of attention", which is
this feature's spec sentence already written down.

- **work_type:** `todo`
- **state:** `open | done`, at every depth. Unlike `explore`
  (`validExploreState`, root vs leaf), a subtask and a root share one
  vocabulary — a subtask is just a smaller todo.
- **anchor_kind:** `none` for slice one.
- **workspace:** a registered name, or `''` for unscoped.

`anchor_kind = 'code'` ("todo about this line") is deliberately deferred, not
rejected — it would inherit read-time re-anchoring through `anchorTaskNow` for
nothing, but it needs `path`/`line` on the create path plus `confinePath`
validation, and it is not what makes the feature useful on day one.

## HTTP surface

Per-task verbs already live at global ids under `/tasks/{id}/…`
(`internal/host/tasksapi.go:5`), which is exactly the shape a workspace-less
todo needs. Three of the five endpoints below are new routes; two are new cases
in an existing handler.

| Route | Meaning |
| --- | --- |
| `POST /todos {title, workspace?}` | create; absent/empty `workspace` = unscoped |
| `GET /todos[?workspace=<name>]` | list — see the tri-state below |
| `POST /tasks/{id}/state {state}` | `open`/`done`; existing handler, new `validTodoState` |
| `POST /tasks/{id}/title {title}` | **new** — no title-update path exists today |
| `DELETE /tasks/{id}` | **new** — `deleteTaskTree` exists, the verb does not |

A single `POST /todos` with an optional workspace field beats a scoped
`POST /workspaces/{ws}/todos` plus a global `POST /todos`: one verb, one
handler, and the unscoped case is not a second-class path.

### The listing tri-state

Listing needs three states where the code has two. `listRootTasks(ws, workType)`
(`internal/host/tasks.go:164`) hard-codes `workspace = ?` as a required equality
filter, so `""` would mean *unscoped only* and there is no way to say *all*.

Signature becomes `listRootTasks(ws *string, workType string)`:

- `nil` → no predicate (the global view)
- `&"rook"` → that workspace
- `&""` → unscoped only

Over HTTP the distinction is `r.URL.Query().Has("workspace")` — present-but-empty
is unscoped, absent is all. It is a real distinction in `net/url` and both
clients (rookctl, the frontend) construct their own requests, but it is subtle
enough to deserve the doc comment it will get.

The one existing caller (`internal/host/tasksapi.go:77`) passes `&name`.

**Ordering:** `ORDER BY (state = 'done'), id DESC` — done sinks, newest first
within each group. Today's bare `id DESC` would bury an open todo under a week
of finished ones.

### An aside that this fixes

`internal/host/exploretasks.go:28` claims "Listing rides
`GET /tasks?workType=explore`". That route is not registered — `host.go:571`
registers only the `/tasks/` subtree, so `/tasks` redirects into `handleTask`,
fails `ParseInt` on an empty id, and 404s. The comment describes a route that
was assumed and never built. `GET /todos` is the same shape; if we would rather
have one generic lister, `GET /tasks?workType=&workspace=` subsumes both and
retires the stale comment.

## Behavior

### Worktrees do not inherit

When a worktree is carved off `rook`, its todo list is its own — it does **not**
show the source workspace's todos.

This deliberately diverges from the `ws.Name || ws.WorktreeOf` pattern used by
`issues.go:53`, `workflow.go:30`, and `allowedWorkspace` (`host.go:616`). Those
inherit *configuration* from the source — which trackers to query, whether to
appear in a demo. A todo is *content*, and inheriting content would make every
worktree's list a duplicate of its parent's at exactly the moment you carved a
worktree to narrow your focus to one issue.

The global view is where you see everything anyway, which makes this cheap to
reverse if it feels wrong in practice.

### Workspace delete reassigns, never deletes

`DELETE /workspaces/{name}` drops only the registry row
(`internal/host/registry.go:337`) — it does not cascade to `rook_tasks`. Add,
inside that path:

```sql
UPDATE rook_tasks SET workspace = '' WHERE workspace = ? AND work_type = 'todo'
```

The todo genuinely has no workspace once the workspace is gone, so `''` is the
honest value, and the item stays in your list instead of silently evaporating.

Note this is belt-and-braces: because the global view carries no workspace
predicate, an orphaned todo would keep appearing there even if this reassign
were missed entirely. A strict-union design would have needed the reassign to
be correct to avoid losing data; this one only needs it to be tidy.

`review` and `explore` tasks are **not** reassigned — they are meaningless
without their repo. Their existing orphaning behavior is untouched here.

## Workspace rename

### Why it ships with this

There is no rename anywhere today: not in the host API, not in `rookctl`, not
in the app. The workspace name is the `workspaces` primary key
(`internal/host/registry.go:69`) and is carried by value as an unenforced
foreign key across six other tables.

That has been survivable because everything keyed by workspace is either
regenerable (reviews, recents, stages) or historical (decisions). A personal
todo list is neither — it is hand-authored content you would notice losing.
Adding todos is what makes rename worth building.

### Surface

`POST /workspaces/{name}/rename {to}` — matches the existing `action` sub-path
convention in `handleWorkspace` (`/status`, `/spawn`, `/review`, `/explore`).

Validation, in order:

- `to` trimmed; empty → 400.
- `name` unknown → 404.
- `to` already registered → 409.

Renaming with live sessions is allowed. Nothing about a session's identity
depends on the name being stable — see the in-memory sweep below.

### The transaction

Seven statements, one `tx`, no schema change:

```sql
UPDATE workspaces SET name        = ? WHERE name        = ?;  -- the PK
UPDATE workspaces SET worktree_of = ? WHERE worktree_of = ?;  -- children
UPDATE stages     SET workspace   = ? WHERE workspace   = ?;
UPDATE threads    SET workspace   = ? WHERE workspace   = ?;
UPDATE rook_tasks SET workspace   = ? WHERE workspace   = ?;
UPDATE recents    SET workspace   = ? WHERE workspace   = ?;
UPDATE decisions  SET workspace   = ? WHERE workspace   = ?;
```

`worktree_of` is the one that is easy to miss: worktrees point at their source
*by name*, so renaming a source without it silently detaches every worktree
carved from it. `thread_comments` and `anchor_blobs` key off thread id and sha
respectively and need nothing.

Then, outside the tx and under `h.mu`, sweep live sessions — `info.Workspace`
is held in memory (`internal/host/host.go:48`) and is what
`workspaceList()` groups on:

```go
for _, s := range h.sessions {
    if s.info.Workspace == old { s.info.Workspace = to }
}
```

### Config keys are reported, not rewritten

Four per-workspace config key families are name-suffixed — `jira-project-<ws>`,
`branch-prefix-<ws>`, `branch-delimiter-<ws>`, `workflow-<ws>`
(`internal/config/config.go:248-277`) — plus any `workspace-allow` entry.

The host does **not** rewrite them. Nothing in `internal/config` writes the
user's config file in production (only tests do); config is hand-edited and
hot-read, and rename is not the place to breach that boundary — a rewrite would
have to preserve comments, ordering, and both the legacy and TOML formats.

Instead the rename response returns the affected keys:

```json
{"workspace": {...}, "configKeys": ["branch-prefix-rook", "workflow-rook"]}
```

`rookctl` prints them as "also update these lines in ~/.config/rook/config";
the UI shows the same list. The rename succeeds either way — a stale
`branch-prefix-rook` after renaming to `corvid` degrades to the `rook/` default,
which is a cosmetic miss, not a broken workspace.

### Edge: orphaned rows collide with a reused name

Delete workspace `foo` (its `stages` rows orphan, since delete does not
cascade), then rename `bar` → `foo`. The `UNIQUE(workspace, idx)` constraint on
`stages` (`registry.go:105`) fires and the whole rename rolls back.

This is the correct outcome, but the error must be legible: catch the
constraint violation and return 409 with "orphaned rows from a previous
workspace named foo — remove them or pick another name" rather than a raw
SQLite string. `recents` has the same shape via `recents_ws`.

## Non-goals

- **No due dates, priorities, tags, or reminders.** `detail` is a JSON bag
  owned by the work_type; any of these can land there later without a
  migration. Slice one is a title, a state, and a scope.
- **No code anchors on todos** — deferred, as above.
- **No tracker sync.** A todo is yours. Mirroring to GitHub/Jira would re-open
  exactly the tar pit `internal/tracker/tracker.go:1` was written to stay out
  of.
- **No config rewriting on rename** — reported, not edited.
- **No cascade cleanup for `review`/`explore` on workspace delete.** Existing
  behavior, separate concern.

## Implementation sketch

- `internal/host/todotasks.go` (new, modeled on `exploretasks.go`):
  `validTodoState`, `handleTodos` (GET + POST).
- `internal/host/tasks.go`: `listRootTasks` takes `ws *string`; add
  `setTaskTitle(id, title)` alongside `setTaskState`; add the `(state='done')`
  ordering term.
- `internal/host/tasksapi.go`: `handleTask` gains `DELETE` (wrapping the
  existing `deleteTaskTree`) and a `title` action; `handleTaskState` gains the
  `todo` work_type case next to `review` and `explore`.
- `internal/host/host.go`: register `/todos`; add the `rename` action to
  `handleWorkspace`.
- `internal/host/registry.go`: `renameWorkspace(old, to)` — the seven-statement
  tx; add the todo reassign to the delete path.
- `cmd/rookctl/main.go`: `todo add|ls|done|rm`, and `ws rename <old> <new>`.
- Frontend: `hostapi.ts` types + methods; a todo panel. The Inbox is the
  closest existing surface to model it on — a global overlay on a hotkey.

## Testing

- **Scope tri-state** — table test over `listRootTasks`: `nil` returns todos
  from two workspaces *and* an unscoped one; `&"rook"` returns only rook's;
  `&""` returns only the unscoped.
- **Ordering** — a done todo created after an open one sorts below it.
- **Worktree non-inheritance** — a todo on `rook` does not appear in `rook-t1`'s
  list.
- **Delete reassign** — todo on `foo`, `DELETE /workspaces/foo`, todo survives
  with `workspace == ''` and still appears in the global list. Assert a
  `review` task in the same workspace is *not* reassigned.
- **Rename, full sweep** — build a workspace with a todo, a thread, a stage, a
  recent, a decision, and a carved worktree; rename; assert all six move and
  `worktree_of` follows. Assert a live session's `info.Workspace` updated.
- **Rename collisions** — target name taken → 409; the orphaned-`stages` case
  → 409 with the legible message and *no partial write* (assert the old name
  still resolves).
- **Config key report** — `branch-prefix-old` and `workflow-old` set, rename
  returns both key names and does not modify the config file on disk.

## Open choices

**1. Does `GET /todos` exist, or does a generic `GET /tasks` subsume it?**

- [ ] `GET /todos` — a dedicated route; simplest to reason about, but it is
      the third list surface for one table.
- [ ] `GET /tasks?workType=todo&workspace=` — one generic lister, and it
      retires the stale `exploretasks.go:28` comment by making that route real.
      *(Recommended — the work_type param already exists on the workspace-scoped
      lister, so this is the same filter one level up.)*

**2. Should rename ship in the same slice as todos, or immediately after?**

- [ ] Same slice — the todo list is the thing that makes losing a name
      expensive, so shipping the mitigation with the risk is tidy.
- [ ] Immediately after — todos are useful the day they land and rename is
      strictly additive; splitting keeps the first slice small enough to
      review in one sitting. *(Recommended.)*

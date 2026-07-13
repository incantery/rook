# Threads: generic AI conversations anchored to files

*Design spec, 2026-07-12. Ratified in conversation with Seth. Supersedes
the narrower "review threads" framing of the Monaco sequence: threads are
a first-class conversation primitive; code review is one use of them.*

## Purpose

A threaded conversation between the user and an AI, anchored to a file
range in a workspace. Code review is the first use (comment on an agent's
diff, the agent responds); discussing a claude plan is the same mechanism
because **plans are files** (PLAN.md, docs/plan.md — skills already write
them). One anchor type covers code, diffs, plans, and specs; the ` g diff
pane and ` e viewer are the commenting surfaces.

The responder is not a new inference tier. A claude session — the one
already working in the workspace when there is one — answers threads
using `rookctl` as its hands, taught by a shipped skill. Replies are tool
calls back into rook. The host stays a dumb thread store behind an
agent-legible API (README decisions 2/3/8: host API, no side doors,
rookctl parity).

## The loop

1. User comments on ranges in the review pane / file viewer. Each comment
   creates a thread with `state=pending` — host-stored immediately, so a
   reload never eats a half-written review.
2. User **submits**. All pending threads in the workspace flip to `open`,
   and the host actuates a nudge: a host-built prompt typed into the
   workspace's correlated live claude session (drafter-approve style pty
   write) — or, when no session is live, `spawnTask` starts a responder
   with the same prompt.
3. Claude runs the `rook-threads` skill: `rookctl threads pending --json`,
   then per thread decides — answer (reply), change code (edit, commit,
   reply citing the commit), or ask back (reply with a question). It may
   fan out subagents for large batches; every reply converges on rookctl.
4. Replies and resolves land in the host as they happen. Threads that now
   need the user surface in the attention inbox; jumping opens the review
   pane at that thread.
5. Either side resolves. `resolved_by` records who; a user reopening an
   agent-resolved thread is a recorded negative verdict — ledger-grade
   data for the autonomy gate (read in a later slice, recorded now).

## Data model (host SQLite, host-only writer)

```sql
CREATE TABLE threads (
    id           INTEGER PRIMARY KEY,
    workspace    TEXT NOT NULL,
    path         TEXT NOT NULL,              -- repo-top-relative
    start_line   INTEGER NOT NULL,           -- 1-based, inclusive
    end_line     INTEGER NOT NULL,
    side         TEXT NOT NULL DEFAULT 'modified', -- modified|original (diff side)
    blob_sha     TEXT NOT NULL,              -- content identity at anchor time
    commit_sha   TEXT NOT NULL DEFAULT '',   -- HEAD at anchor time, informational
    anchor_text  TEXT NOT NULL,              -- the anchored lines verbatim
    state        TEXT NOT NULL DEFAULT 'pending', -- pending|open|resolved
    resolved_by  TEXT NOT NULL DEFAULT '',   -- ''|user|agent
    agent_reopens INTEGER NOT NULL DEFAULT 0, -- times a user reopened an agent-resolve
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL,
    submitted_at TEXT
);
CREATE TABLE thread_comments (
    id            INTEGER PRIMARY KEY,
    thread_id     INTEGER NOT NULL,
    author        TEXT NOT NULL,             -- user|agent
    agent_session TEXT NOT NULL DEFAULT '',  -- transcript id when known
    body          TEXT NOT NULL,
    created_at    TEXT NOT NULL
);
CREATE TABLE anchor_blobs (
    sha     TEXT PRIMARY KEY,                -- git blob hash of content
    content BLOB NOT NULL
);
```

- `blob_sha` anchors to **content**, not a commit — it works for
  uncommitted working-tree edits (the diff pane's modified side IS the
  working tree). `commit_sha` is display-only ("anchored at abc123").
- `anchor_blobs` holds the full file snapshot at anchor time, deduped by
  sha, **in rook.db — never written into the user's repo**. Blobs prune
  when no unresolved thread references them; snapshots share the review
  pane's 2 MB cap. Resolved/outdated threads still render from
  `anchor_text`.
- `outdated` is not a state — it is an anchor property computed on read.
- Reopen flips `resolved` back to `open` and clears `resolved_by`; when
  the cleared value was `agent`, `agent_reopens` increments — the
  negative-verdict datum, recorded now, read in slice 3.
- No batch table: submit stamps `submitted_at`; the timestamp groups a
  review if anything ever cares. First comment is created with its thread.

## API (new `handleWorkspace` actions; auth, JSON, and error conventions
match the review endpoints)

- `POST /workspaces/{ws}/threads` — body `{path, startLine, endLine,
  side?, body}` → creates thread (pending) + first comment. The host
  snapshots the anchored content now: working tree via `confinePath` +
  `os.ReadFile`, or `git show <base>:<path>` when `side=original` (so
  deleted lines are commentable). 400 on bad path / >2 MB.
- `GET /workspaces/{ws}/threads?state=&path=` — threads with comments
  inline (threads are small; one call renders a pane), each carrying its
  re-anchored current range and `outdated` flag.
- `POST /threads/{id}/comments` — `{body, author, agentSession?}`.
  Thread ids are global (one SQLite), so per-thread routes live at top
  level — `rookctl reply <id>` needs no `-w`. Author is **declared, not
  authenticated** — every client shares the one localhost token; the
  webview says `user`, the skill's rookctl says `agent`. Trust-based by
  design.
- `POST /threads/{id}/resolve` `{by}` and `POST /threads/{id}/reopen`.
- `POST /workspaces/{ws}/threads/submit` — flips pending→open, then
  nudges. Returns `{mode: "typed"|"spawned", rookSession, count}`.
  **Re-nudgeable:** with zero pending but open threads still awaiting the
  agent (last comment by user), submit fires the nudge again — covers
  "claude missed it" and "spawn failed" with no new state. Zero pending
  and nothing awaiting → 400 "nothing to submit".
- Attention: the `/attention` payload grows a `threads` section — threads
  needing the user (open + last comment by agent, plus agent-resolved
  within the last 24 h). Old frontends ignore the field; the new frontend
  tolerates its absence (fail open both directions — the protocol-skew
  rule).

The nudge is **one host-built string** used by both actuation paths:

> You have {N} review comments in {workspace}. Use the rook-threads
> skill to address them.

## rookctl

```
rookctl threads [-w ws] [--json]            # list: state, path:range, last comment
rookctl comment [-w ws] <path>:<a>[-<b>] <text…>   # create a pending thread
rookctl submit [-w ws]                      # submit batch + nudge
rookctl threads pending [-w ws] [--json]    # agent pull: open + last-comment-by-user
rookctl reply <thread-id> <text…>           # agent reply (author=agent)
rookctl resolve <thread-id> | reopen <thread-id>
rookctl install-skill                       # write ~/.claude/skills/rook-threads/
```

Inside a rook window, `ROOK_WORKSPACE` defaults `-w` and `ROOK_SESSION`
attributes `agent_session` (via the existing claim machinery). "Needs
reply" is derived (open + last comment authored by user), never stored.

## Re-anchoring (read-time, never persisted)

The stored anchor is immutable ground truth; re-anchoring is a view:

1. Hash the current working-tree file — git's blob hash is
   `sha1("blob <len>\0" + content)`, computed in Go, no subprocess.
2. Same sha → range valid as stored (the common case: one hash, no git).
3. Different sha → `git diff --no-index <tmp:stored-blob> <tmp:current>`
   (scratch files, the 5 s `gitOut` timeout), map the range through
   hunks: untouched → shift by cumulative delta; overlapped → `outdated`
   (original range + `anchor_text` render, GitHub semantics); file gone →
   outdated.
4. Memoized per `(blob_sha, current_sha)` pair — a pane's polls never
   re-diff an unchanged file, and one diff serves every thread on that
   file version.

Not doing: cross-file move tracking (extracted code → thread goes
outdated; the conversation history says why), and no write-back of
computed ranges (drift must not compound).

## The rook-threads skill

Ships in the rook repo; `rookctl install-skill` writes
`~/.claude/skills/rook-threads/SKILL.md` (idempotent, the install-hooks
precedent). It teaches the loop, not policy:

1. `rookctl threads pending --json` — each thread: path, current range,
   outdated flag, full comment history.
2. Per thread: answer / change code (commit, reply citing it) / ask back.
3. `rookctl reply`, `rookctl resolve` when it believes a thread is done.
4. Large batches: subagent fan-out is claude's call; all replies converge
   on rookctl.

No completion callback — replies land in the host as they happen. A
nudge typed into a busy session queues in claude's input box and runs
after the current turn (same as drafter approvals today).

## UI

Threads are per `(workspace, path)`; both panes fetch what's visible.

- **Gutter markers** (Monaco glyph margin) with comment counts; outdated
  threads get a distinct badge and render `anchor_text`.
- **Composer**: select range → "Comment" (Monaco context-menu action +
  ⌘⇧M inside Monaco's keybinding layer — the backtick prefix is
  untouched) → view-zone textarea → save creates a pending thread.
  Framework-free DOM in `editor.ts` style; on the diff pane, zones attach
  to the side being commented.
- **Thread widgets**: click a marker → view zone with history, reply box,
  resolve/reopen. Collapsed by default.
- **Submit**: the editor head shows "submit N comments" when pending
  threads exist; result flashes `typed into window 2` / `spawned
  responder`.
- **Inbox**: thread rows (`💬 ws · path:line — "last reply…"`); Enter
  jumps workspace → review pane → thread expanded. Jump-only this slice.
- Refetch on focus alongside the existing diff refresh; stale-daemon 404
  → the review pane's existing flash + inline-error pattern.

Not in this slice: thread counts on strip tabs/cards, notifications for
replies (the inbox suffices), comment editing/deleting (append-only).

## Slices

- **2a — host domain, CLI-provable.** Tables + migrations, all endpoints,
  re-anchor engine, nudge actuation, rookctl commands. The full
  conversation loop works from two terminals before any UI exists.
- **2b — threads in the panes.** hostapi methods, gutter decorations,
  composer, widgets, submit button, focus refetch.
- **2c — skill + inbox.** rook-threads skill + install-skill, attention
  `threads` section, inbox rows + jump. Live E2E with a real claude
  session.

## Error handling

- Stale daemon 404 → flash + inline error, never fatal.
- Actuation failure after submit leaves threads `open`; re-submit
  re-nudges. Nothing is lost.
- Missing blob (pruned, db hiccup) → render from `anchor_text` as
  outdated; never an error.
- `confinePath` on every path input; 2 MB anchor cap → 400.
- SQLite concurrency: host is the only writer, as everywhere.

## Testing

- **Go (2a):** lifecycle over httptest (pending→open→agent-reply→resolve
  →reopen, author attribution); re-anchor table (same-sha fast path,
  shift, overlap-outdated, deleted-file); submit actuation against a
  pipe-pty fake window (`draftHost` pattern); blob dedupe + prune;
  re-nudge semantics; confinement.
- **verify skill (2a):** isolated host, full loop from two terminals —
  comment → submit → scripted "claude" replies via rookctl → pending
  drains → inbox payload shows the reply.
- **GUI checklist (2b/2c, Seth):** comment on a diff range, submit, watch
  the live session pick it up, reply appears in pane + inbox, resolve,
  reopen, outdated rendering after the agent commits.

## Deferred (explicitly)

- Reading the verdict data (autonomy gating) — slice 3, as ratified.
- Cross-file re-anchoring, comment editing, GitHub mirroring (never —
  threads are rook-native by design).

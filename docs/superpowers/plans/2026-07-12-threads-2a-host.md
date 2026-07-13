# Threads Slice 2a: Host Domain + rookctl — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** File-anchored AI conversation threads as a host domain — store, re-anchoring, HTTP API, nudge actuation, and rookctl parity — so the full comment→submit→claude-replies loop works from two terminals with no UI.

**Architecture:** Threads live in the host's SQLite (host-only writer, like decisions). Anchors are content-identified (git blob hash of the file at comment time; snapshot kept in `anchor_blobs`, never written to the user's repo). Re-anchoring is a read-time view: hash-compare, then `git diff --no-index` hunk mapping, memoized. Submit flips pending→open and nudges the workspace's claimed claude session via pty write, else `spawnTask`s a responder.

**Tech Stack:** Go (stdlib + mattn/go-sqlite3 already vendored), existing host helpers (`gitOut`, `confinePath`, `repoTop`, `reviewBaseFor`, `writeJSON`, `spawnTask`), httptest for tests.

**Spec:** `docs/superpowers/specs/2026-07-12-threads-design.md` — this plan implements the "2a" slice only (2b pane UI and 2c skill+inbox get their own plans after 2a merges).

## Global Constraints

- Branch: `threads-host` off `main`; one PR, one commit per task.
- Host never writes into user repos — snapshots go in rook.db only.
- Every git subprocess uses the `gitOut`/`runGit` discipline: LookPath with `/usr/bin/git` fallback, context timeout (5 s here).
- Every client-supplied path goes through `confinePath` before any file read.
- Anchor snapshots share the review cap: `reviewMaxSide` (2 MB) and `reviewSniffLen` binary sniff from `internal/host/review.go`.
- Timestamps stored as `time.RFC3339Nano` strings (registry convention).
- Author on comments is declared, not authenticated (`user`|`agent`) — one localhost token by design; reject any other value with 400.
- Fail open: unknown/missing anchor blob renders `outdated` from `anchor_text`, never an error.
- Hygiene per task commit: `go build ./internal/... ./cmd/... && go vet ./internal/... ./cmd/... && go test ./internal/host/` (ignore macOS `ld: warning` noise; `build/ios` is excluded on purpose).
- Commit messages follow repo style (lowercase subject, story in the body) and end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Schema + thread store (registry methods)

**Files:**
- Modify: `internal/host/registry.go` (append to the `schema` const, ~line 68–116)
- Create: `internal/host/threads.go` (types + store methods; HTTP handlers arrive in Tasks 3–5)
- Test: `internal/host/threads_test.go`

**Interfaces:**
- Consumes: `registry.db` (`*sql.DB`), `loadRegistry()` test pattern from `attention_test.go:draftHost`.
- Produces (later tasks depend on these exact names):
  - `type ThreadInfo struct` / `type ThreadComment struct` (JSON shapes below)
  - `(r *registry) createThread(t *ThreadInfo, body string) (int64, error)`
  - `(r *registry) getThread(id int64) *ThreadInfo` (nil = not found; comments populated)
  - `(r *registry) listThreads(ws, state, path string) []*ThreadInfo` (""=no filter; comments populated; id order)
  - `(r *registry) addThreadComment(id int64, author, agentSession, body string) error` (`sql.ErrNoRows` = no such thread)
  - `(r *registry) resolveThread(id int64, by string) error` / `(r *registry) reopenThread(id int64) error` (`errThreadState` = wrong state)
  - `(r *registry) submitThreads(ws string) int` / `(r *registry) threadsAwaitingAgent(ws string) int`
  - `(r *registry) putAnchorBlob(sha string, content []byte)` / `(r *registry) getAnchorBlob(sha string) []byte` / `(r *registry) pruneAnchorBlobs()`

- [ ] **Step 1: Append the three tables to the schema const in `registry.go`**

Inside the backtick `schema` string, after the `stages` table:

```sql
CREATE TABLE IF NOT EXISTS threads (
	id            INTEGER PRIMARY KEY,
	workspace     TEXT NOT NULL,
	path          TEXT NOT NULL,
	start_line    INTEGER NOT NULL,
	end_line      INTEGER NOT NULL,
	side          TEXT NOT NULL DEFAULT 'modified', -- modified|original (diff side)
	blob_sha      TEXT NOT NULL,              -- content identity at anchor time
	commit_sha    TEXT NOT NULL DEFAULT '',   -- HEAD at anchor time, informational
	anchor_text   TEXT NOT NULL,              -- the anchored lines verbatim
	state         TEXT NOT NULL DEFAULT 'pending', -- pending|open|resolved
	resolved_by   TEXT NOT NULL DEFAULT '',   -- ''|user|agent
	agent_reopens INTEGER NOT NULL DEFAULT 0, -- user reopened an agent-resolve (verdict datum)
	created_at    TEXT NOT NULL,
	updated_at    TEXT NOT NULL,
	submitted_at  TEXT
);
CREATE TABLE IF NOT EXISTS thread_comments (
	id            INTEGER PRIMARY KEY,
	thread_id     INTEGER NOT NULL,
	author        TEXT NOT NULL,              -- user|agent (declared, not authenticated)
	agent_session TEXT NOT NULL DEFAULT '',
	body          TEXT NOT NULL,
	created_at    TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS anchor_blobs (
	sha     TEXT PRIMARY KEY,                 -- git blob hash of content
	content BLOB NOT NULL
);
```

New tables under `CREATE TABLE IF NOT EXISTS` need no migration entries.

- [ ] **Step 2: Write the failing store test**

`internal/host/threads_test.go`:

```go
package host

import (
	"testing"
)

// threadReg is a registry over a throwaway data dir — store tests need
// no Host, no HTTP.
func threadReg(t *testing.T) *registry {
	t.Helper()
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	r := loadRegistry()
	if r.db == nil {
		t.Fatal("test registry has no db")
	}
	return r
}

func TestThreadStoreCRUD(t *testing.T) {
	r := threadReg(t)

	id, err := r.createThread(&ThreadInfo{
		Workspace: "ws", Path: "a.txt", StartLine: 2, EndLine: 3,
		Side: "modified", BlobSHA: "abc", CommitSHA: "deadbeef",
		AnchorText: "two\nthree",
	}, "why is this like this?")
	if err != nil {
		t.Fatal(err)
	}

	th := r.getThread(id)
	if th == nil || th.State != "pending" || len(th.Comments) != 1 {
		t.Fatalf("getThread: %+v", th)
	}
	if th.Comments[0].Author != "user" || th.Comments[0].Body != "why is this like this?" {
		t.Fatalf("first comment: %+v", th.Comments[0])
	}

	// list filters: workspace, state, path
	if got := len(r.listThreads("ws", "", "")); got != 1 {
		t.Fatalf("list ws: %d", got)
	}
	if got := len(r.listThreads("other", "", "")); got != 0 {
		t.Fatalf("list other ws: %d", got)
	}
	if got := len(r.listThreads("ws", "open", "")); got != 0 {
		t.Fatalf("list open: %d", got)
	}
	if got := len(r.listThreads("ws", "pending", "a.txt")); got != 1 {
		t.Fatalf("list pending a.txt: %d", got)
	}

	// submit: pending → open, stamped
	if n := r.submitThreads("ws"); n != 1 {
		t.Fatalf("submit: %d", n)
	}
	th = r.getThread(id)
	if th.State != "open" || th.SubmittedAt == nil {
		t.Fatalf("after submit: %+v", th)
	}
	// awaiting agent: open + last comment by user
	if n := r.threadsAwaitingAgent("ws"); n != 1 {
		t.Fatalf("awaiting: %d", n)
	}

	// agent replies — no longer awaiting
	if err := r.addThreadComment(id, "agent", "t1", "moved the guard"); err != nil {
		t.Fatal(err)
	}
	if n := r.threadsAwaitingAgent("ws"); n != 0 {
		t.Fatalf("awaiting after reply: %d", n)
	}
	th = r.getThread(id)
	if len(th.Comments) != 2 || th.Comments[1].AgentSession != "t1" {
		t.Fatalf("comments after reply: %+v", th.Comments)
	}

	// resolve by agent, user reopens → agent_reopens increments
	if err := r.resolveThread(id, "agent"); err != nil {
		t.Fatal(err)
	}
	th = r.getThread(id)
	if th.State != "resolved" || th.ResolvedBy != "agent" {
		t.Fatalf("after resolve: %+v", th)
	}
	if err := r.resolveThread(id, "user"); err != errThreadState {
		t.Fatalf("double resolve: %v", err)
	}
	if err := r.reopenThread(id); err != nil {
		t.Fatal(err)
	}
	th = r.getThread(id)
	if th.State != "open" || th.ResolvedBy != "" || th.AgentReopens != 1 {
		t.Fatalf("after reopen: %+v", th)
	}
	if err := r.reopenThread(id); err != errThreadState {
		t.Fatalf("reopen non-resolved: %v", err)
	}

	// unknown ids
	if r.getThread(999) != nil {
		t.Fatal("ghost thread")
	}
	if err := r.addThreadComment(999, "user", "", "x"); err == nil {
		t.Fatal("comment on ghost thread must error")
	}
}

func TestAnchorBlobs(t *testing.T) {
	r := threadReg(t)
	r.putAnchorBlob("sha1", []byte("hello\n"))
	r.putAnchorBlob("sha1", []byte("hello\n")) // dedup: second put is a no-op
	if got := r.getAnchorBlob("sha1"); string(got) != "hello\n" {
		t.Fatalf("blob: %q", got)
	}
	if r.getAnchorBlob("missing") != nil {
		t.Fatal("missing blob must be nil")
	}

	// prune keeps blobs referenced by unresolved threads only
	id, _ := r.createThread(&ThreadInfo{
		Workspace: "ws", Path: "a.txt", StartLine: 1, EndLine: 1,
		Side: "modified", BlobSHA: "sha1", AnchorText: "hello",
	}, "hm")
	r.putAnchorBlob("orphan", []byte("x"))
	r.pruneAnchorBlobs()
	if r.getAnchorBlob("sha1") == nil {
		t.Fatal("referenced blob pruned")
	}
	if r.getAnchorBlob("orphan") != nil {
		t.Fatal("orphan blob survived prune")
	}
	r.submitThreads("ws")
	r.resolveThread(id, "user")
	r.pruneAnchorBlobs()
	if r.getAnchorBlob("sha1") != nil {
		t.Fatal("blob for resolved-only thread survived prune")
	}
	// the resolved thread still renders (anchor_text), just outdated
	if th := r.getThread(id); th == nil || th.AnchorText != "hello" {
		t.Fatalf("resolved thread lost its text: %+v", th)
	}
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `go test ./internal/host/ -run 'TestThreadStoreCRUD|TestAnchorBlobs' 2>&1 | grep -v 'ld: warning'`
Expected: FAIL — `undefined: ThreadInfo`, `undefined: errThreadState`, etc.

- [ ] **Step 4: Implement `internal/host/threads.go` (types + store)**

```go
package host

// Threads: file-anchored AI conversations (docs/superpowers/specs/
// 2026-07-12-threads-design.md). The host is a dumb store behind an
// agent-legible API — the responder is a claude session wielding rookctl,
// never host-side inference. Anchors are content-identified (git blob
// hash); snapshots live in rook.db, NEVER in the user's repo. Threads are
// rook-native and never mirrored to GitHub.

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// errThreadState is resolve/reopen against the wrong state — callers map
// it to 409.
var errThreadState = errors.New("thread is not in a state that allows that")

// ThreadComment is one utterance. Author is declared, not authenticated:
// every client shares the one localhost token; the webview says "user",
// the rook-threads skill's rookctl says "agent".
type ThreadComment struct {
	ID           int64     `json:"id"`
	Author       string    `json:"author"` // user|agent
	AgentSession string    `json:"agentSession,omitempty"`
	Body         string    `json:"body"`
	Created      time.Time `json:"created"`
}

// ThreadInfo is a thread with its comments and, when read through the
// HTTP surface, the re-anchored current range (reanchor.go).
type ThreadInfo struct {
	ID           int64      `json:"id"`
	Workspace    string     `json:"workspace"`
	Path         string     `json:"path"`
	StartLine    int        `json:"startLine"` // 1-based, inclusive
	EndLine      int        `json:"endLine"`
	Side         string     `json:"side"`                // modified|original
	BlobSHA      string     `json:"blobSha"`             // anchor content identity
	CommitSHA    string     `json:"commitSha,omitempty"` // display only
	AnchorText   string     `json:"anchorText"`
	State        string     `json:"state"` // pending|open|resolved
	ResolvedBy   string     `json:"resolvedBy,omitempty"`
	AgentReopens int        `json:"agentReopens,omitempty"`
	Created      time.Time  `json:"created"`
	Updated      time.Time  `json:"updated"`
	Submitted    *time.Time `json:"submitted,omitempty"`
	Comments     []ThreadComment `json:"comments"`
	// Computed on read — the anchor mapped onto today's file. Outdated
	// means the anchored lines themselves changed; render AnchorText.
	CurrentStart int  `json:"currentStart"`
	CurrentEnd   int  `json:"currentEnd"`
	Outdated     bool `json:"outdated,omitempty"`
}

const threadCols = `id, workspace, path, start_line, end_line, side, blob_sha,
	commit_sha, anchor_text, state, resolved_by, agent_reopens,
	created_at, updated_at, submitted_at`

func scanThread(row interface{ Scan(...any) error }) (*ThreadInfo, error) {
	var t ThreadInfo
	var created, updated string
	var submitted sql.NullString
	if err := row.Scan(&t.ID, &t.Workspace, &t.Path, &t.StartLine, &t.EndLine,
		&t.Side, &t.BlobSHA, &t.CommitSHA, &t.AnchorText, &t.State,
		&t.ResolvedBy, &t.AgentReopens, &created, &updated, &submitted); err != nil {
		return nil, err
	}
	t.Created, _ = time.Parse(time.RFC3339Nano, created)
	t.Updated, _ = time.Parse(time.RFC3339Nano, updated)
	if submitted.Valid {
		ts, _ := time.Parse(time.RFC3339Nano, submitted.String)
		t.Submitted = &ts
	}
	// the stored range is the default view; reanchor overwrites on read
	t.CurrentStart, t.CurrentEnd = t.StartLine, t.EndLine
	return &t, nil
}

// createThread inserts the thread and its first comment in one tx —
// a thread without an opening comment cannot exist.
func (r *registry) createThread(t *ThreadInfo, body string) (int64, error) {
	if r.db == nil {
		return 0, fmt.Errorf("no registry db")
	}
	now := time.Now().Format(time.RFC3339Nano)
	tx, err := r.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	res, err := tx.Exec(
		`INSERT INTO threads (workspace, path, start_line, end_line, side,
		 blob_sha, commit_sha, anchor_text, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		t.Workspace, t.Path, t.StartLine, t.EndLine, t.Side,
		t.BlobSHA, t.CommitSHA, t.AnchorText, now, now)
	if err != nil {
		return 0, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, err
	}
	if _, err := tx.Exec(
		`INSERT INTO thread_comments (thread_id, author, body, created_at)
		 VALUES (?, 'user', ?, ?)`, id, body, now); err != nil {
		return 0, err
	}
	return id, tx.Commit()
}

func (r *registry) getThread(id int64) *ThreadInfo {
	if r.db == nil {
		return nil
	}
	t, err := scanThread(r.db.QueryRow(
		`SELECT `+threadCols+` FROM threads WHERE id = ?`, id))
	if err != nil {
		return nil
	}
	r.fillComments(t)
	return t
}

func (r *registry) fillComments(t *ThreadInfo) {
	t.Comments = []ThreadComment{}
	rows, err := r.db.Query(
		`SELECT id, author, agent_session, body, created_at
		 FROM thread_comments WHERE thread_id = ? ORDER BY id`, t.ID)
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var c ThreadComment
		var created string
		if rows.Scan(&c.ID, &c.Author, &c.AgentSession, &c.Body, &created) == nil {
			c.Created, _ = time.Parse(time.RFC3339Nano, created)
			t.Comments = append(t.Comments, c)
		}
	}
}

// listThreads returns a workspace's threads (comments included — threads
// are small and one call renders a pane). Empty state/path = no filter.
func (r *registry) listThreads(ws, state, path string) []*ThreadInfo {
	if r.db == nil {
		return nil
	}
	q := `SELECT ` + threadCols + ` FROM threads WHERE workspace = ?`
	args := []any{ws}
	if state != "" {
		q += ` AND state = ?`
		args = append(args, state)
	}
	if path != "" {
		q += ` AND path = ?`
		args = append(args, path)
	}
	q += ` ORDER BY id`
	rows, err := r.db.Query(q, args...)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []*ThreadInfo
	for rows.Next() {
		if t, err := scanThread(rows); err == nil {
			out = append(out, t)
		}
	}
	for _, t := range out {
		r.fillComments(t)
	}
	return out
}

func (r *registry) addThreadComment(id int64, author, agentSession, body string) error {
	if r.db == nil {
		return fmt.Errorf("no registry db")
	}
	now := time.Now().Format(time.RFC3339Nano)
	res, err := r.db.Exec(
		`UPDATE threads SET updated_at = ? WHERE id = ?`, now, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return sql.ErrNoRows
	}
	_, err = r.db.Exec(
		`INSERT INTO thread_comments (thread_id, author, agent_session, body, created_at)
		 VALUES (?, ?, ?, ?, ?)`, id, author, agentSession, body, now)
	return err
}

func (r *registry) resolveThread(id int64, by string) error {
	if r.db == nil {
		return fmt.Errorf("no registry db")
	}
	now := time.Now().Format(time.RFC3339Nano)
	res, err := r.db.Exec(
		`UPDATE threads SET state = 'resolved', resolved_by = ?, updated_at = ?
		 WHERE id = ? AND state != 'resolved'`, by, now, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		if r.getThread(id) == nil {
			return sql.ErrNoRows
		}
		return errThreadState
	}
	return nil
}

// reopenThread flips resolved → open. A user reopening an AGENT-resolve
// is the negative-verdict datum — counted here, read in slice 3.
func (r *registry) reopenThread(id int64) error {
	if r.db == nil {
		return fmt.Errorf("no registry db")
	}
	now := time.Now().Format(time.RFC3339Nano)
	res, err := r.db.Exec(
		`UPDATE threads SET state = 'open',
		   agent_reopens = agent_reopens + (resolved_by = 'agent'),
		   resolved_by = '', updated_at = ?
		 WHERE id = ? AND state = 'resolved'`, now, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		if r.getThread(id) == nil {
			return sql.ErrNoRows
		}
		return errThreadState
	}
	return nil
}

// submitThreads flips the workspace's pending threads to open — the
// "submit review" barrier. No batch table: submitted_at groups them.
func (r *registry) submitThreads(ws string) int {
	if r.db == nil {
		return 0
	}
	now := time.Now().Format(time.RFC3339Nano)
	res, err := r.db.Exec(
		`UPDATE threads SET state = 'open', submitted_at = ?, updated_at = ?
		 WHERE workspace = ? AND state = 'pending'`, now, now, ws)
	if err != nil {
		return 0
	}
	n, _ := res.RowsAffected()
	return int(n)
}

// threadsAwaitingAgent counts open threads whose LAST comment is the
// user's — "needs reply" is derived, never stored.
func (r *registry) threadsAwaitingAgent(ws string) int {
	if r.db == nil {
		return 0
	}
	var n int
	r.db.QueryRow(
		`SELECT COUNT(*) FROM threads t
		 WHERE t.workspace = ? AND t.state = 'open'
		   AND (SELECT c.author FROM thread_comments c
		        WHERE c.thread_id = t.id ORDER BY c.id DESC LIMIT 1) = 'user'`,
		ws).Scan(&n)
	return n
}

func (r *registry) putAnchorBlob(sha string, content []byte) {
	if r.db == nil {
		return
	}
	r.db.Exec(`INSERT OR IGNORE INTO anchor_blobs (sha, content) VALUES (?, ?)`,
		sha, content)
}

func (r *registry) getAnchorBlob(sha string) []byte {
	if r.db == nil {
		return nil
	}
	var content []byte
	if r.db.QueryRow(`SELECT content FROM anchor_blobs WHERE sha = ?`, sha).
		Scan(&content) != nil {
		return nil
	}
	return content
}

// pruneAnchorBlobs drops snapshots no unresolved thread references —
// resolved threads render from anchor_text. Called after resolves.
func (r *registry) pruneAnchorBlobs() {
	if r.db == nil {
		return
	}
	r.db.Exec(`DELETE FROM anchor_blobs WHERE sha NOT IN
	           (SELECT blob_sha FROM threads WHERE state != 'resolved')`)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `go test ./internal/host/ -run 'TestThreadStoreCRUD|TestAnchorBlobs' 2>&1 | grep -v 'ld: warning'`
Expected: `ok`

Note: `agent_reopens + (resolved_by = 'agent')` relies on SQLite booleans being 0/1 — if the test fails there, replace with a `CASE WHEN resolved_by = 'agent' THEN 1 ELSE 0 END`.

- [ ] **Step 6: Full-package check + commit**

```bash
go build ./internal/... ./cmd/... && go vet ./internal/... ./cmd/...
go test ./internal/host/ 2>&1 | grep -v 'ld: warning'
git checkout -b threads-host
git add internal/host/registry.go internal/host/threads.go internal/host/threads_test.go
git commit -m "host: thread store — file-anchored conversations, sqlite-backed

Threads/thread_comments/anchor_blobs tables plus the registry CRUD:
create-with-first-comment (tx), submit barrier (pending→open),
derived needs-reply, either-side resolve with agent_reopens counting
user-reopens-of-agent-resolves (the verdict datum, recorded now and
read in slice 3), and content snapshots deduped by git blob hash —
in rook.db, never the user's repo.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Re-anchor engine

**Files:**
- Create: `internal/host/reanchor.go`
- Test: `internal/host/reanchor_test.go`
- Modify: `internal/host/host.go` (two `Host` struct fields, next to `cwdMu`/`cwdCache` around line 69)

**Interfaces:**
- Consumes: `gitOut` (review.go), `confinePath` (review.go), `(r *registry).getAnchorBlob` (Task 1).
- Produces:
  - `gitBlobSHA(content []byte) string`
  - `type hunk struct{ oldStart, oldCount, newStart, newCount int }`
  - `parseHunks(diff []byte) []hunk`
  - `mapRange(hunks []hunk, start, end int) (newStart, newEnd int, outdated bool)`
  - `(h *Host) anchorNow(top string, t *ThreadInfo)` — fills `CurrentStart/CurrentEnd/Outdated`

- [ ] **Step 1: Write the failing tests**

`internal/host/reanchor_test.go`:

```go
package host

import (
	"os"
	"path/filepath"
	"testing"
)

func TestGitBlobSHA(t *testing.T) {
	// git's own canonical examples: `echo hello | git hash-object --stdin`
	if got := gitBlobSHA([]byte("hello\n")); got != "ce013625030ba8dba906f756967f9e9ca394464a" {
		t.Fatalf("hello blob: %s", got)
	}
	if got := gitBlobSHA(nil); got != "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391" {
		t.Fatalf("empty blob: %s", got)
	}
}

func TestParseHunks(t *testing.T) {
	diff := []byte(`diff --git a/a b/b
index ce01362..0f2416e 100644
--- a/a
+++ b/b
@@ -2,0 +3,2 @@
+x
+y
@@ -10,3 +12 @@
-a
-b
-c
+z
`)
	hunks := parseHunks(diff)
	want := []hunk{{2, 0, 3, 2}, {10, 3, 12, 1}}
	if len(hunks) != 2 || hunks[0] != want[0] || hunks[1] != want[1] {
		t.Fatalf("hunks: %+v", hunks)
	}
}

func TestMapRange(t *testing.T) {
	cases := []struct {
		name       string
		hunks      []hunk
		start, end int
		wantStart  int
		wantEnd    int
		outdated   bool
	}{
		{"no hunks", nil, 5, 7, 5, 7, false},
		{"insertion above shifts down", []hunk{{2, 0, 3, 2}}, 5, 7, 7, 9, false},
		{"deletion above shifts up", []hunk{{1, 3, 1, 0}}, 10, 12, 7, 9, false},
		{"replacement above shifts by delta", []hunk{{1, 2, 1, 5}}, 10, 12, 13, 15, false},
		{"change below is invisible", []hunk{{20, 2, 20, 4}}, 5, 7, 5, 7, false},
		{"edit inside range outdates", []hunk{{6, 1, 6, 1}}, 5, 7, 5, 7, true},
		{"edit overlapping start outdates", []hunk{{3, 4, 3, 1}}, 5, 7, 5, 7, true},
		{"insertion strictly inside outdates", []hunk{{5, 0, 6, 2}}, 5, 7, 5, 7, true},
		{"insertion at range start shifts", []hunk{{4, 0, 5, 2}}, 5, 7, 7, 9, false},
		{"insertion at range end is below", []hunk{{7, 0, 8, 2}}, 5, 7, 5, 7, false},
		{"whole range deleted outdates", []hunk{{4, 6, 4, 0}}, 5, 7, 5, 7, true},
	}
	for _, c := range cases {
		s, e, out := mapRange(c.hunks, c.start, c.end)
		if s != c.wantStart || e != c.wantEnd || out != c.outdated {
			t.Errorf("%s: got %d-%d outdated=%v, want %d-%d outdated=%v",
				c.name, s, e, out, c.wantStart, c.wantEnd, c.outdated)
		}
	}
}

func TestAnchorNow(t *testing.T) {
	h, _, repo := newWorktreeHost(t)
	// anchored content: 5 lines
	orig := []byte("l1\nl2\nl3\nl4\nl5\n")
	os.WriteFile(filepath.Join(repo, "f.txt"), orig, 0o644)
	sha := gitBlobSHA(orig)
	h.reg.putAnchorBlob(sha, orig)
	th := &ThreadInfo{Workspace: "src", Path: "f.txt", StartLine: 3, EndLine: 4,
		BlobSHA: sha, CurrentStart: 3, CurrentEnd: 4}

	// same content → fast path, no change
	h.anchorNow(repo, th)
	if th.CurrentStart != 3 || th.CurrentEnd != 4 || th.Outdated {
		t.Fatalf("same-sha: %+v", th)
	}

	// two lines inserted above → range rides down
	os.WriteFile(filepath.Join(repo, "f.txt"), []byte("a\nb\nl1\nl2\nl3\nl4\nl5\n"), 0o644)
	h.anchorNow(repo, th)
	if th.CurrentStart != 5 || th.CurrentEnd != 6 || th.Outdated {
		t.Fatalf("shift: %+v", th)
	}

	// anchored line edited → outdated, range stays at stored positions
	th.CurrentStart, th.CurrentEnd, th.Outdated = th.StartLine, th.EndLine, false
	os.WriteFile(filepath.Join(repo, "f.txt"), []byte("l1\nl2\nCHANGED\nl4\nl5\n"), 0o644)
	h.anchorNow(repo, th)
	if !th.Outdated || th.CurrentStart != 3 {
		t.Fatalf("overlap: %+v", th)
	}

	// file gone → outdated
	th.Outdated = false
	os.Remove(filepath.Join(repo, "f.txt"))
	h.anchorNow(repo, th)
	if !th.Outdated {
		t.Fatalf("deleted file: %+v", th)
	}

	// blob missing (pruned) → outdated, never an error
	th2 := &ThreadInfo{Workspace: "src", Path: "a.txt", StartLine: 1, EndLine: 1,
		BlobSHA: "nope", CurrentStart: 1, CurrentEnd: 1}
	h.anchorNow(repo, th2)
	if !th2.Outdated {
		t.Fatalf("missing blob: %+v", th2)
	}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/host/ -run 'TestGitBlobSHA|TestParseHunks|TestMapRange|TestAnchorNow' 2>&1 | grep -v 'ld: warning'`
Expected: FAIL — `undefined: gitBlobSHA` etc.

- [ ] **Step 3: Implement `internal/host/reanchor.go`**

```go
package host

// Read-time re-anchoring: the stored anchor (blob_sha + range) is
// immutable ground truth, and mapping it onto today's file is a VIEW —
// never persisted, so drift cannot compound. Same content hash → the
// stored range holds (one hash, no subprocess). Different → git diff
// --no-index between the stored snapshot and the current file, and the
// range maps through the hunks: shifted when edits landed above it,
// outdated when the anchored lines themselves changed (GitHub
// semantics — the thread still renders its anchor_text).

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
)

// gitBlobSHA is git's blob hash: sha1("blob <len>\x00" + content). In-
// process — the fast path must not fork.
func gitBlobSHA(content []byte) string {
	h := sha1.New()
	fmt.Fprintf(h, "blob %d\x00", len(content))
	h.Write(content)
	return hex.EncodeToString(h.Sum(nil))
}

type hunk struct{ oldStart, oldCount, newStart, newCount int }

// hunkRE parses --unified=0 headers; an omitted count means 1.
var hunkRE = regexp.MustCompile(`(?m)^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@`)

func parseHunks(diff []byte) []hunk {
	var out []hunk
	for _, m := range hunkRE.FindAllSubmatch(diff, -1) {
		atoi := func(b []byte, def int) int {
			if len(b) == 0 {
				return def
			}
			n, _ := strconv.Atoi(string(b))
			return n
		}
		out = append(out, hunk{
			oldStart: atoi(m[1], 0), oldCount: atoi(m[2], 1),
			newStart: atoi(m[3], 0), newCount: atoi(m[4], 1),
		})
	}
	return out
}

// mapRange maps a 1-based inclusive [start,end] from old-file coordinates
// through hunks. Hunks entirely above shift it; a hunk touching the
// anchored lines outdates it (the caller keeps the stored range for
// display). Pure insertions (oldCount 0) sit BETWEEN old lines oldStart
// and oldStart+1: above the range they shift it, strictly inside they
// outdate it, at or past the end they are invisible.
func mapRange(hunks []hunk, start, end int) (int, int, bool) {
	delta := 0
	for _, hk := range hunks {
		if hk.oldCount == 0 {
			if hk.oldStart < start {
				delta += hk.newCount
			} else if hk.oldStart < end {
				return start, end, true
			}
			continue
		}
		oldEnd := hk.oldStart + hk.oldCount - 1
		switch {
		case oldEnd < start:
			delta += hk.newCount - hk.oldCount
		case hk.oldStart > end:
			// below the range — invisible
		default:
			return start, end, true
		}
	}
	return start + delta, end + delta, false
}

// diffHunks runs git diff --no-index over two contents via scratch files.
// Exit code 1 means "files differ" — that is the expected success here.
func diffHunks(old, cur []byte) ([]hunk, error) {
	dir, err := os.MkdirTemp("", "rook-reanchor")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	fa, fb := filepath.Join(dir, "a"), filepath.Join(dir, "b")
	if err := os.WriteFile(fa, old, 0o600); err != nil {
		return nil, err
	}
	if err := os.WriteFile(fb, cur, 0o600); err != nil {
		return nil, err
	}
	git, err := exec.LookPath("git")
	if err != nil {
		git = "/usr/bin/git" // launchd's minimal PATH
	}
	out, err := exec.Command(git, "diff", "--no-index", "--unified=0", fa, fb).Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); !ok || ee.ExitCode() != 1 {
			return nil, err
		}
	}
	return parseHunks(out), nil
}

// hunkMemo caches diffHunks results per (old,cur) blob pair — a pane's
// poll must not re-fork git for an unchanged file, and one entry serves
// every thread anchored to that file version.
type hunkMemo struct {
	mu sync.Mutex
	m  map[string][]hunk
}

func (c *hunkMemo) get(key string) ([]hunk, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	h, ok := c.m[key]
	return h, ok
}

func (c *hunkMemo) put(key string, h []hunk) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.m == nil || len(c.m) > 256 {
		c.m = make(map[string][]hunk) // crude cap; entries are tiny
	}
	c.m[key] = h
}

// anchorNow maps t's stored anchor onto the file as it is right now.
// Every failure lands on outdated-with-stored-range — a thread renders
// from anchor_text, never errors.
func (h *Host) anchorNow(top string, t *ThreadInfo) {
	t.CurrentStart, t.CurrentEnd = t.StartLine, t.EndLine
	abs, err := confinePath(top, t.Path)
	if err != nil {
		t.Outdated = true
		return
	}
	cur, err := os.ReadFile(abs)
	if err != nil {
		t.Outdated = true // deleted (or unreadable) file
		return
	}
	curSHA := gitBlobSHA(cur)
	if curSHA == t.BlobSHA {
		return // the common case: content unchanged, one hash, no git
	}
	key := t.BlobSHA + ":" + curSHA
	hunks, ok := h.anchorMemo.get(key)
	if !ok {
		old := h.reg.getAnchorBlob(t.BlobSHA)
		if old == nil {
			t.Outdated = true // snapshot pruned/missing — fail open
			return
		}
		hunks, err = diffHunks(old, cur)
		if err != nil {
			t.Outdated = true
			return
		}
		h.anchorMemo.put(key, hunks)
	}
	t.CurrentStart, t.CurrentEnd, t.Outdated = mapRange(hunks, t.StartLine, t.EndLine)
	if t.Outdated {
		t.CurrentStart, t.CurrentEnd = t.StartLine, t.EndLine
	}
}
```

- [ ] **Step 4: Add the memo field to `Host` in `host.go`**

In the `Host` struct (after the `um *usageMon` field):

```go
	// anchorMemo caches re-anchor diffs per (old,cur) blob pair
	// (threads.go / reanchor.go).
	anchorMemo hunkMemo
```

No `New()` change needed — the zero value works (`put` allocates the map).

- [ ] **Step 5: Run tests to verify they pass**

Run: `go test ./internal/host/ -run 'TestGitBlobSHA|TestParseHunks|TestMapRange|TestAnchorNow' 2>&1 | grep -v 'ld: warning'`
Expected: `ok`

- [ ] **Step 6: Commit**

```bash
go build ./internal/... ./cmd/... && go vet ./internal/... ./cmd/...
git add internal/host/reanchor.go internal/host/reanchor_test.go internal/host/host.go
git commit -m "host: read-time re-anchoring for threads

The stored anchor is immutable ground truth; mapping it onto today's
file is a view. Same blob hash → done (in-process sha1, no fork).
Different → git diff --no-index between the rook.db snapshot and the
working tree, range mapped through --unified=0 hunks: shifted by edits
above, outdated when the anchored lines themselves changed. Memoized
per blob pair; every failure fails open to outdated + anchor_text.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Create + list endpoints

**Files:**
- Modify: `internal/host/threads.go` (append handlers)
- Modify: `internal/host/host.go` (`handleWorkspace` switch, after the review cases ~line 542)
- Test: `internal/host/threads_test.go` (append)

**Interfaces:**
- Consumes: `reviewRepo` is NOT reused (threads serve non-repo roots like the file endpoint); uses `repoTop`, `confinePath`, `reviewBaseFor`, `gitOut`, `reviewMaxSide`, `reviewSniffLen`, `capSide` (all in review.go), `gitBlobSHA`/`anchorNow` (Task 2), store (Task 1), `writeJSON`.
- Produces:
  - `(h *Host) handleWorkspaceThreads(w, r, name)` — GET list / POST create, wired as `case action == "threads"`.
  - `(h *Host) threadTop(ws *WorkspaceInfo) string` — repo top, else the root (file-endpoint parity).

- [ ] **Step 1: Write the failing endpoint tests (append to `threads_test.go`)**

```go
func TestThreadCreateAndList(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}
	os.WriteFile(filepath.Join(repo, "f.txt"), []byte("l1\nl2\nl3\nl4\nl5\n"), 0o644)

	code, body := c.do(t, "POST", "/workspaces/src/threads", map[string]any{
		"path": "f.txt", "startLine": 2, "endLine": 3, "body": "why?"})
	if code != 200 {
		t.Fatalf("create: %d %s", code, body)
	}
	var th ThreadInfo
	json.Unmarshal([]byte(body), &th)
	if th.State != "pending" || th.AnchorText != "l2\nl3" || th.Side != "modified" ||
		th.CurrentStart != 2 || th.Outdated || len(th.Comments) != 1 {
		t.Fatalf("thread: %+v", th)
	}
	if th.BlobSHA == "" || th.CommitSHA == "" {
		t.Fatalf("anchor identity missing: %+v", th)
	}

	// the snapshot landed
	if h.reg.getAnchorBlob(th.BlobSHA) == nil {
		t.Fatal("anchor blob not stored")
	}

	// list re-anchors: insert 2 lines above the range
	os.WriteFile(filepath.Join(repo, "f.txt"), []byte("a\nb\nl1\nl2\nl3\nl4\nl5\n"), 0o644)
	code, body = c.do(t, "GET", "/workspaces/src/threads", nil)
	if code != 200 {
		t.Fatalf("list: %d %s", code, body)
	}
	var list []ThreadInfo
	json.Unmarshal([]byte(body), &list)
	if len(list) != 1 || list[0].CurrentStart != 4 || list[0].CurrentEnd != 5 || list[0].Outdated {
		t.Fatalf("re-anchored list: %+v", list)
	}

	// filters pass through
	code, body = c.do(t, "GET", "/workspaces/src/threads?state=open", nil)
	json.Unmarshal([]byte(body), &list)
	if code != 200 || len(list) != 0 {
		t.Fatalf("state filter: %d %+v", code, list)
	}

	// validation
	for name, req := range map[string]map[string]any{
		"no body":     {"path": "f.txt", "startLine": 1, "endLine": 1},
		"no path":     {"startLine": 1, "endLine": 1, "body": "x"},
		"bad range":   {"path": "f.txt", "startLine": 3, "endLine": 2, "body": "x"},
		"oob range":   {"path": "f.txt", "startLine": 1, "endLine": 99, "body": "x"},
		"bad side":    {"path": "f.txt", "startLine": 1, "endLine": 1, "side": "left", "body": "x"},
		"traversal":   {"path": "../x", "startLine": 1, "endLine": 1, "body": "x"},
	} {
		if code, body := c.do(t, "POST", "/workspaces/src/threads", req); code != 400 {
			t.Errorf("%s: %d %s", name, code, body)
		}
	}
	if code, _ := c.do(t, "POST", "/workspaces/src/threads", map[string]any{
		"path": "missing.txt", "startLine": 1, "endLine": 1, "body": "x"}); code != 404 {
		t.Errorf("missing file: %d", code)
	}
	if code, _ := c.do(t, "GET", "/workspaces/nope/threads", nil); code != 404 {
		t.Errorf("unknown ws: %d", code)
	}

	// original side: anchored to the base's content (a.txt is committed
	// as "hello\n"; the working tree copy no longer matters)
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("edited\n"), 0o644)
	code, body = c.do(t, "POST", "/workspaces/src/threads", map[string]any{
		"path": "a.txt", "startLine": 1, "endLine": 1, "side": "original", "body": "gone?"})
	if code != 200 {
		t.Fatalf("original side: %d %s", code, body)
	}
	json.Unmarshal([]byte(body), &th)
	if th.AnchorText != "hello" || th.Side != "original" {
		t.Fatalf("original anchor: %+v", th)
	}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/host/ -run TestThreadCreateAndList 2>&1 | grep -v 'ld: warning'`
Expected: FAIL — 404s (routes not wired).

- [ ] **Step 3: Append handlers to `threads.go`**

Add to the imports: `"net/http"`, `"strings"`, and keep existing.

```go
// threadTop resolves where thread paths are confined to: the repo top
// when the root is a repo (git paths are top-relative), the root itself
// otherwise — the ` e file viewer's exact rule, so anything viewable is
// commentable.
func (h *Host) threadTop(ws *WorkspaceInfo) string {
	if top, err := repoTop(ws.Root); err == nil {
		return top
	}
	return ws.Root
}

// handleWorkspaceThreads is /workspaces/{name}/threads: GET lists (with
// read-time re-anchoring), POST creates a pending thread with its first
// comment and captures the anchor snapshot at that instant.
func (h *Host) handleWorkspaceThreads(w http.ResponseWriter, r *http.Request, name string) {
	ws := h.reg.get(name)
	if ws == nil {
		http.Error(w, "no such workspace: "+name, http.StatusNotFound)
		return
	}
	if ws.Root == "" {
		http.Error(w, "workspace has no root", http.StatusBadRequest)
		return
	}
	if r.Method == http.MethodGet {
		top := h.threadTop(ws)
		list := h.reg.listThreads(name,
			r.URL.Query().Get("state"), r.URL.Query().Get("path"))
		for _, t := range list {
			h.anchorNow(top, t)
		}
		if list == nil {
			list = []*ThreadInfo{}
		}
		writeJSON(w, list)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Path      string
		StartLine int
		EndLine   int
		Side      string
		Base      string
		Body      string
	}
	json.NewDecoder(r.Body).Decode(&req)
	if req.Side == "" {
		req.Side = "modified"
	}
	req.Body = strings.TrimSpace(req.Body)
	switch {
	case req.Body == "":
		http.Error(w, "body required", http.StatusBadRequest)
		return
	case req.Side != "modified" && req.Side != "original":
		http.Error(w, "side must be modified or original", http.StatusBadRequest)
		return
	case req.StartLine < 1 || req.EndLine < req.StartLine:
		http.Error(w, "bad line range", http.StatusBadRequest)
		return
	}
	top := h.threadTop(ws)
	abs, err := confinePath(top, req.Path)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// snapshot the anchored content NOW — the anchor is what the
	// commenter was looking at, not what the file becomes
	var content []byte
	if req.Side == "original" {
		base := h.reviewBaseFor(ws, top, req.Base)
		out, err := gitOut(top, reviewTimeout, "show", base.ref+":"+req.Path)
		if err != nil {
			http.Error(w, "no original content: "+err.Error(), http.StatusNotFound)
			return
		}
		content = out
	} else {
		content, err = os.ReadFile(abs)
		if err != nil {
			http.Error(w, "no such file: "+req.Path, http.StatusNotFound)
			return
		}
	}
	if _, binary, _ := capSide(content); binary {
		http.Error(w, "binary file", http.StatusBadRequest)
		return
	}
	if len(content) > reviewMaxSide {
		http.Error(w, "file exceeds the 2 MB anchor cap", http.StatusBadRequest)
		return
	}
	lines := strings.Split(string(content), "\n")
	// a trailing newline yields a phantom "" final element — not a line
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	if req.EndLine > len(lines) {
		http.Error(w, "range out of bounds", http.StatusBadRequest)
		return
	}

	commit := ""
	if out, err := gitOut(top, reviewTimeout, "rev-parse", "HEAD"); err == nil {
		commit = strings.TrimSpace(string(out))
	}
	sha := gitBlobSHA(content)
	h.reg.putAnchorBlob(sha, content)
	id, err := h.reg.createThread(&ThreadInfo{
		Workspace: name, Path: req.Path,
		StartLine: req.StartLine, EndLine: req.EndLine,
		Side: req.Side, BlobSHA: sha, CommitSHA: commit,
		AnchorText: strings.Join(lines[req.StartLine-1:req.EndLine], "\n"),
	}, req.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	t := h.reg.getThread(id)
	h.anchorNow(top, t)
	writeJSON(w, t)
}
```

Add `"encoding/json"` and `"os"` to threads.go imports.

- [ ] **Step 4: Wire the route in `host.go` `handleWorkspace`**

After the review cases:

```go
	// threads: file-anchored AI conversations (threads.go)
	case action == "threads":
		h.handleWorkspaceThreads(w, r, name)
```

(No method guard in the case — the handler 405s itself, since it serves both GET and POST.)

- [ ] **Step 5: Run tests**

Run: `go test ./internal/host/ -run TestThreadCreateAndList 2>&1 | grep -v 'ld: warning'`
Expected: `ok`

- [ ] **Step 6: Full check + commit**

```bash
go build ./internal/... ./cmd/... && go vet ./internal/... ./cmd/...
go test ./internal/host/ 2>&1 | grep -v 'ld: warning'
git add internal/host/threads.go internal/host/threads_test.go internal/host/host.go
git commit -m "host: thread create + list endpoints

POST snapshots the anchored content at comment time (working tree, or
the diff base's side for original-side comments on deleted lines) and
creates the thread pending; GET lists with read-time re-anchoring.
Non-repo roots work exactly like the file viewer — anything viewable
is commentable. confinePath and the 2 MB/binary caps guard the new
read surface.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Per-thread routes — comments, resolve, reopen

**Files:**
- Modify: `internal/host/threads.go` (append handler)
- Modify: `internal/host/host.go` (`Handler()` mux, after the `/drafts/` line ~354)
- Test: `internal/host/threads_test.go` (append)

**Interfaces:**
- Consumes: store methods (Task 1).
- Produces: `(h *Host) handleThread(w, r)` on `/threads/{id}/{comments|resolve|reopen}` — thread ids are global (one SQLite), so `rookctl reply <id>` needs no workspace.

- [ ] **Step 1: Write the failing tests (append to `threads_test.go`)**

```go
func TestThreadCommentResolveReopen(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}
	os.WriteFile(filepath.Join(repo, "f.txt"), []byte("one\n"), 0o644)
	code, body := c.do(t, "POST", "/workspaces/src/threads", map[string]any{
		"path": "f.txt", "startLine": 1, "endLine": 1, "body": "hm"})
	if code != 200 {
		t.Fatalf("create: %d %s", code, body)
	}
	var th ThreadInfo
	json.Unmarshal([]byte(body), &th)
	id := fmt.Sprintf("%d", th.ID)

	// agent reply
	if code, body = c.do(t, "POST", "/threads/"+id+"/comments", map[string]any{
		"body": "fixed in abc123", "author": "agent", "agentSession": "t9"}); code != 204 {
		t.Fatalf("reply: %d %s", code, body)
	}
	got := h.reg.getThread(th.ID)
	if len(got.Comments) != 2 || got.Comments[1].Author != "agent" || got.Comments[1].AgentSession != "t9" {
		t.Fatalf("comments: %+v", got.Comments)
	}

	// bad author / empty body → 400
	if code, _ = c.do(t, "POST", "/threads/"+id+"/comments", map[string]any{
		"body": "x", "author": "root"}); code != 400 {
		t.Fatalf("bad author: %d", code)
	}
	if code, _ = c.do(t, "POST", "/threads/"+id+"/comments", map[string]any{
		"author": "user"}); code != 400 {
		t.Fatalf("empty body: %d", code)
	}

	// resolve by agent → reopen → verdict datum recorded; blob pruned on
	// resolve and the thread still renders
	if code, body = c.do(t, "POST", "/threads/"+id+"/resolve", map[string]any{"by": "agent"}); code != 204 {
		t.Fatalf("resolve: %d %s", code, body)
	}
	if h.reg.getAnchorBlob(th.BlobSHA) != nil {
		t.Fatal("blob should prune once no unresolved thread references it")
	}
	if code, _ = c.do(t, "POST", "/threads/"+id+"/resolve", map[string]any{"by": "user"}); code != 409 {
		t.Fatalf("double resolve: %d", code)
	}
	if code, _ = c.do(t, "POST", "/threads/"+id+"/reopen", nil); code != 204 {
		t.Fatalf("reopen: %d", code)
	}
	if got = h.reg.getThread(th.ID); got.AgentReopens != 1 || got.State != "open" {
		t.Fatalf("verdict datum: %+v", got)
	}
	if code, _ = c.do(t, "POST", "/threads/"+id+"/reopen", nil); code != 409 {
		t.Fatalf("reopen open thread: %d", code)
	}

	// unknown id / bad routes
	if code, _ = c.do(t, "POST", "/threads/999/comments", map[string]any{"body": "x"}); code != 404 {
		t.Fatalf("ghost thread: %d", code)
	}
	if code, _ = c.do(t, "GET", "/threads/"+id+"/comments", nil); code != 404 {
		t.Fatalf("GET on thread route: %d", code)
	}
}
```

Add `"fmt"` to the test imports if missing.

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/host/ -run TestThreadCommentResolveReopen 2>&1 | grep -v 'ld: warning'`
Expected: FAIL — 404 (route not wired).

- [ ] **Step 3: Append the handler to `threads.go`**

```go
// handleThread routes /threads/{id}/comments|resolve|reopen. Thread ids
// are global, so per-thread verbs need no workspace — `rookctl reply 12`
// works from anywhere.
func (h *Host) handleThread(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/threads/")
	idStr, action, _ := strings.Cut(rest, "/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || r.Method != http.MethodPost {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	switch action {
	case "comments":
		var req struct{ Body, Author, AgentSession string }
		json.NewDecoder(r.Body).Decode(&req)
		req.Body = strings.TrimSpace(req.Body)
		if req.Author == "" {
			req.Author = "user"
		}
		if req.Body == "" {
			http.Error(w, "body required", http.StatusBadRequest)
			return
		}
		if req.Author != "user" && req.Author != "agent" {
			http.Error(w, "author must be user or agent", http.StatusBadRequest)
			return
		}
		if err := h.reg.addThreadComment(id, req.Author, req.AgentSession, req.Body); err != nil {
			http.Error(w, "no such thread", http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case "resolve":
		var req struct{ By string }
		json.NewDecoder(r.Body).Decode(&req)
		if req.By == "" {
			req.By = "user"
		}
		if req.By != "user" && req.By != "agent" {
			http.Error(w, "by must be user or agent", http.StatusBadRequest)
			return
		}
		switch err := h.reg.resolveThread(id, req.By); err {
		case nil:
			h.reg.pruneAnchorBlobs() // resolved threads release their snapshots
			w.WriteHeader(http.StatusNoContent)
		case errThreadState:
			http.Error(w, "already resolved", http.StatusConflict)
		default:
			http.Error(w, "no such thread", http.StatusNotFound)
		}
	case "reopen":
		switch err := h.reg.reopenThread(id); err {
		case nil:
			w.WriteHeader(http.StatusNoContent)
		case errThreadState:
			http.Error(w, "thread is not resolved", http.StatusConflict)
		default:
			http.Error(w, "no such thread", http.StatusNotFound)
		}
	default:
		http.Error(w, "not found", http.StatusNotFound)
	}
}
```

Add `"strconv"` to threads.go imports.

- [ ] **Step 4: Wire the mux entry in `Handler()` (host.go)**

After `mux.HandleFunc("/drafts/", h.handleDraftDecide)`:

```go
	// per-thread verbs — ids are global, no workspace in the path
	mux.HandleFunc("/threads/", h.handleThread)
```

- [ ] **Step 5: Run tests**

Run: `go test ./internal/host/ -run TestThreadCommentResolveReopen 2>&1 | grep -v 'ld: warning'`
Expected: `ok`

- [ ] **Step 6: Commit**

```bash
go build ./internal/... ./cmd/... && go vet ./internal/... ./cmd/...
git add internal/host/threads.go internal/host/threads_test.go internal/host/host.go
git commit -m "host: per-thread verbs — comments, resolve, reopen

Top-level /threads/{id}/ routes (ids are global; rookctl reply needs
no workspace). Author is declared, not authenticated — one localhost
token by design. Resolve prunes unreferenced anchor snapshots; a user
reopening an agent-resolve increments agent_reopens, the verdict
datum slice 3 will read.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Submit + nudge actuation

**Files:**
- Modify: `internal/host/threads.go` (append)
- Modify: `internal/host/host.go` (`handleWorkspace` switch)
- Test: `internal/host/threads_test.go` (append)

**Interfaces:**
- Consumes: `h.claims`/`h.bindMu` (host.go), `h.get(id)` (host.go), `h.spawnTask(ws, task)` (spawntask.go), store (Task 1).
- Produces:
  - `(h *Host) handleThreadsSubmit(w, r, name)` — `case action == "threads/submit" && r.Method == http.MethodPost`.
  - `(h *Host) claudeSessionIn(ws string) string` — the workspace's claimed claude window, "" when none.
  - `threadsNudge(n int, ws string) string` — the one host-built prompt.

- [ ] **Step 1: Write the failing tests (append to `threads_test.go`)**

```go
// threadHost is the pipe-pty fixture (draftHost's shape): one fake
// window in workspace "ws", claimed by transcript "t1" — the typed
// nudge lands on the readable end of the pipe.
func threadHost(t *testing.T) (*Host, *os.File, string) {
	t.Helper()
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	pr, pw, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pr.Close(); pw.Close() })
	repo := t.TempDir()
	gitT(t, repo, "init", "-b", "main")
	os.WriteFile(filepath.Join(repo, "f.txt"), []byte("one\ntwo\n"), 0o644)
	gitT(t, repo, "add", ".")
	gitT(t, repo, "commit", "-m", "init")
	h := &Host{
		sessions: map[string]*session{"w1": {info: SessionInfo{ID: "w1", Workspace: "ws"}, pty: pw}},
		reg:      loadRegistry(),
		aw:       newAgentWatch(),
		cwdCache: make(map[int]cwdEntry),
		claims:   map[string]string{"t1": "w1"},
		binds:    map[string]string{},
		drafts:   make(map[string]draftInfo),
	}
	if h.reg.db == nil {
		t.Fatal("test registry has no db")
	}
	h.reg.upsert("ws", repo, false)
	return h, pr, repo
}

func postWS(t *testing.T, h *Host, path string, body map[string]any) *httptest.ResponseRecorder {
	t.Helper()
	b, _ := json.Marshal(body)
	req := httptest.NewRequest("POST", path, bytes.NewReader(b))
	w := httptest.NewRecorder()
	h.handleWorkspace(w, req)
	return w
}

func TestThreadSubmitTypesNudge(t *testing.T) {
	h, ptyOut, _ := threadHost(t)

	// no threads at all → 400
	if w := postWS(t, h, "/workspaces/ws/threads/submit", nil); w.Code != 400 {
		t.Fatalf("empty submit: %d %s", w.Code, w.Body)
	}

	// two pending comments, one submit, one nudge naming both
	id1, _ := h.reg.createThread(&ThreadInfo{Workspace: "ws", Path: "f.txt",
		StartLine: 1, EndLine: 1, Side: "modified", BlobSHA: "s", AnchorText: "one"}, "a?")
	h.reg.createThread(&ThreadInfo{Workspace: "ws", Path: "f.txt",
		StartLine: 2, EndLine: 2, Side: "modified", BlobSHA: "s", AnchorText: "two"}, "b?")
	w := postWS(t, h, "/workspaces/ws/threads/submit", nil)
	if w.Code != 200 {
		t.Fatalf("submit: %d %s", w.Code, w.Body)
	}
	var res struct {
		Mode        string `json:"mode"`
		RookSession string `json:"rookSession"`
		Count       int    `json:"count"`
	}
	json.Unmarshal(w.Body.Bytes(), &res)
	if res.Mode != "typed" || res.RookSession != "w1" || res.Count != 2 {
		t.Fatalf("submit result: %+v", res)
	}
	line, err := bufio.NewReader(ptyOut).ReadString('\r')
	if err != nil || !strings.Contains(line, "2 review comment") || !strings.Contains(line, "rook-threads") {
		t.Fatalf("nudge on pty: %q (%v)", line, err)
	}
	if th := h.reg.getThread(id1); th.State != "open" {
		t.Fatalf("state after submit: %+v", th)
	}

	// re-nudge: zero pending but still awaiting the agent → nudge again
	w = postWS(t, h, "/workspaces/ws/threads/submit", nil)
	if w.Code != 200 {
		t.Fatalf("re-nudge: %d %s", w.Code, w.Body)
	}
	json.Unmarshal(w.Body.Bytes(), &res)
	if res.Mode != "typed" || res.Count != 0 {
		t.Fatalf("re-nudge result: %+v", res)
	}
	if _, err := bufio.NewReader(ptyOut).ReadString('\r'); err != nil {
		t.Fatalf("re-nudge pty: %v", err)
	}

	// agent replied to everything → nothing to submit → 400
	h.reg.addThreadComment(id1, "agent", "t1", "done")
	th2 := h.reg.listThreads("ws", "open", "")
	for _, x := range th2 {
		if x.ID != id1 {
			h.reg.addThreadComment(x.ID, "agent", "t1", "done")
		}
	}
	if w := postWS(t, h, "/workspaces/ws/threads/submit", nil); w.Code != 400 {
		t.Fatalf("drained submit: %d %s", w.Code, w.Body)
	}
}

func TestThreadSubmitSpawnsResponder(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}
	os.WriteFile(filepath.Join(repo, "f.txt"), []byte("one\n"), 0o644)
	c.do(t, "POST", "/workspaces/src/threads", map[string]any{
		"path": "f.txt", "startLine": 1, "endLine": 1, "body": "hm"})

	// no claimed claude window in "src" → spawn path
	code, body := c.do(t, "POST", "/workspaces/src/threads/submit", nil)
	if code != 200 {
		t.Fatalf("submit: %d %s", code, body)
	}
	var res struct {
		Mode        string `json:"mode"`
		RookSession string `json:"rookSession"`
	}
	json.Unmarshal([]byte(body), &res)
	if res.Mode != "spawned" || res.RookSession == "" {
		t.Fatalf("spawn result: %+v", res)
	}
	if h.get(res.RookSession) == nil {
		t.Fatal("responder session not live")
	}
	h.kill(res.RookSession) // no orphan shells from tests
}
```

Add `"bufio"`, `"bytes"`, `"net/http/httptest"`, `"strings"` to the test imports as needed.

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/host/ -run 'TestThreadSubmit' 2>&1 | grep -v 'ld: warning'`
Expected: FAIL — 404 (route not wired).

- [ ] **Step 3: Append submit + helpers to `threads.go`**

```go
// threadsNudge is THE nudge — one host-built string for both actuation
// paths, so every surface triggers the identical thing.
func threadsNudge(n int, ws string) string {
	return fmt.Sprintf("You have %d review comment(s) in %s. Use the rook-threads skill to address them.", n, ws)
}

// claudeSessionIn finds the workspace's live claude window via the claim
// machinery (SessionStart hook → rookctl claim — authoritative, and the
// standard install). Deliberately NOT fg-based: no lsof on the submit
// path, and claims are testable against pipe fixtures. No claim → ""
// and submit spawns a responder instead.
func (h *Host) claudeSessionIn(ws string) string {
	h.bindMu.Lock()
	defer h.bindMu.Unlock()
	for _, sid := range h.claims {
		if s := h.get(sid); s != nil && s.info.Workspace == ws {
			return sid
		}
	}
	return ""
}

// handleThreadsSubmit is POST /workspaces/{name}/threads/submit: flip
// pending→open and nudge the responder. Re-nudgeable — zero pending but
// open threads still awaiting the agent fires the nudge again ("claude
// missed it", or the earlier spawn failed). Actuation failure leaves
// threads open; nothing is lost, resubmit retries.
func (h *Host) handleThreadsSubmit(w http.ResponseWriter, r *http.Request, name string) {
	ws := h.reg.get(name)
	if ws == nil {
		http.Error(w, "no such workspace: "+name, http.StatusNotFound)
		return
	}
	n := h.reg.submitThreads(name)
	waiting := h.reg.threadsAwaitingAgent(name)
	if waiting == 0 {
		http.Error(w, "nothing to submit", http.StatusBadRequest)
		return
	}
	prompt := threadsNudge(waiting, name)
	if sid := h.claudeSessionIn(name); sid != "" {
		s := h.get(sid)
		if _, err := s.pty.Write([]byte(prompt + "\r")); err == nil {
			writeJSON(w, map[string]any{"mode": "typed", "rookSession": sid, "count": n})
			return
		}
		// a dead pty falls through to a fresh responder
	}
	s, err := h.spawnTask(name, prompt)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]any{"mode": "spawned", "rookSession": s.info.ID, "count": n})
}
```

- [ ] **Step 4: Wire the route in `host.go` `handleWorkspace`**

Directly above the `case action == "threads":` line (Cut only splits on the FIRST slash, so `threads/submit` arrives as one action string — order between these two cases doesn't matter, but keep them adjacent):

```go
	case action == "threads/submit" && r.Method == http.MethodPost:
		h.handleThreadsSubmit(w, r, name)
```

- [ ] **Step 5: Run tests**

Run: `go test ./internal/host/ -run 'TestThreadSubmit' 2>&1 | grep -v 'ld: warning'`
Expected: `ok` (the spawn test starts a real `/bin/sh` — the `h.kill` cleanup keeps it from leaking).

- [ ] **Step 6: Commit**

```bash
go build ./internal/... ./cmd/... && go vet ./internal/... ./cmd/...
go test ./internal/host/ 2>&1 | grep -v 'ld: warning'
git add internal/host/threads.go internal/host/threads_test.go internal/host/host.go
git commit -m "host: submit — the review barrier and its nudge

Submit flips the workspace's pending threads open and actuates one
host-built nudge: typed into the claimed claude window (the drafter-
approve pty path), else spawnTask starts a responder. Re-nudgeable by
design — zero pending with threads still awaiting the agent fires
again, covering missed nudges and failed spawns with no new state.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: rookctl commands

**Files:**
- Modify: `cmd/rookctl/main.go` (doc comment, switch, usage line, new functions)

**Interfaces:**
- Consumes: HTTP surface from Tasks 3–5 verbatim; `connect()`, `client.req`, `ROOK_WORKSPACE` conventions already in main.go.
- Produces (CLI contract the 2c skill will rely on):
  - `rookctl threads [-w ws] [--pending] [--json]`
  - `rookctl comment [-w ws] <path>:<start>[-<end>] <text…>`
  - `rookctl submit [-w ws]`
  - `rookctl reply <id> <text…>` (author=agent; `--user` overrides)
  - `rookctl resolve <id> [--user]` / `rookctl reopen <id>`

- [ ] **Step 1: Add commands to the doc comment**

After the `rookctl changes` line:

```go
//	rookctl threads       list a workspace's threads: rookctl threads [-w ws] [--pending] [--json]
//	rookctl comment       start a pending thread: rookctl comment [-w ws] <path>:<a>[-<b>] <text…>
//	rookctl submit        submit pending comments + nudge the responder: rookctl submit [-w ws]
//	rookctl reply         reply in a thread (as the agent): rookctl reply <id> <text…>
//	rookctl resolve       resolve a thread: rookctl resolve <id> [--user]  (reopen undoes)
```

- [ ] **Step 2: Add switch cases**

After `case "changes":`:

```go
	case "threads":
		err = runThreads(os.Args[2:])
	case "comment":
		err = runComment(os.Args[2:])
	case "submit":
		err = runSubmit(os.Args[2:])
	case "reply":
		err = runThreadVerb("reply", os.Args[2:])
	case "resolve":
		err = runThreadVerb("resolve", os.Args[2:])
	case "reopen":
		err = runThreadVerb("reopen", os.Args[2:])
```

And extend the usage string in the `default:` case with:
`threads [-w ws] [--pending] [--json]|comment [-w ws] path:a-b <text…>|submit [-w ws]|reply <id> <text…>|resolve <id>|reopen <id>`

- [ ] **Step 3: Implement the functions (new section before `// ---- decisions`)**

```go
// ---- threads (file-anchored conversations; the rook-threads skill's
// entire tool surface — docs/superpowers/specs/2026-07-12-threads-design.md) ----

type threadComment struct {
	Author string `json:"author"`
	Body   string `json:"body"`
}

type threadRow struct {
	ID           int64           `json:"id"`
	Path         string          `json:"path"`
	StartLine    int             `json:"startLine"`
	EndLine      int             `json:"endLine"`
	State        string          `json:"state"`
	Outdated     bool            `json:"outdated"`
	AnchorText   string          `json:"anchorText"`
	CurrentStart int             `json:"currentStart"`
	CurrentEnd   int             `json:"currentEnd"`
	Comments     []threadComment `json:"comments"`
}

// awaitingAgent mirrors the host's derived "needs reply": open + last
// comment by the user.
func awaitingAgent(t threadRow) bool {
	return t.State == "open" && len(t.Comments) > 0 &&
		t.Comments[len(t.Comments)-1].Author == "user"
}

func runThreads(args []string) error {
	ws := os.Getenv("ROOK_WORKSPACE")
	pending, asJSON := false, false
	for len(args) > 0 {
		switch {
		case args[0] == "-w" && len(args) >= 2:
			ws, args = args[1], args[2:]
		case args[0] == "--pending":
			pending, args = true, args[1:]
		case args[0] == "--json":
			asJSON, args = true, args[1:]
		default:
			return fmt.Errorf("usage: rookctl threads [-w workspace] [--pending] [--json]")
		}
	}
	if ws == "" {
		return fmt.Errorf("usage: rookctl threads [-w workspace] (or run inside a rook window)")
	}
	c, err := connect()
	if err != nil {
		return err
	}
	raw, err := c.req("GET", "/workspaces/"+ws+"/threads", nil)
	if err != nil {
		return err
	}
	var rows []threadRow
	if err := json.Unmarshal(raw, &rows); err != nil {
		return err
	}
	if pending {
		kept := rows[:0]
		for _, t := range rows {
			if awaitingAgent(t) {
				kept = append(kept, t)
			}
		}
		rows = kept
	}
	if asJSON {
		return json.NewEncoder(os.Stdout).Encode(rows)
	}
	if len(rows) == 0 {
		fmt.Println("no threads")
		return nil
	}
	for _, t := range rows {
		mark := " "
		if awaitingAgent(t) {
			mark = "◉"
		}
		loc := fmt.Sprintf("%s:%d-%d", t.Path, t.CurrentStart, t.CurrentEnd)
		if t.Outdated {
			loc += " (outdated)"
		}
		last := ""
		if n := len(t.Comments); n > 0 {
			last = t.Comments[n-1].Author + ": " + strings.ReplaceAll(t.Comments[n-1].Body, "\n", " ")
			if len(last) > 70 {
				last = last[:70] + "…"
			}
		}
		fmt.Printf("%s #%-4d %-9s %-40s %s\n", mark, t.ID, t.State, loc, last)
	}
	return nil
}

// parseAnchor splits "path:40-45" / "path:40" on the LAST colon, so
// paths containing colons still parse.
func parseAnchor(s string) (path string, start, end int, err error) {
	i := strings.LastIndex(s, ":")
	if i <= 0 {
		return "", 0, 0, fmt.Errorf("anchor must be <path>:<line>[-<line>]")
	}
	path = s[:i]
	span := s[i+1:]
	a, b, _ := strings.Cut(span, "-")
	if start, err = strconv.Atoi(a); err != nil {
		return "", 0, 0, fmt.Errorf("bad line number %q", a)
	}
	end = start
	if b != "" {
		if end, err = strconv.Atoi(b); err != nil {
			return "", 0, 0, fmt.Errorf("bad line number %q", b)
		}
	}
	return path, start, end, nil
}

func runComment(args []string) error {
	ws := os.Getenv("ROOK_WORKSPACE")
	if len(args) >= 2 && args[0] == "-w" {
		ws, args = args[1], args[2:]
	}
	if len(args) < 2 || ws == "" {
		return fmt.Errorf("usage: rookctl comment [-w workspace] <path>:<line>[-<line>] <text…>")
	}
	path, start, end, err := parseAnchor(args[0])
	if err != nil {
		return err
	}
	c, err := connect()
	if err != nil {
		return err
	}
	raw, err := c.req("POST", "/workspaces/"+ws+"/threads", map[string]any{
		"path": path, "startLine": start, "endLine": end,
		"body": strings.Join(args[1:], " "),
	})
	if err != nil {
		return err
	}
	var th struct {
		ID int64 `json:"id"`
	}
	json.Unmarshal(raw, &th)
	fmt.Printf("#%d pending — rookctl submit to send\n", th.ID)
	return nil
}

func runSubmit(args []string) error {
	ws := os.Getenv("ROOK_WORKSPACE")
	if len(args) >= 2 && args[0] == "-w" {
		ws = args[1]
	}
	if ws == "" {
		return fmt.Errorf("usage: rookctl submit [-w workspace] (or run inside a rook window)")
	}
	c, err := connect()
	if err != nil {
		return err
	}
	raw, err := c.req("POST", "/workspaces/"+ws+"/threads/submit", map[string]any{})
	if err != nil {
		return err
	}
	var res struct {
		Mode        string `json:"mode"`
		RookSession string `json:"rookSession"`
		Count       int    `json:"count"`
	}
	json.Unmarshal(raw, &res)
	fmt.Printf("%d comment(s) submitted — nudge %s (%s)\n", res.Count, res.Mode, res.RookSession)
	return nil
}

// runThreadVerb handles reply/resolve/reopen — the agent's verbs, so
// author/by default to agent; --user says a human is driving the CLI.
func runThreadVerb(verb string, args []string) error {
	asUser := false
	kept := args[:0]
	for _, a := range args {
		if a == "--user" {
			asUser = true
		} else {
			kept = append(kept, a)
		}
	}
	args = kept
	if len(args) < 1 {
		return fmt.Errorf("usage: rookctl %s <thread-id> [text…] [--user]", verb)
	}
	id := args[0]
	who := "agent"
	if asUser {
		who = "user"
	}
	c, err := connect()
	if err != nil {
		return err
	}
	switch verb {
	case "reply":
		if len(args) < 2 {
			return fmt.Errorf("usage: rookctl reply <thread-id> <text…>")
		}
		_, err = c.req("POST", "/threads/"+id+"/comments",
			map[string]string{"body": strings.Join(args[1:], " "), "author": who})
	case "resolve":
		_, err = c.req("POST", "/threads/"+id+"/resolve", map[string]string{"by": who})
	case "reopen":
		_, err = c.req("POST", "/threads/"+id+"/reopen", map[string]string{})
	}
	return err
}
```

Add `"strconv"` to main.go imports if not present.

- [ ] **Step 4: Build + smoke the parse helper**

Run: `go build ./cmd/rookctl/ && go vet ./cmd/rookctl/`
Expected: clean build. (`parseAnchor` gets its real exercise in Task 7's E2E — rookctl has no test file today and this plan follows that convention.)

- [ ] **Step 5: Commit**

```bash
git add cmd/rookctl/main.go
git commit -m "rookctl: thread verbs — the responder skill's tool surface

threads/comment/submit list-create-send for humans and scripts;
reply/resolve/reopen as the agent's verbs (author defaults to agent,
--user overrides). This CLI is the entire contract the rook-threads
skill will drive in slice 2c.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: End-to-end verification + PR

**Files:**
- None created (verification only; fixes land where they fall).

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Full hygiene**

```bash
go build ./internal/... ./cmd/... && go vet ./internal/... ./cmd/...
go test ./internal/... ./cmd/rook-host/... ./cmd/rook-agent/... ./cmd/rookctl/... 2>&1 | grep -v 'ld: warning' | tail -12
golangci-lint run ./internal/host/... ./cmd/rookctl/... 2>&1 | tail -3
```
Expected: all `ok`, `0 issues`.

- [ ] **Step 2: Live E2E via the verify skill (isolated host — never the live daemon)**

Invoke the `verify` skill with: "exercise the thread endpoints and rookctl thread verbs end to end". The script it should end up running:

```sh
S=<scratch>/threads-verify; mkdir -p $S/{state,data,shim,bin}
go build -o $S/bin/rook-host ./cmd/rook-host && go build -o $S/bin/rookctl ./cmd/rookctl
R=$S/repo; mkdir -p $R && git -C $R init -qb main
printf 'l1\nl2\nl3\nl4\nl5\n' > $R/f.txt
git -C $R add . && git -C $R -c user.name=t -c user.email=t@t commit -qm init
env -i HOME=$HOME USER=$USER XDG_STATE_HOME=$S/state XDG_DATA_HOME=$S/data \
  SHELL=/bin/sh PATH=$S/shim:/opt/homebrew/bin:/usr/bin:/bin \
  $S/bin/rook-host > $S/host.log 2>&1 &
sleep 1
RC="env -i HOME=$HOME XDG_STATE_HOME=$S/state XDG_DATA_HOME=$S/data PATH=/usr/bin:/bin $S/bin/rookctl"
T=$(python3 -c "import json;print(json.load(open('$S/state/rook/host.json'))['token'])")
B=http://127.0.0.1:$(python3 -c "import json;print(json.load(open('$S/state/rook/host.json'))['port'])")
curl -s -H "Authorization: Bearer $T" -X POST $B/workspaces -d "{\"name\":\"ws\",\"root\":\"$R\"}" > /dev/null

$RC comment -w ws f.txt:2-3 "why is this here?"        # → #1 pending
$RC comment -w ws f.txt:5 "typo"                        # → #2 pending
$RC threads -w ws                                       # two pending rows
$RC submit -w ws                                        # → spawned (no claim in the fixture)
$RC threads -w ws --pending --json                      # both awaiting agent
$RC reply 1 "because of the retry loop — see commit"    # agent verbs
$RC resolve 1
$RC threads -w ws --pending                             # only #2 remains
printf 'x\ny\nl1\nl2\nl3\nl4\nl5\n' > $R/f.txt          # shift the anchor
$RC threads -w ws --json | python3 -m json.tool | grep -A2 currentStart  # #2 now 7-7
$RC reopen 1 && $RC threads -w ws                       # #1 open again, agent_reopens=1
$RC submit -w ws                                        # re-nudge fires (open + awaiting)
kill $(python3 -c "import json;print(json.load(open('$S/state/rook/host.json'))['pid'])")
```
Check each command's output matches the comment; kill any spawned responder sessions via the API before teardown.

- [ ] **Step 3: Push + PR**

```bash
git push -u origin threads-host
gh pr create --title "Threads slice 2a: host domain + rookctl" --body "<summarize: spec link, endpoints, re-anchor engine, submit/nudge, rookctl verbs, test evidence; note 2b (pane UI) and 2c (skill+inbox) follow>

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Self-Review (performed while writing)

- **Spec coverage (2a scope):** tables ✓ (T1), snapshots-in-rook.db ✓ (T1/T3), create/list with re-anchor ✓ (T3), per-thread verbs + declared author + agent_reopens ✓ (T4), submit + re-nudge + typed/spawned ✓ (T5), rookctl surface incl. `--pending` derivation ✓ (T6), blob prune ✓ (T1/T4), 2 MB/binary caps + confinePath ✓ (T3), fail-open outdated ✓ (T2). Deliberately out (2b/2c): pane UI, attention `threads` section, rook-threads skill + install-skill.
- **Type consistency:** `ThreadInfo`/`ThreadComment` JSON keys match between threads.go and rookctl's `threadRow`; `errThreadState` used by both store and handlers; `hunk` fields consistent between parseHunks/mapRange tests.
- **Known judgment calls encoded:** claims-only claude detection (no lsof, testable; documented in code), comments return 204 (GET list is the read surface), resolve-of-pending allowed (discarding your own draft).

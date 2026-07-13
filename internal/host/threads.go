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

package host

// Threads: file-anchored AI conversations (docs/superpowers/specs/
// 2026-07-12-threads-design.md). The host is a dumb store behind an
// agent-legible API — the responder is a claude session wielding rookctl,
// never host-side inference. Anchors are content-identified (git blob
// hash); snapshots live in rook.db, NEVER in the user's repo. Threads are
// rook-native and never mirrored to GitHub.

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
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
	ID           int64           `json:"id"`
	Workspace    string          `json:"workspace"`
	Path         string          `json:"path"`
	StartLine    int             `json:"startLine"` // 1-based, inclusive
	EndLine      int             `json:"endLine"`
	Side         string          `json:"side"`                // modified|original
	BlobSHA      string          `json:"blobSha"`             // anchor content identity
	CommitSHA    string          `json:"commitSha,omitempty"` // display only
	AnchorText   string          `json:"anchorText"`
	State        string          `json:"state"` // pending|open|resolved
	ResolvedBy   string          `json:"resolvedBy,omitempty"`
	AgentReopens int             `json:"agentReopens,omitempty"`
	Created      time.Time       `json:"created"`
	Updated      time.Time       `json:"updated"`
	Submitted    *time.Time      `json:"submitted,omitempty"`
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
// is the negative-verdict datum — incremented only when both sides match.
func (r *registry) reopenThread(id int64, by string) error {
	if r.db == nil {
		return fmt.Errorf("no registry db")
	}
	now := time.Now().Format(time.RFC3339Nano)
	res, err := r.db.Exec(
		`UPDATE threads SET state = 'open',
		   agent_reopens = agent_reopens + (resolved_by = 'agent' AND ? = 'user'),
		   resolved_by = '', updated_at = ?
		 WHERE id = ? AND state = 'resolved'`, by, now, id)
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
			h.anchorNow(ws, top, t)
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
	var base reviewBase
	if req.Side == "original" {
		base = h.reviewBaseFor(ws, top, req.Base)
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

	// the commit recorded alongside the snapshot must be the ref the
	// content actually came from: HEAD for modified, the diff base for
	// original (in branch mode that's a merge-base sha, not HEAD)
	commitRef := "HEAD"
	if req.Side == "original" {
		commitRef = base.ref
	}
	commit := ""
	if out, err := gitOut(top, reviewTimeout, "rev-parse", commitRef); err == nil {
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
	h.anchorNow(ws, top, t)
	writeJSON(w, t)
}

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
		var req struct{ By string }
		json.NewDecoder(r.Body).Decode(&req)
		if req.By == "" {
			req.By = "user"
		}
		if req.By != "user" && req.By != "agent" {
			http.Error(w, "by must be user or agent", http.StatusBadRequest)
			return
		}
		switch err := h.reg.reopenThread(id, req.By); err {
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

// threadsNudge is THE nudge — one host-built string for both actuation
// paths, so every surface triggers the identical thing.
func threadsNudge(n int, ws string) string {
	return fmt.Sprintf("You have %d review comment(s) in %s. Use the rook-threads skill to address them.", n, ws)
}

// claudeSessionIn finds the workspace's live claude window via the claim
// machinery (SessionStart hook → rookctl claim — authoritative, and the
// standard install). Deliberately NOT fg-based: no lsof on the submit
// path, and claims are testable against pipe fixtures. Multiple claimed
// windows pick the newest session (highest numeric id) — deterministic,
// and the latest-started claude is the likeliest active coder. Nil means
// no claim; submit spawns a responder instead.
func (h *Host) claudeSessionIn(ws string) *session {
	h.bindMu.Lock()
	defer h.bindMu.Unlock()
	var best *session
	bestN := -1
	for _, sid := range h.claims {
		s := h.get(sid)
		if s == nil || s.info.Workspace != ws {
			continue
		}
		n, err := strconv.Atoi(strings.TrimPrefix(sid, "s"))
		if err != nil {
			n = 0 // unknown shape sorts oldest
		}
		if n > bestN {
			best, bestN = s, n
		}
	}
	return best
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
	if s := h.claudeSessionIn(name); s != nil {
		if _, err := s.pty.Write([]byte(prompt + "\r")); err == nil {
			writeJSON(w, map[string]any{"mode": "typed", "rookSession": s.info.ID, "count": n})
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

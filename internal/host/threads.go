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
	"log"
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
	ID         int64  `json:"id"`
	Workspace  string `json:"workspace"`
	Path       string `json:"path"`
	StartLine  int    `json:"startLine"` // 1-based, inclusive
	EndLine    int    `json:"endLine"`
	Side       string `json:"side"`                // modified|original
	BlobSHA    string `json:"blobSha"`             // anchor content identity
	CommitSHA  string `json:"commitSha,omitempty"` // display only
	AnchorText string `json:"anchorText"`
	State      string `json:"state"` // pending|open|resolved
	// Why the nudge didn't reach a responder; "" when it did. A thread with
	// this set is open and submitted but NOBODY WAS TOLD — the one failure
	// the old model rendered as a normal wait.
	DeliverError string `json:"deliverError,omitempty"`
	// The thread-buffer tail: text saved below the scissors line (:w) but
	// not yet crystallized into a comment (threaddoc.go).
	Draft        string          `json:"draft,omitempty"`
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
	commit_sha, anchor_text, state, deliver_error, draft, resolved_by, agent_reopens,
	created_at, updated_at, submitted_at`

func scanThread(row interface{ Scan(...any) error }) (*ThreadInfo, error) {
	var t ThreadInfo
	var created, updated string
	var submitted sql.NullString
	if err := row.Scan(&t.ID, &t.Workspace, &t.Path, &t.StartLine, &t.EndLine,
		&t.Side, &t.BlobSHA, &t.CommitSHA, &t.AnchorText, &t.State, &t.DeliverError,
		&t.Draft, &t.ResolvedBy, &t.AgentReopens, &created, &updated, &submitted); err != nil {
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

// createThread inserts the anchor blob (if any), the thread, and its
// first comment all in one tx; the blob lands before the thread row does,
// so a concurrent resolve's pruneAnchorBlobs (which only sees committed
// threads) can never delete a snapshot out from under a thread that
// hasn't committed yet. An EMPTY body creates a comment-less thread —
// the gt-create path, where the first words arrive later as the tail —
// and deleteThreadIfEmpty is its abort door.
func (r *registry) createThread(t *ThreadInfo, body string, blob []byte) (int64, error) {
	if r.db == nil {
		return 0, fmt.Errorf("no registry db")
	}
	now := time.Now().Format(time.RFC3339Nano)
	tx, err := r.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	if blob != nil {
		if _, err := tx.Exec(`INSERT OR IGNORE INTO anchor_blobs (sha, content) VALUES (?, ?)`,
			t.BlobSHA, blob); err != nil {
			return 0, err
		}
	}
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
	if body != "" {
		if _, err := tx.Exec(
			`INSERT INTO thread_comments (thread_id, author, body, created_at)
			 VALUES (?, 'user', ?, ?)`, id, body, now); err != nil {
			return 0, err
		}
	}
	return id, tx.Commit()
}

// setThreadDraft stores the tail as the thread's draft — :w, the silent
// save. Deliberately no updated_at bump and no notify: a draft is private
// until a verb crystallizes it, and a notify here would bounce straight
// back into the pane that is mid-edit.
func (r *registry) setThreadDraft(id int64, draft string) error {
	if r.db == nil {
		return fmt.Errorf("no registry db")
	}
	res, err := r.db.Exec(`UPDATE threads SET draft = ? WHERE id = ?`, draft, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return sql.ErrNoRows
	}
	return nil
}

// errEmptyDraft is note/ask with nothing below the scissors — callers map
// it to 400.
var errEmptyDraft = errors.New("draft is empty")

// commitThreadDraft crystallizes the stored draft as a user comment — the
// only moment history grows from this side. One tx, so a concurrent :w
// can't slip a new tail between the read and the clear.
func (r *registry) commitThreadDraft(id int64) (string, error) {
	if r.db == nil {
		return "", fmt.Errorf("no registry db")
	}
	tx, err := r.db.Begin()
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	var draft string
	if err := tx.QueryRow(`SELECT draft FROM threads WHERE id = ?`, id).Scan(&draft); err != nil {
		return "", err
	}
	body := strings.TrimSpace(draft)
	if body == "" {
		return "", errEmptyDraft
	}
	now := time.Now().Format(time.RFC3339Nano)
	if _, err := tx.Exec(
		`UPDATE threads SET draft = '', updated_at = ? WHERE id = ?`, now, id); err != nil {
		return "", err
	}
	if _, err := tx.Exec(
		`INSERT INTO thread_comments (thread_id, author, body, created_at)
		 VALUES (?, 'user', ?, ?)`, id, body, now); err != nil {
		return "", err
	}
	return body, tx.Commit()
}

// deleteThreadIfEmpty is the gt-then-:q abort: only a thread with no
// comments and no draft may vanish. Anything written is content, and
// content leaves through resolve — never through this door. The guard
// lives in the DELETE itself so a racing comment can't be orphaned.
func (r *registry) deleteThreadIfEmpty(id int64) error {
	if r.db == nil {
		return fmt.Errorf("no registry db")
	}
	res, err := r.db.Exec(
		`DELETE FROM threads WHERE id = ? AND draft = ''
		   AND NOT EXISTS (SELECT 1 FROM thread_comments WHERE thread_id = threads.id)`, id)
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
	tx, err := r.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.Exec(
		`UPDATE threads SET updated_at = ? WHERE id = ?`, now, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return sql.ErrNoRows
	}
	if _, err := tx.Exec(
		`INSERT INTO thread_comments (thread_id, author, agent_session, body, created_at)
		 VALUES (?, ?, ?, ?, ?)`, id, author, agentSession, body, now); err != nil {
		return err
	}
	return tx.Commit()
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

// submitThread flips ONE pending thread open — the ,? path, where the user
// asked about this line and means this line. Deliberately NOT submitThreads
// scoped to an id: sweeping the workspace would ship every scratch note the
// user had deliberately left pending. Re-submitting an already-open thread is
// not an error, mirroring the batch contract ("you missed this one").
func (r *registry) submitThread(id int64) {
	if r.db == nil {
		return
	}
	now := time.Now().Format(time.RFC3339Nano)
	if _, err := r.db.Exec(
		`UPDATE threads SET state = 'open', submitted_at = ?, updated_at = ?
		 WHERE id = ? AND state = 'pending'`, now, now, id); err != nil {
		log.Printf("threads: submit one: %v", err)
	}
}

// markDeliverError stamps the workspace's awaiting threads with why the
// nudge failed. Scoped to open+awaiting because that is exactly the set the
// nudge was speaking for: a resolved thread or one the agent already
// answered is not waiting on a delivery that didn't happen.
func (r *registry) markDeliverError(ws, msg string) {
	if r.db == nil || msg == "" {
		return
	}
	if _, err := r.db.Exec(
		`UPDATE threads SET deliver_error = ? WHERE workspace = ? AND state = 'open'
		   AND (SELECT c.author FROM thread_comments c
		        WHERE c.thread_id = threads.id ORDER BY c.id DESC LIMIT 1) = 'user'`,
		promptSafe(msg, 200), ws); err != nil {
		log.Printf("threads: mark deliver error: %v", err)
	}
}

// markThreadDeliverError is the ,? path — one thread, one nudge, one blame.
func (r *registry) markThreadDeliverError(id int64, msg string) {
	if r.db == nil || msg == "" {
		return
	}
	if _, err := r.db.Exec(`UPDATE threads SET deliver_error = ? WHERE id = ?`,
		promptSafe(msg, 200), id); err != nil {
		log.Printf("threads: mark deliver error one: %v", err)
	}
}

// clearDeliverError forgets a past failure for the whole workspace. Called
// on every SUCCESSFUL nudge: a resubmit that lands is the proof the old
// error is stale, and leaving it would keep a warning on a thread that is
// now genuinely just waiting.
func (r *registry) clearDeliverError(ws string) {
	if r.db == nil {
		return
	}
	if _, err := r.db.Exec(
		`UPDATE threads SET deliver_error = '' WHERE workspace = ? AND deliver_error != ''`,
		ws); err != nil {
		log.Printf("threads: clear deliver error: %v", err)
	}
}

// clearThreadDeliverError runs when the AGENT speaks on a thread — the
// other proof of delivery, and the stronger one. A nudge can fail, the user
// can paste the prompt by hand, and the reply still arrives; the warning
// has to come down when the thing it warned about demonstrably happened.
func (r *registry) clearThreadDeliverError(id int64) {
	if r.db == nil {
		return
	}
	if _, err := r.db.Exec(`UPDATE threads SET deliver_error = '' WHERE id = ?`,
		id); err != nil {
		log.Printf("threads: clear deliver error one: %v", err)
	}
}

// threadsAwaitingAgent counts open threads whose LAST comment is the
// user's — "needs reply" is derived, never stored.
func (r *registry) threadsAwaitingAgent(ws string) int {
	if r.db == nil {
		return 0
	}
	var n int
	if err := r.db.QueryRow(
		`SELECT COUNT(*) FROM threads t
		 WHERE t.workspace = ? AND t.state = 'open'
		   AND (SELECT c.author FROM thread_comments c
		        WHERE c.thread_id = t.id ORDER BY c.id DESC LIMIT 1) = 'user'`,
		ws).Scan(&n); err != nil {
		log.Printf("threads: awaiting count: %v", err)
	}
	return n
}

// putAnchorBlob is the test seam — production writes go through
// createThread's tx instead, so pruneAnchorBlobs can never race a
// half-created thread.
func (r *registry) putAnchorBlob(sha string, content []byte) {
	if r.db == nil {
		return
	}
	if _, err := r.db.Exec(`INSERT OR IGNORE INTO anchor_blobs (sha, content) VALUES (?, ?)`,
		sha, content); err != nil {
		log.Printf("threads: put blob: %v", err)
	}
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
	if _, err := r.db.Exec(`DELETE FROM anchor_blobs WHERE sha NOT IN
	           (SELECT blob_sha FROM threads WHERE state != 'resolved')`); err != nil {
		log.Printf("threads: prune blobs: %v", err)
	}
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
	// An empty body is legal — the gt-create path opens a comment-less
	// thread and the first words arrive later as its tail.
	req.Body = strings.TrimSpace(req.Body)
	switch {
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
	id, err := h.reg.createThread(&ThreadInfo{
		Workspace: name, Path: req.Path,
		StartLine: req.StartLine, EndLine: req.EndLine,
		Side: req.Side, BlobSHA: sha, CommitSHA: commit,
		AnchorText: strings.Join(lines[req.StartLine-1:req.EndLine], "\n"),
	}, req.Body, content)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	t := h.reg.getThread(id)
	h.anchorNow(ws, top, t)
	h.notifyThreads(name)
	writeJSON(w, t)
}

// handleThread routes /threads/{id}[/comments|resolve|reopen|submit|doc|
// note|ask]. Thread ids are global, so per-thread verbs need no workspace —
// `rookctl reply 12` works from anywhere.
func (h *Host) handleThread(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/threads/")
	idStr, action, _ := strings.Cut(rest, "/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	// DELETE /threads/{id} — the gt-then-:q abort. Guarded: only a thread
	// with no comments and no draft may vanish (409 otherwise); its anchor
	// blob is released with it.
	if action == "" && r.Method == http.MethodDelete {
		t := h.reg.getThread(id)
		if t == nil {
			http.Error(w, "no such thread", http.StatusNotFound)
			return
		}
		switch err := h.reg.deleteThreadIfEmpty(id); err {
		case nil:
			h.reg.pruneAnchorBlobs()
			h.notifyThreads(t.Workspace)
			w.WriteHeader(http.StatusNoContent)
		case errThreadState:
			http.Error(w, "thread has content — resolve it instead", http.StatusConflict)
		default:
			http.Error(w, "no such thread", http.StatusNotFound)
		}
		return
	}
	// GET /threads/{id}/doc — the thread as an editable document
	// (threaddoc.go): rendered history through the scissors line, then the
	// stored draft. Resolved threads render with no scissors and the client
	// opens them read-only.
	if action == "doc" && r.Method == http.MethodGet {
		t := h.reg.getThread(id)
		if t == nil {
			http.Error(w, "no such thread", http.StatusNotFound)
			return
		}
		doc, _ := renderThreadDoc(t)
		// draft rides along so the client can compute the prefix EXACTLY
		// (content minus draft) instead of scanning for the scissors — a
		// comment body could legally contain a scissors-shaped line.
		writeJSON(w, map[string]any{
			"content": doc, "draft": t.Draft, "resolved": t.State == "resolved",
		})
		return
	}
	if r.Method != http.MethodPost {
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
		// The agent speaking is proof the nudge landed, whatever the
		// delivery bookkeeping believes — clear any stale warning first so
		// the notify below carries the corrected row.
		if req.Author == "agent" {
			h.reg.clearThreadDeliverError(id)
		}
		// THE case this channel exists for: the agent's reply arrives here
		// (rookctl reply → this route), and until now nothing told the UI.
		h.notifyThreadsFor(id)
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
			h.notifyThreadsFor(id)   // before the prune, while the row is still readable
			h.reg.pruneAnchorBlobs() // resolved threads release their snapshots
			w.WriteHeader(http.StatusNoContent)
		case errThreadState:
			http.Error(w, "already resolved", http.StatusConflict)
		default:
			http.Error(w, "no such thread", http.StatusNotFound)
		}
	case "submit":
		// ask about THIS thread now. The nudge names the thread, so the
		// responder needs no list round-trip and can't mistake which comment
		// the user is waiting on.
		t := h.reg.getThread(id)
		if t == nil {
			http.Error(w, "no such thread", http.StatusNotFound)
			return
		}
		if t.State == "resolved" {
			http.Error(w, "thread is resolved", http.StatusConflict)
			return
		}
		h.submitThreadAndNudge(w, t)
	case "doc":
		// :w — the prefix check. The saved content must start byte-for-byte
		// with a FRESH render of the history through the scissors line;
		// everything after is the tail, stored as the draft. A mismatch —
		// concurrent reply, hand-mangled history, either — answers 409 with
		// the fresh doc so the client re-renders and splices its tail.
		t := h.reg.getThread(id)
		if t == nil {
			http.Error(w, "no such thread", http.StatusNotFound)
			return
		}
		if t.State == "resolved" {
			http.Error(w, "thread is resolved", http.StatusConflict)
			return
		}
		var req struct{ Content string }
		json.NewDecoder(r.Body).Decode(&req)
		tail, ok := splitThreadDoc(t, req.Content)
		if !ok {
			doc, _ := renderThreadDoc(t)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusConflict)
			json.NewEncoder(w).Encode(map[string]any{"content": doc, "draft": t.Draft})
			return
		}
		if err := h.reg.setThreadDraft(id, tail); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case "note":
		// :ThreadNote — crystallize the stored draft as a comment without
		// summoning the agent. The whiteboard verb: land it, keep reviewing.
		switch _, err := h.reg.commitThreadDraft(id); err {
		case nil:
			h.notifyThreadsFor(id)
			w.WriteHeader(http.StatusNoContent)
		case errEmptyDraft:
			http.Error(w, "draft is empty — write below the scissors and :w first", http.StatusBadRequest)
		default:
			http.Error(w, "no such thread", http.StatusNotFound)
		}
	case "ask":
		// :ThreadAsk — crystallize, then the single-thread submit path:
		// the same nudge, deliver-error bookkeeping included.
		t := h.reg.getThread(id)
		if t == nil {
			http.Error(w, "no such thread", http.StatusNotFound)
			return
		}
		if t.State == "resolved" {
			http.Error(w, "thread is resolved", http.StatusConflict)
			return
		}
		if _, err := h.reg.commitThreadDraft(id); err != nil {
			if err == errEmptyDraft {
				http.Error(w, "draft is empty — write below the scissors and :w first", http.StatusBadRequest)
			} else {
				http.Error(w, err.Error(), http.StatusInternalServerError)
			}
			return
		}
		// re-read: the nudge quotes comments, and the crystallized draft
		// must be among them (on a gt-created thread it IS the first)
		if t = h.reg.getThread(id); t == nil {
			http.Error(w, "no such thread", http.StatusNotFound)
			return
		}
		h.submitThreadAndNudge(w, t)
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
			h.notifyThreadsFor(id)
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

// The nudges are SELF-CONTAINED on purpose. They used to say "use the
// rook-threads skill", which named a skill that need not exist on the
// machine — a responder without it read the sentence, had no verbs, and the
// agent half of the loop quietly did nothing. Spelling the rookctl calls out
// costs a few hundred characters and works on a cold session.
//
// Both must stay ONE LINE: the typed path writes prompt+"\r" into a pty, so
// an embedded newline would submit the prompt early, mid-sentence.

func threadsNudge(n int, ws string) string {
	return fmt.Sprintf(
		"You have %d review comment(s) waiting in workspace %s. Read them with `rookctl threads -w %s`. "+
			"For each: investigate the code it anchors to, then answer with `rookctl reply <id> <text…>` "+
			"(replies are authored as the agent). Use `rookctl resolve <id>` only once a comment is "+
			"genuinely addressed — if you disagree, or the call is the human's to make, reply with your "+
			"reasoning and leave it open. Answer every thread before you finish.",
		n, ws, ws)
}

// threadNudgeOne is the ,? path: one comment, asked about now. It quotes the
// comment so the responder can start without a round-trip to the list.
func threadNudgeOne(t *ThreadInfo) string {
	return fmt.Sprintf(
		"A review comment is waiting in workspace %s, on %s lines %d-%d (thread %d): %q. "+
			"Investigate the code it anchors to, then answer with `rookctl reply %d <text…>`. "+
			"Use `rookctl resolve %d` only once it is genuinely addressed — if you disagree, or the "+
			"call is the human's to make, reply with your reasoning and leave it open. "+
			"`rookctl threads -w %s` has the full thread if you need more context.",
		t.Workspace, t.Path, t.StartLine, t.EndLine, t.ID,
		promptSafe(firstBody(t), 240), t.ID, t.ID, t.Workspace)
}

// firstBody is the comment that opened the thread — what the user actually
// wrote, as opposed to any agent replies below it.
func firstBody(t *ThreadInfo) string {
	if len(t.Comments) == 0 {
		return ""
	}
	return t.Comments[0].Body
}

// promptSafe flattens and caps user text destined for a one-line prompt.
// Fields collapses every run of whitespace — newlines included, which is the
// whole point — and the cap is in RUNES so a truncation can't split one.
func promptSafe(s string, max int) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > max {
		s = string(r[:max]) + "…"
	}
	return s
}

// submitThreadAndNudge flips ONE thread open and nudges the responder,
// answering the HTTP request either way — the shared tail of the submit
// and ask verbs, so the two can't drift in state flips or deliver-error
// bookkeeping. The caller has already checked existence and resolved-ness.
func (h *Host) submitThreadAndNudge(w http.ResponseWriter, t *ThreadInfo) {
	h.reg.submitThread(t.ID)
	t.State = "open"
	h.notifyThreads(t.Workspace)
	mode, sid, err := h.nudge(t.Workspace, threadNudgeOne(t))
	if err != nil {
		h.reg.markThreadDeliverError(t.ID, err.Error())
		h.notifyThreads(t.Workspace)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	h.reg.clearDeliverError(t.Workspace)
	h.notifyThreads(t.Workspace)
	writeJSON(w, map[string]any{"mode": mode, "rookSession": sid, "count": 1})
}

// nudge actuates a prompt at the workspace's responder: the live claimed
// claude window if there is one, else a freshly spawned task. Both submit
// paths route through here so the batch and single-thread flows can't drift
// in how they reach the agent.
func (h *Host) nudge(ws, prompt string) (mode, rookSession string, err error) {
	if h.nudgeFn != nil {
		return h.nudgeFn(ws, prompt) // test seam — nil in production
	}
	if s := h.claudeSessionIn(ws); s != nil {
		if _, werr := s.pty.Write([]byte(prompt + "\r")); werr == nil {
			return "typed", s.info.ID, nil
		}
		// a dead pty falls through to a fresh responder
	}
	s, err := h.spawnTask(ws, prompt)
	if err != nil {
		return "", "", err
	}
	return "spawned", s.info.ID, nil
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
	for tid, sid := range h.claims {
		s := h.get(sid)
		if s == nil || s.info.Workspace != ws {
			continue
		}
		// The agent that claimed this window may be gone without having
		// said so (see claimAliveLocked). A dead claim is not a responder.
		if !h.claimAliveLocked(tid, s) {
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
	h.notifyThreads(name)
	mode, sid, err := h.nudge(name, threadsNudge(waiting, name))
	if err != nil {
		// Record it before answering. The threads are already open; without
		// this they'd be indistinguishable from delivered ones and the user
		// would be waiting on an agent that was never told.
		h.reg.markDeliverError(name, err.Error())
		h.notifyThreads(name)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	h.reg.clearDeliverError(name)
	h.notifyThreads(name)
	writeJSON(w, map[string]any{"mode": mode, "rookSession": sid, "count": n})
}

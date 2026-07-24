package host

// RookTask: a generic, per-developer, nestable unit of attention
// (docs/superpowers/specs/2026-07-17-rooktask-review-design.md). The base
// object is dumb — `state` is an opaque token the work_type interprets, the
// anchor is a kind-tagged union, and role-specific data rides `detail` (JSON)
// rather than sprouting columns only one work_type reads. Review is the first
// work_type (reviewtasks.go); the host is a dumb store, never the scorer.

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"
)

// RookTask is one node in the task tree. A parent review carries children;
// a leaf (a hunk) carries a code anchor. Children is filled only when a
// caller asks for the tree.
type RookTask struct {
	ID        int64  `json:"id"`
	ParentID  int64  `json:"parentId"`
	Workspace string `json:"workspace"`
	WorkType  string `json:"workType"`
	State     string `json:"state"`
	Title     string `json:"title,omitempty"`

	// anchor (kind-tagged): 'code' uses the threads columns, 'ref' uses
	// anchorRef, 'none' uses nothing.
	AnchorKind string `json:"anchorKind"`
	Path       string `json:"path,omitempty"`
	StartLine  int    `json:"startLine,omitempty"`
	EndLine    int    `json:"endLine,omitempty"`
	Side       string `json:"side,omitempty"`
	BlobSHA    string `json:"blobSha,omitempty"`
	CommitSHA  string `json:"commitSha,omitempty"`
	AnchorText string `json:"anchorText,omitempty"`
	AnchorRef  string `json:"anchorRef,omitempty"`

	Origin    string `json:"origin"`
	SourceRef string `json:"sourceRef,omitempty"`

	// Detail is a work_type-owned JSON bag (parent: {scope,base}; leaf:
	// {score,category}). Always valid JSON on read — empty becomes {}.
	Detail  json.RawMessage `json:"detail,omitempty"`
	Created time.Time       `json:"created"`
	Updated time.Time       `json:"updated"`

	// Computed on read through the HTTP surface (code anchors with a
	// captured blob): the stored range mapped onto today's file — the same
	// seam threads use (reanchor.go anchorTaskNow). Zero-valued when the
	// leaf predates blob capture; clients fall back to StartLine.
	CurrentStart int  `json:"currentStart,omitempty"`
	CurrentEnd   int  `json:"currentEnd,omitempty"`
	Outdated     bool `json:"outdated,omitempty"`

	Children []*RookTask `json:"children,omitempty"`
}

const taskCols = `id, parent_id, workspace, work_type, state, title,
	anchor_kind, path, start_line, end_line, side, blob_sha, commit_sha,
	anchor_text, anchor_ref, origin, source_ref, detail, created_at, updated_at`

func scanTask(row interface{ Scan(...any) error }) (*RookTask, error) {
	var t RookTask
	var detail, created, updated string
	if err := row.Scan(&t.ID, &t.ParentID, &t.Workspace, &t.WorkType, &t.State,
		&t.Title, &t.AnchorKind, &t.Path, &t.StartLine, &t.EndLine, &t.Side,
		&t.BlobSHA, &t.CommitSHA, &t.AnchorText, &t.AnchorRef, &t.Origin,
		&t.SourceRef, &detail, &created, &updated); err != nil {
		return nil, err
	}
	if detail == "" {
		detail = "{}"
	}
	t.Detail = json.RawMessage(detail)
	t.Created, _ = time.Parse(time.RFC3339Nano, created)
	t.Updated, _ = time.Parse(time.RFC3339Nano, updated)
	return &t, nil
}

// insertTask writes one row within tx and returns its id. detail is stored
// verbatim ("" means the empty bag).
func insertTask(tx *sql.Tx, t *RookTask, now string) (int64, error) {
	res, err := tx.Exec(
		`INSERT INTO rook_tasks (parent_id, workspace, work_type, state, title,
		 anchor_kind, path, start_line, end_line, side, blob_sha, commit_sha,
		 anchor_text, anchor_ref, origin, source_ref, detail, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		t.ParentID, t.Workspace, t.WorkType, t.State, t.Title,
		t.AnchorKind, t.Path, t.StartLine, t.EndLine, t.Side, t.BlobSHA,
		t.CommitSHA, t.AnchorText, t.AnchorRef, orDefault(t.Origin, "rook"),
		t.SourceRef, string(t.Detail), now, now)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func orDefault(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

// createTask inserts one task in its own tx and returns the stored row —
// the single-row path (explore roots and breadcrumbs); batch builders
// (prepareReview) keep their own tx.
func (r *registry) createTask(t *RookTask) (*RookTask, error) {
	if r.db == nil {
		return nil, fmt.Errorf("no registry db")
	}
	tx, err := r.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	now := time.Now().Format(time.RFC3339Nano)
	id, err := insertTask(tx, t, now)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return r.getTask(id), nil
}

func (r *registry) getTask(id int64) *RookTask {
	if r.db == nil {
		return nil
	}
	t, err := scanTask(r.db.QueryRow(`SELECT `+taskCols+` FROM rook_tasks WHERE id = ?`, id))
	if err != nil {
		return nil
	}
	return t
}

// childrenOf returns a task's direct children, ordered by id (creation, which
// is the diff's hunk order).
func (r *registry) childrenOf(parentID int64) []*RookTask {
	out := []*RookTask{}
	if r.db == nil {
		return out
	}
	rows, err := r.db.Query(`SELECT `+taskCols+` FROM rook_tasks WHERE parent_id = ? ORDER BY id`, parentID)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		if t, err := scanTask(rows); err == nil {
			out = append(out, t)
		}
	}
	return out
}

// listRootTasks returns a workspace's top-level tasks of a work_type (empty =
// any), newest first, each with its children filled one level deep. Slice one
// is a flat tree, so one level covers it; deeper nesting is a builder change.
func (r *registry) listRootTasks(ws, workType string) []*RookTask {
	out := []*RookTask{}
	if r.db == nil {
		return out
	}
	q := `SELECT ` + taskCols + ` FROM rook_tasks WHERE parent_id = 0 AND workspace = ?`
	args := []any{ws}
	if workType != "" {
		q += ` AND work_type = ?`
		args = append(args, workType)
	}
	q += ` ORDER BY id DESC`
	rows, err := r.db.Query(q, args...)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		if t, err := scanTask(rows); err == nil {
			out = append(out, t)
		}
	}
	for _, t := range out {
		t.Children = r.childrenOf(t.ID)
	}
	return out
}

// findReviewParent returns the existing review root for a workspace+scope key
// (anchor_ref), or nil — the reconcile lookup.
func (r *registry) findReviewParent(ws, scopeKey string) *RookTask {
	if r.db == nil {
		return nil
	}
	t, err := scanTask(r.db.QueryRow(
		`SELECT `+taskCols+` FROM rook_tasks
		 WHERE parent_id = 0 AND workspace = ? AND work_type = 'review' AND anchor_ref = ?
		 ORDER BY id DESC LIMIT 1`, ws, scopeKey))
	if err != nil {
		return nil
	}
	return t
}

// setTaskState updates a leaf's disposition. Rejects an unknown id so the
// caller can 404. Callers validate the token against the work_type first.
func (r *registry) setTaskState(id int64, state string) error {
	if r.db == nil {
		return fmt.Errorf("no registry db")
	}
	now := time.Now().Format(time.RFC3339Nano)
	res, err := r.db.Exec(`UPDATE rook_tasks SET state = ?, updated_at = ? WHERE id = ?`, state, now, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return sql.ErrNoRows
	}
	return nil
}

// mergeTaskDetail folds a patch into a task's detail bag (read-modify-write),
// so a score never clobbers {scope,…} and a re-score never drops a note. The
// scorer (reviewscore.go) and the score endpoint both write through here.
func (r *registry) mergeTaskDetail(id int64, patch map[string]json.RawMessage) error {
	if r.db == nil {
		return fmt.Errorf("no registry db")
	}
	t := r.getTask(id)
	if t == nil {
		return sql.ErrNoRows
	}
	merged := map[string]json.RawMessage{}
	if len(t.Detail) > 0 {
		json.Unmarshal(t.Detail, &merged)
	}
	for k, v := range patch {
		merged[k] = v
	}
	buf, _ := json.Marshal(merged)
	return r.setTaskDetail(id, buf)
}

// setTaskDetail replaces a task's detail bag (the scorer's write path).
func (r *registry) setTaskDetail(id int64, detail json.RawMessage) error {
	if r.db == nil {
		return fmt.Errorf("no registry db")
	}
	now := time.Now().Format(time.RFC3339Nano)
	res, err := r.db.Exec(`UPDATE rook_tasks SET detail = ?, updated_at = ? WHERE id = ?`,
		string(detail), now, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return sql.ErrNoRows
	}
	return nil
}

// deleteTaskTree removes a root task and its descendants in one tx. Slice one
// is one level deep; the recursive delete keeps working if the builder starts
// nesting. Returns the prior children so prepareReview can carry dispositions
// forward before the delete.
func (r *registry) deleteTaskTree(rootID int64) error {
	if r.db == nil {
		return fmt.Errorf("no registry db")
	}
	tx, err := r.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// gather the whole subtree (BFS) — arbitrary depth, tiny trees
	ids := []int64{rootID}
	for i := 0; i < len(ids); i++ {
		rows, err := tx.Query(`SELECT id FROM rook_tasks WHERE parent_id = ?`, ids[i])
		if err != nil {
			return err
		}
		var kids []int64
		for rows.Next() {
			var id int64
			if rows.Scan(&id) == nil {
				kids = append(kids, id)
			}
		}
		rows.Close()
		ids = append(ids, kids...)
	}
	for _, id := range ids {
		if _, err := tx.Exec(`DELETE FROM rook_tasks WHERE id = ?`, id); err != nil {
			return err
		}
	}
	return tx.Commit()
}

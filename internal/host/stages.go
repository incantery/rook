package host

import (
	"log"
	"time"
)

// Stage is one step of a workspace's staged review workflow (docs: the
// pipeline that runs after the coding agent opens its PR). Rows are written
// only by the host — seeded once per PR cycle, advanced by the workflow
// engine. needs_input is deliberately NOT a status: it's live agent state,
// derived at read time from the stage's window.
type Stage struct {
	ID        int64  `json:"id"`
	Workspace string `json:"workspace"`
	Idx       int    `json:"idx"`
	Name      string `json:"name"`   // the slash command
	Status    string `json:"status"` // pending | running | done | error
	// RookSession is the window the stage runs in — the attribution key
	// that keeps a manual claude (or the coding agent) in the same
	// worktree from completing a review stage.
	RookSession string     `json:"rookSession,omitempty"`
	Detail      string     `json:"detail,omitempty"`
	CreatedAt   time.Time  `json:"createdAt"`
	StartedAt   *time.Time `json:"startedAt,omitempty"`
	FinishedAt  *time.Time `json:"finishedAt,omitempty"`
}

// insertStages seeds a workspace's pipeline: one pending row per stage, in
// order. No-op (false) when the workspace already has rows — this is THE
// dedup source of truth, so repeated poll ticks (or a racing trigger) can
// never seed twice. The tx makes check-then-insert atomic.
func (r *registry) insertStages(workspace string, names []string) (bool, error) {
	if r.db == nil {
		return false, errNoDB
	}
	tx, err := r.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	var n int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM stages WHERE workspace = ?`, workspace).Scan(&n); err != nil {
		return false, err
	}
	if n > 0 {
		return false, nil
	}
	now := time.Now().Format(time.RFC3339Nano)
	for i, name := range names {
		if _, err := tx.Exec(
			`INSERT INTO stages (workspace, idx, name, status, created_at) VALUES (?, ?, ?, 'pending', ?)`,
			workspace, i, name, now); err != nil {
			return false, err
		}
	}
	return true, tx.Commit()
}

const stageCols = `id, workspace, idx, name, status, rook_session, detail,
	created_at, COALESCE(started_at,''), COALESCE(finished_at,'')`

func scanStage(row interface{ Scan(...any) error }) (*Stage, error) {
	var s Stage
	var created, started, finished string
	if err := row.Scan(&s.ID, &s.Workspace, &s.Idx, &s.Name, &s.Status,
		&s.RookSession, &s.Detail, &created, &started, &finished); err != nil {
		return nil, err
	}
	s.CreatedAt, _ = time.Parse(time.RFC3339Nano, created)
	if started != "" {
		if t, err := time.Parse(time.RFC3339Nano, started); err == nil {
			s.StartedAt = &t
		}
	}
	if finished != "" {
		if t, err := time.Parse(time.RFC3339Nano, finished); err == nil {
			s.FinishedAt = &t
		}
	}
	return &s, nil
}

// stagesFor returns the workspace's pipeline in execution order.
func (r *registry) stagesFor(workspace string) []*Stage {
	if r.db == nil {
		return nil
	}
	rows, err := r.db.Query(
		`SELECT `+stageCols+` FROM stages WHERE workspace = ? ORDER BY idx`, workspace)
	if err != nil {
		log.Printf("stages: list %q: %v", workspace, err)
		return nil
	}
	defer rows.Close()
	var out []*Stage
	for rows.Next() {
		if s, err := scanStage(rows); err == nil {
			out = append(out, s)
		}
	}
	return out
}

// runningStage returns the workspace's live stage — at most one exists by
// construction (stages run sequentially).
func (r *registry) runningStage(workspace string) *Stage {
	if r.db == nil {
		return nil
	}
	s, err := scanStage(r.db.QueryRow(
		`SELECT `+stageCols+` FROM stages WHERE workspace = ? AND status = 'running' ORDER BY idx LIMIT 1`,
		workspace))
	if err != nil {
		return nil
	}
	return s
}

// startStage moves pending → running, recording the window it runs in. The
// guard makes a double-start (racing advance calls) a no-op, not a corrupt
// row.
func (r *registry) startStage(id int64, rookSession string) bool {
	if r.db == nil {
		return false
	}
	res, err := r.db.Exec(
		`UPDATE stages SET status = 'running', rook_session = ?, started_at = ? WHERE id = ? AND status = 'pending'`,
		rookSession, time.Now().Format(time.RFC3339Nano), id)
	if err != nil {
		log.Printf("stages: start %d: %v", id, err)
		return false
	}
	n, _ := res.RowsAffected()
	return n == 1
}

// finishStage moves running → done|error. The guard keeps a late duplicate
// completion (turn signal racing the reconciler) from rewriting history.
func (r *registry) finishStage(id int64, status, detail string) bool {
	if r.db == nil {
		return false
	}
	res, err := r.db.Exec(
		`UPDATE stages SET status = ?, detail = ?, finished_at = ? WHERE id = ? AND status = 'running'`,
		status, detail, time.Now().Format(time.RFC3339Nano), id)
	if err != nil {
		log.Printf("stages: finish %d: %v", id, err)
		return false
	}
	n, _ := res.RowsAffected()
	return n == 1
}

// failRunningStages errors every running stage — the restart reconciliation
// (windows died with the old host; ✗ + detail is the honest surface, no
// auto-respawn).
func (r *registry) failRunningStages(detail string) {
	if r.db == nil {
		return
	}
	if _, err := r.db.Exec(
		`UPDATE stages SET status = 'error', detail = ?, finished_at = ? WHERE status = 'running'`,
		detail, time.Now().Format(time.RFC3339Nano)); err != nil {
		log.Printf("stages: fail running: %v", err)
	}
}

// deleteStages drops a workspace's pipeline — workspace deletion's cleanup.
func (r *registry) deleteStages(workspace string) {
	if r.db == nil {
		return
	}
	if _, err := r.db.Exec(`DELETE FROM stages WHERE workspace = ?`, workspace); err != nil {
		log.Printf("stages: delete %q: %v", workspace, err)
	}
}

package host

// The edge journal: the device's half of the Cloud–IDE delivery
// contract (at-least-once arrival, at-most-once local effect). The
// protocol may deliver one command any number of times; the PRIMARY KEY
// makes every arrival after the first a no-op, and the phase column
// carries the effect's lifecycle across restarts:
//
//	journaled — received and durable; safe to ack, not yet acted on
//	executing — the effect may have started; a restart finds this and
//	            reconciles (every offered op is re-executable: create
//	            converges on the existing tree, cleanup on its absence)
//	resolved  — outcome recorded, result events journaled, all in one
//	            transaction with any grant spend and fence raise
//
// Events take a device sequence exactly once and are stored as the
// SIGNED bytes — a resubmission must be byte-identical or the cloud's
// signature check would call the journal a liar. Acked rows stay: the
// journal is a ledger, not a queue.
//
// Same posture as decisions (errNoDB): a host without a database
// refuses edge work outright. Executing commands that leave no receipt
// would be worse than executing nothing.

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

var errNoEdgeDB = errors.New("edge journal unavailable: registry has no database")

// edgeCommandRow is one journaled command.
type edgeCommandRow struct {
	CommandID string
	Command   []byte
	Phase     string // journaled | executing | resolved
	Status    string
}

// journalEdgeCommand records an arrived command. Returns true when this
// arrival was the first — only then does the caller owe an execution;
// every redelivery converges here.
func (r *registry) journalEdgeCommand(id string, raw []byte) (bool, error) {
	if r.db == nil {
		return false, errNoEdgeDB
	}
	res, err := r.db.Exec(
		`INSERT OR IGNORE INTO edge_commands (command_id, received_at, command) VALUES (?, ?, ?)`,
		id, time.Now().UTC().Format(time.RFC3339Nano), raw)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// unresolvedEdgeCommands returns journaled and executing commands in
// arrival order — the executor's worklist, and after a restart the
// reconciliation list.
func (r *registry) unresolvedEdgeCommands() ([]edgeCommandRow, error) {
	if r.db == nil {
		return nil, errNoEdgeDB
	}
	rows, err := r.db.Query(
		`SELECT command_id, command, phase, status FROM edge_commands
		 WHERE phase != 'resolved' ORDER BY received_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []edgeCommandRow
	for rows.Next() {
		var c edgeCommandRow
		if err := rows.Scan(&c.CommandID, &c.Command, &c.Phase, &c.Status); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// markEdgeExecuting flips a command into the maybe-started state before
// any effect runs — the crash marker reconciliation looks for.
func (r *registry) markEdgeExecuting(id string) error {
	if r.db == nil {
		return errNoEdgeDB
	}
	_, err := r.db.Exec(`UPDATE edge_commands SET phase = 'executing' WHERE command_id = ?`, id)
	return err
}

// journaledEdgeEvent is one signed result event with the device
// sequence its signature covers. Sequences are allocated by the caller
// (edgeMaxSeq + n) — the executor is the journal's only writer and runs
// serially, so pre-allocation cannot race; signing needs the sequence
// before the insert, because the sequence is a signed field.
type journaledEdgeEvent struct {
	Seq uint64
	Raw []byte
}

// resolveEdgeCommand is the journal's one composed write: the outcome,
// its signed result events, any grant spend, and any fence raise — one
// transaction, so a crash leaves either a command still owed an
// execution or a fully recorded outcome, never something in between.
// Resolving an already-resolved command is a no-op: the redelivered
// execution converged.
func (r *registry) resolveEdgeCommand(id, status, result string, events []journaledEdgeEvent, grantID, resource string, fence uint64) error {
	if r.db == nil {
		return errNoEdgeDB
	}
	tx, err := r.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.Exec(
		`UPDATE edge_commands SET phase = 'resolved', status = ?, result = ?, resolved_at = ?
		 WHERE command_id = ? AND phase != 'resolved'`,
		status, result, time.Now().UTC().Format(time.RFC3339Nano), id)
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err != nil || n == 0 {
		return err // already resolved: events exist, nothing more owed
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	for _, ev := range events {
		if _, err := tx.Exec(
			`INSERT INTO edge_events (device_seq, event, created_at) VALUES (?, ?, ?)`,
			int64(ev.Seq), ev.Raw, now); err != nil {
			return err
		}
	}
	if grantID != "" {
		if _, err := tx.Exec(
			`INSERT INTO edge_grants (grant_id, command_id, spent_at) VALUES (?, ?, ?)`,
			grantID, id, now); err != nil {
			return err
		}
	}
	if resource != "" && fence > 0 {
		if _, err := tx.Exec(
			`INSERT INTO edge_fences (resource, token) VALUES (?, ?)
			 ON CONFLICT(resource) DO UPDATE SET token = excluded.token WHERE excluded.token > token`,
			resource, int64(fence)); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// edgeGrantSpender names the command that spent a grant, "" if unspent.
// Single-use enforcement: a DIFFERENT command offering the same grant is
// refused; the same command re-arriving converges on its journal row
// long before this check.
func (r *registry) edgeGrantSpender(grantID string) (string, error) {
	if r.db == nil {
		return "", errNoEdgeDB
	}
	var cmd string
	err := r.db.QueryRow(`SELECT command_id FROM edge_grants WHERE grant_id = ?`, grantID).Scan(&cmd)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return cmd, err
}

// edgeFence returns the highest fencing token this device has honored
// for a resource — commands below it are from a stale era (§11.6).
func (r *registry) edgeFence(resource string) (uint64, error) {
	if r.db == nil {
		return 0, errNoEdgeDB
	}
	var token int64
	err := r.db.QueryRow(`SELECT token FROM edge_fences WHERE resource = ?`, resource).Scan(&token)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if token < 0 {
		return 0, fmt.Errorf("edge journal: fence for %s is negative", resource)
	}
	return uint64(token), err
}

// unackedEdgeEvents returns journaled events the cloud's cursor has not
// covered, in sequence order — the submit batch, verbatim bytes.
func (r *registry) unackedEdgeEvents() (seqs []uint64, raws [][]byte, err error) {
	if r.db == nil {
		return nil, nil, errNoEdgeDB
	}
	rows, err := r.db.Query(
		`SELECT device_seq, event FROM edge_events WHERE acked = 0 ORDER BY device_seq`)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var seq int64
		var raw []byte
		if err := rows.Scan(&seq, &raw); err != nil {
			return nil, nil, err
		}
		seqs = append(seqs, uint64(seq))
		raws = append(raws, raw)
	}
	return seqs, raws, rows.Err()
}

// ackEdgeEvents records the cloud's contiguous cursor: everything at or
// below it is delivered and stops being resubmitted.
func (r *registry) ackEdgeEvents(upTo uint64) error {
	if r.db == nil {
		return errNoEdgeDB
	}
	_, err := r.db.Exec(`UPDATE edge_events SET acked = 1 WHERE device_seq <= ? AND acked = 0`, int64(upTo))
	return err
}

// edgeAckedCursor is the highest contiguously acked sequence the journal
// remembers — what SyncEdge reports so the cloud can spot a restored
// backup drifting behind its own record.
func (r *registry) edgeAckedCursor() (uint64, error) {
	if r.db == nil {
		return 0, errNoEdgeDB
	}
	var seq sql.NullInt64
	err := r.db.QueryRow(`SELECT MAX(device_seq) FROM edge_events WHERE acked = 1`).Scan(&seq)
	if err != nil || !seq.Valid {
		return 0, err
	}
	return uint64(seq.Int64), nil
}

// edgeMaxSeq is the highest device sequence ever allocated, acked or
// not — the next event takes edgeMaxSeq+1, and a sequence is never
// reused no matter what was compacted or acked since.
func (r *registry) edgeMaxSeq() (uint64, error) {
	if r.db == nil {
		return 0, errNoEdgeDB
	}
	var seq sql.NullInt64
	err := r.db.QueryRow(`SELECT MAX(device_seq) FROM edge_events`).Scan(&seq)
	if err != nil || !seq.Valid {
		return 0, err
	}
	return uint64(seq.Int64), nil
}

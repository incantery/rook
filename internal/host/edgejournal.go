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
// Not every event resolves a command. A cloud-started agent session
// outlives the command that started it, and its own facts take
// sequences from this same space (edgeagent.go) — which is why the
// session bindings live here too, and why sequence allocation is now
// mutex-guarded rather than merely serial.
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
// (edgeMaxSeq + n); signing needs the sequence before the insert,
// because the sequence is a signed field.
//
// The executor was once the journal's only writer, which made
// pre-allocation race-free by construction. Agent sessions ended that:
// a session's own facts (edgeagent.go) are observed on the transcript
// and pty goroutines, not the edge loop. Host.edgeSeqMu is what that
// invariant became — every allocate→sign→insert runs under it, so
// sequences stay dense and each is signed by exactly the writer that
// claimed it.
type journaledEdgeEvent struct {
	Seq uint64
	Raw []byte
}

// appendEdgeEvent journals one signed event that resolves no command —
// an agent session's own word. Same ledger, same sequence space, same
// submit loop as a receipt; the only difference is that nothing else
// belongs in the transaction, because a session fact settles nothing.
func (r *registry) appendEdgeEvent(seq uint64, raw []byte) error {
	if r.db == nil {
		return errNoEdgeDB
	}
	_, err := r.db.Exec(
		`INSERT INTO edge_events (device_seq, event, created_at) VALUES (?, ?, ?)`,
		int64(seq), raw, time.Now().UTC().Format(time.RFC3339Nano))
	return err
}

// edgeAgentSession is the device's binding for one cloud-started
// session: the identity it minted, and the window that identity means.
type edgeAgentSession struct {
	SessionID   string
	CommandID   string
	Workspace   string
	RookSession string
	Profile     string
	Fence       uint64
	Kind        string // last kind reported; "" = the cloud has not been told it started
	// Released: the run let go of this session (§6.6 compensation). The
	// window may well still be running — what ended is the device's
	// obligation to narrate it, not the agent.
	Released bool
}

// releaseEdgeSession records that the run has let go. Converges: a hold
// released twice is released.
func (r *registry) releaseEdgeSession(sessionID string) error {
	if r.db == nil {
		return errNoEdgeDB
	}
	_, err := r.db.Exec(
		`UPDATE edge_sessions SET released_at = ? WHERE session_id = ? AND released_at IS NULL`,
		time.Now().UTC().Format(time.RFC3339Nano), sessionID)
	return err
}

// claimEdgeSession records the identity BEFORE the window exists.
// Returns false when the identity is already claimed — the caller's cue
// that this start command is a redelivery and must not spawn again.
func (r *registry) claimEdgeSession(s edgeAgentSession) (bool, error) {
	if r.db == nil {
		return false, errNoEdgeDB
	}
	res, err := r.db.Exec(
		`INSERT OR IGNORE INTO edge_sessions
		   (session_id, command_id, workspace, profile, fence, started_at)
		 VALUES (?, ?, ?, ?, ?, ?)`,
		s.SessionID, s.CommandID, s.Workspace, s.Profile, int64(s.Fence),
		time.Now().UTC().Format(time.RFC3339Nano))
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// dropEdgeSession gives an identity back. Only one caller may use it, and
// only in one situation: the spawn failed IN PROCESS, so the device knows
// no window was started and the claim is protecting nothing. A claim left
// standing there would make the command id unusable forever and tell the
// next delivery a story about a restart that never happened.
//
// A claim orphaned by an actual crash is NOT this case — nobody is left
// to know whether a window came up — and it keeps the row.
func (r *registry) dropEdgeSession(sessionID string) error {
	if r.db == nil {
		return errNoEdgeDB
	}
	_, err := r.db.Exec(
		`DELETE FROM edge_sessions WHERE session_id = ? AND rook_session = ''`, sessionID)
	return err
}

// bindEdgeSession names the window the identity got. Separate from the
// claim on purpose: between the two there is a spawn that can fail or be
// interrupted, and the gap is exactly what the reconciler reads.
func (r *registry) bindEdgeSession(sessionID, rookSession string) error {
	if r.db == nil {
		return errNoEdgeDB
	}
	_, err := r.db.Exec(
		`UPDATE edge_sessions SET rook_session = ? WHERE session_id = ?`, rookSession, sessionID)
	return err
}

func scanEdgeSession(row *sql.Row) (*edgeAgentSession, error) {
	var s edgeAgentSession
	var fence int64
	var released sql.NullString
	err := row.Scan(&s.SessionID, &s.CommandID, &s.Workspace, &s.RookSession,
		&s.Profile, &fence, &s.Kind, &released)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	s.Fence, s.Released = uint64(max(fence, 0)), released.Valid
	return &s, nil
}

const edgeSessionCols = `session_id, command_id, workspace, rook_session, profile, fence, kind, released_at`

// edgeSession looks a binding up by the identity the cloud knows.
func (r *registry) edgeSession(sessionID string) (*edgeAgentSession, error) {
	if r.db == nil {
		return nil, errNoEdgeDB
	}
	return scanEdgeSession(r.db.QueryRow(
		`SELECT `+edgeSessionCols+` FROM edge_sessions WHERE session_id = ?`, sessionID))
}

// edgeSessionForWindow looks a binding up by the window — the direction
// the sensors need, since what they observe is a rook session.
func (r *registry) edgeSessionForWindow(rookSession string) (*edgeAgentSession, error) {
	if r.db == nil || rookSession == "" {
		return nil, nil
	}
	return scanEdgeSession(r.db.QueryRow(
		`SELECT `+edgeSessionCols+` FROM edge_sessions WHERE rook_session = ?`, rookSession))
}

// reportEdgeSessionKind records the kind about to be reported, and says
// whether it is news. A state the cloud already holds is not: without
// this every assistant record would mint a "progress" event, and the
// run's history would fill with facts no step can act on.
//
// The compare-and-set is one statement so two sensors observing the same
// transition cannot both call it news.
func (r *registry) reportEdgeSessionKind(sessionID, kind string) (bool, error) {
	if r.db == nil {
		return false, errNoEdgeDB
	}
	res, err := r.db.Exec(
		`UPDATE edge_sessions SET kind = ? WHERE session_id = ? AND kind != ?`,
		kind, sessionID, kind)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// claimEdgeArtifact records that this device is about to declare an
// artifact. Returns false when the declaration already crossed — the
// caller's cue to re-report the receipt and say nothing new. The id is
// content-addressed, so "already declared" and "identical bytes" are the
// same statement.
func (r *registry) claimEdgeArtifact(artifactID, sessionID, commandID string) (bool, error) {
	if r.db == nil {
		return false, errNoEdgeDB
	}
	res, err := r.db.Exec(
		`INSERT OR IGNORE INTO edge_artifacts (artifact_id, session_id, command_id, declared_at)
		 VALUES (?, ?, ?, ?)`,
		artifactID, sessionID, commandID, time.Now().UTC().Format(time.RFC3339Nano))
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// announceEdgeSession flips a claimed session to announced exactly once
// — the started event's own gate. Until it succeeds no other fact about
// this session may be reported, because the cloud refuses events about a
// session no receipt introduced.
func (r *registry) announceEdgeSession(sessionID string) (bool, error) {
	if r.db == nil {
		return false, errNoEdgeDB
	}
	res, err := r.db.Exec(
		`UPDATE edge_sessions SET kind = 'started' WHERE session_id = ? AND kind = ''`, sessionID)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
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

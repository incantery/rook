package host

import (
	"errors"
	"log"
	"time"
)

// errNoDB: the registry runs without persistence when the data dir is
// unavailable — workspaces degrade gracefully, but the decisions ledger
// cannot (drafts without rows would be unauditable).
var errNoDB = errors.New("decisions unavailable: registry has no database")

// Decision is one drafter judgment on one ask — the agent's ledger
// (docs/agent.md). Every row is written by the host, mechanically: the
// agent proposes over HTTP, the user (or their manual reply) closes it.
// Verdict counts are the dogfood metric that eventually earns autoreply.
type Decision struct {
	ID           int64      `json:"id"`
	AgentSession string     `json:"agentSession"`
	AskSeq       int        `json:"askSeq"`
	Workspace    string     `json:"workspace,omitempty"`
	RookSession  string     `json:"rookSession,omitempty"`
	CWD          string     `json:"cwd,omitempty"`
	Ask          string     `json:"ask"`
	Action       string     `json:"action"` // draft | escalate
	Draft        string     `json:"draft,omitempty"`
	// Reason is nano's own why, verbatim — what makes an escalation legible
	// ("touches release signing") and a draft auditable.
	Reason       string     `json:"reason,omitempty"`
	Confidence   float64    `json:"confidence,omitempty"`
	Model        string     `json:"model,omitempty"`
	InputTokens  int64      `json:"inputTokens,omitempty"`
	OutputTokens int64      `json:"outputTokens,omitempty"`
	CachedTokens int64      `json:"cachedTokens,omitempty"`
	CostUSD      float64    `json:"costUsd,omitempty"`
	Verdict      string     `json:"verdict"` // open|approved|edited|rejected|manual|stale|auto
	FinalText    string     `json:"finalText,omitempty"`
	CreatedAt    time.Time  `json:"createdAt"`
	DecidedAt    *time.Time `json:"decidedAt,omitempty"`
}

// insertDecision writes a new open row; the UNIQUE(agent_session, ask_seq)
// constraint is the idempotence guard — a second draft for the same ask is
// an error the handler turns into 409.
func (r *registry) insertDecision(d *Decision) (int64, error) {
	if r.db == nil {
		return 0, errNoDB
	}
	res, err := r.db.Exec(
		`INSERT INTO decisions (agent_session, ask_seq, workspace, rook_session, cwd, ask, action,
		   draft, reason, confidence, model, input_tokens, output_tokens, cached_tokens, cost_usd, verdict, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', ?)`,
		d.AgentSession, d.AskSeq, d.Workspace, d.RookSession, d.CWD, d.Ask, d.Action,
		d.Draft, d.Reason, d.Confidence, d.Model, d.InputTokens, d.OutputTokens, d.CachedTokens, d.CostUSD,
		time.Now().Format(time.RFC3339Nano),
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// decideDraft closes an open row. Returns false when the row wasn't open —
// the caller's 409, and the guard against double-deciding (approve racing
// the transcript echo of its own pty write).
func (r *registry) decideDraft(id int64, verdict, finalText string) bool {
	if r.db == nil {
		return false
	}
	res, err := r.db.Exec(
		`UPDATE decisions SET verdict = ?, final_text = ?, decided_at = ? WHERE id = ? AND verdict = 'open'`,
		verdict, finalText, time.Now().Format(time.RFC3339Nano), id)
	if err != nil {
		log.Printf("decisions: decide %d: %v", id, err)
		return false
	}
	n, _ := res.RowsAffected()
	return n == 1
}

const decisionCols = `id, agent_session, ask_seq, workspace, rook_session, cwd, ask, action,
	COALESCE(draft,''), COALESCE(reason,''), COALESCE(confidence,0), COALESCE(model,''),
	COALESCE(input_tokens,0), COALESCE(output_tokens,0), COALESCE(cached_tokens,0), COALESCE(cost_usd,0),
	verdict, COALESCE(final_text,''), created_at, COALESCE(decided_at,'')`

func scanDecision(row interface{ Scan(...any) error }) (*Decision, error) {
	var d Decision
	var created, decided string
	if err := row.Scan(&d.ID, &d.AgentSession, &d.AskSeq, &d.Workspace, &d.RookSession, &d.CWD,
		&d.Ask, &d.Action, &d.Draft, &d.Reason, &d.Confidence, &d.Model,
		&d.InputTokens, &d.OutputTokens, &d.CachedTokens, &d.CostUSD,
		&d.Verdict, &d.FinalText, &created, &decided); err != nil {
		return nil, err
	}
	d.CreatedAt, _ = time.Parse(time.RFC3339Nano, created)
	if decided != "" {
		if t, err := time.Parse(time.RFC3339Nano, decided); err == nil {
			d.DecidedAt = &t
		}
	}
	return &d, nil
}

func (r *registry) getDecision(id int64) *Decision {
	if r.db == nil {
		return nil
	}
	d, err := scanDecision(r.db.QueryRow(`SELECT `+decisionCols+` FROM decisions WHERE id = ?`, id))
	if err != nil {
		return nil
	}
	return d
}

// openDecisionFor is the manual-attribution lookup: the newest open row for
// a transcript session (there is at most one per ask, but a session can in
// principle have several asks' rows if staling raced).
func (r *registry) openDecisionFor(agentSession string) *Decision {
	if r.db == nil {
		return nil
	}
	d, err := scanDecision(r.db.QueryRow(
		`SELECT `+decisionCols+` FROM decisions WHERE agent_session = ? AND verdict = 'open'
		 ORDER BY ask_seq DESC LIMIT 1`, agentSession))
	if err != nil {
		return nil
	}
	return d
}

// markStale expires open rows for asks older than the current one — a new
// turn_completed means those questions are gone; their drafts must not be
// approvable anymore.
func (r *registry) markStale(agentSession string, beforeSeq int) {
	if r.db == nil {
		return
	}
	if _, err := r.db.Exec(
		`UPDATE decisions SET verdict = 'stale', decided_at = ? WHERE agent_session = ? AND verdict = 'open' AND ask_seq < ?`,
		time.Now().Format(time.RFC3339Nano), agentSession, beforeSeq); err != nil {
		log.Printf("decisions: stale %s: %v", agentSession, err)
	}
}

// spendSince sums what the drafter has cost since t — the budget guard's
// source of truth (the agent asks the host; it never keeps its own books).
func (r *registry) spendSince(t time.Time) (usd float64, calls int) {
	if r.db == nil {
		return 0, 0
	}
	err := r.db.QueryRow(
		`SELECT COALESCE(SUM(cost_usd),0), COUNT(*) FROM decisions WHERE created_at >= ?`,
		t.Format(time.RFC3339Nano)).Scan(&usd, &calls)
	if err != nil {
		log.Printf("decisions: spend: %v", err)
	}
	return usd, calls
}

func (r *registry) listDecisions(since time.Time, limit int) []*Decision {
	if r.db == nil {
		return nil
	}
	if limit <= 0 {
		limit = 500
	}
	rows, err := r.db.Query(
		`SELECT `+decisionCols+` FROM decisions WHERE created_at >= ? ORDER BY id DESC LIMIT ?`,
		since.Format(time.RFC3339Nano), limit)
	if err != nil {
		log.Printf("decisions: list: %v", err)
		return nil
	}
	defer rows.Close()
	var out []*Decision
	for rows.Next() {
		if d, err := scanDecision(rows); err == nil {
			out = append(out, d)
		}
	}
	return out
}

package agent

import (
	"context"
	"fmt"
	"log"
	"strings"
	"time"
)

// The preference pass (docs/agent.md step 2): every approve/edit/reject in
// the decisions ledger is training data. Nano reads the verdicts since the
// cursor, extracts durable preferences, and appends them to the visible
// store — which the drafter's SystemPrompt already injects. Extraction is
// easy; the store's semantics are the design (see prefs.go).

const extractRubric = `You maintain a preference file for the Rook Agent, a small assistant
that drafts replies to a developer's "claude" coding sessions. You will see
the current preference file and a batch of recent interactions. Each
interaction is one question a session asked, what the agent proposed
(a drafted reply, or an escalation to the user), and the user's verdict:

- approved: the user sent the draft unchanged
- edited: the user rewrote the draft before sending; "sent" is their text
- rejected: the user declined the draft
- manual: the agent escalated or the user ignored the draft; "sent" is
  what they typed themselves

Extract durable, generalizable preferences that would improve future
drafts. Rules:
- Only patterns the interactions actually support. One interaction is
  rarely enough; an edit that clearly changes tone or adds a standing
  requirement can be.
- Never restate anything already in the preference file, even reworded.
- Each preference is one short imperative line: "prefer running tests
  before approving commits", "never approve force-pushes".
- No secrets, no one-off facts, no session-specific trivia.
- An empty list is the normal outcome. At most 3 lines.`

// extractPrompt renders the volatile half: the store as it stands, then the
// verdicts under consideration.
func extractPrompt(prefs string, rows []DecisionRow) string {
	var b strings.Builder
	b.WriteString("Current preference file:\n")
	if strings.TrimSpace(prefs) == "" {
		b.WriteString("(empty)\n")
	} else {
		b.WriteString(prefs)
		if !strings.HasSuffix(prefs, "\n") {
			b.WriteByte('\n')
		}
	}
	b.WriteString("\nInteractions (oldest first):\n")
	for _, r := range rows {
		fmt.Fprintf(&b, "[#%d %s] asked: %s\n", r.ID, r.Verdict, oneline(r.Ask))
		switch {
		case r.Action == "escalate":
			b.WriteString("  agent escalated (no draft)\n")
		case r.Draft != "":
			fmt.Fprintf(&b, "  agent drafted: %s\n", oneline(r.Draft))
		}
		if r.FinalText != "" && r.FinalText != r.Draft {
			fmt.Fprintf(&b, "  user sent: %s\n", oneline(r.FinalText))
		}
	}
	b.WriteString("\nExtract preferences (empty list if none).")
	return b.String()
}

func oneline(s string) string {
	return truncate(strings.Join(strings.Fields(s), " "), 200)
}

// extract runs one preference pass: ledger rows past the cursor in, learned
// lines out, cursor forward. Single-flight; errors leave the cursor alone
// so the rows are retried next tick.
func (a *Agent) extract(ctx context.Context) {
	a.mu.Lock()
	if a.extracting {
		a.mu.Unlock()
		return
	}
	a.extracting = true
	a.mu.Unlock()
	defer func() {
		a.mu.Lock()
		a.extracting = false
		a.mu.Unlock()
	}()

	cursor := loadCursor()
	all, err := a.Host.Decisions(time.Now().Add(-7 * 24 * time.Hour))
	if err != nil {
		return
	}
	var rows []DecisionRow
	maxID := cursor
	for i := len(all) - 1; i >= 0; i-- { // host returns newest first
		r := all[i]
		if r.ID <= cursor {
			continue
		}
		switch r.Verdict {
		case "approved", "edited", "rejected", "manual":
			rows = append(rows, r)
			maxID = max(maxID, r.ID)
		}
	}
	if len(rows) == 0 {
		return
	}

	// Same purse as the drafter — a blown budget stops learning too.
	if sp, err := a.Host.Spend(); err != nil || (a.DailyCapUSD > 0 && sp.TodayUSD >= a.DailyCapUSD) {
		return
	}

	prefs := LoadPreferences()
	callCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	e, u, err := a.AI.Extract(callCtx, extractRubric, extractPrompt(prefs, rows))
	if err != nil {
		log.Printf("extract: %v", err)
		return
	}
	// Extraction spend is not in the host's ledger yet (no ask to hang the
	// row on) — logged here so the cost stays visible.
	var fresh []string
	for _, p := range e.Preferences {
		p = strings.TrimSpace(p)
		if p == "" || hasPreference(prefs, p) || len(fresh) >= 3 {
			continue
		}
		fresh = append(fresh, p)
	}
	if err := AppendLearned(fresh); err != nil {
		log.Printf("extract: append: %v", err)
		return // cursor stays — retry these rows next pass
	}
	if err := saveCursor(maxID); err != nil {
		log.Printf("extract: cursor: %v", err)
	}
	log.Printf("extract: %d verdicts → %d new preferences ($%.5f)", len(rows), len(fresh), u.CostUSD)
}

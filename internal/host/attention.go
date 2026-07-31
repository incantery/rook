package host

import (
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"time"
)

// This file is the attention list: every claude session waiting on a human,
// across workspaces, plus the transcript→window correlation that makes an
// item actionable. It is mechanical — a sensor reduction, no LLM anywhere.
//
// It used to also hold the drafter's host half (the /context read, the
// draft/approve/reject flow, the decisions ledger). That was an instance:
// one particular producer of "this needs a human" with one particular
// judgment model behind it. The mechanism it leaves behind is the item
// below and the verb a plugin will call to raise one — see
// docs/plugins/VOCABULARY.md. rook-agent and the ledger left in the strip.

// attentionItem is one "a claude session is waiting on you" row, workspace-
// agnostic: the inbox, the titlebar chip, and notifications consume this
// shape.
type attentionItem struct {
	Workspace    string    `json:"workspace"`
	RookSession  string    `json:"rookSession"`
	Window       int       `json:"window"` // index in the workspace's strip order
	AgentSession string    `json:"agentSession"`
	AskSeq       int       `json:"askSeq"`
	State        string    `json:"state"`
	Title        string    `json:"title,omitempty"`
	Ask          string    `json:"ask,omitempty"`
	Interactive  bool      `json:"interactive,omitempty"` // TUI picker: jump, don't type
	Since        time.Time `json:"since"`
}

// GET /attention — every session waiting on the user, across workspaces.
func (h *Host) handleAttention(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	writeJSON(w, h.attention())
}

func (h *Host) attention() []attentionItem {
	h.mu.Lock()
	names := make(map[string]bool)
	for _, s := range h.sessions {
		names[s.info.Workspace] = true
	}
	h.mu.Unlock()

	items := make([]attentionItem, 0, 4)
	for name := range names {
		st := h.statusFor(name, false)
		for i, s := range st.Sessions {
			if s.Agent == nil || s.Agent.State != "needs_input" {
				continue
			}
			items = append(items, attentionItem{
				Workspace:    name,
				RookSession:  s.ID,
				Window:       i,
				AgentSession: s.Agent.SessionID,
				AskSeq:       s.Agent.AskSeq,
				State:        s.Agent.State,
				Title:        s.Agent.Title,
				Ask:          s.Agent.Ask,
				Interactive:  s.Agent.Interactive,
				Since:        s.Agent.Since,
			})
		}
	}
	// oldest waiting first — the thing you've kept waiting longest leads
	sort.Slice(items, func(i, j int) bool { return items[i].Since.Before(items[j].Since) })
	return items
}

// handleAgent routes /agents/{id}/transcript (GET) and /agents/{id}/notify
// (POST) — {id} is the transcript session id.
func (h *Host) handleAgent(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/agents/")
	id, action, _ := strings.Cut(rest, "/")
	if id == "" {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	switch {
	case action == "transcript" && r.Method == http.MethodGet:
		h.handleAgentTranscript(w, r, id)
	case action == "notify" && r.Method == http.MethodPost:
		// Claude Code's Notification hook, relayed by `rookctl
		// notify-hook` — the permission-prompt sensor.
		var req struct{ Message string }
		json.NewDecoder(r.Body).Decode(&req)
		if req.Message == "" {
			req.Message = "Claude is waiting on you"
		}
		h.aw.notify(id, req.Message)
		w.WriteHeader(http.StatusNoContent)
	default:
		http.Error(w, "not found", http.StatusNotFound)
	}
}

// shellQuote single-quotes s for a POSIX shell (the only escape needed
// inside single quotes is the quote itself).
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// pairedSession resolves a transcript session to its rook window: claims
// first, then sticky binds. With correlateNow, a full correlation pass runs
// over every live workspace first, so ring-content evidence gets a chance
// to bind before we give up.
func (h *Host) pairedSession(agentSession string, correlateNow bool) *session {
	lookup := func() *session {
		h.bindMu.Lock()
		defer h.bindMu.Unlock()
		if id := h.claims[agentSession]; id != "" {
			s := h.get(id)
			// A claim whose agent died without unclaiming names a window
			// running something else; acting on it would touch whatever
			// that is. Fall through to the heuristic tier rather than
			// actuate on a claim we can prove is stale.
			if s != nil && h.claimAliveLocked(agentSession, s) {
				return s
			}
		}
		if id := h.binds[agentSession]; id != "" {
			return h.get(id)
		}
		return nil
	}
	if s := lookup(); s != nil {
		return s
	}
	if !correlateNow {
		return nil
	}
	h.mu.Lock()
	names := make(map[string]bool)
	for _, s := range h.sessions {
		names[s.info.Workspace] = true
	}
	h.mu.Unlock()
	for name := range names {
		h.statusFor(name, false) // correlate() side effect: may bind
	}
	return lookup()
}

package host

import (
	"encoding/json"
	"net/http"
	"strings"
)

// This file is what survived the drafter and the inbox: the agent API's
// routing, and the transcript→window correlation every actuator needs
// before it touches a pty.
//
// It held the drafter's host half (the /context read, the
// draft/approve/reject flow, the decisions ledger), then the attention
// list. Both were instances — one particular producer of "this needs a
// human", and one particular consumer of it, each wired to exactly one
// source. What replaces them is a verb: attention.raise, which any plugin
// may call, with core ranking and rendering what it collects. See
// docs/plugins/VOCABULARY.md. Until that lands there is no inbox, and
// that is the deliberate shape of the gap, not an oversight.

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

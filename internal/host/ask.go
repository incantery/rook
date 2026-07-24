// The ask request: `rookctl ask` (and the MCP `ask` tool behind it) asking
// the HUMAN a question through the app — the RUI counterpart of edit.go's
// pane takeover. Where an edit takes over the asking pane, an ask opens a
// split BESIDE it: the agent keeps its window, the question gets its own.
//
// Flow: rookctl POSTs /sessions/{id}/ask {questions} → the host registers a
// pending ask and pushes a msgAsk onto the session's frame socket. The app
// acks on receipt, renders the form, and posts the answer JSON when the
// human decides (or dismisses). rookctl long-polls GET /asks/{id} until
// done, prints the answer to stdout, and exits 0 (answered) or 1
// (dismissed). An old app ignores the unknown frame kind (fail open), which
// rookctl surfaces as a no-ack timeout, not a hang.
//
// The questions payload is deliberately opaque to the host: it validates
// shape at the edges (the CLI and the form) and carries bytes in between,
// so the form can grow fields without a daemon release.
package host

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// askState is one pending ask's lifecycle. Guarded by Host.askMu.
type askState struct {
	session string
	acked   bool
	done    bool
	// the answer JSON the app posted — {"canceled":true} for a dismissal
	answer json.RawMessage
	// the msgAsk frame, kept so a fresh attach can re-push a pending ask:
	// the blocked rookctl outlives a UI reload, so its question must too
	frame []byte
	// closed when done flips — the wait endpoint parks on it
	doneCh  chan struct{}
	created time.Time
}

// askPayload is the msgAsk frame body, JSON: the ask id plus the questions
// exactly as the asker sent them.
type askPayload struct {
	ID        string          `json:"id"`
	Questions json.RawMessage `json:"questions"`
}

// handleSessionAsk is POST /sessions/{id}/ask — create a pending ask and
// push it to the attached app. 409 when no app is attached: a question
// needs a screen to land on.
func (h *Host) handleSessionAsk(w http.ResponseWriter, r *http.Request, s *session) {
	var req struct {
		Questions json.RawMessage `json:"questions"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || len(req.Questions) == 0 {
		http.Error(w, "questions required", http.StatusBadRequest)
		return
	}

	idb := make([]byte, 8)
	rand.Read(idb)
	payload := askPayload{ID: hex.EncodeToString(idb), Questions: req.Questions}

	body, _ := json.Marshal(payload)
	msg := append([]byte{msgAsk}, body...)

	s.mu.Lock()
	oob := s.oob
	s.mu.Unlock()
	if oob == nil {
		http.Error(w, "no app attached to this session — is the rook window open?", http.StatusConflict)
		return
	}

	h.askMu.Lock()
	if h.asks == nil {
		h.asks = map[string]*askState{}
	}
	// lazy sweep: an abandoned ask (rookctl ^C'd, app gone) shouldn't
	// accumulate forever
	for id, a := range h.asks {
		if time.Since(a.created) > 24*time.Hour {
			delete(h.asks, id)
		}
	}
	h.asks[payload.ID] = &askState{
		session: s.info.ID,
		frame:   msg,
		doneCh:  make(chan struct{}),
		created: time.Now(),
	}
	h.askMu.Unlock()

	select {
	case oob <- msg:
	default:
		h.askMu.Lock()
		delete(h.asks, payload.ID)
		h.askMu.Unlock()
		http.Error(w, "app not keeping up — try again", http.StatusConflict)
		return
	}
	writeJSON(w, map[string]string{"askId": payload.ID})
}

// pendingAskFrames returns the msgAsk frames of this session's undecided
// asks — handleAttachFramed re-pushes them on every fresh attach, so a UI
// reload re-renders the question instead of leaving the asker parked
// against a pane that no longer exists. The app dedupes by ask id.
func (h *Host) pendingAskFrames(sessionID string) [][]byte {
	h.askMu.Lock()
	defer h.askMu.Unlock()
	var out [][]byte
	for _, a := range h.asks {
		if a.session == sessionID && !a.done {
			out = append(out, a.frame)
		}
	}
	return out
}

// handleAsks routes /asks/{id} (GET, ?wait=seconds long-poll),
// /asks/{id}/ack (POST, from the app) and /asks/{id}/answer (POST, from
// the app, body = the answer JSON verbatim).
func (h *Host) handleAsks(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/asks/")
	id, action, _ := strings.Cut(rest, "/")

	h.askMu.Lock()
	a := h.asks[id]
	h.askMu.Unlock()
	if a == nil {
		http.Error(w, "no such ask: "+id, http.StatusNotFound)
		return
	}

	switch {
	case action == "" && r.Method == http.MethodGet:
		if secs, _ := strconv.Atoi(r.URL.Query().Get("wait")); secs > 0 {
			h.askMu.Lock()
			done := a.done
			h.askMu.Unlock()
			if !done {
				select {
				case <-a.doneCh:
				case <-time.After(time.Duration(min(secs, 60)) * time.Second):
				case <-r.Context().Done():
					return
				}
			}
		}
		h.askMu.Lock()
		out := map[string]any{"acked": a.acked, "done": a.done}
		if a.done {
			out["answer"] = a.answer
			// single waiter: the poll that observes done also retires the entry
			delete(h.asks, id)
		}
		h.askMu.Unlock()
		writeJSON(w, out)
	case action == "ack" && r.Method == http.MethodPost:
		h.askMu.Lock()
		a.acked = true
		h.askMu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	case action == "answer" && r.Method == http.MethodPost:
		var answer json.RawMessage
		if err := json.NewDecoder(r.Body).Decode(&answer); err != nil || len(answer) == 0 {
			http.Error(w, "answer JSON required", http.StatusBadRequest)
			return
		}
		h.askMu.Lock()
		if !a.done {
			a.done, a.acked, a.answer = true, true, answer
			close(a.doneCh)
		}
		h.askMu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	default:
		http.Error(w, "not found", http.StatusNotFound)
	}
}

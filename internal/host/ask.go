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
	"sort"
	"strconv"
	"strings"
	"time"
)

// askState is one pending ask's lifecycle. Guarded by Host.askMu.
type askState struct {
	session string
	acked   bool
	done    bool
	// async ask (the MCP tool): nobody long-polls it — on answer, ring the
	// doorbell at the asking session and hold the answer for the drain
	// endpoint. Blocking asks (the rookctl ask CLI) are owned by their
	// long-poll and the drain never touches them.
	notify bool
	// escalated: this ask also reached the configured rook-server, so a
	// local decision has to retract it (relay.go). False when there is no
	// remote, or when the publish failed — either way nothing to withdraw.
	escalated bool
	// the answer JSON the app posted — {"canceled":true} for a dismissal
	answer json.RawMessage
	// the msgAsk frame, kept so a fresh attach can re-push a pending ask:
	// the blocked rookctl outlives a UI reload, so its question must too
	frame []byte
	// the questions themselves, for the session-LESS queue: a polling app
	// has no frame to be re-pushed, so GET /asks serves these directly.
	questions json.RawMessage
	// where the ask came from. A session-scoped ask derives provenance
	// from its session; a queued one has none, so the asker carries its
	// cwd and the app resolves the rest (which workspace contains it,
	// which pane is sitting in it) from that one fact.
	cwd string
	// the doorbell was due and could not ring — no live claude claim owned
	// the window at settle time. The answer is sitting in the drain with
	// nobody who knows to read it, so the next claim on this session rings
	// it (see ringOwedDoorbells).
	doorbellOwed bool
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
		Notify    bool            `json:"notify"`
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
	st := &askState{
		session: s.info.ID,
		notify:  req.Notify,
		frame:   msg,
		doneCh:  make(chan struct{}),
		created: time.Now(),
	}
	h.asks[payload.ID] = st
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
	// …and to whatever screen the human is actually near. Unconditional:
	// there is no gesture to make before walking away, which is the point.
	h.escalate(st, payload.ID, req.Questions)
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

// askDoorbell types a one-line pointer at the asking session's pty — the
// automated "I've left comments on the file". Only when a live claude
// claim holds that window: at a bare shell the line would run as a
// command, so a dead claim means the answer just waits in the drain.
// One line, no embedded newline — same delivery rule as the thread nudge.
//
// Reports whether it actually rang. A false here is the quiet failure mode
// that used to strand an answer forever: the human decided, the agent was
// between lives, and nothing ever told the next one to look.
func (h *Host) askDoorbell(sessionID, askID string) bool {
	s := h.get(sessionID)
	if s == nil {
		return false
	}
	h.bindMu.Lock()
	alive := false
	for tid, sid := range h.claims {
		if sid == sessionID && h.claimAliveLocked(tid, s) {
			alive = true
			break
		}
	}
	h.bindMu.Unlock()
	if !alive {
		return false
	}
	h.typeLine(s, "rook ask "+askID+" answered — collect it with the rook answers tool")
	return true
}

// ringOwedDoorbells delivers the pointers that had nobody to point at.
// Called when a claude session claims this window (host.go's claim
// handler): a fresh agent in the window the question came from is exactly
// who the answer was for. It is the same line, so the new agent does what
// the old one would have — call the answers tool, which still holds the
// decision because the drain is read-once and nobody read it.
//
// Deliberately not a ticker: the trigger is a claim, and a claim is the
// only evidence that typing at this pty is safe.
func (h *Host) ringOwedDoorbells(sessionID string) {
	h.askMu.Lock()
	var owed []string
	for id, a := range h.asks {
		if a.session == sessionID && a.done && a.doorbellOwed {
			owed = append(owed, id)
		}
	}
	h.askMu.Unlock()

	for _, id := range owed {
		if !h.askDoorbell(sessionID, id) {
			return // still nobody home; the next claim tries again
		}
		h.askMu.Lock()
		if a := h.asks[id]; a != nil {
			a.doorbellOwed = false
		}
		h.askMu.Unlock()
	}
}

// typeLine is the pty write behind the doorbell — a seam so tests can
// observe a delivery without a tty (nil typeLineFn = the real thing).
func (h *Host) typeLine(s *session, line string) {
	if h.typeLineFn != nil {
		h.typeLineFn(s, line)
		return
	}
	typeLineAt(s, line)
}

// typeLineAt delivers one line to an agent's TUI as TYPED input: the text,
// a beat, then Enter as its own write. Text and \r in a single burst read
// as a PASTE to claude code's heuristic — the newline lands in the input
// box as a literal newline and nothing submits (found live, 07-24). The
// gap makes the \r a keypress.
func typeLineAt(s *session, line string) {
	if _, err := s.pty.Write([]byte(line)); err != nil {
		return
	}
	time.Sleep(150 * time.Millisecond)
	s.pty.Write([]byte("\r"))
}

// handleSessionAsks is GET /sessions/{id}/asks — the drain the MCP answers
// tool reads: every DECIDED async ask for this session (consumed by the
// read), plus the ids still waiting. Blocking asks belong to their
// long-poll and are invisible here.
func (h *Host) handleSessionAsks(w http.ResponseWriter, s *session) {
	type answered struct {
		AskID  string          `json:"askId"`
		Answer json.RawMessage `json:"answer"`
	}
	out := struct {
		Answered []answered `json:"answered"`
		Pending  []string   `json:"pending"`
	}{Answered: []answered{}, Pending: []string{}}
	h.askMu.Lock()
	for id, a := range h.asks {
		if a.session != s.info.ID || !a.notify {
			continue
		}
		if a.done {
			out.Answered = append(out.Answered, answered{AskID: id, Answer: a.answer})
			delete(h.asks, id)
		} else {
			out.Pending = append(out.Pending, id)
		}
	}
	h.askMu.Unlock()
	writeJSON(w, out)
}

// Where a decision came from. It matters for exactly one thing: an answer
// that arrived THROUGH the relay was already consumed by the drain, so
// retracting it would be a pointless round trip.
type settleSource int

const (
	sourceApp settleSource = iota // the pane in this rook, via POST /asks/{id}/answer
	sourceRelay
)

type settleResult int

const (
	settledOK      settleResult = iota
	settledAlready              // someone else got there first
	settledUnknown              // no such ask — swept, drained, or a host restart
)

// settleAsk is the ONE place an ask becomes decided, whichever surface
// decided it. A phone answer and a desk answer are the same event: same
// waiter woken, same doorbell typed, same stand-down pushed to every
// attached screen. Two paths here would drift within a week.
func (h *Host) settleAsk(id string, answer json.RawMessage, src settleSource) settleResult {
	h.askMu.Lock()
	a := h.asks[id]
	if a == nil {
		h.askMu.Unlock()
		return settledUnknown
	}
	if a.done {
		h.askMu.Unlock()
		return settledAlready
	}
	a.done, a.acked, a.answer = true, true, answer
	ring, session, escalated := a.notify, a.session, a.escalated
	close(a.doneCh)
	h.askMu.Unlock()

	// the form stands down wherever it is rendered — the human may have
	// decided this on a screen in another room
	h.pushAskDone(session, id)
	if escalated && src != sourceRelay {
		h.withdraw(id) // answered at the desk; the card leaves the phone
	}
	if ring {
		// off the request path: the pty write can stall on a wedged tty
		go func() {
			if h.askDoorbell(session, id) {
				return
			}
			// nobody to tell yet — the answer waits in the drain and the
			// next claim on this window rings it
			h.askMu.Lock()
			if a := h.asks[id]; a != nil {
				a.doorbellOwed = true
			}
			h.askMu.Unlock()
		}()
	}
	return settledOK
}

// pushAskDone tells the attached app that an ask is over. Best effort: an
// app that isn't listening will settle its own pane the moment it tries to
// answer and learns the question is gone.
func (h *Host) pushAskDone(sessionID, askID string) {
	s := h.get(sessionID)
	if s == nil {
		return
	}
	body, err := json.Marshal(map[string]string{"id": askID})
	if err != nil {
		return
	}
	s.mu.Lock()
	oob := s.oob
	s.mu.Unlock()
	if oob == nil {
		return
	}
	select {
	case oob <- append([]byte{msgAskDone}, body...):
	default:
	}
}

// handleAsks routes /asks/{id} (GET, ?wait=seconds long-poll),
// /asks/{id}/ack (POST, from the app) and /asks/{id}/answer (POST, from
// the app, body = the answer JSON verbatim).
// handleAskQueue is the session-less ask path: POST /asks to create one,
// GET /asks to list what is pending.
//
// The original flow pushes a msgAsk onto the asking session's frame socket
// and 409s when nothing is attached — "a question needs a screen to land
// on". That assumes the app holds a wire-v3 session socket, which the zig
// app deliberately does not: it owns its ptys in-process, so it registers
// no sessions and $ROOK_SESSION is unset in its shells. Both halves of the
// old path are therefore unreachable from it.
//
// So: an ask with no session is queued rather than pushed, and the app
// polls for it the same way it polls /attention and /usage. The tradeoff is
// that such an ask is app-global rather than pane-scoped — with one window
// that is invisible, and a second window is the moment to revisit it.
//
// Session-scoped asks are untouched: they still push, still 409 without a
// screen, and the drain still ignores blocking ones.
func (h *Host) handleAskQueue(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		h.askMu.Lock()
		type pending struct {
			ID        string          `json:"id"`
			Questions json.RawMessage `json:"questions"`
			Cwd       string          `json:"cwd,omitempty"`
			Session   string          `json:"session,omitempty"`
		}
		out := make([]pending, 0, len(h.asks))
		for id, a := range h.asks {
			if a.done {
				continue
			}
			// Session-scoped asks were already delivered over their
			// socket; listing them here would double-render them in an
			// app that holds both paths.
			if a.session != "" {
				continue
			}
			out = append(out, pending{ID: id, Questions: a.questions, Cwd: a.cwd})
		}
		h.askMu.Unlock()
		// Oldest first is the /attention rule and the right one here too:
		// the thing you have kept waiting longest leads.
		sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
		writeJSON(w, out)

	case http.MethodPost:
		var req struct {
			Questions json.RawMessage `json:"questions"`
			Notify    bool            `json:"notify"`
			// Optional provenance: the directory the asker was in. The
			// app resolves workspace and pane from it — one fact the
			// asker always knows, rather than an identity it may not.
			Cwd string `json:"cwd"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || len(req.Questions) == 0 {
			http.Error(w, "questions required", http.StatusBadRequest)
			return
		}
		idb := make([]byte, 8)
		rand.Read(idb)
		id := hex.EncodeToString(idb)

		h.askMu.Lock()
		if h.asks == nil {
			h.asks = map[string]*askState{}
		}
		for old, a := range h.asks {
			if time.Since(a.created) > 24*time.Hour {
				delete(h.asks, old)
			}
		}
		st := &askState{
			notify:    req.Notify,
			questions: req.Questions,
			cwd:       req.Cwd,
			doneCh:    make(chan struct{}),
			created:   time.Now(),
		}
		h.asks[id] = st
		h.askMu.Unlock()

		// Same unconditional escalation as the session path: there is no
		// gesture to make before walking away, which is the point.
		h.escalate(st, id, req.Questions)
		writeJSON(w, map[string]string{"askId": id})

	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

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
		h.settleAsk(id, answer, sourceApp)
		w.WriteHeader(http.StatusNoContent)
	default:
		http.Error(w, "not found", http.StatusNotFound)
	}
}

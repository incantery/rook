package host

import (
	"encoding/json"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

// This file is the host half of the drafter (docs/agent.md): the attention
// list rook-agent and the inbox both poll, the context endpoint the drafter
// reads, and the draft/approve/reject flow that actuates replies. All of it
// is mechanical — the only LLM caller in the system is rook-agent, and it
// goes through these same authenticated endpoints as any other client.

// draftInfo is the in-memory "current open draft" for one transcript
// session, merged into /attention items. The decisions table holds the
// durable row; this is just its hot index.
type draftInfo struct {
	ID         int64   `json:"id"`
	AskSeq     int     `json:"askSeq"`
	Action     string  `json:"action"` // draft | escalate
	Reply      string  `json:"reply,omitempty"`
	Reason     string  `json:"reason,omitempty"` // nano's why, verbatim
	Confidence float64 `json:"confidence,omitempty"`
}

// attentionItem is one "a claude session is waiting on you" row, workspace-
// agnostic: the inbox, the titlebar chip, notifications, and rook-agent all
// consume this shape.
type attentionItem struct {
	Workspace    string     `json:"workspace"`
	RookSession  string     `json:"rookSession"`
	Window       int        `json:"window"` // index in the workspace's strip order
	AgentSession string     `json:"agentSession"`
	AskSeq       int        `json:"askSeq"`
	State        string     `json:"state"`
	Title        string     `json:"title,omitempty"`
	Ask          string     `json:"ask,omitempty"`
	Interactive  bool       `json:"interactive,omitempty"` // TUI picker: jump, don't type
	Since        time.Time  `json:"since"`
	Draft        *draftInfo `json:"draft,omitempty"`
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
			item := attentionItem{
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
			}
			h.draftMu.Lock()
			if d, ok := h.drafts[s.Agent.SessionID]; ok && d.AskSeq == s.Agent.AskSeq {
				c := d
				item.Draft = &c
			}
			h.draftMu.Unlock()
			items = append(items, item)
		}
	}
	// oldest waiting first — the thing you've kept waiting longest leads
	sort.Slice(items, func(i, j int) bool { return items[i].Since.Before(items[j].Since) })
	return items
}

// handleAgent routes /agents/{id}/context (GET) and /agents/{id}/draft
// (POST) — {id} is the transcript session id.
func (h *Host) handleAgent(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/agents/")
	id, action, _ := strings.Cut(rest, "/")
	if id == "" {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	switch {
	case action == "context" && r.Method == http.MethodGet:
		st, hist, ok := h.aw.context(id)
		if !ok {
			http.Error(w, "no such agent session", http.StatusNotFound)
			return
		}
		cwd := st.CWD
		if cwd == "" {
			cwd = st.Project
		}
		writeJSON(w, map[string]any{
			"sessionId": id,
			"title":     st.Title,
			"cwd":       cwd,
			"askSeq":    st.AskSeq,
			"state":     st.State,
			"ask":       st.Ask,
			"history":   hist,
		})
	case action == "draft" && r.Method == http.MethodPost:
		h.handleDraftPost(w, r, id)
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

// POST /agents/{id}/draft — rook-agent submitting a judgment for one ask.
func (h *Host) handleDraftPost(w http.ResponseWriter, r *http.Request, agentSession string) {
	var req struct {
		AskSeq       int
		Action       string
		Reply        string
		Reason       string
		Confidence   float64
		Model        string
		InputTokens  int64
		OutputTokens int64
		CachedTokens int64
		CostUSD      float64
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad body", http.StatusBadRequest)
		return
	}
	// "spawn" is the third verb (inert until a producer exists): draft a
	// NEW claude session — Draft holds the task, approval actuates it.
	if req.Action != "draft" && req.Action != "escalate" && req.Action != "spawn" {
		http.Error(w, "action must be draft|escalate|spawn", http.StatusBadRequest)
		return
	}
	st, _, ok := h.aw.context(agentSession)
	if !ok {
		http.Error(w, "no such agent session", http.StatusNotFound)
		return
	}
	// The ask this draft answers must still be the ask on screen.
	if st.State != "needs_input" || st.AskSeq != req.AskSeq {
		http.Error(w, "ask is stale", http.StatusConflict)
		return
	}
	// Interactive asks (TUI pickers) take menu selections, not typed text —
	// no draft can be actuated, so none may be recorded. Enforced here,
	// not just by the agent's politeness: no side doors (docs/agent.md).
	if st.Interactive {
		http.Error(w, "ask is interactive (picker) — nothing to type", http.StatusConflict)
		return
	}
	d := &Decision{
		AgentSession: agentSession,
		AskSeq:       req.AskSeq,
		CWD:          st.CWD,
		Ask:          st.Ask,
		Action:       req.Action,
		Draft:        req.Reply,
		Reason:       req.Reason,
		Confidence:   req.Confidence,
		Model:        req.Model,
		InputTokens:  req.InputTokens,
		OutputTokens: req.OutputTokens,
		CachedTokens: req.CachedTokens,
		CostUSD:      req.CostUSD,
	}
	if d.CWD == "" {
		d.CWD = st.Project
	}
	// Best-effort placement for the ledger; the authoritative pairing
	// happens again at approve time.
	if s := h.pairedSession(agentSession, false); s != nil {
		d.RookSession, d.Workspace = s.info.ID, s.info.Workspace
	}
	id, err := h.reg.insertDecision(d)
	if err != nil {
		// UNIQUE(agent_session, ask_seq): this ask already has a judgment
		http.Error(w, "draft already recorded for this ask", http.StatusConflict)
		return
	}
	h.draftMu.Lock()
	h.drafts[agentSession] = draftInfo{
		ID: id, AskSeq: req.AskSeq, Action: req.Action,
		Reply: req.Reply, Reason: req.Reason, Confidence: req.Confidence,
	}
	h.draftMu.Unlock()
	writeJSON(w, map[string]any{"id": id})
}

// handleDraftDecide routes /drafts/{id}/approve and /drafts/{id}/reject.
func (h *Host) handleDraftDecide(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/drafts/")
	idStr, action, _ := strings.Cut(rest, "/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || r.Method != http.MethodPost {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	d := h.reg.getDecision(id)
	if d == nil {
		http.Error(w, "no such draft", http.StatusNotFound)
		return
	}
	switch action {
	case "approve":
		h.approveDraft(w, r, d)
	case "reject":
		if !h.reg.decideDraft(d.ID, "rejected", "") {
			http.Error(w, "draft is not open", http.StatusConflict)
			return
		}
		h.dropDraft(d.AgentSession, d.ID)
		w.WriteHeader(http.StatusNoContent)
	default:
		http.Error(w, "not found", http.StatusNotFound)
	}
}

// approveDraft sends the (possibly edited) reply into the paired window.
// Ordering is load-bearing: the verdict is written BEFORE the pty write, so
// the transcript echo of our own reply finds a decided row and manual
// attribution ignores it (no double count).
func (h *Host) approveDraft(w http.ResponseWriter, r *http.Request, d *Decision) {
	var req struct{ Text string }
	json.NewDecoder(r.Body).Decode(&req)
	if d.Verdict != "open" {
		http.Error(w, "draft is not open", http.StatusConflict)
		return
	}
	// The ask must still be live — approving a stale draft would type an
	// answer to a question claude is no longer asking. Interactive asks
	// can't be typed into at all (a picker eats keystrokes, not prose).
	if st, _, ok := h.aw.context(d.AgentSession); !ok || st.AskSeq != d.AskSeq || st.State != "needs_input" || st.Interactive {
		h.reg.decideDraft(d.ID, "stale", "")
		h.dropDraft(d.AgentSession, d.ID)
		http.Error(w, "ask is stale", http.StatusConflict)
		return
	}
	text := strings.TrimSpace(req.Text)
	verdict := "approved"
	if text != "" && text != d.Draft {
		verdict = "edited"
	} else {
		text = d.Draft
	}
	if text == "" {
		http.Error(w, "nothing to send (escalate rows are yours to answer)", http.StatusBadRequest)
		return
	}
	if d.Action == "spawn" {
		h.approveSpawn(w, d, verdict, text)
		return
	}
	// Correlate transcript→window NOW (claims > binds > ring content): the
	// pairing at draft time may be minutes old.
	s := h.pairedSession(d.AgentSession, true)
	if s == nil {
		http.Error(w, "no rook window paired with this session", http.StatusConflict)
		return
	}
	if !h.reg.decideDraft(d.ID, verdict, text) {
		http.Error(w, "draft is not open", http.StatusConflict)
		return
	}
	h.dropDraft(d.AgentSession, d.ID)
	if _, err := s.pty.Write([]byte(text + "\r")); err != nil {
		// The ledger says approved but the keystroke failed — surface it;
		// the user will see the window didn't move.
		http.Error(w, "approved but pty write failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]any{"rookSession": s.info.ID, "verdict": verdict})
}

// approveSpawn actuates a spawn draft: a fresh window in the row's
// workspace (falling back to the source session's), with the claude
// command typed in once the shell has had a beat to come up. The claim
// hook correlates the new claude session on its own.
func (h *Host) approveSpawn(w http.ResponseWriter, d *Decision, verdict, task string) {
	ws := d.Workspace
	if ws == "" {
		if src := h.pairedSession(d.AgentSession, true); src != nil {
			ws = src.info.Workspace
		}
	}
	if ws == "" {
		ws = "main"
	}
	if !h.reg.decideDraft(d.ID, verdict, task) {
		http.Error(w, "draft is not open", http.StatusConflict)
		return
	}
	h.dropDraft(d.AgentSession, d.ID)
	wsInfo := h.reg.upsert(ws, "", false)
	s, err := h.spawn(100, 30, wsInfo.Root, ws)
	if err != nil {
		http.Error(w, "approved but spawn failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	go func() {
		time.Sleep(400 * time.Millisecond) // let the shell come up
		s.pty.Write([]byte("claude " + shellQuote(task) + "\r"))
	}()
	writeJSON(w, map[string]any{"rookSession": s.info.ID, "verdict": verdict, "workspace": ws})
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
		id := h.claims[agentSession]
		if id == "" {
			id = h.binds[agentSession]
		}
		h.bindMu.Unlock()
		if id == "" {
			return nil
		}
		return h.get(id)
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

func (h *Host) dropDraft(agentSession string, id int64) {
	h.draftMu.Lock()
	if e, ok := h.drafts[agentSession]; ok && e.ID == id {
		delete(h.drafts, agentSession)
	}
	h.draftMu.Unlock()
}

// onUserReply is manual attribution: the transcript says the user answered
// an ask. If a draft was open for it, the reply decides its verdict —
// approved when the user typed (≈) the draft, manual otherwise. The approve
// endpoint's own echo lands here too, but its row is already decided.
func (h *Host) onUserReply(agentSession, text string) {
	d := h.reg.openDecisionFor(agentSession)
	if d == nil {
		return
	}
	verdict := "manual"
	if d.Action == "draft" && d.Draft != "" &&
		string(normText([]byte(text))) == string(normText([]byte(d.Draft))) {
		verdict = "approved"
	}
	if h.reg.decideDraft(d.ID, verdict, text) {
		log.Printf("decisions: %s → %s (user replied)", d.AgentSession, verdict)
	}
	h.dropDraft(agentSession, d.ID)
}

// onTurnCompleted expires drafts for asks that no longer exist: a new turn
// means a new question (or none), and yesterday's draft must not be
// approvable against it.
func (h *Host) onTurnCompleted(agentSession string, askSeq int) {
	h.reg.markStale(agentSession, askSeq)
	h.draftMu.Lock()
	if e, ok := h.drafts[agentSession]; ok && e.AskSeq < askSeq {
		delete(h.drafts, agentSession)
	}
	h.draftMu.Unlock()
}

// GET /agent/spend — the drafter's budget guard reads its own ledger.
// POST — LLM spend with no ask to hang a draft row on (the preference
// extraction pass) lands as a closed 'auto' row, so the daily cap and the
// cost surfaces count every call the agent makes, not just drafts.
func (h *Host) handleSpend(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		now := time.Now()
		midnight := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
		todayUSD, _ := h.reg.spendSince(midnight)
		_, hourCalls := h.reg.spendSince(now.Add(-time.Hour))
		writeJSON(w, map[string]any{"todayUsd": todayUSD, "hourCalls": hourCalls})
	case http.MethodPost:
		var req struct {
			Action       string
			Model        string
			InputTokens  int64
			OutputTokens int64
			CachedTokens int64
			CostUSD      float64
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Action == "" {
			http.Error(w, "action required", http.StatusBadRequest)
			return
		}
		if err := h.reg.recordSpend(req.Action, req.Model, req.InputTokens, req.OutputTokens, req.CachedTokens, req.CostUSD); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// GET /decisions?since=RFC3339 — the ledger, for rookctl and the future
// preference-extraction pass (increment C).
func (h *Host) handleDecisions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	since := time.Now().Add(-24 * time.Hour)
	if s := r.URL.Query().Get("since"); s != "" {
		t, err := time.Parse(time.RFC3339, s)
		if err != nil {
			http.Error(w, "bad since (want RFC3339)", http.StatusBadRequest)
			return
		}
		since = t
	}
	list := h.reg.listDecisions(since, 0)
	if list == nil {
		list = []*Decision{}
	}
	writeJSON(w, list)
}

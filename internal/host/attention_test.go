package host

import (
	"bufio"
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

// draftHost builds a Host with a real (temp-dir) registry, a wired
// agentwatch, and one fake window whose "pty" is a pipe we can read the
// actuated keystrokes from. No agentmon, no HTTP listener.
func draftHost(t *testing.T) (*Host, *os.File) {
	t.Helper()
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	pr, pw, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pr.Close(); pw.Close() })
	h := &Host{
		sessions: map[string]*session{"w1": {info: SessionInfo{ID: "w1", Workspace: "ws"}, pty: pw}},
		reg:      loadRegistry(),
		aw:       newAgentWatch(),
		cwdCache: make(map[int]cwdEntry),
		claims:   map[string]string{"t1": "w1"},
		binds:    map[string]string{},
		drafts:   make(map[string]draftInfo),
	}
	if h.reg.db == nil {
		t.Fatal("test registry has no db")
	}
	h.aw.onUserReply = h.onUserReply
	h.aw.onTurnCompleted = h.onTurnCompleted
	return h, pr
}

func postDraft(t *testing.T, h *Host, session string, body map[string]any) *httptest.ResponseRecorder {
	t.Helper()
	b, _ := json.Marshal(body)
	req := httptest.NewRequest("POST", "/agents/"+session+"/draft", bytes.NewReader(b))
	w := httptest.NewRecorder()
	h.handleAgent(w, req)
	return w
}

func decide(t *testing.T, h *Host, id string, action, text string) *httptest.ResponseRecorder {
	t.Helper()
	body := "{}"
	if text != "" {
		b, _ := json.Marshal(map[string]string{"text": text})
		body = string(b)
	}
	req := httptest.NewRequest("POST", "/drafts/"+id+"/"+action, strings.NewReader(body))
	w := httptest.NewRecorder()
	h.handleDraftDecide(w, req)
	return w
}

func askTurn(t *testing.T, a *agentWatch, id, text string) {
	t.Helper()
	a.applyRecord(rline(t, id, assistantMsg("m-"+text, text)))
	a.applyRecord(rline(t, id, turnDone))
}

// The whole increment-B loop against one host: draft → approve → pty gets
// the keystrokes → transcript echo does NOT double-decide.
func TestDraftApproveFlow(t *testing.T) {
	h, ptyOut := draftHost(t)
	a := h.aw
	startSession(t, a, "t1", "/repo")
	askTurn(t, a, "t1", "Deploy to staging?")

	// wrong askSeq → 409, nothing recorded
	if w := postDraft(t, h, "t1", map[string]any{"askSeq": 7, "action": "draft", "reply": "yes"}); w.Code != 409 {
		t.Fatalf("stale-seq draft: code %d, want 409", w.Code)
	}

	w := postDraft(t, h, "t1", map[string]any{
		"askSeq": 1, "action": "draft", "reply": "yes", "confidence": 0.9, "costUsd": 0.002})
	if w.Code != 200 {
		t.Fatalf("draft post: %d %s", w.Code, w.Body)
	}
	var res struct {
		ID int64 `json:"id"`
	}
	json.Unmarshal(w.Body.Bytes(), &res)

	// same ask, second draft → 409 (UNIQUE guard)
	if w := postDraft(t, h, "t1", map[string]any{"askSeq": 1, "action": "draft", "reply": "yes"}); w.Code != 409 {
		t.Fatalf("duplicate draft: code %d, want 409", w.Code)
	}

	if w := decide(t, h, "1", "approve", ""); w.Code != 200 {
		t.Fatalf("approve: %d %s", w.Code, w.Body)
	}
	line, err := bufio.NewReader(ptyOut).ReadString('\r')
	if err != nil || line != "yes\r" {
		t.Fatalf("pty got %q (%v), want yes\\r", line, err)
	}
	if d := h.reg.getDecision(res.ID); d.Verdict != "approved" || d.FinalText != "yes" {
		t.Fatalf("row after approve: %+v", d)
	}

	// the echo of our own write: user_prompt "yes" must find a decided row
	a.applyRecord(rline(t, "t1", userMsg("yes")))
	if d := h.reg.getDecision(res.ID); d.Verdict != "approved" {
		t.Fatalf("echo re-decided the row: %+v", d)
	}

	// second decision on the same row → 409
	if w := decide(t, h, "1", "approve", ""); w.Code != 409 {
		t.Fatalf("double approve: code %d, want 409", w.Code)
	}
}

// The user answers in the window themselves: same text → approved, other
// text → manual. Either way the row closes and the draft map clears.
func TestManualAttribution(t *testing.T) {
	h, _ := draftHost(t)
	a := h.aw
	startSession(t, a, "t1", "/repo")

	askTurn(t, a, "t1", "Run the tests too?")
	postDraft(t, h, "t1", map[string]any{"askSeq": 1, "action": "draft", "reply": "Yes, run them."})
	// user types the draft, modulo case/punctuation — that's an approval
	a.applyRecord(rline(t, "t1", userMsg("yes run them")))
	if d := h.reg.getDecision(1); d.Verdict != "approved" {
		t.Fatalf("matching manual reply: verdict %q, want approved", d.Verdict)
	}

	askTurn(t, a, "t1", "Delete the old branch?")
	postDraft(t, h, "t1", map[string]any{"askSeq": 2, "action": "draft", "reply": "yes"})
	a.applyRecord(rline(t, "t1", userMsg("no, keep it for now")))
	if d := h.reg.getDecision(2); d.Verdict != "manual" || d.FinalText != "no, keep it for now" {
		t.Fatalf("divergent manual reply: %+v", d)
	}

	h.draftMu.Lock()
	_, open := h.drafts["t1"]
	h.draftMu.Unlock()
	if open {
		t.Error("draft map must clear once the user has answered")
	}
}

// A new turn_completed obsoletes open drafts: rows go stale, and approving
// one afterward must refuse rather than type into the wrong question.
func TestStaleOnNewTurn(t *testing.T) {
	h, _ := draftHost(t)
	a := h.aw
	startSession(t, a, "t1", "/repo")

	askTurn(t, a, "t1", "First question?")
	postDraft(t, h, "t1", map[string]any{"askSeq": 1, "action": "draft", "reply": "yes"})
	askTurn(t, a, "t1", "Different question?")

	if d := h.reg.getDecision(1); d.Verdict != "stale" {
		t.Fatalf("open row must go stale on a new turn, got %q", d.Verdict)
	}
	if w := decide(t, h, "1", "approve", ""); w.Code != 409 {
		t.Fatalf("approving a stale draft: code %d, want 409", w.Code)
	}

	// escalate rows: nothing to type, approve is a 400er even when fresh
	postDraft(t, h, "t1", map[string]any{"askSeq": 2, "action": "escalate"})
	if w := decide(t, h, "2", "approve", ""); w.Code != 400 {
		t.Fatalf("approving an escalate row: code %d, want 400", w.Code)
	}
	if w := decide(t, h, "2", "reject", ""); w.Code != 204 {
		t.Fatalf("reject: code %d, want 204", w.Code)
	}
}

// The spawn verb: a draft whose approval starts a NEW session in the
// workspace and types the claude command, rather than writing into the
// source window.
func TestSpawnDraft(t *testing.T) {
	h, _ := draftHost(t)
	a := h.aw
	startSession(t, a, "t1", "/repo")
	askTurn(t, a, "t1", "Done. Next steps: fix the flaky picker test.")

	w := postDraft(t, h, "t1", map[string]any{
		"askSeq": 1, "action": "spawn", "reply": "fix the flaky picker test in ws", "confidence": 0.8})
	if w.Code != 200 {
		t.Fatalf("spawn draft post: %d %s", w.Code, w.Body)
	}
	if w := decide(t, h, "1", "approve", ""); w.Code != 200 {
		t.Fatalf("spawn approve: %d %s", w.Code, w.Body)
	}
	var res struct {
		RookSession string `json:"rookSession"`
		Workspace   string `json:"workspace"`
	}
	json.Unmarshal(decide(t, h, "1", "approve", "").Body.Bytes(), &res) // second decide is a 409; parse the first
	// find the freshly spawned session (the fake window is w1)
	h.mu.Lock()
	var spawned *session
	for id, s := range h.sessions {
		if id != "w1" {
			spawned = s
		}
	}
	h.mu.Unlock()
	if spawned == nil {
		t.Fatal("approve must spawn a real session")
	}
	// workspace falls back to the source window's (claimed t1 → w1 → "ws")
	if spawned.info.Workspace != "ws" {
		t.Errorf("spawned into %q, want ws", spawned.info.Workspace)
	}
	if d := h.reg.getDecision(1); d.Verdict != "approved" {
		t.Errorf("verdict = %q", d.Verdict)
	}
	// the delayed keystroke lands in the new window's ring (shell echo)
	deadline := time.Now().Add(3 * time.Second)
	for {
		spawned.mu.Lock()
		ring := string(spawned.ring)
		spawned.mu.Unlock()
		if strings.Contains(ring, "fix the flaky picker test") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("claude command never reached the spawned pty; ring: %q", ring)
		}
		time.Sleep(50 * time.Millisecond)
	}
	h.kill(spawned.info.ID) // no orphan shells from tests
}

// Interactive asks (TUI pickers) must refuse drafts outright — a typed
// reply cannot actuate a menu, so the ledger must never hold one.
func TestInteractiveAskRefusesDrafts(t *testing.T) {
	h, _ := draftHost(t)
	a := h.aw
	startSession(t, a, "t1", "/repo")
	a.applyRecord(rline(t, "t1", toolUse("AskUserQuestion", map[string]any{
		"questions": []map[string]any{{
			"question": "Which one?",
			"options":  []map[string]string{{"label": "A"}, {"label": "B"}},
		}},
	})))

	if w := postDraft(t, h, "t1", map[string]any{"askSeq": 1, "action": "draft", "reply": "A"}); w.Code != 409 {
		t.Fatalf("draft against a picker: code %d, want 409", w.Code)
	}
}

package host

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"testing"
	"time"
)

// TestOverview covers the mission-control endpoint's two tiers: idle
// workspaces come back as bare list items (no probes spent on them), live
// ones carry the status rollup — and unregistered workspaces with live
// sessions still appear.
func TestOverview(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	// overview runs through workspaceList, which reads config.Load() fresh for
	// the workspace-allow filter — isolate config too, else a real
	// ~/.config/rook with workspace-allow set hides the test's workspaces.
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	h := New()
	defer h.Shutdown()

	h.reg.upsert("alpha", "", false)

	// A live "session" in an unregistered workspace: a real process (fgOf
	// falls back to its pid when the pty ioctl fails on a pipe) plus a pipe
	// standing in for the pty, attach_test-style.
	cmd := exec.Command("sleep", "300")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer cmd.Process.Kill()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	defer r.Close()
	s := &session{
		info: SessionInfo{ID: "s1", Name: "s1", Workspace: "beta", Created: time.Now()},
		pty:  r,
		cmd:  cmd,
	}
	h.mu.Lock()
	h.sessions["s1"] = s
	h.mu.Unlock()

	srv := httptest.NewServer(h.Handler())
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/overview", nil)
	req.Header.Set("Authorization", "Bearer "+h.Token())
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /overview: %d", resp.StatusCode)
	}
	var items []overviewItem
	if err := json.NewDecoder(resp.Body).Decode(&items); err != nil {
		t.Fatal(err)
	}

	byName := map[string]overviewItem{}
	for _, it := range items {
		byName[it.Name] = it
	}
	alpha, ok := byName["alpha"]
	if !ok {
		t.Fatalf("registered idle workspace missing from overview: %+v", items)
	}
	if alpha.Sessions != 0 || alpha.Fg != nil || alpha.Agents != nil || alpha.Attention != 0 {
		t.Fatalf("idle workspace should carry no rollup: %+v", alpha)
	}
	beta, ok := byName["beta"]
	if !ok {
		t.Fatalf("unregistered live workspace missing from overview: %+v", items)
	}
	if beta.Sessions != 1 {
		t.Fatalf("beta sessions = %d, want 1", beta.Sessions)
	}
	if len(beta.Fg) != 1 || beta.Fg[0] != "sleep" {
		t.Fatalf("beta fg = %v, want [sleep]", beta.Fg)
	}
}

// A deck row has to be openable, and openable means carrying BOTH ids: the
// transcript (conversation view) and the pty (raw attach). They come from two
// different objects — the agent names itself, the session names the window —
// which is exactly how one of them goes missing.
func TestAgentRowCarriesBothIdentities(t *testing.T) {
	last := time.Now().Add(-90 * time.Second)
	s := sessionStatus{
		SessionInfo: SessionInfo{ID: "rook-pty-7", Workspace: "rook"},
		Fg:          "claude",
		Cwd:         "/src/rook",
		Agent: &AgentStatus{
			SessionID: "transcript-abc",
			State:     "needs_input",
			Title:     "Migrate charts to design tokens",
			Ask:       "Should I keep the legacy palette export?",
			Tool:      "Edit",
			Model:     "opus",
			CostUSD:   1.25,
			LastEvent: last,
		},
	}

	got := agentRow(s)

	// The two ids must not be crossed: a row that opens the transcript when
	// you asked for raw (or vice versa) is worse than one that refuses.
	if got.SessionID != "transcript-abc" {
		t.Errorf("SessionID = %q, want the transcript id", got.SessionID)
	}
	if got.RookSession != "rook-pty-7" {
		t.Errorf("RookSession = %q, want the pty session id", got.RookSession)
	}
	if got.State != "needs_input" || got.Title != "Migrate charts to design tokens" {
		t.Errorf("state/title lost: %+v", got)
	}
	if got.Ask != "Should I keep the legacy palette export?" || got.Tool != "Edit" {
		t.Errorf("ask/tool lost: %+v", got)
	}
	if got.Model != "opus" || got.CostUSD != 1.25 {
		t.Errorf("model/cost lost: %+v", got)
	}
	if !got.LastEvent.Equal(last) {
		t.Errorf("LastEvent = %v, want %v — the row's age column reads this", got.LastEvent, last)
	}
}

// An agent the watcher sees but never correlated to a window has no pty. It is
// still a real agent and still belongs in the list: the deck drops the raw
// verb rather than the row. Losing it here would make a working claude
// invisible for the only reason that rook couldn't guess its window.
func TestAgentRowUncorrelatedKeepsTheTranscript(t *testing.T) {
	got := agentRow(sessionStatus{
		SessionInfo: SessionInfo{ID: ""},
		Agent:       &AgentStatus{SessionID: "transcript-xyz", State: "working"},
	})
	if got.SessionID != "transcript-xyz" {
		t.Errorf("SessionID = %q — an uncorrelated agent still has a transcript", got.SessionID)
	}
	if got.RookSession != "" {
		t.Errorf("RookSession = %q, want empty rather than invented", got.RookSession)
	}
}

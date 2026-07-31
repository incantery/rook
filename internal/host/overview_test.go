package host

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestOverview covers the projection's two tiers: idle workspaces come back
// as bare list items (no probes spent on them), live ones carry the status
// rollup — and unregistered workspaces with live sessions still appear.
//
// It used to drive GET /overview. The endpoint went with the agent deck in
// the strip and overviewItems() is now called directly, which is also how
// its one remaining caller (cloudProject) reaches it.
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


	items := h.overviewItems()

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

// The seam, end to end: a real agent, correlated to a real window, arriving
// over HTTP with both ids intact.
//
// agentRow's unit test above cannot see the one failure that matters. Revert
// handleOverview to an inline struct literal that drops both ids and it still
// passes — nothing asserts the projection is CALLED. That's the whole bug
// class the extraction was meant to close, so it gets a test that goes
// through the endpoint.
//
// No real claude needed: fgOf basenames the window's foreground process, so a
// copy of `sleep` named `claude` is a claude window as far as correlate() can
// tell. That is the same tier-2/3 cwd match the daily driver leans on today
// (the claim hook is a hook install away, and tier 0 is inert without it).
func TestOverviewRowsCarryIdentityEndToEnd(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	h := New()
	defer h.Shutdown()

	// EvalSymlinks: on macOS t.TempDir() hands back /var/folders/... while the
	// process's real cwd resolves to /private/var/folders/..., and correlation
	// is a string compare on cwd — the test would fail for a reason that has
	// nothing to do with what it's testing.
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h.reg.upsert("rook", dir, false)

	// a "claude" window: correlate() reads the foreground process name
	fake := filepath.Join(t.TempDir(), "claude")
	sleep, err := exec.LookPath("sleep")
	if err != nil {
		t.Skip("no sleep on PATH")
	}
	body, err := os.ReadFile(sleep)
	if err != nil {
		t.Skip("cannot read sleep")
	}
	if err := os.WriteFile(fake, body, 0o755); err != nil {
		t.Skip("cannot write a fake claude")
	}
	cmd := exec.Command(fake, "300")
	cmd.Dir = dir
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
	h.mu.Lock()
	h.sessions["pty-1"] = &session{
		info: SessionInfo{ID: "pty-1", Name: "pty-1", Workspace: "rook", Created: time.Now()},
		pty:  r,
		cmd:  cmd,
	}
	h.mu.Unlock()

	last := time.Now().Add(-90 * time.Second)
	h.aw.mu.Lock()
	h.aw.states["transcript-abc"] = &AgentStatus{
		SessionID: "transcript-abc",
		CWD:       dir, // tier-2/3 correlation is a cwd match
		State:     "needs_input",
		Title:     "Migrate charts to design tokens",
		Ask:       "Keep the legacy palette export?",
		Model:     "opus",
		CostUSD:   1.25,
		LastEvent: last,
	}
	h.aw.mu.Unlock()

	items := h.overviewItems()

	var got *overviewAgent
	for _, it := range items {
		if it.Name == "rook" && len(it.Agents) > 0 {
			got = &it.Agents[0]
		}
	}
	if got == nil {
		t.Fatalf("no correlated agent row in the projection: %+v", items)
	}
	// the two ids, from two different objects — the reason for all of this
	if got.SessionID != "transcript-abc" {
		t.Errorf("sessionId = %q, want the transcript id", got.SessionID)
	}
	if got.RookSession != "pty-1" {
		t.Errorf("rookSession = %q, want the pty id — the row can't open raw without it", got.RookSession)
	}
	if got.Model != "opus" || got.CostUSD != 1.25 {
		t.Errorf("model/cost lost in transit: %+v", got)
	}
	if !got.LastEvent.Equal(last) {
		t.Errorf("lastEvent = %v, want %v", got.LastEvent, last)
	}
}

// needs_input leads. The deck's whole thesis is that the human's queue sorts
// itself to the top, and this is the comparator it rests on.
func TestAgentRankPutsTheHumansQueueFirst(t *testing.T) {
	for _, tt := range []struct {
		state string
		rank  int
	}{
		{"needs_input", 0},
		{"working", 1},
		{"quiet", 2},
		{"", 2}, // unknown sorts with the idle, never above the blocked
	} {
		if got := agentRank(tt.state); got != tt.rank {
			t.Errorf("agentRank(%q) = %d, want %d", tt.state, got, tt.rank)
		}
	}
}

// LastEvent deliberately has no omitempty (a zero time.Time is not the zero
// value encoding/json omits anyway, but the intent is what's being pinned):
// the reader needs to tell "no activity recorded" from "field absent", and
// absent is what an OLD daemon sends. Someone tidying omitempty onto it would
// collapse that distinction silently.
func TestOverviewAgentAlwaysReportsLastEvent(t *testing.T) {
	b, err := json.Marshal(overviewAgent{State: "quiet"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"lastEvent"`) {
		t.Errorf("lastEvent vanished from %s — absent must mean an old daemon, not a quiet one", b)
	}
}

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

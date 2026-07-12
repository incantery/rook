package host

import (
	"encoding/json"
	"strings"
	"testing"
)

// POST /workspaces/{name}/spawn: the shared task-spawn actuator. A real
// spawn starts a shell, so the happy path asserts session bookkeeping and
// the guards assert the refusals.
func TestWorkspaceSpawnEndpoint(t *testing.T) {
	h, srv, _ := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	if code, body := c.do(t, "POST", "/workspaces/nope/spawn", map[string]any{"task": "x"}); code != 404 {
		t.Fatalf("unknown workspace must 404: %d %s", code, body)
	}
	if code, body := c.do(t, "POST", "/workspaces/src/spawn", map[string]any{}); code != 400 {
		t.Fatalf("empty body must 400: %d %s", code, body)
	}
	if code, body := c.do(t, "POST", "/workspaces/src/spawn", map[string]any{"preset": "bogus"}); code != 400 {
		t.Fatalf("unknown preset must 400: %d %s", code, body)
	}

	code, body := c.do(t, "POST", "/workspaces/src/spawn", map[string]any{"task": "echo hi"})
	if code != 200 {
		t.Fatalf("spawn: %d %s", code, body)
	}
	var info SessionInfo
	if err := json.Unmarshal([]byte(body), &info); err != nil || info.ID == "" {
		t.Fatalf("spawn must return the session: %v %s", err, body)
	}
	if info.Workspace != "src" {
		t.Fatalf("session landed in %q, want src", info.Workspace)
	}
	if s := h.get(info.ID); s == nil {
		t.Fatal("spawned session must be live")
	} else {
		s.cmd.Process.Kill()
	}
}

// The resolve-conflicts preset builds the prompt host-side (the house
// pattern): merge — never rebase — and push so the PR updates.
func TestResolveConflictsTask(t *testing.T) {
	task := resolveConflictsTask(&WorkspaceInfo{Name: "t1", Branch: "rook/t1"})
	for _, want := range []string{"rook/t1", "git fetch origin", "NOT rebase", "push"} {
		if !strings.Contains(task, want) {
			t.Fatalf("prompt must mention %q:\n%s", want, task)
		}
	}
}

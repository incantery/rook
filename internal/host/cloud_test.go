package host

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/incantery/rook/internal/cloud"
)

// The projection is the privacy line: what it copies leaves the machine.
// So the test states the whole published set rather than spot-checking a
// field — a new field added to the projection has to be added here too,
// which is the point. Fg (foreground commands) is the field that must NOT
// travel, and the only way to assert that is to serialize and look.
func TestCloudProjectPublishesExactlyTheDecidedFields(t *testing.T) {
	seen := time.Date(2026, 7, 26, 10, 30, 0, 0, time.UTC)
	items := []overviewItem{{
		workspaceListItem: workspaceListItem{
			WorkspaceInfo: WorkspaceInfo{Name: "rook", Root: "/Users/seth/src/rook"},
			Sessions:      2,
		},
		Git:       &GitInfo{Branch: "main", Dirty: 3},
		Fg:        []string{"claude", "nvim ~/.ssh/config"},
		Attention: 1,
		Agents: []overviewAgent{{
			State:       "needs_input",
			Title:       "wire the cloud reporter",
			Ask:         "ship 42px or keep 52?",
			Tool:        "Bash",
			SessionID:   "sess-abc",
			RookSession: "pty-9",
			Model:       "opus",
			CostUSD:     1.25,
			LastEvent:   seen,
		}},
	}}

	st := cloudProject("workbench.local", "v0.36.1", items)

	if st.Hostname != "workbench.local" || st.RookVersion != "v0.36.1" {
		t.Fatalf("machine identity lost: %+v", st)
	}
	if len(st.Workspaces) != 1 {
		t.Fatalf("want 1 workspace, got %d", len(st.Workspaces))
	}
	ws := st.Workspaces[0]
	if ws.Name != "rook" || ws.Branch != "main" || ws.Attention != 1 {
		t.Errorf("workspace projected wrong: %+v", ws)
	}
	if len(ws.Agents) != 1 {
		t.Fatalf("want 1 agent, got %d", len(ws.Agents))
	}
	a := ws.Agents[0]
	want := cloud.Agent{
		State:     "needs_input",
		Title:     "wire the cloud reporter",
		Ask:       "ship 42px or keep 52?",
		Model:     "opus",
		CostUSD:   1.25,
		LastEvent: seen,
	}
	if a != want {
		t.Errorf("agent projected wrong:\n got %+v\nwant %+v", a, want)
	}

	// the fields that stay home, checked on the wire rather than the struct:
	// a leak would arrive by someone adding a field, not by this one changing
	b, err := json.Marshal(st)
	if err != nil {
		t.Fatal(err)
	}
	for _, home := range []string{"nvim", "~/.ssh/config", "/Users/seth", "pty-9", "sess-abc", "Bash"} {
		if strings.Contains(string(b), home) {
			t.Errorf("%q left the machine:\n%s", home, b)
		}
	}
}

// An idle registry entry is not "going on". Dropping it is what keeps the
// payload small on a machine with a long workspace list — and a workspace
// with agents but no counted sessions still travels, because the agents are
// the thing worth seeing.
func TestCloudProjectOmitsIdleWorkspaces(t *testing.T) {
	items := []overviewItem{
		{workspaceListItem: workspaceListItem{WorkspaceInfo: WorkspaceInfo{Name: "idle"}}},
		{
			workspaceListItem: workspaceListItem{WorkspaceInfo: WorkspaceInfo{Name: "live"}, Sessions: 1},
		},
		{
			workspaceListItem: workspaceListItem{WorkspaceInfo: WorkspaceInfo{Name: "agents-only"}},
			Agents:            []overviewAgent{{State: "quiet"}},
		},
	}
	st := cloudProject("h", "v", items)
	var names []string
	for _, ws := range st.Workspaces {
		names = append(names, ws.Name)
	}
	if strings.Join(names, ",") != "live,agents-only" {
		t.Errorf("want live,agents-only — got %v", names)
	}
}

// busy picks the cadence, so what counts as busy is worth pinning: an agent
// doing something, or one waiting on a human. A quiet agent is not busy —
// that machine gets the heartbeat.
func TestBusyCadence(t *testing.T) {
	agents := func(states ...string) cloud.Status {
		ws := cloud.Workspace{Name: "w"}
		for _, s := range states {
			ws.Agents = append(ws.Agents, cloud.Agent{State: s})
		}
		return cloud.Status{Workspaces: []cloud.Workspace{ws}}
	}
	for _, tc := range []struct {
		name string
		st   cloud.Status
		want bool
	}{
		{"nothing at all", cloud.Status{}, false},
		{"no agents", agents(), false},
		{"quiet only", agents("quiet"), false},
		{"working", agents("quiet", "working"), true},
		{"waiting on a human", agents("needs_input"), true},
	} {
		if got := busy(tc.st); got != tc.want {
			t.Errorf("%s: busy = %v, want %v", tc.name, got, tc.want)
		}
	}
}

package host

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/incantery/rook/internal/cloud"
)

// The projection is the privacy line: what it copies leaves the machine.
// So the test states the whole published set rather than spot-checking a
// field — a new field added to the projection has to be added here too,
// which is the point. Fg (foreground commands) and Root (a filesystem
// path) are the fields that must NOT travel, and the only way to assert
// that is to serialize and look.
//
// It used to publish per-agent rows and an attention count as well. The
// transcript sensor that produced them left in the strip, so the set is
// now smaller — and this test shrinking is the record of that.
func TestCloudProjectPublishesExactlyTheDecidedFields(t *testing.T) {
	items := []workspaceListItem{{
		WorkspaceInfo: WorkspaceInfo{
			Name:   "rook",
			Root:   "/Users/seth/go/src/rook",
			Branch: "rook/4-thing",
		},
		Sessions: 2,
	}}
	st := cloudProject("workbench.local", "v0.36.1", items)

	if st.Hostname != "workbench.local" || st.RookVersion != "v0.36.1" {
		t.Fatalf("machine identity: %+v", st)
	}
	if len(st.Workspaces) != 1 {
		t.Fatalf("want 1 workspace, got %d", len(st.Workspaces))
	}
	if ws := st.Workspaces[0]; ws.Name != "rook" || ws.Branch != "rook/4-thing" {
		t.Fatalf("workspace: %+v", ws)
	}

	// Serialize and read the whole thing back: a field added to the wire
	// type shows up here as an unexpected key rather than as a quiet
	// publication.
	b, err := json.Marshal(st)
	if err != nil {
		t.Fatal(err)
	}
	got := string(b)
	want := `{"hostname":"workbench.local","rookVersion":"v0.36.1","workspaces":[{"name":"rook","branch":"rook/4-thing"}]}`
	if got != want {
		t.Errorf("published set changed:\n got %s\nwant %s", got, want)
	}
	// The path is the one thing here that names the user's filesystem.
	if strings.Contains(got, "/Users/") {
		t.Errorf("a workspace root left the machine: %s", got)
	}
}

// An idle registry entry is not "going on". Dropping it is what keeps the
// payload small on a machine with a long workspace list.
func TestCloudProjectOmitsIdleWorkspaces(t *testing.T) {
	items := []workspaceListItem{
		{WorkspaceInfo: WorkspaceInfo{Name: "idle"}},
		{WorkspaceInfo: WorkspaceInfo{Name: "live"}, Sessions: 1},
	}
	st := cloudProject("h", "v", items)
	var names []string
	for _, ws := range st.Workspaces {
		names = append(names, ws.Name)
	}
	if strings.Join(names, ",") != "live" {
		t.Errorf("want live — got %v", names)
	}
}

// busy picks the cadence. It used to mean "an agent is working or waiting
// on a human"; the sensor that knew took that with it, so a live workspace
// is the signal left — and an empty snapshot gets the heartbeat.
func TestBusyCadence(t *testing.T) {
	if busy(cloud.Status{}) {
		t.Error("a machine with nothing live is not busy")
	}
	if !busy(cloud.Status{Workspaces: []cloud.Workspace{{Name: "w"}}}) {
		t.Error("a live workspace is busy")
	}
}

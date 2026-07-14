package host

import (
	"slices"
	"testing"
)

func TestAllowedWorkspace(t *testing.T) {
	off := allowSet(nil)
	if !allowedWorkspace("anything", "", off) {
		t.Fatal("empty allowlist must pass everything (filter off)")
	}

	allow := allowSet([]string{"rook", "dora"})
	cases := []struct {
		name, worktreeOf string
		want             bool
	}{
		{"rook", "", true},             // named directly
		{"rook-t1", "rook", true},      // worktree of a named source
		{"scratch", "", false},         // not named
		{"dora-t2", "dora", true},      // worktree of the other named source
		{"secret-t1", "secret", false}, // worktree of an un-named source
	}
	for _, c := range cases {
		if got := allowedWorkspace(c.name, c.worktreeOf, allow); got != c.want {
			t.Errorf("allowedWorkspace(%q, %q) = %v, want %v", c.name, c.worktreeOf, got, c.want)
		}
	}
}

// writeHostConfig is defined in workflow_test.go; it expects XDG_CONFIG_HOME
// to already be set and writes the rook config file config.Load() reads.

func listNames(items []workspaceListItem) []string {
	out := make([]string, 0, len(items))
	for _, it := range items {
		out = append(out, it.Name)
	}
	slices.Sort(out)
	return out
}

func TestWorkspaceListAllowFilter(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	h := New()
	defer h.Shutdown()

	h.reg.upsert("rook", "", false)
	h.reg.upsert("secret", "", false)
	if _, err := h.reg.createWorktreeWS("rook-t1", "", "rook", "rook/rook-t1", nil); err != nil {
		t.Fatal(err)
	}

	t.Setenv("XDG_CONFIG_HOME", t.TempDir())

	// filter off: everything shows
	writeHostConfig(t, "# no allowlist\n")
	if got, want := listNames(h.workspaceList()), []string{"rook", "rook-t1", "secret"}; !slices.Equal(got, want) {
		t.Fatalf("filter off: got %v, want %v", got, want)
	}

	// allow rook: rook + its worktree survive, secret is hidden
	writeHostConfig(t, "workspace-allow = rook\n")
	if got, want := listNames(h.workspaceList()), []string{"rook", "rook-t1"}; !slices.Equal(got, want) {
		t.Fatalf("allow=rook: got %v, want %v", got, want)
	}
}

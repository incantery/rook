package mux

import (
	"os"
	"path/filepath"
	"testing"
)

func TestEnginePath(t *testing.T) {
	home := t.TempDir()
	prefix := t.TempDir() // stands in for ~/.local
	bin := filepath.Join(prefix, "bin")
	if err := os.MkdirAll(filepath.Join(prefix, "libexec", "rook"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	engine := filepath.Join(prefix, "libexec", "rook", "engine")
	if err := os.WriteFile(engine, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	rook := filepath.Join(bin, "rook")
	if err := os.WriteFile(rook, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	// $ROOK_ENGINE wins outright — the dev build you have not installed.
	if got := enginePath("/tmp/some/engine", rook, home); got != "/tmp/some/engine" {
		t.Errorf("env override: got %q", got)
	}
	// libexec beside the running binary.
	if got := enginePath("", rook, home); got != engine {
		t.Errorf("beside exe: got %q want %q", got, engine)
	}
	// …found through a symlink to it, too (~/.local/bin/rook is one).
	link := filepath.Join(t.TempDir(), "rook")
	if err := os.Symlink(rook, link); err != nil {
		t.Fatal(err)
	}
	// (macOS puts the temp dir under a /var → /private/var symlink, so
	// compare resolved paths here.)
	got, _ := filepath.EvalSymlinks(enginePath("", link, home))
	wantEngine, _ := filepath.EvalSymlinks(engine)
	if got != wantEngine {
		t.Errorf("through symlink: got %q want %q", got, wantEngine)
	}
	// Nothing installed: the default path, so the caller's exec error
	// names where it looked.
	want := filepath.Join(home, ".local", "libexec", "rook", "engine")
	if got := enginePath("", filepath.Join(t.TempDir(), "rook"), home); got != want {
		t.Errorf("default: got %q want %q", got, want)
	}
	// It must never be a bare name a shell would resolve on $PATH.
	if !filepath.IsAbs(want) {
		t.Errorf("default engine path is not absolute: %q", want)
	}
}

// The picker opens on the workspace you are in, and the state feed is
// where that fact lives. A snapshot it cannot read names nobody —
// the picker still opens, just without a placed cursor.
func TestCurrentFrom(t *testing.T) {
	snapshot := `{"rookMuxState":1,"epoch":"e","serial":3,` +
		`"workspaces":[{"name":"rook","current":false,"windows":[]},` +
		`{"name":"dora","current":true,"windows":[]}],"panes":[]}`
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"the workspace marked current", snapshot, "dora"},
		{"a snapshot with one workspace", `{"workspaces":[{"name":"rook","current":true}]}`, "rook"},
		{"no workspace is current", `{"workspaces":[{"name":"rook","current":false}]}`, ""},
		{"no workspaces at all", `{"workspaces":[]}`, ""},
		{"a field this reader does not know", `{"workspaces":[{"name":"rook","current":true,"mood":"new"}],"mood":"new"}`, "rook"},
		{"not a snapshot", "engine: connection refused\n", ""},
		{"nothing", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := currentFrom(c.in); got != c.want {
				t.Errorf("currentFrom(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

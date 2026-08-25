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

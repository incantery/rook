package main

import (
	"os"
	"path/filepath"
	"testing"
)

func bin(t *testing.T, dir, name string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestTsgoWinsAndIsNeverToldAboutATsdk(t *testing.T) {
	// A project with tsgo has chosen TypeScript 7. It IS the compiler,
	// so a tsdk pointing at some other lib would be wrong, not merely
	// redundant.
	root := t.TempDir()
	want := bin(t, filepath.Join(root, "node_modules", ".bin"), "tsgo")
	res := resolve(root)
	cmd := res["command"].([]string)
	if cmd[0] != want {
		t.Fatalf("command = %v, want %q", cmd, want)
	}
	if _, ok := res["settings"]; ok {
		t.Fatalf("tsgo was handed settings: %v", res)
	}
}

func TestTsgoIsOnlyEverFoundInTheProject(t *testing.T) {
	// It ships with a dependency, not as a system tool. A tsgo on $PATH
	// belongs to some other project's toolchain.
	root := t.TempDir()
	path := t.TempDir()
	bin(t, path, "tsgo")
	t.Setenv("PATH", path)
	res := resolve(root)
	if _, bad := res["error"]; !bad {
		t.Fatalf("resolve = %v, want no server — a tsgo on PATH is not this project's", res)
	}
}

func TestAWrapperIsToldWhereTheProjectsCompilerIs(t *testing.T) {
	// Run vtsls against its own bundled TypeScript and it reports errors
	// the project's pinned version does not have.
	root := t.TempDir()
	want := bin(t, filepath.Join(root, "node_modules", ".bin"), "vtsls")
	lib := filepath.Join(root, "node_modules", "typescript", "lib")
	bin(t, lib, "tsserver.js")

	res := resolve(root)
	cmd := res["command"].([]string)
	if cmd[0] != want || cmd[1] != "--stdio" {
		t.Fatalf("command = %v", cmd)
	}
	got := res["settings"].(map[string]any)["typescript"].(map[string]any)["tsdk"]
	if got != lib {
		t.Fatalf("tsdk = %v, want %q", got, lib)
	}
}

func TestAnEmptyLibDirectoryIsNotATsdk(t *testing.T) {
	// A half-removed node_modules leaves the directory behind. Pointing
	// a server at it is worse than not configuring it.
	root := t.TempDir()
	bin(t, filepath.Join(root, "node_modules", ".bin"), "vtsls")
	if err := os.MkdirAll(filepath.Join(root, "node_modules", "typescript", "lib"), 0o755); err != nil {
		t.Fatal(err)
	}
	res := resolve(root)
	if _, ok := res["settings"]; ok {
		t.Fatalf("settings = %v, want none for an empty lib", res)
	}
}

func TestNoServerNamesTheFix(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	res := resolve(t.TempDir())
	msg, ok := res["error"].(string)
	if !ok || msg == "" {
		t.Fatalf("resolve = %v, want an error naming the fix", res)
	}
}

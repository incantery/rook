package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func ptr(s string) *string { return &s }

func read(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// Comments, blank lines, and out-of-scope keys survive a scalar upsert; the
// edited key changes in place; a round-trip through Load() reflects it.
func TestSetConfigScalarUpsertPreserves(t *testing.T) {
	writeConfig(t, "# my config\nfont-size = 14\n\nbackground-opacity = 0.8\njira-url = https://old.atlassian.net\n")
	p := Path()

	var s Service
	if err := s.SetConfig(Patch{
		JiraURL:   ptr("https://new.atlassian.net/"), // trailing slash trimmed like Load()
		JiraEmail: ptr("me@org.com"),                 // appended (absent before)
	}); err != nil {
		t.Fatal(err)
	}

	out := read(t, p)
	if !strings.Contains(out, "# my config") || !strings.Contains(out, "background-opacity = 0.8") {
		t.Fatalf("comment / out-of-scope key lost:\n%s", out)
	}
	if strings.Contains(out, "old.atlassian.net") {
		t.Fatalf("old value not replaced:\n%s", out)
	}
	cfg := Load()
	if cfg.JiraURL != "https://new.atlassian.net" {
		t.Fatalf("jira-url = %q", cfg.JiraURL)
	}
	if cfg.JiraEmail != "me@org.com" {
		t.Fatalf("jira-email = %q", cfg.JiraEmail)
	}
	if cfg.FontSize != 14 {
		t.Fatalf("untouched font-size changed: %d", cfg.FontSize)
	}
}

// Projects reconcile: existing kept-row updates, missing row is added, a row
// absent from the patch map is deleted.
func TestSetConfigProjectsReconcile(t *testing.T) {
	writeConfig(t, "jira-project-rook = OLD\njira-project-stale = ZZ\n")

	var s Service
	if err := s.SetConfig(Patch{Projects: map[string]string{
		"rook":     "INF",
		"x-darwin": "XD",
	}}); err != nil {
		t.Fatal(err)
	}
	cfg := Load()
	if cfg.JiraProjects["rook"] != "INF" || cfg.JiraProjects["x-darwin"] != "XD" {
		t.Fatalf("projects wrong: %+v", cfg.JiraProjects)
	}
	if _, ok := cfg.JiraProjects["stale"]; ok {
		t.Fatalf("stale project not deleted: %+v", cfg.JiraProjects)
	}
}

// A newline in a project value must be rejected (all-or-nothing) so a JSON
// value can't inject a rogue physical config line — e.g. a keybind directive.
func TestSetConfigProjectsRejectsNewline(t *testing.T) {
	writeConfig(t, "jira-project-rook = OLD\n")

	var s Service
	if err := s.SetConfig(Patch{Projects: map[string]string{
		"rook": "X\nkeybind = ctrl+z=nuke",
	}}); err == nil {
		t.Fatalf("newline in project value must be rejected")
	}
	// The file must never have been written: the injected directive must not
	// have reached Load().
	if _, ok := Load().Keybinds["ctrl+z"]; ok {
		t.Fatalf("injected keybind reached the config: %+v", Load().Keybinds)
	}
}

// Keybinds are a block: all existing keybind lines are replaced by the set.
func TestSetConfigKeybindsBlockReplace(t *testing.T) {
	writeConfig(t, "keybind = g=review.changes\nkeybind = e=file.open\nleader = `\n")

	var s Service
	if err := s.SetConfig(Patch{Keybinds: map[string]string{
		"g":           "", // unbind
		"cmd+shift+p": "palette.toggle",
	}}); err != nil {
		t.Fatal(err)
	}
	cfg := Load()
	if cfg.Keybinds["g"] != "" {
		t.Fatalf("g should be unbound, got %q", cfg.Keybinds["g"])
	}
	if cfg.Keybinds["cmd+shift+p"] != "palette.toggle" {
		t.Fatalf("new bind missing: %+v", cfg.Keybinds)
	}
	if _, ok := cfg.Keybinds["e"]; ok {
		t.Fatalf("old keybind line not cleared: %+v", cfg.Keybinds)
	}
	if cfg.Leader != "`" {
		t.Fatalf("leader clobbered: %q", cfg.Leader)
	}
}

// Writing into a fresh (missing) file creates it and leaves no temp file.
func TestSetConfigCreatesFileAtomically(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)

	var s Service
	if err := s.SetConfig(Patch{Leader: ptr("ctrl+b")}); err != nil {
		t.Fatal(err)
	}
	if Load().Leader != "ctrl+b" {
		t.Fatalf("leader not written")
	}
	entries, _ := os.ReadDir(filepath.Join(dir, "rook"))
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".config-") {
			t.Fatalf("temp file left behind: %s", e.Name())
		}
	}

	// A newline in a value is rejected.
	if err := s.SetConfig(Patch{JiraJQL: ptr("a\nb")}); err == nil {
		t.Fatalf("newline value must be rejected")
	}
}

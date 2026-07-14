package config

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func writeConfig(t *testing.T, content string) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if err := os.MkdirAll(filepath.Join(dir, "rook"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "rook", "config"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestLoadWorkflow(t *testing.T) {
	writeConfig(t, `
workflow = /security-review, /review
workflow-special = /review
# opt-out: empty value must store an empty NON-NIL list, not vanish
workflow-quiet =
coder = my-coder
`)
	cfg := Load()
	if !slices.Equal(cfg.Workflow, []string{"/security-review", "/review"}) {
		t.Fatalf("workflow: %v", cfg.Workflow)
	}
	if !slices.Equal(cfg.Workflows["special"], []string{"/review"}) {
		t.Fatalf("workflow-special: %v", cfg.Workflows["special"])
	}
	quiet, ok := cfg.Workflows["quiet"]
	if !ok || quiet == nil || len(quiet) != 0 {
		t.Fatalf("workflow-quiet must be an explicit empty list: %v (present %v)", quiet, ok)
	}
	if cfg.Coder != "my-coder" {
		t.Fatalf("coder: %q", cfg.Coder)
	}
}

func TestLoadWorkflowDefaults(t *testing.T) {
	writeConfig(t, "# nothing configured\n")
	cfg := Load()
	if len(cfg.Workflow) != 0 || cfg.Workflows != nil {
		t.Fatalf("workflow must default off: %v %v", cfg.Workflow, cfg.Workflows)
	}
	if cfg.Coder != "claude" {
		t.Fatalf("coder must default to claude: %q", cfg.Coder)
	}
}

func TestLoadKeybinds(t *testing.T) {
	writeConfig(t, `
keybind = m=workspace.manager
keybind = cmd+shift+k = palette.toggle
# unbind form: empty command clears the trigger's default
keybind = h=
# "=" itself stays bindable (split on the LAST '=')
keybind = ==session.next
# no '=' in the value → not a binding, ignored
keybind = nonsense
`)
	cfg := Load()
	want := map[string]string{
		"m":           "workspace.manager",
		"cmd+shift+k": "palette.toggle",
		"h":           "",
		"=":           "session.next",
	}
	if len(cfg.Keybinds) != len(want) {
		t.Fatalf("keybinds: %v", cfg.Keybinds)
	}
	for k, v := range want {
		if got, ok := cfg.Keybinds[k]; !ok || got != v {
			t.Fatalf("keybind %q = %q, want %q (present %v)", k, got, v, ok)
		}
	}

	writeConfig(t, "# nothing configured\n")
	if cfg := Load(); cfg.Keybinds != nil {
		t.Fatalf("keybinds must default nil: %v", cfg.Keybinds)
	}
}

// messy values: whitespace and stray commas collapse, order survives
func TestSplitList(t *testing.T) {
	got := splitList(" /a , , /b,")
	if !slices.Equal(got, []string{"/a", "/b"}) {
		t.Fatalf("splitList: %v", got)
	}
	if empty := splitList(""); empty == nil || len(empty) != 0 {
		t.Fatalf("empty input must give empty non-nil list: %v", empty)
	}
}

func TestLoadWorkspaceAllow(t *testing.T) {
	writeConfig(t, `
workspace-allow = rook, dora
`)
	cfg := Load()
	if !slices.Equal(cfg.WorkspaceAllow, []string{"rook", "dora"}) {
		t.Fatalf("workspace-allow: %v", cfg.WorkspaceAllow)
	}

	// unset → feature off, nil list
	writeConfig(t, "# nothing configured\n")
	if cfg := Load(); cfg.WorkspaceAllow != nil {
		t.Fatalf("workspace-allow must default nil (off): %v", cfg.WorkspaceAllow)
	}
}

func TestLoadTheme(t *testing.T) {
	writeConfig(t, "theme = One Dark\n")
	if cfg := Load(); cfg.Theme != "One Dark" {
		t.Fatalf("theme = %q", cfg.Theme)
	}
	// unset → the default built-in
	writeConfig(t, "# nothing\n")
	if cfg := Load(); cfg.Theme != "Material Ocean" {
		t.Fatalf("theme must default to Material Ocean: %q", cfg.Theme)
	}
}

// JiraTokenStatus's file branch is cross-platform (keychain is darwin-only and
// tested there); point Path() at a temp dir via XDG and exercise file/none.
func TestJiraTokenStatusFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if err := os.MkdirAll(filepath.Join(dir, "rook"), 0o755); err != nil {
		t.Fatal(err)
	}
	var s Service

	// none: no keychain item (test env), no file
	if got := s.JiraTokenStatus(); got != "" && got != "keychain" {
		t.Fatalf("clean env should be \"\" (or a stray keychain item); got %q", got)
	}

	// file, but world-readable → must be ignored (0600-tight rule)
	tok := filepath.Join(dir, "rook", "jira-token")
	if err := os.WriteFile(tok, []byte("abc_def\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := s.JiraTokenStatus(); got == "file" {
		t.Fatalf("loose-perm token file must not count as a source")
	}

	// file, 0600 → "file" (assuming no keychain item shadowing it)
	if err := os.Chmod(tok, 0o600); err != nil {
		t.Fatal(err)
	}
	got := s.JiraTokenStatus()
	if got != "file" && got != "keychain" {
		t.Fatalf("tight token file should read as \"file\"; got %q", got)
	}
}

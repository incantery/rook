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

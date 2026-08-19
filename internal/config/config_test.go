package config

import (
	"os"
	"path/filepath"
	"testing"
)

func write(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "rook.toml")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLoadMissingFileMeansDefaults(t *testing.T) {
	c, err := Load(filepath.Join(t.TempDir(), "absent.toml"))
	if err != nil {
		t.Fatalf("missing file should not error: %v", err)
	}
	if c.Tmux.Prefix != "" {
		t.Fatalf("zero config expected, got %+v", c)
	}
}

func TestLoadPrefix(t *testing.T) {
	c, err := Load(write(t, "[tmux]\nprefix = \"`\"\n"))
	if err != nil {
		t.Fatal(err)
	}
	if c.Tmux.Prefix != "`" {
		t.Fatalf("prefix = %q, want backtick", c.Tmux.Prefix)
	}
}

func TestLoadRejectsUnknownKeys(t *testing.T) {
	if _, err := Load(write(t, "[tmux]\nprefx = \"C-a\"\n")); err == nil {
		t.Fatal("a typoed key must refuse to boot, not silently default")
	}
}

func TestLoadRejectsMalformedTOML(t *testing.T) {
	if _, err := Load(write(t, "[tmux\nprefix=")); err == nil {
		t.Fatal("malformed TOML must error")
	}
}

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

func TestLoadCompanion(t *testing.T) {
	c, err := Load(write(t, "[companion]\ncommand = \"vera chat\"\nkey = \"g\"\n"))
	if err != nil {
		t.Fatal(err)
	}
	if c.Companion.Command != "vera chat" || c.Companion.Key != "g" || c.Companion.Name != "" {
		t.Fatalf("companion = %+v", c.Companion)
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

// One file, two readers: the engine parses [mux] and the companion's
// `program` out of the same rook.toml, and a loader that refuses keys
// it has not heard of must not refuse those.
func TestEngineKeysAreNotErrors(t *testing.T) {
	c, err := Load(write(t, "[mux]\nagents = [\"claude\"]\nsidebar_width = 30\n"+
		"[companion]\ncommand = \"vera chat\"\nname = \"vera\"\nprogram = \"vera\"\nkey = \"l\"\n"))
	if err != nil {
		t.Fatalf("a file the engine also reads refused to load: %v", err)
	}
	if c.Companion.Program != "vera" || c.Companion.Command != "vera chat" {
		t.Errorf("companion: %+v", c.Companion)
	}
	// A typo is still a typo.
	if _, err := Load(write(t, "[companion]\ncommandd = \"vera\"\n")); err == nil {
		t.Error("an unrecognized key loaded anyway")
	}
}

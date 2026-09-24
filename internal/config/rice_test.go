package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func files(t *testing.T, fs map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, body := range fs {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestRicesComeFirstAndTheFileHasTheLastWord(t *testing.T) {
	dir := files(t, map[string]string{
		"rook.toml": "include = [\"rices/*.toml\"]\n[style]\naccent = \"#111111\"\n" +
			"[[style.match]]\nhome = true\nlabel = \"mine\"\n",
		"rices/a.toml": "[style]\naccent = \"#aaaaaa\"\nchip = \"round\"\n[[style.match]]\nhome = true\nlabel = \"a\"\n",
		"rices/b.toml": "include = [\"../nested.toml\"]\n[[style.match]]\nrepo = \"x/*\"\nbar = \"#bbbbbb\"\n",
		"nested.toml":  "[style]\nfill = \"╌\"\n",
	})
	c, err := Load(filepath.Join(dir, "rook.toml"))
	if err != nil {
		t.Fatal(err)
	}
	// base: a's chip and nested's fill survive; the file's accent wins
	b := c.Style.Style
	if *b.Accent != "#111111" || *b.Chip != "round" || *b.Fill != "╌" {
		t.Fatalf("base = accent %v chip %v fill %v", *b.Accent, b.Chip, b.Fill)
	}
	m := c.Style.Match
	if len(m) != 3 || *m[0].Label != "a" || *m[1].Bar != "#bbbbbb" || *m[2].Label != "mine" {
		t.Fatalf("rules out of order: %+v", m)
	}
	if !strings.HasSuffix(m[0].Source, "rices/a.toml #1") || !strings.HasSuffix(m[1].Source, "rices/b.toml #1") || m[2].Source != "" {
		t.Fatalf("sources = %q %q %q", m[0].Source, m[1].Source, m[2].Source)
	}
	if len(c.Files) != 4 {
		t.Fatalf("files = %v", c.Files)
	}
	// and it all compiles, sources riding along
	if r := c.Compile().Style.Rules; !strings.HasSuffix(r[0].Source, "a.toml #1") {
		t.Fatalf("compiled = %+v", r[0])
	}
}

func TestRicesRefuse(t *testing.T) {
	for name, fs := range map[string]map[string]string{
		"a cycle": {
			"rook.toml": "include = [\"a.toml\"]\n",
			"a.toml":    "include = [\"b.toml\"]\n",
			"b.toml":    "include = [\"a.toml\"]\n",
		},
		"a rice that binds a key": {
			"rook.toml": "include = [\"a.toml\"]\n",
			"a.toml":    "[keys]\ng = \"popup curl evil\"\n",
		},
		"a missing file": {
			"rook.toml": "include = [\"nope.toml\"]\n",
		},
		"an include under a table": {
			"rook.toml": "[tmux]\nprefix = \"`\"\ninclude = [\"a.toml\"]\n",
			"a.toml":    "[style]\nchip = \"round\"\n",
		},
		"a bad property in a rice, named by its file": {
			"rook.toml": "include = [\"bad.toml\"]\n",
			"bad.toml":  "[style]\nchip = \"hexagon\"\n",
		},
	} {
		dir := files(t, fs)
		_, err := Load(filepath.Join(dir, "rook.toml"))
		if err == nil {
			t.Errorf("%s: loaded anyway", name)
			continue
		}
		if name == "a bad property in a rice, named by its file" && !strings.Contains(err.Error(), "bad.toml") {
			t.Errorf("%s: %v", name, err)
		}
		if name == "an include under a table" && !strings.Contains(err.Error(), "top of the file") {
			t.Errorf("%s: %v", name, err)
		}
	}
	// a glob that matches nothing is no error: an empty rices dir is fine
	dir := files(t, map[string]string{"rook.toml": "include = [\"rices/*.toml\"]\n"})
	if _, err := Load(filepath.Join(dir, "rook.toml")); err != nil {
		t.Fatal(err)
	}
}

// Every rice the repository ships loads: they are examples people copy,
// and an example that does not load is worse than none.
func TestShippedRicesLoad(t *testing.T) {
	shipped, _ := filepath.Glob("../../rices/*.toml")
	if len(shipped) < 9 {
		t.Fatalf("rices/ holds %d files", len(shipped))
	}
	for _, p := range shipped {
		abs, _ := filepath.Abs(p)
		dir := files(t, map[string]string{"rook.toml": "include = [\"" + abs + "\"]\n"})
		c, err := Load(filepath.Join(dir, "rook.toml"))
		if err != nil {
			t.Errorf("%s: %v", filepath.Base(p), err)
			continue
		}
		if len(c.Style.Match) == 0 && c.Style.Style == (Style{}) {
			t.Errorf("%s says nothing", filepath.Base(p))
		}
	}
}

func TestRicesCarryTabRules(t *testing.T) {
	dir := files(t, map[string]string{
		"rook.toml": "include = [\"tabs.toml\"]\n[[style.tab]]\nname = \"docker\"\ncolor = \"red\"\n",
		"tabs.toml": "[[style.tab]]\nname = \"docker\"\ncolor = \"blue\"\n",
	})
	c, err := Load(filepath.Join(dir, "rook.toml"))
	if err != nil {
		t.Fatal(err)
	}
	tabs := c.Compile().Style.Tabs
	if len(tabs) != 2 || *tabs[0].Style.Color != "blue" || *tabs[1].Style.Color != "red" || !strings.HasSuffix(tabs[0].Source, "tabs.toml tab #1") {
		t.Fatalf("tabs = %+v", tabs)
	}
}

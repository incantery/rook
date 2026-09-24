package config

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// The engine owns the vocabulary; this list is its copy for refusing
// typos early. A verb added to one and not the other fails here.
func TestVerbsMatchTheEngine(t *testing.T) {
	src, err := os.ReadFile("../../mux/src/keys.zig")
	if err != nil {
		t.Fatal(err)
	}
	body := string(src)
	start := strings.Index(body, "pub const Verb = enum {")
	end := strings.Index(body[start:], "pub fn parse(")
	if start < 0 || end < 0 {
		t.Fatal("keys.zig: the Verb enum moved")
	}
	var engine []string
	for _, m := range regexp.MustCompile(`(?m)^\s+([a-z_]+),$`).FindAllStringSubmatch(body[start:start+end], -1) {
		if m[1] != "none" {
			engine = append(engine, strings.ReplaceAll(m[1], "_", "-"))
		}
	}
	if strings.Join(engine, " ") != strings.Join(Verbs, " ") {
		t.Fatalf("verbs differ\nengine: %v\ngo:     %v", engine, Verbs)
	}
}

func TestLoadKeys(t *testing.T) {
	c, err := Load(write(t, "[keys]\ng = \"popup 72x86@124x48 grim\"\n\"C-o\" = \"last-space\"\n\"|\" = \"split-right\"\nx = \"\"\n"))
	if err != nil {
		t.Fatal(err)
	}
	if c.Keys["g"] != "popup 72x86@124x48 grim" || c.Keys["C-o"] != "last-space" || c.Keys["x"] != "" {
		t.Fatalf("keys = %v", c.Keys)
	}
	for _, bad := range []string{
		"[keys]\ng = \"popop grim\"\n",
		"[keys]\ng = \"popup\"\n",
		"[keys]\n\"M-g\" = \"home\"\n",
		"[keys]\ng = 3\n",
	} {
		if _, err := Load(write(t, bad)); err == nil {
			t.Errorf("loaded anyway: %q", bad)
		}
	}
}

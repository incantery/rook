package config

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

func TestStyleCompilesInOrder(t *testing.T) {
	e := compile(t, `[home]
color = "cyan"
[style]
chip = "round"
accent = "#89b4fa"
[[style.match]]
repo = "github.com/grafana/*"
accent = "#ff8833"
label = "{icon} {REPO}"
[[style.match]]
home = true
workspace = "x*"
tint = "accent"
tint_amount = 40
`)
	s := e.Style
	if s.Base.Chip == nil || *s.Base.Chip != "round" || *s.Base.Accent != "#89b4fa" {
		t.Fatalf("base = %+v", s.Base)
	}
	// [home] color is a rule of its own, ahead of the file's
	if len(s.Rules) != 3 || s.Rules[0].When.Home == nil || *s.Rules[0].Style.Accent != "cyan" {
		t.Fatalf("rules = %+v", s.Rules)
	}
	if s.Rules[1].When.Repo != "github.com/grafana/*" || *s.Rules[1].Style.Label != "{icon} {REPO}" {
		t.Fatalf("rule 1 = %+v", s.Rules[1])
	}
	if !*s.Rules[2].When.Home || s.Rules[2].When.Workspace != "x*" || *s.Rules[2].Style.TintAmount != 40 {
		t.Fatalf("rule 2 = %+v", s.Rules[2])
	}
}

func TestStyleRefusesWhatTheEngineWouldMisread(t *testing.T) {
	for _, bad := range []string{
		"[style]\naccent = \"purple-ish\"\n",
		"[style]\nchip = \"hexagon\"\n",
		"[style]\ntint_amount = 140\n",
		"[style]\nlabel = \"{nmae}\"\n",
		"[[style.match]]\nrepo = \"x\"\nacent = \"red\"\n",
		"[[style.match]]\nrepo = \"x\"\nbar = \"#12\"\n",
	} {
		if _, err := Load(write(t, bad)); err == nil {
			t.Errorf("loaded anyway: %q", bad)
		}
	}
	for _, good := range []string{
		"[style]\nbar = \"#123\"\nchip_bg = \"accent\"\nmuted = \"bright-black\"\n",
		"[style]\nlabel = \"{icon} {NAME} · {branch}\"\nfill = \"╌\"\nseparator = \"\"\n",
	} {
		if _, err := Load(write(t, good)); err != nil {
			t.Errorf("%q: %v", good, err)
		}
	}
}

func TestStyleClassAndState(t *testing.T) {
	e := compile(t, "[[style.match]]\nclass = \"error\"\nstate = \"unread\"\nbar = \"#aa0000\"\n")
	if w := e.Style.Rules[0].When; w.Class != "error" || w.State != "unread" {
		t.Fatalf("when = %+v", w)
	}
	if _, err := Load(write(t, "[[style.match]]\nstate = \"on-fire\"\nbar = \"red\"\n")); err == nil {
		t.Error("an unknown state loaded")
	}
}

// The engine owns the states; this list is its copy for refusing typos.
func TestStatesMatchTheEngine(t *testing.T) {
	src, err := os.ReadFile("../../mux/src/style.zig")
	if err != nil {
		t.Fatal(err)
	}
	body := string(src)
	start := strings.Index(body, "pub const State = enum {")
	end := strings.Index(body[start:], "};")
	var engine []string
	for _, m := range regexp.MustCompile(`(?m)^\s+([a-z_]+),$`).FindAllStringSubmatch(body[start:start+end], -1) {
		engine = append(engine, m[1])
	}
	if strings.Join(engine, " ") != strings.Join(States, " ") {
		t.Fatalf("states differ\nengine: %v\ngo:     %v", engine, States)
	}
}

package config

import (
	"encoding/json"
	"strings"
	"testing"
)

func compile(t *testing.T, toml string) Engine {
	t.Helper()
	c, err := Load(write(t, toml))
	if err != nil {
		t.Fatal(err)
	}
	var e Engine
	if err := json.Unmarshal(c.Compile().JSON(), &e); err != nil {
		t.Fatal(err)
	}
	return e
}

func TestCompileEmptyIsDefaults(t *testing.T) {
	e := compile(t, "")
	if e.V != EngineVersion || e.Prefix != "" || e.Companion != "" || len(e.Keys) != 0 || len(e.Home.Windows) != 0 {
		t.Fatalf("an empty file compiled to %+v", e)
	}
	// unset is left out, so the engine's own default stands
	if s := string(Config{}.Compile().JSON()); strings.Contains(s, "restore") || strings.Contains(s, "bar") {
		t.Fatalf("unset knobs were written: %s", s)
	}
}

func TestCompileCompanionPrecedence(t *testing.T) {
	for _, c := range []struct{ toml, want string }{
		{`command = "vera chat"`, "vera"},
		{`command = "/opt/bin/aider --dark"`, "aider"},
		{"command = \"vera chat\"\nprogram = \"vera-dev\"", "vera-dev"},
		{"command = \"vera chat\"\nname = \"Vera\"", "vera"},
		{`name = "vera"`, "vera"},
		{"command = \"vera chat\"\nprogram = \"\"", ""}, // said empty: off
	} {
		if got := compile(t, "[companion]\n"+c.toml+"\n").Companion; got != c.want {
			t.Errorf("%q → %q, want %q", c.toml, got, c.want)
		}
	}
}

func TestCompileHomePanesInOrder(t *testing.T) {
	e := compile(t, "[[home.window]]\nname = \"me\"\npanes = [\"docket\", \"\"]\n"+
		"[[home.window.pane]]\ncommand = \"grim\"\nsplit = \"down\"\n")
	w := e.Home.Windows[0]
	if len(w.Panes) != 3 || w.Panes[0].Command != "docket" || w.Panes[1].Command != "" || w.Panes[2].Command != "grim" || w.Panes[2].Split != "down" {
		t.Fatalf("panes = %+v", w.Panes)
	}
}

func TestCompileMux(t *testing.T) {
	e := compile(t, "[mux]\nstatus = [\"input\"]\nrestore = false\nsidebar_width = 40\n")
	if len(e.Mux.StatusSpace) != 1 || e.Mux.Restore == nil || *e.Mux.Restore || *e.Mux.SidebarWidth != 40 {
		t.Fatalf("mux = %+v", e.Mux)
	}
	if _, err := Load(write(t, "[mux]\nglyphs = \"emoji\"\n")); err == nil {
		t.Error("an unknown glyphs value loaded")
	}
	if _, err := Load(write(t, "[mux]\nsidebar_widht = 40\n")); err == nil {
		t.Error("a typo in [mux] loaded: it is typed now")
	}
}

// Keys a config may still carry from before the root went: they load,
// and they do nothing.
func TestRetiredKeysStillLoad(t *testing.T) {
	if _, err := Load(write(t, "[mux]\nstatus_home = [\"view\"]\nzoom_view = \"orbit\"\n"+
		"[companion]\ncommand = \"vera\"\nask = \"vera say\"\nchat = \"vera chat\"\nkey = \"t\"\n")); err != nil {
		t.Fatal(err)
	}
}

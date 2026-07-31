package rook

import "testing"

// The preset bundles exist twice — here and config.zig's applyPreset
// (the TOML front end's expansion). This golden pins the Go side to
// the agreed values; the e2e `presetparity` scenario diffs the two
// implementations on the live app. Change a bundle → change BOTH
// definitions and this golden, or one of the guards goes red.
func TestPresetGoldens(t *testing.T) {
	tmux := string(New().PresetTmuxNeovim().JSON())
	wantTmux := `{"rookEnvironment":1,"nodes":[` +
		`{"id":"option:app:top-bar","kind":"option","scope":"app","key":"top-bar","value":[]},` +
		`{"id":"option:app:status-left","kind":"option","scope":"app","key":"status-left","value":["tabs"]},` +
		`{"id":"option:app:status-right","kind":"option","scope":"app","key":"status-right","value":["workspace","branch","cwd"]},` +
		`{"id":"option:app:tab-style","kind":"option","scope":"app","key":"tab-style","value":"index-name"},` +
		`{"id":"option:app:buffer-line","kind":"option","scope":"app","key":"buffer-line","value":false}` +
		"]}\n"
	if tmux != wantTmux {
		t.Errorf("tmux-neovim bundle drifted:\n got %s\nwant %s", tmux, wantTmux)
	}

	vscode := string(New().PresetVSCode().JSON())
	wantVSCode := `{"rookEnvironment":1,"nodes":[` +
		`{"id":"option:app:top-bar","kind":"option","scope":"app","key":"top-bar","value":[]},` +
		`{"id":"option:app:status-left","kind":"option","scope":"app","key":"status-left","value":["tabs","branch"]},` +
		`{"id":"option:app:status-right","kind":"option","scope":"app","key":"status-right","value":["cwd","hints"]},` +
		`{"id":"option:app:tab-style","kind":"option","scope":"app","key":"tab-style","value":"current"},` +
		`{"id":"option:app:buffer-line","kind":"option","scope":"app","key":"buffer-line","value":"always"},` +
		`{"id":"option:app:theme","kind":"option","scope":"app","key":"theme","value":"vscode-dark"},` +
		`{"id":"option:app:editor-mode","kind":"option","scope":"app","key":"editor-mode","value":"insert"},` +
		`{"id":"option:app:activity-bar","kind":"option","scope":"app","key":"activity-bar","value":true},` +
		`{"id":"option:app:explorer-auto","kind":"option","scope":"app","key":"explorer-auto","value":true}` +
		"]}\n"
	if vscode != wantVSCode {
		t.Errorf("vscode bundle drifted:\n got %s\nwant %s", vscode, wantVSCode)
	}
}

// A preset is a defaults layer: an explicit key AFTER it overrides the
// bundle's node in place (same id, later call wins).
func TestPresetOverride(t *testing.T) {
	e := New().PresetVSCode().BufferLine(false)
	got := string(e.JSON())
	want := `"key":"buffer-line","value":false`
	if !contains(got, want) {
		t.Errorf("override lost: %s", got)
	}
	if contains(got, `"key":"buffer-line","value":true`) {
		t.Errorf("bundle value survived beside the override: %s", got)
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// The plugin node is the user-facing half of the plugin system, so its
// exact bytes matter: the TS SDK pins the SAME literal (sdk/ts/rook.test.ts),
// and parity between them is a byte diff.
//
// Note what is asserted beyond the shape: `grants` is an ARRAY even when
// empty, never null. Absent and empty mean the same thing — nothing
// granted — and a reader that has to handle both will get one wrong.
const wantPluginGraph = `{"rookEnvironment":1,"nodes":[` +
	`{"id":"plugin:hello","kind":"plugin","scope":"app","name":"hello","command":["hello"],"load":"lazy","grants":["items.list"]},` +
	`{"id":"plugin:demo-list","kind":"plugin","scope":"app","name":"demo-list","command":["demo-list"],"load":"eager","grants":["items.list","items.act"]},` +
	`{"id":"plugin:untrusted","kind":"plugin","scope":"app","name":"untrusted","command":["untrusted"],"load":"lazy","grants":[]}` +
	`]}` + "\n"

func TestPluginNodeBytes(t *testing.T) {
	e := New()
	e.Plugin("hello", []string{"hello"}, "", "items.list")
	e.Plugin("demo-list", []string{"demo-list"}, "eager", "items.list", "items.act")
	e.Plugin("untrusted", []string{"untrusted"}, "lazy")
	if got := string(e.JSON()); got != wantPluginGraph {
		t.Errorf("plugin graph moved.\n got: %s\nwant: %s", got, wantPluginGraph)
	}
}

// lazy is the DEFAULT, and it is a decision rather than a convenience: a
// surface nobody opened must cost nothing, which is the rule every poller
// in rook's history had to learn.
func TestPluginDefaultsToLazy(t *testing.T) {
	got := string(New().Plugin("p", []string{"p"}, "").JSON())
	if !contains(got, `"load":"lazy"`) {
		t.Errorf("empty load did not default to lazy: %s", got)
	}
}

// A plugin declared with no grants is INERT, not ungoverned. Staging one
// before you trust it has to be expressible.
func TestPluginWithNoGrantsIsDeclaredButInert(t *testing.T) {
	got := string(New().Plugin("p", []string{"p"}, "lazy").JSON())
	if !contains(got, `"grants":[]`) {
		t.Errorf("no grants should emit an empty array: %s", got)
	}
}

// Same id replaces in place — composing a base environment then overriding
// one plugin's grants has to mean something.
func TestPluginOverrideReplacesInPlace(t *testing.T) {
	e := New()
	e.Plugin("p", []string{"p"}, "eager", "items.list", "items.act")
	e.Plugin("p", []string{"p"}, "lazy") // the override: revoke everything
	got := string(e.JSON())
	if !contains(got, `"load":"lazy","grants":[]`) {
		t.Errorf("override lost: %s", got)
	}
	if contains(got, `"items.act"`) {
		t.Errorf("revoked grant survived the override: %s", got)
	}
}

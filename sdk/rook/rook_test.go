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
		`{"id":"option:app:buffer-line","kind":"option","scope":"app","key":"buffer-line","value":true}` +
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

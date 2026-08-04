package rook

import (
	"strings"
	"testing"
)

// The preset bundles exist twice — here and config.zig's applyPreset
// (the TOML front end's expansion). This golden pins the Go side to
// the agreed values; the e2e `presetparity` scenario diffs the two
// implementations on the live app. Change a bundle → change BOTH
// definitions and this golden, or one of the guards goes red.
func TestPresetGoldens(t *testing.T) {
	tmux := string(JSON(PresetTmuxNeovim()))
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

	vscode := string(JSON(PresetVSCode()))
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

// A preset is a defaults layer: a declaration AFTER it overrides the
// bundle's node in place (same id, later declaration wins).
func TestPresetOverride(t *testing.T) {
	got := string(JSON(PresetVSCode(), BufferLineOff))
	if !strings.Contains(got, `"key":"buffer-line","value":"off"`) {
		t.Errorf("override lost: %s", got)
	}
	if strings.Contains(got, `"key":"buffer-line","value":"always"`) {
		t.Errorf("bundle value survived beside the override: %s", got)
	}
}

// The plugin node is the user-facing half of the plugin system, so its
// exact bytes matter: the TS SDK pins the SAME literal (sdk/ts/rook.test.ts),
// and parity between them is a byte diff.
//
// Note what is asserted beyond the shape: `grants` is an ARRAY even when
// empty, never null. Absent and empty mean the same thing — nothing
// granted — and a reader handling both shapes will get one wrong.
const wantPluginGraph = `{"rookEnvironment":1,"nodes":[` +
	`{"id":"plugin:hello","kind":"plugin","scope":"app","name":"hello","command":["hello"],"load":"lazy","grants":["items.list"]},` +
	`{"id":"plugin:demo-list","kind":"plugin","scope":"app","name":"demo-list","command":["demo-list"],"load":"eager","grants":["items.list","items.act"]},` +
	`{"id":"plugin:untrusted","kind":"plugin","scope":"app","name":"untrusted","command":["untrusted"],"load":"lazy","grants":[]}` +
	`]}` + "\n"

func TestPluginNodeBytes(t *testing.T) {
	got := string(JSON(
		Plugin{Name: "hello", Command: []string{"hello"}, Grants: []string{OpItemsList}},
		Plugin{Name: "demo-list", Command: []string{"demo-list"}, Load: Eager, Grants: []string{OpItemsList, OpItemsAct}},
		Plugin{Name: "untrusted", Command: []string{"untrusted"}, Load: Lazy},
	))
	if got != wantPluginGraph {
		t.Errorf("plugin graph moved.\n got: %s\nwant: %s", got, wantPluginGraph)
	}
}

// A sourced plugin names itself from the URL's last segment, and a pin
// rides beside the source.
func TestPluginFromSource(t *testing.T) {
	got := string(JSON(Plugin{Source: "https://example.com/x/hello-plugin", SHA256: "abc123", Grants: []string{OpItemsList}}))
	want := `{"id":"plugin:hello-plugin","kind":"plugin","scope":"app","name":"hello-plugin",` +
		`"source":"https://example.com/x/hello-plugin","sha256":"abc123","load":"lazy","grants":["items.list"]}`
	if !strings.Contains(got, want) {
		t.Errorf("sourced plugin moved:\n got: %s\nwant: %s", got, want)
	}
}

// The workspace node replaces the sqlite registry, so its bytes are the
// contract the app parses and the TS SDK pins the same literal
// (sdk/ts/rook.test.ts). `~/` roots ship unexpanded — expansion is the
// app's job, against the machine the graph lands on.
const wantWorkspaceGraph = `{"rookEnvironment":1,"nodes":[` +
	`{"id":"workspace:rook","kind":"workspace","scope":"app","name":"rook","root":"~/src/rook"},` +
	`{"id":"workspace:dora","kind":"workspace","scope":"app","name":"dora","root":"/w/dora"}` +
	`]}` + "\n"

func TestWorkspaceNodeBytes(t *testing.T) {
	// Singles, in declaration order — the ordered form.
	got := string(JSON(
		Workspace{Name: "rook", Root: "~/src/rook"},
		Workspace{Name: "dora", Root: "/w/dora"},
	))
	if got != wantWorkspaceGraph {
		t.Errorf("workspace graph moved.\n got: %s\nwant: %s", got, wantWorkspaceGraph)
	}
}

// The group forms are sugar over the same nodes: maps emit SORTED
// (canonical bytes cannot ride Go's random map order), and merging is
// per entry — a later group's chord replaces, in place, only the
// chords it names.
func TestGroupsSortAndMergePerEntry(t *testing.T) {
	got := string(JSON(Workspaces{
		"rook": "~/src/rook",
		"dora": "/w/dora",
	}))
	dora := strings.Index(got, `"workspace:dora"`)
	rk := strings.Index(got, `"workspace:rook"`)
	if dora == -1 || rk == -1 || dora > rk {
		t.Errorf("workspaces not sorted by name: %s", got)
	}

	got = string(JSON(
		Binds{"<leader>v": CmdPaneSplitRight, "<leader>c": CmdTabNew},
		Binds{"<leader>v": CmdPaneSplitDown}, // rebind ONE chord
	))
	if !strings.Contains(got, `"chord":"<leader>v","command":"pane.split-down"`) {
		t.Errorf("later group's chord did not win: %s", got)
	}
	if !strings.Contains(got, `"chord":"<leader>c","command":"tab.new"`) {
		t.Errorf("merge was not per-entry — untouched chord lost: %s", got)
	}
	if strings.Contains(got, "pane.split-right") {
		t.Errorf("replaced chord survived: %s", got)
	}
}

// Zero fields in the grouped structs are UNSET, not zero-values on the
// wire — Font{Size: 16} must leave font-family alone.
func TestZeroFieldsAreUnset(t *testing.T) {
	got := string(JSON(Font{Size: 16}))
	if strings.Contains(got, "font-family") {
		t.Errorf("zero Family emitted: %s", got)
	}
	if !strings.Contains(got, `"key":"font-size","value":16`) {
		t.Errorf("size lost: %s", got)
	}
}

// The typed command constants are generated from the app's registry;
// this smoke-checks the generator's naming so a regeneration that
// drifts fails here before it confuses anyone.
func TestGeneratedCmds(t *testing.T) {
	if CmdPaneSplitRight != "pane.split-right" || CmdTreeToggle != "tree.toggle" {
		t.Fatal("cmds.go naming drifted from registry ids")
	}
	if TabSelect(3) != "tab.select-3" {
		t.Fatal("TabSelect misrenders")
	}
}

// The typed first-party declarations are sugar over Plugin, and the
// proof they are PURE sugar is byte equality: each zero-value form
// must emit exactly the argv and grants a hand written its config
// with before these types existed — so adopting them shows "no
// pending changes" in rook env, not a diff.
func TestFirstPartyPluginsLowerToTheHandWrittenBytes(t *testing.T) {
	got := string(JSON(Claude{}, Agent{}, Cloud{}))
	want := string(JSON(
		Plugin{
			Name:    "claude",
			Command: []string{"/Applications/rook.app/Contents/MacOS/rook-plugin-claude"},
			Load:    Eager,
			Grants: []string{
				OpItemsList, OpItemsAct, OpAttentionRaise, OpSessionSpawn, OpPanesActivity,
			},
		},
		Plugin{
			Name:    "agent",
			Command: []string{"/Applications/rook.app/Contents/MacOS/rook-plugin-agent", "--model", "gpt-5.6-luna"},
			Load:    Eager,
			Grants:  []string{OpItemsList, OpItemsAct, OpClipboardSet},
		},
		Plugin{
			Name:    "cloud",
			Command: []string{"/Applications/rook.app/Contents/MacOS/rook-plugin-cloud"},
			Load:    Eager,
			Grants:  []string{OpItemsList, OpItemsAct, OpPanesActivity, OpSessionSend},
		},
	))
	if got != want {
		t.Errorf("typed forms are not pure sugar.\n got: %s\nwant: %s", got, want)
	}
}

// Each option becomes a visible flag in the graph — expansion where
// provenance can see it, never a default hidden in the binary.
func TestAgentOptionsBecomeFlags(t *testing.T) {
	got := string(JSON(Agent{Model: "llama3.2", API: Ollama, MinWords: 200}))
	want := `"command":["/Applications/rook.app/Contents/MacOS/rook-plugin-agent",` +
		`"--model","llama3.2","--api-base","http://localhost:11434/v1","--min-words","200"]`
	if !strings.Contains(got, want) {
		t.Errorf("agent options lost in lowering:\n got: %s\nwant contains: %s", got, want)
	}

	got = string(JSON(Cloud{API: "http://192.168.4.22:8080"}))
	if !strings.Contains(got, `"command":["/Applications/rook.app/Contents/MacOS/rook-plugin-cloud","--api","http://192.168.4.22:8080"]`) {
		t.Errorf("cloud API target lost: %s", got)
	}
}

// Overrides must really override: narrowed grants replace the default
// set (and an EMPTY slice stages the plugin inert — nil means default,
// empty means nothing, and those are different declarations), and an
// explicit Lazy beats the watchers' Eager default.
func TestFirstPartyOverrides(t *testing.T) {
	got := string(JSON(Agent{Grants: []string{OpItemsList}, Load: Lazy}))
	if !strings.Contains(got, `"load":"lazy","grants":["items.list"]`) {
		t.Errorf("overrides lost: %s", got)
	}
	if strings.Contains(got, "clipboard.set") {
		t.Errorf("default grant survived beside the override: %s", got)
	}
	got = string(JSON(Claude{Grants: []string{}}))
	if !strings.Contains(got, `"grants":[]`) {
		t.Errorf("empty grants must stage inert, not fall back to defaults: %s", got)
	}
}

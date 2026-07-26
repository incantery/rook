package config

import (
	"os"
	"reflect"
	"regexp"
	"strings"
	"testing"
)

const sampleTOMLPath = "../../docs/config.sample.toml"

// A commented key line in the TOML sample: `# key = ...` with a bare
// kebab-case key or a quoted trigger. Prose comments don't match — they
// either don't start with a key shape or lack the `=`.
var sampleTOMLKeyLine = regexp.MustCompile(`^([a-z][a-z0-9-]*|"[^"]+")\s*=`)

func readSampleTOML(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile(sampleTOMLPath)
	if err != nil {
		t.Fatalf("read %s: %v", sampleTOMLPath, err)
	}
	return string(b)
}

// uncommentSample rebuilds the sample with every documented key line
// uncommented, keeping the section headers (which the sample leaves
// uncommented) in place.
func uncommentSample(t *testing.T) string {
	t.Helper()
	var b strings.Builder
	for line := range strings.SplitSeq(readSampleTOML(t), "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "[") {
			b.WriteString(trimmed)
			b.WriteByte('\n')
			continue
		}
		s := strings.TrimSpace(strings.TrimPrefix(trimmed, "#"))
		if sampleTOMLKeyLine.MatchString(s) {
			b.WriteString(s)
			b.WriteByte('\n')
		}
	}
	return b.String()
}

// TestSampleTOMLDefaults uncomments every documented key line and asserts
// the result parses as valid TOML and loads the scalar knobs to exactly
// Default() — so each commented default in the sample provably IS the
// default, and can't silently drift from config.go.
func TestSampleTOMLDefaults(t *testing.T) {
	writeTOML(t, uncommentSample(t))

	got := Load()
	// The placeholder/example keys (jira, relay, workflow, keybinds,
	// workspace tables, lsp) carry no meaningful default — zero them so the
	// comparison is exactly the concrete-default scalar knobs.
	got.JiraURL, got.JiraEmail, got.JiraJQL = "", "", ""
	got.RelayURL, got.CloudURL = "", ""
	got.JiraProjects, got.BranchPrefixes, got.BranchDelimiters = nil, nil, nil
	got.Workflow, got.Workflows, got.Keybinds, got.WorkspaceAllow = nil, nil, nil, nil
	got.EditorKeybinds = nil
	got.LSP, got.LSPServers, got.LSPRefused = nil, nil, nil
	if !reflect.DeepEqual(got, Default()) {
		t.Fatalf("TOML sample defaults drifted from config.Default():\n got %+v\nwant %+v", got, Default())
	}
}

// TestSampleTOMLValid asserts the uncommenting round actually applied the
// file (a parse error applies nothing, which would make TestSampleTOMLDefaults
// pass vacuously): an uncommented non-default key must be visible.
func TestSampleTOMLValid(t *testing.T) {
	writeTOML(t, uncommentSample(t))
	cfg := Load()
	if cfg.Keybinds["<leader>m"] != "workspace.manager" {
		t.Fatalf("uncommented sample did not parse/apply — keybinds: %v", cfg.Keybinds)
	}
	if cfg.EditorKeybinds["normal"]["<leader>q"] != "quickfix.toggle" {
		t.Fatalf("editor keybinds missing: %v", cfg.EditorKeybinds)
	}
	if !reflect.DeepEqual(cfg.LSP, []string{"go", "typescript"}) {
		t.Fatalf("lsp enable missing: %v", cfg.LSP)
	}
}

// TestSampleTOMLCoversSchema asserts every toml tag the schema understands
// is documented in the sample. Teach toml.go a new knob without documenting
// it and this fails.
func TestSampleTOMLCoversSchema(t *testing.T) {
	src, err := os.ReadFile("toml.go")
	if err != nil {
		t.Fatalf("read toml.go: %v", err)
	}
	sample := readSampleTOML(t)

	tags := regexp.MustCompile("toml:\"([a-z0-9-]+)\"").FindAllStringSubmatch(string(src), -1)
	if len(tags) == 0 {
		t.Fatal("found no toml tags in toml.go — the scraping regex is wrong")
	}
	for _, m := range tags {
		if !strings.Contains(sample, m[1]) {
			t.Errorf("config key %q is not documented in %s", m[1], sampleTOMLPath)
		}
	}
}

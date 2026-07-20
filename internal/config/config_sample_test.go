package config

import (
	"os"
	"reflect"
	"regexp"
	"strings"
	"testing"
)

const samplePath = "../../docs/config.sample"

// A commented key line in the sample: "# <key> = ...", the key optionally
// carrying a <workspace> placeholder. Prose comments don't match — they
// either don't start lowercase or lack the `key =` shape.
var sampleKeyLine = regexp.MustCompile(`^[a-z][a-z0-9-]*(<[a-z]+>)?\s*=`)

func readSample(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile(samplePath)
	if err != nil {
		t.Fatalf("read %s: %v", samplePath, err)
	}
	return string(b)
}

// TestSampleDefaults uncomments every documented key line and asserts the
// scalar knobs load to exactly Default() — so each commented default in the
// sample provably IS the default, and can't silently drift from config.go.
func TestSampleDefaults(t *testing.T) {
	var b strings.Builder
	for _, line := range strings.Split(readSample(t), "\n") {
		s := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "#"))
		if sampleKeyLine.MatchString(s) {
			b.WriteString(s)
			b.WriteByte('\n')
		}
	}
	writeConfig(t, b.String())
	got := Load()
	// The placeholder/example keys (jira-*, workflow, keybind, and the
	// per-workspace dynamic keys) carry no meaningful default — zero them so
	// the comparison is exactly the concrete-default scalar knobs.
	got.JiraURL, got.JiraEmail, got.JiraJQL = "", "", ""
	got.JiraProjects, got.BranchPrefixes, got.BranchDelimiters = nil, nil, nil
	got.Workflow, got.Workflows, got.Keybinds = nil, nil, nil
	got.LSP, got.LSPServers, got.LSPRefused = nil, nil, nil
	if !reflect.DeepEqual(got, Default()) {
		t.Fatalf("sample defaults drifted from config.Default():\n got %+v\nwant %+v", got, Default())
	}
}

// TestSampleCoversParser asserts every key the parser understands is
// documented in the sample: each fixed `case "..."` and each dynamic
// `CutPrefix(key, "...")` prefix. Teach the parser a new knob without
// documenting it here and this fails.
func TestSampleCoversParser(t *testing.T) {
	src, err := os.ReadFile("config.go")
	if err != nil {
		t.Fatalf("read config.go: %v", err)
	}
	sample := readSample(t)

	var keys []string
	for _, m := range regexp.MustCompile(`case "([^"]+)":`).FindAllStringSubmatch(string(src), -1) {
		keys = append(keys, m[1])
	}
	for _, m := range regexp.MustCompile(`CutPrefix\(key, "([^"]+)"\)`).FindAllStringSubmatch(string(src), -1) {
		keys = append(keys, m[1])
	}
	if len(keys) == 0 {
		t.Fatal("found no keys in config.go — the scraping regexes are wrong")
	}
	for _, k := range keys {
		if !strings.Contains(sample, k) {
			t.Errorf("config key %q is not documented in %s", k, samplePath)
		}
	}
}

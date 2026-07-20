package plugin

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/incantery/rook/internal/config"
)

func testManager(t *testing.T) *Manager {
	t.Helper()
	return NewManager(t.TempDir())
}

func TestResolveIntentTier(t *testing.T) {
	m := testManager(t)
	cfg := config.Config{LSP: []string{"go", "cobol"}}
	specs, issues := Resolve(cfg, m)
	if len(specs) != 1 {
		t.Fatalf("specs: %+v", specs)
	}
	s := specs[0]
	if s.Server != "gopls" || s.Plugin != "go" || s.Tier != "catalog" {
		t.Fatalf("gopls spec: %+v", s)
	}
	if !strings.HasPrefix(s.Command[0], m.Dir) || !strings.HasSuffix(s.Command[0], filepath.FromSlash("bin/gopls")) {
		t.Fatalf("managed command must live in the prefix: %v", s.Command)
	}
	if !slices.Contains(s.Filetypes, "go") || !slices.Contains(s.Roots, "go.mod") {
		t.Fatalf("catalog payload missing: %+v", s)
	}
	if len(issues) != 1 || !strings.Contains(issues[0].Detail, "unknown language") {
		t.Fatalf("cobol must be an issue: %+v", issues)
	}
}

func TestResolveOverridesAndOff(t *testing.T) {
	m := testManager(t)
	cfg := config.Config{
		LSP: []string{"go", "typescript"},
		LSPServers: map[string]config.LSPServer{
			"gopls": {Settings: `{"gopls":{"buildFlags":["-tags","server"]}}`},
			"vtsls": {Off: true},
		},
	}
	specs, _ := Resolve(cfg, m)
	if len(specs) != 1 {
		t.Fatalf("vtsls must be off: %+v", specs)
	}
	if specs[0].Settings != `{"gopls":{"buildFlags":["-tags","server"]}}` {
		t.Fatalf("settings override: %+v", specs[0])
	}
}

// A command line flips a catalog server to system-provided.
func TestResolveCommandFlipsToSystem(t *testing.T) {
	m := testManager(t)
	cfg := config.Config{
		LSP: []string{"go"},
		LSPServers: map[string]config.LSPServer{
			"gopls": {Command: "/opt/gopls serve -rpc.trace"},
		},
	}
	specs, _ := Resolve(cfg, m)
	if len(specs) != 1 || specs[0].Tier != "system" || specs[0].Plugin != "" {
		t.Fatalf("spec: %+v", specs)
	}
	if !slices.Equal(specs[0].Command, []string{"/opt/gopls", "serve", "-rpc.trace"}) {
		t.Fatalf("command: %v", specs[0].Command)
	}
	// catalog payload survives the flip
	if !slices.Contains(specs[0].Filetypes, "go") {
		t.Fatalf("filetypes lost: %+v", specs[0])
	}
}

func TestResolveBringYourOwn(t *testing.T) {
	m := testManager(t)
	cfg := config.Config{LSPServers: map[string]config.LSPServer{
		"zls":  {Command: "zls", Filetypes: []string{"zig"}},
		"nope": {Command: "nope-lsp"}, // no filetypes → issue, not a spec
		"orph": {Settings: "{}"},      // tuning with no server behind it
	}}
	specs, issues := Resolve(cfg, m)
	if len(specs) != 1 || specs[0].Server != "zls" || specs[0].Tier != "system" {
		t.Fatalf("specs: %+v", specs)
	}
	if !slices.Equal(specs[0].Roots, []string{".git"}) {
		t.Fatalf("default roots: %+v", specs[0].Roots)
	}
	var subjects []string
	for _, i := range issues {
		subjects = append(subjects, i.Subject)
	}
	slices.Sort(subjects)
	if !slices.Equal(subjects, []string{"lsp-nope", "lsp-orph"}) {
		t.Fatalf("issues: %+v", issues)
	}
}

// Tuning keys for an unselected catalog server are inert — a checked-in
// .rook/config may tune gopls on a machine whose dotfile omits go.
func TestResolveInertCatalogTuning(t *testing.T) {
	m := testManager(t)
	cfg := config.Config{LSPServers: map[string]config.LSPServer{
		"gopls": {Settings: "{}"},
	}}
	specs, issues := Resolve(cfg, m)
	if len(specs) != 0 || len(issues) != 0 {
		t.Fatalf("must be inert: %+v %+v", specs, issues)
	}
}

// ---- Manager ----

// fakeToolchain drops stub `go` and `npm` scripts on PATH that create the
// binary their real counterparts would — the full exec path, no network.
func fakeToolchain(t *testing.T, fail bool) {
	t.Helper()
	dir := t.TempDir()
	// the test PATH is only this dir — the stubs must reach mkdir/chmod
	body := "#!/bin/sh\nPATH=/bin:/usr/bin:$PATH\n"
	if fail {
		body += "echo boom >&2; exit 1\n"
	} else {
		// go: GOBIN is set; npm: --prefix is $3. Either way, create the
		// expected binary inside the staging tree.
		body += `if [ -n "$GOBIN" ]; then mkdir -p "$GOBIN" && printf '#!/bin/sh\n' > "$GOBIN/gopls" && chmod +x "$GOBIN/gopls";` + "\n"
		body += `else mkdir -p "$3/node_modules/.bin" && printf '#!/bin/sh\n' > "$3/node_modules/.bin/vtsls" && chmod +x "$3/node_modules/.bin/vtsls"; fi` + "\n"
	}
	for _, name := range []string{"go", "npm"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", dir)
}

func entryFor(t *testing.T, name string) Entry {
	t.Helper()
	e := catalogByName(name)
	if e == nil {
		t.Fatalf("no catalog entry %q", name)
	}
	return *e
}

func TestManagerInstallGo(t *testing.T) {
	fakeToolchain(t, false)
	m := testManager(t)
	e := entryFor(t, "go")
	if state, _ := m.State(e); state != "missing" {
		t.Fatalf("pre-install state: %s", state)
	}
	if err := m.Install(e); err != nil {
		t.Fatal(err)
	}
	if state, _ := m.State(e); state != "ready" {
		t.Fatalf("post-install state: %s", state)
	}
	if _, err := os.Stat(filepath.Join(m.Dir, "go", e.Version, "bin", "gopls")); err != nil {
		t.Fatalf("binary not in versioned dir: %v", err)
	}
	// idempotent — the binary is the lock
	if err := m.Install(e); err != nil {
		t.Fatal(err)
	}
	// no staging debris
	entries, _ := os.ReadDir(filepath.Join(m.Dir, "go"))
	if len(entries) != 1 {
		t.Fatalf("stray entries: %v", entries)
	}
}

func TestManagerInstallNpm(t *testing.T) {
	fakeToolchain(t, false)
	m := testManager(t)
	e := entryFor(t, "typescript")
	if err := m.Install(e); err != nil {
		t.Fatal(err)
	}
	if state, _ := m.State(e); state != "ready" {
		t.Fatalf("state: %s", state)
	}
}

func TestManagerInstallFailure(t *testing.T) {
	fakeToolchain(t, true)
	m := testManager(t)
	e := entryFor(t, "go")
	err := m.Install(e)
	if err == nil || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("want toolchain stderr in the error: %v", err)
	}
	state, detail := m.State(e)
	if state != "error" || !strings.Contains(detail, "boom") {
		t.Fatalf("state after failure: %s %q", state, detail)
	}
	// a later success clears the error
	fakeToolchain(t, false)
	if err := m.Install(e); err != nil {
		t.Fatal(err)
	}
	if state, _ := m.State(e); state != "ready" {
		t.Fatalf("state after retry: %s", state)
	}
}

// A toolchain that "succeeds" without producing the promised binary is an
// install error, never a ready plugin.
func TestManagerInstallNoBinary(t *testing.T) {
	dir := t.TempDir()
	noop := "#!/bin/sh\nexit 0\n"
	for _, name := range []string{"go", "npm"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(noop), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", dir)
	m := testManager(t)
	err := m.Install(entryFor(t, "go"))
	if err == nil || !strings.Contains(err.Error(), "produced no") {
		t.Fatalf("want produced-no-binary error: %v", err)
	}
}

func TestManagerNeedsToolchain(t *testing.T) {
	t.Setenv("PATH", t.TempDir()) // empty PATH: no go, no npm
	m := testManager(t)
	state, detail := m.State(entryFor(t, "go"))
	if state != "needs-toolchain" || detail != "go" {
		t.Fatalf("state: %s %q", state, detail)
	}
	if err := m.Install(entryFor(t, "go")); err == nil {
		t.Fatal("install without toolchain must error")
	}
}

func TestManagerPrune(t *testing.T) {
	fakeToolchain(t, false)
	m := testManager(t)
	e := entryFor(t, "go")
	old := filepath.Join(m.Dir, "go", "v0.0.1", "bin")
	if err := os.MkdirAll(old, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := m.Install(e); err != nil {
		t.Fatal(err)
	}
	m.Prune(e)
	entries, _ := os.ReadDir(filepath.Join(m.Dir, "go"))
	if len(entries) != 1 || entries[0].Name() != e.Version {
		t.Fatalf("prune left: %v", entries)
	}
}

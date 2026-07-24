// Package config loads the rook config file: ghostty-style `key = value`
// lines at ~/.config/rook/config (XDG_CONFIG_HOME respected). Unknown keys
// are ignored, missing file means defaults, and defaults mirror the ghostty
// parity targets (docs/parity.md).
package config

import (
	"bufio"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/incantery/rook/internal/keychain"
)

type Config struct {
	FontFamily        string  `json:"fontFamily"`
	FontSize          int     `json:"fontSize"`
	BackgroundOpacity float64 `json:"backgroundOpacity"`
	WindowPaddingX    int     `json:"windowPaddingX"`
	WindowPaddingY    int     `json:"windowPaddingY"`
	// Theme names the color theme (built-in like "Material Ocean", "One Dark",
	// "One Light"). Empty = the frontend's default. Frontend-only: the host
	// stores it, the webview builds and applies the palette.
	Theme string `json:"theme"`
	// Agent settings (docs/agent.md): read by rook-agent, never by the
	// host — the host supervises the process, the process reads its own
	// policy. Off by default; the whole feature is opt-in.
	Agent bool `json:"agent"`
	// AgentEngine picks the drafter's model backend: "claude" shells out to
	// the coder CLI the user already has (no key, no setup — claude is
	// already a hard dependency, since agentmon reads its transcripts),
	// "openai" uses an API key, "auto" (the default) prefers claude when
	// it's on PATH and falls back to a key. Empty means auto.
	AgentEngine string `json:"agentEngine"`
	// AgentModel empty means the engine's own default — the engines disagree
	// (nano vs haiku), so the default can't live here.
	AgentModel       string  `json:"agentModel"`
	AgentDailyCapUSD float64 `json:"agentDailyCapUsd"`
	// Jira issue queue (host-read): jira-url + jira-email are global; a
	// workspace opts in with `jira-project-<workspace> = KEY`. The API
	// token lives in the keychain (rookctl set-jira-token), file fallback
	// ~/.config/rook/jira-token. jira-jql replaces the default query.
	JiraURL      string            `json:"jiraUrl"`
	JiraEmail    string            `json:"jiraEmail"`
	JiraJQL      string            `json:"jiraJql"`
	JiraProjects map[string]string `json:"jiraProjects"`
	// BranchPrefixes maps a workspace to its worktree-branch prefix,
	// `branch-prefix-<workspace> = seth/`. The value is used verbatim
	// (bring your own trailing separator); unset means rook/.
	BranchPrefixes map[string]string `json:"branchPrefixes"`
	// BranchDelimiters maps a workspace to what joins an issue's key to its
	// title in a worktree branch, `branch-delimiter-<workspace> = /` →
	// FOO-123/bar-baz. Unset (or empty) means "-".
	BranchDelimiters map[string]string `json:"branchDelimiters"`
	// Coder is the CLI the host types into spawned task windows (spawn
	// drafts, the conflict-resolve chip, workflow stages). claude unless
	// overridden.
	Coder string `json:"coder"`
	// Workflow is the staged review pipeline run after a worktree's coding
	// agent opens its PR: slash commands, comma-separated (`workflow =
	// /security-review, /review`), each spawned sequentially in its own
	// window. Empty = feature off. Workflows carries per-workspace
	// overrides (`workflow-<ws> = ...`); an explicitly empty value there
	// is a non-nil empty list — that workspace opts out of the global
	// pipeline.
	Workflow  []string            `json:"workflow"`
	Workflows map[string][]string `json:"workflows"`
	// Leader is the tmux-style prefix that arms the bare-key bindings: a
	// single key (`leader = \`, the backtick default) or a modifier chord
	// (`leader = ctrl+b`, the tmux default). Pressing it twice passes the
	// leader through to the terminal. The frontend owns parsing and falls
	// back to the backtick on anything it can't read.
	Leader string `json:"leader"`
	// Keybinds maps a trigger to a registry command id, ghostty-style:
	// `keybind = <trigger>=<command>`, repeated per binding. A bare key
	// ("h") acts after the leader prefix; a modifier chord
	// ("cmd+shift+]") acts directly. An empty command ("keybind = h=")
	// unbinds the trigger's default. The frontend owns validation and
	// fails open: unknown commands, unparseable chords, and reserved
	// triggers (digits, the literal-backtick escape) are ignored there.
	Keybinds map[string]string `json:"keybinds"`
	// EditorLeader is the editor scope's own leader (vim's maplocalleader
	// to Leader's mapleader) — the comma, unless config moves it.
	EditorLeader string `json:"editorLeader"`
	// Commands maps an ex-command alias to a registry command id
	// ([commands] table, TOML-only): `Ta = "thread.ask"` makes :Ta run
	// thread.ask in the editor. The frontend owns validation and fails
	// open — unknown ids and non-CamelCase names drop with a warn.
	Commands map[string]string `json:"commands"`
	// EditorKeybinds is mode → trigger → command ([editor.keybinds.normal]
	// etc., TOML-only). Triggers: "<leader>q", chords, or bare vim
	// sequences ("gd", "K"). The frontend owns validation and ignores
	// modes it doesn't know — fail open, both directions.
	EditorKeybinds map[string]map[string]string `json:"editorKeybinds"`
	// WorkspaceAllow is a presentation-only visibility filter: when
	// non-empty, only the named workspaces (and any worktree carved from
	// one of them) appear in the host's workspace list — the dashboard,
	// mission control, and /overview. Empty/unset means every workspace
	// shows. `workspace-allow = rook, dora`. Not access control:
	// registration and per-workspace endpoints are unaffected.
	WorkspaceAllow []string `json:"workspaceAllow"`
	// LSP is the plugin intent tier (docs/superpowers/specs/
	// 2026-07-20-plugins-language-design.md): language names that expand
	// through the host's curated catalog — `lsp = go, typescript`. Rook
	// installs and manages these servers itself.
	LSP []string `json:"lsp"`
	// LSPServers is the explicit tier, keyed by server name: overrides for
	// a catalog expansion, or bring-your-own declarations
	// (`lsp-zls = zls`). A non-empty Command marks the server
	// system-provided — rook execs it as found, never installs it.
	LSPServers map[string]LSPServer `json:"lspServers"`
	// LSPRefused records repo-layer lines that were ignored under the
	// trust rule (a cloned repo must never supply argv). Surfaced in
	// status, never applied.
	LSPRefused []string `json:"lspRefused,omitempty"`
}

// LSPServer is one server's explicit-tier declaration. Zero-valued fields
// defer to the catalog entry (if the server has one); Off wins over
// everything — `lsp-<server> = off` disables the server in either layer.
type LSPServer struct {
	Command   string   `json:"command,omitempty"`
	Off       bool     `json:"off,omitempty"`
	Filetypes []string `json:"filetypes,omitempty"`
	Roots     []string `json:"roots,omitempty"`
	// Settings is raw JSON handed to the server verbatim
	// (workspace/didChangeConfiguration) — rook never interprets it.
	Settings string `json:"settings,omitempty"`
}

func Default() Config {
	return Config{
		FontFamily:        "Hack Nerd Font Mono",
		FontSize:          18,
		BackgroundOpacity: 0.95,
		WindowPaddingX:    4,
		WindowPaddingY:    4,
		Theme:             "Material Ocean",
		Agent:             false,
		AgentEngine:       "auto",
		AgentModel:        "", // engine's default
		AgentDailyCapUSD:  1.00,
		Coder:             "claude",
		Leader:            "`",
		EditorLeader:      ",",
	}
}

func Path() string {
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "rook", "config")
}

func Load() Config {
	cfg := Default()
	// config.toml is canonical; the legacy flat file applies only when no
	// TOML file exists. A present-but-broken TOML file applies nothing —
	// falling back to the legacy file would silently revive stale settings.
	if !applyTOML(&cfg, TOMLPath(), false) {
		applyFile(&cfg, Path(), false)
	}
	return cfg
}

// LoadWorkspace layers a workspace's checked-in `.rook/config` (repoTop is
// the repository top-level) over the user config. Layering is parse order:
// the repo file's lines win, last-wins like every key. The repo layer is
// bounded to lsp* keys and may select catalog plugins or tune declared
// servers, but a command line from a cloned repo is refused (recorded in
// LSPRefused, surfaced in status) — git clone must never supply argv.
func LoadWorkspace(repoTop string) Config {
	cfg := Load()
	if repoTop != "" {
		// each layer picks its format independently: .rook/config.toml
		// wins when present, else the legacy .rook/config
		if !applyTOML(&cfg, repoTOMLPath(repoTop), true) {
			applyFile(&cfg, filepath.Join(repoTop, ".rook", "config"), true)
		}
	}
	return cfg
}

// applyFile parses one config file over cfg. Missing file is a no-op.
// repoLayer bounds parsing to the keys a checked-in file may set.
func applyFile(cfg *Config, path string, repoLayer bool) {
	if path == "" {
		return
	}
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		applyKey(cfg, strings.TrimSpace(key), strings.TrimSpace(value), repoLayer)
	}
}

// applyKey applies one `key = value` line. The lsp family is handled first
// (it is the only family the repo layer may touch); everything else is the
// user file's fixed and dynamic keys.
func applyKey(cfg *Config, key, value string, repoLayer bool) {
	if key == "lsp" {
		cfg.LSP = splitList(value)
		return
	}
	if rest, ok := strings.CutPrefix(key, "lsp-"); ok && rest != "" {
		applyLSPKey(cfg, rest, value, repoLayer)
		return
	}
	if repoLayer {
		return // fail open: a repo file may carry keys a newer rook reads
	}
	// dynamic keys first — the switch below only knows fixed names
	if ws, ok := strings.CutPrefix(key, "jira-project-"); ok && ws != "" && value != "" {
		if cfg.JiraProjects == nil {
			cfg.JiraProjects = map[string]string{}
		}
		cfg.JiraProjects[ws] = value
		return
	}
	// an EMPTY value is meaningful here: `branch-prefix-<ws> =` stores an
	// empty string — that workspace's branches carry no prefix (matching a
	// CI naming scheme exactly). A genuinely unset key falls back to rook/.
	if ws, ok := strings.CutPrefix(key, "branch-prefix-"); ok && ws != "" {
		if cfg.BranchPrefixes == nil {
			cfg.BranchPrefixes = map[string]string{}
		}
		cfg.BranchPrefixes[ws] = value
		return
	}
	// the delimiter takes the opposite reading of an empty value:
	// FOO-123bar-baz is nobody's naming scheme, so `branch-delimiter-<ws> =`
	// is a typo and falls back to "-" like an unset key.
	if ws, ok := strings.CutPrefix(key, "branch-delimiter-"); ok && ws != "" && value != "" {
		if cfg.BranchDelimiters == nil {
			cfg.BranchDelimiters = map[string]string{}
		}
		cfg.BranchDelimiters[ws] = value
		return
	}
	// likewise for workflows: `workflow-<ws> =` stores an empty non-nil
	// list — that workspace explicitly opts out of the global workflow.
	if ws, ok := strings.CutPrefix(key, "workflow-"); ok && ws != "" {
		if cfg.Workflows == nil {
			cfg.Workflows = map[string][]string{}
		}
		cfg.Workflows[ws] = splitList(value)
		return
	}
	switch key {
	case "font-family":
		if value != "" {
			cfg.FontFamily = value
		}
	case "font-size":
		if n, err := strconv.Atoi(value); err == nil && n > 0 {
			cfg.FontSize = n
		}
	case "background-opacity":
		if o, err := strconv.ParseFloat(value, 64); err == nil && o >= 0 && o <= 1 {
			cfg.BackgroundOpacity = o
		}
	case "theme":
		if value != "" {
			cfg.Theme = value
		}
	case "window-padding-x":
		if n, err := strconv.Atoi(value); err == nil && n >= 0 {
			cfg.WindowPaddingX = n
		}
	case "window-padding-y":
		if n, err := strconv.Atoi(value); err == nil && n >= 0 {
			cfg.WindowPaddingY = n
		}
	case "agent":
		cfg.Agent = value == "on" || value == "true"
	case "agent-model":
		if value != "" {
			cfg.AgentModel = value
		}
	case "agent-engine":
		if value != "" {
			cfg.AgentEngine = value
		}
	case "agent-daily-cap-usd":
		if f, err := strconv.ParseFloat(value, 64); err == nil && f >= 0 {
			cfg.AgentDailyCapUSD = f
		}
	case "jira-url":
		cfg.JiraURL = strings.TrimRight(value, "/")
	case "jira-email":
		cfg.JiraEmail = value
	case "jira-jql":
		cfg.JiraJQL = value
	case "coder":
		if value != "" {
			cfg.Coder = value
		}
	case "leader":
		if value != "" {
			cfg.Leader = value
		}
	case "workflow":
		cfg.Workflow = splitList(value)
	case "workspace-allow":
		cfg.WorkspaceAllow = splitList(value)
	case "keybind":
		// <trigger>=<command>; command ids never contain '=', so split
		// on the LAST '=' — that keeps "=" itself a bindable trigger and
		// makes `keybind = h=` (empty command) the unbind form.
		if i := strings.LastIndexByte(value, '='); i > 0 {
			if cfg.Keybinds == nil {
				cfg.Keybinds = map[string]string{}
			}
			trigger := normalizeLegacyTrigger(strings.TrimSpace(value[:i]))
			cfg.Keybinds[trigger] = strings.TrimSpace(value[i+1:])
		}
	}
}

// applyLSPKey applies one `lsp-<server>[-<attr>]` line; rest is the key
// past "lsp-". The known attribute suffixes are peeled first, so
// `lsp-gopls-filetypes` addresses server "gopls" — a server whose name
// itself ends in "-filetypes" is not expressible, accepted.
func applyLSPKey(cfg *Config, rest, value string, repoLayer bool) {
	server, attr := rest, ""
	for _, suf := range []string{"filetypes", "roots", "settings"} {
		if s, ok := strings.CutSuffix(rest, "-"+suf); ok && s != "" {
			server, attr = s, suf
			break
		}
	}
	if cfg.LSPServers == nil {
		cfg.LSPServers = map[string]LSPServer{}
	}
	s := cfg.LSPServers[server]
	switch attr {
	case "filetypes":
		s.Filetypes = splitList(value)
	case "roots":
		s.Roots = splitList(value)
	case "settings":
		s.Settings = value
	default: // the base key: a command line, or the off switch
		if value == "off" {
			s.Off, s.Command = true, ""
			break
		}
		if repoLayer {
			// Trust rule: a checked-in file may select and tune, but its
			// command lines are never exec'd. Record the refusal for status.
			if value != "" {
				cfg.LSPRefused = append(cfg.LSPRefused, "lsp-"+server+" = "+value)
			}
			return
		}
		// last-wins: a command line re-enables a server an earlier line
		// turned off; an empty value clears back to catalog-managed.
		s.Off, s.Command = false, value
	}
	cfg.LSPServers[server] = s
}

// normalizeLegacyTrigger rewrites the legacy flat file's implicit leader
// convention into the explicit notation the TOML format (and the frontend)
// speak: a bare key acted after the leader, so `h` becomes `<leader>h`.
// Modifier chords ("cmd+shift+k") fired directly and pass through — as
// does "+" itself, which the legacy parser treated as a bindable bare key.
func normalizeLegacyTrigger(trigger string) string {
	if strings.HasPrefix(strings.ToLower(trigger), "<leader>") {
		return trigger // already explicit, don't double-wrap
	}
	if strings.Contains(trigger, "+") && trigger != "+" {
		return trigger // a chord
	}
	return "<leader>" + trigger
}

// splitList parses a comma-separated config value: items trimmed, empties
// dropped. Always non-nil — "" is an empty list, not absence.
func splitList(s string) []string {
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

type Service struct{}

// Get re-reads the file on every call, so a page reload picks up edits
// without restarting the app.
func (s *Service) Get() Config {
	return Load()
}

// ---- OpenAI key management (the drafter's credential, docs/agent.md) ----
// The app writes ONLY to the keychain — the config file stays user-owned,
// ghostty-style. rook-agent reads keychain first, key file second.

// SetOpenAIKey stores the drafter's API key in the login keychain.
func (s *Service) SetOpenAIKey(key string) error {
	key = strings.TrimSpace(key)
	if key == "" {
		return errors.New("empty key")
	}
	return keychain.Set(keychain.Service, keychain.OpenAIAccount, key)
}

func (s *Service) ClearOpenAIKey() error {
	return keychain.Delete(keychain.Service, keychain.OpenAIAccount)
}

// JiraToken resolves the Jira API token: keychain first (service rook,
// account jira — set via `rookctl set-jira-token`), then the
// ~/.config/rook/jira-token file (must be 0600-tight, like the OpenAI
// fallback). "" means the Jira queue is off.
func JiraToken() string {
	if t, err := keychain.Get(keychain.Service, keychain.JiraAccount); err == nil && strings.TrimSpace(t) != "" {
		return strings.TrimSpace(t)
	}
	tokFile := filepath.Join(filepath.Dir(Path()), "jira-token")
	if st, err := os.Stat(tokFile); err != nil || st.Mode().Perm()&0o077 != 0 {
		return ""
	}
	data, err := os.ReadFile(tokFile)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// keyStatus reports where a usable secret lives: "keychain" if the keychain
// holds it, else "file" if a 0600-tight fallback file exists and is non-empty,
// else "". Shared by the OpenAI and Jira status methods.
func keyStatus(account, fileName string) string {
	if k, err := keychain.Get(keychain.Service, account); err == nil && k != "" {
		return "keychain"
	}
	f := filepath.Join(filepath.Dir(Path()), fileName)
	if st, err := os.Stat(f); err == nil && st.Mode().Perm()&0o077 == 0 && st.Size() > 0 {
		return "file"
	}
	return ""
}

// OpenAIKeyStatus reports where a usable key currently lives: "keychain",
// "file" (the ~/.config/rook/openai-key fallback), or "" for none.
func (s *Service) OpenAIKeyStatus() string {
	return keyStatus(keychain.OpenAIAccount, "openai-key")
}

// SetJiraToken stores the Jira API token in the login keychain (service rook,
// account jira). Entering it here — not on a shell — is why special characters
// like underscores survive.
func (s *Service) SetJiraToken(token string) error {
	token = strings.TrimSpace(token)
	if token == "" {
		return errors.New("empty token")
	}
	return keychain.Set(keychain.Service, keychain.JiraAccount, token)
}

func (s *Service) ClearJiraToken() error {
	return keychain.Delete(keychain.Service, keychain.JiraAccount)
}

// JiraTokenStatus reports where the token lives: "keychain", "file"
// (~/.config/rook/jira-token, 0600), or "" for none.
func (s *Service) JiraTokenStatus() string {
	return keyStatus(keychain.JiraAccount, "jira-token")
}

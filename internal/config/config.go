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
	// DashboardTab is the strip number the dashboard occupies; shell
	// windows number from the next one up (` <n> follows along).
	DashboardTab int `json:"dashboardTab"`
	// Agent settings (docs/agent.md): read by rook-agent, never by the
	// host — the host supervises the process, the process reads its own
	// policy. Off by default; the whole feature is opt-in.
	Agent            bool    `json:"agent"`
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
}

func Default() Config {
	return Config{
		FontFamily:        "Hack Nerd Font Mono",
		FontSize:          18,
		BackgroundOpacity: 0.95,
		WindowPaddingX:    4,
		WindowPaddingY:    4,
		DashboardTab:      1,
		Agent:             false,
		AgentModel:        "gpt-5.4-nano",
		AgentDailyCapUSD:  1.00,
		Coder:             "claude",
		Leader:            "`",
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
	path := Path()
	if path == "" {
		return cfg
	}
	f, err := os.Open(path)
	if err != nil {
		return cfg
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
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		// dynamic keys first — the switch below only knows fixed names
		if ws, ok := strings.CutPrefix(key, "jira-project-"); ok && ws != "" && value != "" {
			if cfg.JiraProjects == nil {
				cfg.JiraProjects = map[string]string{}
			}
			cfg.JiraProjects[ws] = value
			continue
		}
		// an EMPTY value is meaningful here: `branch-prefix-<ws> =` stores an
		// empty string — that workspace's branches carry no prefix (matching a
		// CI naming scheme exactly). A genuinely unset key falls back to rook/.
		if ws, ok := strings.CutPrefix(key, "branch-prefix-"); ok && ws != "" {
			if cfg.BranchPrefixes == nil {
				cfg.BranchPrefixes = map[string]string{}
			}
			cfg.BranchPrefixes[ws] = value
			continue
		}
		// likewise for workflows: `workflow-<ws> =` stores an empty non-nil
		// list — that workspace explicitly opts out of the global workflow.
		if ws, ok := strings.CutPrefix(key, "workflow-"); ok && ws != "" {
			if cfg.Workflows == nil {
				cfg.Workflows = map[string][]string{}
			}
			cfg.Workflows[ws] = splitList(value)
			continue
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
		case "window-padding-x":
			if n, err := strconv.Atoi(value); err == nil && n >= 0 {
				cfg.WindowPaddingX = n
			}
		case "window-padding-y":
			if n, err := strconv.Atoi(value); err == nil && n >= 0 {
				cfg.WindowPaddingY = n
			}
		case "dashboard-tab":
			if n, err := strconv.Atoi(value); err == nil && n >= 0 && n <= 8 {
				cfg.DashboardTab = n
			}
		case "agent":
			cfg.Agent = value == "on" || value == "true"
		case "agent-model":
			if value != "" {
				cfg.AgentModel = value
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
		case "keybind":
			// <trigger>=<command>; command ids never contain '=', so split
			// on the LAST '=' — that keeps "=" itself a bindable trigger and
			// makes `keybind = h=` (empty command) the unbind form.
			if i := strings.LastIndexByte(value, '='); i > 0 {
				if cfg.Keybinds == nil {
					cfg.Keybinds = map[string]string{}
				}
				cfg.Keybinds[strings.TrimSpace(value[:i])] = strings.TrimSpace(value[i+1:])
			}
		}
	}
	return cfg
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

// OpenAIKeyStatus reports where a usable key currently lives: "keychain",
// "file" (the ~/.config/rook/openai-key fallback), or "" for none.
func (s *Service) OpenAIKeyStatus() string {
	if k, err := keychain.Get(keychain.Service, keychain.OpenAIAccount); err == nil && k != "" {
		return "keychain"
	}
	keyFile := filepath.Join(filepath.Dir(Path()), "openai-key")
	if st, err := os.Stat(keyFile); err == nil && st.Mode().Perm()&0o077 == 0 && st.Size() > 0 {
		return "file"
	}
	return ""
}

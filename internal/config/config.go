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
		if ws, ok := strings.CutPrefix(key, "branch-prefix-"); ok && ws != "" && value != "" {
			if cfg.BranchPrefixes == nil {
				cfg.BranchPrefixes = map[string]string{}
			}
			cfg.BranchPrefixes[ws] = value
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
		}
	}
	return cfg
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

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

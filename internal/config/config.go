// Package config loads the rook config file: ghostty-style `key = value`
// lines at ~/.config/rook/config (XDG_CONFIG_HOME respected). Unknown keys
// are ignored, missing file means defaults, and defaults mirror the ghostty
// parity targets (docs/parity.md).
package config

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
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
}

func Default() Config {
	return Config{
		FontFamily:        "Hack Nerd Font Mono",
		FontSize:          18,
		BackgroundOpacity: 0.95,
		WindowPaddingX:    4,
		WindowPaddingY:    4,
		DashboardTab:      1,
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

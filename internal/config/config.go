// Package config loads rook's user configuration from
// ~/.config/rook/rook.toml (XDG_CONFIG_HOME respected). A missing file
// means defaults; a malformed file or an unrecognized key refuses to
// boot — a typo that silently falls back to defaults is how settings
// get lost.
//
// The file is rook.toml, not config.toml: that name is owned by the
// previous rook app and this rebuild never reads or writes it.
package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/BurntSushi/toml"
)

// Config is the whole user-facing configuration surface. Keys appear
// here when they earn a knob, not before.
type Config struct {
	Tmux      Tmux      `toml:"tmux"`
	Companion Companion `toml:"companion"`
}

// Companion is the resident summoned by prefix+key from anywhere: a
// popup over whatever you're doing, launched with rook context in its
// environment (ROOK_SESSION, ROOK_DIR, ROOK_PANE). Rook ships the
// slot; the config names the occupant — vera first.
type Companion struct {
	// Command runs inside the popup. Required for the slot to exist.
	Command string `toml:"command"`
	// Name labels the popup; defaults to the command's first word.
	Name string `toml:"name"`
	// Key is the prefix key that summons it; defaults to "a" (agent).
	// A key set here wins over rook's default bindings.
	Key string `toml:"key"`
}

// Tmux is the [tmux] table: the slice of rook settings that proxy into
// tmux options.
type Tmux struct {
	// Prefix is the tmux prefix key in tmux key syntax: "C-b", "C-a",
	// "`". Empty means rook's default.
	Prefix string `toml:"prefix"`

	// Plugins are tmux plugins as "owner/repo" GitHub specs, e.g.
	// "christoomey/vim-tmux-navigator". Rook clones and wires them
	// itself; there is no TPM.
	Plugins []string `toml:"plugins"`
}

// Path returns where the config file lives, whether or not it exists.
func Path() (string, error) {
	dir := os.Getenv("XDG_CONFIG_HOME")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		dir = filepath.Join(home, ".config")
	}
	return filepath.Join(dir, "rook", "rook.toml"), nil
}

// Load reads the config file at path. A missing file is not an error:
// it returns the zero Config, which means all defaults.
func Load(path string) (Config, error) {
	var c Config
	md, err := toml.DecodeFile(path, &c)
	if os.IsNotExist(err) {
		return Config{}, nil
	}
	if err != nil {
		return Config{}, fmt.Errorf("%s: %w", path, err)
	}
	if undecoded := md.Undecoded(); len(undecoded) > 0 {
		keys := make([]string, len(undecoded))
		for i, k := range undecoded {
			keys[i] = k.String()
		}
		return Config{}, fmt.Errorf("%s: unrecognized keys: %s (typo, or a newer rook?)",
			path, strings.Join(keys, ", "))
	}
	return c, nil
}

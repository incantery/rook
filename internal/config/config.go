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
	Worktree  Worktree  `toml:"worktree"`
	// Mux is the [mux] table: the engine's half of this file, which it
	// parses for itself (mux/README.md). Nothing here reads it — but an
	// unrecognized key refuses to boot, and one file with two readers
	// must not mean that either reader's keys break the other's.
	Mux map[string]any `toml:"mux"`
}

// Worktree is the [worktree] table: what a fresh worktree needs that git
// doesn't carry. Paths are repo-relative and apply to every repo; a
// path a repo doesn't have is skipped.
type Worktree struct {
	// Copy lists files copied from the main checkout (".env").
	Copy []string `toml:"copy"`
	// Link lists paths symlinked to the main checkout's ("node_modules").
	Link []string `toml:"link"`
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
	// Program is the foreground program that means "the companion is
	// open in this pane" — what the engine watches for so `rook
	// companion` and the state feed can say when and where she is.
	// Empty means the first word of Command (its basename), which is
	// right whenever the command is her binary; set it when that word
	// is a wrapper, or to "" to turn the slot off. Read by the engine,
	// declared here because this loader refuses keys it has not heard
	// of and one file cannot have two ideas of what is valid.
	Program string `toml:"program"`
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

// Package mux is the Go layer's client for the rook-mux engine. The
// CLI verbs are the stable interface; these are thin wrappers. Go
// never holds state the server doesn't.
package mux

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func bin() string {
	if p, err := exec.LookPath("rook-mux"); err == nil {
		return p
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "bin", "rook-mux")
}

func run(args ...string) (string, error) {
	out, err := exec.Command(bin(), args...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("rook-mux %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return string(out), nil
}

// Inside reports whether this process runs in a rook-mux pane.
func Inside() bool {
	return os.Getenv("ROOK_MUX_PANE") != ""
}

// SessionName derives a workspace name from a directory, the same
// rule the tmux era used, plus scrubbing the protocol's separators.
func SessionName(dir string) string {
	name := filepath.Base(dir)
	if name == "" || name == "/" || name == "." {
		return "rook"
	}
	return strings.NewReplacer(".", "_", ":", "_", "\t", "_", "\n", "_").Replace(name)
}

// Sessions lists workspace names; empty (not an error) when the
// server isn't running.
func Sessions() ([]string, error) {
	out, err := run("ls")
	if err != nil {
		return nil, nil
	}
	var names []string
	for _, l := range strings.Split(out, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			names = append(names, l)
		}
	}
	return names, nil
}

// Has reports whether a workspace by exactly this name exists.
func Has(name string) bool {
	names, _ := Sessions()
	for _, n := range names {
		if n == name {
			return true
		}
	}
	return false
}

// Open creates the workspace (first window in cwd) or switches to it
// when it already exists — the server dedupes by name.
func Open(name, cwd string) error {
	_, err := run("new", name, cwd)
	return err
}

// Switch makes the named workspace current.
func Switch(name string) error {
	_, err := run("switch", name)
	return err
}

// Close hangs up every pane in the workspace; the server reaps it.
// Best-effort: a stopped server means nothing to close.
func Close(name string) error {
	if !Has(name) {
		return nil
	}
	_, err := run("close", name)
	return err
}

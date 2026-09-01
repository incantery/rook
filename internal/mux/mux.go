// Package mux is the Go layer's client for the Zig engine. The CLI
// verbs are the stable interface; these are thin wrappers. Go never
// holds state the server doesn't.
package mux

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// EngineEnv names an explicit engine binary, for a dev build you have
// not installed: ROOK_ENGINE=mux/zig-out/bin/engine rook ls.
const EngineEnv = "ROOK_ENGINE"

// engineRel is where the engine lives relative to the directory the
// rook binary is installed in: ~/.local/bin/rook → ~/.local/libexec/
// rook/engine. Deliberately off $PATH — there is one command, and it
// is rook; the engine is an implementation detail nobody types.
var engineRel = []string{"..", "libexec", "rook", "engine"}

// EnginePath locates the engine binary: $ROOK_ENGINE first, then
// libexec beside whichever rook/rookd is running (symlinks resolved),
// then the default under ~/.local. The last is returned even when
// nothing is there, so the caller's exec reports the path it wanted.
func EnginePath() string {
	exe, err := os.Executable()
	if err != nil {
		exe = ""
	}
	home, _ := os.UserHomeDir()
	return enginePath(os.Getenv(EngineEnv), exe, home)
}

// enginePath is EnginePath with its three inputs handed in.
func enginePath(env, exe, home string) string {
	if env != "" {
		return env
	}
	var dirs []string
	if exe != "" {
		dirs = append(dirs, filepath.Dir(exe))
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			if d := filepath.Dir(real); d != dirs[0] {
				dirs = append(dirs, d)
			}
		}
	}
	for _, d := range dirs {
		if cand := beside(d); exists(cand) {
			return cand
		}
	}
	return beside(filepath.Join(home, ".local", "bin"))
}

// beside maps a bin directory to the engine under its libexec sibling.
func beside(bindir string) string {
	return filepath.Clean(filepath.Join(append([]string{bindir}, engineRel...)...))
}

func exists(path string) bool {
	st, err := os.Stat(path)
	return err == nil && !st.IsDir()
}

func run(args ...string) (string, error) {
	out, err := exec.Command(EnginePath(), args...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("engine %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return string(out), nil
}

// Inside reports whether this process runs in a rook pane.
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

// Current is the workspace the person is standing in, off the state
// snapshot the engine already publishes. Empty (not an error) when
// the server isn't running or the snapshot names no current
// workspace: a picker that cannot say where you are still opens.
func Current() string {
	out, err := run("state")
	if err != nil {
		return ""
	}
	return currentFrom(out)
}

// currentFrom reads the workspace marked current out of one state
// snapshot. It picks the fields it needs and ignores the rest, which
// is how a reader survives a newer schema (see docs/surfaces.md).
func currentFrom(snapshot string) string {
	var s struct {
		Workspaces []struct {
			Name    string `json:"name"`
			Current bool   `json:"current"`
		} `json:"workspaces"`
	}
	if json.Unmarshal([]byte(snapshot), &s) != nil {
		return ""
	}
	for _, w := range s.Workspaces {
		if w.Current {
			return w.Name
		}
	}
	return ""
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

// Companion is what the engine knows about the companion — the one
// resident rook watches for by name (vera first). Rook publishes it;
// this is the replica, and nothing here is held between calls.
type Companion struct {
	// Name is the program rook watches for.
	Name string `json:"name"`
	// Open, Visible, Focused are the rollups: any pane running it, any
	// of them on the glass, any of them holding the keyboard.
	Open    bool            `json:"open"`
	Visible bool            `json:"visible"`
	Focused bool            `json:"focused"`
	Panes   []CompanionPane `json:"panes"`
}

// CompanionPane is one pane running the companion: where it is, and
// since when.
type CompanionPane struct {
	Pane int `json:"pane"`
	// Workspace is empty for a globally pinned pane — it belongs to
	// every workspace, so it is named by its place instead.
	Workspace string `json:"workspace"`
	// Window is 1-based, nil when the pane is not in a window at all
	// (the rail and the popup are above windows).
	Window  *int   `json:"window"`
	Place   string `json:"place"`
	Visible bool   `json:"visible"`
	Focused bool   `json:"focused"`
	// Since is epoch ms, wall clock: when rook first saw this pane
	// running the companion.
	Since int64 `json:"since"`
}

// CompanionState asks the engine where the companion is. A nil
// Companion means the slot is off (the config named none) or the
// server isn't running — in both, rook knows of no companion, which
// is the same answer to the caller.
func CompanionState() *Companion {
	out, err := run("state")
	if err != nil {
		return nil
	}
	return companionFrom(out)
}

// companionFrom reads the companion out of one state snapshot. It
// picks the fields it needs and ignores the rest, which is how a
// reader survives a newer schema (see docs/surfaces.md).
func companionFrom(snapshot string) *Companion {
	var s struct {
		Companion *Companion `json:"companion"`
	}
	if json.Unmarshal([]byte(snapshot), &s) != nil {
		return nil
	}
	return s.Companion
}

// CompanionJSON is the same answer as rook's own bytes: the companion
// object out of the snapshot, verbatim, so a consumer sees every
// field this Go struct does not know about. "null" when there is no
// companion to speak of.
func CompanionJSON() string {
	out, err := run("state")
	if err != nil {
		return "null"
	}
	return companionJSON(out)
}

func companionJSON(snapshot string) string {
	var s struct {
		Companion json.RawMessage `json:"companion"`
	}
	if json.Unmarshal([]byte(snapshot), &s) != nil || len(s.Companion) == 0 {
		return "null"
	}
	return string(s.Companion)
}

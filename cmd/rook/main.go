// Command rook is the front door to the rook multiplexer. Bare `rook`
// attaches at rook's home (rookd keeps the server alive; attach boots
// one if needed); `rook .` and `rook --space <name>` land in a space.
// Mux verbs pass straight through to the Zig engine, which lives off
// $PATH and is an implementation detail users never type. Worktrees
// and the web URL live here in the Go layer.
package main

import (
	_ "embed"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/incantery/rook/internal/mux"
)

// The skill: how an agent inside a pane drives rook. Printed by
// `rook --skill`, the same way herdr and cmux hand theirs over — a
// program that can read its own manual is one nobody has to teach.
//
//go:embed skill.md
var skill string

// Build metadata, stamped by the linker at release time.
var (
	version = "dev"
	commit  = ""
	date    = ""
)

func versionLine() string {
	s := "rook " + version
	if commit != "" {
		c := commit
		if len(c) > 7 {
			c = c[:7]
		}
		s += " (" + c
		if date != "" {
			s += ", " + date
		}
		s += ")"
	}
	return s
}

const usage = `rook — the multiplexer, owned

  rook                    rook's home: intent, attention, work, spaces
                          (starts the server if rookd hasn't)
  rook .                  the space for this directory, made if it must be
  rook --space <name>     that space (made here if it must be)
  rook home               rook's home, said outright
  rook attach [--root | --space <name> [--cwd DIR]]   the exact form of the three above
  rook ls                 list workspaces
  rook new <name>         create/switch workspace
  rook switch <name>      switch workspace
  rook pick               pick a workspace (fzf; prefix-s floats this)
  rook blocks             the block table (stable ids)
  rook raw <id>           this terminal becomes one block, no chrome
  rook state | watch      the state feed: one snapshot, or one per change
  rook read <id> [-n N]   a pane as plain text: the viewport, or its last N lines
                          (capture is the same verb, viewport only)
  rook send|run|key <id> …  type into a pane (run adds Enter; key names keys)
  rook wait <id> --match S | --quiet MS [--timeout MS]
  rook split|window <id> [--down] [--focus] [--cwd DIR]
  rook focus <id> | jump  bring a pane forward; jump = the oldest unread one
  rook close-pane <id>    hang a pane up
  rook resume <id> <cmd>  how to bring the pane's program back after a restart
  rook own <id> <actor> | --paused <actor> | --release | --request | --take
                          who holds a pane's keyboard (docs/altitude.md)
  rook rename <name>      name the current tab; rook never renames it again
  rook side [-|demo]      push the side rail's model (JSON frames on stdin)
  rook companion [--json] where the companion (vera) is open, if she is
  rook popup <cmd...>     float a command over the current window
  rook nav h|j|k|l        move focus (vim plugins call this at edges)
  rook stats | kill       server introspection / shutdown
  rook url                the web client URL (token included)
  rook worktree ...       git worktrees (ls|new|open|merge|rm)
  rook skill [--install]  the skill for an agent inside a pane; --install puts it
                          where Claude Code finds it (~/.claude/skills/rook)
  rook version

  <id> is a pane number from "rook blocks", or . for the pane you are in.

Are you an AI? "rook --skill" prints how to drive rook from inside a pane;
docs/surfaces.md in the repo is the state feed and the rail, in full.
`

// verbs the Zig engine owns; rook execs into it verbatim.
var muxVerbs = map[string]bool{
	"server": true, "stats": true, "kill": true, "nav": true,
	"popup": true, "ls": true, "switch": true, "new": true,
	"blocks": true, "raw": true,
	// the state feed (out) and the side rail's model (in)
	"state": true, "watch": true, "capture": true, "side": true,
	// a pane, by id: read it, type into it, wait on it, open beside it
	"read": true, "send": true, "run": true, "key": true, "wait": true,
	"split": true, "window": true, "focus": true, "jump": true, "close-pane": true,
	"resume": true,
	// input ownership, and the one act that changes a minted tab name
	"own": true, "rename": true,
	// where a glass lands: the exact form behind `rook .` and `--space`
	"attach": true,
}

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		execMux(nil)
	}
	var err error
	switch {
	case args[0] == ".":
		// The space for this directory: named the way `rook new` would
		// name it, started here if rook does not hold one yet.
		execMux(attachArgs(spaceArgs(args[1:])))
	case args[0] == "--space", args[0] == "-s":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "rook: --space needs a name")
			os.Exit(1)
		}
		execMux(attachArgs(append([]string{"--space", args[1]}, args[2:]...)))
	case args[0] == "home", args[0] == "--home", args[0] == "--root":
		execMux([]string{"attach", "--root"})
	case args[0] == "version", args[0] == "--version", args[0] == "-v":
		fmt.Println(versionLine())
	case args[0] == "help", args[0] == "--help", args[0] == "-h":
		fmt.Print(usage)
	case args[0] == "--skill", args[0] == "skill":
		err = runSkill(args[1:])
	case args[0] == "worktree", args[0] == "wt":
		err = runWorktree(args[1:])
	case args[0] == "pick":
		err = runPick()
	case args[0] == "companion":
		err = runCompanion(args[1:])
	case args[0] == "url":
		err = runURL()
	case muxVerbs[args[0]]:
		execMux(args)
	default:
		fmt.Fprintf(os.Stderr, "rook: unknown command %q\n%s", args[0], usage)
		os.Exit(1)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "rook:", err)
		os.Exit(1)
	}
}

// spaceArgs is `rook .`: the space named for the working directory,
// seeded there. A directory rook already holds a space for is simply
// entered; `--cwd` is only where a new one starts.
func spaceArgs(rest []string) []string {
	cwd, err := os.Getwd()
	if err != nil {
		cwd = ""
	}
	return append([]string{"--space", mux.SessionName(cwd), "--cwd", cwd}, rest...)
}

// attachArgs is the engine's exact spelling of a destination. Every
// `--space` carries the directory to start in, so a name rook does
// not hold yet becomes a space rooted where the person stood.
func attachArgs(flags []string) []string {
	out := []string{"attach"}
	hasCwd := false
	for _, f := range flags {
		if f == "--cwd" {
			hasCwd = true
		}
	}
	out = append(out, flags...)
	if !hasCwd {
		if cwd, err := os.Getwd(); err == nil {
			out = append(out, "--cwd", cwd)
		}
	}
	return out
}

// execMux replaces this process with the Zig engine.
func execMux(args []string) {
	bin := mux.EnginePath()
	argv := append([]string{filepath.Base(bin)}, args...)
	if err := syscall.Exec(bin, argv, os.Environ()); err != nil {
		fmt.Fprintf(os.Stderr, "rook: cannot exec the engine at %s: %v\n"+
			"    install it with `make -C mux install`, or point %s at a build\n", bin, err, mux.EngineEnv)
		os.Exit(1)
	}
}

// runURL prints the web client URL(s) with the persisted token — the
// thing you type into a new device exactly once.
func runURL() error {
	home, _ := os.UserHomeDir()
	tok, err := os.ReadFile(filepath.Join(home, ".local", "state", "rook", "web-token"))
	if err != nil {
		return fmt.Errorf("no web token yet — is rookd running? (%w)", err)
	}
	token := strings.TrimSpace(string(tok))
	fmt.Printf("http://localhost:7673/?token=%s\n", token)
	ifaces, _ := net.InterfaceAddrs()
	for _, a := range ifaces {
		ipn, ok := a.(*net.IPNet)
		if !ok || ipn.IP.To4() == nil || ipn.IP.IsLoopback() {
			continue
		}
		fmt.Printf("http://%s:7673/?token=%s\n", ipn.IP, token)
	}
	return nil
}

// runSkill prints the skill, or installs it where Claude Code loads
// user skills from. The binary is the one source: the installed file
// is a copy, stamped as one, and installing again overwrites it.
func runSkill(args []string) error {
	if len(args) == 0 {
		fmt.Print(skill)
		return nil
	}
	if len(args) != 1 || args[0] != "--install" {
		return fmt.Errorf("usage: rook skill [--install]")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	dir := filepath.Join(home, ".claude", "skills", "rook")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	path := filepath.Join(dir, "SKILL.md")
	if err := os.WriteFile(path, []byte(installedSkill(skill, versionLine())), 0o644); err != nil {
		return err
	}
	fmt.Println("rook: skill installed at", path)
	return nil
}

// installedSkill is the skill with one line after its front matter
// saying where it came from, so a reader of the file knows not to
// edit it there.
func installedSkill(body, from string) string {
	const fence = "---\n"
	// front matter: the first fence opens it, the second closes it
	end := strings.Index(body[len(fence):], fence)
	if !strings.HasPrefix(body, fence) || end < 0 {
		return body
	}
	cut := len(fence) + end + len(fence)
	return body[:cut] + "\n<!-- generated by `rook skill --install` (" + from + "); edit cmd/rook/skill.md in the rook repo instead -->\n" + body[cut:]
}

// Command rook is the front door to the rook multiplexer. Bare `rook`
// attaches (rookd keeps the server alive; attach boots one if needed).
// Mux verbs pass straight through to the Zig engine, which lives off
// $PATH and is an implementation detail users never type. Worktrees
// and the web URL live here in the Go layer.
package main

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/incantery/rook/internal/mux"
)

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

  rook                    attach (starts the server if rookd hasn't)
  rook ls                 list workspaces
  rook new <name>         create/switch workspace
  rook switch <name>      switch workspace
  rook pick               pick a workspace (fzf; prefix-s floats this)
  rook blocks             the block table (stable ids)
  rook raw <id>           this terminal becomes one block, no chrome
  rook state | watch      the state feed: one snapshot, or one per change
  rook capture <id>       one pane's viewport as plain text
  rook side [-|demo]      push the side rail's model (JSON frames on stdin)
  rook popup <cmd...>     float a command over the current window
  rook nav h|j|k|l        move focus (vim plugins call this at edges)
  rook stats | kill       server introspection / shutdown
  rook url                the web client URL (token included)
  rook worktree ...       git worktrees (ls|new|open|merge|rm)
  rook version
`

// verbs the Zig engine owns; rook execs into it verbatim.
var muxVerbs = map[string]bool{
	"server": true, "stats": true, "kill": true, "nav": true,
	"popup": true, "ls": true, "switch": true, "new": true,
	"blocks": true, "raw": true,
	// the state feed (out) and the side rail's model (in)
	"state": true, "watch": true, "capture": true, "side": true,
}

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		execMux(nil)
	}
	var err error
	switch {
	case args[0] == "version", args[0] == "--version", args[0] == "-v":
		fmt.Println(versionLine())
	case args[0] == "help", args[0] == "--help", args[0] == "-h":
		fmt.Print(usage)
	case args[0] == "worktree", args[0] == "wt":
		err = runWorktree(args[1:])
	case args[0] == "pick":
		err = runPick()
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

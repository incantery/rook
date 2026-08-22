// Command rook boots an opinionated tmux session: run it in place of
// `tmux` and you are attached to a session named after the current
// directory, on a rook-owned server that never loads the user's
// tmux.conf. The multiplexer, the session manager and the jump list are
// dependencies, not rewrites.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"

	"github.com/incantery/rook/internal/agents"
	"github.com/incantery/rook/internal/attention"
	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/sessions"
	"github.com/incantery/rook/internal/tmux"
)

// Build metadata, stamped by the linker at release time (see
// .goreleaser.yaml and the Makefile). "dev" when built without them.
var (
	version = "dev"
	commit  = ""
	date    = ""
)

// versionLine renders "rook <version>", appending a short commit and date
// when the linker stamped them.
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

func main() {
	args := os.Args[1:]
	var err error
	switch {
	case len(args) == 0:
		err = run()
	case args[0] == "version", args[0] == "--version", args[0] == "-v":
		fmt.Println(versionLine())
	case args[0] == "ls":
		filter, asJSON := "", false
		for _, a := range args[1:] {
			if a == "--json" {
				asJSON = true
			} else {
				filter = a
			}
		}
		if asJSON {
			err = sessions.ListJSON(filter)
		} else {
			err = sessions.List(filter)
		}
	case args[0] == "sweep":
		err = sessions.Sweep()
	case args[0] == "paneline":
		dir, active := "", false
		if len(args) > 1 {
			dir = args[1]
		}
		if len(args) > 2 && args[2] == "1" {
			active = true
		}
		err = sessions.PaneLine(dir, active)
	case args[0] == "claude-hook":
		attention.HandleClaudeHook(os.Stdin)
	case args[0] == "attention":
		items := attention.Load()
		if len(args) > 1 && args[1] == "--bar" {
			fmt.Print(attention.Bar(items))
		} else {
			for _, it := range items {
				fmt.Printf("%-8s %-20s %s\n", it.Kind, it.Session+it.Dir, it.Headline)
			}
		}
	case args[0] == "connect":
		err = sessions.Connect(strings.Join(args[1:], " "))
	case args[0] == "preview":
		err = sessions.Preview(strings.Join(args[1:], " "))
	case args[0] == "agents":
		switch {
		case len(args) > 1 && args[1] == "side":
			pane := ""
			if len(args) > 2 {
				pane = args[2]
			}
			err = agents.Side(pane)
		case len(args) > 2 && args[1] == "sync":
			err = agents.Sync(args[2])
		case len(args) > 1 && args[1] == "--side":
			err = agents.Run(true)
		case len(args) > 1 && args[1] == "--json":
			enc := json.NewEncoder(os.Stdout)
			for _, a := range sessions.Agents() {
				if err = enc.Encode(a); err != nil {
					break
				}
			}
		default:
			err = agents.Run(false)
		}
	case args[0] == "worktree", args[0] == "wt":
		err = runWorktree(args[1:])
	default:
		err = fmt.Errorf("unknown command %q (rook | rook ls [-t|-z] | rook connect <row> | rook preview <row> | rook worktree … | rook agents | rook version)", args[0])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "rook:", err)
		os.Exit(1)
	}
}

func run() error {
	if os.Getenv("TMUX") != "" {
		return fmt.Errorf("already inside a tmux session; nesting comes later")
	}

	cfgPath, err := config.Path()
	if err != nil {
		return err
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		return err
	}

	settings := tmux.Defaults()
	if cfg.Tmux.Prefix != "" {
		settings.Prefix = cfg.Tmux.Prefix
	}
	if cfg.Companion.Command != "" {
		settings.Companion = tmux.Companion{
			Command: cfg.Companion.Command,
			Name:    cfg.Companion.Name,
			Key:     cfg.Companion.Key,
		}
		if settings.Companion.Name == "" {
			settings.Companion.Name = strings.Fields(cfg.Companion.Command)[0]
		}
		if settings.Companion.Key == "" {
			settings.Companion.Key = "a"
		}
		if _, err := exec.LookPath(strings.Fields(cfg.Companion.Command)[0]); err != nil {
			fmt.Fprintf(os.Stderr, "rook: companion %q: %s not on PATH — prefix %s will fail\n",
				settings.Companion.Name, strings.Fields(cfg.Companion.Command)[0], settings.Companion.Key)
		}
	}

	scripts, warnings := tmux.EnsurePlugins(cfg.Tmux.Plugins)
	for _, w := range warnings {
		fmt.Fprintln(os.Stderr, "rook:", w)
	}
	settings.PluginScripts = scripts

	// The prefix-s session picker rides on these; missing ones should
	// say so at boot, not fail silently inside a popup.
	for _, dep := range []string{"zoxide", "fzf"} {
		if _, err := exec.LookPath(dep); err != nil {
			fmt.Fprintf(os.Stderr, "rook: %s not on PATH — the session picker (prefix s) needs it (`brew install %s`)\n", dep, dep)
		}
	}

	confPath, err := tmux.WriteConf(settings)
	if err != nil {
		return fmt.Errorf("writing tmux conf: %w", err)
	}

	cwd, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("getwd: %w", err)
	}

	// new-session -A attaches when the session already exists.
	argv, err := tmux.Argv(confPath, "new-session", "-A", "-s", tmux.SessionName(cwd), "-c", cwd)
	if err != nil {
		return err
	}

	// Replace this process: the terminal belongs to tmux now.
	return syscall.Exec(argv[0], argv, os.Environ())
}

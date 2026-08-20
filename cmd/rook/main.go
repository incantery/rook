// Command rook boots an opinionated tmux session: run it in place of
// `tmux` and you are attached to a session named after the current
// directory, on a rook-owned server that never loads the user's
// tmux.conf. The multiplexer, the session manager and the jump list are
// dependencies, not rewrites.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"

	"github.com/incantery/rook/internal/attention"
	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/sessions"
	"github.com/incantery/rook/internal/tmux"
)

func main() {
	args := os.Args[1:]
	var err error
	switch {
	case len(args) == 0:
		err = run()
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
	default:
		err = fmt.Errorf("unknown command %q (rook | rook ls [-t|-z] | rook connect <row> | rook preview <row>)", args[0])
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

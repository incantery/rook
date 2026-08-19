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
	"syscall"

	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/tmux"
)

func main() {
	if err := run(); err != nil {
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

	scripts, warnings := tmux.EnsurePlugins(cfg.Tmux.Plugins)
	for _, w := range warnings {
		fmt.Fprintln(os.Stderr, "rook:", w)
	}
	settings.PluginScripts = scripts

	// The prefix-s session picker rides on these; missing ones should
	// say so at boot, not fail silently inside a popup.
	for _, dep := range []string{"sesh", "zoxide", "fzf"} {
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

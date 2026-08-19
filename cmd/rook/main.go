// Command rook boots an opinionated tmux session: run it in place of
// `tmux` and you are attached to a session named after the current
// directory, on a rook-owned server that never loads the user's
// tmux.conf. The multiplexer, the session manager and the jump list are
// dependencies, not rewrites.
package main

import (
	"fmt"
	"os"
	"syscall"

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

	confPath, err := tmux.WriteConf(tmux.Defaults())
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

package tmux

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Run executes one tmux command against the rook server, conf included
// so a down server boots as rook, never as stock tmux. Combined output
// comes back either way so callers can show tmux's complaint.
func Run(cmd ...string) (string, error) {
	argv, err := RunArgv(cmd...)
	if err != nil {
		return "", err
	}
	out, err := exec.Command(argv[0], argv[1:]...).CombinedOutput()
	return string(out), err
}

// RunArgv is Run's argv without running it — for callers that exec into
// tmux (attach) rather than ask it a question. It writes the default
// conf when none exists yet.
func RunArgv(cmd ...string) ([]string, error) {
	confPath, err := ConfPath()
	if err != nil {
		return nil, err
	}
	if _, err := os.Stat(confPath); err != nil {
		if _, err := WriteConf(Defaults()); err != nil {
			return nil, err
		}
	}
	return Argv(confPath, cmd...)
}

// InsideRook reports whether this process runs in a client of the rook
// server — not merely inside some tmux. $TMUX is "socket-path,pid,index";
// only a matching socket means switch-client has a client to switch.
func InsideRook() bool {
	env := os.Getenv("TMUX")
	if env == "" {
		return false
	}
	sock, _, _ := strings.Cut(env, ",")
	return filepath.Base(sock) == SocketName()
}

// HasSession reports whether the rook server has a session by exactly
// this name.
func HasSession(name string) bool {
	_, err := Run("has-session", "-t", "="+name)
	return err == nil
}

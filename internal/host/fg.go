package host

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

// fgOf names the foreground process on a session's tty — what the user is
// actually running ("zsh", "claude", "nvim"). tcgetpgrp on the pty master
// gives the foreground process group; naming its leader is close enough.
// This is a shared sensor: the dashboard shows it, and the attention router
// (docs/agent.md) will key off it to find agent sessions.
func fgOf(pty *os.File, fallbackPid int) string {
	pid, err := unix.IoctlGetInt(int(pty.Fd()), unix.TIOCGPGRP)
	if err != nil || pid <= 0 {
		pid = fallbackPid
	}
	ps := "/bin/ps"
	if _, err := os.Stat(ps); err != nil {
		if p, perr := exec.LookPath("ps"); perr == nil {
			ps = p
		}
	}
	out, err := exec.Command(ps, "-o", "comm=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return ""
	}
	// login shells report as "-zsh"
	return strings.TrimPrefix(filepath.Base(strings.TrimSpace(string(out))), "-")
}

package host

import (
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// fgOf names the foreground process on a session's tty — what the user is
// actually running ("zsh", "claude", "nvim"). tcgetpgrp on the pty master
// gives the foreground process group; naming its leader is close enough.
// This is a shared sensor: the dashboard shows it, and the attention router
// (docs/agent.md) will key off it to find agent sessions.
//
// The ioctl is free; naming the pid used to cost a `ps` fork per call, and
// /attention multiplied that by session count three times over at 2-5s. The
// name now comes from the batched table every other sensor reads
// (procsample.go).
func (h *Host) fgOf(pty *os.File, fallbackPid int) string {
	pid, err := unix.IoctlGetInt(int(pty.Fd()), unix.TIOCGPGRP)
	if err != nil || pid <= 0 {
		pid = fallbackPid
	}
	comm := h.pt.comm(pid)
	if comm == "" {
		return ""
	}
	// login shells report as "-zsh"
	return strings.TrimPrefix(filepath.Base(comm), "-")
}

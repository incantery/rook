package host

import (
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// fgPgrp is the foreground process group on a session's tty, or 0 when the
// tty can't say. Just the ioctl — no name, no proc table, nothing batched —
// so it is cheap enough to call on an actuation path.
func fgPgrp(pty *os.File) int {
	pid, err := unix.IoctlGetInt(int(pty.Fd()), unix.TIOCGPGRP)
	if err != nil || pid <= 0 {
		return 0
	}
	return pid
}

// fgOf names the foreground process on a session's tty — what the user is
// actually running ("zsh", "claude", "nvim"). tcgetpgrp on the pty master
// gives the foreground process group; naming its leader is close enough.
// The ioctl is free; naming the pid used to cost a `ps` fork per call,
// multiplied by session count by every poller that wanted it. Those
// pollers left in the strip, but the batching stays — it is the shape
// that keeps idle cost flat in window count (procsample.go).
func (h *Host) fgOf(pty *os.File, fallbackPid int) string {
	pid := fgPgrp(pty)
	if pid <= 0 {
		pid = fallbackPid
	}
	comm := h.pt.comm(pid)
	if comm == "" {
		return ""
	}
	// login shells report as "-zsh"
	return strings.TrimPrefix(filepath.Base(comm), "-")
}

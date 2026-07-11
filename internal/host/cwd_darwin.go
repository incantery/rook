package host

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// cwdOf returns the working directory of a process, or "" if it can't be
// determined. lsof is slow (~100ms) but this only runs on session create,
// to implement tmux's `new-window -c "#{pane_current_path}"`.
func cwdOf(pid int) string {
	// Absolute path first: the daemon may run under launchd's minimal
	// environment where PATH lookups are not to be trusted.
	lsof := "/usr/sbin/lsof"
	if _, err := os.Stat(lsof); err != nil {
		if p, perr := exec.LookPath("lsof"); perr == nil {
			lsof = p
		}
	}
	out, err := exec.Command(lsof, "-a", "-p", strconv.Itoa(pid), "-d", "cwd", "-Fn").Output()
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		if path, ok := strings.CutPrefix(line, "n"); ok {
			return path
		}
	}
	return ""
}

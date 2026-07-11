package host

import (
	"os/exec"
	"strconv"
	"strings"
)

// cwdOf returns the working directory of a process, or "" if it can't be
// determined. lsof is slow (~100ms) but this only runs on session create,
// to implement tmux's `new-window -c "#{pane_current_path}"`.
func cwdOf(pid int) string {
	out, err := exec.Command("lsof", "-a", "-p", strconv.Itoa(pid), "-d", "cwd", "-Fn").Output()
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

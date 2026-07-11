//go:build !darwin

package host

import (
	"fmt"
	"os"
)

func cwdOf(pid int) string {
	path, err := os.Readlink(fmt.Sprintf("/proc/%d/cwd", pid))
	if err != nil {
		return ""
	}
	return path
}

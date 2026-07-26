//go:build darwin

package host

import "golang.org/x/sys/unix"

// The termios get/set ioctl requests are spelled differently per platform —
// BSD/darwin calls them TIOCGETA/TIOCSETA, Linux TCGETS/TCSETS. The framed
// tests only need to drop ICANON|ECHO on a test tty, so they name the pair
// and let the build pick the spelling. Without this the whole package failed
// to typecheck on Linux, which is every CI run.
const (
	tcGetAttr = unix.TIOCGETA
	tcSetAttr = unix.TIOCSETA
)

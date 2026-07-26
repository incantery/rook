//go:build linux

package host

import "golang.org/x/sys/unix"

// Linux's spelling of the pair documented in termios_darwin_test.go.
const (
	tcGetAttr = unix.TCGETS
	tcSetAttr = unix.TCSETS
)

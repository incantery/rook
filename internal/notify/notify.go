// Package notify posts macOS user notifications for the attention router:
// "«workspace» window N needs you". osascript is deliberately boring — no
// entitlements, no UNUserNotification delegate, works from a dev build.
package notify

import (
	"fmt"
	"os/exec"
	"strings"
)

type Service struct{}

// esc keeps titles/bodies from breaking out of the AppleScript string
// literal (quotes and backslashes are the only special characters there).
func esc(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	return strings.ReplaceAll(s, `"`, `\"`)
}

func (s *Service) Notify(title, body string) error {
	script := fmt.Sprintf(`display notification "%s" with title "%s"`, esc(body), esc(title))
	return exec.Command("osascript", "-e", script).Run()
}

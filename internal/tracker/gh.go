// Package tracker is what is LEFT of the issue-queue plumbing after the
// trackers themselves became providers (internal/provider): the gh CLI
// runner and the branch→PR lookup that rides it.
//
// This is code-host territory, not tracker territory — a Linear-tracked
// repo still merges through GitHub — which is why it survived the move.
// It is next to leave: `pulls.status` is the second capability
// rook-provider-github should offer, at which point prwatch.go asks the
// provider and this package is deleted.
package tracker

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// findGH resolves the CLI: PATH first, then the conventional install
// spots — the daemon inherits launchd's minimal PATH, not the shell's.
var findGH = sync.OnceValue(func() string {
	if p, err := exec.LookPath("gh"); err == nil {
		return p
	}
	home, _ := os.UserHomeDir()
	for _, p := range []string{
		"/opt/homebrew/bin/gh",
		"/usr/local/bin/gh",
		filepath.Join(home, ".local", "bin", "gh"),
	} {
		if st, err := os.Stat(p); err == nil && st.Mode()&0o111 != 0 {
			return p
		}
	}
	return ""
})

func runGH(dir string, args ...string) (string, error) {
	gh := findGH()
	if gh == "" {
		return "", fmt.Errorf("gh not installed")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, gh, args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if len(msg) > 200 {
			msg = msg[:200]
		}
		if msg == "" {
			msg = err.Error()
		}
		return "", fmt.Errorf("gh %s: %s", args[0], msg)
	}
	return string(out), nil
}

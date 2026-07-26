// The daemon inherits its parent's environment, and when the parent is the
// .app launched from Finder that PATH is the GUI default (/usr/bin:/bin:…) —
// no homebrew, no go, no npm. Everything the host execs sees it: git, gh,
// claude, plugin installs, and the language servers themselves (gopls shells
// out to `go` to load packages). So the host resolves the login shell's PATH
// once at boot and ADOPTS the entries it doesn't already have.
//
// Two deliberate choices:
//   - login, NOT interactive (-l without -i): rc files alias tools lazily
//     (nvm's npm is an alias until sourced) and print banners; profiles are
//     where PATH actually lives, and zsh -l reads .zprofile — where brew
//     shellenv sits.
//   - APPEND, never prepend: a harness that puts shim binaries first on
//     PATH (the e2e/verify sandboxes' fake claude) must keep winning; a
//     terminal-launched host already has everything and merges to a no-op.
//
// Fail open on any error — the inherited PATH stays.

package host

import (
	"context"
	"log"
	"os"
	"os/exec"
	"strings"
	"time"
)

const loginPathTimeout = 5 * time.Second

// AdoptLoginPATH merges the login shell's PATH into this process's PATH.
// Called once from rook-host's main before anything execs.
func AdoptLoginPATH() {
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/zsh"
	}
	ctx, cancel := context.WithTimeout(context.Background(), loginPathTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, shell, "-l", "-c", "command printenv PATH").Output()
	if err != nil {
		log.Printf("host: login PATH resolution failed, keeping inherited: %v", err)
		return
	}
	login := lastNonEmptyLine(string(out))
	if !strings.Contains(login, "/") {
		return // a profile that echoes garbage must not replace anything
	}
	merged := mergePaths(os.Getenv("PATH"), login)
	if merged != os.Getenv("PATH") {
		if err := os.Setenv("PATH", merged); err != nil {
			log.Printf("host: PATH from %s login shell rejected: %v", shell, err)
			return
		}
		log.Printf("host: PATH adopted from %s login shell", shell)
	}
}

// mergePaths keeps cur's entries in place and appends login's entries that
// cur doesn't already have. Empty segments drop.
func mergePaths(cur, login string) string {
	var out []string
	seen := map[string]bool{}
	for p := range strings.SplitSeq(cur+":"+login, ":") {
		if p == "" || seen[p] {
			continue
		}
		seen[p] = true
		out = append(out, p)
	}
	return strings.Join(out, ":")
}

// lastNonEmptyLine survives profiles that print before the PATH does.
func lastNonEmptyLine(s string) string {
	lines := strings.Split(s, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if t := strings.TrimSpace(lines[i]); t != "" {
			return t
		}
	}
	return ""
}

package host

import (
	"context"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// GitInfo is the shallow repo status shown on the workspace dashboard —
// and, later, part of the structured context the agent reads.
type GitInfo struct {
	Branch string `json:"branch"`
	Dirty  int    `json:"dirty"`
	Ahead  int    `json:"ahead"`
	Behind int    `json:"behind"`
}

// gitInfo probes dir's repo with a hard timeout; nil means not a repo (or
// git took too long — a status endpoint must never hang on a slow disk).
func gitInfo(dir string) *GitInfo {
	if dir == "" {
		return nil
	}
	git, err := exec.LookPath("git")
	if err != nil {
		git = "/usr/bin/git"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	out, err := exec.CommandContext(ctx, git, "-C", dir, "status", "--porcelain=v2", "--branch").Output()
	if err != nil {
		return nil
	}
	info := &GitInfo{}
	for _, line := range strings.Split(string(out), "\n") {
		switch {
		case strings.HasPrefix(line, "# branch.head "):
			info.Branch = strings.TrimPrefix(line, "# branch.head ")
		case strings.HasPrefix(line, "# branch.ab "):
			for _, f := range strings.Fields(strings.TrimPrefix(line, "# branch.ab ")) {
				n, _ := strconv.Atoi(f[1:])
				if strings.HasPrefix(f, "+") {
					info.Ahead = n
				} else {
					info.Behind = n
				}
			}
		case line != "" && !strings.HasPrefix(line, "#"):
			info.Dirty++
		}
	}
	return info
}

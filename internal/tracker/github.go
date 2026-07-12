package tracker

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// GitHub reads open issues via the gh CLI, run in the workspace root so gh
// resolves the repo from the checkout's remote — the same trick the user's
// own `gh issue list` relies on. No tokens to manage; gh's auth is gh's.
type GitHub struct {
	// Root is the workspace's checkout.
	Root string
}

func NewGitHub(root string) *GitHub { return &GitHub{Root: root} }

func (g *GitHub) Name() string { return "github" }

// ghLogin caches the authenticated login for the process lifetime — it
// changes when the user re-auths gh, which is rare enough that a restart
// picking it up is fine.
var ghLogin = sync.OnceValue(func() string {
	out, err := runGH(".", "api", "user", "--jq", ".login")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
})

// findGH resolves the gh CLI: PATH first, then the conventional install
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

type ghIssue struct {
	Number    int       `json:"number"`
	Title     string    `json:"title"`
	Body      string    `json:"body"`
	URL       string    `json:"url"`
	UpdatedAt time.Time `json:"updatedAt"`
	Assignees []struct {
		Login string `json:"login"`
	} `json:"assignees"`
	Labels []struct {
		Name string `json:"name"`
	} `json:"labels"`
}

func (g *GitHub) Issues() ([]Issue, error) {
	out, err := runGH(g.Root, "issue", "list", "--state", "open", "--limit", "50",
		"--json", "number,title,body,url,updatedAt,assignees,labels")
	if err != nil {
		return nil, err
	}
	return parseGitHub([]byte(out), ghLogin())
}

// parseGitHub keeps only the queue scope: unassigned, or assigned to me.
// Issues someone else owns are their problem, not queue noise.
func parseGitHub(data []byte, login string) ([]Issue, error) {
	var raw []ghIssue
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("gh json: %w", err)
	}
	var out []Issue
	for _, gi := range raw {
		mine := false
		for _, a := range gi.Assignees {
			if a.Login == login && login != "" {
				mine = true
			}
		}
		if len(gi.Assignees) > 0 && !mine {
			continue
		}
		is := Issue{
			Tracker: "github",
			Key:     fmt.Sprintf("#%d", gi.Number),
			Title:   gi.Title,
			Body:    gi.Body,
			URL:     gi.URL,
			State:   "open",
			Mine:    mine,
			Updated: gi.UpdatedAt,
		}
		for _, l := range gi.Labels {
			is.Labels = append(is.Labels, l.Name)
		}
		is.Task = BuildTask(is)
		out = append(out, is)
	}
	return out, nil
}

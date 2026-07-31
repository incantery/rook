// rook-provider-github answers rook's questions about GitHub.
//
// Auth is gh's. This shells out to the gh CLI in the workspace checkout,
// so the repo resolves from its own remote and the credentials are the
// ones the user already logged in with — rook stores no GitHub token and
// there is nothing here to leak. That is the preferred provider shape
// wherever a first-class CLI exists: delegate the authority rather than
// hold it.
//
// The cost of delegating: a provider inherits rook's environment, and gh
// reads its auth from $XDG_CONFIG_HOME/gh. So an instance with a
// sandboxed config — `make dev` — has no GitHub auth until `gh auth
// login` runs against that sandbox, and the queue says so rather than
// coming back mysteriously empty.
//
// Deliberately standalone: it imports the protocol and nothing else of
// rook's. A provider is a process that could live in another repository
// written by another person, and the first one should prove that by
// being buildable that way, even while it ships in this tree.
package main

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

	"github.com/incantery/rook/internal/provider"
)

func main() {
	provider.Serve(
		provider.Describe{Name: "github"},
		map[string]provider.Handler{
			provider.OpIssuesList:  issuesList,
			provider.OpPullsStatus: pullsStatus,
		},
	)
}

// pullsStatus resolves a branch to its PR, run in the checkout so gh
// finds the repo from its remote.
//
// "No PR for this branch" is a RESULT, not an error: gh says so in prose
// on stderr, and the difference between that and a real failure is the
// whole reason the caller can tell "there is no PR yet" from "I could not
// look". GitHub keeps the PR↔branch association even after the remote
// branch is auto-deleted post-merge, so a merged PR still resolves here.
func pullsStatus(ctx context.Context, raw json.RawMessage) (any, error) {
	var p provider.PullsStatusParams
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, err
		}
	}
	if p.Root == "" || p.Branch == "" {
		return nil, fmt.Errorf("a checkout and a branch are both required")
	}
	out, err := runGH(ctx, p.Root, "pr", "view", p.Branch,
		"--json", "number,state,url,mergedAt,mergeable")
	if err != nil {
		if strings.Contains(err.Error(), "no pull requests found") {
			return provider.PullsStatusResult{Found: false}, nil
		}
		return nil, err
	}
	return parsePR([]byte(out))
}

func parsePR(data []byte) (provider.PullsStatusResult, error) {
	var pr struct {
		Number    int    `json:"number"`
		State     string `json:"state"`
		URL       string `json:"url"`
		MergedAt  string `json:"mergedAt"`
		Mergeable string `json:"mergeable"`
	}
	if err := json.Unmarshal(data, &pr); err != nil {
		return provider.PullsStatusResult{}, fmt.Errorf("gh pr json: %w", err)
	}
	return provider.PullsStatusResult{
		Found: true, Number: pr.Number, State: pr.State, URL: pr.URL,
		MergedAt: pr.MergedAt, Mergeable: pr.Mergeable,
	}, nil
}

// issuesList is the open queue scoped to "could be my next task":
// assigned to me, or assigned to nobody. Work someone else already owns
// is their queue, not this one.
func issuesList(ctx context.Context, raw json.RawMessage) (any, error) {
	var p provider.IssuesListParams
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, err
		}
	}
	if p.Root == "" {
		return nil, fmt.Errorf("no workspace root to resolve a repository from")
	}
	out, err := runGH(ctx, p.Root, "issue", "list", "--state", "open", "--limit", "50",
		"--json", "number,title,body,url,updatedAt,assignees,labels")
	if err != nil {
		return nil, err
	}
	issues, err := parseIssues([]byte(out), login(ctx))
	if err != nil {
		return nil, err
	}
	return provider.IssuesListResult{Issues: issues}, nil
}

type ghIssue struct {
	Number    int    `json:"number"`
	Title     string `json:"title"`
	Body      string `json:"body"`
	URL       string `json:"url"`
	UpdatedAt string `json:"updatedAt"`
	Assignees []struct {
		Login string `json:"login"`
	} `json:"assignees"`
	Labels []struct {
		Name string `json:"name"`
	} `json:"labels"`
}

func parseIssues(data []byte, me string) ([]provider.Issue, error) {
	var raw []ghIssue
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("gh json: %w", err)
	}
	out := []provider.Issue{}
	for _, gi := range raw {
		mine := false
		for _, a := range gi.Assignees {
			if me != "" && a.Login == me {
				mine = true
			}
		}
		if len(gi.Assignees) > 0 && !mine {
			continue
		}
		is := provider.Issue{
			Provider: "github",
			Key:      fmt.Sprintf("#%d", gi.Number),
			Title:    gi.Title,
			Body:     gi.Body,
			URL:      gi.URL,
			State:    "open",
			Mine:     mine,
			Updated:  gi.UpdatedAt,
		}
		for _, l := range gi.Labels {
			is.Labels = append(is.Labels, l.Name)
		}
		out = append(out, is)
	}
	return out, nil
}

// login is the authenticated user, cached for the process lifetime. It
// changes when the user re-auths gh, which is rare enough that a restart
// noticing is fine — and this process is restarted often.
var loginOnce sync.Once
var loginVal string

func login(ctx context.Context) string {
	loginOnce.Do(func() {
		out, err := runGH(ctx, ".", "api", "user", "--jq", ".login")
		if err == nil {
			loginVal = strings.TrimSpace(out)
		}
	})
	return loginVal
}

// findGH resolves the CLI: PATH first, then the conventional install
// spots. A provider spawned by a daemon inherits launchd's minimal PATH,
// not the shell's, so PATH alone is not enough on a real machine.
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

func runGH(ctx context.Context, dir string, args ...string) (string, error) {
	gh := findGH()
	if gh == "" {
		return "", fmt.Errorf("gh is not installed")
	}
	// The caller's deadline bounds this, but a provider must never hang
	// forever on its own account either.
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
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

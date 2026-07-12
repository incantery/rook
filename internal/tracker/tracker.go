// Package tracker reads issue queues from external trackers (GitHub
// Issues, Jira) behind one interface. rook READS, NEVER MIRRORS: nothing
// issue-shaped is ever persisted — the host keeps a short in-memory cache
// and every view is a live query. A stale copy of someone else's tracker
// is a tar pit rook stays out of by construction.
package tracker

import (
	"fmt"
	"strings"
	"time"
)

// Issue is one row of a workspace's work queue, tracker-agnostic.
type Issue struct {
	Tracker string `json:"tracker"` // "github" | "jira"
	Key     string `json:"key"`     // "#123" | "PROJ-42"
	Title   string `json:"title"`
	Body    string `json:"body,omitempty"`
	URL     string `json:"url,omitempty"`
	// State is the tracker's own label (github: open; jira: status name).
	State string `json:"state,omitempty"`
	// Mine: assigned to the authenticated user. False = unassigned — the
	// queue never contains issues assigned to someone else.
	Mine    bool      `json:"mine"`
	Labels  []string  `json:"labels,omitempty"`
	Updated time.Time `json:"updated"`
	// Task is the ready-to-spawn claude prompt for this issue, built
	// host-side once so every surface (dashboard, rookctl, future agent)
	// spawns the identical thing.
	Task string `json:"task"`
}

// Tracker is one queue source. Issues returns the active queue scoped to
// "could be my next task": assigned to me + unassigned. Active means open
// for GitHub and current-sprint (when sprints exist) for Jira.
type Tracker interface {
	Name() string
	Issues() ([]Issue, error)
}

// BuildTask renders the claude prompt for an issue. The body rides along
// (Jira needs it — claude has no Jira credentials); GitHub issues also get
// the gh escape hatch for comments and linked context.
func BuildTask(i Issue) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Work on %s: %s\n", i.Key, i.Title)
	if body := strings.TrimSpace(i.Body); body != "" {
		if len(body) > 4000 {
			body = body[:4000] + "\n[…truncated]"
		}
		fmt.Fprintf(&b, "\n%s\n", body)
	}
	if i.URL != "" {
		fmt.Fprintf(&b, "\nIssue: %s\n", i.URL)
	}
	if i.Tracker == "github" {
		fmt.Fprintf(&b, "Use `gh issue view %s --comments` for full context.\n", strings.TrimPrefix(i.Key, "#"))
	}
	return b.String()
}

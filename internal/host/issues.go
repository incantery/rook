package host

import (
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/tracker"
)

// The issue queue: GET /workspaces/{name}/issues fans out to the
// workspace's trackers (GitHub via gh when the root is a repo; Jira when
// configured for the workspace) and merges. READ, NEVER MIRROR — the only
// state is this short in-memory cache, gone with the process; rook.db
// never sees an issue. Each Issue carries its ready-to-spawn Task prompt
// so every surface actuates identically.

const issuesTTL = 60 * time.Second

type issuesCacheEntry struct {
	at  time.Time
	res issuesResult
}

type issuesResult struct {
	Issues []tracker.Issue `json:"issues"`
	// Errors surface per-tracker failures without hiding the other
	// tracker's rows — a dead Jira must not blank the GitHub queue.
	Errors []string `json:"errors,omitempty"`
}

var (
	issuesMu    sync.Mutex
	issuesCache = map[string]issuesCacheEntry{}
)

// trackersFor assembles the workspace's sources from its root and the
// (hot-reloaded) config. No trackers is a normal answer, not an error.
func trackersFor(ws *WorkspaceInfo) []tracker.Tracker {
	var out []tracker.Tracker
	if ws == nil {
		return out
	}
	if ws.Root != "" && gitInfo(ws.Root) != nil {
		out = append(out, tracker.NewGitHub(ws.Root))
	}
	cfg := config.Load()
	// worktree workspaces inherit their source's Jira project
	project := cfg.JiraProjects[ws.Name]
	if project == "" && ws.WorktreeOf != "" {
		project = cfg.JiraProjects[ws.WorktreeOf]
	}
	if project != "" && cfg.JiraURL != "" && cfg.JiraEmail != "" {
		if token := config.JiraToken(); token != "" {
			out = append(out, tracker.NewJira(cfg.JiraURL, cfg.JiraEmail, token, project, cfg.JiraJQL))
		}
	}
	return out
}

func (h *Host) handleWorkspaceIssues(w http.ResponseWriter, r *http.Request, name string) {
	issuesMu.Lock()
	if e, ok := issuesCache[name]; ok && time.Since(e.at) < issuesTTL && r.URL.Query().Get("refresh") == "" {
		issuesMu.Unlock()
		writeJSON(w, e.res)
		return
	}
	issuesMu.Unlock()

	ws := h.reg.get(name)
	res := issuesResult{Issues: []tracker.Issue{}}
	type answer struct {
		name   string
		issues []tracker.Issue
		err    error
	}
	trs := trackersFor(ws)
	ch := make(chan answer, len(trs))
	for _, tr := range trs {
		go func(tr tracker.Tracker) {
			issues, err := tr.Issues()
			ch <- answer{tr.Name(), issues, err}
		}(tr)
	}
	for range trs {
		a := <-ch
		if a.err != nil {
			res.Errors = append(res.Errors, fmt.Sprintf("%s: %v", a.name, a.err))
			continue
		}
		res.Issues = append(res.Issues, a.issues...)
	}
	// mine first, then unassigned; fresher first within each
	sortIssues(res.Issues)

	issuesMu.Lock()
	issuesCache[name] = issuesCacheEntry{at: time.Now(), res: res}
	issuesMu.Unlock()
	writeJSON(w, res)
}

func sortIssues(list []tracker.Issue) {
	// insertion-order stability matters less than a simple total order
	for i := 1; i < len(list); i++ {
		for j := i; j > 0 && issueLess(list[j], list[j-1]); j-- {
			list[j], list[j-1] = list[j-1], list[j]
		}
	}
}

func issueLess(a, b tracker.Issue) bool {
	if a.Mine != b.Mine {
		return a.Mine
	}
	return a.Updated.After(b.Updated)
}

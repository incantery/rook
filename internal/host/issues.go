package host

// The issue queue: GET /workspaces/{name}/issues asks every provider the
// workspace has and merges the answers.
//
// READ, NEVER MIRROR — the only state is the short in-memory cache below,
// gone with the process; rook.db never sees an issue. A stale copy of
// someone else's tracker is a tar pit rook stays out of by construction.
//
// Providers are separate processes (sdk/provider). What that buys
// here, concretely: a Linear API key never enters rook, a hung tracker
// cannot hang the host, and adding a third tracker adds no code to this
// file. What it costs is one process per provider, started on first use.
//
// Two ways a provider attaches to a workspace, and the difference is
// whether the workspace itself is evidence:
//
//	INFERRED  github, wherever the checkout is a git repo — the remote
//	          says which repo this is better than a config line could.
//	DECLARED  [providers.<name>] in config, for everything else. Nothing
//	          about a checkout implies a Linear workspace.
//
// Per-provider failures are reported per provider: a dead Linear must
// never blank the GitHub queue.

import (
	"context"
	"fmt"
	"maps"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/sdk/provider"
)

const (
	issuesTTL = 60 * time.Second
	// issuesTimeout bounds one provider's answer. Generous — `gh` on a
	// cold auth cache is not fast — but finite, because the queue is a
	// thing a human is waiting on.
	issuesTimeout = 20 * time.Second
)

// queueIssue is one row as this API returns it: what the provider said,
// plus the Task rook built from it. The Task is deliberately NOT a
// provider's to supply — see buildTask.
type queueIssue struct {
	Provider string    `json:"provider"`
	Key      string    `json:"key"`
	Title    string    `json:"title"`
	Body     string    `json:"body,omitempty"`
	URL      string    `json:"url,omitempty"`
	State    string    `json:"state,omitempty"`
	Mine     bool      `json:"mine"`
	Labels   []string  `json:"labels,omitempty"`
	Updated  time.Time `json:"updated"`
	Task     string    `json:"task"`
}

type issuesResult struct {
	Issues []queueIssue `json:"issues"`
	// Errors surface per-provider failures without hiding the others.
	Errors []string `json:"errors,omitempty"`
}

type issuesCacheEntry struct {
	at  time.Time
	res issuesResult
}

var (
	issuesMu    sync.Mutex
	issuesCache = map[string]issuesCacheEntry{}
)

// providerClients are long-lived, keyed by name: a provider process is
// reused across requests and workspaces, started on first use and
// respawned by the next call if it died.
var (
	provMu      sync.Mutex
	provClients = map[string]*provider.Client{}
	provEnv     = map[string]map[string]string{}
)

// providerClient returns the live client for name, rebuilding it when the
// provider's configuration changed — config is hot-reloaded everywhere
// else in rook, and a provider running on last hour's settings would be
// the one place that silently is not.
func providerClient(name string, env map[string]string) *provider.Client {
	provMu.Lock()
	defer provMu.Unlock()
	if c, ok := provClients[name]; ok {
		if maps.Equal(provEnv[name], env) {
			return c
		}
		c.Close()
	}
	c := provider.New(name)
	c.Env = env
	provClients[name], provEnv[name] = c, env
	return c
}

// providersFor names the providers this workspace can ask, inferred and
// declared, deduplicated and in a stable order.
func providersFor(ws *WorkspaceInfo) []string {
	if ws == nil {
		return nil
	}
	seen := map[string]bool{}
	var out []string
	if ws.Root != "" && gitInfo(ws.Root) != nil {
		out, seen["github"] = append(out, "github"), true
	}
	var declared []string
	for name := range config.Load().Providers {
		if name = strings.TrimSpace(name); name != "" && !seen[name] {
			declared = append(declared, name)
		}
	}
	sort.Strings(declared) // config maps have no order; the answer must
	return append(out, declared...)
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
	res := issuesResult{Issues: []queueIssue{}}
	names := providersFor(ws)
	cfg := config.Load()

	type answer struct {
		name   string
		issues []queueIssue
		err    error
	}
	ch := make(chan answer, len(names))
	for _, pname := range names {
		go func(pname string) {
			issues, err := askProvider(r.Context(), providerClient(pname, cfg.Providers[pname]), ws)
			ch <- answer{pname, issues, err}
		}(pname)
	}
	for range names {
		a := <-ch
		if a.err != nil {
			res.Errors = append(res.Errors, fmt.Sprintf("%s: %v", a.name, a.err))
			continue
		}
		res.Issues = append(res.Issues, a.issues...)
	}
	sortIssues(res.Issues)

	issuesMu.Lock()
	issuesCache[name] = issuesCacheEntry{at: time.Now(), res: res}
	issuesMu.Unlock()
	writeJSON(w, res)
}

// askProvider runs one provider's issues.list and renders the rows.
func askProvider(ctx context.Context, c *provider.Client, ws *WorkspaceInfo) ([]queueIssue, error) {
	ctx, cancel := context.WithTimeout(ctx, issuesTimeout)
	defer cancel()

	root := ""
	if ws != nil {
		root = ws.Root
	}
	var res provider.IssuesListResult
	if err := c.Call(ctx, provider.OpIssuesList, provider.IssuesListParams{Root: root}, &res); err != nil {
		return nil, err
	}
	out := make([]queueIssue, 0, len(res.Issues))
	for _, is := range res.Issues {
		q := queueIssue{
			Provider: is.Provider, Key: is.Key, Title: is.Title, Body: is.Body,
			URL: is.URL, State: is.State, Mine: is.Mine, Labels: is.Labels,
		}
		if q.Provider == "" {
			q.Provider = c.Name // a provider that forgot to say who it is
		}
		// A timestamp rook cannot read sorts last rather than failing the
		// row: the queue is more useful slightly out of order than short.
		if t, err := time.Parse(time.RFC3339, is.Updated); err == nil {
			q.Updated = t
		}
		q.Task = buildTask(q)
		out = append(out, q)
	}
	return out, nil
}

// buildTask renders the claude prompt for an issue, HERE and never in the
// provider. Same rule the edge protocol keeps and the spawn presets keep:
// a remote party names a thing, and rook owns what that thing means. A
// provider that could write the prompt could write any prompt, and the
// queue would be a hole straight through to an agent.
func buildTask(i queueIssue) string {
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
	if i.Provider == "github" {
		fmt.Fprintf(&b, "Use `gh issue view %s --comments` for full context.\n", strings.TrimPrefix(i.Key, "#"))
		// The issue learns its state through GitHub's own PR↔issue linkage —
		// rook never writes to the tracker (read, never mirror).
		fmt.Fprintf(&b, "When the work is done, push the branch and open a PR with `Closes %s` in its description so the issue closes on merge.\n", i.Key)
	}
	return b.String()
}

func sortIssues(list []queueIssue) {
	sort.SliceStable(list, func(a, b int) bool { return issueLess(list[a], list[b]) })
}

func issueLess(a, b queueIssue) bool {
	if a.Mine != b.Mine {
		return a.Mine
	}
	return a.Updated.After(b.Updated)
}

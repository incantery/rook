package host

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// gitT runs git in dir, failing the test on error.
func gitT(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t",
		"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// newWorktreeHost stands up a host with an isolated data dir and a source
// workspace pointing at a fresh git repo with one commit.
func newWorktreeHost(t *testing.T) (h *Host, srv *httptest.Server, repo string) {
	t.Helper()
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	repo = t.TempDir()
	gitT(t, repo, "init", "-b", "main")
	if err := os.WriteFile(filepath.Join(repo, "a.txt"), []byte("hello\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitT(t, repo, "add", ".")
	gitT(t, repo, "commit", "-m", "init")

	h = New()
	srv = httptest.NewServer(h.Handler())
	t.Cleanup(srv.Close)
	h.reg.upsert("src", repo, false)
	return h, srv, repo
}

func (c *wtClient) do(t *testing.T, method, path string, body any) (int, string) {
	t.Helper()
	var rd *bytes.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	} else {
		rd = bytes.NewReader(nil)
	}
	req, err := http.NewRequest(method, c.base+path, rd)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var buf bytes.Buffer
	buf.ReadFrom(resp.Body)
	return resp.StatusCode, strings.TrimSpace(buf.String())
}

type wtClient struct{ base, token string }

func TestWorktreeLifecycle(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	// create: auto-name, branch, checkout on disk, registered
	code, body := c.do(t, "POST", "/workspaces", map[string]any{"worktreeFrom": "src"})
	if code != 200 {
		t.Fatalf("create: %d %s", code, body)
	}
	var ws WorkspaceInfo
	if err := json.Unmarshal([]byte(body), &ws); err != nil {
		t.Fatal(err)
	}
	if ws.Name != "src-t1" || ws.WorktreeOf != "src" || ws.Branch != "rook/src-t1" {
		t.Fatalf("unexpected workspace: %+v", ws)
	}
	if _, err := os.Stat(filepath.Join(ws.Root, "a.txt")); err != nil {
		t.Fatalf("checkout missing: %v", err)
	}
	if got := gitT(t, ws.Root, "rev-parse", "--abbrev-ref", "HEAD"); got != "rook/src-t1" {
		t.Fatalf("branch = %q", got)
	}

	// clean tree deletes without force; checkout gone, branch survives
	if code, body = c.do(t, "DELETE", "/workspaces/"+ws.Name, nil); code != 204 {
		t.Fatalf("clean delete: %d %s", code, body)
	}
	if _, err := os.Stat(ws.Root); !os.IsNotExist(err) {
		t.Fatalf("checkout still on disk: %v", err)
	}
	if !strings.Contains(gitT(t, repo, "branch", "--list", "rook/src-t1"), "rook/src-t1") {
		t.Fatal("branch should survive removal")
	}
}

func TestWorktreeRefusesToLoseWork(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	mk := func() WorkspaceInfo {
		code, body := c.do(t, "POST", "/workspaces", map[string]any{"worktreeFrom": "src"})
		if code != 200 {
			t.Fatalf("create: %d %s", code, body)
		}
		var ws WorkspaceInfo
		json.Unmarshal([]byte(body), &ws)
		return ws
	}

	// dirty file → 409, tree intact; force → gone
	ws := mk()
	os.WriteFile(filepath.Join(ws.Root, "wip.txt"), []byte("wip"), 0o644)
	code, body := c.do(t, "DELETE", "/workspaces/"+ws.Name, nil)
	if code != 409 || !strings.Contains(body, "dirty") {
		t.Fatalf("dirty delete: %d %s", code, body)
	}
	if _, err := os.Stat(ws.Root); err != nil {
		t.Fatal("refusal must not touch the tree")
	}
	if code, body = c.do(t, "DELETE", "/workspaces/"+ws.Name+"?force=1", nil); code != 204 {
		t.Fatalf("forced delete: %d %s", code, body)
	}

	// unmerged commit → 409 mentioning the branch; force → gone, branch kept
	ws = mk()
	os.WriteFile(filepath.Join(ws.Root, "done.txt"), []byte("done"), 0o644)
	gitT(t, ws.Root, "add", ".")
	gitT(t, ws.Root, "commit", "-m", "unmerged work")
	code, body = c.do(t, "DELETE", "/workspaces/"+ws.Name, nil)
	if code != 409 || !strings.Contains(body, "unmerged") {
		t.Fatalf("unmerged delete: %d %s", code, body)
	}
	if code, body = c.do(t, "DELETE", "/workspaces/"+ws.Name+"?force=1", nil); code != 204 {
		t.Fatalf("forced delete: %d %s", code, body)
	}
	if !strings.Contains(gitT(t, repo, "branch", "--list", ws.Branch), ws.Branch) {
		t.Fatal("branch with unmerged commits must survive")
	}

	// merged-back branch counts as clean
	ws = mk()
	os.WriteFile(filepath.Join(ws.Root, "feat.txt"), []byte("feat"), 0o644)
	gitT(t, ws.Root, "add", ".")
	gitT(t, ws.Root, "commit", "-m", "feature")
	gitT(t, repo, "merge", ws.Branch)
	if code, body = c.do(t, "DELETE", "/workspaces/"+ws.Name, nil); code != 204 {
		t.Fatalf("merged delete should be clean: %d %s", code, body)
	}
}

func TestWorktreeIssueStamp(t *testing.T) {
	h, srv, _ := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	// work-on-issue create: provenance stamped and returned
	code, body := c.do(t, "POST", "/workspaces", map[string]any{
		"worktreeFrom": "src",
		"issue":        map[string]string{"tracker": "github", "key": "#2"},
	})
	if code != 200 {
		t.Fatalf("create: %d %s", code, body)
	}
	var ws WorkspaceInfo
	json.Unmarshal([]byte(body), &ws)
	if ws.IssueRef == nil || ws.IssueRef.Tracker != "github" || ws.IssueRef.Key != "#2" {
		t.Fatalf("issue ref not stamped: %+v", ws.IssueRef)
	}

	// survives the registry round-trip: the list endpoint carries it
	code, body = c.do(t, "GET", "/workspaces", nil)
	if code != 200 {
		t.Fatalf("list: %d %s", code, body)
	}
	var list []WorkspaceInfo
	json.Unmarshal([]byte(body), &list)
	found := false
	for _, item := range list {
		if item.Name == ws.Name {
			found = true
			if item.IssueRef == nil || item.IssueRef.Key != "#2" || item.IssueRef.Tracker != "github" {
				t.Fatalf("list lost the issue ref: %+v", item.IssueRef)
			}
		}
	}
	if !found {
		t.Fatalf("%s missing from list", ws.Name)
	}

	// plain worktrees (and empty refs) stay unstamped
	code, body = c.do(t, "POST", "/workspaces", map[string]any{"worktreeFrom": "src"})
	if code != 200 {
		t.Fatalf("plain create: %d %s", code, body)
	}
	var plain WorkspaceInfo
	json.Unmarshal([]byte(body), &plain)
	if plain.IssueRef != nil {
		t.Fatalf("plain worktree should have no issue ref: %+v", plain.IssueRef)
	}
	code, body = c.do(t, "POST", "/workspaces", map[string]any{
		"worktreeFrom": "src",
		"issue":        map[string]string{"tracker": "github", "key": ""},
	})
	if code != 200 {
		t.Fatalf("empty-ref create: %d %s", code, body)
	}
	var empty WorkspaceInfo
	json.Unmarshal([]byte(body), &empty)
	if empty.IssueRef != nil {
		t.Fatalf("empty issue ref should not be stamped: %+v", empty.IssueRef)
	}
}

func TestWorktreeCreateErrors(t *testing.T) {
	h, srv, _ := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	if code, body := c.do(t, "POST", "/workspaces", map[string]any{"worktreeFrom": "nope"}); code != 400 {
		t.Fatalf("missing source: %d %s", code, body)
	}
	h.reg.upsert("norepo", t.TempDir(), false)
	if code, body := c.do(t, "POST", "/workspaces", map[string]any{"worktreeFrom": "norepo"}); code != 400 {
		t.Fatalf("non-repo source: %d %s", code, body)
	}
	if code, body := c.do(t, "POST", "/workspaces", map[string]any{"worktreeFrom": "src", "name": "src"}); code != 409 {
		t.Fatalf("name collision: %d %s", code, body)
	}
	// names must keep incrementing past existing worktrees
	c.do(t, "POST", "/workspaces", map[string]any{"worktreeFrom": "src"})
	code, body := c.do(t, "POST", "/workspaces", map[string]any{"worktreeFrom": "src"})
	var ws WorkspaceInfo
	json.Unmarshal([]byte(body), &ws)
	if code != 200 || ws.Name != "src-t2" {
		t.Fatalf("second auto-name: %d %+v", code, ws)
	}
}

package host

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The close-the-loop surface: PR snapshots ride the workspace list (absent
// = unknown, fail open), and deleting the workspace forgets its snapshot.
func TestWorkspaceListCarriesPR(t *testing.T) {
	h, srv, _ := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	code, body := c.do(t, "POST", "/workspaces", map[string]any{"worktreeFrom": "src"})
	if code != 200 {
		t.Fatalf("create: %d %s", code, body)
	}
	var ws WorkspaceInfo
	json.Unmarshal([]byte(body), &ws)

	find := func() map[string]any {
		t.Helper()
		code, body := c.do(t, "GET", "/workspaces", nil)
		if code != 200 {
			t.Fatalf("list: %d %s", code, body)
		}
		var list []map[string]any
		json.Unmarshal([]byte(body), &list)
		for _, item := range list {
			if item["name"] == ws.Name {
				return item
			}
		}
		t.Fatalf("%s missing from list", ws.Name)
		return nil
	}

	// unknown state: no pr field at all — old and new frontends both no-op
	if _, ok := find()["pr"]; ok {
		t.Fatal("pr must be absent before the poller has an answer")
	}

	h.prm.set(ws.Name, PRSnapshot{State: "merged", Number: 14, URL: "https://github.com/x/y/pull/14"})
	pr, ok := find()["pr"].(map[string]any)
	if !ok || pr["state"] != "merged" || pr["number"] != float64(14) {
		t.Fatalf("list must carry the snapshot: %v", find()["pr"])
	}

	if code, body := c.do(t, "DELETE", "/workspaces/"+ws.Name, nil); code != 204 {
		t.Fatalf("delete: %d %s", code, body)
	}
	if h.prm.get(ws.Name) != nil {
		t.Fatal("delete must forget the PR snapshot")
	}
}

// The merged nudge's exact call: force (squash merges read as unmerged to
// the guard) + prune — checkout gone, and for once the branch too.
func TestWorktreeCleanupPrunesBranch(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	code, body := c.do(t, "POST", "/workspaces", map[string]any{"worktreeFrom": "src"})
	if code != 200 {
		t.Fatalf("create: %d %s", code, body)
	}
	var ws WorkspaceInfo
	json.Unmarshal([]byte(body), &ws)
	if err := os.WriteFile(filepath.Join(ws.Root, "feat.txt"), []byte("feat"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitT(t, ws.Root, "add", ".")
	gitT(t, ws.Root, "commit", "-m", "feature")
	// squash-merge shape: main gets the change as a DIFFERENT commit, so
	// the branch's own commit stays unreachable from every other ref
	if err := os.WriteFile(filepath.Join(repo, "feat.txt"), []byte("feat"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitT(t, repo, "add", ".")
	gitT(t, repo, "commit", "-m", "feature (squashed)")

	// without force the guard still refuses — prune never weakens it
	if code, body = c.do(t, "DELETE", "/workspaces/"+ws.Name+"?prune=1", nil); code != 409 {
		t.Fatalf("unforced cleanup must keep the guard: %d %s", code, body)
	}
	if code, body = c.do(t, "DELETE", "/workspaces/"+ws.Name+"?force=1&prune=1", nil); code != 204 {
		t.Fatalf("cleanup: %d %s", code, body)
	}
	if strings.Contains(gitT(t, repo, "branch", "--list", ws.Branch), ws.Branch) {
		t.Fatal("prune must delete the local branch")
	}
}

package host

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The review ↔ threads bridge: leaves re-anchor like threads do, a thread
// created inside a hunk's current range links to that leaf and blocks the
// gate (pending), and the last resolve restores the prior disposition.

func lines(n int, edit map[int]string) string {
	var b strings.Builder
	for i := 1; i <= n; i++ {
		if s, ok := edit[i]; ok {
			b.WriteString(s)
		} else {
			fmt.Fprintf(&b, "line %d", i)
		}
		b.WriteString("\n")
	}
	return b.String()
}

func prepareUnstaged(t *testing.T, c *wtClient) (parent RookTask, gate reviewGate) {
	t.Helper()
	code, raw := c.do(t, "POST", "/workspaces/src/review", map[string]string{"scope": "unstaged"})
	if code != 200 {
		t.Fatalf("prepare: %d %s", code, raw)
	}
	var res struct {
		Task RookTask   `json:"task"`
		Gate reviewGate `json:"gate"`
	}
	if err := json.Unmarshal([]byte(raw), &res); err != nil {
		t.Fatal(err)
	}
	return res.Task, res.Gate
}

func gateOf(t *testing.T, c *wtClient, id int64) reviewGate {
	t.Helper()
	code, raw := c.do(t, "GET", fmt.Sprintf("/tasks/%d/gate", id), nil)
	if code != 200 {
		t.Fatalf("gate: %d %s", code, raw)
	}
	var g reviewGate
	json.Unmarshal([]byte(raw), &g)
	return g
}

func TestReviewLeafReanchors(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	p := filepath.Join(repo, "r.txt")
	os.WriteFile(p, []byte(lines(12, nil)), 0o644)
	gitT(t, repo, "add", ".")
	gitT(t, repo, "commit", "-m", "base")
	// one hunk: line 8 modified
	os.WriteFile(p, []byte(lines(12, map[int]string{8: "LINE EIGHT, CHANGED"})), 0o644)

	parent, _ := prepareUnstaged(t, c)
	if len(parent.Children) != 1 {
		t.Fatalf("children: %+v", parent.Children)
	}
	leaf := parent.Children[0]
	if leaf.BlobSHA == "" {
		t.Fatal("leaf must carry an anchor blob now")
	}
	// hunks carry their context lines, so the stored range is 5-11
	if leaf.CurrentStart != 5 || leaf.CurrentEnd != 11 || leaf.Outdated {
		t.Fatalf("fresh leaf: current=%d-%d outdated=%v", leaf.CurrentStart, leaf.CurrentEnd, leaf.Outdated)
	}

	// edits ABOVE the hunk shift the current range on read — the thread seam
	os.WriteFile(p, []byte("new one\nnew two\nnew three\n"+
		lines(12, map[int]string{8: "LINE EIGHT, CHANGED"})), 0o644)
	code, raw := c.do(t, "GET", "/workspaces/src/tasks?workType=review", nil)
	if code != 200 {
		t.Fatalf("tasks: %d %s", code, raw)
	}
	var roots []RookTask
	json.Unmarshal([]byte(raw), &roots)
	if len(roots) != 1 || len(roots[0].Children) != 1 {
		t.Fatalf("roots: %s", raw)
	}
	got := roots[0].Children[0]
	if got.CurrentStart != 8 || got.CurrentEnd != 14 || got.Outdated {
		t.Fatalf("shifted leaf: current=%d-%d outdated=%v (want 8-14)",
			got.CurrentStart, got.CurrentEnd, got.Outdated)
	}
}

func TestThreadLinksToReview(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	p := filepath.Join(repo, "r.txt")
	os.WriteFile(p, []byte(lines(12, nil)), 0o644)
	gitT(t, repo, "add", ".")
	gitT(t, repo, "commit", "-m", "base")
	os.WriteFile(p, []byte(lines(12, map[int]string{8: "LINE EIGHT, CHANGED"})), 0o644)

	parent, _ := prepareUnstaged(t, c)
	leaf := parent.Children[0]

	// approve the hunk first, so the pending flip is observable on the gate
	if code, _ := c.do(t, "POST", fmt.Sprintf("/tasks/%d/state", leaf.ID),
		map[string]string{"state": "approved"}); code != 204 {
		t.Fatal("approve failed")
	}
	if g := gateOf(t, c, parent.ID); !g.Ready {
		t.Fatalf("approved single hunk must open the gate: %+v", g)
	}

	mkLinked := func(line int) *ThreadInfo {
		t.Helper()
		code, raw := c.do(t, "POST", "/workspaces/src/threads", map[string]any{
			"path": "r.txt", "startLine": line, "endLine": line,
			"body": "question", "rookTaskId": parent.ID,
		})
		if code != 200 {
			t.Fatalf("thread: %d %s", code, raw)
		}
		var th ThreadInfo
		json.Unmarshal([]byte(raw), &th)
		return &th
	}

	// in-hunk: links to the LEAF, which flips pending and closes the gate
	th := mkLinked(8)
	if th.RookTaskID != leaf.ID {
		t.Fatalf("in-hunk link: got %d want leaf %d", th.RookTaskID, leaf.ID)
	}
	if got := h.reg.getTask(leaf.ID); got.State != "pending" {
		t.Fatalf("leaf state: %s", got.State)
	}
	if g := gateOf(t, c, parent.ID); g.Ready || g.Blocking != 1 {
		t.Fatalf("pending leaf must block: %+v", g)
	}

	// a second in-hunk thread; resolving only one keeps the leaf pending
	th2 := mkLinked(8)
	if th2.RookTaskID != leaf.ID {
		t.Fatalf("second link: %d", th2.RookTaskID)
	}
	if code, _ := c.do(t, "POST", fmt.Sprintf("/threads/%d/resolve", th2.ID),
		map[string]string{"by": "user"}); code != 204 {
		t.Fatal("resolve failed")
	}
	if got := h.reg.getTask(leaf.ID); got.State != "pending" {
		t.Fatalf("one open thread must keep pending: %s", got.State)
	}

	// the LAST resolve restores the prior disposition (approved, not proposed)
	if code, _ := c.do(t, "POST", fmt.Sprintf("/threads/%d/resolve", th.ID),
		map[string]string{"by": "user"}); code != 204 {
		t.Fatal("resolve failed")
	}
	if got := h.reg.getTask(leaf.ID); got.State != "approved" {
		t.Fatalf("prior disposition must come back: %s", got.State)
	}
	if g := gateOf(t, c, parent.ID); !g.Ready {
		t.Fatalf("gate must reopen: %+v", g)
	}

	// reopen re-blocks
	if code, _ := c.do(t, "POST", fmt.Sprintf("/threads/%d/reopen", th.ID),
		map[string]string{"by": "user"}); code != 204 {
		t.Fatal("reopen failed")
	}
	if got := h.reg.getTask(leaf.ID); got.State != "pending" {
		t.Fatalf("reopen must re-block: %s", got.State)
	}
	if code, _ := c.do(t, "POST", fmt.Sprintf("/threads/%d/resolve", th.ID),
		map[string]string{"by": "user"}); code != 204 {
		t.Fatal("re-resolve failed")
	}

	// out-of-hunk: links to the PARENT (a global comment), no leaf flip
	global := mkLinked(2)
	if global.RookTaskID != parent.ID {
		t.Fatalf("out-of-hunk link: got %d want parent %d", global.RookTaskID, parent.ID)
	}
	if got := h.reg.getTask(leaf.ID); got.State != "approved" {
		t.Fatalf("global comment must not touch the leaf: %s", got.State)
	}

	// the gt-abort: an empty linked thread deleted → leaf unblocks again
	code, raw := c.do(t, "POST", "/workspaces/src/threads", map[string]any{
		"path": "r.txt", "startLine": 8, "endLine": 8, "body": "", "rookTaskId": parent.ID,
	})
	if code != 200 {
		t.Fatalf("empty linked thread: %d %s", code, raw)
	}
	var empty ThreadInfo
	json.Unmarshal([]byte(raw), &empty)
	if got := h.reg.getTask(leaf.ID); got.State != "pending" {
		t.Fatalf("empty linked thread must block: %s", got.State)
	}
	if code, _ := c.do(t, "DELETE", fmt.Sprintf("/threads/%d", empty.ID), nil); code != 204 {
		t.Fatal("delete failed")
	}
	if got := h.reg.getTask(leaf.ID); got.State != "approved" {
		t.Fatalf("gt-abort must unblock: %s", got.State)
	}

	// a bogus root fails open: thread created, no link
	code, raw = c.do(t, "POST", "/workspaces/src/threads", map[string]any{
		"path": "r.txt", "startLine": 8, "endLine": 8, "body": "x", "rookTaskId": 99999,
	})
	if code != 200 {
		t.Fatalf("bogus root: %d %s", code, raw)
	}
	var unlinked ThreadInfo
	json.Unmarshal([]byte(raw), &unlinked)
	if unlinked.RookTaskID != 0 {
		t.Fatalf("bogus root must not link: %d", unlinked.RookTaskID)
	}
}

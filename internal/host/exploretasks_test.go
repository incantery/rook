package host

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// reviewPOST is reviewGET's POST twin — typed body in, typed answer out.
func reviewPOST[T any](t *testing.T, c *wtClient, path string, body any, wantCode int) T {
	t.Helper()
	code, raw := c.do(t, "POST", path, body)
	if code != wantCode {
		t.Fatalf("POST %s: %d %s (want %d)", path, code, raw, wantCode)
	}
	var out T
	if wantCode == 200 {
		if err := json.Unmarshal([]byte(raw), &out); err != nil {
			t.Fatalf("POST %s: %v in %s", path, err, raw)
		}
	}
	return out
}

func taskPath(id int64, verb string) string {
	return fmt.Sprintf("/tasks/%d/%s", id, verb)
}

func TestExploreTrail(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	os.WriteFile(filepath.Join(repo, "seek.go"), []byte("package x\n\nfunc Seek() {}\n"), 0o644)

	// a question starts the investigation
	root := reviewPOST[RookTask](t, c, "/workspaces/src/explore",
		map[string]string{"title": "why does Seek exist?"}, 200)
	if root.WorkType != "explore" || root.State != "open" || root.ParentID != 0 {
		t.Fatalf("root: %+v", root)
	}

	// an empty title is refused — an investigation is a question
	if code, _ := c.do(t, "POST", "/workspaces/src/explore", map[string]string{"title": "  "}); code != 400 {
		t.Fatalf("empty title: want 400")
	}

	// visits append breadcrumbs, line text captured at visit time
	visit := func(path string, line int, wantCode int) RookTask {
		t.Helper()
		return reviewPOST[RookTask](t, c, taskPath(root.ID, "visit"),
			map[string]any{"path": path, "line": line, "col": 2}, wantCode)
	}
	b1 := visit("seek.go", 3, 200)
	if b1.ParentID != root.ID || b1.State != "visited" || b1.AnchorText != "func Seek() {}" {
		t.Fatalf("breadcrumb: %+v", b1)
	}
	// standing still is not a step — the same spot dedups to the same row
	if b2 := visit("seek.go", 3, 200); b2.ID != b1.ID {
		t.Fatalf("dedup: got new id %d, want %d", b2.ID, b1.ID)
	}
	b3 := visit("seek.go", 1, 200)
	if b3.ID == b1.ID {
		t.Fatal("different line should append")
	}
	// ...and returning to an earlier spot IS a step (only consecutive dedups)
	if b4 := visit("seek.go", 3, 200); b4.ID == b1.ID {
		t.Fatal("non-consecutive revisit should append")
	}

	// a path outside the repo is the caller's bug
	if code, _ := c.do(t, "POST", taskPath(root.ID, "visit"),
		map[string]any{"path": "../escape.go", "line": 1}); code != 400 {
		t.Fatal("escaping path: want 400")
	}

	// the tree lists newest-root-first with the trail one level deep
	roots := reviewGET[[]RookTask](t, c, "/workspaces/src/tasks?workType=explore", 200)
	if len(roots) != 1 || len(roots[0].Children) != 3 {
		t.Fatalf("roots: %+v", roots)
	}

	// finishing closes the door: state done sticks, visits refuse
	if code, _ := c.do(t, "POST", taskPath(root.ID, "state"), map[string]string{"state": "done"}); code != 204 {
		t.Fatal("state done failed")
	}
	if code, _ := c.do(t, "POST", taskPath(root.ID, "visit"),
		map[string]any{"path": "seek.go", "line": 2}); code != 400 {
		t.Fatal("visit on done investigation: want 400")
	}
	// and the vocabulary is validated per role
	if code, _ := c.do(t, "POST", taskPath(root.ID, "state"), map[string]string{"state": "approved"}); code != 400 {
		t.Fatal("review vocabulary on explore root: want 400")
	}
	if code, _ := c.do(t, "POST", taskPath(b1.ID, "state"), map[string]string{"state": "starred"}); code != 204 {
		t.Fatal("starring a breadcrumb failed")
	}
}

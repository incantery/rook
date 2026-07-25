package host

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRelUnder(t *testing.T) {
	cases := []struct{ root, p, want string }{
		{"/repo", "/repo/internal/pty/session.go", "internal/pty/session.go"},
		{"/repo", "/repo/go.mod", "go.mod"},
		{"/repo", "/elsewhere/file.go", ""},
		{"/repo", "/repo", ""},            // the root itself is not "under" it
		{"/repo", "/repository/x.go", ""}, // prefix of the name, not the path
		{"", "/anything", ""},             // no workspace root — everything external
	}
	for _, c := range cases {
		if got := relUnder(c.root, c.p); got != c.want {
			t.Errorf("relUnder(%q, %q) = %q, want %q", c.root, c.p, got, c.want)
		}
	}
}

func TestCanonicalFile(t *testing.T) {
	dir := t.TempDir()
	real, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	// an existing file resolves outright
	p := filepath.Join(dir, "there.txt")
	os.WriteFile(p, []byte("x\n"), 0o644)
	if got := canonicalFile(p); got != filepath.Join(real, "there.txt") {
		t.Errorf("existing file: %q", got)
	}
	// one that isn't there yet still canonicalizes through its DIRECTORY —
	// plain canonical() hands back the literal path, and a literal /var/…
	// compared against a resolved /private/var/… reads as outside the repo
	miss := filepath.Join(dir, "new.txt")
	if got := canonicalFile(miss); got != filepath.Join(real, "new.txt") {
		t.Errorf("missing file: %q", got)
	}
	if got := canonicalFile(""); got != "" {
		t.Errorf("empty: %q", got)
	}
}

// `re` path resolution: what lands in the msgEdit frame. Workspace files go
// relative, outsiders absolute, a directory re-anchors instead of opening,
// and a file that doesn't exist yet rides through as a new-file buffer.
func TestSessionEditPaths(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}
	oob := make(chan []byte, 4)
	h.mu.Lock()
	h.sessions["s1"] = &session{info: SessionInfo{ID: "s1", Workspace: "src"}, oob: oob}
	h.mu.Unlock()

	ask := func(cwd string, paths ...string) editPayload {
		t.Helper()
		code, body := c.do(t, "POST", "/sessions/s1/edit",
			map[string]any{"cwd": cwd, "paths": paths})
		if code != 200 {
			t.Fatalf("edit %v: %d %s", paths, code, body)
		}
		msg := <-oob
		if msg[0] != msgEdit {
			t.Fatalf("frame tag %#x, want msgEdit", msg[0])
		}
		var p editPayload
		if err := json.Unmarshal(msg[1:], &p); err != nil {
			t.Fatal(err)
		}
		return p
	}

	// in the workspace: relative
	if p := ask(repo, "a.txt"); len(p.Paths) != 1 || p.Paths[0] != "a.txt" {
		t.Fatalf("workspace file: %+v", p)
	}
	// not there yet, but its directory is: still a relative new-file buffer
	if p := ask(repo, "brand-new.txt"); len(p.Paths) != 1 || p.Paths[0] != "brand-new.txt" {
		t.Fatalf("new file: %+v", p)
	}
	// under a directory that doesn't exist: a typo, not an intention
	if code, _ := c.do(t, "POST", "/sessions/s1/edit",
		map[string]any{"cwd": repo, "paths": []string{"nodir/x.txt"}}); code != 404 {
		t.Fatalf("missing dir: got %d, want 404", code)
	}
	// outside the workspace: absolute, and a new one there too
	out := t.TempDir()
	os.WriteFile(filepath.Join(out, "there.txt"), []byte("t\n"), 0o644)
	p := ask(out, "there.txt", "fresh.txt")
	if len(p.Paths) != 2 || !filepath.IsAbs(p.Paths[0]) || !filepath.IsAbs(p.Paths[1]) {
		t.Fatalf("external files: %+v", p)
	}
	if filepath.Base(p.Paths[1]) != "fresh.txt" {
		t.Fatalf("external new file: %+v", p)
	}
	// a directory argument re-anchors and asks for the tree (netrw)
	if p := ask(repo, "."); !p.Tree || len(p.Paths) != 0 {
		t.Fatalf("dir arg: %+v", p)
	}
}

// The edit lifecycle over the HTTP surface: ack flips acked, done closes the
// long-poll with the code, and the poll that observes done retires the entry.
func TestEditLifecycle(t *testing.T) {
	h := &Host{edits: map[string]*editState{
		"e1": {session: "s1", doneCh: make(chan struct{}), created: time.Now()},
	}}

	get := func(path string) map[string]any {
		t.Helper()
		rec := httptest.NewRecorder()
		h.handleEdits(rec, httptest.NewRequest("GET", path, nil))
		if rec.Code != 200 {
			t.Fatalf("GET %s: %d %s", path, rec.Code, rec.Body)
		}
		var out map[string]any
		json.Unmarshal(rec.Body.Bytes(), &out)
		return out
	}
	post := func(path, body string) int {
		t.Helper()
		rec := httptest.NewRecorder()
		h.handleEdits(rec, httptest.NewRequest("POST", path, strings.NewReader(body)))
		return rec.Code
	}

	if st := get("/edits/e1"); st["acked"] != false || st["done"] != false {
		t.Fatalf("fresh edit: %v", st)
	}
	if code := post("/edits/e1/ack", ""); code != 204 {
		t.Fatalf("ack: %d", code)
	}
	if st := get("/edits/e1"); st["acked"] != true || st["done"] != false {
		t.Fatalf("acked edit: %v", st)
	}

	// done from another goroutine unblocks a parked long-poll
	go func() {
		time.Sleep(50 * time.Millisecond)
		post("/edits/e1/done", `{"code":1}`)
	}()
	start := time.Now()
	st := get("/edits/e1?wait=10")
	if time.Since(start) > 5*time.Second {
		t.Fatal("wait did not unblock on done")
	}
	if st["done"] != true || st["code"] != float64(1) {
		t.Fatalf("done edit: %v", st)
	}

	// the observing poll retired the entry
	rec := httptest.NewRecorder()
	h.handleEdits(rec, httptest.NewRequest("GET", "/edits/e1", nil))
	if rec.Code != 404 {
		t.Fatalf("retired edit should 404, got %d", rec.Code)
	}

	// done twice must not double-close doneCh (would panic)
	h.editMu.Lock()
	h.edits["e2"] = &editState{session: "s", doneCh: make(chan struct{}), created: time.Now()}
	h.editMu.Unlock()
	post("/edits/e2/done", `{"code":0}`)
	post("/edits/e2/done", `{"code":0}`)
}

package host

import (
	"encoding/json"
	"net/http/httptest"
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

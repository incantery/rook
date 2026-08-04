package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/incantery/rook/plugins/internal/transcript"
)

// The whole loop, in process: a transcript that is WORKING on the first
// pass finishes its turn, and one poll later the digest is in the store.
// This is the test that would catch the baseline pass summarizing, the
// trigger misreading the edge, or the scanner and the summarizer
// disagreeing about what a session is.
func TestWatchDigestsAFinishingTurnOnce(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		io.WriteString(w, completion("The refactor landed.\n- Tests stay green.", 100, 20))
	}))
	defer srv.Close()

	dir := t.TempDir()
	proj := filepath.Join(dir, "-Users-u-proj")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(proj, "sess1.jsonl")
	now := time.Now().UTC()
	stamp := func(d time.Duration) string { return now.Add(d).Format("2006-01-02T15:04:05.000Z") }
	// Mid-turn: a tool call with nothing back yet reads as working.
	working := fmt.Sprintf(`{"type":"user","timestamp":%q,"cwd":"/Users/u/proj","message":{"role":"user","content":"do the thing"}}
{"type":"assistant","timestamp":%q,"message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1"}]}}
`, stamp(-time.Minute), stamp(-30*time.Second))
	if err := os.WriteFile(path, []byte(working), 0o644); err != nil {
		t.Fatal(err)
	}

	sc := &transcript.Scanner{Dir: dir, Window: time.Hour, Idle: 10 * time.Minute, Quiet: time.Minute, Max: 20}
	st := &store{keep: 10}
	z := &Summarizer{Client: srv.Client(), Base: srv.URL, Key: "k", Model: "gpt-5-mini"}
	go watch(sc, st, z, 25*time.Millisecond, 5)

	// Let the baseline pass see "working", then finish the turn.
	time.Sleep(100 * time.Millisecond)
	finished := fmt.Sprintf(`{"type":"assistant","timestamp":%q,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":%q}]}}
`, stamp(-time.Second), strings.Repeat("a long and verbose reply ", 10))
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString(finished)
	f.Close()

	deadline := time.Now().Add(5 * time.Second)
	for len(st.list()) == 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	ds := st.list()
	if len(ds) != 1 {
		t.Fatalf("digests: %d (api calls: %d)", len(ds), calls)
	}
	if ds[0].Headline != "The refactor landed." || ds[0].SessionID != "sess1" {
		t.Fatalf("digest: %+v", ds[0])
	}
	// The state now SITS at needs-you: more polls must not mean more bills.
	time.Sleep(150 * time.Millisecond)
	if got := len(st.list()); got != 1 || calls != 1 {
		t.Fatalf("resummarized a finished turn: digests=%d calls=%d", got, calls)
	}
}

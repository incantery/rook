package host

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

// docOf fetches a thread's document projection.
func docOf(t *testing.T, c *wtClient, id int64) (content string, resolved bool) {
	t.Helper()
	code, raw := c.do(t, "GET", fmt.Sprintf("/threads/%d/doc", id), nil)
	if code != 200 {
		t.Fatalf("GET doc: %d %s", code, raw)
	}
	var res struct {
		Content  string `json:"content"`
		Resolved bool   `json:"resolved"`
	}
	if err := json.Unmarshal([]byte(raw), &res); err != nil {
		t.Fatal(err)
	}
	return res.Content, res.Resolved
}

func mkThread(t *testing.T, c *wtClient, body string) ThreadInfo {
	t.Helper()
	code, raw := c.do(t, "POST", "/workspaces/src/threads",
		map[string]any{"path": "a.txt", "startLine": 1, "endLine": 1, "body": body})
	if code != 200 {
		t.Fatalf("create thread: %d %s", code, raw)
	}
	var th ThreadInfo
	if err := json.Unmarshal([]byte(raw), &th); err != nil {
		t.Fatal(err)
	}
	return th
}

func TestThreadDocRoundTrip(t *testing.T) {
	h, srv, _ := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}
	th := mkThread(t, c, "why is this here?")

	doc, resolved := docOf(t, c, th.ID)
	if resolved {
		t.Fatal("fresh thread must not be resolved")
	}
	for _, want := range []string{
		fmt.Sprintf("thread: %d", th.ID),
		"anchor: a.txt:1 (modified)",
		"why is this here?",
		scissorsLine,
	} {
		if !strings.Contains(doc, want) {
			t.Fatalf("doc missing %q:\n%s", want, doc)
		}
	}
	if !strings.HasSuffix(doc, scissorsLine+"\n") {
		t.Fatalf("empty-draft doc must end at the scissors:\n%s", doc)
	}

	// :w — append a tail, save, read back: the draft rides the doc
	tail := "\nand a second thought\n"
	if code, raw := c.do(t, "POST", fmt.Sprintf("/threads/%d/doc", th.ID),
		map[string]string{"content": doc + tail}); code != 204 {
		t.Fatalf("save: %d %s", code, raw)
	}
	doc2, _ := docOf(t, c, th.ID)
	if doc2 != doc+tail {
		t.Fatalf("draft did not ride the doc:\n%q\nwant\n%q", doc2, doc+tail)
	}
}

func TestThreadDocPrefixCheck(t *testing.T) {
	h, srv, _ := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}
	th := mkThread(t, c, "original question")
	doc, _ := docOf(t, c, th.ID)

	// hand-mangled history → 409 carrying the fresh doc (the splice contract)
	mangled := strings.Replace(doc, "original question", "rewritten history", 1) + "\ntail\n"
	code, raw := c.do(t, "POST", fmt.Sprintf("/threads/%d/doc", th.ID),
		map[string]string{"content": mangled})
	if code != 409 {
		t.Fatalf("mangled save: %d %s (want 409)", code, raw)
	}
	var res struct {
		Content string `json:"content"`
	}
	if err := json.Unmarshal([]byte(raw), &res); err != nil || res.Content != doc {
		t.Fatalf("409 must carry the fresh doc: %v %q", err, res.Content)
	}

	// the splice: fresh prefix + the same tail saves clean
	if code, raw := c.do(t, "POST", fmt.Sprintf("/threads/%d/doc", th.ID),
		map[string]string{"content": res.Content + "\ntail\n"}); code != 204 {
		t.Fatalf("spliced save: %d %s", code, raw)
	}

	// a concurrent agent reply grows the history — the stale doc now 409s
	if code, _ := c.do(t, "POST", fmt.Sprintf("/threads/%d/comments", th.ID),
		map[string]string{"body": "the answer", "author": "agent"}); code != 204 {
		t.Fatal("agent reply failed")
	}
	if code, _ := c.do(t, "POST", fmt.Sprintf("/threads/%d/doc", th.ID),
		map[string]string{"content": doc + "\ntail\n"}); code != 409 {
		t.Fatal("stale prefix after agent reply: want 409")
	}
}

func TestThreadDocNoteAndAsk(t *testing.T) {
	h, srv, _ := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	// note on an empty draft is refused — there is nothing to say
	th := mkThread(t, c, "opening comment")
	if code, _ := c.do(t, "POST", fmt.Sprintf("/threads/%d/note", th.ID), nil); code != 400 {
		t.Fatal("note on empty draft: want 400")
	}

	// :w then note — the draft crystallizes as a user comment and clears
	doc, _ := docOf(t, c, th.ID)
	if code, _ := c.do(t, "POST", fmt.Sprintf("/threads/%d/doc", th.ID),
		map[string]string{"content": doc + "\na note for later\n"}); code != 204 {
		t.Fatal("save failed")
	}
	if code, _ := c.do(t, "POST", fmt.Sprintf("/threads/%d/note", th.ID), nil); code != 204 {
		t.Fatal("note failed")
	}
	got := h.reg.getThread(th.ID)
	if n := len(got.Comments); n != 2 || got.Comments[1].Author != "user" ||
		got.Comments[1].Body != "a note for later" {
		t.Fatalf("crystallized comment: %+v", got.Comments)
	}
	if got.Draft != "" {
		t.Fatalf("draft must clear on note: %q", got.Draft)
	}
	if got.State != "pending" {
		t.Fatalf("note must not submit: %s", got.State)
	}
	// the crystallized comment is now history — above the scissors
	doc2, _ := docOf(t, c, th.ID)
	if !strings.Contains(doc2[:strings.Index(doc2, scissorsPrefix)], "a note for later") {
		t.Fatalf("note must land above the scissors:\n%s", doc2)
	}

	// ask: crystallize + submit + nudge (stubbed)
	var nudged string
	h.nudgeFn = func(ws, prompt string) (string, string, error) {
		nudged = prompt
		return "typed", "s1", nil
	}
	if code, _ := c.do(t, "POST", fmt.Sprintf("/threads/%d/doc", th.ID),
		map[string]string{"content": doc2 + "\nplease explain\n"}); code != 204 {
		t.Fatal("save failed")
	}
	if code, raw := c.do(t, "POST", fmt.Sprintf("/threads/%d/ask", th.ID), nil); code != 200 {
		t.Fatalf("ask: %d %s", code, raw)
	}
	got = h.reg.getThread(th.ID)
	if got.State != "open" || got.Draft != "" || len(got.Comments) != 3 {
		t.Fatalf("ask transitions: state=%s draft=%q comments=%d",
			got.State, got.Draft, len(got.Comments))
	}
	if nudged == "" || !strings.Contains(nudged, fmt.Sprintf("thread %d", th.ID)) {
		t.Fatalf("nudge must name the thread: %q", nudged)
	}

	// ask whose nudge fails records the deliver error — the honest wait
	th2 := mkThread(t, c, "second thread")
	doc3, _ := docOf(t, c, th2.ID)
	if code, _ := c.do(t, "POST", fmt.Sprintf("/threads/%d/doc", th2.ID),
		map[string]string{"content": doc3 + "\nhello?\n"}); code != 204 {
		t.Fatal("save failed")
	}
	h.nudgeFn = func(ws, prompt string) (string, string, error) {
		return "", "", fmt.Errorf("no responder")
	}
	if code, _ := c.do(t, "POST", fmt.Sprintf("/threads/%d/ask", th2.ID), nil); code != 500 {
		t.Fatal("failed nudge: want 500")
	}
	got = h.reg.getThread(th2.ID)
	if got.DeliverError == "" || got.State != "open" {
		t.Fatalf("deliver error must be recorded: %+v", got)
	}
	// ask on an empty draft is refused like note
	if code, _ := c.do(t, "POST", fmt.Sprintf("/threads/%d/ask", th2.ID), nil); code != 400 {
		t.Fatal("ask on empty draft: want 400")
	}
}

func TestThreadDocEmptyCreateAndDelete(t *testing.T) {
	h, srv, _ := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	// gt-create: empty body → a thread with zero comments
	th := mkThread(t, c, "")
	if got := h.reg.getThread(th.ID); len(got.Comments) != 0 {
		t.Fatalf("empty create must have no comments: %+v", got.Comments)
	}
	doc, _ := docOf(t, c, th.ID)
	if !strings.Contains(doc, scissorsLine) {
		t.Fatalf("comment-less doc still carries the scissors:\n%s", doc)
	}

	// the abort path: :q on the untouched thread deletes it and its blob
	if code, _ := c.do(t, "DELETE", fmt.Sprintf("/threads/%d", th.ID), nil); code != 204 {
		t.Fatal("delete of empty thread failed")
	}
	if h.reg.getThread(th.ID) != nil {
		t.Fatal("thread must be gone")
	}
	if h.reg.getAnchorBlob(th.BlobSHA) != nil {
		t.Fatal("comment-less thread must not hold its anchor blob past deletion")
	}
	if code, _ := c.do(t, "DELETE", fmt.Sprintf("/threads/%d", th.ID), nil); code != 404 {
		t.Fatal("double delete: want 404")
	}

	// a thread with content refuses the delete door
	th2 := mkThread(t, c, "real content")
	if code, _ := c.do(t, "DELETE", fmt.Sprintf("/threads/%d", th2.ID), nil); code != 409 {
		t.Fatal("delete of commented thread: want 409")
	}
	// ...and so does one carrying only a draft
	th3 := mkThread(t, c, "")
	doc3, _ := docOf(t, c, th3.ID)
	if code, _ := c.do(t, "POST", fmt.Sprintf("/threads/%d/doc", th3.ID),
		map[string]string{"content": doc3 + "\nhalf a thought"}); code != 204 {
		t.Fatal("save failed")
	}
	if code, _ := c.do(t, "DELETE", fmt.Sprintf("/threads/%d", th3.ID), nil); code != 409 {
		t.Fatal("delete of drafted thread: want 409")
	}
}

func TestThreadDocResolved(t *testing.T) {
	h, srv, _ := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}
	th := mkThread(t, c, "done deal")
	if code, _ := c.do(t, "POST", fmt.Sprintf("/threads/%d/resolve", th.ID),
		map[string]string{"by": "user"}); code != 204 {
		t.Fatal("resolve failed")
	}
	doc, resolved := docOf(t, c, th.ID)
	if !resolved {
		t.Fatal("doc must report resolved")
	}
	if strings.Contains(doc, scissorsPrefix) {
		t.Fatalf("resolved doc must have no scissors:\n%s", doc)
	}
	// saving into a resolved thread is refused
	if code, _ := c.do(t, "POST", fmt.Sprintf("/threads/%d/doc", th.ID),
		map[string]string{"content": doc + "tail"}); code != 409 {
		t.Fatal("save into resolved: want 409")
	}
}

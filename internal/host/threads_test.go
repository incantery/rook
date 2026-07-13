package host

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// threadReg is a registry over a throwaway data dir — store tests need
// no Host, no HTTP.
func threadReg(t *testing.T) *registry {
	t.Helper()
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	r := loadRegistry()
	if r.db == nil {
		t.Fatal("test registry has no db")
	}
	return r
}

func TestThreadStoreCRUD(t *testing.T) {
	r := threadReg(t)

	id, err := r.createThread(&ThreadInfo{
		Workspace: "ws", Path: "a.txt", StartLine: 2, EndLine: 3,
		Side: "modified", BlobSHA: "abc", CommitSHA: "deadbeef",
		AnchorText: "two\nthree",
	}, "why is this like this?")
	if err != nil {
		t.Fatal(err)
	}

	th := r.getThread(id)
	if th == nil || th.State != "pending" || len(th.Comments) != 1 {
		t.Fatalf("getThread: %+v", th)
	}
	if th.Comments[0].Author != "user" || th.Comments[0].Body != "why is this like this?" {
		t.Fatalf("first comment: %+v", th.Comments[0])
	}

	// list filters: workspace, state, path
	if got := len(r.listThreads("ws", "", "")); got != 1 {
		t.Fatalf("list ws: %d", got)
	}
	if got := len(r.listThreads("other", "", "")); got != 0 {
		t.Fatalf("list other ws: %d", got)
	}
	if got := len(r.listThreads("ws", "open", "")); got != 0 {
		t.Fatalf("list open: %d", got)
	}
	if got := len(r.listThreads("ws", "pending", "a.txt")); got != 1 {
		t.Fatalf("list pending a.txt: %d", got)
	}

	// submit: pending → open, stamped
	if n := r.submitThreads("ws"); n != 1 {
		t.Fatalf("submit: %d", n)
	}
	th = r.getThread(id)
	if th.State != "open" || th.Submitted == nil {
		t.Fatalf("after submit: %+v", th)
	}
	// awaiting agent: open + last comment by user
	if n := r.threadsAwaitingAgent("ws"); n != 1 {
		t.Fatalf("awaiting: %d", n)
	}

	// agent replies — no longer awaiting
	if err := r.addThreadComment(id, "agent", "t1", "moved the guard"); err != nil {
		t.Fatal(err)
	}
	if n := r.threadsAwaitingAgent("ws"); n != 0 {
		t.Fatalf("awaiting after reply: %d", n)
	}
	th = r.getThread(id)
	if len(th.Comments) != 2 || th.Comments[1].AgentSession != "t1" {
		t.Fatalf("comments after reply: %+v", th.Comments)
	}

	// resolve by agent, user reopens → agent_reopens increments
	if err := r.resolveThread(id, "agent"); err != nil {
		t.Fatal(err)
	}
	th = r.getThread(id)
	if th.State != "resolved" || th.ResolvedBy != "agent" {
		t.Fatalf("after resolve: %+v", th)
	}
	if err := r.resolveThread(id, "user"); err != errThreadState {
		t.Fatalf("double resolve: %v", err)
	}
	if err := r.reopenThread(id, "user"); err != nil {
		t.Fatal(err)
	}
	th = r.getThread(id)
	if th.State != "open" || th.ResolvedBy != "" || th.AgentReopens != 1 {
		t.Fatalf("after reopen: %+v", th)
	}
	if err := r.reopenThread(id, "user"); err != errThreadState {
		t.Fatalf("reopen non-resolved: %v", err)
	}

	// unknown ids
	if r.getThread(999) != nil {
		t.Fatal("ghost thread")
	}
	if err := r.addThreadComment(999, "user", "", "x"); err == nil {
		t.Fatal("comment on ghost thread must error")
	}
}

func TestAnchorBlobs(t *testing.T) {
	r := threadReg(t)
	r.putAnchorBlob("sha1", []byte("hello\n"))
	r.putAnchorBlob("sha1", []byte("hello\n")) // dedup: second put is a no-op
	if got := r.getAnchorBlob("sha1"); string(got) != "hello\n" {
		t.Fatalf("blob: %q", got)
	}
	if r.getAnchorBlob("missing") != nil {
		t.Fatal("missing blob must be nil")
	}

	// prune keeps blobs referenced by unresolved threads only
	id, _ := r.createThread(&ThreadInfo{
		Workspace: "ws", Path: "a.txt", StartLine: 1, EndLine: 1,
		Side: "modified", BlobSHA: "sha1", AnchorText: "hello",
	}, "hm")
	r.putAnchorBlob("orphan", []byte("x"))
	r.pruneAnchorBlobs()
	if r.getAnchorBlob("sha1") == nil {
		t.Fatal("referenced blob pruned")
	}
	if r.getAnchorBlob("orphan") != nil {
		t.Fatal("orphan blob survived prune")
	}
	r.submitThreads("ws")
	r.resolveThread(id, "user")
	r.pruneAnchorBlobs()
	if r.getAnchorBlob("sha1") != nil {
		t.Fatal("blob for resolved-only thread survived prune")
	}
	// the resolved thread still renders (anchor_text), just outdated
	if th := r.getThread(id); th == nil || th.AnchorText != "hello" {
		t.Fatalf("resolved thread lost its text: %+v", th)
	}
}

func TestThreadCreateAndList(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}
	os.WriteFile(filepath.Join(repo, "f.txt"), []byte("l1\nl2\nl3\nl4\nl5\n"), 0o644)

	code, body := c.do(t, "POST", "/workspaces/src/threads", map[string]any{
		"path": "f.txt", "startLine": 2, "endLine": 3, "body": "why?"})
	if code != 200 {
		t.Fatalf("create: %d %s", code, body)
	}
	var th ThreadInfo
	json.Unmarshal([]byte(body), &th)
	if th.State != "pending" || th.AnchorText != "l2\nl3" || th.Side != "modified" ||
		th.CurrentStart != 2 || th.Outdated || len(th.Comments) != 1 {
		t.Fatalf("thread: %+v", th)
	}
	if th.BlobSHA == "" || th.CommitSHA == "" {
		t.Fatalf("anchor identity missing: %+v", th)
	}

	// the snapshot landed
	if h.reg.getAnchorBlob(th.BlobSHA) == nil {
		t.Fatal("anchor blob not stored")
	}

	// list re-anchors: insert 2 lines above the range
	os.WriteFile(filepath.Join(repo, "f.txt"), []byte("a\nb\nl1\nl2\nl3\nl4\nl5\n"), 0o644)
	code, body = c.do(t, "GET", "/workspaces/src/threads", nil)
	if code != 200 {
		t.Fatalf("list: %d %s", code, body)
	}
	var list []ThreadInfo
	json.Unmarshal([]byte(body), &list)
	if len(list) != 1 || list[0].CurrentStart != 4 || list[0].CurrentEnd != 5 || list[0].Outdated {
		t.Fatalf("re-anchored list: %+v", list)
	}

	// filters pass through
	code, body = c.do(t, "GET", "/workspaces/src/threads?state=open", nil)
	json.Unmarshal([]byte(body), &list)
	if code != 200 || len(list) != 0 {
		t.Fatalf("state filter: %d %+v", code, list)
	}

	// validation
	for name, req := range map[string]map[string]any{
		"no body":   {"path": "f.txt", "startLine": 1, "endLine": 1},
		"no path":   {"startLine": 1, "endLine": 1, "body": "x"},
		"bad range": {"path": "f.txt", "startLine": 3, "endLine": 2, "body": "x"},
		"oob range": {"path": "f.txt", "startLine": 1, "endLine": 99, "body": "x"},
		"bad side":  {"path": "f.txt", "startLine": 1, "endLine": 1, "side": "left", "body": "x"},
		"traversal": {"path": "../x", "startLine": 1, "endLine": 1, "body": "x"},
	} {
		if code, body := c.do(t, "POST", "/workspaces/src/threads", req); code != 400 {
			t.Errorf("%s: %d %s", name, code, body)
		}
	}
	if code, _ := c.do(t, "POST", "/workspaces/src/threads", map[string]any{
		"path": "missing.txt", "startLine": 1, "endLine": 1, "body": "x"}); code != 404 {
		t.Errorf("missing file: %d", code)
	}
	if code, _ := c.do(t, "GET", "/workspaces/nope/threads", nil); code != 404 {
		t.Errorf("unknown ws: %d", code)
	}

	// original side: anchored to the base's content (a.txt is committed
	// as "hello\n"; the working tree copy no longer matters)
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("edited\n"), 0o644)
	code, body = c.do(t, "POST", "/workspaces/src/threads", map[string]any{
		"path": "a.txt", "startLine": 1, "endLine": 1, "side": "original", "body": "gone?"})
	if code != 200 {
		t.Fatalf("original side: %d %s", code, body)
	}
	json.Unmarshal([]byte(body), &th)
	if th.AnchorText != "hello" || th.Side != "original" {
		t.Fatalf("original anchor: %+v", th)
	}
	// the diverged working tree must not brand a fresh original-side
	// thread outdated — it re-anchors against the base, not the tree.
	if th.Outdated {
		t.Fatalf("original side wrongly outdated on create: %+v", th)
	}
	if th.CommitSHA == "" {
		t.Fatalf("original side missing commitSha: %+v", th)
	}
	wantHead := strings.TrimSpace(gitT(t, repo, "rev-parse", "HEAD"))
	if th.CommitSHA != wantHead {
		t.Fatalf("original side commitSha: got %q want %q (head mode)", th.CommitSHA, wantHead)
	}

	// GET-list coherence: the original-side thread must still show as
	// not outdated even though the working tree has since diverged.
	code, body = c.do(t, "GET", "/workspaces/src/threads", nil)
	if code != 200 {
		t.Fatalf("list: %d %s", code, body)
	}
	json.Unmarshal([]byte(body), &list)
	var found *ThreadInfo
	for i := range list {
		if list[i].Side == "original" {
			found = &list[i]
		}
	}
	if found == nil {
		t.Fatal("original-side thread missing from list")
	}
	if found.Outdated {
		t.Fatalf("original-side thread outdated in list: %+v", found)
	}
}

func TestThreadCommentResolveReopen(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}
	os.WriteFile(filepath.Join(repo, "f.txt"), []byte("one\n"), 0o644)
	code, body := c.do(t, "POST", "/workspaces/src/threads", map[string]any{
		"path": "f.txt", "startLine": 1, "endLine": 1, "body": "hm"})
	if code != 200 {
		t.Fatalf("create: %d %s", code, body)
	}
	var th ThreadInfo
	json.Unmarshal([]byte(body), &th)
	id := fmt.Sprintf("%d", th.ID)

	// agent reply
	if code, body = c.do(t, "POST", "/threads/"+id+"/comments", map[string]any{
		"body": "fixed in abc123", "author": "agent", "agentSession": "t9"}); code != 204 {
		t.Fatalf("reply: %d %s", code, body)
	}
	got := h.reg.getThread(th.ID)
	if len(got.Comments) != 2 || got.Comments[1].Author != "agent" || got.Comments[1].AgentSession != "t9" {
		t.Fatalf("comments: %+v", got.Comments)
	}

	// bad author / empty body → 400
	if code, _ = c.do(t, "POST", "/threads/"+id+"/comments", map[string]any{
		"body": "x", "author": "root"}); code != 400 {
		t.Fatalf("bad author: %d", code)
	}
	if code, _ = c.do(t, "POST", "/threads/"+id+"/comments", map[string]any{
		"author": "user"}); code != 400 {
		t.Fatalf("empty body: %d", code)
	}

	// resolve by agent → reopen → verdict datum recorded; blob pruned on
	// resolve and the thread still renders
	if code, body = c.do(t, "POST", "/threads/"+id+"/resolve", map[string]any{"by": "agent"}); code != 204 {
		t.Fatalf("resolve: %d %s", code, body)
	}
	if h.reg.getAnchorBlob(th.BlobSHA) != nil {
		t.Fatal("blob should prune once no unresolved thread references it")
	}
	if code, _ = c.do(t, "POST", "/threads/"+id+"/resolve", map[string]any{"by": "user"}); code != 409 {
		t.Fatalf("double resolve: %d", code)
	}
	if code, _ = c.do(t, "POST", "/threads/"+id+"/reopen", nil); code != 204 {
		t.Fatalf("reopen: %d", code)
	}
	if got = h.reg.getThread(th.ID); got.AgentReopens != 1 || got.State != "open" {
		t.Fatalf("verdict datum: %+v", got)
	}
	if code, _ = c.do(t, "POST", "/threads/"+id+"/reopen", nil); code != 409 {
		t.Fatalf("reopen open thread: %d", code)
	}

	// agent reopening its own resolve must not count: resolve again, reopen as agent
	if code, _ = c.do(t, "POST", "/threads/"+id+"/resolve", map[string]any{"by": "agent"}); code != 204 {
		t.Fatalf("resolve again: %d", code)
	}
	if code, _ = c.do(t, "POST", "/threads/"+id+"/reopen", map[string]any{"by": "agent"}); code != 204 {
		t.Fatalf("reopen as agent: %d", code)
	}
	if got = h.reg.getThread(th.ID); got.AgentReopens != 1 {
		t.Fatalf("agent self-reopen must not increment: %+v", got)
	}

	// invalid by value
	if code, _ = c.do(t, "POST", "/threads/"+id+"/resolve", map[string]any{"by": "agent"}); code != 204 {
		t.Fatalf("resolve for invalid test: %d", code)
	}
	if code, _ = c.do(t, "POST", "/threads/"+id+"/reopen", map[string]any{"by": "root"}); code != 400 {
		t.Fatalf("invalid by value: %d", code)
	}

	// unknown id / bad routes
	if code, _ = c.do(t, "POST", "/threads/999/comments", map[string]any{"body": "x"}); code != 404 {
		t.Fatalf("ghost thread: %d", code)
	}
	if code, _ = c.do(t, "GET", "/threads/"+id+"/comments", nil); code != 404 {
		t.Fatalf("GET on thread route: %d", code)
	}
}

// threadHost is the pipe-pty fixture (draftHost's shape): one fake
// window in workspace "ws", claimed by transcript "t1" — the typed
// nudge lands on the readable end of the pipe.
func threadHost(t *testing.T) (*Host, *os.File, string) {
	t.Helper()
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	pr, pw, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pr.Close(); pw.Close() })
	repo := t.TempDir()
	gitT(t, repo, "init", "-b", "main")
	os.WriteFile(filepath.Join(repo, "f.txt"), []byte("one\ntwo\n"), 0o644)
	gitT(t, repo, "add", ".")
	gitT(t, repo, "commit", "-m", "init")
	h := &Host{
		sessions: map[string]*session{"w1": {info: SessionInfo{ID: "w1", Workspace: "ws"}, pty: pw}},
		reg:      loadRegistry(),
		aw:       newAgentWatch(),
		cwdCache: make(map[int]cwdEntry),
		claims:   map[string]string{"t1": "w1"},
		binds:    map[string]string{},
		drafts:   make(map[string]draftInfo),
	}
	if h.reg.db == nil {
		t.Fatal("test registry has no db")
	}
	h.reg.upsert("ws", repo, false)
	return h, pr, repo
}

func postWS(t *testing.T, h *Host, path string, body map[string]any) *httptest.ResponseRecorder {
	t.Helper()
	b, _ := json.Marshal(body)
	req := httptest.NewRequest("POST", path, bytes.NewReader(b))
	w := httptest.NewRecorder()
	h.handleWorkspace(w, req)
	return w
}

func TestThreadSubmitTypesNudge(t *testing.T) {
	h, ptyOut, _ := threadHost(t)

	// no threads at all → 400
	if w := postWS(t, h, "/workspaces/ws/threads/submit", nil); w.Code != 400 {
		t.Fatalf("empty submit: %d %s", w.Code, w.Body)
	}

	// two pending comments, one submit, one nudge naming both
	id1, _ := h.reg.createThread(&ThreadInfo{Workspace: "ws", Path: "f.txt",
		StartLine: 1, EndLine: 1, Side: "modified", BlobSHA: "s", AnchorText: "one"}, "a?")
	h.reg.createThread(&ThreadInfo{Workspace: "ws", Path: "f.txt",
		StartLine: 2, EndLine: 2, Side: "modified", BlobSHA: "s", AnchorText: "two"}, "b?")
	w := postWS(t, h, "/workspaces/ws/threads/submit", nil)
	if w.Code != 200 {
		t.Fatalf("submit: %d %s", w.Code, w.Body)
	}
	var res struct {
		Mode        string `json:"mode"`
		RookSession string `json:"rookSession"`
		Count       int    `json:"count"`
	}
	json.Unmarshal(w.Body.Bytes(), &res)
	if res.Mode != "typed" || res.RookSession != "w1" || res.Count != 2 {
		t.Fatalf("submit result: %+v", res)
	}
	line, err := bufio.NewReader(ptyOut).ReadString('\r')
	if err != nil || !strings.Contains(line, "2 review comment") || !strings.Contains(line, "rook-threads") {
		t.Fatalf("nudge on pty: %q (%v)", line, err)
	}
	if th := h.reg.getThread(id1); th.State != "open" {
		t.Fatalf("state after submit: %+v", th)
	}

	// re-nudge: zero pending but still awaiting the agent → nudge again
	w = postWS(t, h, "/workspaces/ws/threads/submit", nil)
	if w.Code != 200 {
		t.Fatalf("re-nudge: %d %s", w.Code, w.Body)
	}
	json.Unmarshal(w.Body.Bytes(), &res)
	if res.Mode != "typed" || res.Count != 0 {
		t.Fatalf("re-nudge result: %+v", res)
	}
	if _, err := bufio.NewReader(ptyOut).ReadString('\r'); err != nil {
		t.Fatalf("re-nudge pty: %v", err)
	}

	// agent replied to everything → nothing to submit → 400
	h.reg.addThreadComment(id1, "agent", "t1", "done")
	th2 := h.reg.listThreads("ws", "open", "")
	for _, x := range th2 {
		if x.ID != id1 {
			h.reg.addThreadComment(x.ID, "agent", "t1", "done")
		}
	}
	if w := postWS(t, h, "/workspaces/ws/threads/submit", nil); w.Code != 400 {
		t.Fatalf("drained submit: %d %s", w.Code, w.Body)
	}
}

// TestThreadSubmitMultipleClaimsPicksNewest verifies that when a workspace
// has multiple claimed claude sessions, the nudge goes to the one with the
// highest numeric ID (the newest/latest-started claude).
func TestThreadSubmitMultipleClaimsPicksNewest(t *testing.T) {
	t.Helper()
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	// Set up two pipes: one for w1 (claimed), one for w2 (newest claimed)
	pr1, pw1, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	pr2, pw2, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pr1.Close(); pw1.Close(); pr2.Close(); pw2.Close() })

	repo := t.TempDir()
	gitT(t, repo, "init", "-b", "main")
	os.WriteFile(filepath.Join(repo, "f.txt"), []byte("one\ntwo\n"), 0o644)
	gitT(t, repo, "add", ".")
	gitT(t, repo, "commit", "-m", "init")

	// Create host with two claimed sessions: w1 (older) and w2 (newer)
	h := &Host{
		sessions: map[string]*session{
			"s1": {info: SessionInfo{ID: "s1", Workspace: "ws"}, pty: pw1},
			"s2": {info: SessionInfo{ID: "s2", Workspace: "ws"}, pty: pw2},
		},
		reg:      loadRegistry(),
		aw:       newAgentWatch(),
		cwdCache: make(map[int]cwdEntry),
		claims:   map[string]string{"t1": "s1", "t2": "s2"},
		binds:    map[string]string{},
		drafts:   make(map[string]draftInfo),
	}
	if h.reg.db == nil {
		t.Fatal("test registry has no db")
	}
	h.reg.upsert("ws", repo, false)

	// Create a pending thread
	h.reg.createThread(&ThreadInfo{Workspace: "ws", Path: "f.txt",
		StartLine: 1, EndLine: 1, Side: "modified", BlobSHA: "s", AnchorText: "one"}, "test?")

	// Submit: should nudge s2 (highest id), not s1
	w := postWS(t, h, "/workspaces/ws/threads/submit", nil)
	if w.Code != 200 {
		t.Fatalf("submit: %d %s", w.Code, w.Body)
	}
	var res struct {
		Mode        string `json:"mode"`
		RookSession string `json:"rookSession"`
	}
	json.Unmarshal(w.Body.Bytes(), &res)
	if res.Mode != "typed" || res.RookSession != "s2" {
		t.Fatalf("submit result: got mode=%s session=%s, want typed/s2", res.Mode, res.RookSession)
	}

	// Verify the nudge arrived on pr2 (w2's read end), not pr1
	line, err := bufio.NewReader(pr2).ReadString('\r')
	if err != nil || !strings.Contains(line, "1 review comment") {
		t.Fatalf("nudge on pr2: %q (%v)", line, err)
	}

	// pr1 should be empty (the nudge went to pr2, not pr1)
	pr1.SetReadDeadline(time.Now().Add(10 * time.Millisecond))
	if _, err := bufio.NewReader(pr1).ReadString('\r'); err == nil {
		t.Fatal("nudge unexpectedly arrived on pr1 (should only go to newest s2)")
	}
}

// TestThreadSubmitDeadPtyFallthrough verifies that when a claimed session's
// pty is dead/closed, submit falls through to spawning a responder instead
// of panicking or getting stuck on a nil session.
func TestThreadSubmitDeadPtyFallthrough(t *testing.T) {
	t.Helper()
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	pr, pw, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pr.Close() })

	repo := t.TempDir()
	gitT(t, repo, "init", "-b", "main")
	os.WriteFile(filepath.Join(repo, "f.txt"), []byte("one\n"), 0o644)
	gitT(t, repo, "add", ".")
	gitT(t, repo, "commit", "-m", "init")

	// Create host with one claimed session whose write-end is closed
	pw.Close() // Close the write end → pty.Write will fail
	h := &Host{
		sessions: map[string]*session{
			"s1": {info: SessionInfo{ID: "s1", Workspace: "ws"}, pty: pw},
		},
		reg:      loadRegistry(),
		aw:       newAgentWatch(),
		cwdCache: make(map[int]cwdEntry),
		claims:   map[string]string{"t1": "s1"},
		binds:    map[string]string{},
		drafts:   make(map[string]draftInfo),
	}
	if h.reg.db == nil {
		t.Fatal("test registry has no db")
	}
	h.reg.upsert("ws", repo, false)

	// Create a pending thread
	h.reg.createThread(&ThreadInfo{Workspace: "ws", Path: "f.txt",
		StartLine: 1, EndLine: 1, Side: "modified", BlobSHA: "s", AnchorText: "one"}, "test?")

	// Submit: pty.Write fails on the closed pipe → should spawn instead
	w := postWS(t, h, "/workspaces/ws/threads/submit", nil)
	if w.Code != 200 {
		t.Fatalf("submit: %d %s", w.Code, w.Body)
	}
	var res struct {
		Mode        string `json:"mode"`
		RookSession string `json:"rookSession"`
	}
	json.Unmarshal(w.Body.Bytes(), &res)
	if res.Mode != "spawned" {
		t.Fatalf("submit result: got mode=%s want spawned", res.Mode)
	}

	// Verify the spawned responder is live
	if h.get(res.RookSession) == nil {
		t.Fatal("responder session not live")
	}

	// Clean up
	h.kill(res.RookSession)
}

func TestThreadSubmitSpawnsResponder(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}
	os.WriteFile(filepath.Join(repo, "f.txt"), []byte("one\n"), 0o644)
	c.do(t, "POST", "/workspaces/src/threads", map[string]any{
		"path": "f.txt", "startLine": 1, "endLine": 1, "body": "hm"})

	// no claimed claude window in "src" → spawn path
	code, body := c.do(t, "POST", "/workspaces/src/threads/submit", nil)
	if code != 200 {
		t.Fatalf("submit: %d %s", code, body)
	}
	var res struct {
		Mode        string `json:"mode"`
		RookSession string `json:"rookSession"`
	}
	json.Unmarshal([]byte(body), &res)
	if res.Mode != "spawned" || res.RookSession == "" {
		t.Fatalf("spawn result: %+v", res)
	}
	if h.get(res.RookSession) == nil {
		t.Fatal("responder session not live")
	}
	h.kill(res.RookSession) // no orphan shells from tests
}

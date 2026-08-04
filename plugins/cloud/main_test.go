package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/incantery/rook/plugins/internal/transcript"
)

var t0 = time.Date(2026, 8, 4, 9, 0, 0, 0, time.UTC)

func fixtureSessions() []transcript.Session {
	return []transcript.Session{
		{ID: "a", Title: "fix the socket bind", Cwd: "/Users/u/src/rook", Branch: "main",
			State: transcript.StateNeedsYou, LastText: "The fix is in. Ship it?", Mtime: t0},
		{ID: "b", Title: "migrate the schema", Cwd: "/Users/u/src/rook", Branch: "main",
			State: transcript.StateWorking, Mtime: t0},
		{ID: "c", Title: "docs pass", Cwd: "/Users/u/src/dora",
			State: transcript.StateBlocked, Prompt: "run the deploy script", Mtime: t0},
		{ID: "d", Title: "old thing", Cwd: "/Users/u/src/dora",
			State: transcript.StateIdle, Mtime: t0},
	}
}

func TestStatusFromSpeaksTheCloudsVocabulary(t *testing.T) {
	st := statusFrom(fixtureSessions(), "v0.42.0")
	if st.RookVersion != "v0.42.0" || st.Hostname == "" {
		t.Fatalf("header: %+v", st)
	}
	if len(st.Workspaces) != 2 {
		t.Fatalf("workspaces: %+v", st.Workspaces)
	}
	// Sorted by name: dora, rook.
	dora, rook := st.Workspaces[0], st.Workspaces[1]
	if dora.Name != "dora" || rook.Name != "rook" {
		t.Fatalf("order: %q %q", dora.Name, rook.Name)
	}
	if rook.Attention != 1 || len(rook.Agents) != 2 {
		t.Fatalf("rook ws: %+v", rook)
	}
	if rook.Agents[0].State != "needs_input" || !strings.Contains(rook.Agents[0].Ask, "Ship it?") {
		t.Fatalf("needs-you agent: %+v", rook.Agents[0])
	}
	if rook.Agents[1].State != "working" || rook.Agents[1].Ask != "" {
		t.Fatalf("working agent carries no ask: %+v", rook.Agents[1])
	}
	// blocked? maps to needs_input — the approval you left the room on —
	// and carries the prompt, marked as an approval guess.
	if dora.Agents[0].State != "needs_input" || !strings.Contains(dora.Agents[0].Ask, "approval? run the deploy") {
		t.Fatalf("blocked agent: %+v", dora.Agents[0])
	}
	if dora.Agents[1].State != "quiet" {
		t.Fatalf("idle agent: %+v", dora.Agents[1])
	}
}

// fakeCloud is api.rookide.com in miniature: whoami and status behind
// one bearer token, recording what arrives.
type fakeCloud struct {
	mu       sync.Mutex
	token    string
	statuses []wireStatus
	auths    []string
	dead     bool // flips every response to 401 — the revoked-token story
}

func (f *fakeCloud) handler() http.Handler {
	mux := http.NewServeMux()
	auth := func(next http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			f.mu.Lock()
			f.auths = append(f.auths, r.Header.Get("Authorization"))
			dead := f.dead
			tok := f.token
			f.mu.Unlock()
			if dead || r.Header.Get("Authorization") != "Bearer "+tok {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
			next(w, r)
		}
	}
	mux.HandleFunc("GET /v1/whoami", auth(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"machineId":"m1","name":"seth-mbp"}`)
	}))
	mux.HandleFunc("POST /v1/status", auth(func(w http.ResponseWriter, r *http.Request) {
		var st wireStatus
		json.NewDecoder(r.Body).Decode(&st)
		f.mu.Lock()
		f.statuses = append(f.statuses, st)
		f.mu.Unlock()
		w.WriteHeader(http.StatusNoContent) // what the real server sends
	}))
	return mux
}

func (f *fakeCloud) pushed() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.statuses)
}

func testBridge(t *testing.T, api, token string) *bridge {
	t.Helper()
	return &bridge{
		client: &http.Client{Timeout: 5 * time.Second},
		api:    api,
		token:  token,
		nofile: "/nonexistent/cloud_token",
		sc:     &transcript.Scanner{Dir: t.TempDir(), Window: time.Hour, Idle: 10 * time.Minute, Quiet: time.Minute, Max: 20},
		names:  []string{"claude"},
		kick:   make(chan struct{}, 1),
	}
}

func TestWhoamiThenPushCarriesTheToken(t *testing.T) {
	f := &fakeCloud{token: "tok-1"}
	srv := httptest.NewServer(f.handler())
	defer srv.Close()
	br := testBridge(t, srv.URL, "tok-1")

	br.whoami()
	br.mu.Lock()
	name, id, lastErr := br.machineName, br.machineID, br.lastErr
	br.mu.Unlock()
	if id != "m1" || name != "seth-mbp" || lastErr != "" {
		t.Fatalf("whoami: %q %q %q", id, name, lastErr)
	}

	br.push(nil, map[int]transcript.PaneSample{})
	if f.pushed() != 1 {
		t.Fatalf("pushes: %d", f.pushed())
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.auths[len(f.auths)-1] != "Bearer tok-1" {
		t.Fatalf("auth: %q", f.auths[len(f.auths)-1])
	}
	if f.statuses[0].Hostname == "" {
		t.Fatal("a push without a hostname is an anonymous machine")
	}
	// The panel row reads connected.
	row := items(br, t0)[0]
	if row.State != "up" || !strings.Contains(row.Title, "seth-mbp") {
		t.Fatalf("row: %+v", row)
	}
}

func TestRevokedTokenSaysSoAndStopsClaimingIdentity(t *testing.T) {
	f := &fakeCloud{token: "tok-1"}
	srv := httptest.NewServer(f.handler())
	defer srv.Close()
	br := testBridge(t, srv.URL, "tok-1")
	br.whoami()

	f.mu.Lock()
	f.dead = true
	f.mu.Unlock()
	br.push(nil, map[int]transcript.PaneSample{})

	br.mu.Lock()
	id, lastErr := br.machineID, br.lastErr
	br.mu.Unlock()
	if id != "" || !strings.Contains(lastErr, "revoked") {
		t.Fatalf("after 401: id=%q err=%q", id, lastErr)
	}
	row := items(br, t0)[0]
	if row.State != "error" || !strings.Contains(row.Title, "cloud.rookide.com") {
		t.Fatalf("row must say where to fix it: %+v", row)
	}
}

func TestUnreachableCloudIsWeatherNotDamage(t *testing.T) {
	br := testBridge(t, "http://127.0.0.1:1", "tok-1")
	br.whoami()
	br.mu.Lock()
	lastErr := br.lastErr
	br.mu.Unlock()
	if !strings.Contains(lastErr, "unreachable") {
		t.Fatalf("err: %q", lastErr)
	}
	row := items(br, t0)[0]
	if row.State != "error" {
		t.Fatalf("row: %+v", row)
	}
}

func TestNoTokenIsOnboardingNotAnError(t *testing.T) {
	br := testBridge(t, "http://unused", "")
	row := items(br, t0)[0]
	if row.State != "off" || !strings.Contains(row.Title, "cloud_token") {
		t.Fatalf("row: %+v", row)
	}
	rep := act(br, 1, json.RawMessage(`{"actionId":"push"}`))
	if rep.OK {
		t.Fatal("pushed with no token")
	}
}

func TestPushNowRingsTheDoorbellOnce(t *testing.T) {
	br := testBridge(t, "http://unused", "tok")
	if rep := act(br, 1, json.RawMessage(`{"actionId":"push"}`)); !rep.OK {
		t.Fatalf("push refused: %+v", rep)
	}
	// A second act while one is queued is fine — the doorbell holds one.
	if rep := act(br, 2, json.RawMessage(`{"actionId":"push"}`)); !rep.OK {
		t.Fatalf("second push refused: %+v", rep)
	}
	select {
	case <-br.kick:
	default:
		t.Fatal("the doorbell never rang")
	}
	select {
	case <-br.kick:
		t.Fatal("the doorbell rang twice for two acts — it should coalesce")
	default:
	}
}

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
			State: transcript.StateNeedsYou, LastText: "The fix is in. Ship it?", Mtime: t0,
			CtxTokens: 106_000, Model: "claude-fable-5"},
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
	// Every agent names its session — a phone-issued command needs the
	// handle — and context occupancy rides along when the transcript
	// reported usage, omitted (zero) when it never did.
	if rook.Agents[0].ID != "a" || rook.Agents[1].ID != "b" {
		t.Fatalf("agents must carry session ids: %+v", rook.Agents)
	}
	if rook.Agents[0].CtxPct != 53 {
		t.Fatalf("ctx pct: %+v", rook.Agents[0])
	}
	if rook.Agents[1].CtxPct != 0 {
		t.Fatalf("unknown ctx must stay omitted: %+v", rook.Agents[1])
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
	answers  []cloudAnswer  // the outbox /v1/answers serves
	acks     []string       // askIds acked via /v1/answers/ack
	commands []cloudCommand // the outbox /v1/commands serves
	cmdAcks  []string       // command ids acked via /v1/commands/ack
	dead     bool           // flips every response to 401 — the revoked-token story
}

func (f *fakeCloud) acked() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.acks...)
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
	mux.HandleFunc("GET /v1/answers", auth(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		out, _ := json.Marshal(map[string]any{"answers": f.answers})
		f.mu.Unlock()
		w.Write(out)
	}))
	mux.HandleFunc("POST /v1/answers/ack", auth(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			AskID string `json:"askId"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		f.acks = append(f.acks, body.AskID)
		f.mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	}))
	mux.HandleFunc("GET /v1/commands", auth(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		out, _ := json.Marshal(map[string]any{"commands": f.commands})
		f.mu.Unlock()
		w.Write(out)
	}))
	mux.HandleFunc("POST /v1/commands/ack", auth(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			ID string `json:"id"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		f.cmdAcks = append(f.cmdAcks, body.ID)
		f.mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
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
		// The spawn->prompt poll, at test speed.
		spawnTries: 3,
		spawnWait:  time.Millisecond,
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
	// The panel row reads connected — and names the non-default target,
	// because "connected" to the wrong cloud reads exactly like
	// connected to the right one.
	row := items(br, t0)[0]
	if row.State != "up" || !strings.Contains(row.Title, "seth-mbp") {
		t.Fatalf("row: %+v", row)
	}
	var apiField string
	for _, f := range row.Fields {
		if f.Key == "api" {
			apiField = f.Value
		}
	}
	if !strings.Contains(srv.URL, apiField) || apiField == "" {
		t.Fatalf("a non-default target must be named: %+v", row.Fields)
	}
}

func TestTheDefaultCloudNeedsNoNameTag(t *testing.T) {
	br := testBridge(t, defaultAPI, "tok")
	br.mu.Lock()
	br.machineID, br.machineName = "m1", "seth-mbp"
	br.mu.Unlock()
	for _, f := range items(br, t0)[0].Fields {
		if f.Key == "api" {
			t.Fatal("the default target labeled itself — noise on every healthy row")
		}
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

// chanWriter hands each frame the conn writes to a channel, so a test
// can play rook's half of the wire.
type chanWriter struct{ ch chan string }

func (w chanWriter) Write(p []byte) (int, error) {
	w.ch <- string(p)
	return len(p), nil
}

func withOutbox(f *fakeCloud, answers ...cloudAnswer) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.answers = answers
}

func needsInputSession() transcript.Session {
	return transcript.Session{
		ID: "sess1", Title: "fix the bind", Cwd: "/Users/u/src/rook",
		State: transcript.StateNeedsYou, LastText: "Ship it?", Mtime: t0,
	}
}

func agentPane() transcript.PaneActivity {
	return transcript.PaneActivity{ID: 7, Fg: "claude", Path: "/usr/local/bin/claude", Cwd: "/Users/u/src/rook"}
}

func TestAnswerRoundTripTypesOnceAndAcks(t *testing.T) {
	sess := needsInputSession()
	f := &fakeCloud{token: "tok"}
	srv := httptest.NewServer(f.handler())
	defer srv.Close()
	br := testBridge(t, srv.URL, "tok")
	withOutbox(f, cloudAnswer{AskID: askID(sess), Text: "yes — ship it, keep the test"})

	frames := make(chan string, 4)
	c := &conn{out: chanWriter{frames}}
	done := make(chan struct{})
	go func() {
		br.collect(c, []transcript.Session{sess}, []transcript.PaneActivity{agentPane()})
		close(done)
	}()
	frame := <-frames
	if !strings.Contains(frame, `"op":"session.send"`) || !strings.Contains(frame, `"pane":7`) || !strings.Contains(frame, "keep the test") {
		t.Fatalf("frame: %s", frame)
	}
	var req struct {
		ID uint64 `json:"id"`
	}
	json.Unmarshal([]byte(frame), &req)
	c.deliver(req.ID, true, "", nil)
	<-done
	if got := f.acked(); len(got) != 1 || got[0] != askID(sess) {
		t.Fatalf("acks: %v", got)
	}
	// A lost ack redelivers the same answer: it must re-ack, never
	// re-type.
	withOutbox(f, cloudAnswer{AskID: askID(sess), Text: "yes — ship it, keep the test"})
	br.collect(c, []transcript.Session{sess}, []transcript.PaneActivity{agentPane()})
	select {
	case fr := <-frames:
		t.Fatalf("typed twice: %s", fr)
	default:
	}
	if len(f.acked()) != 2 {
		t.Fatalf("the redelivery was not re-acked: %v", f.acked())
	}
}

func TestStaleAnswerIsAckedNeverTyped(t *testing.T) {
	sess := needsInputSession()
	f := &fakeCloud{token: "tok"}
	srv := httptest.NewServer(f.handler())
	defer srv.Close()
	br := testBridge(t, srv.URL, "tok")
	// The answer names the OLD ask; the session has since moved on.
	withOutbox(f, cloudAnswer{AskID: "sess1:deadbeef", Text: "yes"})

	frames := make(chan string, 1)
	br.collect(&conn{out: chanWriter{frames}}, []transcript.Session{sess}, []transcript.PaneActivity{agentPane()})
	select {
	case fr := <-frames:
		t.Fatalf("typed a stale answer: %s", fr)
	default:
	}
	if len(f.acked()) != 1 {
		t.Fatalf("stale answer must be acked away: %v", f.acked())
	}
	if note := items(br, t0); len(note) < 2 || !strings.Contains(note[1].Title, "stale") {
		t.Fatalf("the drop needs its receipt: %+v", note)
	}
}

func TestNoAgentPaneRetriesThenDrops(t *testing.T) {
	sess := needsInputSession()
	f := &fakeCloud{token: "tok"}
	srv := httptest.NewServer(f.handler())
	defer srv.Close()
	br := testBridge(t, srv.URL, "tok")
	shellPane := transcript.PaneActivity{ID: 1, Fg: "zsh", Path: "/bin/zsh", Cwd: sess.Cwd}

	for i := 0; i < 5; i++ {
		withOutbox(f, cloudAnswer{AskID: askID(sess), Text: "yes"})
		br.collect(nil, []transcript.Session{sess}, []transcript.PaneActivity{shellPane})
		if n := len(f.acked()); n != 0 {
			t.Fatalf("acked while still retrying (attempt %d): %d", i, n)
		}
	}
	withOutbox(f, cloudAnswer{AskID: askID(sess), Text: "yes"})
	br.collect(nil, []transcript.Session{sess}, []transcript.PaneActivity{shellPane})
	if n := len(f.acked()); n != 1 {
		t.Fatalf("the sixth miss must drop with an ack: %d", n)
	}
}

func TestAskIDRidesTheStatusForNeedsInputOnly(t *testing.T) {
	st := statusFrom(fixtureSessions(), "")
	var withID, withoutID int
	for _, w := range st.Workspaces {
		for _, a := range w.Agents {
			if a.State == "needs_input" {
				if a.AskID == "" {
					t.Fatalf("needs_input without askId: %+v", a)
				}
				withID++
			} else if a.AskID != "" {
				t.Fatalf("%s agent carries an askId: %+v", a.State, a)
			} else {
				withoutID++
			}
		}
	}
	if withID != 2 || withoutID != 2 {
		t.Fatalf("fixture spread: %d with, %d without", withID, withoutID)
	}
}

func withCommands(f *fakeCloud, cmds ...cloudCommand) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.commands = cmds
}

func (f *fakeCloud) cmdAcked() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.cmdAcks...)
}

func compactCmd(sessID string) cloudCommand {
	return cloudCommand{ID: "compact:" + sessID, Kind: "compact", SessionID: sessID}
}

// The command rail's happy path mirrors the answers': /compact typed
// into the agent's pane exactly once, delivered marked before the ack,
// and a redelivered command re-acked without a second keystroke.
func TestCompactCommandTypesOnceAndAcks(t *testing.T) {
	sess := needsInputSession()
	f := &fakeCloud{token: "tok"}
	srv := httptest.NewServer(f.handler())
	defer srv.Close()
	br := testBridge(t, srv.URL, "tok")
	withCommands(f, compactCmd(sess.ID))

	frames := make(chan string, 4)
	c := &conn{out: chanWriter{frames}}
	done := make(chan struct{})
	go func() {
		br.executeCommands(c, []transcript.Session{sess}, []transcript.PaneActivity{agentPane()})
		close(done)
	}()
	frame := <-frames
	if !strings.Contains(frame, `"op":"session.send"`) || !strings.Contains(frame, `"pane":7`) || !strings.Contains(frame, "/compact") {
		t.Fatalf("frame: %s", frame)
	}
	var req struct {
		ID uint64 `json:"id"`
	}
	json.Unmarshal([]byte(frame), &req)
	c.deliver(req.ID, true, "", nil)
	<-done
	if got := f.cmdAcked(); len(got) != 1 || got[0] != "compact:sess1" {
		t.Fatalf("acks: %v", got)
	}
	withCommands(f, compactCmd(sess.ID))
	br.executeCommands(c, []transcript.Session{sess}, []transcript.PaneActivity{agentPane()})
	select {
	case fr := <-frames:
		t.Fatalf("typed twice: %s", fr)
	default:
	}
	if len(f.cmdAcked()) != 2 {
		t.Fatalf("the redelivery was not re-acked: %v", f.cmdAcked())
	}
}

// A working session is left alone: typing /compact into a mid-turn
// composer interleaves with the agent's own work. Retried while the
// turn runs, dropped with its reason when patience runs out.
func TestCompactHoldsWhileWorkingThenDrops(t *testing.T) {
	sess := needsInputSession()
	sess.State = transcript.StateWorking
	f := &fakeCloud{token: "tok"}
	srv := httptest.NewServer(f.handler())
	defer srv.Close()
	br := testBridge(t, srv.URL, "tok")

	for i := 0; i < 5; i++ {
		withCommands(f, compactCmd(sess.ID))
		br.executeCommands(nil, []transcript.Session{sess}, []transcript.PaneActivity{agentPane()})
		if n := len(f.cmdAcked()); n != 0 {
			t.Fatalf("acked while the turn still ran (attempt %d): %d", i, n)
		}
	}
	withCommands(f, compactCmd(sess.ID))
	br.executeCommands(nil, []transcript.Session{sess}, []transcript.PaneActivity{agentPane()})
	if n := len(f.cmdAcked()); n != 1 {
		t.Fatalf("the sixth mid-turn miss must drop with an ack: %d", n)
	}
	if note := items(br, t0); len(note) < 2 || !strings.Contains(note[1].Title, "mid-turn") {
		t.Fatalf("the drop needs its receipt: %+v", note)
	}
}

// A command for a session that no longer exists, or of a kind this
// rook does not speak, is acked away with its reason — never guessed
// at, never left pending forever.
func TestUnknownSessionOrKindIsAckedAwayWithItsReason(t *testing.T) {
	sess := needsInputSession()
	f := &fakeCloud{token: "tok"}
	srv := httptest.NewServer(f.handler())
	defer srv.Close()
	br := testBridge(t, srv.URL, "tok")

	withCommands(f, compactCmd("nope"))
	br.executeCommands(nil, []transcript.Session{sess}, nil)
	if got := f.cmdAcked(); len(got) != 1 || got[0] != "compact:nope" {
		t.Fatalf("gone session: %v", got)
	}
	if note := items(br, t0); !strings.Contains(note[1].Title, "gone") {
		t.Fatalf("receipt: %+v", note)
	}

	withCommands(f, cloudCommand{ID: "reboot:x", Kind: "reboot", SessionID: sess.ID})
	br.executeCommands(nil, []transcript.Session{sess}, nil)
	if got := f.cmdAcked(); len(got) != 2 {
		t.Fatalf("unknown kind must ack: %v", got)
	}
	if note := items(br, t0); !strings.Contains(note[1].Title, "does not know") {
		t.Fatalf("receipt: %+v", note)
	}
}

// Resume spawns `claude --resume <id>` in the session's own directory.
// The id in that command comes from the LOCAL scanner, and the whole
// path re-acks without re-spawning on a lost ack.
func TestResumeSpawnsClaudeWithTheLocalSessionID(t *testing.T) {
	sess := needsInputSession()
	sess.State = transcript.StateIdle
	f := &fakeCloud{token: "tok"}
	srv := httptest.NewServer(f.handler())
	defer srv.Close()
	br := testBridge(t, srv.URL, "tok")
	withCommands(f, cloudCommand{ID: "resume:sess1", Kind: "resume", SessionID: "sess1"})

	frames := make(chan string, 4)
	c := &conn{out: chanWriter{frames}}
	done := make(chan struct{})
	go func() {
		br.executeCommands(c, []transcript.Session{sess}, nil)
		close(done)
	}()
	frame := <-frames
	if !strings.Contains(frame, `"op":"session.spawn"`) ||
		!strings.Contains(frame, "claude --resume sess1") ||
		!strings.Contains(frame, sess.Cwd) {
		t.Fatalf("frame: %s", frame)
	}
	var req struct {
		ID uint64 `json:"id"`
	}
	json.Unmarshal([]byte(frame), &req)
	c.deliver(req.ID, true, "", nil)
	<-done
	if got := f.cmdAcked(); len(got) != 1 || got[0] != "resume:sess1" {
		t.Fatalf("acks: %v", got)
	}
	withCommands(f, cloudCommand{ID: "resume:sess1", Kind: "resume", SessionID: "sess1"})
	br.executeCommands(c, []transcript.Session{sess}, nil)
	select {
	case fr := <-frames:
		t.Fatalf("resumed twice: %s", fr)
	default:
	}
	if len(f.cmdAcked()) != 2 {
		t.Fatalf("redelivery not re-acked: %v", f.cmdAcked())
	}
}

// A session that is already on a screen (a claude pane in its
// directory, and it is the directory's freshest) is not resumed into
// a second instance; and a session id that is not shell-safe is
// refused outright, because session.spawn's command reaches a shell.
func TestResumeRefusesOpenSessionsAndUnsafeIDs(t *testing.T) {
	sess := needsInputSession()
	f := &fakeCloud{token: "tok"}
	srv := httptest.NewServer(f.handler())
	defer srv.Close()
	br := testBridge(t, srv.URL, "tok")

	withCommands(f, cloudCommand{ID: "resume:sess1", Kind: "resume", SessionID: "sess1"})
	frames := make(chan string, 1)
	br.executeCommands(&conn{out: chanWriter{frames}}, []transcript.Session{sess}, []transcript.PaneActivity{agentPane()})
	select {
	case fr := <-frames:
		t.Fatalf("resumed an open session: %s", fr)
	default:
	}
	if got := f.cmdAcked(); len(got) != 1 {
		t.Fatalf("acks: %v", got)
	}
	if note := items(br, t0); !strings.Contains(note[1].Title, "already open") {
		t.Fatalf("receipt: %+v", note)
	}

	evil := sess
	evil.ID = "x; rm -rf ~"
	withCommands(f, cloudCommand{ID: "resume:x; rm -rf ~", Kind: "resume", SessionID: "x; rm -rf ~"})
	br.executeCommands(&conn{out: chanWriter{frames}}, []transcript.Session{evil}, nil)
	select {
	case fr := <-frames:
		t.Fatalf("an unsafe id reached session.spawn: %s", fr)
	default:
	}
	if note := items(br, t0); !strings.Contains(note[1].Title, "not shell-safe") {
		t.Fatalf("receipt: %+v", note)
	}
}

// The spawn round trip: `claude` (the literal string — the prompt is
// NOT in it) starts in the workspace's directory, then the prompt is
// typed into the NEW pane once it looks like claude, and the receipt
// says both hops landed.
func TestSpawnStartsClaudeThenTypesThePrompt(t *testing.T) {
	sess := needsInputSession() // maps workspace "rook" -> its cwd
	f := &fakeCloud{token: "tok"}
	srv := httptest.NewServer(f.handler())
	defer srv.Close()
	br := testBridge(t, srv.URL, "tok")
	withCommands(f, cloudCommand{ID: "spawn:rook:abc", Kind: "spawn", Workspace: "rook", Prompt: "fix the flaky test; keep the API"})

	frames := make(chan string, 8)
	c := &conn{out: chanWriter{frames}}
	done := make(chan struct{})
	// The old pane (id 7) exists BEFORE the spawn; the new claude pane
	// is id 9. The prompt must go to 9, never 7.
	go func() {
		br.executeCommands(c, []transcript.Session{sess}, []transcript.PaneActivity{agentPane()})
		close(done)
	}()
	reply := func(frame string, result string) uint64 {
		var req struct {
			ID uint64 `json:"id"`
		}
		json.Unmarshal([]byte(frame), &req)
		c.deliver(req.ID, true, "", json.RawMessage(result))
		return req.ID
	}
	spawnFrame := <-frames
	if !strings.Contains(spawnFrame, `"op":"session.spawn"`) || !strings.Contains(spawnFrame, `"command":"claude"`) {
		t.Fatalf("spawn frame: %s", spawnFrame)
	}
	if strings.Contains(spawnFrame, "flaky") {
		t.Fatalf("the prompt reached the shell command: %s", spawnFrame)
	}
	reply(spawnFrame, "null")
	actFrame := <-frames
	if !strings.Contains(actFrame, `"op":"panes.activity"`) {
		t.Fatalf("activity frame: %s", actFrame)
	}
	reply(actFrame, `{"panes":[{"id":7,"fg":"claude","path":"/usr/local/bin/claude","cwd":"/Users/u/src/rook"},{"id":9,"fg":"claude","path":"/usr/local/bin/claude","cwd":"/Users/u/src/rook"}]}`)
	sendFrame := <-frames
	if !strings.Contains(sendFrame, `"op":"session.send"`) || !strings.Contains(sendFrame, `"pane":9`) || !strings.Contains(sendFrame, "flaky test") {
		t.Fatalf("send frame: %s", sendFrame)
	}
	reply(sendFrame, "null")
	<-done
	if got := f.cmdAcked(); len(got) != 1 || got[0] != "spawn:rook:abc" {
		t.Fatalf("acks: %v", got)
	}
	if note := items(br, t0); !strings.Contains(note[1].Title, "handed it the prompt") {
		t.Fatalf("receipt: %+v", note)
	}
}

// A workspace the machine never showed the phone cannot be spawned
// into — the name maps through this machine's own sessions or not at
// all. And a promptless spawn is complete at the first hop.
func TestSpawnUnknownWorkspaceAndPromptless(t *testing.T) {
	sess := needsInputSession()
	f := &fakeCloud{token: "tok"}
	srv := httptest.NewServer(f.handler())
	defer srv.Close()
	br := testBridge(t, srv.URL, "tok")

	withCommands(f, cloudCommand{ID: "spawn:dora:x", Kind: "spawn", Workspace: "dora"})
	br.executeCommands(&conn{out: chanWriter{make(chan string, 1)}}, []transcript.Session{sess}, nil)
	if got := f.cmdAcked(); len(got) != 1 {
		t.Fatalf("unknown workspace must ack away: %v", got)
	}
	if note := items(br, t0); !strings.Contains(note[1].Title, "no workspace called dora") {
		t.Fatalf("receipt: %+v", note)
	}

	withCommands(f, cloudCommand{ID: "spawn:rook:0", Kind: "spawn", Workspace: "rook"})
	frames := make(chan string, 4)
	c := &conn{out: chanWriter{frames}}
	done := make(chan struct{})
	go func() {
		br.executeCommands(c, []transcript.Session{sess}, nil)
		close(done)
	}()
	frame := <-frames
	if !strings.Contains(frame, `"op":"session.spawn"`) {
		t.Fatalf("frame: %s", frame)
	}
	var req struct {
		ID uint64 `json:"id"`
	}
	json.Unmarshal([]byte(frame), &req)
	c.deliver(req.ID, true, "", nil)
	<-done
	select {
	case fr := <-frames:
		t.Fatalf("a promptless spawn kept talking: %s", fr)
	default:
	}
	if note := items(br, t0); !strings.Contains(note[1].Title, "started a session in rook") {
		t.Fatalf("receipt: %+v", note)
	}
}

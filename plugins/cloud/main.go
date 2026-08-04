// rook-plugin-cloud — the thin line to rook-cloud: this machine, made
// visible from your phone.
//
// It is the device half of the machine surface (rook-cloud
// internal/server/machines.go): a bearer token names the machine, GET
// /v1/whoami proves the provisioning, and POST /v1/status pushes a
// snapshot — workspaces, each with its agents and their honest states —
// that the fleet pages at cloud.rookide.com render. The ingest is
// last-write-wins by design, so a retry after a network blip is
// harmless and this plugin never needs a journal.
//
// The snapshot is derived, never stored: the same transcript scanner
// the watcher and the summarizer stand on, fused with panes.activity
// when granted. What the phone shows is what the panel would show —
// one membrane, another renderer (docs/agent/VISION.md).
//
// The token comes from $ROOK_CLOUD_TOKEN or --token-file. Missing
// token, dead token, unreachable cloud: all are panel rows that say
// exactly that, never a dead plugin — connectivity is configuration,
// not damage.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/incantery/rook/plugins/internal/transcript"
)

const version = "0.1.0"

func main() {
	api := flag.String("api", "https://api.rookide.com", "rook-cloud API base")
	tokenFile := flag.String("token-file", "", "machine token file (default ~/.config/rook/cloud_token)")
	interval := flag.Duration("interval", 20*time.Second, "status push interval")
	dir := flag.String("dir", "", "projects directory (default ~/.claude/projects)")
	window := flag.Duration("window", 48*time.Hour, "how far back sessions are reported")
	rookVersion := flag.String("rook-version", "", "reported rook version")
	busyRate := flag.Float64("busy-rate", 200, "pane output above this (bytes/sec) proves an agent is working")
	names := flag.String("claude-names", "claude,node", "foreground program names that count as Claude Code")
	flag.Parse()

	home, _ := os.UserHomeDir()
	if *dir == "" {
		if home == "" {
			fmt.Fprintln(os.Stderr, "no home directory and no --dir")
			os.Exit(1)
		}
		*dir = filepath.Join(home, ".claude", "projects")
	}
	if *tokenFile == "" && home != "" {
		*tokenFile = filepath.Join(home, ".config", "rook", "cloud_token")
	}

	br := &bridge{
		client:  &http.Client{Timeout: 15 * time.Second},
		api:     strings.TrimRight(*api, "/"),
		token:   readToken(*tokenFile),
		nofile:  *tokenFile,
		rookVer: *rookVersion,
		sc: &transcript.Scanner{
			Dir:    *dir,
			Window: *window,
			Idle:   10 * time.Minute,
			Quiet:  60 * time.Second,
			Max:    50,
		},
		names:    strings.Split(*names, ","),
		busyRate: *busyRate,
		kick:     make(chan struct{}, 1),
	}
	c := &conn{out: os.Stdout}
	if br.token != "" {
		go br.loop(c, *interval)
	}
	serve(c, br)
}

func readToken(path string) string {
	if t := strings.TrimSpace(os.Getenv("ROOK_CLOUD_TOKEN")); t != "" {
		return t
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// ---- the bridge ----

// bridge holds the connection truth the panel renders: who this machine
// is to the cloud, when the last push landed, and why it did not.
type bridge struct {
	client  *http.Client
	api     string
	nofile  string // where the token was looked for, for the notice row
	rookVer string

	sc       *transcript.Scanner
	names    []string
	busyRate float64
	kick     chan struct{} // the "push now" action's doorbell

	mu          sync.Mutex
	token       string
	machineName string
	machineID   string
	lastPush    time.Time
	lastErr     string
	agents      int // agents in the last snapshot, for the panel row
}

// loop is the heartbeat: whoami until it answers, then a status push
// every interval (or on the doorbell). Failures are recorded, never
// fatal — the network coming and going is weather, not damage.
func (br *bridge) loop(c *conn, interval time.Duration) {
	samples := map[int]transcript.PaneSample{}
	for {
		if br.machineIDLocked() == "" {
			br.whoami()
		}
		if br.machineIDLocked() != "" {
			br.push(c, samples)
		}
		select {
		case <-time.After(interval):
		case <-br.kick:
		}
	}
}

func (br *bridge) machineIDLocked() string {
	br.mu.Lock()
	defer br.mu.Unlock()
	return br.machineID
}

func (br *bridge) getToken() string {
	br.mu.Lock()
	defer br.mu.Unlock()
	return br.token
}

func (br *bridge) whoami() {
	req, err := http.NewRequest("GET", br.api+"/v1/whoami", nil)
	if err != nil {
		return
	}
	req.Header.Set("Authorization", "Bearer "+br.getToken())
	resp, err := br.client.Do(req)
	if err != nil {
		br.fail("cloud unreachable: " + err.Error())
		return
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if resp.StatusCode != 200 {
		br.fail(fmt.Sprintf("whoami: HTTP %d — is the token still valid?", resp.StatusCode))
		return
	}
	var w struct {
		MachineID string `json:"machineId"`
		Name      string `json:"name"`
	}
	if json.Unmarshal(raw, &w) != nil || w.MachineID == "" {
		br.fail("whoami: answer did not parse")
		return
	}
	br.mu.Lock()
	br.machineID = w.MachineID
	br.machineName = w.Name
	br.lastErr = ""
	br.mu.Unlock()
}

func (br *bridge) push(c *conn, samples map[int]transcript.PaneSample) {
	now := time.Now()
	sessions := br.sc.Scan(now)
	// No conn means no substrate (tests, and any future headless use):
	// the transcript's word stands alone, same as a withheld grant.
	var panes []transcript.PaneActivity
	if c != nil {
		panes = fetchActivity(c)
	}
	transcript.ComputeRates(samples, panes, now)
	transcript.Fuse(sessions, panes, br.names, br.busyRate, 45*time.Second)

	st := statusFrom(sessions, br.rookVer)
	body, err := json.Marshal(st)
	if err != nil {
		return
	}
	req, err := http.NewRequest("POST", br.api+"/v1/status", bytes.NewReader(body))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+br.getToken())
	resp, err := br.client.Do(req)
	if err != nil {
		br.fail("push: " + err.Error())
		return
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<12))
	if resp.StatusCode == 401 {
		// The machine was deleted — the token is dead and the cloud just
		// said so. Stop claiming an identity; keep trying whoami, so a
		// re-minted token in the same file resurrects the bridge.
		br.mu.Lock()
		br.machineID = ""
		br.machineName = ""
		br.lastErr = "token revoked — mint a new one at cloud.rookide.com and update " + br.nofile
		// A re-minted token in the same file resurrects the bridge; an
		// empty read keeps the dead one so the row keeps saying WHY.
		if t := readToken(br.nofile); t != "" {
			br.token = t
		}
		br.mu.Unlock()
		return
	}
	// The server answers 204 on a stored snapshot — accept the whole
	// success class; insisting on 200 called every good push an error.
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		br.fail(fmt.Sprintf("push: HTTP %d", resp.StatusCode))
		return
	}
	agents := 0
	for _, w := range st.Workspaces {
		agents += len(w.Agents)
	}
	br.mu.Lock()
	br.lastPush = now
	br.lastErr = ""
	br.agents = agents
	br.mu.Unlock()
}

func (br *bridge) fail(msg string) {
	br.mu.Lock()
	br.lastErr = msg
	br.mu.Unlock()
}

// ---- the snapshot ----

// The wire shapes of rook-cloud's machine.Status, reproduced: the
// server clamps and owns the schema; this side only has to speak it.
type wireStatus struct {
	Hostname    string          `json:"hostname,omitempty"`
	RookVersion string          `json:"rookVersion,omitempty"`
	Workspaces  []wireWorkspace `json:"workspaces,omitempty"`
}

type wireWorkspace struct {
	Name      string      `json:"name"`
	Branch    string      `json:"branch,omitempty"`
	Attention int         `json:"attention,omitempty"`
	Agents    []wireAgent `json:"agents,omitempty"`
}

type wireAgent struct {
	State     string    `json:"state"` // working | needs_input | quiet
	Title     string    `json:"title,omitempty"`
	Ask       string    `json:"ask,omitempty"`
	Model     string    `json:"model,omitempty"`
	LastEvent time.Time `json:"lastEvent,omitzero"`
}

// statusFrom folds sessions into the cloud's vocabulary. The mapping
// is deliberately conservative in one place: `blocked?` becomes
// needs_input, because a session that may be sitting on an approval is
// exactly what you left the room and want to know about.
func statusFrom(sessions []transcript.Session, rookVer string) wireStatus {
	host, _ := os.Hostname()
	st := wireStatus{Hostname: host, RookVersion: rookVer}

	byWS := map[string]*wireWorkspace{}
	var order []string
	for _, s := range sessions {
		name := filepath.Base(s.Cwd)
		if name == "" || name == "." || name == "/" {
			name = "?"
		}
		w, ok := byWS[name]
		if !ok {
			w = &wireWorkspace{Name: name, Branch: s.Branch}
			byWS[name] = w
			order = append(order, name)
		}
		a := wireAgent{
			Title:     transcript.Snip(s.Title, 80),
			Model:     "claude",
			LastEvent: s.Mtime,
		}
		switch s.State {
		case transcript.StateNeedsYou:
			a.State = "needs_input"
			a.Ask = transcript.Snip(s.LastText, 200)
		case transcript.StateBlocked:
			a.State = "needs_input"
			a.Ask = transcript.Snip("approval? "+s.Prompt, 200)
		case transcript.StateWorking:
			a.State = "working"
		default:
			a.State = "quiet"
		}
		if a.State == "needs_input" {
			w.Attention++
		}
		w.Agents = append(w.Agents, a)
	}
	sort.Strings(order)
	for _, name := range order {
		st.Workspaces = append(st.Workspaces, *byWS[name])
	}
	return st
}

// fetchActivity asks rook who is redrawing and who is typing — the
// same degradation story as the watcher: refusal or timeout means the
// transcript's word stands alone.
func fetchActivity(c *conn) []transcript.PaneActivity {
	raw, err := c.call("panes.activity", struct{}{}, 1500*time.Millisecond)
	if err != nil {
		return nil
	}
	var rep struct {
		Panes []transcript.PaneActivity `json:"panes"`
	}
	if json.Unmarshal(raw, &rep) != nil {
		return nil
	}
	return rep.Panes
}

// ---- the wire (the claude plugin's conn — the third copy; the wire
// package this argues for is owed) ----

type conn struct {
	mu      sync.Mutex
	out     io.Writer
	nextID  uint64
	pending map[uint64]chan callResult
}

type callResult struct {
	ok  bool
	err string
	raw json.RawMessage
}

func (c *conn) send(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.out.Write(append(b, '\n'))
}

type reply struct {
	V      int    `json:"v"`
	ID     uint64 `json:"id"`
	OK     bool   `json:"ok"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

type request struct {
	V      int    `json:"v"`
	ID     uint64 `json:"id"`
	Op     string `json:"op"`
	Params any    `json:"params"`
}

// call asks rook and waits. MUST NOT run on the serve goroutine —
// serve is what delivers the reply.
func (c *conn) call(op string, params any, timeout time.Duration) (json.RawMessage, error) {
	ch := make(chan callResult, 1)
	c.mu.Lock()
	c.nextID++
	id := c.nextID
	if c.pending == nil {
		c.pending = map[uint64]chan callResult{}
	}
	c.pending[id] = ch
	c.mu.Unlock()
	c.send(request{1, id, op, params})
	select {
	case r := <-ch:
		if !r.ok {
			return nil, errors.New(r.err)
		}
		return r.raw, nil
	case <-time.After(timeout):
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return nil, errors.New("timeout: " + op)
	}
}

func (c *conn) deliver(id uint64, ok bool, errText string, raw json.RawMessage) {
	c.mu.Lock()
	ch := c.pending[id]
	delete(c.pending, id)
	c.mu.Unlock()
	if ch != nil {
		ch <- callResult{ok, errText, raw}
	}
}

// serve answers rook until stdin closes, which is how a plugin ends.
func serve(c *conn, br *bridge) {
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 64*1024), 2*1024*1024)
	for in.Scan() {
		var req struct {
			ID     uint64          `json:"id"`
			Op     string          `json:"op"`
			Params json.RawMessage `json:"params"`
		}
		if json.Unmarshal(in.Bytes(), &req) != nil {
			continue
		}
		if req.Op == "" {
			var rep struct {
				ID     uint64          `json:"id"`
				OK     bool            `json:"ok"`
				Error  string          `json:"error"`
				Result json.RawMessage `json:"result"`
			}
			if json.Unmarshal(in.Bytes(), &rep) == nil {
				c.deliver(rep.ID, rep.OK, rep.Error, rep.Result)
			}
			continue
		}
		switch req.Op {
		case "describe":
			c.send(reply{1, req.ID, true, map[string]any{
				"name":         "cloud",
				"version":      version,
				"capabilities": []string{"items.list", "items.act", "panes.activity"},
				"surfaces":     []string{"LIST"},
			}, ""})
		case "items.list":
			c.send(reply{1, req.ID, true, map[string]any{
				"items":     items(br, time.Now()),
				"truncated": false,
			}, ""})
		case "items.act":
			c.send(act(br, req.ID, req.Params))
		default:
			c.send(reply{1, req.ID, false, nil, "cloud does not do " + req.Op})
		}
	}
}

type wireField struct {
	Key   string `json:"key"`
	Kind  string `json:"kind"`
	Value string `json:"value"`
}

type wireItemAction struct {
	ID    string `json:"id"`
	Label string `json:"label"`
}

type wireItem struct {
	ID      string           `json:"id"`
	Title   string           `json:"title"`
	State   string           `json:"state,omitempty"`
	Fields  []wireField      `json:"fields,omitempty"`
	Actions []wireItemAction `json:"actions,omitempty"`
}

// items is the connection truth as one row: who this machine is to the
// cloud, when the last push landed, and — when something is wrong —
// exactly what.
func items(br *bridge, now time.Time) []wireItem {
	br.mu.Lock()
	name, id, token := br.machineName, br.machineID, br.token
	lastPush, lastErr, agents := br.lastPush, br.lastErr, br.agents
	br.mu.Unlock()

	if token == "" {
		return []wireItem{{
			ID:    "cloud:notoken",
			Title: "not connected — mint a machine token at cloud.rookide.com and write it to " + br.nofile,
			State: "off",
		}}
	}
	it := wireItem{
		ID:      "cloud:link",
		Actions: []wireItemAction{{ID: "push", Label: "push now"}},
	}
	switch {
	case lastErr != "":
		it.Title = lastErr
		it.State = "error"
	case id == "":
		it.Title = "connecting to " + br.api + "…"
		it.State = "connecting"
	default:
		it.Title = fmt.Sprintf("connected as %q — %d agent(s) on the fleet page", name, agents)
		it.State = "up"
		if !lastPush.IsZero() {
			it.Fields = append(it.Fields, wireField{"pushed", "TEXT", transcript.RelAge(now.Sub(lastPush)) + " ago"})
		}
	}
	return []wireItem{it}
}

func act(br *bridge, id uint64, params json.RawMessage) reply {
	var p struct {
		ActionID string `json:"actionId"`
	}
	if json.Unmarshal(params, &p) != nil {
		return reply{1, id, false, nil, "params did not parse"}
	}
	if p.ActionID != "push" {
		return reply{1, id, false, nil, "no such action: " + p.ActionID}
	}
	if br.getToken() == "" {
		return reply{1, id, false, nil, "no token to push with"}
	}
	select {
	case br.kick <- struct{}{}:
	default: // a push is already queued; one doorbell is enough
	}
	return reply{1, id, true, map[string]string{"message": "pushing…"}, ""}
}

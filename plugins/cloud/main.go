// rook-plugin-cloud — the thin line to rook-cloud: this machine, made
// visible from your phone.
//
// It is the device half of the machine surface (rook-cloud
// internal/server/machines.go): a bearer token names the machine, GET
// /v1/whoami proves the provisioning, and POST /v1/status pushes a
// snapshot — workspaces, each with its agents and their honest states —
// that the fleet pages at cloud.rookide.com render. The ingest is
// last-write-wins by design, so a retry after a network blip costs
// nothing.
//
// The rails that come BACK are a different matter. Answers and commands
// are delivered at-least-once and take effect at a keyboard, where a
// second delivery is a second thing typed into somebody's editor. What
// makes that at-most-once is the delivery journal
// (plugins/internal/cmdjournal): the effect is recorded before the ack,
// on disk, so a process that dies in that gap costs a redundant ack and
// never a duplicate. Both rails share the one log.
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
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/incantery/rook/plugins/internal/cmdjournal"
	"github.com/incantery/rook/plugins/internal/digestlog"
	"github.com/incantery/rook/plugins/internal/nowfile"
	"github.com/incantery/rook/plugins/internal/statusfold"
	"github.com/incantery/rook/plugins/internal/transcript"
)

const version = "0.1.0"

// defaultAPI is the live cloud; --api points the bridge anywhere — a
// localhost rook-cloud, a LAN box — and the panel row names the target
// whenever it is not this one.
const defaultAPI = "https://api.rookide.com"

func main() {
	api := flag.String("api", defaultAPI, "rook-cloud API base")
	tokenFile := flag.String("token-file", "", "machine token file (default ~/.config/rook/cloud_token)")
	interval := flag.Duration("interval", 20*time.Second, "status push interval")
	dir := flag.String("dir", "", "projects directory (default ~/.claude/projects)")
	window := flag.Duration("window", 48*time.Hour, "how far back sessions are reported")
	rookVersion := flag.String("rook-version", "", "reported rook version")
	busyRate := flag.Float64("busy-rate", 200, "pane output above this (bytes/sec) proves an agent is working")
	names := flag.String("claude-names", "claude,node", "foreground program names that count as Claude Code")
	digests := flag.String("digest-log", digestlog.DefaultPath(), "the agent plugin's digest journal (empty sends no digests)")
	deliveries := flag.String("delivery-log", cmdjournal.DefaultPath(), "where deliveries are journaled (empty = remember only while running)")
	linkIdentity := flag.String("link-identity", "", "the link plugin's identity file, read for the shared machine id (default $XDG_STATE_HOME/rook/link/identity.json)")
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
	if *linkIdentity == "" {
		state := os.Getenv("XDG_STATE_HOME")
		if state == "" && home != "" {
			state = filepath.Join(home, ".local", "state")
		}
		if state != "" {
			*linkIdentity = filepath.Join(state, "rook", "link", "identity.json")
		}
	}

	// The delivery journal, replayed before the first poll: whatever the
	// last process typed is already known here, so a crash between the
	// keyboard and the ack costs a redundant ack rather than a second
	// round of typing. A window well past any ask's life, because the
	// cost of remembering too long is a few bytes and the cost of
	// forgetting too soon lands in somebody's editor.
	journal, jerr := cmdjournal.Open(*deliveries, 30*24*time.Hour, time.Now())

	br := &bridge{
		journal: journal,
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
		names:        strings.Split(*names, ","),
		busyRate:     *busyRate,
		digestLog:    *digests,
		linkIdentity: *linkIdentity,
		kick:         make(chan struct{}, 1),
		spawnTries:   6,
		spawnWait:    2 * time.Second,
	}
	// A journal that could not be opened is a degradation worth saying
	// out loud rather than a reason to refuse to run: the bridge still
	// works, it just forgets across restarts the way it always used to.
	if jerr != nil {
		br.note("deliveries are not journaled (" + jerr.Error() + ") — a crash could retype an answer")
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

	sc           *transcript.Scanner
	names        []string
	busyRate     float64
	digestLog    string        // the agent plugin's journal; "" sends no digests
	linkIdentity string        // the link plugin's identity file; "" or absent sends no hostId
	kick         chan struct{} // the "push now" action's doorbell

	// How long a spawn waits for its new claude pane to be ready for
	// the prompt: spawnTries polls of the pane list, spawnWait apart.
	spawnTries int
	spawnWait  time.Duration

	mu          sync.Mutex
	token       string
	machineName string
	machineID   string
	lastPush    time.Time
	lastErr     string
	agents      int    // agents in the last snapshot, for the panel row
	lastNote    string // the last delivery's story, for the panel row

	// Delivery bookkeeping: an answer types into a pane AT MOST once
	// (delivered survives a failed ack), and one that cannot land gets
	// a bounded number of tries before it is dropped with a note —
	// at-least-once from the cloud, at-most-once at the keyboard.
	//
	// Journaled rather than held in memory, because that promise is
	// about crashes too: the gap between typing and acking is exactly
	// where a dying process used to cost a second round of typing.
	// Both rails share the one log — plugins/internal/cmdjournal.
	journal *cmdjournal.Log
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
			sessions, panes := br.push(c, samples)
			br.collect(c, sessions, panes)
			br.executeCommands(c, sessions, panes)
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

func (br *bridge) push(c *conn, samples map[int]transcript.PaneSample) ([]transcript.Session, []transcript.PaneActivity) {
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

	// The journal is re-read every push: the agent plugin owns it, this
	// process only ever looks. A missing file is a machine without the
	// agent plugin, which is a machine without digests — not an error.
	var digests map[string]digestlog.Digest
	if br.digestLog != "" {
		digests = digestlog.Latest(digestlog.Load(br.digestLog, br.sc.Window, now))
	}
	// Same ownership story as the journal: the agent plugin's
	// screen-watcher writes the now-file, this process only looks.
	nows := nowfile.Read(nowfile.DefaultPath(), 90*time.Second, now)
	st := statusFrom(sessions, digests, nows, br.rookVer, linkHostID(br.linkIdentity))
	st.Usage = wireUsageFrom(statusfold.CollectUsage(now))
	body, err := json.Marshal(st)
	if err != nil {
		return sessions, panes
	}
	req, err := http.NewRequest("POST", br.api+"/v1/status", bytes.NewReader(body))
	if err != nil {
		return sessions, panes
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+br.getToken())
	resp, err := br.client.Do(req)
	if err != nil {
		br.fail("push: " + err.Error())
		return sessions, panes
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
		return sessions, panes
	}
	// The server answers 204 on a stored snapshot — accept the whole
	// success class; insisting on 200 called every good push an error.
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		br.fail(fmt.Sprintf("push: HTTP %d", resp.StatusCode))
		return sessions, panes
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
	return sessions, panes
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
	Hostname    string `json:"hostname,omitempty"`
	RookVersion string `json:"rookVersion,omitempty"`
	// HostID is the machine's durable link identity, read from the
	// link plugin's identity file — the same id the direct rail
	// stamps on its snapshots, so a phone seeing this machine on both
	// rails can prove they are one machine and collapse them.
	HostID     string          `json:"hostId,omitempty"`
	Usage      *wireUsage      `json:"usage,omitempty"`
	Workspaces []wireWorkspace `json:"workspaces,omitempty"`
}

// wireUsage mirrors projection.Usage's json field names exactly — the
// cloud server decodes into that type, and a renamed field here would
// silently drop on the wire.
type wireUsage struct {
	Mode            string    `json:"mode"`
	SessionPct      int       `json:"sessionPct,omitempty"`
	SessionResets   string    `json:"sessionResets,omitempty"`
	WeekAllPct      int       `json:"weekAllPct,omitempty"`
	WeekAllResets   string    `json:"weekAllResets,omitempty"`
	WeekModelName   string    `json:"weekModelName,omitempty"`
	WeekModelPct    int       `json:"weekModelPct,omitempty"`
	WeekModelResets string    `json:"weekModelResets,omitempty"`
	At              time.Time `json:"at,omitzero"`
	AgentTodayUSD   float64   `json:"agentTodayUsd,omitempty"`
	AgentWeekUSD    float64   `json:"agentWeekUsd,omitempty"`
}

func wireUsageFrom(u *statusfold.Usage) *wireUsage {
	if u == nil {
		return nil
	}
	return &wireUsage{
		Mode:            u.Mode,
		SessionPct:      u.SessionPct,
		SessionResets:   u.SessionResets,
		WeekAllPct:      u.WeekAllPct,
		WeekAllResets:   u.WeekAllResets,
		WeekModelName:   u.WeekModelName,
		WeekModelPct:    u.WeekModelPct,
		WeekModelResets: u.WeekModelResets,
		At:              u.At,
		AgentTodayUSD:   u.AgentTodayUSD,
		AgentWeekUSD:    u.AgentWeekUSD,
	}
}

type wireWorkspace struct {
	Name      string      `json:"name"`
	Branch    string      `json:"branch,omitempty"`
	Attention int         `json:"attention,omitempty"`
	Agents    []wireAgent `json:"agents,omitempty"`
}

type wireAgent struct {
	ID     string      `json:"id,omitempty"` // session id — what a phone-issued command names
	State  string      `json:"state"`        // working | needs_input | quiet
	Title  string      `json:"title,omitempty"`
	Ask    string      `json:"ask,omitempty"`
	AskID  string      `json:"askId,omitempty"`
	Model  string      `json:"model,omitempty"`
	CtxPct int         `json:"ctxPct,omitempty"` // context occupancy, percent of the model's window
	Digest *wireDigest `json:"digest,omitempty"`
	// The membrane's live line — see statusfold.Agent.Now.
	Now       string    `json:"now,omitempty"`
	NowAt     time.Time `json:"nowAt,omitzero"`
	Attached  bool      `json:"attached,omitempty"`
	LastEvent time.Time `json:"lastEvent,omitzero"`
}

// wireDigest is the membrane's artifact, exported: the agent plugin's
// STE compression of the session's last finished turn. This is the
// deliberate line of what leaves the machine — headline and bullets
// travel, the raw turn they compress stays home in the journal.
type wireDigest struct {
	Headline string    `json:"headline"`
	Bullets  []string  `json:"bullets,omitempty"`
	At       time.Time `json:"at,omitzero"`
}

// maxCloudAsk is what rook-cloud stores for an ask, whose own comment
// calls it "the one field worth reading in full".
const maxCloudAsk = 2000

// submitSettle is how long a paste is left to settle before the CR
// that submits it. An agent TUI collapses a large or multi-line paste
// into a placeholder draft, and a CR glued to the same burst is eaten
// by that collapse instead of submitting — so type, let the TUI's
// event loop finish, then submit.
const submitSettle = 150 * time.Millisecond

// typeAndSubmit types text into a pane and submits it in two steps: the
// bracketed paste held open (no CR), a settle, then the CR alone. Both
// steps pass session.send's gates; the second is a bare submit. This
// is what makes a long or multi-line answer actually send, not just
// draft.
func typeAndSubmit(c *conn, pane int, text string) error {
	if _, err := c.call("session.send",
		map[string]any{"pane": pane, "text": text, "no_submit": true}, 5*time.Second); err != nil {
		return err
	}
	time.Sleep(submitSettle)
	_, err := c.call("session.send",
		map[string]any{"pane": pane, "submit_only": true}, 5*time.Second)
	return err
}

// linkHostID is who this machine is on the direct rail, read from the
// link plugin's identity file so both rails carry one id and a phone
// can collapse them. Best effort at every push: no file, no id, no
// problem — the field simply stays home. Prefers the denormalized
// hostId; derives it from the seed for identities minted before the
// field existed (same derivation as rook-host's identity package:
// lowercase unpadded base32 of sha256(pub)[:16]).
func linkHostID(path string) string {
	if path == "" {
		return ""
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	var f struct {
		HostID   string `json:"hostId"`
		HostSeed string `json:"hostSeed"`
	}
	if json.Unmarshal(raw, &f) != nil {
		return ""
	}
	if f.HostID != "" {
		return f.HostID
	}
	seed, err := base64.StdEncoding.DecodeString(f.HostSeed)
	if err != nil || len(seed) != ed25519.SeedSize {
		return ""
	}
	pub := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
	sum := sha256.Sum256(pub)
	enc := base32.StdEncoding.WithPadding(base32.NoPadding)
	return strings.ToLower(enc.EncodeToString(sum[:16]))
}

// askText and askID moved to plugins/internal/statusfold, where the
// link plugin shares them; these aliases keep this plugin's tests
// pinned to the exact behavior its wire promised.
func askText(s string) string { return statusfold.AskText(s) }

func askID(s transcript.Session) string { return statusfold.AskID(s) }

// statusFrom folds sessions into the cloud's vocabulary — the fold
// itself lives in plugins/internal/statusfold now, shared with the
// link plugin so both rails say the same thing about this machine.
// This side only renders the neutral struct as rook-cloud's wire JSON;
// the field names and omitempty semantics above are the contract, and
// the mapping here is deliberately 1:1.
func statusFrom(sessions []transcript.Session, digests map[string]digestlog.Digest, nows map[string]nowfile.Now, rookVer, linkHostID string) wireStatus {
	host, _ := os.Hostname()
	n := statusfold.Fold(sessions, digests, nows, host, rookVer)

	st := wireStatus{Hostname: n.Hostname, RookVersion: n.RookVersion, HostID: linkHostID}
	st.Usage = wireUsageFrom(n.Usage)
	for _, w := range n.Workspaces {
		ww := wireWorkspace{Name: w.Name, Branch: w.Branch, Attention: w.Attention}
		for _, a := range w.Agents {
			wa := wireAgent{
				ID:        a.ID,
				State:     a.State,
				Title:     a.Title,
				Ask:       a.Ask,
				AskID:     a.AskID,
				Model:     a.Model,
				CtxPct:    a.CtxPct,
				Now:       a.Now,
				NowAt:     a.NowAt,
				Attached:  a.Attached,
				LastEvent: a.LastEvent,
			}
			if a.Digest != nil {
				wa.Digest = &wireDigest{Headline: a.Digest.Headline, Bullets: a.Digest.Bullets, At: a.Digest.At}
			}
			ww.Agents = append(ww.Agents, wa)
		}
		st.Workspaces = append(st.Workspaces, ww)
	}
	return st
}

// collect drains the cloud outbox: for each phone-authored answer,
// verify the ask is STILL the session's current one, deliver it into
// the agent's pane via session.send, and ack. The verify step is the
// both-settle rule: an ask answered at the desk (or superseded by a
// new turn) makes the phone's answer stale, and stale answers are
// acked away with a note, never typed.
func (br *bridge) collect(c *conn, sessions []transcript.Session, panes []transcript.PaneActivity) {
	answers := br.fetchAnswers()
	if len(answers) == 0 {
		return
	}
	for _, ans := range answers {
		if br.journal.Delivered(ans.AskID) {
			// Typed already; a previous ack must have been lost. Ack
			// again — never type twice.
			br.ack(ans.AskID)
			continue
		}
		var target *transcript.Session
		for i := range sessions {
			if askID(sessions[i]) == ans.AskID {
				target = &sessions[i]
				break
			}
		}
		if target == nil {
			// The session moved on, or was answered at the desk: the
			// desk won. Both settle; the phone's answer is dropped
			// with its reason on the record.
			br.ack(ans.AskID)
			br.note("dropped a stale answer — the ask moved on")
			continue
		}
		var pane *transcript.PaneActivity
		for i := range panes {
			if panes[i].Cwd == target.Cwd && transcript.ClaudeLike(panes[i], br.names) {
				pane = &panes[i]
				break
			}
		}
		if pane == nil {
			// The session runs outside rook, or its pane is gone. A
			// bounded number of retries, then drop with the reason —
			// an answer that can never land must not pend forever.
			if br.journal.Failed(ans.AskID) > 5 {
				br.ack(ans.AskID)
				br.note("dropped an answer — no agent pane for " + transcript.Snip(target.Title, 40))
			}
			continue
		}
		if c == nil {
			continue
		}
		err := typeAndSubmit(c, pane.ID, ans.Text)
		if err != nil {
			if br.journal.Failed(ans.AskID) > 5 {
				br.ack(ans.AskID)
				br.note("could not deliver an answer: " + err.Error())
			} else {
				br.note("delivery refused, retrying: " + err.Error())
			}
			continue
		}
		// Typed. Mark BEFORE the ack: a lost ack must re-ack, never
		// re-type — and the mark is on disk before this returns, so a
		// crash in the gap cannot cost a second round of typing either.
		br.journal.MarkDelivered(ans.AskID)
		br.ack(ans.AskID)
		br.note("answered " + transcript.Snip(target.Title, 40) + " from the phone")
	}
}

// executeCommands drains the second outbox — the verb rail beside the
// answers. Three kinds: "compact" types /compact into the session's
// pane, "resume" reopens a quiet session (`claude --resume` in its own
// directory), "spawn" starts a fresh claude in a named workspace and
// types the prompt in. Answers' rules carry over exactly (at-most-once
// at the keyboard, delivered-before-ack, bounded retries, notes on the
// record), and nothing from the wire ever reaches a shell: commands
// are built from local data, prompts are typed text. The host's gates
// still stand under all of it; the cloud requests, this machine
// decides.
func (br *bridge) executeCommands(c *conn, sessions []transcript.Session, panes []transcript.PaneActivity) {
	cmds := br.fetchCommands()
	if len(cmds) == 0 {
		return
	}
	for _, cmd := range cmds {
		key := "cmd:" + cmd.ID
		if br.journal.Delivered(key) {
			br.ackCommand(cmd.ID)
			continue
		}
		switch cmd.Kind {
		case "compact":
			br.runCompact(c, cmd, key, sessions, panes)
		case "resume":
			br.runResume(c, cmd, key, sessions, panes)
		case "spawn":
			br.runSpawn(c, cmd, key, sessions, panes)
		case "say":
			br.runSay(c, cmd, key, sessions, panes)
		default:
			// A kind this rook does not speak: honestly refused, never
			// guessed at. (An older bridge meeting a newer cloud.)
			br.ackCommand(cmd.ID)
			br.note("dropped a command this rook does not know: " + cmd.Kind)
		}
	}
}

func findSession(sessions []transcript.Session, id string) *transcript.Session {
	for i := range sessions {
		if sessions[i].ID == id {
			return &sessions[i]
		}
	}
	return nil
}

func (br *bridge) runCompact(c *conn, cmd cloudCommand, key string, sessions []transcript.Session, panes []transcript.PaneActivity) {
	target := findSession(sessions, cmd.SessionID)
	if target == nil {
		br.ackCommand(cmd.ID)
		br.note("dropped a compact — that session is gone")
		return
	}
	if target.State == transcript.StateWorking {
		if br.journal.Failed(key) > 5 {
			br.ackCommand(cmd.ID)
			br.note("dropped a compact — " + transcript.Snip(target.Title, 40) + " stayed mid-turn")
		}
		return
	}
	var pane *transcript.PaneActivity
	for i := range panes {
		if panes[i].Cwd == target.Cwd && transcript.ClaudeLike(panes[i], br.names) {
			pane = &panes[i]
			break
		}
	}
	if pane == nil {
		if br.journal.Failed(key) > 5 {
			br.ackCommand(cmd.ID)
			br.note("dropped a compact — no agent pane for " + transcript.Snip(target.Title, 40))
		}
		return
	}
	if c == nil {
		return
	}
	_, err := c.call("session.send",
		map[string]any{"pane": pane.ID, "text": "/compact"}, 5*time.Second)
	if err != nil {
		if br.journal.Failed(key) > 5 {
			br.ackCommand(cmd.ID)
			br.note("could not deliver a compact: " + err.Error())
		} else {
			br.note("compact refused, retrying: " + err.Error())
		}
		return
	}

	br.journal.MarkDelivered(key)
	br.ackCommand(cmd.ID)
	br.note("compacted " + transcript.Snip(target.Title, 40) + " from the phone")
}

// runSay types a message into an ATTACHED session's pane — the verb a
// quiet-but-open session offers instead of resume. Attachment is the
// resume refusal inverted: the freshest transcript in a cwd with a
// Claude-like pane IS that pane's session. The text reaches the pane
// as TYPED TEXT via session.send, the same path answers ride.
func (br *bridge) runSay(c *conn, cmd cloudCommand, key string, sessions []transcript.Session, panes []transcript.PaneActivity) {
	target := findSession(sessions, cmd.SessionID)
	if target == nil {
		br.ackCommand(cmd.ID)
		br.note("dropped a message — that session is gone")
		return
	}
	if target.ID != freshestInCwd(sessions, target.Cwd) {
		br.ackCommand(cmd.ID)
		br.note("dropped a message — " + transcript.Snip(target.Title, 40) + " is history in its directory; resume it instead")
		return
	}
	var pane *transcript.PaneActivity
	for i := range panes {
		if panes[i].Cwd == target.Cwd && transcript.ClaudeLike(panes[i], br.names) {
			pane = &panes[i]
			break
		}
	}
	if pane == nil {
		br.ackCommand(cmd.ID)
		br.note("dropped a message — " + transcript.Snip(target.Title, 40) + " is not on a pane; resume it instead")
		return
	}
	if c == nil {
		return
	}
	_, err := c.call("session.send",
		map[string]any{"pane": pane.ID, "text": cmd.Prompt}, 8*time.Second)
	if err != nil {
		if br.journal.Failed(key) > 5 {
			br.ackCommand(cmd.ID)
			br.note("could not deliver a message: " + err.Error())
		} else {
			br.note("message refused, retrying: " + err.Error())
		}
		return
	}

	br.journal.MarkDelivered(key)
	br.ackCommand(cmd.ID)
	br.note("typed a message into " + transcript.Snip(target.Title, 40) + " from the phone")
}

// runResume reopens a quiet session: a new pane running
// `claude --resume <id>` in the session's own directory. The command
// string is built from LOCAL data only — the id comes from this
// machine's transcript filename, never from the wire, and is charset-
// checked besides, because session.spawn hands its command to a shell.
func (br *bridge) runResume(c *conn, cmd cloudCommand, key string, sessions []transcript.Session, panes []transcript.PaneActivity) {
	target := findSession(sessions, cmd.SessionID)
	if target == nil {
		br.ackCommand(cmd.ID)
		br.note("dropped a resume — that session is gone")
		return
	}
	if !shellSafeID(target.ID) {
		br.ackCommand(cmd.ID)
		br.note("refused a resume — session id is not shell-safe")
		return
	}
	// Already on a screen? A claude pane in this directory running the
	// directory's freshest session IS this session (the same heuristic
	// Fuse stands on); resuming it twice makes two instances fight
	// over one transcript.
	if target.ID == freshestInCwd(sessions, target.Cwd) {
		for i := range panes {
			if panes[i].Cwd == target.Cwd && transcript.ClaudeLike(panes[i], br.names) {
				br.ackCommand(cmd.ID)
				br.note("skipped a resume — " + transcript.Snip(target.Title, 40) + " is already open")
				return
			}
		}
	}
	if c == nil {
		return
	}
	_, err := c.call("session.spawn",
		map[string]any{"command": "claude --resume " + target.ID, "cwd": target.Cwd}, 5*time.Second)
	if err != nil {
		if br.journal.Failed(key) > 5 {
			br.ackCommand(cmd.ID)
			br.note("could not resume: " + err.Error())
		} else {
			br.note("resume refused, retrying: " + err.Error())
		}
		return
	}
	br.journal.MarkDelivered(key)
	br.ackCommand(cmd.ID)
	br.note("resumed " + transcript.Snip(target.Title, 40) + " from the phone")
}

// runSpawn opens a fresh claude session in a named workspace. The
// workspace name maps to a directory through this machine's OWN
// sessions (the same vocabulary the status push spoke — the phone can
// only name what the machine showed it), the spawned command is the
// literal string "claude", and the prompt goes in afterwards as TYPED
// TEXT through session.send's gates — cloud words never touch a shell.
func (br *bridge) runSpawn(c *conn, cmd cloudCommand, key string, sessions []transcript.Session, panes []transcript.PaneActivity) {
	cwd := ""
	var newest time.Time
	for _, s := range sessions {
		if filepath.Base(s.Cwd) == cmd.Workspace && (cwd == "" || s.Mtime.After(newest)) {
			cwd, newest = s.Cwd, s.Mtime
		}
	}
	if cwd == "" {
		br.ackCommand(cmd.ID)
		br.note("dropped a spawn — no workspace called " + transcript.Snip(cmd.Workspace, 40) + " in view")
		return
	}
	if c == nil {
		return
	}
	// Which panes exist NOW: the new session is the claude pane that
	// appears in this directory afterwards and is not one of these.
	before := map[int]bool{}
	for _, p := range panes {
		before[p.ID] = true
	}
	_, err := c.call("session.spawn", map[string]any{"command": "claude", "cwd": cwd}, 5*time.Second)
	if err != nil {
		if br.journal.Failed(key) > 5 {
			br.ackCommand(cmd.ID)
			br.note("could not spawn: " + err.Error())
		} else {
			br.note("spawn refused, retrying: " + err.Error())
		}
		return
	}
	// Spawned exactly once — marked and acked BEFORE the prompt hop,
	// because a redelivered spawn must never open a second pane. A
	// prompt that then fails to land costs a note, not a duplicate.
	br.journal.MarkDelivered(key)
	br.ackCommand(cmd.ID)
	if cmd.Prompt == "" {
		br.note("started a session in " + cmd.Workspace + " from the phone")
		return
	}
	for i := 0; i < br.spawnTries; i++ {
		time.Sleep(br.spawnWait)
		for _, p := range fetchActivity(c) {
			if before[p.ID] || p.Cwd != cwd || !transcript.ClaudeLike(p, br.names) {
				continue
			}
			if err := typeAndSubmit(c, p.ID, cmd.Prompt); err == nil {
				br.note("started a session in " + cmd.Workspace + " and handed it the prompt")
				return
			}
			break // found the pane but it is not ready — wait and retry
		}
	}
	br.note("started a session in " + cmd.Workspace + " — the prompt did not land, type it there")
}

// freshestInCwd names the newest session working in a directory — the
// one a claude pane there is presumed to run.
func freshestInCwd(sessions []transcript.Session, cwd string) string {
	id := ""
	var newest time.Time
	for _, s := range sessions {
		if s.Cwd == cwd && (id == "" || s.Mtime.After(newest)) {
			id, newest = s.ID, s.Mtime
		}
	}
	return id
}

// shellSafeID: session ids are transcript filenames (UUIDs in
// practice), but session.spawn's command reaches a shell, so anything
// beyond [A-Za-z0-9._-] is refused outright.
func shellSafeID(id string) bool {
	if id == "" {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '.', c == '_', c == '-':
		default:
			return false
		}
	}
	return true
}

type cloudCommand struct {
	ID        string `json:"id"`
	Kind      string `json:"kind"`
	SessionID string `json:"sessionId"`
	Workspace string `json:"workspace"`
	Prompt    string `json:"prompt"`
}

func (br *bridge) fetchCommands() []cloudCommand {
	req, err := http.NewRequest("GET", br.api+"/v1/commands", nil)
	if err != nil {
		return nil
	}
	req.Header.Set("Authorization", "Bearer "+br.getToken())
	resp, err := br.client.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != 200 {
		return nil
	}
	var rep struct {
		Commands []cloudCommand `json:"commands"`
	}
	if json.Unmarshal(raw, &rep) != nil {
		return nil
	}
	return rep.Commands
}

func (br *bridge) ackCommand(id string) {
	body, _ := json.Marshal(map[string]string{"id": id})
	req, err := http.NewRequest("POST", br.api+"/v1/commands/ack", bytes.NewReader(body))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+br.getToken())
	if resp, err := br.client.Do(req); err == nil {
		io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<12))
		resp.Body.Close()
	}
}

type cloudAnswer struct {
	AskID string `json:"askId"`
	Text  string `json:"text"`
}

func (br *bridge) fetchAnswers() []cloudAnswer {
	req, err := http.NewRequest("GET", br.api+"/v1/answers", nil)
	if err != nil {
		return nil
	}
	req.Header.Set("Authorization", "Bearer "+br.getToken())
	resp, err := br.client.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != 200 {
		return nil
	}
	var rep struct {
		Answers []cloudAnswer `json:"answers"`
	}
	if json.Unmarshal(raw, &rep) != nil {
		return nil
	}
	return rep.Answers
}

func (br *bridge) ack(askID string) {
	body, _ := json.Marshal(map[string]string{"askId": askID})
	req, err := http.NewRequest("POST", br.api+"/v1/answers/ack", bytes.NewReader(body))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+br.getToken())
	if resp, err := br.client.Do(req); err == nil {
		io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<12))
		resp.Body.Close()
	}
}

func (br *bridge) note(msg string) {
	br.mu.Lock()
	br.lastNote = msg
	br.mu.Unlock()
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
				"capabilities": []string{"items.list", "items.act", "panes.activity", "session.send"},
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
	lastNote := br.lastNote
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
		// A non-default target is worth a field: "connected" to the
		// wrong cloud reads exactly like connected to the right one.
		if br.api != defaultAPI {
			it.Fields = append(it.Fields, wireField{"api", "TEXT", strings.TrimPrefix(strings.TrimPrefix(br.api, "https://"), "http://")})
		}
		if !lastPush.IsZero() {
			it.Fields = append(it.Fields, wireField{"pushed", "TEXT", transcript.RelAge(now.Sub(lastPush)) + " ago"})
		}
	}
	out := []wireItem{it}
	// The last delivery's story: "answered X from the phone", a stale
	// drop, a refused send. One row, newest wins — the round trip's
	// visible receipt on this side.
	if lastNote != "" {
		out = append(out, wireItem{ID: "cloud:note", Title: lastNote})
	}
	return out
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

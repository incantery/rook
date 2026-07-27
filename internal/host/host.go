// Package host is the PTY host: it owns shell sessions and serves them over
// localhost HTTP + WebSocket. It runs in the rook-host process, NOT the app
// (README decision 2) — the UI can crash, rebuild, and reattach without
// killing shells. Sessions keep a replay ring buffer so a reattaching client
// gets recent scrollback, tmux-style.
package host

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/http/pprof"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	cpty "github.com/creack/pty"

	"github.com/incantery/rook/internal/cloud"
	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/edge"
	"github.com/incantery/rook/internal/plugin"
	"github.com/incantery/rook/internal/relay"
	"github.com/incantery/rook/internal/version"
)

// Client/daemon compatibility is version.Build equality — binaries built
// together agree by construction; on drift the daemon is replaced and its
// sessions die with it (the tmux server-upgrade reality). There is no
// hand-bumped protocol number to forget. See internal/hostclient.
const ringCap = 512 * 1024

type SessionInfo struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// Workspace groups sessions the way tmux sessions group windows; the
	// host only tags and reports it, grouping is a client concern.
	Workspace string    `json:"workspace"`
	Cols      int       `json:"cols"`
	Rows      int       `json:"rows"`
	Created   time.Time `json:"created"`
}

type session struct {
	info SessionInfo
	pty  *os.File
	cmd  *exec.Cmd

	mu   sync.Mutex // guards ring, frameConn
	ring []byte     // recent output, for correlate/normRing — NOT replay

	// The framed transport (termframe.go): a host-side emulator and the client
	// that renders its grid diffs.
	emu       Terminal
	emuMu     sync.Mutex    // guards emu across readPump, render loop, resize
	dirty     chan struct{} // buffered(1): pty output happened, render loop wake
	frameConn *websocket.Conn
	// oob carries pre-framed control messages (edit requests) to the render
	// loop — the frame socket's sole writer. Set per attach, nil when detached.
	oob chan []byte
}

type Host struct {
	mu       sync.Mutex
	sessions map[string]*session
	nextID   int
	token    string
	reg      *registry
	aw       *agentWatch
	tw       *threadWatch // thread change fan-out (threadwatch.go)
	// nudgeFn overrides nudge() in tests — nil in production, where the
	// real actuator (claimed window, else spawned task) runs.
	nudgeFn func(ws, prompt string) (mode, rookSession string, err error)

	// pending `rookctl edit` requests (edit.go), keyed by edit id
	editMu sync.Mutex
	edits  map[string]*editState

	// pending `rookctl ask` requests (ask.go), keyed by ask id
	askMu sync.Mutex
	asks  map[string]*askState
	// typeLineFn overrides the doorbell's pty write in tests — nil in
	// production, where typeLineAt types at the real tty.
	typeLineFn func(s *session, line string)

	// The configured rook-server, if any (relay.go): asks escalate to it so
	// they can be answered from a phone. nil = no remote, path inert.
	relay *relay.Client

	// The configured rook-cloud, if any (cloud.go): status snapshots go up
	// so the dashboard can show this machine. nil = nothing leaves here.
	cloud *cloud.Client

	// The edge client, if this machine opted in ([cloud] edge = true,
	// edge.go): typed commands arrive, are journaled, verified, and
	// executed here. nil = this machine takes no orders from anywhere.
	edge *edge.Client

	cwdMu    sync.Mutex
	cwdCache map[int]cwdEntry

	// review roots with a Haiku triage fan-out in flight (reviewscore.go)
	scoreMu sync.Mutex
	scoring map[int64]bool

	// pt is the batched process table: one `ps` behind a TTL, shared by
	// fgOf and the monitor (procsample.go, monitor.go).
	pt *procTable

	// Two tiers of transcript↔window pairing (see correlate): claims are
	// authoritative (a SessionStart hook inside the claude process told us,
	// via `rookctl claim`); binds are heuristic (proven by ring content).
	// Both map transcript session id → rook session id.
	bindMu sync.Mutex
	claims map[string]string
	binds  map[string]string
	// claimFg is the pty's foreground process group at the moment each claim
	// was made — the agent's own, since the SessionStart hook runs inside it.
	// A claim only survives its process if nothing releases it, and the
	// SessionEnd hook does not run for ^C, a crash, or a kill -9. The claim
	// then still names a window, but that window has moved on to a shell, or
	// an editor. Typing a prompt at it is not delivery; it is keystrokes into
	// whatever is there. Comparing this against the tty's current foreground
	// group answers "is the thing that claimed this still the thing running"
	// exactly, and for one ioctl. Keyed like claims: transcript session id.
	claimFg map[string]int

	// Live drafts by transcript session id — what /attention decorates its
	// items with. The decisions table is the durable ledger; this map is
	// just the "current open draft" index over it.
	draftMu sync.Mutex
	drafts  map[string]draftInfo

	// um caches subscription usage windows (WatchUsage).
	um *usageMon

	// latestTag caches the newest published release (runUpdateCheck) —
	// the /update indicator's answer.
	updMu     sync.Mutex
	latestTag string

	// anchorMemo caches re-anchor diffs per (old,cur) blob pair
	// (threads.go / reanchor.go).
	anchorMemo hunkMemo

	// prm caches per-worktree PR state (WatchPRs) — the close-the-loop
	// signal on workspace cards.
	prm *prMon

	// wfMu serializes workflow advancement (see advanceWorkflow).
	wfMu sync.Mutex

	// The plugin substrate (internal/plugin) and its language-type
	// runtime: pm materializes catalog plugins into the data prefix, lm
	// owns live LSP server instances (lsp.go, plugins.go).
	pm *plugin.Manager
	lm *lspManager

	// Lifecycle root for supervised children (agentmon, and rook-agent via
	// SuperviseAgent when callers pass Done()'s context). Shutdown cancels
	// it — child processes must die with the host, or every daemon
	// replacement leaks orphans.
	ctx    context.Context
	cancel context.CancelFunc
}

type cwdEntry struct {
	cwd string
	at  time.Time
}

func New() *Host {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	h := &Host{
		sessions: make(map[string]*session),
		token:    hex.EncodeToString(b),
		reg:      loadRegistry(),
		aw:       newAgentWatch(),
		tw:       newThreadWatch(),
		cwdCache: make(map[int]cwdEntry),
		pt:       newProcTable(),
		claims:   make(map[string]string),
		claimFg:  make(map[string]int),
		binds:    make(map[string]string),
		drafts:   make(map[string]draftInfo),
		um:       newUsageMon(),
		prm:      newPRMon(),
		pm:       plugin.NewManager(filepath.Join(DataDir(), "plugins")),
	}
	h.ctx, h.cancel = context.WithCancel(context.Background())
	h.lm = newLSPManager(h.ctx, h.pm)
	// Manual-attribution + stale-ask hooks: the transcript is the ground
	// truth for what actually got answered (see onUserReply).
	h.aw.onUserReply = h.onUserReply
	h.aw.onTurnCompleted = h.onTurnCompleted
	// The workflow engine's stage-completion sensor — genuine turn ends
	// only, never AskUserQuestion/notify (see agentwatch.onTurnFinished).
	h.aw.onTurnFinished = h.onTurnFinished
	// Restart reconciliation: running stages lost their windows with the
	// old host. ✗ + detail is the honest surface — no auto-respawn, no
	// surprise spend.
	h.reg.failRunningStages("host restarted — window lost")
	go h.aw.runTranscript(h.ctx)
	go h.runUpdateCheck()
	h.initRelay()
	h.initCloud()
	h.initEdge()
	return h
}

// Context is the host's lifecycle root: run supervised work under it so
// Shutdown reaches everything.
func (h *Host) Context() context.Context { return h.ctx }

// Shutdown kills the host's supervised children (agentmon, rook-agent).
// Call it on the way out — SIGTERM from a replacing daemon included.
func (h *Host) Shutdown() { h.cancel() }

// cachedCwdOf is cwdOf behind a short TTL: the status endpoint gets polled
// every few seconds and lsof is ~100ms per pid — cache, don't multiply.
func (h *Host) cachedCwdOf(pid int) string {
	h.cwdMu.Lock()
	e, ok := h.cwdCache[pid]
	h.cwdMu.Unlock()
	if ok && time.Since(e.at) < 8*time.Second {
		return e.cwd
	}
	cwd := cwdOf(pid)
	h.cwdMu.Lock()
	h.cwdCache[pid] = cwdEntry{cwd, time.Now()}
	h.cwdMu.Unlock()
	return cwd
}

// claimAliveLocked reports whether the window a claim names is still running
// the process that claimed it. Callers must hold bindMu.
//
// A claim is only as durable as the hook that releases it, and SessionEnd
// does not run for ^C, a crash, or a kill -9. What is left then is a claim
// pointing at a window where the agent has been replaced by a shell prompt —
// or by whatever the user started next. Every actuator that types at a claim
// has to ask this first, because typing at the wrong window is not a missed
// delivery, it is keystrokes into someone's editor.
//
// The test is the tty's foreground process group against the one recorded
// when the claim was made. Exact, and one ioctl: no `ps`, no lsof, nothing
// that would make it too expensive for an actuation path.
//
// Nothing recorded means a claim older than this check — fail open, since
// inventing an answer is worse than the behaviour that shipped before.
func (h *Host) claimAliveLocked(agentSession string, s *session) bool {
	want, ok := h.claimFg[agentSession]
	if !ok || want <= 0 {
		return true
	}
	return fgPgrp(s.pty) == want
}

// agentPane reports whether this session is a live claimed agent window — a
// claude the SessionStart hook named via `rookctl claim`, still the thing on
// the tty.
//
// This is the keyboard-routing half of the claim machinery. The framed
// transport ships it to the client (termframe.go), where it carves the
// navigation chords back out of the blanket "a full-screen app owns the
// keyboard" yield: claude is a full-screen TUI, and in an AI-native terminal
// it is the pane you live in, so that rule cost ⌃hjkl exactly where it was
// needed most.
//
// Note what this is NOT: a name match on the foreground process. `fgOf`
// would go through the 2s proc table and would flap the moment claude ran
// something — this is claimAliveLocked, the same pgrp test every actuator
// already trusts, exact and one ioctl. A claude with no live claim (hooks
// never installed, or a claim orphaned by ^C) reports false and keeps the
// pre-existing yield, which is the safe direction to fail.
func (h *Host) agentPane(s *session) bool {
	h.bindMu.Lock()
	defer h.bindMu.Unlock()
	for tid, sid := range h.claims {
		if sid == s.info.ID && h.claimAliveLocked(tid, s) {
			return true
		}
	}
	return false
}

func (h *Host) Token() string { return h.token }

// ---- session lifecycle ----

// expandPath resolves a leading ~; returns "" for paths that don't exist so
// callers fall back rather than failing the spawn.
func expandPath(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		p = filepath.Join(home, strings.TrimPrefix(p[1:], "/"))
	}
	if st, err := os.Stat(p); err != nil || !st.IsDir() {
		return ""
	}
	return p
}

func (h *Host) spawn(cols, rows int, cwd, workspace string) (*session, error) {
	if workspace == "" {
		workspace = "main"
	}
	h.mu.Lock()
	h.nextID++
	id := fmt.Sprintf("s%d", h.nextID)
	num := h.nextID
	h.mu.Unlock()

	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/zsh"
	}
	cmd := exec.Command(shell, "-l")
	// A bad cwd (typo'd root, deleted dir) must not fail the spawn — fall
	// back to home.
	if cwd = expandPath(cwd); cwd != "" {
		cmd.Dir = cwd
	} else if home, err := os.UserHomeDir(); err == nil {
		cmd.Dir = home
	}
	// ROOK_SESSION makes the window identity a first-class fact inside the
	// shell (tmux's $TMUX_PANE): scripts can ask "which window am I", and
	// claude's SessionStart hook uses it to claim the window (rookctl).
	cmd.Env = append(os.Environ(),
		"TERM=xterm-256color", "COLORTERM=truecolor",
		"ROOK_SESSION="+id, "ROOK_WORKSPACE="+workspace)

	f, err := cpty.StartWithSize(cmd, &cpty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
	if err != nil {
		return nil, err
	}

	h.mu.Lock()
	s := &session{
		info: SessionInfo{
			ID:        id,
			Name:      fmt.Sprintf("%s — %d", filepath.Base(shell), num),
			Workspace: workspace,
			Cols:      cols,
			Rows:      rows,
			Created:   time.Now(),
		},
		pty:   f,
		cmd:   cmd,
		emu:   newTerminal(cols, rows),
		dirty: make(chan struct{}, 1),
	}
	h.sessions[s.info.ID] = s
	h.mu.Unlock()

	go h.readPump(s)
	return s, nil
}

// gather is the pty-draining half of readPump (the Ghostty gather-thread
// shape). The kernel hands out at most ~1KB per pty read(), and a serial
// read-then-parse loop stalls twice per cycle: the writing TUI blocks on a
// full kernel buffer while we parse, and the parser idles while we sit in the
// read syscall. So one goroutine does nothing but drain the pty into a pending
// buffer, and the parse loop takes whatever has accumulated as one coalesced
// chunk — reads overlap parsing, and a firehose reaches the emulator in
// big writes instead of 1KB nibbles.
type gather struct {
	mu      sync.Mutex
	pending []byte
	err     error         // terminal read error; delivered after pending drains
	notify  chan struct{} // cap 1: bytes or err landed
	drained chan struct{} // cap 1: parser took — releases backpressure
}

// gatherMax bounds unparsed bytes; past it the gather loop stops reading until
// the parser catches up, pushing backpressure into the pty like the old serial
// loop did — just at a much coarser grain.
const gatherMax = 1 << 20

func (g *gather) run(pty *os.File) {
	buf := make([]byte, 64*1024)
	for {
		n, err := pty.Read(buf)
		if n > 0 {
			g.mu.Lock()
			g.pending = append(g.pending, buf[:n]...)
			over := len(g.pending) > gatherMax
			g.mu.Unlock()
			g.signal(g.notify)
			if over {
				<-g.drained
			}
		}
		if err != nil {
			g.mu.Lock()
			g.err = err
			g.mu.Unlock()
			g.signal(g.notify)
			return
		}
	}
}

// take blocks until output or the terminal error is available, then swaps the
// pending buffer for the caller's recycled one (zero steady-state allocation).
func (g *gather) take(recycled []byte) ([]byte, error) {
	waited := false
	for {
		g.mu.Lock()
		if n := len(g.pending); n > 0 || g.err != nil {
			// Micro-batch: waking with only a nibble pending usually means the
			// parser is OUTRUNNING the pty mid-burst — the kernel hands out
			// ~1KB per read, and swapping per nibble puts a goroutine wake on
			// the per-KB path, which caps throughput below the parse rate
			// (measured: a faster parser made `cat 150MB` slower). One beat of
			// sleep gathers a chunk worth parsing; at most one per take, so an
			// interactive keystroke's echo is delayed ≤~a quarter millisecond.
			if n > 0 && n < 32<<10 && g.err == nil && !waited {
				g.mu.Unlock()
				waited = true
				time.Sleep(200 * time.Microsecond)
				continue
			}
			data, err := g.pending, g.err
			g.pending = recycled[:0]
			g.mu.Unlock()
			g.signal(g.drained)
			return data, err
		}
		g.mu.Unlock()
		<-g.notify
	}
}

func (g *gather) signal(ch chan struct{}) {
	select {
	case ch <- struct{}{}:
	default:
	}
}

// readPump runs for the session's whole life, host-side: output lands in the
// ring buffer whether or not a client is attached — sessions keep producing
// while detached, and the ring is what a reattaching client replays. It is the
// parse half of the gather pair (see gather).
func (h *Host) readPump(s *session) {
	g := &gather{notify: make(chan struct{}, 1), drained: make(chan struct{}, 1)}
	go g.run(s.pty)
	var chunk []byte
	for {
		buf, err := g.take(chunk)
		if n := len(buf); n > 0 {
			// The emulator answers the session's terminal queries now (DA/DSR/
			// CPR/DECRQM/DECRQSS): feed it the output, then route its replies
			// back as pty INPUT — so they never reach the ring or a rendering
			// client, and a program that stopped asking is never re-answered.
			// This is the query answering that termquery.go (DA/DSR only) and
			// xterm (CPR/DECRQSS/OSC) used to split; the emulator holds the
			// screen, so it does both. OSC 4/10-12 palette answers still want
			// the theme and are a follow-up. (emu is nil only for the bare
			// sessions some tests hand-build.)
			if s.emu != nil {
				s.emuMu.Lock()
				s.emu.Write(buf[:n])
				reply := s.emu.TakeOutput()
				s.emuMu.Unlock()
				if len(reply) > 0 {
					s.pty.Write(reply)
				}
				s.signalDirty()
			}
			// The ring is retained for correlate/normRing (transcript↔window
			// binding), not for replay — the framed transport snapshots from a
			// blank Surface, so there is nothing to replay.
			s.mu.Lock()
			s.ring = append(s.ring, buf[:n]...)
			if len(s.ring) > ringCap {
				s.ring = s.ring[len(s.ring)-ringCap:]
			}
			s.mu.Unlock()
		}
		// recycle the chunk, but let a firehose-sized buffer go once the
		// burst is over — two 1MB slabs per idle session is not a deal
		chunk = buf
		if cap(chunk) > 256<<10 && len(buf) < 64<<10 {
			chunk = nil
		}
		if err != nil {
			break
		}
	}
	// shell exited
	s.cmd.Wait()
	s.pty.Close()
	// The cwd cache is keyed by pid and its TTL only gates staleness, never
	// removal — without this every shell ever spawned left an entry behind,
	// and a reused pid could read a dead session's cwd for up to 8s.
	// Process is nil for sessions that never started a shell (tests).
	if s.cmd != nil && s.cmd.Process != nil {
		h.cwdMu.Lock()
		delete(h.cwdCache, s.cmd.Process.Pid)
		h.cwdMu.Unlock()
	}
	h.bindMu.Lock()
	for tid, sid := range h.binds {
		if sid == s.info.ID {
			delete(h.binds, tid)
		}
	}
	for tid, sid := range h.claims {
		if sid == s.info.ID {
			delete(h.claims, tid)
			delete(h.claimFg, tid)
		}
	}
	h.bindMu.Unlock()
	h.mu.Lock()
	delete(h.sessions, s.info.ID)
	remaining := 0
	for _, o := range h.sessions {
		if o.info.Workspace == s.info.Workspace {
			remaining++
		}
	}
	h.mu.Unlock()
	// scratch workspaces are ephemeral: gone with their last session
	if remaining == 0 {
		if w := h.reg.get(s.info.Workspace); w != nil && w.Scratch {
			h.reg.remove(s.info.Workspace)
		}
	}
	s.mu.Lock()
	fc := s.frameConn
	s.frameConn = nil
	s.mu.Unlock()
	// Close the framed socket so the client learns the session is gone and tears
	// its pane down (without this, `exit` hung: shell dead, socket still open).
	if fc != nil {
		fc.Close(websocket.StatusNormalClosure, "session-exited")
	}
}

func (h *Host) get(id string) *session {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.sessions[id]
}

func (h *Host) kill(id string) bool {
	s := h.get(id)
	if s == nil {
		return false
	}
	s.cmd.Process.Kill() // readPump handles cleanup
	return true
}

// ---- HTTP surface ----

func (h *Host) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", h.handleHealth)
	mux.HandleFunc("/sessions", h.handleSessions)
	mux.HandleFunc("/sessions/", h.handleSession)
	mux.HandleFunc("/workspaces", h.handleWorkspaces)
	mux.HandleFunc("/workspaces/", h.handleWorkspace)
	// cross-workspace status in one call — mission control's poll
	mux.HandleFunc("/overview", h.handleOverview)
	// every live claude session agentwatch knows about, uncorrelated —
	// debugging surface now, the drafter's read surface via /agents/{id}
	mux.HandleFunc("/agents", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, h.aw.snapshot())
	})
	mux.HandleFunc("/agents/", h.handleAgent)
	mux.HandleFunc("/attention", h.handleAttention)
	// subscription usage windows, cached from the cost-weighted prober —
	// {windows: []} until the first probe lands (or claude is absent)
	mux.HandleFunc("/usage", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, h.um.current())
	})
	mux.HandleFunc("/costs", h.handleCosts)
	mux.HandleFunc("/drafts/", h.handleDraftDecide)
	mux.HandleFunc("/edits/", h.handleEdits)
	mux.HandleFunc("/asks/", h.handleAsks)
	// per-thread verbs — ids are global, no workspace in the path
	mux.HandleFunc("/threads/", h.handleThread)
	// per-task verbs (RookTask) — global ids, same as threads
	mux.HandleFunc("/tasks/", h.handleTask)
	// plugin lifecycle (plugins.go) — the catalog, install/upgrade verbs
	mux.HandleFunc("/plugins", h.handlePlugins)
	mux.HandleFunc("/plugins/", h.handlePlugins)
	mux.HandleFunc("/agent/spend", h.handleSpend)
	mux.HandleFunc("/decisions", h.handleDecisions)
	mux.HandleFunc("/runtime", h.handleRuntime)
	mux.HandleFunc("/update", h.handleUpdate)
	// pprof rides the same authenticated loopback surface as everything
	// else — no side door (README decision 3). Reach it with the token:
	//   go tool pprof "http://127.0.0.1:$PORT/debug/pprof/heap?token=$TOKEN"
	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)
	return h.cors(h.auth(mux))
}

// workspaceListItem is a WorkspaceInfo plus live-session count and, for
// worktrees, the host-polled PR state (absent = unknown; old frontends
// ignore the field — fail open on both sides).
type workspaceListItem struct {
	WorkspaceInfo
	Sessions int         `json:"sessions"`
	PR       *PRSnapshot `json:"pr,omitempty"`
}

// allowSet turns the workspace-allow config list into a membership set, or
// nil when the list is empty (the filter is off).
func allowSet(names []string) map[string]bool {
	if len(names) == 0 {
		return nil
	}
	m := make(map[string]bool, len(names))
	for _, n := range names {
		m[n] = true
	}
	return m
}

// allowedWorkspace reports whether a workspace is visible under the
// workspace-allow filter. An empty set means the filter is off (everything
// visible). A workspace passes if its own name or its worktree source is
// listed — the name-or-WorktreeOf pattern shared with Jira/workflow lookups.
func allowedWorkspace(name, worktreeOf string, allow map[string]bool) bool {
	if len(allow) == 0 {
		return true
	}
	return allow[name] || (worktreeOf != "" && allow[worktreeOf])
}

// workspaceList assembles the workspace list with live-session counts and
// PR snapshots — GET /workspaces verbatim, and /overview's base layer.
func (h *Host) workspaceList() []workspaceListItem {
	counts := map[string]int{}
	h.mu.Lock()
	for _, s := range h.sessions {
		counts[s.info.Workspace]++
	}
	h.mu.Unlock()
	allow := allowSet(config.Load().WorkspaceAllow)
	list := h.reg.list()
	out := make([]workspaceListItem, 0, len(list))
	for _, ws := range list {
		sessions := counts[ws.Name]
		delete(counts, ws.Name) // consumed; must not reappear below even if filtered out
		if !allowedWorkspace(ws.Name, ws.WorktreeOf, allow) {
			continue
		}
		out = append(out, workspaceListItem{WorkspaceInfo: *ws, Sessions: sessions, PR: h.prm.get(ws.Name)})
	}
	// live sessions in unregistered workspaces (pre-registry hosts)
	for name, n := range counts {
		if !allowedWorkspace(name, "", allow) {
			continue
		}
		out = append(out, workspaceListItem{WorkspaceInfo: WorkspaceInfo{Name: name}, Sessions: n})
	}
	return out
}

func (h *Host) handleWorkspaces(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, h.workspaceList())
	case http.MethodPost:
		var req struct {
			Name    string
			Root    string
			Scratch bool
			// WorktreeFrom carves a new git worktree off this source
			// workspace's repo instead of pointing at an existing path;
			// Name is optional (auto: <source>-t<n>).
			WorktreeFrom string
			// Issue stamps the tracker issue this worktree is spawned
			// for (work-on-issue flow); only meaningful with WorktreeFrom.
			Issue *spawnIssue
		}
		json.NewDecoder(r.Body).Decode(&req)
		req.Name = strings.TrimSpace(req.Name)
		if req.WorktreeFrom != "" {
			h.createWorktreeWorkspace(w, req.Name, req.WorktreeFrom, req.Issue)
			return
		}
		if req.Name == "" {
			http.Error(w, "name required", http.StatusBadRequest)
			return
		}
		// store roots tilde-expanded; existence is checked at spawn time
		if req.Root == "~" || strings.HasPrefix(req.Root, "~/") {
			if home, err := os.UserHomeDir(); err == nil {
				req.Root = filepath.Join(home, strings.TrimPrefix(req.Root[1:], "/"))
			}
		}
		writeJSON(w, h.reg.upsert(req.Name, req.Root, req.Scratch))
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// spawnIssue is the wire shape of the issue in POST /workspaces: the ref
// that gets stored as provenance, plus the title — which only feeds the
// workspace name and is never persisted (the queue is the title's home).
type spawnIssue struct {
	IssueRef
	Title string
}

// branchNaming is how the source workspace names its worktree branches, from
// the config (hot-read, like the issue trackers).
//
// prefix is `branch-prefix-<workspace>`, used verbatim — teams bring their
// own separator. An explicit empty value (`branch-prefix-<ws> =`) means no
// prefix at all, so branches can match a CI naming scheme exactly; only a
// genuinely unset prefix falls back to rook/.
//
// delim is `branch-delimiter-<workspace>`, what joins a spawning issue's key
// to its title: "-" by default (FOO-123-bar-baz), `= /` for the teams whose
// scheme is FOO-123/bar-baz. Unlike the prefix, an empty value reads as unset
// — FOO-123bar-baz is a typo, not a naming scheme.
func branchNaming(ws string) (prefix, delim string) {
	cfg := config.Load()
	prefix, ok := cfg.BranchPrefixes[ws]
	if !ok {
		prefix = "rook/"
	}
	if delim = cfg.BranchDelimiters[ws]; delim == "" {
		delim = "-"
	}
	return prefix, delim
}

// createWorktreeWorkspace is POST /workspaces {worktreeFrom}: a fresh
// `git worktree add` off the source workspace's repo, on branch
// <prefix><name> (rook/ unless configured, and an issue's key and title join
// with the workspace's branch delimiter), registered as a workspace
// rooted at the new checkout. The spawner's isolation rung — parallel
// agent sessions get a tree each.
func (h *Host) createWorktreeWorkspace(w http.ResponseWriter, name, from string, issue *spawnIssue) {
	src := h.reg.get(from)
	if src == nil || src.Root == "" {
		http.Error(w, fmt.Sprintf("workspace %q has no root to branch from", from), http.StatusBadRequest)
		return
	}
	if gitInfo(src.Root) == nil {
		http.Error(w, fmt.Sprintf("%s is not a git repo", src.Root), http.StatusBadRequest)
		return
	}
	if issue != nil && issue.Key == "" {
		issue = nil // an empty ref is no ref
	}
	prefix, delim := branchNaming(from)
	// what the branch carries after the prefix. It tracks name on every path
	// but the issue-derived one, where the delimiter may split key from title
	// (FOO-123/bar-baz) — a name can't, being a directory too.
	suffix := name
	if name == "" {
		// auto-names must also step past branches left behind by deleted
		// worktrees — the branch outliving its tree is the design
		free := func(name, suffix string) bool {
			_, err := os.Stat(worktreeDir(name))
			return os.IsNotExist(err) && h.reg.get(name) == nil && !branchExists(src.Root, prefix+suffix)
		}
		key, title := issueSlugs(issue)
		if base := joinSlugs(key, title, "-"); base != "" {
			// issue spawns name themselves from the issue
			branchBase := joinSlugs(key, title, delim)
			for n := 1; ; n++ {
				name, suffix = base, branchBase
				if n > 1 {
					name = fmt.Sprintf("%s-%d", base, n)
					suffix = fmt.Sprintf("%s-%d", branchBase, n)
				}
				if free(name, suffix) {
					break
				}
			}
		} else {
			// last resort for nameless manual spawns
			for n := 1; ; n++ {
				name = fmt.Sprintf("%s-t%d", from, n)
				suffix = name
				if free(name, suffix) {
					break
				}
			}
		}
	} else if h.reg.get(name) != nil {
		http.Error(w, fmt.Sprintf("workspace %q already exists", name), http.StatusConflict)
		return
	} else if branchExists(src.Root, prefix+name) {
		http.Error(w, fmt.Sprintf("branch %s%s already exists (left by an earlier worktree) — pick another name or delete the branch", prefix, name), http.StatusConflict)
		return
	}
	dir := worktreeDir(name)
	branch := prefix + suffix
	if err := worktreeAdd(src.Root, dir, branch); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	var ref *IssueRef
	if issue != nil {
		ref = &issue.IssueRef
	}
	ws, err := h.reg.createWorktreeWS(name, dir, from, branch, ref)
	if err != nil {
		_ = worktreeRemove(dir, true) // roll back the checkout; nothing is in it yet
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, ws)
}

// handleWorkspace routes /workspaces/{name} (DELETE: kill its sessions and
// drop it from the registry) and /workspaces/{name}/status (GET: the
// dashboard payload).
func (h *Host) handleWorkspace(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/workspaces/")
	name, action, _ := strings.Cut(rest, "/")
	if name == "" {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	switch {
	case action == "status" && r.Method == http.MethodGet:
		h.handleWorkspaceStatus(w, name)
	case action == "issues" && r.Method == http.MethodGet:
		h.handleWorkspaceIssues(w, r, name)
	case action == "spawn" && r.Method == http.MethodPost:
		h.handleWorkspaceSpawn(w, r, name)
	// the read-only review surface (review.go) — the Monaco pane's data
	case action == "changes" && r.Method == http.MethodGet:
		h.handleWorkspaceChanges(w, r, name)
	case action == "diff" && r.Method == http.MethodGet:
		h.handleWorkspaceDiff(w, r, name)
	case action == "file" && r.Method == http.MethodGet:
		h.handleWorkspaceFile(w, r, name)
	case action == "write" && r.Method == http.MethodPost:
		h.handleWorkspaceWrite(w, r, name)
	case action == "files" && r.Method == http.MethodGet:
		h.handleWorkspaceFiles(w, r, name)
	// what the editor's start screen leads with (recents.go)
	case action == "recents":
		h.handleWorkspaceRecents(w, r, name)
	case action == "grep" && r.Method == http.MethodGet:
		h.handleWorkspaceGrep(w, r, name)
	case action == "gutter":
		h.handleWorkspaceGutter(w, r, name)
	// threads: file-anchored AI conversations (threads.go)
	case action == "threads/submit" && r.Method == http.MethodPost:
		h.handleThreadsSubmit(w, r, name)
	case action == "threads/watch" && r.Method == http.MethodGet:
		h.handleThreadsWatch(w, r, name)
	case action == "threads":
		h.handleWorkspaceThreads(w, r, name)
	// language servers (lsp.go) — the exploration queries + runtime status
	case strings.HasPrefix(action, "lsp/"):
		h.handleWorkspaceLSP(w, r, name, strings.TrimPrefix(action, "lsp/"))
	// review work-type over RookTask (reviewtasks.go / tasksapi.go)
	case action == "review" && r.Method == http.MethodPost:
		h.handleWorkspaceReview(w, r, name)
	// explore work-type — investigations with breadcrumb trails
	case action == "explore" && r.Method == http.MethodPost:
		h.handleWorkspaceExplore(w, r, name)
	case action == "tasks" && r.Method == http.MethodGet:
		h.handleWorkspaceTasks(w, r, name)
	case action == "" && r.Method == http.MethodDelete:
		force := r.URL.Query().Get("force") == "1"
		// prune also deletes the worktree's local branch — the close-the-
		// loop cleanup once its PR merged. Explicit opt-in: branch survival
		// is otherwise the design.
		prune := r.URL.Query().Get("prune") == "1"
		ws := h.reg.get(name)
		// Worktree workspaces guard their checkout: refuse BEFORE any side
		// effect (sessions stay alive on refusal) when removal would lose
		// work — dirty files, or commits no other ref reaches. Unknown
		// state counts as risky. The branch survives removal either way.
		if ws != nil && ws.WorktreeOf != "" && !force {
			if _, err := os.Stat(ws.Root); err == nil {
				dirty, unmerged, err := worktreeRisk(ws.Root, ws.Branch)
				if err != nil {
					http.Error(w, fmt.Sprintf("can't prove the worktree is safe to remove (%v) — force to discard", err), http.StatusConflict)
					return
				}
				if dirty > 0 || unmerged > 0 {
					http.Error(w, fmt.Sprintf("worktree has %d dirty file(s) and %d unmerged commit(s) on %s — force to discard the tree (the branch survives)", dirty, unmerged, ws.Branch), http.StatusConflict)
					return
				}
			}
		}
		h.mu.Lock()
		var ids []string
		for id, s := range h.sessions {
			if s.info.Workspace == name {
				ids = append(ids, id)
			}
		}
		h.mu.Unlock()
		for _, id := range ids {
			h.kill(id)
		}
		if ws != nil && ws.WorktreeOf != "" {
			if _, err := os.Stat(ws.Root); err == nil {
				// resolve the main repo before removal — the checkout is the
				// only reliable pointer to it and it's about to disappear
				repo := ""
				if prune && ws.Branch != "" {
					repo, _ = worktreeRepo(ws.Root)
				}
				if err := worktreeRemove(ws.Root, force); err != nil {
					http.Error(w, err.Error(), http.StatusInternalServerError)
					return
				}
				if repo != "" {
					// best-effort: a surviving branch is the safe default,
					// and it stays visible in git either way
					if err := branchDelete(repo, ws.Branch); err != nil {
						log.Printf("workspace %s: prune %s: %v", name, ws.Branch, err)
					}
				}
			}
		}
		h.reg.remove(name)
		h.prm.forget(name)
		h.reg.deleteStages(name)
		w.WriteHeader(http.StatusNoContent)
	default:
		http.Error(w, "not found", http.StatusNotFound)
	}
}

// sessionStatus is SessionInfo plus what's live inside the window right
// now. The dashboard renders it, and the attention router (docs/agent.md)
// reads the same struct — Fg is how rook knows a window runs claude, and
// Agent is that claude session's transcript-derived state.
type sessionStatus struct {
	SessionInfo
	Fg  string `json:"fg"`
	Cwd string `json:"cwd"`
	// AgentSession is the claude transcript id claimed for this window
	// (set even while the agent isn't foreground); Agent is that
	// session's live state when one is paired.
	AgentSession string       `json:"agentSession,omitempty"`
	Agent        *AgentStatus `json:"agent,omitempty"`
}

type workspaceStatus struct {
	Name     string          `json:"name"`
	Root     string          `json:"root,omitempty"`
	Scratch  bool            `json:"scratch,omitempty"`
	Git      *GitInfo        `json:"git,omitempty"`
	Sessions []sessionStatus `json:"sessions"`
	// Attention counts sessions whose agent is waiting on the user.
	Attention int `json:"attention"`
}

// ansiRE strips escape sequences (CSI, OSC, single-char ESC) so ring
// content can be compared to transcript text.
var ansiRE = regexp.MustCompile(`\x1b(\[[0-9;:?<=>]*[ -/]*[@-~]|\][^\x07\x1b]*(\x07|\x1b\\)?|[@-Z\\-_])`)

// normText reduces text to lowercase alphanumerics: TUI rendering differs
// from transcript text by markdown markers, wrapping, and color — none of
// which survive this.
func normText(b []byte) []byte {
	b = ansiRE.ReplaceAll(b, nil)
	out := b[:0]
	for _, c := range b {
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
			out = append(out, c)
		case c >= 'A' && c <= 'Z':
			out = append(out, c+'a'-'A')
		}
	}
	return out
}

// askProbe is the tail of an ask, normalized — long enough to be
// distinctive, short enough to survive agentmon's content truncation.
func askProbe(ask string) []byte {
	p := normText([]byte(ask))
	if len(p) > 160 {
		p = p[len(p)-160:]
	}
	if len(p) < 12 {
		return nil // too generic to be evidence
	}
	return p
}

func (s *session) normRing() []byte {
	s.mu.Lock()
	ring := make([]byte, len(s.ring))
	copy(ring, s.ring)
	s.mu.Unlock()
	return normText(ring)
}

// correlate pairs rook windows running claude with agentwatch's transcript
// sessions. Working directory narrows the field, but several claude
// sessions can share one dir (including ones running outside rook), so
// within a dir the evidence hierarchy is:
//
//  0. claims — the claude session said so itself (SessionStart hook via
//     rookctl); a claimed transcript never falls through to heuristics
//  1. sticky bindings — pairs proven earlier by ring content stay paired
//  2. ring content — at needs_input, claude's ask text is on exactly one
//     window's PTY; a unique match proves the pair and binds it
//  3. recency — last resort, never binds (guesses must not stick)
//
// live is index-aligned with sessions and supplies the ring buffers.
func (h *Host) correlate(sessions []sessionStatus, live []*session, states []*AgentStatus) {
	sort.Slice(states, func(i, j int) bool { return states[i].LastEvent.After(states[j].LastEvent) })
	h.bindMu.Lock()
	defer h.bindMu.Unlock()

	// surface claims regardless of what's foreground right now
	rookToClaim := make(map[string]string, len(h.claims))
	for tid, sid := range h.claims {
		rookToClaim[sid] = tid
	}
	for i := range sessions {
		sessions[i].AgentSession = rookToClaim[sessions[i].ID]
	}

	var windows []int // claude windows, still unassigned
	for i := range sessions {
		if sessions[i].Fg == "claude" && sessions[i].Cwd != "" {
			windows = append(windows, i)
		}
	}
	dirMatch := func(st *AgentStatus, i int) bool {
		return st.CWD == sessions[i].Cwd || st.Project == sessions[i].Cwd
	}
	assign := func(st *AgentStatus, i int) {
		sessions[i].Agent = st
		for k, w := range windows {
			if w == i {
				windows = append(windows[:k], windows[k+1:]...)
				break
			}
		}
	}

	var unbound []*AgentStatus
	for _, st := range states {
		// tier 0: claimed transcripts belong to their window, period —
		// even when that window's claude isn't foreground (suspended,
		// shelled out), the state must not drift to another window.
		if id := h.claims[st.SessionID]; id != "" {
			for _, i := range windows {
				if sessions[i].ID == id {
					assign(st, i)
					break
				}
			}
			continue
		}
		if id := h.binds[st.SessionID]; id != "" {
			bound := false
			for _, i := range windows {
				if sessions[i].ID == id {
					assign(st, i)
					bound = true
					break
				}
			}
			if bound {
				continue
			}
			delete(h.binds, st.SessionID) // window is gone; unpin
		}
		unbound = append(unbound, st)
	}

	var leftover []*AgentStatus
	rings := make(map[int][]byte)
	for _, st := range unbound {
		probe := askProbe(st.Ask)
		if st.State != "needs_input" || probe == nil {
			leftover = append(leftover, st)
			continue
		}
		match := -1
		for _, i := range windows {
			if !dirMatch(st, i) {
				continue
			}
			if _, ok := rings[i]; !ok {
				rings[i] = live[i].normRing()
			}
			if bytes.Contains(rings[i], probe) {
				if match != -1 {
					match = -1 // two windows show the same text: not evidence
					break
				}
				match = i
			}
		}
		if match == -1 {
			leftover = append(leftover, st)
			continue
		}
		h.binds[st.SessionID] = sessions[match].ID
		assign(st, match)
	}

	for _, st := range leftover {
		for _, i := range windows {
			if dirMatch(st, i) {
				assign(st, i)
				break
			}
		}
	}
}

func (h *Host) handleWorkspaceStatus(w http.ResponseWriter, name string) {
	writeJSON(w, h.statusFor(name, true))
}

// statusFor assembles the live picture of one workspace — the dashboard
// payload, and (via /attention) the attention router's input. withGit
// skips the repo probe for callers that only care about sessions.
func (h *Host) statusFor(name string, withGit bool) workspaceStatus {
	h.mu.Lock()
	var sess []*session
	for _, s := range h.sessions {
		if s.info.Workspace == name {
			sess = append(sess, s)
		}
	}
	h.mu.Unlock()
	// creation order matches the strip's window numbering
	sort.Slice(sess, func(i, j int) bool { return sess[i].info.Created.Before(sess[j].info.Created) })

	out := workspaceStatus{Name: name, Sessions: make([]sessionStatus, len(sess))}
	if ws := h.reg.get(name); ws != nil {
		out.Root, out.Scratch = ws.Root, ws.Scratch
	}
	// lsof runs ~100ms a call — probe every session concurrently
	var wg sync.WaitGroup
	for i, s := range sess {
		wg.Add(1)
		go func(i int, s *session) {
			defer wg.Done()
			s.mu.Lock()
			info := s.info
			s.mu.Unlock()
			pid := s.cmd.Process.Pid
			out.Sessions[i] = sessionStatus{SessionInfo: info, Fg: h.fgOf(s.pty, pid), Cwd: h.cachedCwdOf(pid)}
		}(i, s)
	}
	wg.Wait()
	if withGit {
		// repo status from the root — or from wherever the first shell is,
		// for rootless (scratch) workspaces
		dir := out.Root
		if dir == "" && len(out.Sessions) > 0 {
			dir = out.Sessions[0].Cwd
		}
		out.Git = gitInfo(dir)
	}
	h.correlate(out.Sessions, sess, h.aw.snapshot())
	for _, s := range out.Sessions {
		if s.Agent != nil && s.Agent.State == "needs_input" {
			out.Attention++
		}
	}
	return out
}

func (h *Host) cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (h *Host) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok := r.URL.Query().Get("token")
		if tok == "" {
			tok = strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		}
		if tok != h.token {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func (h *Host) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]any{"ok": true, "release": version.Version, "build": version.Build, "pid": os.Getpid()})
}

func (h *Host) handleSessions(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		h.mu.Lock()
		list := make([]SessionInfo, 0, len(h.sessions))
		for _, s := range h.sessions {
			list = append(list, s.info)
		}
		h.mu.Unlock()
		// stable order: by numeric id (creation order)
		for i := 0; i < len(list); i++ {
			for j := i + 1; j < len(list); j++ {
				if list[j].Created.Before(list[i].Created) {
					list[i], list[j] = list[j], list[i]
				}
			}
		}
		writeJSON(w, list)
	case http.MethodPost:
		var req struct {
			Cols, Rows int
			CwdFrom    string // inherit the working directory of this session's shell
			Workspace  string
		}
		json.NewDecoder(r.Body).Decode(&req)
		if req.Cols <= 0 || req.Cols > 1000 {
			req.Cols = 100
		}
		if req.Rows <= 0 || req.Rows > 1000 {
			req.Rows = 30
		}
		ws := req.Workspace
		if ws == "" {
			ws = "main"
		}
		// register/touch the workspace; a workspace root seeds the first
		// shell's cwd when there's no session to inherit from
		wsInfo := h.reg.upsert(ws, "", false)
		cwd := ""
		if from := h.get(req.CwdFrom); from != nil {
			cwd = cwdOf(from.cmd.Process.Pid)
		}
		if cwd == "" && wsInfo.Root != "" {
			cwd = wsInfo.Root
		}
		s, err := h.spawn(req.Cols, req.Rows, cwd, ws)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, s.info)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// handleSession routes /sessions/{id}, /sessions/{id}/resize, /sessions/{id}/attach.
func (h *Host) handleSession(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/sessions/")
	id, action, _ := strings.Cut(rest, "/")
	s := h.get(id)
	if s == nil {
		http.Error(w, "no such session: "+id, http.StatusNotFound)
		return
	}
	switch {
	case action == "" && r.Method == http.MethodDelete:
		h.kill(id)
		w.WriteHeader(http.StatusNoContent)
	case action == "cwd" && r.Method == http.MethodGet:
		// the shell's live working directory — feeds "set workspace root
		// to here" and anything else that wants where the user actually is
		writeJSON(w, map[string]string{"cwd": cwdOf(s.cmd.Process.Pid)})
	case action == "edit" && r.Method == http.MethodPost:
		// `rookctl edit` (the `re` shim): take over this session's pane
		// with the editor, vim-style — see edit.go
		h.handleSessionEdit(w, r, s)
	case action == "ask" && r.Method == http.MethodPost:
		// `rookctl ask` (and the MCP tool): a question for the human,
		// rendered as a split beside this session's pane — see ask.go
		h.handleSessionAsk(w, r, s)
	case action == "asks" && r.Method == http.MethodGet:
		// the async drain: decided asks out (consumed), pending ids listed
		h.handleSessionAsks(w, s)
	case action == "claim" && r.Method == http.MethodPost:
		// A claude session announcing which window it lives in — sent by
		// `rookctl claim` from a SessionStart hook (ROOK_SESSION names the
		// window, the hook's stdin names the transcript). Authoritative:
		// it displaces heuristic evidence for both parties.
		var req struct {
			AgentSession string
			Release      bool
		}
		json.NewDecoder(r.Body).Decode(&req)
		if req.AgentSession == "" {
			http.Error(w, "agentSession required", http.StatusBadRequest)
			return
		}
		h.bindMu.Lock()
		if req.Release {
			if h.claims[req.AgentSession] == id {
				delete(h.claims, req.AgentSession)
				delete(h.claimFg, req.AgentSession)
			}
		} else {
			// one live claude per window: a new claim evicts older ones
			for tid, sid := range h.claims {
				if sid == id {
					delete(h.claims, tid)
					delete(h.claimFg, tid)
				}
			}
			h.claims[req.AgentSession] = id
			// The hook runs inside the agent, so the tty's foreground group
			// right now IS the agent's. See claimFg.
			h.claimFg[req.AgentSession] = fgPgrp(s.pty)
			delete(h.binds, req.AgentSession)
		}
		h.bindMu.Unlock()
		if !req.Release {
			// an answer decided while this window had no live agent has
			// been waiting for someone to tell (ask.go) — this is them
			go h.ringOwedDoorbells(id)
		}
		w.WriteHeader(http.StatusNoContent)
	case action == "input" && r.Method == http.MethodPost:
		// Raw, byte-faithful pty write — the attention surface's actuator
		// (rookctl send, draft approval). Callers append "\r" to submit;
		// the host adds nothing.
		var req struct{ Data string }
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Data == "" {
			http.Error(w, "data required", http.StatusBadRequest)
			return
		}
		if _, err := s.pty.Write([]byte(req.Data)); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case action == "resize" && r.Method == http.MethodPost:
		var req struct{ Cols, Rows int }
		json.NewDecoder(r.Body).Decode(&req)
		if req.Cols <= 0 || req.Rows <= 0 {
			http.Error(w, "bad size", http.StatusBadRequest)
			return
		}
		if err := cpty.Setsize(s.pty, &cpty.Winsize{Cols: uint16(req.Cols), Rows: uint16(req.Rows)}); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		s.mu.Lock()
		s.info.Cols, s.info.Rows = req.Cols, req.Rows
		s.mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	case action == "framed":
		// The host-side-emulator transport (termframe.go): the only terminal
		// transport since HI-C retired the raw byte-stream + ring replay.
		h.handleAttachFramed(w, r, s)
	default:
		http.Error(w, "not found", http.StatusNotFound)
	}
}

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

	mu     sync.Mutex // guards ring, attach
	ring   []byte
	attach *websocket.Conn
	wmu    sync.Mutex // serializes writes to the attached socket
}

type Host struct {
	mu       sync.Mutex
	sessions map[string]*session
	nextID   int
	token    string
	reg      *registry
	aw       *agentWatch

	cwdMu    sync.Mutex
	cwdCache map[int]cwdEntry

	// Two tiers of transcript↔window pairing (see correlate): claims are
	// authoritative (a SessionStart hook inside the claude process told us,
	// via `rookctl claim`); binds are heuristic (proven by ring content).
	// Both map transcript session id → rook session id.
	bindMu sync.Mutex
	claims map[string]string
	binds  map[string]string

	// Live drafts by transcript session id — what /attention decorates its
	// items with. The decisions table is the durable ledger; this map is
	// just the "current open draft" index over it.
	draftMu sync.Mutex
	drafts  map[string]draftInfo

	// um caches subscription usage windows (WatchUsage).
	um *usageMon

	// prm caches per-worktree PR state (WatchPRs) — the close-the-loop
	// signal on workspace cards.
	prm *prMon

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
		cwdCache: make(map[int]cwdEntry),
		claims:   make(map[string]string),
		binds:    make(map[string]string),
		drafts:   make(map[string]draftInfo),
		um:       newUsageMon(),
		prm:      newPRMon(),
	}
	h.ctx, h.cancel = context.WithCancel(context.Background())
	// Manual-attribution + stale-ask hooks: the transcript is the ground
	// truth for what actually got answered (see onUserReply).
	h.aw.onUserReply = h.onUserReply
	h.aw.onTurnCompleted = h.onTurnCompleted
	go h.aw.run(h.ctx)
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
		pty: f,
		cmd: cmd,
	}
	h.sessions[s.info.ID] = s
	h.mu.Unlock()

	go h.readPump(s)
	return s, nil
}

// readPump runs for the session's whole life, host-side: output lands in the
// ring buffer whether or not a client is attached — sessions keep producing
// while detached, and the ring is what a reattaching client replays.
func (h *Host) readPump(s *session) {
	buf := make([]byte, 32*1024)
	for {
		n, err := s.pty.Read(buf)
		if n > 0 {
			s.mu.Lock()
			s.ring = append(s.ring, buf[:n]...)
			if len(s.ring) > ringCap {
				s.ring = s.ring[len(s.ring)-ringCap:]
			}
			c := s.attach
			s.mu.Unlock()
			if c != nil {
				s.wmu.Lock()
				werr := c.Write(context.Background(), websocket.MessageBinary, buf[:n])
				s.wmu.Unlock()
				if werr != nil {
					s.detach(c)
				}
			}
		}
		if err != nil {
			break
		}
	}
	// shell exited
	s.cmd.Wait()
	s.pty.Close()
	h.bindMu.Lock()
	for tid, sid := range h.binds {
		if sid == s.info.ID {
			delete(h.binds, tid)
		}
	}
	for tid, sid := range h.claims {
		if sid == s.info.ID {
			delete(h.claims, tid)
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
	c := s.attach
	s.attach = nil
	s.mu.Unlock()
	if c != nil {
		c.Close(websocket.StatusNormalClosure, "session-exited")
	}
}

func (s *session) detach(c *websocket.Conn) {
	s.mu.Lock()
	if s.attach == c {
		s.attach = nil
	}
	s.mu.Unlock()
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
	mux.HandleFunc("/agent/spend", h.handleSpend)
	mux.HandleFunc("/decisions", h.handleDecisions)
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

func (h *Host) handleWorkspaces(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		counts := map[string]int{}
		h.mu.Lock()
		for _, s := range h.sessions {
			counts[s.info.Workspace]++
		}
		h.mu.Unlock()
		list := h.reg.list()
		out := make([]workspaceListItem, 0, len(list))
		for _, ws := range list {
			out = append(out, workspaceListItem{WorkspaceInfo: *ws, Sessions: counts[ws.Name], PR: h.prm.get(ws.Name)})
			delete(counts, ws.Name)
		}
		// live sessions in unregistered workspaces (pre-registry hosts)
		for name, n := range counts {
			out = append(out, workspaceListItem{WorkspaceInfo: WorkspaceInfo{Name: name}, Sessions: n})
		}
		writeJSON(w, out)
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
			Issue *IssueRef
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

// createWorktreeWorkspace is POST /workspaces {worktreeFrom}: a fresh
// `git worktree add` off the source workspace's repo, on branch
// rook/<name>, registered as a workspace rooted at the new checkout. The
// spawner's isolation rung — parallel agent sessions get a tree each.
func (h *Host) createWorktreeWorkspace(w http.ResponseWriter, name, from string, issue *IssueRef) {
	src := h.reg.get(from)
	if src == nil || src.Root == "" {
		http.Error(w, fmt.Sprintf("workspace %q has no root to branch from", from), http.StatusBadRequest)
		return
	}
	if gitInfo(src.Root) == nil {
		http.Error(w, fmt.Sprintf("%s is not a git repo", src.Root), http.StatusBadRequest)
		return
	}
	if name == "" {
		// auto-names must also step past branches left behind by deleted
		// worktrees — the branch outliving its tree is the design
		for n := 1; ; n++ {
			name = fmt.Sprintf("%s-t%d", from, n)
			if _, err := os.Stat(worktreeDir(name)); os.IsNotExist(err) &&
				h.reg.get(name) == nil && !branchExists(src.Root, "rook/"+name) {
				break
			}
		}
	} else if h.reg.get(name) != nil {
		http.Error(w, fmt.Sprintf("workspace %q already exists", name), http.StatusConflict)
		return
	} else if branchExists(src.Root, "rook/"+name) {
		http.Error(w, fmt.Sprintf("branch rook/%s already exists (left by an earlier worktree) — pick another name or delete the branch", name), http.StatusConflict)
		return
	}
	dir := worktreeDir(name)
	branch := "rook/" + name
	if err := worktreeAdd(src.Root, dir, branch); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if issue != nil && issue.Key == "" {
		issue = nil // an empty ref is no ref
	}
	ws, err := h.reg.createWorktreeWS(name, dir, from, branch, issue)
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
	case action == "" && r.Method == http.MethodDelete:
		force := r.URL.Query().Get("force") == "1"
		// prune also deletes the local rook/<name> branch — the close-the-
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
			out.Sessions[i] = sessionStatus{SessionInfo: info, Fg: fgOf(s.pty, pid), Cwd: h.cachedCwdOf(pid)}
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
			}
		} else {
			// one live claude per window: a new claim evicts older ones
			for tid, sid := range h.claims {
				if sid == id {
					delete(h.claims, tid)
				}
			}
			h.claims[req.AgentSession] = id
			delete(h.binds, req.AgentSession)
		}
		h.bindMu.Unlock()
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
	case action == "attach":
		h.handleAttach(w, r, s)
	default:
		http.Error(w, "not found", http.StatusNotFound)
	}
}

func (h *Host) handleAttach(w http.ResponseWriter, r *http.Request, s *session) {
	// Page origin is the Wails asset scheme (or vite in dev), never this
	// server's host — the token is the real gate, not Origin.
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}

	// One client per session: a new attach replaces the old (page reload).
	//
	// Gap-free replay: the ring copy and the attach swap happen in ONE
	// critical section, with wmu held across the swap AND the replay. A
	// pty chunk landing during replay sees the new socket and parks its
	// live write on wmu until the replay is out — every byte reaches the
	// client exactly once, in order. (The old shape set attach only after
	// replaying; bytes arriving in between reached the ring but never
	// this client — silent scrollback loss under output.)
	s.wmu.Lock()
	s.mu.Lock()
	if old := s.attach; old != nil {
		go old.Close(websocket.StatusPolicyViolation, "replaced")
	}
	ring := make([]byte, len(s.ring))
	copy(ring, s.ring)
	s.attach = c
	s.mu.Unlock()

	ok := true
	for off := 0; off < len(ring); off += 32 * 1024 {
		end := min(off+32*1024, len(ring))
		if c.Write(context.Background(), websocket.MessageBinary, ring[off:end]) != nil {
			ok = false
			break
		}
	}
	// Mark the replay→live seam with the sole text frame on this socket
	// (output is all binary). Replayed bytes contain terminal queries (OSC
	// 10/11, CSI 6n, …) whose askers are long gone; the client must
	// swallow xterm's auto-replies to them or they land in the shell as
	// junk input ("11;rgb:0000/…;1R" at the prompt). Sent under wmu, so
	// every live pump write sorts strictly after it.
	if ok {
		ok = c.Write(context.Background(), websocket.MessageText, []byte("live")) == nil
	}
	s.wmu.Unlock()
	if !ok {
		s.detach(c)
		c.CloseNow()
		return
	}

	// Client → PTY. Detach on any read error; the session lives on.
	for {
		_, data, rerr := c.Read(r.Context())
		if rerr != nil {
			break
		}
		if _, werr := s.pty.Write(data); werr != nil {
			break
		}
	}
	s.detach(c)
	c.CloseNow()
}

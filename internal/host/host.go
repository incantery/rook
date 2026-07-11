// Package host is the PTY host: it owns shell sessions and serves them over
// localhost HTTP + WebSocket. It runs in the rook-host process, NOT the app
// (README decision 2) — the UI can crash, rebuild, and reattach without
// killing shells. Sessions keep a replay ring buffer so a reattaching client
// gets recent scrollback, tmux-style.
package host

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	cpty "github.com/creack/pty"
)

const (
	Version = 1
	ringCap = 512 * 1024
)

type SessionInfo struct {
	ID      string    `json:"id"`
	Name    string    `json:"name"`
	Cols    int       `json:"cols"`
	Rows    int       `json:"rows"`
	Created time.Time `json:"created"`
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
}

func New() *Host {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return &Host{
		sessions: make(map[string]*session),
		token:    hex.EncodeToString(b),
	}
}

func (h *Host) Token() string { return h.token }

// ---- session lifecycle ----

func (h *Host) spawn(cols, rows int, cwd string) (*session, error) {
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/zsh"
	}
	cmd := exec.Command(shell, "-l")
	if cwd != "" {
		cmd.Dir = cwd
	} else if home, err := os.UserHomeDir(); err == nil {
		cmd.Dir = home
	}
	cmd.Env = append(os.Environ(), "TERM=xterm-256color", "COLORTERM=truecolor")

	f, err := cpty.StartWithSize(cmd, &cpty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
	if err != nil {
		return nil, err
	}

	h.mu.Lock()
	h.nextID++
	s := &session{
		info: SessionInfo{
			ID:      fmt.Sprintf("s%d", h.nextID),
			Name:    fmt.Sprintf("%s — %d", filepath.Base(shell), h.nextID),
			Cols:    cols,
			Rows:    rows,
			Created: time.Now(),
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
	h.mu.Lock()
	delete(h.sessions, s.info.ID)
	h.mu.Unlock()
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
	return h.cors(h.auth(mux))
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
	writeJSON(w, map[string]any{"ok": true, "version": Version, "pid": os.Getpid()})
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
		}
		json.NewDecoder(r.Body).Decode(&req)
		if req.Cols <= 0 || req.Cols > 1000 {
			req.Cols = 100
		}
		if req.Rows <= 0 || req.Rows > 1000 {
			req.Rows = 30
		}
		cwd := ""
		if from := h.get(req.CwdFrom); from != nil {
			cwd = cwdOf(from.cmd.Process.Pid)
		}
		s, err := h.spawn(req.Cols, req.Rows, cwd)
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
	s.mu.Lock()
	if old := s.attach; old != nil {
		s.attach = nil
		go old.Close(websocket.StatusPolicyViolation, "replaced")
	}
	ring := make([]byte, len(s.ring))
	copy(ring, s.ring)
	s.mu.Unlock()

	// Replay before going live; wmu keeps the pump from interleaving.
	s.wmu.Lock()
	ok := true
	for off := 0; off < len(ring); off += 32 * 1024 {
		end := min(off+32*1024, len(ring))
		if c.Write(context.Background(), websocket.MessageBinary, ring[off:end]) != nil {
			ok = false
			break
		}
	}
	s.wmu.Unlock()
	if !ok {
		c.CloseNow()
		return
	}
	s.mu.Lock()
	s.attach = c
	s.mu.Unlock()

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

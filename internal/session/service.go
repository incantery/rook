// Package session owns shell sessions: it spawns the user's shell on a PTY
// and shuttles bytes between it and the frontend. Interim, in-process stand-in
// for the separate PTY host process (README decision 2); the wire shape
// (spawn/resize bindings + a byte stream per session) is what survives the
// split.
//
// PTY bytes travel over a localhost WebSocket, not Wails events: the event
// bus drops messages under flood (fzf redraws), and a terminal cannot tolerate
// lost chunks — every one splices lines together mid-escape-sequence. TCP
// gives ordering, delivery, and backpressure; binary frames avoid the
// base64+JSON tax.
package session

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"

	"github.com/coder/websocket"
	cpty "github.com/creack/pty"
	"github.com/wailsapp/wails/v3/pkg/application"
)

type session struct {
	pty      *os.File
	cmd      *exec.Cmd
	attached bool
}

type Service struct {
	mu       sync.Mutex
	sessions map[string]*session
	nextID   int
	listener net.Listener
}

// ServiceStartup starts the byte-stream server on an ephemeral localhost
// port. TODO: any local process can connect; add a per-session token when
// the PTY host splits out.
func (s *Service) ServiceStartup(ctx context.Context, options application.ServiceOptions) error {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	s.listener = ln
	mux := http.NewServeMux()
	mux.HandleFunc("/session/", s.handleWS)
	go http.Serve(ln, mux)
	return nil
}

// Endpoint returns the WebSocket base URL; the frontend appends /session/{id}.
func (s *Service) Endpoint() string {
	return "ws://" + s.listener.Addr().String()
}

func (s *Service) Spawn(cols, rows int) (string, error) {
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/zsh"
	}
	cmd := exec.Command(shell, "-l")
	if home, err := os.UserHomeDir(); err == nil {
		cmd.Dir = home
	}
	cmd.Env = append(os.Environ(), "TERM=xterm-256color", "COLORTERM=truecolor")

	f, err := cpty.StartWithSize(cmd, &cpty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
	if err != nil {
		return "", err
	}

	s.mu.Lock()
	if s.sessions == nil {
		s.sessions = make(map[string]*session)
	}
	s.nextID++
	id := fmt.Sprintf("s%d", s.nextID)
	s.sessions[id] = &session{pty: f, cmd: cmd}
	s.mu.Unlock()
	return id, nil
}

// handleWS attaches a client to a session's byte stream. The PTY is not read
// until a client attaches — early output (the first prompt) waits in the
// kernel PTY buffer, so nothing is lost in the spawn→connect window.
func (s *Service) handleWS(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/session/")

	s.mu.Lock()
	sess, ok := s.sessions[id]
	if ok && sess.attached {
		ok = false
	}
	if ok {
		sess.attached = true
	}
	s.mu.Unlock()
	if !ok {
		http.Error(w, "no such session (or already attached): "+id, http.StatusNotFound)
		return
	}

	// The page's origin is the Wails asset scheme, never this server's host,
	// so the default same-origin check would always fail.
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		s.drop(id, sess)
		return
	}

	ctx := r.Context()

	// PTY → WS. Read error means the shell exited (or the PTY closed);
	// closing the socket is how the frontend learns.
	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, rerr := sess.pty.Read(buf)
			if n > 0 {
				if werr := c.Write(ctx, websocket.MessageBinary, buf[:n]); werr != nil {
					break
				}
			}
			if rerr != nil {
				break
			}
		}
		c.Close(websocket.StatusNormalClosure, "session ended")
	}()

	// WS → PTY. Read error means the client went away (reload, window
	// closed); the session dies with it — the UI is its only consumer until
	// the PTY host split makes detach/reattach a feature.
	for {
		_, data, rerr := c.Read(ctx)
		if rerr != nil {
			break
		}
		if _, werr := sess.pty.Write(data); werr != nil {
			break
		}
	}
	c.CloseNow()
	s.drop(id, sess)
	sess.cmd.Wait()
}

func (s *Service) drop(id string, sess *session) {
	sess.cmd.Process.Kill()
	sess.pty.Close()
	s.mu.Lock()
	delete(s.sessions, id)
	s.mu.Unlock()
}

func (s *Service) get(id string) (*session, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	sess, ok := s.sessions[id]
	if !ok {
		return nil, errors.New("no such session: " + id)
	}
	return sess, nil
}

func (s *Service) Resize(id string, cols, rows int) error {
	sess, err := s.get(id)
	if err != nil {
		return err
	}
	return cpty.Setsize(sess.pty, &cpty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
}

func (s *Service) Kill(id string) error {
	sess, err := s.get(id)
	if err != nil {
		return err
	}
	return sess.cmd.Process.Kill()
}

// ServiceShutdown kills every live shell when the app exits. Goes away with
// the PTY host split, whose entire point is that shells outlive the app.
func (s *Service) ServiceShutdown() error {
	if s.listener != nil {
		s.listener.Close()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, sess := range s.sessions {
		sess.cmd.Process.Kill()
		sess.pty.Close()
	}
	return nil
}

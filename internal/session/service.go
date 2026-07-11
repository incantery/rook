// Package session owns shell sessions: it spawns the user's shell on a PTY
// and shuttles bytes between it and the frontend. Interim, in-process stand-in
// for the separate PTY host process (README decision 2); the wire shape
// (spawn/write/resize + data/exit events) is what survives the split.
package session

import (
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"sync"

	cpty "github.com/creack/pty"
	"github.com/wailsapp/wails/v3/pkg/application"
)

// DataEvent carries one chunk of PTY output. Data is base64 because chunks
// can split UTF-8 sequences mid-rune and JSON cannot carry invalid UTF-8;
// xterm.js decodes the raw bytes with its own stream-safe decoder. Seq is
// per-session and lets the frontend detect dropped or reordered chunks —
// either corrupts the escape-sequence stream and garbles the screen.
type DataEvent struct {
	ID   string `json:"id"`
	Seq  uint64 `json:"seq"`
	Data string `json:"data"`
}

type ExitEvent struct {
	ID string `json:"id"`
}

func init() {
	application.RegisterEvent[DataEvent]("pty:data")
	application.RegisterEvent[ExitEvent]("pty:exit")
}

type session struct {
	pty *os.File
	cmd *exec.Cmd
}

type Service struct {
	mu       sync.Mutex
	sessions map[string]*session
	nextID   int
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
	sess := &session{pty: f, cmd: cmd}
	s.sessions[id] = sess
	s.mu.Unlock()

	go s.readLoop(id, sess)
	return id, nil
}

func (s *Service) readLoop(id string, sess *session) {
	app := application.Get()
	buf := make([]byte, 32*1024)
	var seq uint64
	for {
		n, err := sess.pty.Read(buf)
		if n > 0 {
			seq++
			app.Event.Emit("pty:data", DataEvent{
				ID:   id,
				Seq:  seq,
				Data: base64.StdEncoding.EncodeToString(buf[:n]),
			})
		}
		if err != nil {
			break
		}
	}
	sess.cmd.Wait()
	sess.pty.Close()

	s.mu.Lock()
	delete(s.sessions, id)
	s.mu.Unlock()

	app.Event.Emit("pty:exit", ExitEvent{ID: id})
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

func (s *Service) Write(id, data string) error {
	sess, err := s.get(id)
	if err != nil {
		return err
	}
	_, err = sess.pty.WriteString(data)
	return err
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
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, sess := range s.sessions {
		sess.cmd.Process.Kill()
		sess.pty.Close()
	}
	return nil
}

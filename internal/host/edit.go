// The edit request: `rookctl edit` (the `re` shim) asking the app to take
// over its own pane with the editor, vim-style — blocking until :q.
//
// Flow: rookctl POSTs /sessions/{id}/edit {cwd, paths} → the host resolves
// paths against the CWD (the anchor — never the repo; the workspace is an
// annotation discovered upward), registers a pending edit, and pushes a
// msgEdit onto the session's frame socket. The app acks on receipt, takes
// over the pane, and reports the exit code on :q/:cq. rookctl long-polls
// GET /edits/{id} until done. An old app ignores the unknown frame kind
// (fail open), which rookctl surfaces as a no-ack timeout, not a hang.
package host

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// editState is one pending edit request's lifecycle. Guarded by Host.editMu.
type editState struct {
	session string
	acked   bool
	done    bool
	code    int
	// closed when done flips — the wait endpoint parks on it
	doneCh  chan struct{}
	created time.Time
}

// editPayload is the msgEdit frame body, JSON. Paths are pre-resolved:
// workspace-relative when the target lives under the session's workspace
// root (read-write), absolute otherwise (the file endpoint's external
// read-only tier). Cwd is workspace-relative ("" at the root or outside)
// and scopes the finder for a bare `re`.
type editPayload struct {
	ID    string   `json:"id"`
	Cwd   string   `json:"cwd"`
	Paths []string `json:"paths"`
}

// handleSessionEdit is POST /sessions/{id}/edit — create a pending edit and
// push it to the attached app. 409 when no app is attached: the takeover
// needs a pane on a screen somewhere.
func (h *Host) handleSessionEdit(w http.ResponseWriter, r *http.Request, s *session) {
	var req struct {
		Cwd   string   `json:"cwd"`
		Paths []string `json:"paths"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Cwd == "" {
		http.Error(w, "cwd required", http.StatusBadRequest)
		return
	}

	root := ""
	if ws := h.reg.get(s.info.Workspace); ws != nil {
		root = ws.Root
	}

	payload := editPayload{Cwd: relUnder(root, req.Cwd)}
	for _, p := range req.Paths {
		abs := p
		if !filepath.IsAbs(abs) {
			abs = filepath.Join(req.Cwd, abs)
		}
		abs = filepath.Clean(abs)
		st, err := os.Stat(abs)
		if err != nil {
			http.Error(w, "no such file: "+p, http.StatusNotFound)
			return
		}
		if st.IsDir() {
			http.Error(w, p+" is a directory (open a file, or bare `re` for the finder)", http.StatusBadRequest)
			return
		}
		if rel := relUnder(root, abs); rel != "" || abs == root {
			payload.Paths = append(payload.Paths, rel)
		} else {
			// outside the workspace: the file endpoint serves absolute
			// paths as external READ-ONLY — vim anywhere, saving later
			payload.Paths = append(payload.Paths, abs)
		}
	}

	idb := make([]byte, 8)
	rand.Read(idb)
	payload.ID = hex.EncodeToString(idb)

	body, _ := json.Marshal(payload)
	msg := append([]byte{msgEdit}, body...)

	s.mu.Lock()
	oob := s.oob
	s.mu.Unlock()
	if oob == nil {
		http.Error(w, "no app attached to this session — is the rook window open?", http.StatusConflict)
		return
	}

	h.editMu.Lock()
	if h.edits == nil {
		h.edits = map[string]*editState{}
	}
	// lazy sweep: an abandoned edit (rookctl ^C'd, app gone) shouldn't
	// accumulate forever
	for id, e := range h.edits {
		if time.Since(e.created) > 24*time.Hour {
			delete(h.edits, id)
		}
	}
	h.edits[payload.ID] = &editState{
		session: s.info.ID,
		doneCh:  make(chan struct{}),
		created: time.Now(),
	}
	h.editMu.Unlock()

	select {
	case oob <- msg:
	default:
		h.editMu.Lock()
		delete(h.edits, payload.ID)
		h.editMu.Unlock()
		http.Error(w, "app not keeping up — try again", http.StatusConflict)
		return
	}
	writeJSON(w, map[string]string{"editId": payload.ID})
}

// handleEdits routes /edits/{id} (GET, ?wait=seconds long-poll),
// /edits/{id}/ack (POST, from the app) and /edits/{id}/done (POST, from
// the app, body {code}).
func (h *Host) handleEdits(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/edits/")
	id, action, _ := strings.Cut(rest, "/")

	h.editMu.Lock()
	e := h.edits[id]
	h.editMu.Unlock()
	if e == nil {
		http.Error(w, "no such edit: "+id, http.StatusNotFound)
		return
	}

	switch {
	case action == "" && r.Method == http.MethodGet:
		if secs, _ := strconv.Atoi(r.URL.Query().Get("wait")); secs > 0 {
			h.editMu.Lock()
			done := e.done
			h.editMu.Unlock()
			if !done {
				select {
				case <-e.doneCh:
				case <-time.After(time.Duration(min(secs, 60)) * time.Second):
				case <-r.Context().Done():
					return
				}
			}
		}
		h.editMu.Lock()
		out := map[string]any{"acked": e.acked, "done": e.done, "code": e.code}
		// single waiter: the poll that observes done also retires the entry
		if e.done {
			delete(h.edits, id)
		}
		h.editMu.Unlock()
		writeJSON(w, out)
	case action == "ack" && r.Method == http.MethodPost:
		h.editMu.Lock()
		e.acked = true
		h.editMu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	case action == "done" && r.Method == http.MethodPost:
		var req struct {
			Code int `json:"code"`
		}
		json.NewDecoder(r.Body).Decode(&req)
		h.editMu.Lock()
		if !e.done {
			e.done, e.acked, e.code = true, true, req.Code
			close(e.doneCh)
		}
		h.editMu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	default:
		http.Error(w, "not found", http.StatusNotFound)
	}
}

// relUnder returns p relative to root when p sits strictly under it
// ("" otherwise — including p == root, which callers treat as the root
// itself via the abs==root check where it matters).
func relUnder(root, p string) string {
	if root == "" {
		return ""
	}
	rel, err := filepath.Rel(root, p)
	if err != nil || rel == "." || strings.HasPrefix(rel, "..") {
		return ""
	}
	return rel
}

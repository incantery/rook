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
// root, absolute otherwise (the file endpoints' external tier — read and
// write both). A path that doesn't exist yet rides through as a new file.
// Dir is the ABSOLUTE anchor — the shell's cwd, or the
// last directory argument — and scopes the editor's finder/grep/tree.
// Tree marks a directory asked for by name (`re .`): netrw parity, the
// app opens the file tree there.
type editPayload struct {
	ID    string   `json:"id"`
	Dir   string   `json:"dir"`
	Tree  bool     `json:"tree"`
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
		root = canonical(ws.Root)
	}

	payload := editPayload{Dir: canonical(filepath.Clean(req.Cwd))}
	for _, p := range req.Paths {
		abs := p
		if !filepath.IsAbs(abs) {
			abs = filepath.Join(req.Cwd, abs)
		}
		// canonical, so a shell whose $PWD spells the path through a
		// symlink (/tmp, /var on macOS) still lands INSIDE the workspace —
		// the alternative silently demotes a repo file to external
		// because "/var/…" isn't a prefix of "/private/var/…"
		abs = canonicalFile(filepath.Clean(abs))
		if st, err := os.Stat(abs); err == nil {
			if st.IsDir() {
				// vim's `nvim .`: a directory arg re-anchors the editor there
				// and asks for the tree — you land IN the editor, netrw-style
				payload.Dir = abs
				payload.Tree = true
				continue
			}
		} else if di, derr := os.Stat(filepath.Dir(abs)); derr != nil || !di.IsDir() {
			// `vim newfile.md` opens an empty named buffer that :w creates,
			// so a path that isn't there yet is fine — as long as its
			// DIRECTORY is. Under a missing dir it's a typo, and rook never
			// mkdir -p's behind you.
			http.Error(w, "no such file: "+p, http.StatusNotFound)
			return
		}
		if rel := relUnder(root, abs); rel != "" {
			payload.Paths = append(payload.Paths, rel)
		} else {
			// outside the workspace: the file endpoints serve absolute paths
			// on their external tier — read, save, stripe, all of it
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

// canonical resolves symlinks so path containment compares real locations
// (macOS: /tmp and /var are symlinks into /private). A path that doesn't
// resolve is returned as given — the Stat that follows will say why.
func canonical(p string) string {
	if p == "" {
		return p
	}
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return p
}

// canonicalFile is canonical for a FILE path: it resolves the directory and
// rejoins the base name, so a path that doesn't exist yet (a new file) still
// canonicalizes. Plain canonical would hand back the literal path there —
// and a literal /var/… compared against a resolved /private/var/… reads as
// "outside", which is how a file in the repo gets called external.
func canonicalFile(p string) string {
	if p == "" {
		return p
	}
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	dir, base := filepath.Split(p)
	if dir == "" {
		return p
	}
	if r, err := filepath.EvalSymlinks(filepath.Clean(dir)); err == nil {
		return filepath.Join(r, base)
	}
	return p
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

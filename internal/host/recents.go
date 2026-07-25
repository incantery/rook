// Recently-opened files, per workspace — what the editor's start screen
// leads with, and the first thing about the editor that outlives a restart.
//
// The frontend already keeps `app.buffers` (the open set, most-recent
// first), but that is session state: it empties on reload, which is exactly
// when a greeter is asked to be useful. So the durable list lives here, in
// the host, where rookctl and the agent can read it too — the same reason
// every other list in rook does.
//
// What counts as "recent" is deliberately narrow: a document a pane actually
// OPENED. Recording every /file read would fold in Finder previews and
// gutter refetches, which would bury the five paths you meant.
package host

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"
)

// recentsCap bounds what a workspace remembers. The screen shows a handful;
// the surplus is there so a burst of opens doesn't evict the file you were
// actually living in.
const recentsCap = 50

// Recent is one remembered document. Path is workspace-relative for files
// under the root and absolute for external ones — the same two-tier spelling
// the file endpoints already serve, so a recent round-trips straight back
// into readFile without translation.
type Recent struct {
	Path     string    `json:"path"`
	OpenedAt time.Time `json:"openedAt"`
}

// touchRecent promotes a path to most-recent, inserting it if new. The
// primary key is (workspace, path), so re-opening a file moves it rather
// than accumulating duplicates.
func (r *registry) touchRecent(ws, path string) error {
	if r.db == nil || ws == "" || path == "" {
		return nil // no store, or nothing to remember — never an error
	}
	now := time.Now().Format(time.RFC3339Nano)
	_, err := r.db.Exec(
		`INSERT INTO recents (workspace, path, opened_at) VALUES (?, ?, ?)
		 ON CONFLICT(workspace, path) DO UPDATE SET opened_at = excluded.opened_at`,
		ws, path, now)
	if err != nil {
		return err
	}
	// Trim past the cap here rather than on read: the list is written far
	// less often than it is read, and an unbounded table would otherwise
	// grow for the lifetime of the workspace.
	_, err = r.db.Exec(
		`DELETE FROM recents WHERE workspace = ? AND path NOT IN (
		     SELECT path FROM recents WHERE workspace = ?
		     ORDER BY opened_at DESC LIMIT ?)`,
		ws, ws, recentsCap)
	return err
}

// recentList returns a workspace's remembered documents, newest first.
// Fails open: no store, or a broken query, is an empty list — a greeter with
// no recents is a greeter, and a broken one would be a wall.
func (r *registry) recentList(ws string, limit int) []Recent {
	out := []Recent{}
	if r.db == nil || ws == "" {
		return out
	}
	if limit <= 0 || limit > recentsCap {
		limit = recentsCap
	}
	rows, err := r.db.Query(
		`SELECT path, opened_at FROM recents WHERE workspace = ?
		 ORDER BY opened_at DESC LIMIT ?`, ws, limit)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var path, at string
		if rows.Scan(&path, &at) != nil {
			continue
		}
		t, _ := time.Parse(time.RFC3339Nano, at)
		out = append(out, Recent{Path: path, OpenedAt: t})
	}
	return out
}

// forgetRecent drops one path. The start screen's own delete verb, and what
// keeps a renamed or deleted file from sitting at the top of the list
// forever — the host never stats these, so pruning is a user act.
func (r *registry) forgetRecent(ws, path string) error {
	if r.db == nil || ws == "" || path == "" {
		return nil
	}
	_, err := r.db.Exec(`DELETE FROM recents WHERE workspace = ? AND path = ?`, ws, path)
	return err
}

// GET  /workspaces/{name}/recents[?limit=N]  → [{path, openedAt}]
// POST /workspaces/{name}/recents  {path}    → record an open
// POST /workspaces/{name}/recents  {path, forget:true} → drop one
//
// Unlike the file endpoints this does NOT require a root: a workspace with
// no root can still have had external files opened in it, and refusing here
// would make the greeter's list vanish exactly when the file tree already
// has nothing to offer.
func (h *Host) handleWorkspaceRecents(w http.ResponseWriter, r *http.Request, name string) {
	if h.reg.get(name) == nil {
		http.Error(w, "no such workspace: "+name, http.StatusNotFound)
		return
	}
	switch r.Method {
	case http.MethodGet:
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		writeJSON(w, map[string]any{"recents": h.reg.recentList(name, limit)})
	case http.MethodPost:
		var req struct {
			Path   string `json:"path"`
			Forget bool   `json:"forget"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Path == "" {
			http.Error(w, "path required", http.StatusBadRequest)
			return
		}
		var err error
		if req.Forget {
			err = h.reg.forgetRecent(name, req.Path)
		} else {
			err = h.reg.touchRecent(name, req.Path)
		}
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, map[string]any{"ok": true})
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

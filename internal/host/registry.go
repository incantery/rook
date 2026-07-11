package host

import (
	"database/sql"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// WorkspaceInfo is a persistent workspace: it exists independent of live
// sessions (VS Code-style) and survives host restarts. Scratch workspaces
// are the exception — ephemeral by design, removed when their last session
// dies.
type WorkspaceInfo struct {
	Name     string    `json:"name"`
	Root     string    `json:"root,omitempty"`
	Scratch  bool      `json:"scratch,omitempty"`
	Created  time.Time `json:"created"`
	LastUsed time.Time `json:"lastUsed"`
}

// registry is backed by SQLite (~/.local/share/rook/rook.db). The host is
// the ONLY writer — the app reads through the host API — which keeps SQLite
// happy and keeps the door open for a hosted backend later. mattn/go-sqlite3
// specifically because it can load extensions (sqlite-vec is on the roadmap).
type registry struct {
	db *sql.DB
}

// DataDir is durable app data (the database), as opposed to StateDir which
// holds runtime state (host.json, logs).
func DataDir() string {
	base := os.Getenv("XDG_DATA_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		base = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(base, "rook")
}

const schema = `
CREATE TABLE IF NOT EXISTS workspaces (
	name       TEXT PRIMARY KEY,
	root       TEXT NOT NULL DEFAULT '',
	scratch    INTEGER NOT NULL DEFAULT 0,
	created_at TEXT NOT NULL,
	last_used  TEXT NOT NULL
);
`

func loadRegistry() *registry {
	dir := DataDir()
	if dir == "" {
		log.Println("registry: no data dir; workspaces will not persist")
		return &registry{}
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		log.Printf("registry: %v; workspaces will not persist", err)
		return &registry{}
	}
	db, err := sql.Open("sqlite3", "file:"+filepath.Join(dir, "rook.db")+"?_busy_timeout=5000&_journal_mode=WAL")
	if err == nil {
		_, err = db.Exec(schema)
	}
	if err != nil {
		log.Printf("registry: open db: %v; workspaces will not persist", err)
		return &registry{}
	}
	r := &registry{db: db}
	r.migrateJSON()
	return r
}

// migrateJSON imports the pre-SQLite workspaces.json once, then renames it
// out of the way.
func (r *registry) migrateJSON() {
	path := filepath.Join(StateDir(), "workspaces.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var list []WorkspaceInfo
	if json.Unmarshal(data, &list) != nil {
		return
	}
	for _, w := range list {
		r.db.Exec(
			`INSERT OR IGNORE INTO workspaces (name, root, scratch, created_at, last_used) VALUES (?, ?, ?, ?, ?)`,
			w.Name, w.Root, w.Scratch, w.Created.Format(time.RFC3339Nano), w.LastUsed.Format(time.RFC3339Nano),
		)
	}
	os.Rename(path, path+".migrated")
	log.Printf("registry: migrated %d workspaces from json", len(list))
}

func scanWorkspace(row interface{ Scan(...any) error }) (*WorkspaceInfo, error) {
	var w WorkspaceInfo
	var created, used string
	if err := row.Scan(&w.Name, &w.Root, &w.Scratch, &created, &used); err != nil {
		return nil, err
	}
	w.Created, _ = time.Parse(time.RFC3339Nano, created)
	w.LastUsed, _ = time.Parse(time.RFC3339Nano, used)
	return &w, nil
}

// upsert registers a workspace (or refreshes LastUsed on an existing one,
// updating the root only when a non-empty one is given) and returns it.
func (r *registry) upsert(name, root string, scratch bool) *WorkspaceInfo {
	now := time.Now()
	if r.db != nil {
		_, err := r.db.Exec(
			`INSERT INTO workspaces (name, root, scratch, created_at, last_used) VALUES (?, ?, ?, ?, ?)
			 ON CONFLICT(name) DO UPDATE SET
			   last_used = excluded.last_used,
			   root = CASE WHEN excluded.root != '' THEN excluded.root ELSE workspaces.root END`,
			name, root, scratch, now.Format(time.RFC3339Nano), now.Format(time.RFC3339Nano),
		)
		if err != nil {
			log.Printf("registry: upsert %q: %v", name, err)
		}
		if w := r.get(name); w != nil {
			return w
		}
	}
	return &WorkspaceInfo{Name: name, Root: root, Scratch: scratch, Created: now, LastUsed: now}
}

func (r *registry) get(name string) *WorkspaceInfo {
	if r.db == nil {
		return nil
	}
	w, err := scanWorkspace(r.db.QueryRow(
		`SELECT name, root, scratch, created_at, last_used FROM workspaces WHERE name = ?`, name))
	if err != nil {
		return nil
	}
	return w
}

func (r *registry) remove(name string) {
	if r.db == nil {
		return
	}
	if _, err := r.db.Exec(`DELETE FROM workspaces WHERE name = ?`, name); err != nil {
		log.Printf("registry: remove %q: %v", name, err)
	}
}

func (r *registry) list() []*WorkspaceInfo {
	if r.db == nil {
		return nil
	}
	rows, err := r.db.Query(
		`SELECT name, root, scratch, created_at, last_used FROM workspaces ORDER BY last_used DESC`)
	if err != nil {
		log.Printf("registry: list: %v", err)
		return nil
	}
	defer rows.Close()
	var out []*WorkspaceInfo
	for rows.Next() {
		if w, err := scanWorkspace(rows); err == nil {
			out = append(out, w)
		}
	}
	return out
}

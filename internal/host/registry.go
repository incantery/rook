package host

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
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
	// WorktreeOf names the source workspace this one was carved from
	// (git worktree under DataDir); Branch is its branch, rook/<name>
	// unless the source workspace configures a branch-prefix.
	// Deleting a worktree workspace removes the checkout (guarded by
	// worktreeRisk) — the branch always survives.
	WorktreeOf string `json:"worktreeOf,omitempty"`
	Branch     string `json:"branch,omitempty"`
	// IssueRef is the tracker issue this workspace was spawned for
	// (▶ work / rookctl work); nil for workspaces created any other way.
	IssueRef *IssueRef `json:"issueRef,omitempty"`
}

// IssueRef identifies a tracker issue: provenance for workspaces spawned
// off the queue — the key downstream hooks (issue badges, spend
// attribution, close-the-loop) hang off.
type IssueRef struct {
	Tracker string `json:"tracker"` // "github" | "jira"
	Key     string `json:"key"`     // "#123" | "PROJ-42"
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
CREATE TABLE IF NOT EXISTS decisions (
	id            INTEGER PRIMARY KEY,
	agent_session TEXT NOT NULL,
	ask_seq       INTEGER NOT NULL,
	workspace     TEXT DEFAULT '',
	rook_session  TEXT DEFAULT '',
	cwd           TEXT DEFAULT '',
	ask           TEXT NOT NULL,
	action        TEXT NOT NULL, -- draft | escalate
	draft         TEXT,
	confidence    REAL,
	model         TEXT,
	input_tokens  INT,
	output_tokens INT,
	cached_tokens INT,
	cost_usd      REAL,
	verdict       TEXT DEFAULT 'open', -- open|approved|edited|rejected|manual|stale|auto
	final_text    TEXT,
	reason        TEXT, -- nano's own why, verbatim (drafted because…/escalated because…)
	created_at    TEXT NOT NULL,
	decided_at    TEXT,
	UNIQUE(agent_session, ask_seq)
);
CREATE TABLE IF NOT EXISTS costs (
	day TEXT PRIMARY KEY, -- local date, 2006-01-02
	usd REAL NOT NULL DEFAULT 0 -- claude raw-inference $, host-observed
);
CREATE TABLE IF NOT EXISTS stages (
	id           INTEGER PRIMARY KEY,
	workspace    TEXT NOT NULL,
	idx          INTEGER NOT NULL,
	name         TEXT NOT NULL,                     -- the slash command
	status       TEXT NOT NULL DEFAULT 'pending',   -- pending|running|done|error
	rook_session TEXT NOT NULL DEFAULT '',          -- attribution key: the stage's window
	detail       TEXT NOT NULL DEFAULT '',
	created_at   TEXT NOT NULL,
	started_at   TEXT,
	finished_at  TEXT,
	UNIQUE(workspace, idx)
);
CREATE TABLE IF NOT EXISTS threads (
	id            INTEGER PRIMARY KEY,
	workspace     TEXT NOT NULL,
	path          TEXT NOT NULL,
	start_line    INTEGER NOT NULL,
	end_line      INTEGER NOT NULL,
	side          TEXT NOT NULL DEFAULT 'modified', -- modified|original (diff side)
	blob_sha      TEXT NOT NULL,              -- content identity at anchor time
	commit_sha    TEXT NOT NULL DEFAULT '',   -- HEAD at anchor time, informational
	anchor_text   TEXT NOT NULL,              -- the anchored lines verbatim
	state         TEXT NOT NULL DEFAULT 'pending', -- pending|open|resolved
	resolved_by   TEXT NOT NULL DEFAULT '',   -- ''|user|agent
	agent_reopens INTEGER NOT NULL DEFAULT 0, -- user reopened an agent-resolve (verdict datum)
	created_at    TEXT NOT NULL,
	updated_at    TEXT NOT NULL,
	submitted_at  TEXT
);
CREATE TABLE IF NOT EXISTS thread_comments (
	id            INTEGER PRIMARY KEY,
	thread_id     INTEGER NOT NULL,
	author        TEXT NOT NULL,              -- user|agent (declared, not authenticated)
	agent_session TEXT NOT NULL DEFAULT '',
	body          TEXT NOT NULL,
	created_at    TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS anchor_blobs (
	sha     TEXT PRIMARY KEY,                 -- git blob hash of content
	content BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS samples (
	ts     TEXT NOT NULL,
	metric TEXT NOT NULL,            -- rook_process_rss_bytes, …
	labels TEXT NOT NULL DEFAULT '', -- JSON object, keys sorted by Marshal
	value  REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS samples_ts ON samples(ts);
`

// migrations are columns added after a table shipped — CREATE IF NOT EXISTS
// won't touch an existing table, so each ALTER runs and "duplicate column"
// is the expected steady-state error.
var migrations = []string{
	`ALTER TABLE decisions ADD COLUMN reason TEXT`,
	`ALTER TABLE workspaces ADD COLUMN worktree_of TEXT NOT NULL DEFAULT ''`,
	`ALTER TABLE workspaces ADD COLUMN branch TEXT NOT NULL DEFAULT ''`,
	`ALTER TABLE workspaces ADD COLUMN issue_tracker TEXT NOT NULL DEFAULT ''`,
	`ALTER TABLE workspaces ADD COLUMN issue_key TEXT NOT NULL DEFAULT ''`,
}

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
	for _, m := range migrations {
		if _, err := db.Exec(m); err != nil && !strings.Contains(err.Error(), "duplicate column") {
			log.Printf("registry: migration %q: %v", m, err)
		}
	}
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
		_, _ = r.db.Exec(
			`INSERT OR IGNORE INTO workspaces (name, root, scratch, created_at, last_used) VALUES (?, ?, ?, ?, ?)`,
			w.Name, w.Root, w.Scratch, w.Created.Format(time.RFC3339Nano), w.LastUsed.Format(time.RFC3339Nano),
		)
	}
	os.Rename(path, path+".migrated")
	log.Printf("registry: migrated %d workspaces from json", len(list))
}

const workspaceCols = `name, root, scratch, worktree_of, branch, issue_tracker, issue_key, created_at, last_used`

func scanWorkspace(row interface{ Scan(...any) error }) (*WorkspaceInfo, error) {
	var w WorkspaceInfo
	var tracker, key, created, used string
	if err := row.Scan(&w.Name, &w.Root, &w.Scratch, &w.WorktreeOf, &w.Branch, &tracker, &key, &created, &used); err != nil {
		return nil, err
	}
	if key != "" {
		w.IssueRef = &IssueRef{Tracker: tracker, Key: key}
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
		`SELECT `+workspaceCols+` FROM workspaces WHERE name = ?`, name))
	if err != nil {
		return nil
	}
	return w
}

// createWorktreeWS registers a worktree workspace. Strict insert, no upsert
// semantics — a name collision is the caller's error, not a refresh.
func (r *registry) createWorktreeWS(name, root, source, branch string, issue *IssueRef) (*WorkspaceInfo, error) {
	if r.db == nil {
		return nil, fmt.Errorf("no registry db; workspaces cannot persist")
	}
	tracker, key := "", ""
	if issue != nil {
		tracker, key = issue.Tracker, issue.Key
	}
	now := time.Now().Format(time.RFC3339Nano)
	if _, err := r.db.Exec(
		`INSERT INTO workspaces (name, root, scratch, worktree_of, branch, issue_tracker, issue_key, created_at, last_used)
		 VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?)`,
		name, root, source, branch, tracker, key, now, now); err != nil {
		return nil, err
	}
	return r.get(name), nil
}

func (r *registry) remove(name string) {
	if r.db == nil {
		return
	}
	if _, err := r.db.Exec(`DELETE FROM workspaces WHERE name = ?`, name); err != nil {
		log.Printf("registry: remove %q: %v", name, err)
	}
}

// addDailyCost folds a raw-inference cost delta into today's row — the
// durable side of the usage monitor's burn sampling. What the subscription
// absorbs, priced as if it were API tokens.
func (r *registry) addDailyCost(day string, usd float64) {
	if r.db == nil || usd <= 0 {
		return
	}
	if _, err := r.db.Exec(
		`INSERT INTO costs (day, usd) VALUES (?, ?)
		 ON CONFLICT(day) DO UPDATE SET usd = usd + excluded.usd`, day, usd); err != nil {
		log.Printf("registry: cost: %v", err)
	}
}

// sampleRetention bounds the monitor's series. Everything else in this file
// grows forever on purpose — the ledger is the product — but samples are
// diagnostics, and a 30s cadence with no sweeper is how you get a multi-GB
// database by accident.
const sampleRetention = 7 * 24 * time.Hour

// addSamples writes one gather pass in a single transaction: ~15 rows every
// 30s, so the tx is what keeps it one fsync instead of fifteen.
func (r *registry) addSamples(at time.Time, ss []sample) {
	if r.db == nil || len(ss) == 0 {
		return
	}
	tx, err := r.db.Begin()
	if err != nil {
		log.Printf("registry: samples: %v", err)
		return
	}
	defer tx.Rollback()
	stmt, err := tx.Prepare(`INSERT INTO samples (ts, metric, labels, value) VALUES (?, ?, ?, ?)`)
	if err != nil {
		log.Printf("registry: samples: %v", err)
		return
	}
	defer stmt.Close()
	ts := at.Format(time.RFC3339Nano)
	for _, s := range ss {
		if _, err := stmt.Exec(ts, s.Metric, s.labelJSON(), s.Value); err != nil {
			log.Printf("registry: samples: %v", err)
			return
		}
	}
	if err := tx.Commit(); err != nil {
		log.Printf("registry: samples: %v", err)
	}
}

func (r *registry) pruneSamples(before time.Time) {
	if r.db == nil {
		return
	}
	if _, err := r.db.Exec(`DELETE FROM samples WHERE ts < ?`, before.Format(time.RFC3339Nano)); err != nil {
		log.Printf("registry: prune samples: %v", err)
	}
}

// samplesSince reads the stored series back, oldest first — the detail
// panel's payload, and the shape a Prometheus remote-write would iterate.
func (r *registry) samplesSince(t time.Time) []storedSample {
	out := []storedSample{}
	if r.db == nil {
		return out
	}
	rows, err := r.db.Query(
		`SELECT ts, metric, labels, value FROM samples WHERE ts >= ? ORDER BY ts`,
		t.Format(time.RFC3339Nano))
	if err != nil {
		log.Printf("registry: samplesSince: %v", err)
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var ts, metric, labels string
		var v float64
		if err := rows.Scan(&ts, &metric, &labels, &v); err != nil {
			continue
		}
		at, err := time.Parse(time.RFC3339Nano, ts)
		if err != nil {
			continue
		}
		s := storedSample{At: at, Metric: metric, Value: v}
		if labels != "" {
			json.Unmarshal([]byte(labels), &s.Labels)
		}
		out = append(out, s)
	}
	return out
}

func (r *registry) costSince(day string) float64 {
	if r.db == nil {
		return 0
	}
	var usd float64
	if err := r.db.QueryRow(
		`SELECT COALESCE(SUM(usd),0) FROM costs WHERE day >= ?`, day).Scan(&usd); err != nil {
		log.Printf("registry: cost sum: %v", err)
	}
	return usd
}

func (r *registry) list() []*WorkspaceInfo {
	if r.db == nil {
		return nil
	}
	rows, err := r.db.Query(
		`SELECT ` + workspaceCols + ` FROM workspaces ORDER BY last_used DESC`)
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

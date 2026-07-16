package transcript

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/fsnotify/fsnotify"
)

const (
	// DefaultMaxAge bounds which sessions are followed. On a real machine
	// the tree holds ~115 session files and 6-8 are touched in an hour —
	// the live working set is tiny, and replaying the rest on every start
	// would be pure cost. A file that goes quiet and later resumes gets
	// picked back up: the sweep re-checks mtime, it does not remember a
	// verdict.
	DefaultMaxAge = time.Hour

	// DefaultPoll is the fallback sweep. fsnotify is the low-latency path;
	// this exists because macOS coalesces events under load and a dropped
	// wake must cost a beat, not a session.
	DefaultPoll = 2 * time.Second
)

// DefaultRoot is ~/.claude/projects, the tree Claude Code writes session
// transcripts into. Rook does not own it and neither does agentmon — it is
// Claude Code's, and both read it independently (docs/agent.md, amendment
// 2026-07-15).
func DefaultRoot() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".claude", "projects"), nil
}

// FindSession locates a session's transcript by its id.
//
// The tree is <root>/<project-slug>/<session-uuid>.jsonl, and the slug is a
// lossy transform of the cwd — both '/' and '.' collapse to '-', so
// /a/b/github.com/x and /a/b/github-com/x produce the same directory name.
// The path is therefore searched for rather than computed: scanning a few
// dozen project directories costs nothing and cannot be wrong.
//
// Subagent transcripts live deeper and are never matched.
func FindSession(root, sessionID string) (string, error) {
	if root == "" {
		r, err := DefaultRoot()
		if err != nil {
			return "", err
		}
		root = r
	}
	if sessionID == "" || strings.ContainsAny(sessionID, "/\\.") {
		// Session ids are uuids. Anything with a separator is a caller
		// trying to escape the tree, not a session.
		return "", fmt.Errorf("transcript: invalid session id %q", sessionID)
	}
	projects, err := os.ReadDir(root)
	if err != nil {
		return "", err
	}
	name := sessionID + ".jsonl"
	for _, p := range projects {
		if !p.IsDir() {
			continue
		}
		path := filepath.Join(root, p.Name(), name)
		if st, err := os.Stat(path); err == nil && !st.IsDir() {
			return path, nil
		}
	}
	return "", fmt.Errorf("transcript: no session %s under %s", sessionID, root)
}

// ReadSession returns a window of a session's records in file order, ending
// at before (exclusive) or at EOF when before is 0. More reports whether
// older records exist ahead of the window — i.e. whether scrollback can page
// further back.
//
// Windowing is not optional: transcripts here average 1.6MB and reach 58MB,
// so "just send the file" is a page nobody can render. The whole file is
// still read to find line boundaries, which at the average is nothing and at
// the outlier is one 58MB sequential read; if that ever bites, the fix is an
// offset index, not a smaller window.
func ReadSession(path string, limit int, before int64) (lines []Line, more bool, err error) {
	if limit <= 0 {
		limit = 200
	}
	t := NewTail(path)
	all, err := t.Read()
	if err != nil {
		return nil, false, err
	}
	if before > 0 {
		cut := len(all)
		for i, ln := range all {
			if ln.Offset >= before {
				cut = i
				break
			}
		}
		all = all[:cut]
	}
	if len(all) > limit {
		return all[len(all)-limit:], true, nil
	}
	return all, false, nil
}

// Watcher follows every live session in the transcript tree and emits their
// records.
//
// Layout is <root>/<project-slug>/<session-uuid>.jsonl, and only that depth
// is a session. Subagent transcripts live deeper
// (<slug>/<uuid>/subagents/agent-*.jsonl) and are 91% of the files in the
// tree; rook discards subagent traffic anyway, so they are never globbed and
// — because fsnotify watches are not recursive — never even wake us.
type Watcher struct {
	// Root defaults to DefaultRoot().
	Root string
	// MaxAge defaults to DefaultMaxAge; zero means DefaultMaxAge, not "no
	// limit".
	MaxAge time.Duration
	// Poll defaults to DefaultPoll.
	Poll time.Duration
}

// Run follows the tree until ctx is cancelled, sending every record it reads
// to out. It closes nothing it did not open, and never closes out.
//
// Sends are subject to ctx: a consumer that stops reading stalls the
// watcher rather than growing a queue behind it.
func (w *Watcher) Run(ctx context.Context, out chan<- Line) error {
	root := w.Root
	if root == "" {
		r, err := DefaultRoot()
		if err != nil {
			return err
		}
		root = r
	}
	maxAge := w.MaxAge
	if maxAge <= 0 {
		maxAge = DefaultMaxAge
	}
	poll := w.Poll
	if poll <= 0 {
		poll = DefaultPoll
	}

	fsw, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	defer fsw.Close()

	tails := map[string]*Tail{}  // by path
	watched := map[string]bool{} // dirs under watch

	// emit drains one tail. A read error means the file went away
	// mid-flight; drop the tail and let the next sweep decide.
	emit := func(path string, t *Tail) bool {
		lines, err := t.Read()
		if err != nil {
			delete(tails, path)
			return true
		}
		for _, ln := range lines {
			select {
			case out <- ln:
			case <-ctx.Done():
				return false
			}
		}
		return true
	}

	watch := func(dir string) {
		if watched[dir] {
			return
		}
		if err := fsw.Add(dir); err != nil {
			return // raced with a delete, or not a dir; the sweep retries
		}
		watched[dir] = true
	}

	// sweep reconciles the tree: new project dirs get watched, sessions
	// that have gone quiet past maxAge are dropped, freshly active ones are
	// picked up, and every live tail is drained.
	sweep := func() bool {
		watch(root)
		entries, err := os.ReadDir(root)
		if err != nil {
			return true
		}
		cutoff := time.Now().Add(-maxAge)
		live := map[string]bool{}
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			dir := filepath.Join(root, e.Name())
			watch(dir)

			files, err := os.ReadDir(dir)
			if err != nil {
				continue
			}
			for _, f := range files {
				if f.IsDir() || !strings.HasSuffix(f.Name(), ".jsonl") {
					continue
				}
				info, err := f.Info()
				if err != nil || info.ModTime().Before(cutoff) {
					continue
				}
				path := filepath.Join(dir, f.Name())
				live[path] = true
				if tails[path] == nil {
					tails[path] = NewTail(path)
				}
			}
		}
		for path := range tails {
			if !live[path] {
				delete(tails, path) // gone quiet; re-tailed from zero if it wakes
			}
		}
		for path, t := range tails {
			if !emit(path, t) {
				return false
			}
		}
		return true
	}

	if !sweep() {
		return ctx.Err()
	}

	ticker := time.NewTicker(poll)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()

		case <-ticker.C:
			if !sweep() {
				return ctx.Err()
			}

		case ev, ok := <-fsw.Events:
			if !ok {
				return nil
			}
			// The hot path: an append to a session we already follow.
			if t := tails[ev.Name]; t != nil && ev.Op&fsnotify.Write != 0 {
				if !emit(ev.Name, t) {
					return ctx.Err()
				}
				continue
			}
			// Anything structural — a new project dir, a new session, a
			// removal — is rare enough to just reconcile.
			if !sweep() {
				return ctx.Err()
			}

		case err, ok := <-fsw.Errors:
			if !ok {
				return nil
			}
			// Never fatal: the ticker is still sweeping, so a watcher error
			// costs latency, not sight.
			log.Printf("transcript: watch: %v", err)
		}
	}
}

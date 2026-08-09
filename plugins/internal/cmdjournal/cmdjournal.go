// Package cmdjournal is the bridge's memory of what it has already
// typed: one jsonl file recording, per delivery, whether the effect
// happened and how many times landing it has failed.
//
// It exists because at-most-once at the keyboard is a promise about
// CRASHES, not just about retries. The cloud's rails are at-least-once
// by design — a lost ack means redelivery, which is correct — so the
// only thing standing between a redelivered answer and a second round
// of typing into someone's editor is a record of the first. Held in
// memory, that record dies with the process and the guarantee dies with
// it: relaunch after a crash and the same answer types again, the same
// spawn opens a second pane.
//
// The file is the interface, the same as digestlog beside it: a line is
// a full snapshot of one key's state, the last line for a key wins, and
// a torn tail is skipped rather than fatal. ALL rails share one log —
// answers keyed by ask id, commands by "cmd:<id>" — because they make
// the same promise at the same keyboard, and two bookkeepers would be
// two chances to break it.
//
// Since the link plugin, "all rails" means two PROCESSES, not two
// goroutines: the cloud bridge and the link server both hold this file
// open at once, and a command can arrive over both rails. So the file
// is guarded by an exclusive flock on a sidecar (the sidecar because
// compaction renames the journal itself, and a lock must outlive the
// rename), held around every append and compaction — and every read
// answers from the file's CURRENT truth: a cheap stat under the lock,
// a re-read when it changed. A marks delivered, B sees delivered, no
// reopen required.
//
// A journal that cannot be opened degrades to memory rather than
// refusing to run: that is exactly today's behavior, and a bridge that
// dies over a read-only state directory would be worse than one that
// forgets across restarts.
package cmdjournal

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

// Entry is one delivery's state. Written on every change, read back as
// "the last line for this key" — so a single line is enough to know
// both whether the effect landed and how close the retries are to
// giving up.
type Entry struct {
	Key string `json:"key"`
	// Delivered is the whole point: the effect HAPPENED. It is written
	// before the ack, so a crash in the gap costs a redundant ack and
	// never a redundant effect.
	Delivered bool `json:"delivered,omitempty"`
	// Attempts counts failures to land, not tries. It persists so that
	// an answer which can never land — a pane that is gone for good —
	// stays bounded across restarts instead of getting a fresh budget
	// every relaunch and pending forever.
	Attempts int       `json:"attempts,omitempty"`
	At       time.Time `json:"at,omitzero"`
}

// DefaultPath is where the journal lives: rook's state home, beside the
// digest log. XDG_STATE_HOME is the override the rest of the app
// honors; an empty return means "no home, nowhere to write" and the
// caller degrades to memory.
func DefaultPath() string {
	if x := os.Getenv("XDG_STATE_HOME"); x != "" {
		return filepath.Join(x, "rook", "cloud-deliveries.jsonl")
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, ".local", "state", "rook", "cloud-deliveries.jsonl")
}

// maxBytes triggers compaction. Lines here are tiny — an id, two small
// fields, a timestamp — so this is generous by weight and still holds
// tens of thousands of deliveries.
const maxBytes = 1 << 20

// Log is a rail's handle: the live state in memory, appended through
// to disk. The mutex serializes this process's goroutines; the flock
// serializes processes.
type Log struct {
	mu     sync.Mutex
	path   string   // "" = memory only, which is a working degraded mode
	lock   *os.File // the flock sidecar; nil when memory-only
	window time.Duration
	state  map[string]Entry
	// forgot remembers deliberate Forgets so a reload from the shared
	// file (whose lines outlive a Forget until compaction) does not
	// resurrect them in this process.
	forgot map[string]bool
	now    func() time.Time

	// The file's shape at last read/write, for reload-if-changed: a
	// matching stat under the lock means our memory IS the file.
	lastSize  int64
	lastMtime time.Time
}

// Open replays the journal and prepares it for appending. A file grown
// past maxBytes is compacted to the live window first. Every failure
// here — no path, unmakeable directory, unopenable lock — yields a
// working memory-only Log and a non-nil error, so a caller may report
// the degradation on its panel without having to handle a nil log.
func Open(path string, window time.Duration, now time.Time) (*Log, error) {
	l := &Log{path: path, window: window, state: map[string]Entry{}, forgot: map[string]bool{}, now: time.Now}
	if path == "" {
		return l, nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		l.path = ""
		return l, err
	}
	// The sidecar carries the flock. Locking the journal itself would
	// not survive compaction's rename — the fd would keep guarding the
	// unlinked old file while another process appends to the new one.
	lf, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		l.path = ""
		return l, err
	}
	l.lock = lf

	l.flock()
	for _, e := range load(path, window, now) {
		l.state[e.Key] = e
	}
	l.restatLocked()
	size := l.lastSize
	l.funlock()

	if size > maxBytes {
		l.compact()
	}
	return l, nil
}

// flock takes the cross-process lock; funlock releases it. Blocking
// and exclusive: appends are rare and tiny, and a reader that answers
// from a half-merged view is exactly the bug this exists to prevent.
// No-ops in memory-only mode.
func (l *Log) flock() {
	if l.lock != nil {
		_ = syscall.Flock(int(l.lock.Fd()), syscall.LOCK_EX)
	}
}

func (l *Log) funlock() {
	if l.lock != nil {
		_ = syscall.Flock(int(l.lock.Fd()), syscall.LOCK_UN)
	}
}

// restatLocked records the file's current shape. Call with the flock
// held, after reading or writing.
func (l *Log) restatLocked() {
	if fi, err := os.Stat(l.path); err == nil {
		l.lastSize, l.lastMtime = fi.Size(), fi.ModTime()
	} else {
		l.lastSize, l.lastMtime = -1, time.Time{}
	}
}

// reloadLocked re-reads the file if it changed since we last looked —
// the other process's writes, folded in. Call with the flock held.
//
// The merge direction matters: the file is the shared truth, but this
// process's own memory may hold a guarantee the file missed (an append
// that failed on a full disk still protects for as long as we live).
// So a Delivered we remember is never forgotten, and attempts take the
// larger count — both errors fall on the side of not typing twice.
func (l *Log) reloadLocked() {
	if l.path == "" {
		return
	}
	fi, err := os.Stat(l.path)
	if err == nil && fi.Size() == l.lastSize && fi.ModTime().Equal(l.lastMtime) {
		return
	}
	fresh := map[string]Entry{}
	for _, e := range load(l.path, l.window, l.now()) {
		if l.forgot[e.Key] {
			continue
		}
		fresh[e.Key] = e
	}
	for k, mine := range l.state {
		e, ok := fresh[k]
		if !ok {
			fresh[k] = mine
			continue
		}
		if mine.Delivered && !e.Delivered {
			e.Delivered = true
		}
		if mine.Attempts > e.Attempts {
			e.Attempts = mine.Attempts
		}
		fresh[k] = e
	}
	l.state = fresh
	l.restatLocked()
}

// Delivered reports whether this key's effect has already happened —
// by ANY process on this journal, not just this one. The answer is
// read against the file's current truth under the lock, so the other
// rail's mark made a moment ago counts.
func (l *Log) Delivered(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.flock()
	l.reloadLocked()
	l.funlock()
	return l.state[key].Delivered
}

// MarkDelivered records the effect. Call it BEFORE the ack: a lost ack
// must re-ack, never re-type.
func (l *Log) MarkDelivered(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.flock()
	l.reloadLocked()
	delete(l.forgot, key)
	e := l.state[key]
	e.Key, e.Delivered, e.At = key, true, l.now()
	l.state[key] = e
	l.appendLocked(e)
	l.funlock()
}

// Failed counts one failure to land and returns the running total, so
// the caller's bound reads as one expression rather than a load, an
// increment and a compare that could drift apart. The total is shared
// across processes: both rails burning tries at the same dead pane
// spend one budget, not two.
func (l *Log) Failed(key string) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.flock()
	l.reloadLocked()
	e := l.state[key]
	e.Key, e.Attempts, e.At = key, e.Attempts+1, l.now()
	l.state[key] = e
	l.appendLocked(e)
	l.funlock()
	return e.Attempts
}

// Forget drops a key from this process's memory and writes nothing.
// Used when a delivery is abandoned for good and the record has served
// its purpose; the window sweeps the line itself on the next
// compaction. Local by design — the other rail keeps its own counsel.
func (l *Log) Forget(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.flock()
	delete(l.state, key)
	l.forgot[key] = true
	l.funlock()
}

// appendLocked writes one snapshot line. Call with the flock held. A
// write that fails costs durability for that entry and nothing else —
// the in-memory state is already updated, so the process keeps its
// guarantee for as long as it lives (and reloadLocked's merge keeps
// protecting it against the file).
func (l *Log) appendLocked(e Entry) {
	if l.path == "" {
		return
	}
	f, err := os.OpenFile(l.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	if line, err := json.Marshal(e); err == nil {
		_, _ = f.Write(append(line, '\n'))
	}
	l.restatLocked()
}

// compact rewrites the file to one line per live key, through a temp
// file and a rename under the flock — another process is either before
// the whole rewrite or after it, never inside.
func (l *Log) compact() {
	l.flock()
	defer l.funlock()
	l.reloadLocked()
	tmp := l.path + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return
	}
	w := bufio.NewWriter(f)
	for _, e := range l.state {
		if line, err := json.Marshal(e); err == nil {
			_, _ = w.Write(append(line, '\n'))
		}
	}
	if w.Flush() != nil || f.Close() != nil {
		_ = os.Remove(tmp)
		return
	}
	if os.Rename(tmp, l.path) != nil {
		_ = os.Remove(tmp)
		return
	}
	l.restatLocked()
}

// load replays the file, last line per key winning. Entries older than
// the window are left in the file but out of the result — they are
// dropped for real by the next compaction. A line that does not parse,
// including a torn tail the writer is mid-append on, is skipped.
func load(path string, window time.Duration, now time.Time) []Entry {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	cutoff := now.Add(-window)
	latest := map[string]Entry{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for sc.Scan() {
		var e Entry
		if json.Unmarshal(sc.Bytes(), &e) != nil || e.Key == "" {
			continue
		}
		latest[e.Key] = e
	}
	out := make([]Entry, 0, len(latest))
	for _, e := range latest {
		// A zero timestamp is from a line written before At existed, or
		// a truncated one; keep it rather than silently forgetting a
		// delivery, since forgetting is the failure that matters.
		if !e.At.IsZero() && e.At.Before(cutoff) {
			continue
		}
		out = append(out, e)
	}
	return out
}

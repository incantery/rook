package transcript

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Line is one parsed record with the provenance a Record alone cannot carry.
//
// SessionID comes from the filename, not the record: Claude Code writes
// sessionId on some line types and omits it on others (an assistant record
// has none), and the file it lives in is authoritative either way. agentmon
// reaches the same conclusion — its Parser takes the session id from its
// caller.
type Line struct {
	SessionID string
	Offset    int64 // byte offset of the line start, for seek/resume
	Record    *Record

	// Live distinguishes an append we witnessed from backlog we read to
	// catch up. It is load-bearing, not informational: a consumer replays a
	// discovered file from zero to rebuild state, and every historical turn
	// in it would otherwise look like a turn that just ended — firing
	// draft invalidation and advancing workflow stages for turns that
	// finished hours ago. Reduce state from every line; fire side effects
	// only on Live ones.
	Live bool
}

// Tail follows one transcript file from a byte offset.
//
// The offset only ever advances to just past a newline, which is what makes
// this safe against the half-written line a live transcript always has at
// its end: a partial tail is simply re-read on the next call, and costs one
// read of whatever has not been terminated yet. Nothing is buffered across
// calls, so a Tail can be dropped and rebuilt at its offset with no loss.
type Tail struct {
	path      string
	sessionID string
	off       int64
	caughtUp  bool

	// Malformed counts lines that would not parse. A live transcript can
	// tear mid-write, so a nonzero count is not itself a problem; a rising
	// one means the format moved.
	Malformed int
}

// NewTail follows path from the beginning. The session id is the filename
// stem — ~/.claude/projects/<slug>/<session-uuid>.jsonl.
func NewTail(path string) *Tail {
	return &Tail{
		path:      path,
		sessionID: strings.TrimSuffix(filepath.Base(path), ".jsonl"),
	}
}

// SessionID is the session this file belongs to.
func (t *Tail) SessionID() string { return t.sessionID }

// Offset is the byte position after the last complete line consumed.
func (t *Tail) Offset() int64 { return t.off }

// SeekEnd jumps to the current end of file, skipping history. Used when a
// session is first sighted and only its live tail is wanted; there is no
// backlog to catch up on afterwards, so everything it then reads is Live.
func (t *Tail) SeekEnd() error {
	st, err := os.Stat(t.path)
	if err != nil {
		return err
	}
	t.off = st.Size()
	t.caughtUp = true
	return nil
}

// Read consumes every complete line written since the last call. It returns
// nil, nil when there is nothing new, which is the common case.
//
// Lines that will not parse are counted and skipped rather than returned as
// an error: one torn line must never stall a session's whole stream.
func (t *Tail) Read() ([]Line, error) {
	f, err := os.Open(t.path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	st, err := f.Stat()
	if err != nil {
		return nil, err
	}

	// The first drain of a file is backlog: everything already in it was
	// written before we looked. Once we have reached EOF once, anything
	// further is an append we witnessed.
	live := t.caughtUp
	t.caughtUp = true

	// A shrinking file means it was replaced, not appended to. Start over
	// rather than reading from a meaningless offset into new content — and
	// what we re-read is backlog again, not new events.
	if st.Size() < t.off {
		t.off = 0
		live = false
	}
	if st.Size() == t.off {
		return nil, nil
	}
	if _, err := f.Seek(t.off, io.SeekStart); err != nil {
		return nil, err
	}
	data, err := io.ReadAll(f)
	if err != nil {
		return nil, err
	}

	// Consume only through the last newline; anything after it is a line
	// still being written.
	end := bytes.LastIndexByte(data, '\n')
	if end < 0 {
		return nil, nil
	}
	complete := data[:end+1]

	var out []Line
	base := t.off
	var pos int64
	for _, raw := range bytes.SplitAfter(complete, []byte{'\n'}) {
		if len(raw) == 0 {
			continue
		}
		start := base + pos
		pos += int64(len(raw))
		if len(bytes.TrimSpace(raw)) == 0 {
			continue
		}
		rec, err := Parse(raw)
		if err != nil {
			t.Malformed++
			continue
		}
		out = append(out, Line{SessionID: t.sessionID, Offset: start, Record: rec, Live: live})
	}
	t.off = base + pos
	return out, nil
}

package host

// Read-time re-anchoring: the stored anchor (blob_sha + range) is
// immutable ground truth, and mapping it onto today's file is a VIEW —
// never persisted, so drift cannot compound. Same content hash → the
// stored range holds (one hash, no subprocess). Different → git diff
// --no-index between the stored snapshot and the current file, and the
// range maps through the hunks: shifted when edits landed above it,
// outdated when the anchored lines themselves changed (GitHub
// semantics — the thread still renders its anchor_text).

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
)

// gitBlobSHA is git's blob hash: sha1("blob <len>\x00" + content). In-
// process — the fast path must not fork.
func gitBlobSHA(content []byte) string {
	h := sha1.New()
	fmt.Fprintf(h, "blob %d\x00", len(content))
	h.Write(content)
	return hex.EncodeToString(h.Sum(nil))
}

type hunk struct{ oldStart, oldCount, newStart, newCount int }

// hunkRE parses --unified=0 headers; an omitted count means 1.
var hunkRE = regexp.MustCompile(`(?m)^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@`)

func parseHunks(diff []byte) []hunk {
	var out []hunk
	for _, m := range hunkRE.FindAllSubmatch(diff, -1) {
		atoi := func(b []byte, def int) int {
			if len(b) == 0 {
				return def
			}
			n, _ := strconv.Atoi(string(b))
			return n
		}
		out = append(out, hunk{
			oldStart: atoi(m[1], 0), oldCount: atoi(m[2], 1),
			newStart: atoi(m[3], 0), newCount: atoi(m[4], 1),
		})
	}
	return out
}

// mapRange maps a 1-based inclusive [start,end] from old-file coordinates
// through hunks. Hunks entirely above shift it; a hunk touching the
// anchored lines outdates it (the caller keeps the stored range for
// display). Pure insertions (oldCount 0) sit BETWEEN old lines oldStart
// and oldStart+1: above the range they shift it, strictly inside they
// outdate it, at or past the end they are invisible.
func mapRange(hunks []hunk, start, end int) (int, int, bool) {
	delta := 0
	for _, hk := range hunks {
		if hk.oldCount == 0 {
			if hk.oldStart < start {
				delta += hk.newCount
			} else if hk.oldStart < end {
				return start, end, true
			}
			continue
		}
		oldEnd := hk.oldStart + hk.oldCount - 1
		switch {
		case oldEnd < start:
			delta += hk.newCount - hk.oldCount
		case hk.oldStart > end:
			// below the range — invisible
		default:
			return start, end, true
		}
	}
	return start + delta, end + delta, false
}

// diffHunks runs git diff --no-index over two contents via scratch files.
// Exit code 1 means "files differ" — that is the expected success here.
func diffHunks(old, cur []byte) ([]hunk, error) {
	dir, err := os.MkdirTemp("", "rook-reanchor")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	fa, fb := filepath.Join(dir, "a"), filepath.Join(dir, "b")
	if err := os.WriteFile(fa, old, 0o600); err != nil {
		return nil, err
	}
	if err := os.WriteFile(fb, cur, 0o600); err != nil {
		return nil, err
	}
	git, err := exec.LookPath("git")
	if err != nil {
		git = "/usr/bin/git" // launchd's minimal PATH
	}
	out, err := exec.Command(git, "diff", "--no-index", "--unified=0", fa, fb).Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); !ok || ee.ExitCode() != 1 {
			return nil, err
		}
	}
	return parseHunks(out), nil
}

// hunkMemo caches diffHunks results per (old,cur) blob pair — a pane's
// poll must not re-fork git for an unchanged file, and one entry serves
// every thread anchored to that file version.
type hunkMemo struct {
	mu sync.Mutex
	m  map[string][]hunk
}

func (c *hunkMemo) get(key string) ([]hunk, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	h, ok := c.m[key]
	return h, ok
}

func (c *hunkMemo) put(key string, h []hunk) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.m == nil || len(c.m) > 256 {
		c.m = make(map[string][]hunk) // crude cap; entries are tiny
	}
	c.m[key] = h
}

// anchorNow maps t's stored anchor onto the file as it is right now.
// Every failure lands on outdated-with-stored-range — a thread renders
// from anchor_text, never errors.
func (h *Host) anchorNow(top string, t *ThreadInfo) {
	t.CurrentStart, t.CurrentEnd = t.StartLine, t.EndLine
	abs, err := confinePath(top, t.Path)
	if err != nil {
		t.Outdated = true
		return
	}
	cur, err := os.ReadFile(abs)
	if err != nil {
		t.Outdated = true // deleted (or unreadable) file
		return
	}
	curSHA := gitBlobSHA(cur)
	if curSHA == t.BlobSHA {
		return // the common case: content unchanged, one hash, no git
	}
	key := t.BlobSHA + ":" + curSHA
	hunks, ok := h.anchorMemo.get(key)
	if !ok {
		old := h.reg.getAnchorBlob(t.BlobSHA)
		if old == nil {
			t.Outdated = true // snapshot pruned/missing — fail open
			return
		}
		hunks, err = diffHunks(old, cur)
		if err != nil {
			t.Outdated = true
			return
		}
		h.anchorMemo.put(key, hunks)
	}
	t.CurrentStart, t.CurrentEnd, t.Outdated = mapRange(hunks, t.StartLine, t.EndLine)
	if t.Outdated {
		t.CurrentStart, t.CurrentEnd = t.StartLine, t.EndLine
	}
}

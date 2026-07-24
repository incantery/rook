package host

// The thread document (docs/superpowers/specs/2026-07-23-thread-buffers-
// design.md): a thread projected as an editable buffer. Truth stays
// structured in the DB — this file renders the projection and, on save,
// diffs what it handed out against what came back. The contract is
// append-only history enforced by a PREFIX CHECK: saved content must start
// byte-for-byte with the rendered history through the scissors line, and
// everything below is the user's tail (the mutable draft). Not a parser —
// strings.HasPrefix.
//
// Mutable state (current anchor mapping, whose-move, outdated) never
// renders in: it would make the prefix unstable, and concurrent agent
// replies merge by re-render + tail splice precisely because the prefix
// is a pure function of immutable rows.

import (
	"fmt"
	"os/user"
	"strconv"
	"strings"
	"sync"
)

// scissorsPrefix is the fixed head of the scissors line — what a client
// might key off; the host itself only ever matches whole rendered prefixes.
const scissorsPrefix = "-- ✂ --"

const scissorsLine = scissorsPrefix +
	" reply below · history above this line is read-only --------------------"

// docUser is the login name rendered on user comments. Resolved once per
// process, so the prefix stays deterministic between the GET that handed a
// doc out and the POST that brings it back.
var docUser = sync.OnceValue(func() string {
	if u, err := user.Current(); err == nil && u.Username != "" {
		return u.Username
	}
	return "user"
})

func docAuthor(author string) string {
	if author == "agent" {
		return "claude"
	}
	return docUser()
}

// renderThreadDoc projects a thread as its editable document. prefix is
// everything through (and including) the scissors line — the read-only
// history a save must reproduce byte-for-byte; doc is prefix + the stored
// draft. A resolved thread renders with NO scissors (doc == prefix): its
// history is closed, and the client opens it read-only.
//
// Frontmatter carries immutable facts only — id, the anchor AT CREATION,
// created date. Timestamps are absolute local time: a relative "2m ago"
// would rot the prefix between render and save.
func renderThreadDoc(t *ThreadInfo) (doc, prefix string) {
	var b strings.Builder
	rng := strconv.Itoa(t.StartLine)
	if t.EndLine != t.StartLine {
		rng += "-" + strconv.Itoa(t.EndLine)
	}
	fmt.Fprintf(&b, "---\nthread: %d\nanchor: %s:%s (%s)\ncreated: %s\n---\n\n",
		t.ID, t.Path, rng, t.Side, t.Created.Local().Format("2006-01-02"))
	for _, c := range t.Comments {
		fmt.Fprintf(&b, "## %s · %s", docAuthor(c.Author), c.Created.Local().Format("2006-01-02 15:04"))
		if c.AgentSession != "" {
			fmt.Fprintf(&b, " · session %s", c.AgentSession)
		}
		b.WriteString("\n\n")
		b.WriteString(strings.TrimRight(c.Body, "\n"))
		b.WriteString("\n\n")
	}
	if t.State == "resolved" {
		doc = b.String()
		return doc, doc
	}
	b.WriteString(scissorsLine + "\n")
	prefix = b.String()
	return prefix + t.Draft, prefix
}

// splitThreadDoc is the prefix check: saved must start with a FRESH render
// of the history through the scissors line; the remainder is the tail.
// ok=false means the histories diverged — a concurrent reply landed, or the
// history was hand-edited — and the caller answers 409 with the fresh doc
// so the client can splice its tail back under the new prefix.
func splitThreadDoc(t *ThreadInfo, saved string) (tail string, ok bool) {
	_, prefix := renderThreadDoc(t)
	if !strings.HasPrefix(saved, prefix) {
		return "", false
	}
	return saved[len(prefix):], true
}

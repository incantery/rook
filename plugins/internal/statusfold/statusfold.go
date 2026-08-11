// Package statusfold is the one fold from scanner truth to the status
// snapshot every remote rail publishes: transcript sessions (already
// fused with pane activity), the agent plugin's digests, a hostname
// and a version in — a neutral Status out.
//
// Neutral is the point. The cloud bridge renders this as rook-cloud's
// wire JSON; the link plugin converts it to rook-host's projection
// types; both must say exactly the same thing about the same machine,
// so the mapping (which states collapse to needs_input, what an ask
// looks like, how the ask's stable handle is minted) lives here once.
//
// The field vocabulary mirrors the wire: id / state / title / ask /
// askId / model / costUsd / ctxPct / digest{headline,bullets,at} /
// lastEvent per agent; name / branch / attention per workspace. A zero
// value here means "absent on the wire" — renderers apply their own
// omitempty tags and get identical bytes.
package statusfold

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/incantery/rook/plugins/internal/digestlog"
	"github.com/incantery/rook/plugins/internal/nowfile"
	"github.com/incantery/rook/plugins/internal/spendfile"
	"github.com/incantery/rook/plugins/internal/transcript"
	"github.com/incantery/rook/plugins/internal/usagefile"
)

// Status is one machine's snapshot, rail-neutral.
type Status struct {
	Hostname    string
	RookVersion string
	Usage       *Usage
	Workspaces  []Workspace
}

// Usage is the account's spend picture: the Claude subscription's
// rate-limit windows exactly as the claude CLI reported them (the
// claude plugin's collector writes the usage file), plus the rook
// agent's own model bill (the spend ledger). Nil when neither file is
// fresh.
type Usage struct {
	Mode            string
	SessionPct      int
	SessionResets   string
	WeekAllPct      int
	WeekAllResets   string
	WeekModelName   string
	WeekModelPct    int
	WeekModelResets string
	At              time.Time
	AgentTodayUSD   float64
	AgentWeekUSD    float64
}

// CollectUsage reads the shared files at their default paths — the
// convenience both bridges call per snapshot. Freshness: the usage
// collector refreshes every ~5 minutes, so 15 minutes stale means a
// dead collector; the spend ledger has no staleness (it is a sum, not
// a claim about the present).
func CollectUsage(now time.Time) *Usage {
	u := usagefile.Read(usagefile.DefaultPath(), 15*time.Minute, now)
	today, week := spendfile.Totals(spendfile.DefaultPath(), now)
	if u == nil && today == 0 && week == 0 {
		return nil
	}
	out := &Usage{AgentTodayUSD: today, AgentWeekUSD: week}
	if u != nil {
		out.Mode = u.Mode
		out.SessionPct = u.SessionPct
		out.SessionResets = u.SessionResets
		out.WeekAllPct = u.WeekAllPct
		out.WeekAllResets = u.WeekAllResets
		out.WeekModelName = u.WeekModelName
		out.WeekModelPct = u.WeekModelPct
		out.WeekModelResets = u.WeekModelResets
		out.At = u.At
	} else {
		out.Mode = "agent-only"
	}
	return out
}

// Workspace groups the agents working in one directory.
type Workspace struct {
	Name      string
	Branch    string
	Attention int // how many agents are waiting on a human
	Agents    []Agent
}

// Agent is one session's row. State is the remote vocabulary:
// working | needs_input | quiet.
type Agent struct {
	ID      string // session id — what a remote-issued command names
	State   string
	Title   string
	Ask     string
	AskID   string
	Model   string
	CostUSD float64 // unreported today; carried so the shape matches the wire
	CtxPct  int     // context occupancy percent; 0 = unreported
	Digest  *Digest
	// Now is the membrane's live line — what the screen says is
	// happening at NowAt, from the agent plugin's screen-watcher. Set
	// only while the session is working; a finished turn's story is the
	// digest's job.
	Now       string
	NowAt     time.Time
	Attached  bool // open in a live pane right now — see transcript.Session.Attached
	LastEvent time.Time
}

// Digest is the membrane's artifact: headline plus bullets, the STE
// compression of the session's last finished turn.
type Digest struct {
	Headline string
	Bullets  []string
	At       time.Time
}

// maxAsk is what the remote surfaces store for an ask — rook-cloud's
// own comment calls it "the one field worth reading in full".
const maxAsk = 2000

// AskText is the question as a remote surface will read and answer it.
//
// Snip is right for the panel: cell rows are one line, so it flattens
// whitespace and cuts hard. It is wrong here. We were sending 200
// bytes, a tenth of what the wire allows, so every ask longer than a
// sentence reached the phone already ending in an ellipsis — and a
// reply written against a tenth of a question is a reply to a
// different question.
//
// Line structure survives for the same reason. The asks that are
// hardest to answer away from the keyboard are the ones offering
// numbered choices, and flattening them to one line is exactly what
// makes them unreadable on the surface that most needs them readable.
func AskText(s string) string {
	s = strings.TrimSpace(s)
	if len(s) <= maxAsk {
		return s
	}
	cut := maxAsk - len("…")
	for cut > 0 && s[cut]&0xC0 == 0x80 { // land on a rune boundary
		cut--
	}
	return s[:cut] + "…"
}

// AskID is the stable handle for one session's current ask: the
// session plus a hash of what it is waiting on. FNV-1a, an identity
// not a defense — same as the digest ids next door. Delivery re-derives
// it, so a changed ask (the session moved on) makes an old answer
// STALE by construction.
func AskID(s transcript.Session) string {
	basis := s.LastText
	if s.State == transcript.StateBlocked {
		basis = "approval:" + s.Prompt
	}
	var h uint64 = 14695981039346656037
	for i := range len(basis) {
		h ^= uint64(basis[i])
		h *= 1099511628211
	}
	return fmt.Sprintf("%s:%08x", s.ID, uint32(h^(h>>32)))
}

// Fold collapses sessions into the remote vocabulary. The mapping is
// deliberately conservative in one place: `blocked?` becomes
// needs_input, because a session that may be sitting on an approval is
// exactly what you left the room and want to know about.
//
// digests is the agent plugin's journal, latest per session; nows is
// its ephemeral screen-watcher file (nil is fine — older machines and
// idle fleets simply carry no live lines): this fold does no language
// work of its own — it carries the membrane's artifacts, it does not
// make them.
func Fold(sessions []transcript.Session, digests map[string]digestlog.Digest, nows map[string]nowfile.Now, hostname, rookVersion string) Status {
	st := Status{Hostname: hostname, RookVersion: rookVersion}

	byWS := map[string]*Workspace{}
	var order []string
	for _, s := range sessions {
		name := filepath.Base(s.Cwd)
		if name == "" || name == "." || name == "/" {
			name = "?"
		}
		w, ok := byWS[name]
		if !ok {
			w = &Workspace{Name: name, Branch: s.Branch}
			byWS[name] = w
			order = append(order, name)
		}
		a := Agent{
			ID:        s.ID,
			Title:     transcript.Snip(s.Title, 80),
			Model:     "claude",
			Attached:  s.Attached,
			LastEvent: s.Mtime,
		}
		if p := transcript.CtxPct(s.CtxTokens, s.Model); p > 0 {
			a.CtxPct = p
		}
		if d, ok := digests[s.ID]; ok {
			a.Digest = &Digest{Headline: d.Headline, Bullets: d.Bullets, At: d.At}
		}
		// The live line rides only on a WORKING session: once the turn
		// ends, the digest is the story and a leftover "now" would be a
		// stale claim about the present.
		if n, ok := nows[s.ID]; ok && s.State == transcript.StateWorking {
			a.Now = transcript.Snip(n.Line, 200)
			a.NowAt = n.At
		}
		switch s.State {
		case transcript.StateNeedsYou:
			a.State = "needs_input"
			a.Ask = AskText(s.LastText)
		case transcript.StateBlocked:
			a.State = "needs_input"
			a.Ask = AskText("approval? " + s.Prompt)
		case transcript.StateWorking:
			a.State = "working"
		default:
			a.State = "quiet"
		}
		if a.State == "needs_input" {
			a.AskID = AskID(s)
			w.Attention++
		}
		w.Agents = append(w.Agents, a)
	}
	sort.Strings(order)
	for _, name := range order {
		st.Workspaces = append(st.Workspaces, *byWS[name])
	}
	return st
}

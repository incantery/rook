package host

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/incantery/rook/internal/transcript"
)

// sessionFiles returns the real session transcripts on this machine.
// Only <root>/<slug>/*.jsonl is a session; subagent transcripts live
// deeper and rook discards their traffic.
func sessionFiles(t *testing.T) []string {
	t.Helper()
	root, err := transcript.DefaultRoot()
	if err != nil {
		t.Skip("no home dir")
	}
	projects, err := os.ReadDir(root)
	if err != nil {
		t.Skip("no ~/.claude/projects on this machine")
	}
	var out []string
	for _, p := range projects {
		if !p.IsDir() {
			continue
		}
		files, err := os.ReadDir(filepath.Join(root, p.Name()))
		if err != nil {
			continue
		}
		for _, f := range files {
			if !f.IsDir() && strings.HasSuffix(f.Name(), ".jsonl") {
				out = append(out, filepath.Join(root, p.Name(), f.Name()))
			}
		}
	}
	return out
}

// replay pushes a whole transcript through the reducer as backlog and
// returns the session's final state.
func replay(path string) (*AgentStatus, int, int) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, 0, 0
	}
	id := strings.TrimSuffix(filepath.Base(path), ".jsonl")
	a := newAgentWatch()
	var lines, malformed int
	for raw := range strings.SplitSeq(string(data), "\n") {
		if strings.TrimSpace(raw) == "" {
			continue
		}
		lines++
		rec, err := transcript.Parse([]byte(raw))
		if err != nil {
			malformed++
			continue
		}
		a.applyRecord(transcript.Line{SessionID: id, Record: rec})
	}
	return a.states[id], lines, malformed
}

// TestReducerAgainstRealSessions replays every real session on this machine
// through the reducer.
//
// The unit tests above are all written against JSON this package's author
// composed from a reading of the format — if that reading is wrong, the
// fixtures encode the mistake and pass anyway. Types cannot catch that; only
// real data can. This is also the drift detector: when Claude Code changes
// what it writes, the invariants here go red rather than the Inbox going
// quietly empty.
//
// Skips wherever the tree is absent (CI, a fresh machine).
func TestReducerAgainstRealSessions(t *testing.T) {
	files := sessionFiles(t)
	if len(files) == 0 {
		t.Skip("no session transcripts")
	}

	states := map[string]int{} // final state -> count
	var sessions, lines, malformed int
	var needsInput, needsInputWithAsk, withCost, titled int

	for _, f := range files {
		st, n, bad := replay(f)
		lines += n
		malformed += bad
		if st == nil {
			continue // empty file, or the usage prober's own artifact
		}
		sessions++
		states[st.State]++

		// The state machine's enum is closed. Anything else means a
		// transition wrote a state nobody reads.
		switch st.State {
		case "working", "needs_input", "quiet":
		default:
			t.Errorf("%s: final state %q is outside the enum", filepath.Base(f), st.State)
		}
		if st.State == "needs_input" {
			needsInput++
			if st.Ask != "" {
				needsInputWithAsk++
			}
		}
		if st.CostUSD > 0 {
			withCost++
		}
		if st.Title != "" {
			titled++
		}
		if st.CostUSD < 0 {
			t.Errorf("%s: negative cost %v", filepath.Base(f), st.CostUSD)
		}
	}

	t.Logf("%d files, %d sessions, %d lines, %d malformed", len(files), sessions, lines, malformed)
	t.Logf("final states: %v", states)
	t.Logf("needs_input: %d (%d with an ask) | priced: %d | titled: %d",
		needsInput, needsInputWithAsk, withCost, titled)

	if sessions == 0 {
		t.Skip("no sessions reduced")
	}

	// The load-bearing belief: system/turn_duration is what marks a turn's
	// end, and it is the only thing that puts a session into needs_input.
	// If that reading is wrong, this is zero and the Inbox never surfaces
	// anything — while every unit test still passes.
	if needsInput == 0 {
		t.Error("no session ended in needs_input across the whole corpus — turn_duration is not being reduced as a turn end")
	}
	// An ask with no text is a row the user cannot act on.
	if needsInput > 0 && needsInputWithAsk == 0 {
		t.Error("every needs_input session has an empty Ask — the assistant text is not reaching askDraft")
	}
	// Cost is stamped from the model table; zero everywhere means the usage
	// object or the model id is not being read.
	if withCost == 0 {
		t.Error("no session priced — usage or model is not reaching Cost()")
	}
	if rate := float64(malformed) / float64(lines); lines > 0 && rate > 0.01 {
		t.Errorf("%.1f%% of lines failed to parse (%d/%d) — the format likely changed", rate*100, malformed, lines)
	}
}

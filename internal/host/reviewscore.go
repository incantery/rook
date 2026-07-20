package host

// Host-side triage: the per-hunk Haiku fan-out, ONE implementation shared by
// every trigger (rookctl review score-all, the review hero's Triage button).
// The host still holds no model SDK and no API key — it execs the user's own
// claude CLI (findClaude, the usage prober's resolver), the same trust
// boundary as the drafter and the prober. Scoring is async: the endpoint
// returns immediately, results land per-hunk in each task's detail bag, and
// the in-flight flag rides the task payloads so clients poll instead of
// blocking.

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"time"
)

const (
	// cheap, fast, parallel across hunks — the triage tier
	scoreModel = "claude-haiku-4-5-20251001"
	// enough to be fast on a big review, not a claude-process fork bomb
	scoreConcurrency = 6
	// a stuck claude must not pin a slot forever
	scoreHunkTimeout = 3 * time.Minute
	// prompt cap per hunk; the path still orients the model when truncated
	scoreBodyCap = 4000
)

// hunkAnalysis is one Haiku's read of one hunk. summary + concerns are the
// "why look at this / what to check" that make a review card worth more than
// a diff row; risk/understand drive ranking.
type hunkAnalysis struct {
	Category   string   `json:"category"`
	Risk       int      `json:"risk"`
	Understand int      `json:"understand"`
	Summary    string   `json:"summary"`
	Concerns   []string `json:"concerns"`
}

func (h *Host) isScoring(rootID int64) bool {
	h.scoreMu.Lock()
	defer h.scoreMu.Unlock()
	return h.scoring[rootID]
}

// startScoring marks a root in-flight; false means a run is already going.
func (h *Host) startScoring(rootID int64) bool {
	h.scoreMu.Lock()
	defer h.scoreMu.Unlock()
	if h.scoring == nil {
		h.scoring = make(map[int64]bool)
	}
	if h.scoring[rootID] {
		return false
	}
	h.scoring[rootID] = true
	return true
}

func (h *Host) finishScoring(rootID int64) {
	h.scoreMu.Lock()
	defer h.scoreMu.Unlock()
	delete(h.scoring, rootID)
}

// scoreReviewAsync kicks the fan-out for a review root and returns at once.
// A second trigger while one is in flight is a no-op, not an error — the
// button and the CLI can race without double-spending.
func (h *Host) scoreReviewAsync(root *RookTask) error {
	claude := findClaude()
	if claude == "" {
		return fmt.Errorf("claude CLI not found — triage needs it on PATH")
	}
	if !h.startScoring(root.ID) {
		return nil
	}
	kids := h.reg.childrenOf(root.ID)
	go func() {
		defer h.finishScoring(root.ID)
		sem := make(chan struct{}, scoreConcurrency)
		var wg sync.WaitGroup
		for _, kid := range kids {
			wg.Add(1)
			go func(t *RookTask) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()
				a, err := analyzeHunk(claude, t)
				if err != nil {
					return // this hunk stays unscored; a re-trigger retries it
				}
				patch := map[string]any{
					"category": a.Category,
					"summary":  a.Summary,
					"concerns": a.Concerns,
					"score":    map[string]int{"risk": a.Risk, "understand": a.Understand},
				}
				raw := make(map[string]json.RawMessage, len(patch))
				for k, v := range patch {
					b, _ := json.Marshal(v)
					raw[k] = b
				}
				_ = h.reg.mergeTaskDetail(t.ID, raw)
			}(kid)
		}
		wg.Wait()
	}()
	return nil
}

// analyzeHunk runs one Haiku over one hunk's patch and parses its JSON.
func analyzeHunk(claude string, t *RookTask) (*hunkAnalysis, error) {
	ctx, cancel := context.WithTimeout(context.Background(), scoreHunkTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, claude, "-p", "--model", scoreModel, buildHunkPrompt(t)).Output()
	if err != nil {
		return nil, err
	}
	return extractAnalysis(out)
}

func buildHunkPrompt(t *RookTask) string {
	body := t.AnchorText
	if body == "" {
		body = t.Path
	}
	if len(body) > scoreBodyCap {
		body = body[:scoreBodyCap] + "\n… (truncated)"
	}
	var b strings.Builder
	b.WriteString("You are triaging ONE hunk of a code review. Reply with ONLY a JSON object:\n")
	b.WriteString(`{"category":"terse phrase","risk":1,"understand":1,"summary":"one sentence: what this change does","concerns":["short things a human should check"]}` + "\n\n")
	b.WriteString("- risk: 1 trivial/mechanical/docs → 5 subtle, high blast radius\n")
	b.WriteString("- understand: 1 skim → 5 needs careful human attention\n")
	b.WriteString("- category: e.g. \"internal docs, no prod impact\", \"error-path change\", \"public API\"\n")
	b.WriteString("- concerns: 0-3 short bullets a reviewer should check; empty array if genuinely trivial\n\n")
	fmt.Fprintf(&b, "File: %s\n\n%s\n", t.Path, body)
	return b.String()
}

// extractAnalysis finds the first JSON object in claude's output and parses
// it — the model may wrap the object in prose.
func extractAnalysis(out []byte) (*hunkAnalysis, error) {
	s := string(out)
	i := strings.IndexByte(s, '{')
	j := strings.LastIndexByte(s, '}')
	if i < 0 || j <= i {
		return nil, fmt.Errorf("no JSON object in output")
	}
	var a hunkAnalysis
	if err := json.Unmarshal([]byte(s[i:j+1]), &a); err != nil {
		return nil, err
	}
	return &a, nil
}

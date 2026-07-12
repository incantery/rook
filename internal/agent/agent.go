package agent

import (
	"context"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/incantery/rook/internal/config"
)

// Agent is the drafter loop: poll /attention, judge each fresh ask once,
// post the judgment back. All state (drafts, verdicts, spend) lives in the
// host; ours is just "which asks are in flight".
type Agent struct {
	Host        *Client
	AI          *OpenAI
	DailyCapUSD float64
	// Debounce lets a burst of transcript events settle before we spend a
	// call — the ask we draft against must be the one that stays on screen.
	Debounce  time.Duration
	Poll      time.Duration
	HourlyCap int

	mu         sync.Mutex
	seen       map[string]bool // agentSession:askSeq → judged or in flight
	pauseUntil time.Time
	sem        chan struct{}
}

func New(host *Client, ai *OpenAI, dailyCapUSD float64) *Agent {
	return &Agent{
		Host:        host,
		AI:          ai,
		DailyCapUSD: dailyCapUSD,
		Debounce:    1500 * time.Millisecond,
		Poll:        2 * time.Second,
		HourlyCap:   60,
		seen:        make(map[string]bool),
		sem:         make(chan struct{}, 2), // concurrency 2
	}
}

// Run polls until ctx ends, the host rejects us (ErrHostGone — exit and
// let the supervisor respawn), or the config turns the agent off.
func (a *Agent) Run(ctx context.Context) error {
	tick := time.NewTicker(a.Poll)
	defer tick.Stop()
	cfgCheck := time.NewTicker(time.Minute)
	defer cfgCheck.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-cfgCheck.C:
			if !config.Load().Agent {
				return errors.New("agent turned off in config")
			}
		case <-tick.C:
			items, err := a.Host.Attention()
			if errors.Is(err, ErrHostGone) {
				return err
			}
			if err != nil {
				continue // host briefly unreachable
			}
			a.tick(ctx, items)
		}
	}
}

func itemKey(it AttentionItem) string {
	return fmt.Sprintf("%s:%d", it.AgentSession, it.AskSeq)
}

// tick launches a judge for every fresh, draft-less ask, and prunes the
// seen-set down to asks that still exist (a resolved ask frees its key;
// an in-flight one is still live, so its marker survives).
func (a *Agent) tick(ctx context.Context, items []AttentionItem) {
	a.mu.Lock()
	if time.Now().Before(a.pauseUntil) {
		a.mu.Unlock()
		return
	}
	live := make(map[string]bool, len(items))
	var todo []AttentionItem
	for _, it := range items {
		k := itemKey(it)
		live[k] = true
		// interactive asks are pickers — nothing we could type; the inbox
		// surfaces them and the user answers in the window
		if it.State != "needs_input" || it.Interactive || it.Draft != nil || a.seen[k] {
			continue
		}
		a.seen[k] = true
		todo = append(todo, it)
	}
	for k := range a.seen {
		if !live[k] {
			delete(a.seen, k)
		}
	}
	a.mu.Unlock()
	for _, it := range todo {
		go a.judge(ctx, it)
	}
}

func (a *Agent) unmark(k string) {
	a.mu.Lock()
	delete(a.seen, k)
	a.mu.Unlock()
}

func (a *Agent) pause(d time.Duration) {
	a.mu.Lock()
	a.pauseUntil = time.Now().Add(d)
	a.mu.Unlock()
}

func (a *Agent) judge(ctx context.Context, it AttentionItem) {
	k := itemKey(it)
	a.sem <- struct{}{}
	defer func() { <-a.sem }()

	select {
	case <-ctx.Done():
		return
	case <-time.After(a.Debounce):
	}

	// Budget guards — asked of the host, whose ledger is the truth. Over
	// budget: the item stays surfaced draft-less; nothing breaks.
	sp, err := a.Host.Spend()
	if err != nil {
		a.unmark(k)
		return
	}
	if a.DailyCapUSD > 0 && sp.TodayUSD >= a.DailyCapUSD {
		log.Printf("budget: daily cap $%.2f reached ($%.4f spent) — pausing", a.DailyCapUSD, sp.TodayUSD)
		a.pause(10 * time.Minute)
		a.unmark(k)
		return
	}
	if sp.HourCalls >= a.HourlyCap {
		log.Printf("budget: %d calls in the last hour — pausing", sp.HourCalls)
		a.pause(5 * time.Minute)
		a.unmark(k)
		return
	}

	// Re-read after the debounce: only draft against the ask that stayed.
	c, err := a.Host.Context(it.AgentSession)
	if err != nil {
		a.unmark(k)
		return
	}
	if c.AskSeq != it.AskSeq || c.State != "needs_input" || c.Ask == "" {
		return // ask moved on; its key dies with it
	}

	callCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	j, u, err := a.AI.Judge(callCtx, SystemPrompt(LoadPreferences()), UserPrompt(c))
	if err != nil {
		log.Printf("judge %s: %v (cooling off 60s)", k, err)
		a.pause(time.Minute)
		a.unmark(k)
		return
	}
	// The gate, belt and braces: a hesitant draft is an escalation even if
	// the model didn't say so.
	if j.Action == "draft" && (j.Confidence < 0.6 || j.Reply == "") {
		j.Action, j.Reply = "escalate", ""
	}
	stale, err := a.Host.PostDraft(it.AgentSession, DraftPost{
		AskSeq:       it.AskSeq,
		Action:       j.Action,
		Reply:        j.Reply,
		Confidence:   j.Confidence,
		Model:        a.AI.Model,
		InputTokens:  u.InputTokens,
		OutputTokens: u.OutputTokens,
		CachedTokens: u.CachedTokens,
		CostUSD:      u.CostUSD,
	})
	switch {
	case err != nil:
		log.Printf("post draft %s: %v", k, err)
		a.unmark(k)
	case stale:
		log.Printf("draft %s: host says stale/duplicate — dropped", k)
	default:
		log.Printf("%s %s (conf %.2f, $%.5f): %s", j.Action, k, j.Confidence, u.CostUSD, truncate(j.Reply, 80))
	}
}

package host

import (
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/incantery/rook/internal/cloud"
	"github.com/incantery/rook/internal/transcript"
)

// The queued event is the privacy line for usage: everything it copies
// leaves the machine. So the test states the whole published set — a field
// added to the projection has to be added here too. Note what is absent:
// no session id, no cwd, no text. Tokens travel with zero cost when the
// model isn't priced, because the tokens are the data.
func TestQueueUsagePublishesExactlyTheDecidedFields(t *testing.T) {
	at := time.Date(2026, 7, 26, 15, 0, 0, 0, time.UTC)
	a := newAgentWatch()
	a.enableUsagePush()

	m := &transcript.Message{
		ID:    "msg_abc",
		Model: "claude-fable-5",
		Usage: transcript.Usage{
			InputTokens:         100,
			OutputTokens:        200,
			CacheReadTokens:     3000,
			CacheCreationTokens: 40,
			Cache5mTokens:       30, // subdivision of creation — stays home
			Speed:               "fast",
		},
	}
	a.mu.Lock()
	a.queueUsageLocked(m, 0.42, at)
	a.mu.Unlock()

	got := a.drainUsage(10)
	want := []cloud.UsageEvent{{
		ID:                  "msg_abc",
		Kind:                "claude",
		Model:               "claude-fable-5",
		At:                  at,
		InputTokens:         100,
		OutputTokens:        200,
		CacheReadTokens:     3000,
		CacheCreationTokens: 40,
		CostUSD:             0.42,
	}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("event projected wrong:\n got %+v\nwant %+v", got, want)
	}
}

// Three ways a response has nothing meterable to say: the push is off (no
// cloud configured), the message has no id (no idempotency key, so pushing
// risks double-count on replay), or the usage object is empty.
func TestQueueUsageSkipsTheUnmeterable(t *testing.T) {
	at := time.Now()
	tokens := transcript.Usage{InputTokens: 1}

	for name, tc := range map[string]struct {
		push bool
		msg  *transcript.Message
	}{
		"push disabled": {false, &transcript.Message{ID: "m1", Usage: tokens}},
		"no message id": {true, &transcript.Message{Usage: tokens}},
		"no tokens":     {true, &transcript.Message{ID: "m2"}},
	} {
		a := newAgentWatch()
		if tc.push {
			a.enableUsagePush()
		}
		a.mu.Lock()
		a.queueUsageLocked(tc.msg, 0.1, at)
		a.mu.Unlock()
		if got := a.drainUsage(10); len(got) != 0 {
			t.Errorf("%s: queued %d events, want none", name, len(got))
		}
	}
}

// The outbox is oldest-first through drain, requeue, and overflow: a failed
// batch goes back to the front, and the cap sacrifices the oldest history
// rather than the newest.
func TestUsageOutboxOrderAndCap(t *testing.T) {
	a := newAgentWatch()
	a.enableUsagePush()

	queue := func(id string) {
		a.mu.Lock()
		a.queueUsageLocked(&transcript.Message{
			ID:    id,
			Usage: transcript.Usage{OutputTokens: 1},
		}, 0, time.Now())
		a.mu.Unlock()
	}
	ids := func(evs []cloud.UsageEvent) []string {
		out := make([]string, len(evs))
		for i, e := range evs {
			out[i] = e.ID
		}
		return out
	}

	for i := range 5 {
		queue(fmt.Sprintf("m%d", i))
	}

	batch := a.drainUsage(2)
	if got := ids(batch); !reflect.DeepEqual(got, []string{"m0", "m1"}) {
		t.Fatalf("drain took %v, want oldest first", got)
	}

	// the post failed: the batch goes back ahead of what queued meanwhile
	a.requeueUsage(batch)
	if got := ids(a.drainUsage(10)); !reflect.DeepEqual(got, []string{"m0", "m1", "m2", "m3", "m4"}) {
		t.Errorf("after requeue: %v, want original order restored", got)
	}

	// overflow drops from the front — oldest lost, newest kept
	for i := range usageOutboxCap + 10 {
		queue(fmt.Sprintf("n%d", i))
	}
	all := a.drainUsage(usageOutboxCap * 2)
	if len(all) != usageOutboxCap {
		t.Fatalf("cap not enforced: %d events", len(all))
	}
	if all[0].ID != "n10" || all[len(all)-1].ID != fmt.Sprintf("n%d", usageOutboxCap+9) {
		t.Errorf("cap dropped the wrong end: first %s, last %s", all[0].ID, all[len(all)-1].ID)
	}
}

// The limits event id derives from the capture time: the same snapshot
// pushed twice — restarted host, retried batch — must land as one row,
// and a fresh probe must land as a new one.
func TestLimitsEventIdempotentPerCapture(t *testing.T) {
	captured := time.Date(2026, 7, 26, 14, 0, 0, 0, time.UTC)
	snap := UsageSnapshot{
		CapturedAt: captured,
		Windows: []UsageWindow{
			{Label: "session", Pct: 40, Resets: "6pm"},
			{Label: "week (all models)", Pct: 12, Resets: "Thu 9am"},
		},
	}

	ev := limitsEvent(snap)
	if !reflect.DeepEqual(ev, limitsEvent(snap)) {
		t.Errorf("same snapshot produced different events")
	}
	if ev.ID != fmt.Sprintf("limits-%d", captured.Unix()) || ev.Kind != "limits" || !ev.At.Equal(captured) {
		t.Errorf("event identity wrong: %+v", ev)
	}
	want := []cloud.LimitWindow{
		{Label: "session", Pct: 40, Resets: "6pm"},
		{Label: "week (all models)", Pct: 12, Resets: "Thu 9am"},
	}
	if !reflect.DeepEqual(ev.Windows, want) {
		t.Errorf("windows not verbatim:\n got %+v\nwant %+v", ev.Windows, want)
	}

	later := limitsEvent(UsageSnapshot{CapturedAt: captured.Add(time.Hour), Windows: snap.Windows})
	if later.ID == ev.ID {
		t.Errorf("a fresh capture must get a fresh id")
	}
}

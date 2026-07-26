package host

// The usage push: per-response Claude Code token counts and the
// subscription meters, batched up to rook-cloud on the status tick.
//
// Token events come from the transcript reader — the same seenMsg dedupe
// that keeps cost honest queues one event per API response, so the outbox
// inherits the ~2x-double-count fix for free. The outbox is telemetry, not
// a ledger: capped, oldest dropped, and requeued on a failed post rather
// than fsynced anywhere. What makes that safe to be casual about is the
// server's idempotency — events are named (message id, capture time), so
// a replayed backlog after a restart or a retried batch after a blip
// deduplicates instead of double-counting.

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/incantery/rook/internal/cloud"
	"github.com/incantery/rook/internal/transcript"
)

// usageOutboxCap bounds what a dead tunnel can accumulate. At one event
// per API response this is days of heavy use; past it the oldest events
// drop, which loses history, not correctness — the local cost ledger is
// unaffected and the server keeps what already arrived.
const usageOutboxCap = 2000

// enableUsagePush turns the outbox on. Called once from initCloud; without
// a cloud nothing would ever drain the queue, so it never fills.
func (a *agentWatch) enableUsagePush() {
	a.mu.Lock()
	a.usagePush = true
	a.mu.Unlock()
}

// queueUsageLocked appends one API response's tokens. Caller holds a.mu
// and has already deduped on message id — this runs once per response,
// backlog included. Backlog is wanted: replaying recent files after a
// restart re-queues events the server already has, and their ids make
// that a wash rather than a double-count.
//
// usd may be zero when the model wasn't in the price table; the tokens
// are the data and still travel. An id-less or token-less response has
// nothing meterable to say.
func (a *agentWatch) queueUsageLocked(m *transcript.Message, usd float64, at time.Time) {
	if !a.usagePush || m.ID == "" {
		return
	}
	u := m.Usage
	if u.InputTokens+u.OutputTokens+u.CacheReadTokens+u.CacheCreationTokens == 0 {
		return
	}
	a.usageOut = append(a.usageOut, cloud.UsageEvent{
		ID:                  m.ID,
		Kind:                cloud.UsageKindClaude,
		Model:               m.Model,
		At:                  at,
		InputTokens:         u.InputTokens,
		OutputTokens:        u.OutputTokens,
		CacheReadTokens:     u.CacheReadTokens,
		CacheCreationTokens: u.CacheCreationTokens,
		CostUSD:             usd,
	})
	if len(a.usageOut) > usageOutboxCap {
		a.usageOut = a.usageOut[len(a.usageOut)-usageOutboxCap:]
	}
}

// drainUsage removes and returns up to max events, oldest first.
func (a *agentWatch) drainUsage(max int) []cloud.UsageEvent {
	a.mu.Lock()
	defer a.mu.Unlock()
	n := min(max, len(a.usageOut))
	if n == 0 {
		return nil
	}
	out := make([]cloud.UsageEvent, n)
	copy(out, a.usageOut)
	a.usageOut = append(a.usageOut[:0], a.usageOut[n:]...)
	return out
}

// requeueUsage puts a failed batch back at the front, keeping the outbox
// oldest-first for the next tick. Overflow drops from the front — the
// requeued events are the oldest, and oldest is what the cap sacrifices.
func (a *agentWatch) requeueUsage(evs []cloud.UsageEvent) {
	if len(evs) == 0 {
		return
	}
	a.mu.Lock()
	a.usageOut = append(evs, a.usageOut...)
	if len(a.usageOut) > usageOutboxCap {
		a.usageOut = a.usageOut[len(a.usageOut)-usageOutboxCap:]
	}
	a.mu.Unlock()
}

// limitsEvent projects a probe snapshot into the wire shape. The id is
// derived from the capture time, so the same snapshot pushed twice — a
// restarted host, a retried batch — lands as one row.
func limitsEvent(snap UsageSnapshot) cloud.UsageEvent {
	ev := cloud.UsageEvent{
		ID:   fmt.Sprintf("limits-%d", snap.CapturedAt.Unix()),
		Kind: cloud.UsageKindLimits,
		At:   snap.CapturedAt,
	}
	for _, w := range snap.Windows {
		ev.Windows = append(ev.Windows, cloud.LimitWindow{
			Label: w.Label, Pct: w.Pct, Resets: w.Resets,
		})
	}
	return ev
}

// pushUsage sends one batch per status tick: whatever the outbox holds,
// plus the limits snapshot when the probe has a fresher one than the last
// that made it up. Failures requeue the token events and leave lastLimits
// alone — the limits event re-derives from the snapshot, so requeueing it
// too would only race a fresher capture.
func (h *Host) pushUsage(ctx context.Context, lastLimits *time.Time, failed *bool) {
	batch := h.aw.drainUsage(cloud.MaxUsageBatch - 1) // room for the limits event

	var limitsAt time.Time
	if snap := h.um.current(); len(snap.Windows) > 0 && snap.CapturedAt.After(*lastLimits) {
		batch = append(batch, limitsEvent(snap))
		limitsAt = snap.CapturedAt
	}
	if len(batch) == 0 {
		return
	}

	pctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	err := h.cloud.PostUsage(pctx, batch)
	cancel()
	if err != nil {
		// same one-line discipline as status: say it on the first failure,
		// then let the ticks retry quietly
		if !*failed {
			log.Printf("cloud: post usage: %v", err)
		}
		*failed = true
		if !limitsAt.IsZero() {
			batch = batch[:len(batch)-1]
		}
		h.aw.requeueUsage(batch)
		return
	}
	*failed = false
	if !limitsAt.IsZero() {
		*lastLimits = limitsAt
	}
}

package host

// The relay half of an ask: escalation out, decisions back in.
//
// An ask still fires locally and still opens a pane — that path is
// untouched. When a rook-server is configured the question ALSO goes to the
// mailbox, unconditionally, so walking away from the desk requires no
// gesture and no mode. Nothing buzzes yet, so an escalated ask nobody looks
// at costs nothing; when push lands, THAT is when the routing decision
// (pane / desktop notification / phone) has to get smart.
//
// Two directions, both dumb:
//
//   - out: publish on raise, retract on settle. Retract is what keeps the
//     phone trustworthy — a card for a question you answered at the desk
//     ten minutes ago teaches you to ignore the app.
//   - in: poll for answers while anything is outstanding, back off to
//     nothing when the mailbox is empty. An answer applies through exactly
//     the same settle path as the local pane's, so the two can never drift.

import (
	"context"
	"encoding/json"
	"log"
	"time"

	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/relay"
)

const (
	// while something is waiting: brisk enough that walking back to the
	// desk after answering on the phone finds the pane already closed
	relayPollBusy = 3 * time.Second
	// nothing outstanding — the loop still ticks so a decision made against
	// a card the host forgot about (restart) is eventually collected
	relayPollIdle = 60 * time.Second
)

// initRelay wires the configured rook-server, if any. Called from New;
// a nil client means every relay call site is inert.
func (h *Host) initRelay() {
	cfg := config.Load()
	if cfg.RelayURL == "" {
		return
	}
	c := relay.New(cfg.RelayURL, config.RelayToken())
	if c == nil {
		log.Printf("relay: %s configured but no token — run `rookctl set-relay-token`", cfg.RelayURL)
		return
	}
	h.relay = c
	log.Printf("relay: asks escalate to %s", c.Base())
	go h.runRelay(h.ctx)
}

// escalate publishes a freshly-raised ask to the mailbox. Best effort and
// off the request path: the local pane is the primary surface, and a
// mailbox that's down must never make asking fail.
func (h *Host) escalate(a *askState, id string, questions json.RawMessage) {
	if h.relay == nil {
		return
	}
	s := h.get(a.session)
	if s == nil {
		return
	}
	// the workspace name is the only context the phone gets about why it's
	// being asked — enough to know which of several agents is talking
	ws := s.info.Workspace
	go func() {
		ctx, cancel := context.WithTimeout(h.ctx, 20*time.Second)
		defer cancel()
		err := h.relay.Publish(ctx, relay.Ask{
			ID: id, Session: a.session, Workspace: ws, Title: ws, Questions: questions,
		})
		if err != nil {
			log.Printf("relay: publish %s: %v", id, err)
			return
		}
		h.askMu.Lock()
		if st, ok := h.asks[id]; ok {
			st.escalated = true
		}
		h.askMu.Unlock()
	}()
}

// withdraw pulls a settled ask off the mailbox. Only for asks we actually
// escalated, and only when the decision came from somewhere else — an
// answer that arrived THROUGH the relay was already consumed by the drain.
func (h *Host) withdraw(id string) {
	if h.relay == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(h.ctx, 20*time.Second)
		defer cancel()
		if err := h.relay.Retract(ctx, id); err != nil {
			log.Printf("relay: retract %s: %v", id, err)
		}
	}()
}

// outstanding reports whether anything is escalated and still undecided —
// the only condition under which polling is worth the request.
func (h *Host) outstanding() bool {
	h.askMu.Lock()
	defer h.askMu.Unlock()
	for _, a := range h.asks {
		if a.escalated && !a.done {
			return true
		}
	}
	return false
}

// runRelay is the answer poll. Not a real-time system on purpose: this
// exists to unstall work that would otherwise wait for you to walk back to
// the desk, so seconds are fine and a persistent connection would be a
// standing cost for a rare event.
func (h *Host) runRelay(ctx context.Context) {
	for {
		wait := relayPollIdle
		if h.outstanding() {
			wait = relayPollBusy
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
		pctx, cancel := context.WithTimeout(ctx, 20*time.Second)
		answered, err := h.relay.Drain(pctx)
		cancel()
		if err != nil {
			// offline, asleep, tunnel down — the next tick tries again
			continue
		}
		for _, a := range answered {
			h.applyRemoteAnswer(a.AskID, a.Answer)
		}
	}
}

// applyRemoteAnswer settles an ask decided on another surface. It routes
// through settleAsk, the same function the app's own POST uses, so a phone
// answer and a desk answer are literally the same event — including the
// doorbell that tells the agent to collect it.
func (h *Host) applyRemoteAnswer(id string, answer json.RawMessage) {
	if len(answer) == 0 {
		return
	}
	switch h.settleAsk(id, answer, sourceRelay) {
	case settledOK:
		log.Printf("relay: %s answered away from the desk", id)
	case settledUnknown:
		// answered against a card this host has forgotten (restart, or a
		// sweep). Nothing to deliver it to; dropping it is the honest
		// outcome, and the agent is still parked on its own drain.
		log.Printf("relay: %s is not an ask this host is holding — dropped", id)
	case settledAlready:
		// the desk won the race; the mailbox just hadn't been told yet
	}
}

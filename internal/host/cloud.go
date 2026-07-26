package host

// The cloud half of "what is going on on my machines": a snapshot of the
// overview, POSTed on a timer. Same picture the deck renders, sent to the
// same place asks already escalate to — one assembly (overviewItems), two
// consumers, no drift between the desk and the phone.
//
// Deliberately snapshot-shaped, not event-shaped. Last write wins on the
// server, so a missed tick costs staleness the next tick repairs, a retry
// can never corrupt anything, and there is no outbox to maintain. The
// cadence is the only cleverness allowed here: brisk while agents are
// doing something worth watching, slow when the machine is quiet — the
// idle steady state is a heartbeat, not a stream.
//
// What goes up is a decided line (see cloud.Status): workspace names,
// branches, agent states, titles, and pending ask text. Foreground
// commands, terminal contents, and file paths stay home.

import (
	"context"
	"log"
	"os"
	"time"

	"github.com/incantery/rook/internal/cloud"
	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/version"
)

const (
	// Something live: keep the picture current, but not live-current. The
	// ALERT path is not this one — a raised ask escalates to the mailbox
	// the instant it is raised (relay.go escalate), so a phone learns about
	// needs_input without waiting for a tick. What this cadence buys is the
	// ambient picture around that alert, and a glance-at-it surface does
	// not need it fresher than a minute. Every tick costs a git probe per
	// live workspace, indefinitely, whether or not anyone is looking.
	cloudTickBusy = 60 * time.Second
	// nothing live: the post is a heartbeat that keeps "online" honest
	cloudTickIdle = 2 * time.Minute
)

// initCloud wires the configured rook-cloud, if any. Called from New; a
// nil client means every cloud call site is inert.
func (h *Host) initCloud() {
	cfg := config.Load()
	if cfg.CloudURL == "" {
		return
	}
	c := cloud.New(cfg.CloudURL, config.CloudToken())
	if c == nil {
		log.Printf("cloud: %s configured but no token — run `rookctl set-cloud-token`", cfg.CloudURL)
		return
	}
	h.cloud = c
	log.Printf("cloud: status reports to %s", c.Base())
	// From here on the transcript reader queues per-response token counts
	// for the push. Records reduced before this line aren't queued — they
	// are at most a few, and the next backlog replay re-offers them.
	h.aw.enableUsagePush()
	go h.runCloud(h.ctx)
}

// runCloud posts the snapshot forever. Errors are swallowed and retried on
// the next tick — offline, asleep, tunnel down — with one exception worth
// a log line each time: the first failure after a success, so a revoked
// token says so once rather than never or every 15 seconds.
func (h *Host) runCloud(ctx context.Context) {
	hostname, _ := os.Hostname()

	// Say which machine this token is FOR, once, before any status goes up.
	// A token pasted from the wrong machine's "Add machine" dialog is the
	// failure that otherwise looks like success: posts return 200 and land
	// on somebody else's row. Not fatal, not retried — the reports work
	// regardless, and this is the line you go looking for when they land
	// somewhere surprising.
	wctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	if id, name, err := h.cloud.Whoami(wctx); err == nil {
		log.Printf("cloud: machine %s (%s)", name, id)
	}
	cancel()

	failed := false
	// usage rides the status tick: lastLimits is the newest snapshot that
	// made it up, usageFailed keeps its log line to first-failure-only.
	var lastLimits time.Time
	usageFailed := false
	for {
		st := h.cloudSnapshot(hostname)

		pctx, cancel := context.WithTimeout(ctx, 20*time.Second)
		err := h.cloud.PostStatus(pctx, st)
		cancel()
		if err != nil {
			if !failed {
				log.Printf("cloud: post status: %v", err)
			}
			failed = true
		} else {
			failed = false
		}

		h.pushUsage(ctx, &lastLimits, &usageFailed)

		wait := cloudTickIdle
		if busy(st) {
			wait = cloudTickBusy
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
	}
}

// busy reports whether the snapshot shows anything worth a brisk cadence —
// an agent working, or one waiting on a human who might be watching the
// dashboard rather than the desk.
func busy(st cloud.Status) bool {
	for _, ws := range st.Workspaces {
		for _, a := range ws.Agents {
			if a.State == "working" || a.State == "needs_input" {
				return true
			}
		}
	}
	return false
}

// cloudSnapshot reads the machine's live picture and projects it.
func (h *Host) cloudSnapshot(hostname string) cloud.Status {
	return cloudProject(hostname, version.Version, h.overviewItems())
}

// cloudProject turns overview items into the wire shape. Workspaces with no
// live sessions are omitted — an idle registry entry is not "going on", and
// leaving it out is also what keeps the payload small on machines with long
// workspace lists.
//
// Split from the read so it can be tested: this function IS the privacy
// line. Everything it copies leaves the machine, and everything it declines
// to copy — Fg, the foreground commands — stays home. A field quietly added
// here is a field quietly published, so the test states the whole set.
func cloudProject(hostname, ver string, items []overviewItem) cloud.Status {
	st := cloud.Status{
		Hostname:    hostname,
		RookVersion: ver,
	}
	for _, it := range items {
		if it.Sessions == 0 && len(it.Agents) == 0 {
			continue
		}
		ws := cloud.Workspace{Name: it.Name, Attention: it.Attention}
		if it.Git != nil {
			ws.Branch = it.Git.Branch
		}
		for _, a := range it.Agents {
			ws.Agents = append(ws.Agents, cloud.Agent{
				State:     a.State,
				Title:     a.Title,
				Ask:       a.Ask,
				Model:     a.Model,
				CostUSD:   a.CostUSD,
				LastEvent: a.LastEvent,
			})
		}
		st.Workspaces = append(st.Workspaces, ws)
	}
	return st
}

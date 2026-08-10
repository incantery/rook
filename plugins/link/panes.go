// The pane streamer — the plugin half of WatchPane. The link server
// tells us when a session gains its first watcher (Open) and loses its
// last (Close); in between, a goroutine per watched session polls the
// substrate cheaply (panes.activity, the same call the status loop
// makes) and pulls the expensive verb (pane.read, a whole styled grid)
// ONLY when the pane's output counter moved — an etag, so an idle pane
// costs activity polls and nothing more.
//
// The session id is the phone's only handle. It resolves to a pane per
// tick by the SAME heuristic the executor delivers by (findPane on the
// session's cwd) — and a tick that cannot resolve one publishes
// nothing rather than closing anything: panes move, sessions restart,
// and the stream's heartbeats carry the gap.
package main

import (
	"context"
	"encoding/json"
	"time"

	"github.com/incantery/rook-host/projection"
)

const (
	// paneTick is the activity-poll cadence while watched — the frame
	// rate ceiling. panes.activity is a few hundred bytes; pane.read
	// only fires when the etag moved.
	paneTick = 200 * time.Millisecond
	// paneFailBackoff stretches the tick after a failed pane.read, per
	// consecutive failure, so a wedged substrate is asked at a walking
	// pace instead of five times a second.
	paneFailBackoff = 500 * time.Millisecond
	paneMaxBackoff  = 5 * time.Second
)

// Open starts streaming frames for sessionID. Called by the link
// server's hub under its lock — so the work leaves this stack
// immediately, and PublishPane is only ever called from the spawned
// goroutine.
func (h *lk) Open(sessionID string) error {
	h.paneMu.Lock()
	defer h.paneMu.Unlock()
	if h.paneWatch == nil {
		h.paneWatch = map[string]context.CancelFunc{}
	}
	if _, ok := h.paneWatch[sessionID]; ok {
		return nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	h.paneWatch[sessionID] = cancel
	go h.streamPane(ctx, sessionID)
	return nil
}

// Close stops the session's streamer. Idempotent, like the hub's edge.
func (h *lk) Close(sessionID string) {
	h.paneMu.Lock()
	cancel := h.paneWatch[sessionID]
	delete(h.paneWatch, sessionID)
	h.paneMu.Unlock()
	if cancel != nil {
		cancel()
	}
}

// paneReadReply is pane.read's wire shape: a display-ready grid, colors
// already resolved by the emulator. `gen` echoes the session's total
// output bytes — the etag the next poll compares against.
type paneReadReply struct {
	Pane   int    `json:"pane"`
	Cols   int    `json:"cols"`
	Rows   int    `json:"rows"`
	Gen    uint64 `json:"gen"`
	Cursor struct {
		X       int  `json:"x"`
		Y       int  `json:"y"`
		Visible bool `json:"visible"`
	} `json:"cursor"`
	Lines []struct {
		T string      `json:"t"`
		S [][5]uint32 `json:"s"`
	} `json:"lines"`
}

func (h *lk) streamPane(ctx context.Context, sessionID string) {
	var lastPane = -1
	var lastGen uint64
	sent := false
	fails := 0
	for {
		wait := paneTick
		if fails > 0 {
			backoff := time.Duration(fails) * paneFailBackoff
			if backoff > paneMaxBackoff {
				backoff = paneMaxBackoff
			}
			wait += backoff
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}

		// Session → cwd from the loop's world; cwd → pane from a FRESH
		// activity poll (the world's copy is a heartbeat old — useless
		// as an etag). A miss on either is a gap, never an end.
		sessions, _ := h.snapshot()
		target := findSession(sessions, sessionID)
		if target == nil {
			continue
		}
		panes := fetchActivity(h.c)
		pane := findPane(panes, target.Cwd, h.names)
		if pane == nil {
			continue
		}
		// The etag gate: first frame, the pane moved, or output moved.
		if sent && pane.ID == lastPane && pane.OutBytes == lastGen {
			continue
		}

		raw, err := h.c.call("pane.read", map[string]any{"pane": pane.ID}, 1500*time.Millisecond)
		if err != nil {
			fails++
			continue
		}
		var rep paneReadReply
		if json.Unmarshal(raw, &rep) != nil {
			fails++
			continue
		}
		fails = 0
		h.pubPane(sessionID, paneFrame(&rep))
		sent = true
		lastPane = pane.ID
		lastGen = rep.Gen
	}
}

// paneFrame converts the wire reply to the projection's value type —
// the shape the hub clamps and the server converts to proto.
func paneFrame(rep *paneReadReply) projection.PaneFrame {
	f := projection.PaneFrame{
		Cols:          rep.Cols,
		Rows:          rep.Rows,
		CursorX:       rep.Cursor.X,
		CursorY:       rep.Cursor.Y,
		CursorVisible: rep.Cursor.Visible,
	}
	for _, l := range rep.Lines {
		row := projection.PaneRow{Text: l.T}
		for _, r := range l.S {
			row.Runs = append(row.Runs, projection.StyleRun{
				Start: r[0], Len: r[1], FG: r[2], BG: r[3], Attrs: r[4],
			})
		}
		f.Lines = append(f.Lines, row)
	}
	return f
}

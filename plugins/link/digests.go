package main

import (
	"time"

	"github.com/incantery/rook-host/projection"

	"github.com/incantery/rook/plugins/internal/digestlog"
)

// Digest implements link.DigestSource: the newest presentable digest
// for one session, read fresh from the shared journal the agent plugin
// writes. Fresh on every call, deliberately — GetDigest fires when a
// human taps "full reply", which is rare enough that re-reading the
// journal costs nothing and caching would only add a staleness bug.
func (h *lk) Digest(sessionID string) (projection.Digest, bool) {
	if h.digestLog == "" {
		return projection.Digest{}, false
	}
	latest := digestlog.Latest(digestlog.Load(h.digestLog, h.sc.Window, time.Now()))
	d, ok := latest[sessionID]
	if !ok {
		return projection.Digest{}, false
	}
	return projection.Digest{
		ID:         d.ID,
		SessionID:  d.SessionID,
		Headline:   d.Headline,
		Bullets:    d.Bullets,
		FullText:   d.FullText,
		Prompt:     d.Prompt,
		Reply:      d.Reply,
		ReplyState: d.ReplyState,
		At:         d.At,
		Model:      d.Model,
		CostUSD:    d.CostUSD,
	}, true
}

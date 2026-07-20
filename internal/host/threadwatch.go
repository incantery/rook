package host

import (
	"fmt"
	"net/http"
	"sync"
	"time"
)

// The thread change channel — rook's first push surface that isn't a pty.
//
// Every thread mutation used to write SQLite and return, with nothing
// announcing it. The cost was concrete and user-visible: the frontend
// refetched threads only when an editor pane regained focus, so you could ask
// the agent a question, watch it answer in its own window, and rook would
// still be showing you your own comment alone. The daemon knew; nobody told
// the UI.
//
// Both consumers want the identical signal — the webview, and the LSP bridge
// that has to call publishDiagnostics when a comment appears
// (docs/superpowers/specs/2026-07-20-comments-lsp-design.md).
//
// The event carries NO PAYLOAD. Subscribers refetch through the normal
// endpoint, which re-anchors ranges on read; shipping a ThreadInfo here would
// duplicate that serialization and could hand a reader a range it would
// recompute anyway. "Something changed, go look" is the honest signal.
type threadWatch struct {
	mu   sync.Mutex
	subs map[string]map[chan struct{}]struct{} // workspace → subscribers
}

func newThreadWatch() *threadWatch {
	return &threadWatch{subs: map[string]map[chan struct{}]struct{}{}}
}

func (tw *threadWatch) subscribe(ws string) chan struct{} {
	tw.mu.Lock()
	defer tw.mu.Unlock()
	if tw.subs[ws] == nil {
		tw.subs[ws] = map[chan struct{}]struct{}{}
	}
	ch := make(chan struct{}, 1)
	tw.subs[ws][ch] = struct{}{}
	return ch
}

func (tw *threadWatch) unsubscribe(ws string, ch chan struct{}) {
	tw.mu.Lock()
	defer tw.mu.Unlock()
	if m := tw.subs[ws]; m != nil {
		delete(m, ch)
		if len(m) == 0 {
			delete(tw.subs, ws)
		}
	}
}

// notify wakes every watcher of ws. The send is non-blocking onto a buffered
// channel: a subscriber that hasn't drained yet already has a wake-up
// pending, and COALESCING is correct here precisely because the event has no
// payload — two changes collapse into one refetch that reads current state.
func (tw *threadWatch) notify(ws string) {
	if tw == nil || ws == "" {
		return
	}
	tw.mu.Lock()
	defer tw.mu.Unlock()
	for ch := range tw.subs[ws] {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

// notifyThreads announces a change in ws. Nil-safe on the Host's watch so a
// hand-built Host in tests needs no extra wiring.
func (h *Host) notifyThreads(ws string) { h.tw.notify(ws) }

// notifyThreadsFor announces a change to whichever workspace owns a thread —
// the per-thread routes are global (`rookctl reply 12` works from anywhere),
// so the workspace has to be looked up rather than parsed from the path.
func (h *Host) notifyThreadsFor(id int64) {
	if t := h.reg.getThread(id); t != nil {
		h.notifyThreads(t.Workspace)
	}
}

// handleThreadsWatch is GET /workspaces/{name}/threads/watch: server-sent
// events, one `threads` event per change.
//
// SSE rather than a WebSocket because the traffic is one-way and a browser
// EventSource reconnects on its own — a daemon restart heals without any
// client-side retry logic. The bearer token rides the query string, since
// EventSource cannot set headers; that is the same door the pty WebSocket
// already uses (hostapi.attach) on a loopback-only server.
func (h *Host) handleThreadsWatch(w http.ResponseWriter, r *http.Request, name string) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	if h.tw == nil {
		h.tw = newThreadWatch()
	}
	ch := h.tw.subscribe(name)
	defer h.tw.unsubscribe(name, ch)

	// tell the client it's live before anything happens, so a subscriber can
	// distinguish "connected, nothing yet" from "still connecting"
	fmt.Fprint(w, ": ok\n\n")
	flusher.Flush()

	// A comment line every 25s keeps intermediaries and idle-socket reapers
	// from closing a stream that is legitimately quiet — a review session can
	// sit untouched for a long time between comments.
	ping := time.NewTicker(25 * time.Second)
	defer ping.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-ch:
			fmt.Fprint(w, "event: threads\ndata: 1\n\n")
			flusher.Flush()
		case <-ping.C:
			fmt.Fprint(w, ": ping\n\n")
			flusher.Flush()
		}
	}
}

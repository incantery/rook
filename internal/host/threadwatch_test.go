package host

import (
	"bufio"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func (tw *threadWatch) count(ws string) int {
	tw.mu.Lock()
	defer tw.mu.Unlock()
	return len(tw.subs[ws])
}

func TestThreadWatchFansOutAndCoalesces(t *testing.T) {
	tw := newThreadWatch()
	a, b := tw.subscribe("ws"), tw.subscribe("ws")
	other := tw.subscribe("elsewhere")

	tw.notify("ws")
	for _, ch := range []chan struct{}{a, b} {
		select {
		case <-ch:
		default:
			t.Fatal("subscriber not woken")
		}
	}
	select {
	case <-other:
		t.Fatal("woke a watcher of a different workspace")
	default:
	}

	// Two changes with nothing drained collapse into ONE wake-up. That's
	// correct precisely because the event has no payload: the subscriber
	// refetches current state, so a second notification would buy nothing —
	// and a blocking send here would stall the mutating HTTP handler.
	tw.notify("ws")
	tw.notify("ws")
	<-a
	select {
	case <-a:
		t.Fatal("notifications queued instead of coalescing")
	default:
	}

	tw.unsubscribe("ws", a)
	if got := tw.count("ws"); got != 1 {
		t.Fatalf("after unsubscribe: %d watchers", got)
	}
	tw.unsubscribe("ws", b)
	if got := tw.count("ws"); got != 0 {
		t.Fatalf("workspace not reaped: %d watchers", got)
	}
}

// notify must be safe on a Host that never built a watch — tests construct
// Host literally, and a nil channel must not take a mutation handler down.
func TestNotifyThreadsNilSafe(t *testing.T) {
	h := &Host{}
	h.notifyThreads("ws") // must not panic
}

func TestThreadWatchStreamsOverSSE(t *testing.T) {
	h := &Host{tw: newThreadWatch()}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.handleThreadsWatch(w, r, "ws")
	}))
	defer srv.Close()

	resp, err := http.Get(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("content-type: %q", ct)
	}

	lines := make(chan string, 8)
	go func() {
		br := bufio.NewReader(resp.Body)
		for {
			l, err := br.ReadString('\n')
			if err != nil {
				return
			}
			lines <- l
		}
	}()

	read := func(what string) string {
		t.Helper()
		select {
		case l := <-lines:
			return l
		case <-time.After(5 * time.Second):
			t.Fatalf("timed out waiting for %s", what)
			return ""
		}
	}

	// The ": ok" preamble is what makes this test deterministic: it can only
	// be written after subscribe(), so receiving it proves the notify below
	// cannot be lost to a not-yet-registered watcher.
	if l := read("preamble"); !strings.HasPrefix(l, ": ok") {
		t.Fatalf("preamble: %q", l)
	}
	read("preamble blank line")

	h.tw.notify("ws")
	if l := read("event"); !strings.HasPrefix(l, "event: threads") {
		t.Fatalf("event line: %q", l)
	}
	if l := read("data"); !strings.HasPrefix(l, "data:") {
		t.Fatalf("data line: %q", l)
	}

	// closing the client must reap the subscription, or a long session leaks
	// a goroutine and a channel per pane open
	resp.Body.Close()
	deadline := time.Now().Add(5 * time.Second)
	for h.tw.count("ws") != 0 {
		if time.Now().After(deadline) {
			t.Fatal("subscription not reaped after client disconnect")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

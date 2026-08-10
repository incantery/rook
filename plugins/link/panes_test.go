package main

import (
	"bufio"
	"encoding/json"
	"io"
	"sync/atomic"
	"testing"
	"time"

	"github.com/incantery/rook-host/projection"

	"github.com/incantery/rook/plugins/internal/transcript"
)

// fakeRook answers the plugin's calls the way the app would: a
// goroutine on the far end of the conn's pipe, one handler per op.
func fakeRook(t *testing.T, handler func(op string, params json.RawMessage) (any, string)) *conn {
	t.Helper()
	pr, pw := io.Pipe()
	c := &conn{out: pw}
	t.Cleanup(func() { pr.Close() })
	go func() {
		sc := bufio.NewScanner(pr)
		sc.Buffer(make([]byte, 64*1024), 2*1024*1024)
		for sc.Scan() {
			var req struct {
				ID     uint64          `json:"id"`
				Op     string          `json:"op"`
				Params json.RawMessage `json:"params"`
			}
			if json.Unmarshal(sc.Bytes(), &req) != nil || req.Op == "" {
				continue
			}
			res, errText := handler(req.Op, req.Params)
			if errText != "" {
				c.deliver(req.ID, false, errText, nil)
				continue
			}
			raw, _ := json.Marshal(res)
			c.deliver(req.ID, true, "", raw)
		}
	}()
	return c
}

// The streamer's contract: the first frame goes up unconditionally,
// a static outBytes is an etag hit (no pane.read at all), movement
// publishes again, and Close stops the loop.
func TestPaneStreamerEtagGateAndPublishOnChange(t *testing.T) {
	var outBytes atomic.Uint64
	outBytes.Store(100)
	var paneReads atomic.Int64

	c := fakeRook(t, func(op string, params json.RawMessage) (any, string) {
		switch op {
		case "panes.activity":
			return map[string]any{"panes": []map[string]any{{
				"id": 7, "outMs": 10, "inMs": -1, "outBytes": outBytes.Load(),
				"fg": "claude", "path": "/usr/local/bin/claude", "cwd": "/w/a",
			}}}, ""
		case "pane.read":
			var p struct {
				Pane int `json:"pane"`
			}
			if json.Unmarshal(params, &p) != nil || p.Pane != 7 {
				return nil, "no such pane"
			}
			paneReads.Add(1)
			return map[string]any{
				"pane": 7, "cols": 4, "rows": 1, "gen": outBytes.Load(),
				"cursor": map[string]any{"x": 2, "y": 0, "visible": true},
				"lines": []map[string]any{{
					"t": "hi",
					"s": [][]uint32{{0, 2, 0xFFFFFF, 0x102030, 1}, {2, 2, 0xAAAAAA, 0x102030, 0}},
				}},
			}, ""
		}
		return nil, "unknown op " + op
	})

	frames := make(chan projection.PaneFrame, 8)
	h := testLk(t, []transcript.Session{
		{ID: "s1", Cwd: "/w/a", State: transcript.StateWorking},
	}, nil)
	h.c = c
	h.pubPane = func(sessionID string, f projection.PaneFrame) {
		if sessionID != "s1" {
			t.Errorf("frame published for %q, want s1", sessionID)
		}
		frames <- f
	}

	if err := h.Open("s1"); err != nil {
		t.Fatal(err)
	}
	defer h.Close("s1")

	// The first frame needs no movement — "no frame sent yet" is its
	// own reason.
	var first projection.PaneFrame
	select {
	case first = <-frames:
	case <-time.After(5 * time.Second):
		t.Fatal("no first frame")
	}
	if first.Cols != 4 || first.Rows != 1 || first.CursorX != 2 || !first.CursorVisible {
		t.Fatalf("frame mangled: %+v", first)
	}
	if len(first.Lines) != 1 || first.Lines[0].Text != "hi" ||
		len(first.Lines[0].Runs) != 2 ||
		first.Lines[0].Runs[0] != (projection.StyleRun{Start: 0, Len: 2, FG: 0xFFFFFF, BG: 0x102030, Attrs: 1}) {
		t.Fatalf("row mangled: %+v", first.Lines)
	}

	// Static outBytes: several ticks pass, pane.read is never asked.
	before := paneReads.Load()
	time.Sleep(4 * paneTick)
	if got := paneReads.Load(); got != before {
		t.Fatalf("etag gate leaked: %d pane.reads while nothing moved (was %d)", got, before)
	}
	select {
	case f := <-frames:
		t.Fatalf("frame published while nothing moved: %+v", f)
	default:
	}

	// Movement publishes again.
	outBytes.Store(250)
	select {
	case <-frames:
	case <-time.After(5 * time.Second):
		t.Fatal("no frame after output moved")
	}

	// Close stops the loop: movement after it publishes nothing.
	h.Close("s1")
	time.Sleep(2 * paneTick)
	outBytes.Store(400)
	time.Sleep(4 * paneTick)
	select {
	case f := <-frames:
		t.Fatalf("frame published after Close: %+v", f)
	default:
	}
}

// A session whose pane cannot be resolved publishes nothing and calls
// nothing expensive — the gap is the stream's heartbeats, not an error.
func TestPaneStreamerUnresolvableSessionIsAGap(t *testing.T) {
	var paneReads atomic.Int64
	c := fakeRook(t, func(op string, params json.RawMessage) (any, string) {
		if op == "panes.activity" {
			// A pane in the wrong directory: findPane must not take it.
			return map[string]any{"panes": []map[string]any{{
				"id": 9, "outMs": 10, "inMs": -1, "outBytes": 50,
				"fg": "claude", "path": "/usr/local/bin/claude", "cwd": "/somewhere/else",
			}}}, ""
		}
		paneReads.Add(1)
		return nil, "should not be called"
	})

	h := testLk(t, []transcript.Session{
		{ID: "s1", Cwd: "/w/a", State: transcript.StateWorking},
	}, nil)
	h.c = c
	h.pubPane = func(string, projection.PaneFrame) { t.Error("published a frame with no pane") }

	if err := h.Open("s1"); err != nil {
		t.Fatal(err)
	}
	defer h.Close("s1")
	time.Sleep(4 * paneTick)
	if paneReads.Load() != 0 {
		t.Fatal("pane.read called for an unresolvable session")
	}
}

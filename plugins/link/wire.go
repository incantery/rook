// The stdio wire — the plugin protocol of rook-plugin(7). This is the
// cloud plugin's conn, copied again (the fourth copy; the wire package
// this argues for is still owed).
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"os"
	"sync"
	"time"

	"github.com/incantery/rook/plugins/internal/transcript"
)

type conn struct {
	mu      sync.Mutex
	out     io.Writer
	nextID  uint64
	pending map[uint64]chan callResult
}

type callResult struct {
	ok  bool
	err string
	raw json.RawMessage
}

func (c *conn) send(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.out.Write(append(b, '\n'))
}

type reply struct {
	V      int    `json:"v"`
	ID     uint64 `json:"id"`
	OK     bool   `json:"ok"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

type request struct {
	V      int    `json:"v"`
	ID     uint64 `json:"id"`
	Op     string `json:"op"`
	Params any    `json:"params"`
}

// call asks rook and waits. MUST NOT run on the serve goroutine —
// serve is what delivers the reply.
func (c *conn) call(op string, params any, timeout time.Duration) (json.RawMessage, error) {
	ch := make(chan callResult, 1)
	c.mu.Lock()
	c.nextID++
	id := c.nextID
	if c.pending == nil {
		c.pending = map[uint64]chan callResult{}
	}
	c.pending[id] = ch
	c.mu.Unlock()
	c.send(request{1, id, op, params})
	select {
	case r := <-ch:
		if !r.ok {
			return nil, errors.New(r.err)
		}
		return r.raw, nil
	case <-time.After(timeout):
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return nil, errors.New("timeout: " + op)
	}
}

func (c *conn) deliver(id uint64, ok bool, errText string, raw json.RawMessage) {
	c.mu.Lock()
	ch := c.pending[id]
	delete(c.pending, id)
	c.mu.Unlock()
	if ch != nil {
		ch <- callResult{ok, errText, raw}
	}
}

// serve answers rook until stdin closes, which is how a plugin ends.
func serve(c *conn, h *lk) {
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 64*1024), 2*1024*1024)
	for in.Scan() {
		var req struct {
			ID     uint64          `json:"id"`
			Op     string          `json:"op"`
			Params json.RawMessage `json:"params"`
		}
		if json.Unmarshal(in.Bytes(), &req) != nil {
			continue
		}
		if req.Op == "" {
			var rep struct {
				ID     uint64          `json:"id"`
				OK     bool            `json:"ok"`
				Error  string          `json:"error"`
				Result json.RawMessage `json:"result"`
			}
			if json.Unmarshal(in.Bytes(), &rep) == nil {
				c.deliver(rep.ID, rep.OK, rep.Error, rep.Result)
			}
			continue
		}
		switch req.Op {
		case "describe":
			c.send(reply{1, req.ID, true, map[string]any{
				"name":    "link",
				"version": version,
				"capabilities": []string{
					"items.list", "items.act", "panes.activity", "pane.read",
					"session.send", "session.spawn", "clipboard.set",
				},
				"surfaces": []string{"LIST"},
			}, ""})
		case "items.list":
			c.send(reply{1, req.ID, true, map[string]any{
				"items":     items(h, time.Now()),
				"truncated": false,
			}, ""})
		case "items.act":
			c.send(act(h, req.ID, req.Params))
		default:
			c.send(reply{1, req.ID, false, nil, "link does not do " + req.Op})
		}
	}
}

// fetchActivity asks rook who is redrawing and who is typing — the
// same degradation story as the cloud bridge: refusal or timeout means
// the transcript's word stands alone.
func fetchActivity(c *conn) []transcript.PaneActivity {
	raw, err := c.call("panes.activity", struct{}{}, 1500*time.Millisecond)
	if err != nil {
		return nil
	}
	var rep struct {
		Panes []transcript.PaneActivity `json:"panes"`
	}
	if json.Unmarshal(raw, &rep) != nil {
		return nil
	}
	return rep.Panes
}

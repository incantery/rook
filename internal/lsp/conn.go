// Package lsp is rook's hand-rolled LSP client: JSON-RPC 2.0 over stdio
// with Content-Length framing, the initialize handshake, full-text document
// sync, and the three exploration queries (definition, references, hover).
// ~200 lines of protocol instead of a dependency — the host is the only
// speaker; everything else sees rook-shaped HTTP.
package lsp

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
)

type message struct {
	JSONRPC string `json:"jsonrpc"`
	// ID is raw so a server-initiated request's id (number or string)
	// echoes back byte-exact in our response.
	ID     json.RawMessage `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *respError      `json:"error,omitempty"`
}

type respError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *respError) Error() string { return fmt.Sprintf("lsp: %s (%d)", e.Message, e.Code) }

const codeMethodNotFound = -32601

// conn speaks framed JSON-RPC on a server's stdio. One writer mutex, one
// reader goroutine; responses route to pending calls by id, server→client
// requests go to handle, notifications are dropped (diagnostics are a
// deferred seam).
type conn struct {
	wmu    sync.Mutex
	w      *bufio.Writer
	nextID atomic.Int64

	mu      sync.Mutex
	pending map[int64]chan *message
	closed  bool

	// handle answers a server→client request; nil result with nil error
	// encodes `"result": null`.
	handle func(method string, params json.RawMessage) (any, error)
}

func newConn(w io.Writer, r io.Reader, handle func(string, json.RawMessage) (any, error)) *conn {
	c := &conn{w: bufio.NewWriter(w), pending: map[int64]chan *message{}, handle: handle}
	go c.readLoop(bufio.NewReader(r))
	return c
}

func (c *conn) writeMsg(m message) error {
	m.JSONRPC = "2.0"
	body, err := json.Marshal(m)
	if err != nil {
		return err
	}
	c.wmu.Lock()
	defer c.wmu.Unlock()
	if _, err := fmt.Fprintf(c.w, "Content-Length: %d\r\n\r\n", len(body)); err != nil {
		return err
	}
	if _, err := c.w.Write(body); err != nil {
		return err
	}
	return c.w.Flush()
}

// call sends a request and hands back the channel its response will land
// on. The caller owns timeout policy (select on done/ctx).
func (c *conn) call(method string, params any) (<-chan *message, error) {
	id := c.nextID.Add(1)
	raw, err := marshalParams(params)
	if err != nil {
		return nil, err
	}
	ch := make(chan *message, 1)
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil, fmt.Errorf("lsp: connection closed")
	}
	c.pending[id] = ch
	c.mu.Unlock()
	idRaw, _ := json.Marshal(id)
	if err := c.writeMsg(message{ID: idRaw, Method: method, Params: raw}); err != nil {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return nil, err
	}
	return ch, nil
}

func (c *conn) notify(method string, params any) error {
	raw, err := marshalParams(params)
	if err != nil {
		return err
	}
	return c.writeMsg(message{Method: method, Params: raw})
}

func marshalParams(params any) (json.RawMessage, error) {
	if params == nil {
		return nil, nil
	}
	return json.Marshal(params)
}

func (c *conn) readLoop(r *bufio.Reader) {
	defer c.shutdownPending()
	for {
		m, err := readMsg(r)
		if err != nil {
			return // EOF or a framing error: the server side is gone
		}
		switch {
		case m.Method != "" && m.ID != nil: // server→client request
			result, herr := c.handleOr404(m.Method, m.Params)
			resp := message{ID: m.ID}
			if herr != nil {
				resp.Error = &respError{Code: codeMethodNotFound, Message: herr.Error()}
			} else {
				raw, err := json.Marshal(result)
				if err != nil {
					raw = []byte("null")
				}
				resp.Result = raw
			}
			c.writeMsg(resp)
		case m.ID != nil: // response to one of ours
			var id int64
			if json.Unmarshal(m.ID, &id) != nil {
				continue
			}
			c.mu.Lock()
			ch := c.pending[id]
			delete(c.pending, id)
			c.mu.Unlock()
			if ch != nil {
				ch <- m
			}
		default: // notification — dropped (diagnostics are a deferred seam)
		}
	}
}

func (c *conn) handleOr404(method string, params json.RawMessage) (any, error) {
	if c.handle == nil {
		return nil, fmt.Errorf("unhandled method %s", method)
	}
	return c.handle(method, params)
}

// shutdownPending fails every in-flight call when the read side dies, so
// callers waiting on a crashed server error once instead of hanging.
func (c *conn) shutdownPending() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closed = true
	for id, ch := range c.pending {
		ch <- &message{Error: &respError{Message: "server exited"}}
		delete(c.pending, id)
	}
}

func readMsg(r *bufio.Reader) (*message, error) {
	length := -1
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return nil, err
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break // end of headers
		}
		if v, ok := strings.CutPrefix(line, "Content-Length:"); ok {
			if length, err = strconv.Atoi(strings.TrimSpace(v)); err != nil {
				return nil, fmt.Errorf("lsp: bad Content-Length %q", v)
			}
		}
	}
	if length < 0 {
		return nil, fmt.Errorf("lsp: missing Content-Length")
	}
	body := make([]byte, length)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, err
	}
	var m message
	if err := json.Unmarshal(body, &m); err != nil {
		return nil, err
	}
	return &m, nil
}

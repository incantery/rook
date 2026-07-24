// Package relay talks to a rook-server — the mailbox that carries an
// escalated ask to whatever screen the human is near.
//
// Stateless HTTP in both directions, deliberately: the host POSTs a
// question in and polls for the answer out. No persistent connection means
// no heartbeat, no reconnect, and nothing to reap when a laptop sleeps or
// changes networks. It also means the relay only ever sees asks that
// actually escalated — steady state is zero traffic, which is a better
// privacy posture than any amount of encryption on an always-open pipe.
//
// The types here are duplicated from rook-server rather than imported. It
// is a dozen fields, and rook must not grow a dependency on a service it
// works perfectly well without.
package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Ask is one escalated question, as rook-server stores it.
type Ask struct {
	ID        string          `json:"id"`
	Session   string          `json:"session,omitempty"`
	Workspace string          `json:"workspace,omitempty"`
	Title     string          `json:"title,omitempty"`
	Questions json.RawMessage `json:"questions"`
}

// Answered is one decision coming back.
type Answered struct {
	AskID  string          `json:"askId"`
	Answer json.RawMessage `json:"answer"`
}

type Client struct {
	base  string
	token string
	hc    *http.Client
}

// New returns nil when the relay isn't configured — callers treat a nil
// client as "no remote", so every call site is a cheap nil check and the
// feature is genuinely absent rather than half-wired.
func New(base, token string) *Client {
	base, token = strings.TrimRight(strings.TrimSpace(base), "/"), strings.TrimSpace(token)
	if base == "" || token == "" {
		return nil
	}
	if u, err := url.Parse(base); err != nil || u.Scheme == "" || u.Host == "" {
		return nil
	}
	return &Client{
		base:  base,
		token: token,
		// generous: a phone answer crosses a mobile network, and the poll
		// is the only thing anyone is waiting on
		hc: &http.Client{Timeout: 20 * time.Second},
	}
}

func (c *Client) Base() string { return c.base }

func (c *Client) do(ctx context.Context, method, path string, body any) ([]byte, error) {
	var rdr io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		rdr = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, rdr)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	res, err := c.hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	out, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode >= 300 {
		return nil, fmt.Errorf("%s %s: %s: %s", method, path, res.Status,
			strings.TrimSpace(string(out)))
	}
	return out, nil
}

// Publish escalates an ask. Idempotent server-side: a retry after a blip
// cannot clobber an answer the phone already gave.
func (c *Client) Publish(ctx context.Context, a Ask) error {
	_, err := c.do(ctx, http.MethodPost, "/v1/asks", a)
	return err
}

// Retract pulls an ask back — it was answered at the desk, so the card has
// to leave the phone. Best-effort by design: a failure here costs a stale
// card, never a lost decision.
func (c *Client) Retract(ctx context.Context, id string) error {
	_, err := c.do(ctx, http.MethodDelete, "/v1/asks/"+url.PathEscape(id), nil)
	return err
}

// Drain collects decisions made on another surface. Read-once server-side,
// so whatever comes back here is ours to apply and nobody else's.
func (c *Client) Drain(ctx context.Context) ([]Answered, error) {
	out, err := c.do(ctx, http.MethodGet, "/v1/answers", nil)
	if err != nil {
		return nil, err
	}
	var body struct {
		Answered []Answered `json:"answered"`
	}
	if err := json.Unmarshal(out, &body); err != nil {
		return nil, err
	}
	return body.Answered, nil
}

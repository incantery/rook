// Package cloud talks to rook-cloud's machine API — the surface that lets
// the dashboard show what is happening on this machine from anywhere.
//
// One verb matters: POST /v1/status, a snapshot of every workspace with
// live agents. Snapshots are last-write-wins on the server, which is what
// makes this client safe to be dumb — a retry after a blip cannot corrupt
// anything, and a missed tick costs nothing but staleness that the next
// tick repairs. There is no outbox, no replay, and no ordering, on
// purpose: that is the event-sourced version of this feature, and it
// should arrive as its own thing rather than leak in here.
//
// The types are duplicated from rook-cloud rather than imported, same rule
// as the relay: rook must not grow a dependency on a service it works
// perfectly well without.
package cloud

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

// Status is the snapshot rook-cloud stores. The detail level is a decided
// line: states, titles, and pending ask text go up; foreground commands,
// terminal contents, and file paths stay home.
type Status struct {
	Hostname    string      `json:"hostname,omitempty"`
	RookVersion string      `json:"rookVersion,omitempty"`
	Workspaces  []Workspace `json:"workspaces,omitempty"`
}

type Workspace struct {
	Name      string  `json:"name"`
	Branch    string  `json:"branch,omitempty"`
	Attention int     `json:"attention,omitempty"`
	Agents    []Agent `json:"agents,omitempty"`
}

type Agent struct {
	State   string  `json:"state"` // working | needs_input | quiet
	Title   string  `json:"title,omitempty"`
	Ask     string  `json:"ask,omitempty"`
	Model   string  `json:"model,omitempty"`
	CostUSD float64 `json:"costUsd,omitempty"`
	// No omitempty: encoding/json never omits a struct, so the tag would
	// promise something it cannot do — a zero time goes up as
	// 0001-01-01T00:00:00Z either way. Same reason overviewAgent, the type
	// this is projected from, spells it out.
	LastEvent time.Time `json:"lastEvent"`
}

type Client struct {
	base  string
	token string
	hc    *http.Client
}

// New returns nil when the cloud isn't configured — callers treat a nil
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
		hc:    &http.Client{Timeout: 20 * time.Second},
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

// PostStatus reports the machine's current snapshot. Last write wins
// server-side, so this is idempotent in the only sense that matters here.
func (c *Client) PostStatus(ctx context.Context, s Status) error {
	_, err := c.do(ctx, http.MethodPost, "/v1/status", s)
	return err
}

// Whoami resolves the token to the machine the dashboard knows — the
// provisioning check, useful in logs when a token turns out to be for the
// wrong machine.
func (c *Client) Whoami(ctx context.Context) (machineID, name string, err error) {
	out, err := c.do(ctx, http.MethodGet, "/v1/whoami", nil)
	if err != nil {
		return "", "", err
	}
	var body struct {
		MachineID string `json:"machineId"`
		Name      string `json:"name"`
	}
	if err := json.Unmarshal(out, &body); err != nil {
		return "", "", err
	}
	return body.MachineID, body.Name, nil
}

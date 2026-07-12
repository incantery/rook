// Package agent is the Rook Agent's drafter loop (docs/agent.md): a
// nano-tier model that watches claude sessions through rook-host's
// attention surface and proposes replies the user approves with one key.
// It is the ONLY LLM caller in the system, and structurally just another
// host client — env-injected credentials, the same authenticated HTTP the
// webview uses, no side doors.
package agent

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"time"

	"github.com/incantery/rook/internal/host"
)

// Client talks to rook-host. ErrHostGone (401/404) means the daemon was
// replaced or the endpoint predates us — the caller exits and the
// supervisor respawns with fresh credentials.
type Client struct {
	Endpoint string
	Token    string
	http     *http.Client
}

var ErrHostGone = fmt.Errorf("host rejected us (replaced daemon?)")

// Connect prefers the supervisor's env (ROOK_HOST_ENDPOINT/ROOK_HOST_TOKEN)
// and falls back to the state file for hand-run `rook-agent` in a shell.
func Connect() (*Client, error) {
	c := &Client{
		Endpoint: os.Getenv("ROOK_HOST_ENDPOINT"),
		Token:    os.Getenv("ROOK_HOST_TOKEN"),
		http:     &http.Client{Timeout: 10 * time.Second},
	}
	if c.Endpoint != "" && c.Token != "" {
		return c, nil
	}
	st, err := host.ReadState()
	if err != nil {
		return nil, fmt.Errorf("no ROOK_HOST_ENDPOINT and no state file: %w", err)
	}
	c.Endpoint, c.Token = st.Endpoint(), st.Token
	return c, nil
}

func (c *Client) req(method, path string, body, out any) (int, error) {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return 0, err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, c.Endpoint+path, rd)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	resp, err := c.http.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode == http.StatusUnauthorized {
		return resp.StatusCode, ErrHostGone
	}
	if resp.StatusCode >= 300 {
		return resp.StatusCode, fmt.Errorf("%s %s: %s", method, path, resp.Status)
	}
	if out != nil {
		if err := json.Unmarshal(raw, out); err != nil {
			return resp.StatusCode, err
		}
	}
	return resp.StatusCode, nil
}

// AttentionItem mirrors the host's /attention row.
type AttentionItem struct {
	Workspace    string `json:"workspace"`
	RookSession  string `json:"rookSession"`
	Window       int    `json:"window"`
	AgentSession string `json:"agentSession"`
	AskSeq       int    `json:"askSeq"`
	State        string `json:"state"`
	Title        string `json:"title"`
	Ask          string `json:"ask"`
	Interactive  bool   `json:"interactive"`
	Draft        *struct {
		ID int64 `json:"id"`
	} `json:"draft"`
}

func (c *Client) Attention() ([]AttentionItem, error) {
	var items []AttentionItem
	code, err := c.req("GET", "/attention", nil, &items)
	if code == http.StatusNotFound {
		// a host without /attention predates v8 — we're the stale one
		return nil, ErrHostGone
	}
	return items, err
}

// AskContext is /agents/{id}/context — everything the drafter may know.
type AskContext struct {
	SessionID string `json:"sessionId"`
	Title     string `json:"title"`
	CWD       string `json:"cwd"`
	AskSeq    int    `json:"askSeq"`
	State     string `json:"state"`
	Ask       string `json:"ask"`
	History   []struct {
		Role string `json:"role"`
		Text string `json:"text"`
	} `json:"history"`
}

func (c *Client) Context(agentSession string) (*AskContext, error) {
	var ctx AskContext
	_, err := c.req("GET", "/agents/"+agentSession+"/context", nil, &ctx)
	if err != nil {
		return nil, err
	}
	return &ctx, nil
}

// DraftPost is the judgment the agent submits; the host inserts the
// decisions row and decorates /attention.
type DraftPost struct {
	AskSeq       int     `json:"askSeq"`
	Action       string  `json:"action"`
	Reply        string  `json:"reply"`
	Confidence   float64 `json:"confidence"`
	Model        string  `json:"model"`
	InputTokens  int64   `json:"inputTokens"`
	OutputTokens int64   `json:"outputTokens"`
	CachedTokens int64   `json:"cachedTokens"`
	CostUSD      float64 `json:"costUsd"`
}

// PostDraft returns (stale, err): stale means the host 409ed — the ask
// moved on or already has a judgment, which is a no-op for us.
func (c *Client) PostDraft(agentSession string, d DraftPost) (bool, error) {
	code, err := c.req("POST", "/agents/"+agentSession+"/draft", d, nil)
	if code == http.StatusConflict {
		return true, nil
	}
	return false, err
}

type Spend struct {
	TodayUSD  float64 `json:"todayUsd"`
	HourCalls int     `json:"hourCalls"`
}

func (c *Client) Spend() (Spend, error) {
	var s Spend
	_, err := c.req("GET", "/agent/spend", nil, &s)
	return s, err
}

// DecisionRow mirrors the subset of the host's decisions ledger the
// preference pass reads: what was asked, what we proposed, what the user
// actually did about it.
type DecisionRow struct {
	ID         int64   `json:"id"`
	Workspace  string  `json:"workspace"`
	Ask        string  `json:"ask"`
	Action     string  `json:"action"`
	Draft      string  `json:"draft"`
	Confidence float64 `json:"confidence"`
	Verdict    string  `json:"verdict"`
	FinalText  string  `json:"finalText"`
}

// Decisions is GET /decisions — the ledger since t, newest first.
func (c *Client) Decisions(since time.Time) ([]DecisionRow, error) {
	var rows []DecisionRow
	_, err := c.req("GET", "/decisions?since="+url.QueryEscape(since.Format(time.RFC3339)), nil, &rows)
	return rows, err
}

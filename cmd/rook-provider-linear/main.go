// rook-provider-linear answers rook's questions about Linear.
//
// Where the GitHub provider delegates its authority to `gh`, Linear has
// no such CLI, so this one HOLDS a credential — which is the whole reason
// providers are processes. The key is fetched by this process, from the
// login keychain, and never passes through rook: rook spawns a binary and
// reads JSON from a pipe, and at no point does a Linear token exist in
// rook's address space.
//
//	LINEAR_API_KEY                  set it here to run this by hand
//	security find-generic-password  -s rook -a linear   (what rook expects)
//
// Configuration arrives as environment (see provider.Client.Env):
//
//	ROOK_PROVIDER_LINEAR_TEAM=ENG   restrict the queue to one team
//
// Standalone on purpose: the protocol package and the standard library,
// nothing else of rook's. Shelling out to /usr/bin/security rather than
// importing rook's keychain package is part of that — this file could be
// lifted into its own repository unchanged.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/incantery/rook/internal/provider"
)

const endpoint = "https://api.linear.app/graphql"

func main() {
	provider.Serve(
		provider.Describe{Name: "linear"},
		map[string]provider.Handler{
			provider.OpIssuesList: issuesList,
		},
	)
}

// issuesQuery asks for the viewer and the active queue in ONE round trip
// — the viewer's id is what decides "mine", and a second call to learn
// who we are would double the latency of every refresh for a value that
// never changes.
//
// The filter is server-side for state (so a queue full of completed work
// cannot crowd out the open items inside the page limit) and client-side
// for assignment (so "mine or nobody's" is expressed once, the same way
// the GitHub provider expresses it).
const issuesQuery = `query Rook($first: Int!, $filter: IssueFilter) {
  viewer { id }
  issues(first: $first, orderBy: updatedAt, filter: $filter) {
    nodes {
      identifier
      title
      description
      url
      updatedAt
      state { name }
      assignee { id }
      labels { nodes { name } }
    }
  }
}`

type issuesResponse struct {
	Data struct {
		Viewer struct {
			ID string `json:"id"`
		} `json:"viewer"`
		Issues struct {
			Nodes []struct {
				Identifier  string `json:"identifier"`
				Title       string `json:"title"`
				Description string `json:"description"`
				URL         string `json:"url"`
				UpdatedAt   string `json:"updatedAt"`
				State       struct {
					Name string `json:"name"`
				} `json:"state"`
				Assignee *struct {
					ID string `json:"id"`
				} `json:"assignee"`
				Labels struct {
					Nodes []struct {
						Name string `json:"name"`
					} `json:"nodes"`
				} `json:"labels"`
			} `json:"nodes"`
		} `json:"issues"`
	} `json:"data"`
	Errors []struct {
		Message string `json:"message"`
	} `json:"errors"`
}

func issuesList(ctx context.Context, _ json.RawMessage) (any, error) {
	key, err := apiKey()
	if err != nil {
		return nil, err
	}

	// Anything not finished is "active". Linear's state TYPES are the
	// stable vocabulary here (backlog, unstarted, started, completed,
	// canceled); a workspace can rename the states themselves.
	filter := map[string]any{
		"state": map[string]any{"type": map[string]any{"nin": []string{"completed", "canceled"}}},
	}
	if team := strings.TrimSpace(os.Getenv("ROOK_PROVIDER_LINEAR_TEAM")); team != "" {
		filter["team"] = map[string]any{"key": map[string]any{"eq": team}}
	}

	var res issuesResponse
	if err := query(ctx, key, map[string]any{"first": 50, "filter": filter}, &res); err != nil {
		return nil, err
	}
	if len(res.Errors) > 0 {
		return nil, fmt.Errorf("linear: %s", res.Errors[0].Message)
	}

	me := res.Data.Viewer.ID
	out := []provider.Issue{}
	for _, n := range res.Data.Issues.Nodes {
		mine := n.Assignee != nil && me != "" && n.Assignee.ID == me
		if n.Assignee != nil && !mine {
			continue // someone else's work is their queue, not this one
		}
		is := provider.Issue{
			Provider: "linear",
			Key:      n.Identifier,
			Title:    n.Title,
			Body:     n.Description,
			URL:      n.URL,
			State:    n.State.Name,
			Mine:     mine,
			Updated:  n.UpdatedAt,
		}
		for _, l := range n.Labels.Nodes {
			is.Labels = append(is.Labels, l.Name)
		}
		out = append(out, is)
	}
	return provider.IssuesListResult{Issues: out}, nil
}

func query(ctx context.Context, key string, vars map[string]any, out any) error {
	body, err := json.Marshal(map[string]any{"query": issuesQuery, "variables": vars})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	// A personal API key goes in Authorization RAW — no Bearer prefix,
	// which is reserved for OAuth access tokens. Getting this wrong reads
	// as a 400 about the query rather than as an auth failure.
	req.Header.Set("Authorization", key)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		var msg bytes.Buffer
		msg.ReadFrom(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("linear: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(msg.String()))
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// apiKey: the environment for a hand-run, the login keychain for rook's.
func apiKey() (string, error) {
	if k := strings.TrimSpace(os.Getenv("LINEAR_API_KEY")); k != "" {
		return k, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/security",
		"find-generic-password", "-s", "rook", "-a", "linear", "-w").Output()
	if k := strings.TrimSpace(string(out)); err == nil && k != "" {
		return k, nil
	}
	return "", fmt.Errorf("no Linear API key — run `rookctl set-linear-token`, or set LINEAR_API_KEY")
}

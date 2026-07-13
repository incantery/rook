package tracker

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Jira reads the current queue over the enhanced-search endpoint
// /rest/api/2/search/jql. It stays on v2 (not v3) because v2 returns
// descriptions as plain text instead of ADF documents; the old
// /rest/api/2/search was removed by Atlassian in May 2025 (410 Gone).
// We only ever fetch the first page, so the endpoint's nextPageToken
// pagination (which replaced startAt) doesn't matter and the response's
// issues array decodes exactly as before.
// Auth is the standard cloud pair: account email + API token, basic auth.
type Jira struct {
	BaseURL string // https://yourorg.atlassian.net
	Email   string
	Token   string
	Project string
	// JQL overrides the default query entirely when set (config jira-jql).
	JQL string

	client *http.Client
}

func NewJira(baseURL, email, token, project, jql string) *Jira {
	return &Jira{
		BaseURL: strings.TrimRight(baseURL, "/"),
		Email:   email,
		Token:   token,
		Project: project,
		JQL:     jql,
		client:  &http.Client{Timeout: 10 * time.Second},
	}
}

func (j *Jira) Name() string { return "jira" }

// The queue scope: my issues + unassigned ones, in the current sprint.
// currentUser() makes identity Jira's problem — any assigned issue this
// query returns is mine by construction.
const jiraScope = `project = %q AND statusCategory != Done AND (assignee = currentUser() OR assignee IS EMPTY)`

func (j *Jira) Issues() ([]Issue, error) {
	jql := j.JQL
	if jql == "" {
		jql = fmt.Sprintf(jiraScope+` AND sprint IN openSprints() ORDER BY updated DESC`, j.Project)
		issues, err := j.search(jql)
		// Kanban projects have no sprints and reject the sprint clause —
		// fall back to the same scope un-sprinted rather than erroring.
		if err != nil && strings.Contains(strings.ToLower(err.Error()), "sprint") {
			jql = fmt.Sprintf(jiraScope+` ORDER BY updated DESC`, j.Project)
			return j.search(jql)
		}
		return issues, err
	}
	return j.search(jql)
}

type jiraIssue struct {
	Key    string `json:"key"`
	Fields struct {
		Summary     string `json:"summary"`
		Description string `json:"description"`
		Updated     string `json:"updated"`
		Status      struct {
			Name string `json:"name"`
		} `json:"status"`
		Assignee *struct {
			DisplayName string `json:"displayName"`
		} `json:"assignee"`
		Labels []string `json:"labels"`
	} `json:"fields"`
}

func (j *Jira) search(jql string) ([]Issue, error) {
	q := url.Values{
		"jql":        {jql},
		"maxResults": {"50"},
		"fields":     {"summary,description,status,assignee,labels,updated"},
	}
	req, err := http.NewRequest(http.MethodGet, j.BaseURL+"/rest/api/2/search/jql?"+q.Encode(), nil)
	if err != nil {
		return nil, err
	}
	req.SetBasicAuth(j.Email, j.Token)
	resp, err := j.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("jira: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("jira search: %s: %s", resp.Status, jiraErrText(body))
	}
	var raw struct {
		Issues []jiraIssue `json:"issues"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, fmt.Errorf("jira json: %w", err)
	}
	out := make([]Issue, 0, len(raw.Issues))
	for _, ji := range raw.Issues {
		is := Issue{
			Tracker: "jira",
			Key:     ji.Key,
			Title:   ji.Fields.Summary,
			Body:    ji.Fields.Description,
			URL:     j.BaseURL + "/browse/" + ji.Key,
			State:   ji.Fields.Status.Name,
			Mine:    ji.Fields.Assignee != nil, // see jiraScope
			Labels:  ji.Fields.Labels,
		}
		if t, err := time.Parse("2006-01-02T15:04:05.000-0700", ji.Fields.Updated); err == nil {
			is.Updated = t
		}
		is.Task = BuildTask(is)
		out = append(out, is)
	}
	return out, nil
}

// jiraErrText digs the human message out of Jira's error envelope.
func jiraErrText(body []byte) string {
	var e struct {
		ErrorMessages []string          `json:"errorMessages"`
		Errors        map[string]string `json:"errors"`
	}
	if json.Unmarshal(body, &e) == nil {
		var parts []string
		parts = append(parts, e.ErrorMessages...)
		for k, v := range e.Errors {
			parts = append(parts, k+": "+v)
		}
		if len(parts) > 0 {
			return strings.Join(parts, "; ")
		}
	}
	s := strings.TrimSpace(string(body))
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}

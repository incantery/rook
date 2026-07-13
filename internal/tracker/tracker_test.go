package tracker

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestParseGitHubScope(t *testing.T) {
	data := `[
		{"number": 1, "title": "mine", "assignees": [{"login": "seth"}], "updatedAt": "2026-07-12T10:00:00Z"},
		{"number": 2, "title": "unassigned", "assignees": [], "body": "do the thing"},
		{"number": 3, "title": "someone else's", "assignees": [{"login": "other"}]}
	]`
	issues, err := parseGitHub([]byte(data), "seth")
	if err != nil {
		t.Fatal(err)
	}
	if len(issues) != 2 {
		t.Fatalf("want 2 issues (mine + unassigned), got %d: %+v", len(issues), issues)
	}
	if issues[0].Key != "#1" || !issues[0].Mine {
		t.Fatalf("first should be mine: %+v", issues[0])
	}
	if issues[1].Key != "#2" || issues[1].Mine {
		t.Fatalf("second should be unassigned: %+v", issues[1])
	}
	if !strings.Contains(issues[1].Task, "do the thing") || !strings.Contains(issues[1].Task, "gh issue view 2") {
		t.Fatalf("task prompt missing body or gh hint: %q", issues[1].Task)
	}
}

// fakeJira answers the enhanced-search endpoint /rest/api/2/search/jql,
// rejecting sprint JQL when sprints=false. The legacy /rest/api/2/search
// path was removed by Atlassian and now returns 410 Gone — model that so a
// regression back to the old endpoint fails loudly instead of silently.
func fakeJira(t *testing.T, sprints bool) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/rest/api/2/search/jql" {
			w.WriteHeader(http.StatusGone) // 410
			json.NewEncoder(w).Encode(map[string]any{
				"errorMessages": []string{
					"The requested API has been removed. Please migrate to the /rest/api/3/search/jql endpoint.",
				},
			})
			return
		}
		jql := r.URL.Query().Get("jql")
		if user, _, _ := r.BasicAuth(); user != "me@example.com" {
			w.WriteHeader(401)
			return
		}
		if !sprints && strings.Contains(jql, "openSprints") {
			w.WriteHeader(400)
			json.NewEncoder(w).Encode(map[string]any{
				"errorMessages": []string{"The operator 'IN' is not supported by the 'sprint' field."},
			})
			return
		}
		json.NewEncoder(w).Encode(map[string]any{
			"issues": []map[string]any{
				{"key": "INF-7", "fields": map[string]any{
					"summary": "fix the intake", "description": "details here",
					"status":   map[string]any{"name": "In Progress"},
					"assignee": map[string]any{"displayName": "Seth"},
					"updated":  "2026-07-12T09:30:00.000-0400",
				}},
				{"key": "INF-9", "fields": map[string]any{
					"summary": "unassigned one",
					"status":  map[string]any{"name": "To Do"},
				}},
			},
		})
	}))
}

func TestJiraSearch(t *testing.T) {
	srv := fakeJira(t, true)
	defer srv.Close()
	j := NewJira(srv.URL, "me@example.com", "tok", "INF", "")
	issues, err := j.Issues()
	if err != nil {
		t.Fatal(err)
	}
	if len(issues) != 2 {
		t.Fatalf("want 2, got %d", len(issues))
	}
	if issues[0].Key != "INF-7" || !issues[0].Mine || issues[0].State != "In Progress" {
		t.Fatalf("bad first issue: %+v", issues[0])
	}
	if issues[1].Mine {
		t.Fatalf("INF-9 has no assignee, must not be mine: %+v", issues[1])
	}
	if !strings.Contains(issues[0].Task, "details here") || !strings.Contains(issues[0].Task, "/browse/INF-7") {
		t.Fatalf("task prompt incomplete: %q", issues[0].Task)
	}
	if strings.Contains(issues[0].Task, "gh issue view") {
		t.Fatal("jira tasks must not reference gh")
	}
}

func TestJiraSprintFallback(t *testing.T) {
	srv := fakeJira(t, false)
	defer srv.Close()
	j := NewJira(srv.URL, "me@example.com", "tok", "INF", "")
	issues, err := j.Issues()
	if err != nil {
		t.Fatalf("sprint-less project must fall back, got: %v", err)
	}
	if len(issues) != 2 {
		t.Fatalf("want 2 after fallback, got %d", len(issues))
	}
}

func TestJiraAuthError(t *testing.T) {
	srv := fakeJira(t, true)
	defer srv.Close()
	j := NewJira(srv.URL, "wrong@example.com", "tok", "INF", "")
	if _, err := j.Issues(); err == nil {
		t.Fatal("bad auth must surface an error")
	}
}

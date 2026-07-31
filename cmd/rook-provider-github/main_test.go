package main

// The parsing rules, ported with the code they belong to when the tracker
// package was dissolved. Both are about the same discipline: gh's answer
// is translated, never guessed at.

import (
	"encoding/json"
	"testing"

	"github.com/incantery/rook/internal/provider"
)

// The queue's scope rule: mine, or nobody's. Work someone else already
// owns is their queue, and an issue with no assignee is up for grabs.
func TestParseIssuesScope(t *testing.T) {
	raw := []byte(`[
	  {"number":1,"title":"mine","assignees":[{"login":"seth"}],"updatedAt":"2026-07-12T18:00:00Z"},
	  {"number":2,"title":"nobody's","assignees":[],"updatedAt":"2026-07-12T17:00:00Z"},
	  {"number":3,"title":"someone else's","assignees":[{"login":"other"}],"updatedAt":"2026-07-12T16:00:00Z"},
	  {"number":4,"title":"mine and theirs","assignees":[{"login":"other"},{"login":"seth"}],"updatedAt":"2026-07-12T15:00:00Z"}
	]`)
	got, err := parseIssues(raw, "seth")
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]bool{"#1": true, "#2": false, "#4": true} // key -> mine
	if len(got) != len(want) {
		t.Fatalf("scope: got %d issues, want %d: %+v", len(got), len(want), got)
	}
	for _, is := range got {
		mine, ok := want[is.Key]
		if !ok {
			t.Fatalf("%s must not be in the queue: %+v", is.Key, is)
		}
		if is.Mine != mine {
			t.Fatalf("%s mine=%v, want %v", is.Key, is.Mine, mine)
		}
		if is.Provider != "github" {
			t.Fatalf("%s provider=%q", is.Key, is.Provider)
		}
	}

	// With no login resolved (gh not authenticated), nothing may claim to
	// be mine — and an assigned issue is still someone's, so it stays out.
	got, err = parseIssues(raw, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Key != "#2" || got[0].Mine {
		t.Fatalf("unknown login must claim nothing: %+v", got)
	}
}

// A provider must not invent an issue's prompt: the Issue type has no
// Task field, and rook builds it. This pins the absence.
func TestIssueCarriesNoPrompt(t *testing.T) {
	got, err := parseIssues([]byte(`[{"number":1,"title":"t","body":"b","assignees":[]}]`), "seth")
	if err != nil || len(got) != 1 {
		t.Fatalf("%v %+v", err, got)
	}
	blob, err := json.Marshal(got[0])
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	json.Unmarshal(blob, &fields)
	for _, forbidden := range []string{"task", "prompt", "command"} {
		if _, ok := fields[forbidden]; ok {
			t.Fatalf("a provider must not supply %q: %s", forbidden, blob)
		}
	}
}

func TestParsePR(t *testing.T) {
	pr, err := parsePR([]byte(`{"number":14,"state":"MERGED","url":"https://github.com/x/y/pull/14","mergedAt":"2026-07-12T18:00:00Z"}`))
	if err != nil {
		t.Fatal(err)
	}
	if !pr.Found || pr.Number != 14 || pr.State != "MERGED" || pr.MergedAt == "" {
		t.Fatalf("pr: %+v", pr)
	}
}

// Mergeability fails OPEN: only CONFLICTING means conflicts, and a gh too
// old to report it must not read as conflicted. The caller tests for the
// exact string, so what matters here is that we never substitute one.
func TestParsePRMergeable(t *testing.T) {
	for _, tc := range []struct{ raw, want string }{
		{`{"number":1,"state":"OPEN","mergeable":"CONFLICTING"}`, "CONFLICTING"},
		{`{"number":1,"state":"OPEN","mergeable":"MERGEABLE"}`, "MERGEABLE"},
		{`{"number":1,"state":"OPEN","mergeable":"UNKNOWN"}`, "UNKNOWN"},
		{`{"number":1,"state":"OPEN"}`, ""}, // gh too old to say
	} {
		pr, err := parsePR([]byte(tc.raw))
		if err != nil {
			t.Fatal(err)
		}
		if pr.Mergeable != tc.want {
			t.Fatalf("%s -> mergeable %q, want %q", tc.raw, pr.Mergeable, tc.want)
		}
		if !pr.Found {
			t.Fatalf("%s must be found", tc.raw)
		}
	}
}

// Found=false is a fact, and it is the one thing a caller must be able to
// tell apart from an error. The zero value must therefore never look like
// a PR — this is what stops "I could not look" reading as "no PR".
func TestPullsStatusZeroIsNotAPR(t *testing.T) {
	var zero provider.PullsStatusResult
	if zero.Found || zero.Number != 0 || zero.State != "" {
		t.Fatalf("the zero result must assert nothing: %+v", zero)
	}
}

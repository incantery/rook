package tracker

import (
	"strings"
	"testing"
)

func TestParsePR(t *testing.T) {
	pr, err := parsePR([]byte(`{"number": 14, "state": "MERGED", "url": "https://github.com/x/y/pull/14", "mergedAt": "2026-07-12T18:00:00Z"}`))
	if err != nil {
		t.Fatal(err)
	}
	if pr.Number != 14 || pr.State != "MERGED" || pr.MergedAt.IsZero() {
		t.Fatalf("bad merged PR: %+v", pr)
	}

	// open PRs carry a null mergedAt — must stay zero, not error
	pr, err = parsePR([]byte(`{"number": 15, "state": "OPEN", "url": "https://github.com/x/y/pull/15", "mergedAt": null}`))
	if err != nil {
		t.Fatal(err)
	}
	if pr.State != "OPEN" || !pr.MergedAt.IsZero() {
		t.Fatalf("bad open PR: %+v", pr)
	}

	if _, err = parsePR([]byte(`not json`)); err == nil {
		t.Fatal("garbage must error")
	}
}

func TestBuildTaskClosesLoop(t *testing.T) {
	task := BuildTask(Issue{Tracker: "github", Key: "#3", Title: "close the loop"})
	if !strings.Contains(task, "Closes #3") {
		t.Fatalf("github task must ask for a Closes-linked PR: %q", task)
	}
	task = BuildTask(Issue{Tracker: "jira", Key: "INF-7", Title: "no gh here"})
	if strings.Contains(task, "Closes") {
		t.Fatalf("jira task must not carry the github PR line: %q", task)
	}
}

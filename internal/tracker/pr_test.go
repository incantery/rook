package tracker

import (
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

// Mergeability rides the same JSON: CONFLICTING is the only value that may
// ever read as conflicted — UNKNOWN (GitHub still computing) and absent
// (older gh) fail open to "fine".
func TestParsePRMergeable(t *testing.T) {
	pr, err := parsePR([]byte(`{"number": 16, "state": "OPEN", "mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY"}`))
	if err != nil {
		t.Fatal(err)
	}
	if pr.Mergeable != "CONFLICTING" || pr.MergeStateStatus != "DIRTY" {
		t.Fatalf("mergeability must parse: %+v", pr)
	}

	pr, err = parsePR([]byte(`{"number": 17, "state": "OPEN", "mergeable": "UNKNOWN"}`))
	if err != nil {
		t.Fatal(err)
	}
	if pr.Mergeable != "UNKNOWN" {
		t.Fatalf("bad UNKNOWN: %+v", pr)
	}

	// absent fields (older gh JSON) must parse to empty, not error
	pr, err = parsePR([]byte(`{"number": 18, "state": "OPEN"}`))
	if err != nil {
		t.Fatal(err)
	}
	if pr.Mergeable != "" || pr.MergeStateStatus != "" {
		t.Fatalf("absent mergeability must stay empty: %+v", pr)
	}
}

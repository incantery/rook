package host

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestClassifyHunks(t *testing.T) {
	for name, tc := range map[string]struct {
		in   []hunk
		want []gutterHunk
	}{
		"pure insertion": {
			in:   []hunk{{oldStart: 3, oldCount: 0, newStart: 4, newCount: 2}},
			want: []gutterHunk{{Start: 4, End: 5, Kind: "added"}},
		},
		"pure deletion marks the boundary line": {
			in:   []hunk{{oldStart: 5, oldCount: 3, newStart: 4, newCount: 0}},
			want: []gutterHunk{{Start: 4, End: 4, Kind: "deleted", DelLines: 3}},
		},
		"deletion at the very top clamps to line 1": {
			in:   []hunk{{oldStart: 1, oldCount: 2, newStart: 0, newCount: 0}},
			want: []gutterHunk{{Start: 1, End: 1, Kind: "deleted", DelLines: 2}},
		},
		"replacement is modified, remembering what it replaced": {
			in:   []hunk{{oldStart: 7, oldCount: 2, newStart: 7, newCount: 3}},
			want: []gutterHunk{{Start: 7, End: 9, Kind: "modified", DelLines: 2}},
		},
		"empty in, empty (not nil) out": {
			in:   nil,
			want: []gutterHunk{},
		},
	} {
		if got := classifyHunks(tc.in); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%s: got %+v want %+v", name, got, tc.want)
		}
	}
}

func TestGutterEndpoint(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	// commit a known five-line file, then edit it three ways
	p := filepath.Join(repo, "g.txt")
	os.WriteFile(p, []byte("one\ntwo\nthree\nfour\nfive\n"), 0o644)
	gitT(t, repo, "add", ".")
	gitT(t, repo, "commit", "-m", "gutter base")
	// line 2 modified, a line appended, line 4 deleted
	os.WriteFile(p, []byte("one\nTWO\nthree\nfive\nsix\nseven\n"), 0o644)

	type res struct {
		Base  string       `json:"base"`
		Hunks []gutterHunk `json:"hunks"`
	}
	get := func(q string) res {
		t.Helper()
		code, raw := c.do(t, "GET", "/workspaces/src/gutter?"+q, nil)
		if code != 200 {
			t.Fatalf("gutter: %d %s", code, raw)
		}
		var r res
		if err := json.Unmarshal([]byte(raw), &r); err != nil {
			t.Fatal(err)
		}
		return r
	}

	r := get("path=g.txt")
	if r.Base != "HEAD" {
		t.Fatalf("base: %q", r.Base)
	}
	kinds := map[string]bool{}
	for _, hk := range r.Hunks {
		kinds[hk.Kind] = true
	}
	if !kinds["modified"] || !kinds["added"] || !kinds["deleted"] {
		t.Fatalf("want all three kinds, got %+v", r.Hunks)
	}

	// a file the base never saw is one whole addition
	os.WriteFile(filepath.Join(repo, "new.txt"), []byte("a\nb\n"), 0o644)
	if r := get("path=new.txt"); len(r.Hunks) != 1 || r.Hunks[0].Kind != "added" ||
		r.Hunks[0].Start != 1 || r.Hunks[0].End != 2 {
		t.Fatalf("untracked: %+v", r.Hunks)
	}

	// an explicit ref as base (the review-scope seam); garbage fails open
	sha := gitT(t, repo, "rev-parse", "HEAD")
	if r := get("path=g.txt&base=" + sha); len(r.Hunks) == 0 {
		t.Fatalf("explicit ref base: %+v", r.Hunks)
	}
	if r := get("path=g.txt&base=no-such-ref"); r.Base != "HEAD" {
		t.Fatalf("bad ref must fail open to HEAD: %q", r.Base)
	}

	// guards: missing path, escape, missing file
	if code, _ := c.do(t, "GET", "/workspaces/src/gutter", nil); code != 400 {
		t.Fatal("no path: want 400")
	}
	if code, _ := c.do(t, "GET", "/workspaces/src/gutter?path=../x", nil); code != 400 {
		t.Fatal("escape: want 400")
	}
	if code, _ := c.do(t, "GET", "/workspaces/src/gutter?path=ghost.txt", nil); code != 404 {
		t.Fatal("missing file: want 404")
	}
}

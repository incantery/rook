package host

import (
	"net/url"
	"os"
	"path/filepath"
	"testing"
)

func grepGET(t *testing.T, c *wtClient, ws, q string, wantCode int) grepResult {
	t.Helper()
	return reviewGET[grepResult](t, c, "/workspaces/"+ws+"/grep?q="+url.QueryEscape(q), wantCode)
}

func TestGrepRepo(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	os.WriteFile(filepath.Join(repo, "alpha.go"), []byte("package x\n\nfunc NeedleFunc() {}\n"), 0o644)
	os.MkdirAll(filepath.Join(repo, "sub"), 0o755)
	// untracked files must be searched too — git grep gets --untracked
	os.WriteFile(filepath.Join(repo, "sub", "loose.txt"), []byte("calls needlefunc here\n"), 0o644)

	// smart case: all-lowercase query hits both spellings
	res := grepGET(t, c, "src", "needlefunc", 200)
	if len(res.Hits) != 2 {
		t.Fatalf("hits: %+v", res.Hits)
	}
	byPath := map[string]grepHit{}
	for _, h := range res.Hits {
		byPath[h.Path] = h
	}
	if g := byPath["alpha.go"]; g.Line != 3 || g.Col != 6 || g.Text != "func NeedleFunc() {}" {
		t.Errorf("alpha.go hit: %+v", g)
	}
	if g := byPath["sub/loose.txt"]; g.Line != 1 || g.Col != 7 {
		t.Errorf("loose.txt hit: %+v", g)
	}

	// uppercase in the query turns case sensitivity back on
	res = grepGET(t, c, "src", "NeedleFunc", 200)
	if len(res.Hits) != 1 || res.Hits[0].Path != "alpha.go" {
		t.Fatalf("case-sensitive hits: %+v", res.Hits)
	}

	// extended regex works…
	res = grepGET(t, c, "src", "needle(func)", 200)
	if len(res.Hits) != 2 {
		t.Fatalf("regex hits: %+v", res.Hits)
	}
	// …and a broken pattern falls back to literal text, never an error
	os.WriteFile(filepath.Join(repo, "weird.txt"), []byte("a literal ( paren\n"), 0o644)
	res = grepGET(t, c, "src", "literal (", 200)
	if len(res.Hits) != 1 || res.Hits[0].Path != "weird.txt" {
		t.Fatalf("fallback hits: %+v", res.Hits)
	}

	// no matches is an empty list, not an error
	res = grepGET(t, c, "src", "zz-not-here-zz", 200)
	if len(res.Hits) != 0 || res.Truncated {
		t.Fatalf("miss: %+v", res)
	}

	// empty q is the caller's bug
	if code, _ := c.do(t, "GET", "/workspaces/src/grep?q=", nil); code != 400 {
		t.Fatalf("empty q: %d", code)
	}
}

func TestGrepNonRepoWalk(t *testing.T) {
	h, srv, _ := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "notes.md"), []byte("first\nsecond Marker line\n"), 0o644)
	os.WriteFile(filepath.Join(root, "bin.dat"), append([]byte("Marker"), 0), 0o644)
	if code, _ := c.do(t, "POST", "/workspaces", map[string]string{"name": "plain", "root": root}); code != 200 {
		t.Fatalf("create plain ws: %d", code)
	}

	res := grepGET(t, c, "plain", "marker", 200)
	if len(res.Hits) != 1 {
		t.Fatalf("hits: %+v", res.Hits)
	}
	if g := res.Hits[0]; g.Path != "notes.md" || g.Line != 2 || g.Col != 8 || g.Text != "second Marker line" {
		t.Errorf("hit: %+v", g)
	}
}

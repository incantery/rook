package host

import (
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestConfinePath(t *testing.T) {
	top := t.TempDir()
	bad := []string{"", "../x", "a/../../x", "/etc/passwd", "..", "a/b/../../../x"}
	for _, rel := range bad {
		if p, err := confinePath(top, rel); err == nil {
			t.Errorf("confinePath(%q) = %q, want error", rel, p)
		}
	}
	good := map[string]string{
		"a.txt":       filepath.Join(top, "a.txt"),
		"dir/b.txt":   filepath.Join(top, "dir", "b.txt"),
		"dir/../a.go": filepath.Join(top, "a.go"),
	}
	for rel, want := range good {
		p, err := confinePath(top, rel)
		if err != nil || p != want {
			t.Errorf("confinePath(%q) = %q, %v; want %q", rel, p, err, want)
		}
	}
}

// reviewGET is a typed GET against the review endpoints.
func reviewGET[T any](t *testing.T, c *wtClient, path string, wantCode int) T {
	t.Helper()
	code, body := c.do(t, "GET", path, nil)
	if code != wantCode {
		t.Fatalf("GET %s: %d %s (want %d)", path, code, body, wantCode)
	}
	var out T
	if wantCode == 200 {
		if err := json.Unmarshal([]byte(body), &out); err != nil {
			t.Fatalf("GET %s: %v in %s", path, err, body)
		}
	}
	return out
}

func fileByPath(files []changedFile, path string) *changedFile {
	for i := range files {
		if files[i].Path == path {
			return &files[i]
		}
	}
	return nil
}

func TestReviewChangesHead(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	// modified + staged-new + untracked, one of each
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("changed\n"), 0o644)
	os.WriteFile(filepath.Join(repo, "staged.txt"), []byte("new\n"), 0o644)
	gitT(t, repo, "add", "staged.txt")
	os.WriteFile(filepath.Join(repo, "loose.txt"), []byte("loose\n"), 0o644)

	res := reviewGET[changesResult](t, c, "/workspaces/src/changes", 200)
	if res.Base != "head" || res.BaseRef != "HEAD" || res.BaseName != "HEAD" || res.Fallback != "" {
		t.Fatalf("head base: %+v", res)
	}
	want := map[string]string{"a.txt": "modified", "staged.txt": "added", "loose.txt": "untracked"}
	if len(res.Files) != len(want) {
		t.Fatalf("files: %+v", res.Files)
	}
	for path, status := range want {
		f := fileByPath(res.Files, path)
		if f == nil || f.Status != status {
			t.Errorf("%s: got %+v, want %s", path, f, status)
		}
	}

	// unknown workspace 404s before any git runs
	reviewGET[changesResult](t, c, "/workspaces/nope/changes", 404)
}

func TestReviewChangesBranch(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}
	base := gitT(t, repo, "rev-parse", "HEAD")

	code, body := c.do(t, "POST", "/workspaces", map[string]any{"worktreeFrom": "src"})
	if code != 200 {
		t.Fatalf("create worktree: %d %s", code, body)
	}
	var ws WorkspaceInfo
	json.Unmarshal([]byte(body), &ws)

	// the task's work: a commit, a dirty edit, an untracked file
	os.WriteFile(filepath.Join(ws.Root, "feat.txt"), []byte("feat\n"), 0o644)
	gitT(t, ws.Root, "add", ".")
	gitT(t, ws.Root, "commit", "-m", "feat")
	os.WriteFile(filepath.Join(ws.Root, "a.txt"), []byte("edited\n"), 0o644)
	os.WriteFile(filepath.Join(ws.Root, "wip.txt"), []byte("wip\n"), 0o644)
	// main moves on — merge-base, not main's tip, must stay the base
	os.WriteFile(filepath.Join(repo, "mainline.txt"), []byte("m\n"), 0o644)
	gitT(t, repo, "add", ".")
	gitT(t, repo, "commit", "-m", "mainline")

	// worktrees default to branch mode with no param
	res := reviewGET[changesResult](t, c, "/workspaces/"+ws.Name+"/changes", 200)
	if res.Base != "branch" || res.BaseName != "main" || res.BaseRef != base || res.Fallback != "" {
		t.Fatalf("branch base: %+v (want merge-base %s)", res, base)
	}
	want := map[string]string{"feat.txt": "added", "a.txt": "modified", "wip.txt": "untracked"}
	if len(res.Files) != len(want) {
		t.Fatalf("files: %+v", res.Files)
	}
	for path, status := range want {
		if f := fileByPath(res.Files, path); f == nil || f.Status != status {
			t.Errorf("%s: got %+v, want %s", path, f, status)
		}
	}
	if fileByPath(res.Files, "mainline.txt") != nil {
		t.Error("main's own commit leaked into the branch diff")
	}

	// the header toggle: ?base=head narrows to uncommitted work
	res = reviewGET[changesResult](t, c, "/workspaces/"+ws.Name+"/changes?base=head", 200)
	if res.Base != "head" || fileByPath(res.Files, "feat.txt") != nil {
		t.Fatalf("head toggle: %+v", res)
	}
}

func TestReviewBaseFallsOpenToHead(t *testing.T) {
	h, srv, _ := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	// a repo with no main/master/origin — branch mode has no candidate
	solo := t.TempDir()
	gitT(t, solo, "init", "-b", "work")
	os.WriteFile(filepath.Join(solo, "f.txt"), []byte("f\n"), 0o644)
	gitT(t, solo, "add", ".")
	gitT(t, solo, "commit", "-m", "init")
	h.reg.upsert("solo", solo, false)

	res := reviewGET[changesResult](t, c, "/workspaces/solo/changes?base=branch", 200)
	if res.Base != "head" || res.BaseRef != "HEAD" {
		t.Fatalf("must fail open to head: %+v", res)
	}
	if !strings.Contains(res.Fallback, "no merge base") {
		t.Fatalf("fallback reason missing: %+v", res)
	}
}

func TestReviewDiff(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}
	os.WriteFile(filepath.Join(repo, "del.txt"), []byte("bye\n"), 0o644)
	gitT(t, repo, "add", ".")
	gitT(t, repo, "commit", "-m", "setup")

	// trailing-newline fidelity — the reason gitOut exists
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("hello"), 0o644)
	res := reviewGET[diffResult](t, c, "/workspaces/src/diff?path=a.txt", 200)
	if res.Original != "hello\n" || res.Modified != "hello" {
		t.Fatalf("fidelity: original %q, modified %q", res.Original, res.Modified)
	}
	if res.Base != "head" || res.BaseRef != "HEAD" {
		t.Fatalf("diff base: %+v", res)
	}

	// untracked: no original side
	os.WriteFile(filepath.Join(repo, "new.txt"), []byte("new\n"), 0o644)
	res = reviewGET[diffResult](t, c, "/workspaces/src/diff?path=new.txt", 200)
	if res.Original != "" || res.Modified != "new\n" {
		t.Fatalf("untracked: %+v", res)
	}

	// deleted: no modified side
	os.Remove(filepath.Join(repo, "del.txt"))
	res = reviewGET[diffResult](t, c, "/workspaces/src/diff?path=del.txt", 200)
	if res.Original != "bye\n" || res.Modified != "" {
		t.Fatalf("deleted: %+v", res)
	}

	// binary: sniffed, contents withheld
	os.WriteFile(filepath.Join(repo, "bin.dat"), []byte("a\x00b"), 0o644)
	res = reviewGET[diffResult](t, c, "/workspaces/src/diff?path=bin.dat", 200)
	if !res.Binary || res.Original != "" || res.Modified != "" {
		t.Fatalf("binary: %+v", res)
	}

	// traversal → 400, absolute → 400
	reviewGET[diffResult](t, c, "/workspaces/src/diff?path=../../etc/passwd", 400)
	reviewGET[diffResult](t, c, "/workspaces/src/diff?path=%2Fetc%2Fpasswd", 400)
}

func TestReviewFileAndFiles(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	res := reviewGET[fileResult](t, c, "/workspaces/src/file?path=a.txt", 200)
	if res.Content != "hello\n" || res.Binary || res.Truncated {
		t.Fatalf("file: %+v", res)
	}
	// a file that isn't there YET is vim's new-file buffer: empty, named,
	// 200. Only under a directory that exists — a bogus dir is still 404.
	if nf := reviewGET[fileResult](t, c, "/workspaces/src/file?path=missing.txt", 200); !nf.Missing || nf.Content != "" {
		t.Fatalf("new file: %+v", nf)
	}
	reviewGET[fileResult](t, c, "/workspaces/src/file?path=nodir/missing.txt", 404)
	reviewGET[fileResult](t, c, "/workspaces/src/file?path=../x", 400)

	// ?dir= scopes the listing to a subtree: names relative to it, base set
	os.MkdirAll(filepath.Join(repo, "sub"), 0o755)
	os.WriteFile(filepath.Join(repo, "sub", "inner.txt"), []byte("i\n"), 0o644)
	scoped := reviewGET[filesResult](t, c,
		"/workspaces/src/files?dir="+url.QueryEscape(filepath.Join(repo, "sub")), 200)
	if scoped.Base != "sub" || strings.Join(scoped.Files, " ") != "inner.txt" {
		t.Fatalf("scoped files: %+v", scoped)
	}

	// a dir OUTSIDE the workspace lists from there with an absolute base
	out := t.TempDir()
	os.WriteFile(filepath.Join(out, "elsewhere.txt"), []byte("e\n"), 0o644)
	ext2 := reviewGET[filesResult](t, c,
		"/workspaces/src/files?dir="+url.QueryEscape(out), 200)
	if ext2.Base != out || strings.Join(ext2.Files, " ") != "elsewhere.txt" {
		t.Fatalf("external files: %+v", ext2)
	}

	// a bogus dir falls back to the workspace, never errors
	fb := reviewGET[filesResult](t, c, "/workspaces/src/files?dir=%2Fno%2Fsuch%2Fdir", 200)
	if fb.Base != "" || len(fb.Files) == 0 {
		t.Fatalf("fallback files: %+v", fb)
	}

	// an absolute path is an external view (gd into the stdlib, or a file in
	// another checkout — that one saves too, see TestReviewWrite)
	extDir := t.TempDir()
	ext := filepath.Join(extDir, "outside.go")
	os.WriteFile(ext, []byte("package outside\n"), 0o644)
	xres := reviewGET[fileResult](t, c, "/workspaces/src/file?path="+url.QueryEscape(ext), 200)
	if xres.Content != "package outside\n" || !xres.External || xres.Path != ext {
		t.Fatalf("external file: %+v", xres)
	}
	// a new file outside the workspace: same new-file buffer, still external
	xnew := reviewGET[fileResult](t, c,
		"/workspaces/src/file?path="+url.QueryEscape(filepath.Join(extDir, "fresh.go")), 200)
	if !xnew.Missing || !xnew.External || xnew.Content != "" {
		t.Fatalf("external new file: %+v", xnew)
	}
	reviewGET[fileResult](t, c, "/workspaces/src/file?path=%2Fno%2Fsuch%2Fexternal.go", 404)

	// repo listing: tracked + untracked, .gitignore respected
	os.WriteFile(filepath.Join(repo, "loose.txt"), []byte("l\n"), 0o644)
	os.WriteFile(filepath.Join(repo, ".gitignore"), []byte("ignored.txt\n"), 0o644)
	os.WriteFile(filepath.Join(repo, "ignored.txt"), []byte("i\n"), 0o644)
	list := reviewGET[filesResult](t, c, "/workspaces/src/files", 200)
	got := strings.Join(list.Files, " ")
	if !strings.Contains(got, "a.txt") || !strings.Contains(got, "loose.txt") {
		t.Fatalf("repo listing: %v", list.Files)
	}
	if strings.Contains(got, "ignored.txt") {
		t.Fatalf("ignored file listed: %v", list.Files)
	}

	// non-repo root: WalkDir fallback, hidden/node_modules skipped —
	// and the file endpoint still serves it (the ` e viewer works
	// in any workspace)
	plain := t.TempDir()
	os.WriteFile(filepath.Join(plain, "notes.md"), []byte("n\n"), 0o644)
	os.MkdirAll(filepath.Join(plain, "sub"), 0o755)
	os.WriteFile(filepath.Join(plain, "sub", "deep.txt"), []byte("d\n"), 0o644)
	os.WriteFile(filepath.Join(plain, ".hidden"), []byte("h\n"), 0o644)
	os.MkdirAll(filepath.Join(plain, "node_modules", "x"), 0o755)
	os.WriteFile(filepath.Join(plain, "node_modules", "x", "j.js"), []byte("j\n"), 0o644)
	h.reg.upsert("plain", plain, false)
	list = reviewGET[filesResult](t, c, "/workspaces/plain/files", 200)
	got = strings.Join(list.Files, " ")
	if !strings.Contains(got, "notes.md") || !strings.Contains(got, "sub/deep.txt") {
		t.Fatalf("walk listing: %v", list.Files)
	}
	if strings.Contains(got, ".hidden") || strings.Contains(got, "node_modules") {
		t.Fatalf("walk listing leaked noise: %v", list.Files)
	}
	f := reviewGET[fileResult](t, c, "/workspaces/plain/file?path=sub/deep.txt", 200)
	if f.Content != "d\n" {
		t.Fatalf("non-repo file: %+v", f)
	}
}

func TestReviewWrite(t *testing.T) {
	h, srv, repo := newWorktreeHost(t)
	c := &wtClient{srv.URL, h.Token()}

	// round trip: save new content, it lands on disk verbatim
	code, body := c.do(t, "POST", "/workspaces/src/write", writeRequest{Path: "a.txt", Content: "changed\n"})
	if code != 200 {
		t.Fatalf("write: %d %s", code, body)
	}
	var res writeResult
	if err := json.Unmarshal([]byte(body), &res); err != nil {
		t.Fatalf("write result: %v in %s", err, body)
	}
	if res.Bytes != 8 {
		t.Fatalf("write bytes: %+v", res)
	}
	if got, _ := os.ReadFile(filepath.Join(repo, "a.txt")); string(got) != "changed\n" {
		t.Fatalf("on disk: %q", got)
	}

	// a save preserves the file's mode — an executable stays executable
	tool := filepath.Join(repo, "tool.sh")
	os.WriteFile(tool, []byte("#!/bin/sh\n"), 0o755)
	if code, body := c.do(t, "POST", "/workspaces/src/write", writeRequest{Path: "tool.sh", Content: "#!/bin/sh\necho hi\n"}); code != 200 {
		t.Fatalf("write tool.sh: %d %s", code, body)
	}
	if fi, err := os.Stat(tool); err != nil || fi.Mode().Perm() != 0o755 {
		t.Fatalf("mode not preserved: %v %v", fi.Mode().Perm(), err)
	}

	// confinePath still guards RELATIVE writes exactly like reads: a
	// relative path means "in this workspace", so ../ is a lie, not a door
	for _, rel := range []string{"../escape.txt", ""} {
		if code, _ := c.do(t, "POST", "/workspaces/src/write", writeRequest{Path: rel, Content: "x"}); code != 400 {
			t.Fatalf("write %q: got %d, want 400", rel, code)
		}
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(repo), "escape.txt")); !os.IsNotExist(err) {
		t.Fatalf("traversal write escaped the repo")
	}

	// the external tier: an ABSOLUTE path saves outside the workspace —
	// the write side of the read endpoint's external door
	outside := filepath.Join(t.TempDir(), "notes.md")
	os.WriteFile(outside, []byte("old\n"), 0o644)
	if code, body := c.do(t, "POST", "/workspaces/src/write", writeRequest{Path: outside, Content: "new\n"}); code != 200 {
		t.Fatalf("external write: %d %s", code, body)
	}
	if got, _ := os.ReadFile(outside); string(got) != "new\n" {
		t.Fatalf("external write on disk: %q", got)
	}

	// …and creates a file that isn't there yet (vim's `nvim newfile`)
	fresh := filepath.Join(filepath.Dir(outside), "fresh.txt")
	if code, body := c.do(t, "POST", "/workspaces/src/write", writeRequest{Path: fresh, Content: "hi\n"}); code != 200 {
		t.Fatalf("external create: %d %s", code, body)
	}
	if got, _ := os.ReadFile(fresh); string(got) != "hi\n" {
		t.Fatalf("external create on disk: %q", got)
	}

	// a missing parent dir is a 404, not a 500 — rook never mkdir -p's
	if code, _ := c.do(t, "POST", "/workspaces/src/write", writeRequest{Path: filepath.Join(fresh, "deeper", "x.txt"), Content: "x"}); code != 404 {
		t.Fatalf("missing parent: got %d, want 404", code)
	}
	// a directory is not a file
	if code, _ := c.do(t, "POST", "/workspaces/src/write", writeRequest{Path: filepath.Dir(outside), Content: "x"}); code != 400 {
		t.Fatalf("write to a directory: got %d, want 400", code)
	}

	// unknown workspace → 404
	if code, _ := c.do(t, "POST", "/workspaces/nope/write", writeRequest{Path: "a.txt", Content: "x"}); code != 404 {
		t.Fatalf("unknown workspace: got %d, want 404", code)
	}
}

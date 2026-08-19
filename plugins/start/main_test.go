package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// testBuilder is the whole screen with nothing real behind it: a
// journal on disk, git answered from a map, no sessions.
func testBuilder(t *testing.T, journal string, git map[string]string) *builder {
	t.Helper()
	return &builder{
		journal:  journal,
		projects: "", // no sessions section unless a test asks for one
		art:      []string{"ART"},
		recent:   3,
		changed:  3,
		sessions: 2,
		window:   12 * time.Hour,
		now:      func() time.Time { return time.Unix(1_800_000_000, 0) },
		git: func(dir string, args ...string) (string, error) {
			out, ok := git[strings.Join(args, " ")]
			if !ok {
				return "", os.ErrNotExist
			}
			return out, nil
		},
	}
}

func writeJournal(t *testing.T, dir string, paths ...string) string {
	t.Helper()
	p := filepath.Join(dir, "oldfiles")
	if err := os.WriteFile(p, []byte(strings.Join(paths, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func touch(t *testing.T, path string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func rowsOfKind(rows []row, kind string) []row {
	out := []row{}
	for _, r := range rows {
		if r.Kind == kind {
			out = append(out, r)
		}
	}
	return out
}

func findLabel(rows []row, label string) (row, bool) {
	for _, r := range rows {
		if r.Label == label {
			return r, true
		}
	}
	return row{}, false
}

func TestRecentSplitsByRepo(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "repo")
	in := touch(t, filepath.Join(root, "src", "editor.zig"))
	out := touch(t, filepath.Join(dir, "elsewhere", "notes.md"))
	j := writeJournal(t, dir, in, out)

	rows := testBuilder(t, j, nil).build(root)

	// The in-repo file is labelled RELATIVE to the root: the part of a
	// path that repeats on every row is the part nobody reads.
	if r, ok := findLabel(rows, "src/editor.zig"); !ok || r.Path != in {
		t.Fatalf("in-repo row missing or wrong: %+v", r)
	}
	if _, ok := findLabel(rows, "src/editor.zig"); !ok {
		t.Fatal("expected the repo-relative label")
	}
	// The other one keeps a whole path, because a bare basename from
	// another project says nothing about which project.
	found := false
	for _, r := range rows {
		if r.Path == out {
			found = true
			if !strings.HasSuffix(r.Label, "elsewhere/notes.md") {
				t.Fatalf("elsewhere row should keep its path, got %q", r.Label)
			}
		}
	}
	if !found {
		t.Fatal("the file outside the repo was dropped")
	}
	// Two headings, and the in-repo one names the repo.
	heads := rowsOfKind(rows, "heading")
	if len(heads) < 2 || !strings.Contains(heads[0].Label, "repo") {
		t.Fatalf("headings: %+v", heads)
	}
}

func TestVanishedFilesAreNotOffered(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "repo")
	alive := touch(t, filepath.Join(root, "alive.go"))
	j := writeJournal(t, dir, filepath.Join(root, "deleted.go"), alive)

	rows := testBuilder(t, j, nil).build(root)
	for _, r := range rows {
		if strings.Contains(r.Path, "deleted.go") {
			t.Fatal("a journal entry outlived its file and was offered anyway")
		}
	}
	if _, ok := findLabel(rows, "alive.go"); !ok {
		t.Fatal("the surviving file should still be there")
	}
}

func TestJumpLettersAreUniqueAndSpareTheActions(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "repo")
	paths := []string{}
	for _, n := range []string{"a.go", "b.go", "c.go"} {
		paths = append(paths, touch(t, filepath.Join(root, n)))
	}
	touch(t, filepath.Join(root, "dirty.go"))
	j := writeJournal(t, dir, paths...)

	b := testBuilder(t, j, map[string]string{
		"rev-parse --abbrev-ref HEAD": "main\n",
		"status --porcelain":          " M dirty.go\n",
	})
	rows := b.build(root)

	seen := map[string]string{}
	for _, r := range rows {
		if r.Key == "" {
			continue
		}
		if prev, dup := seen[r.Key]; dup {
			t.Fatalf("key %q reaches both %q and %q", r.Key, prev, r.Label)
		}
		seen[r.Key] = r.Label
	}
	// The action letters are fixed: a hand that learns `q` must not
	// find a file there tomorrow because the journal changed.
	for _, k := range []string{"f", "p", "w", "g", "q"} {
		if _, ok := seen[k]; !ok {
			t.Fatalf("action key %q went missing", k)
		}
	}
	if got := seen["f"]; got != "find a file" {
		t.Fatalf("f should stay the file finder, got %q", got)
	}
}

func TestGitHeadlineAndChanges(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "repo")
	touch(t, filepath.Join(root, "one.go"))
	touch(t, filepath.Join(root, "two.go"))
	j := writeJournal(t, dir)

	b := testBuilder(t, j, map[string]string{
		"rev-parse --abbrev-ref HEAD": "feature/start-screen\n",
		"status --porcelain":          " M one.go\n?? two.go\n D gone.go\n",
	})
	rows := b.build(root)

	head := ""
	for _, r := range rows {
		if r.Kind == "art" && strings.Contains(r.Label, "feature/start-screen") {
			head = r.Label
		}
	}
	if head == "" {
		t.Fatal("no headline with the branch on it")
	}
	if !strings.Contains(head, "3 changed") {
		t.Fatalf("headline should count every change, got %q", head)
	}
	// The deleted file is counted but not OFFERED: there is nothing to
	// open, and a row that refuses when pressed is worse than no row.
	for _, r := range rows {
		if strings.HasSuffix(r.Path, "gone.go") {
			t.Fatal("a deleted file was offered as a row")
		}
	}
	if r, ok := findLabel(rows, "one.go"); !ok || r.Detail != "M" {
		t.Fatalf("changed row wrong: %+v", r)
	}
}

func TestNoRepoStillHasAScreen(t *testing.T) {
	dir := t.TempDir()
	loose := touch(t, filepath.Join(dir, "loose.txt"))
	j := writeJournal(t, dir, loose)

	rows := testBuilder(t, j, nil).build("") // a pane in no repository

	if len(rowsOfKind(rows, "art")) == 0 {
		t.Fatal("the header should survive having no repo")
	}
	if _, ok := findLabel(rows, "find a file"); !ok {
		t.Fatal("the actions should survive having no repo")
	}
	found := false
	for _, r := range rows {
		if r.Path == loose {
			found = true
		}
	}
	if !found {
		t.Fatal("recents should survive having no repo")
	}
}

func TestEmptySectionsAreDroppedWhole(t *testing.T) {
	dir := t.TempDir()
	j := filepath.Join(dir, "no-such-journal")

	rows := testBuilder(t, j, nil).build("")
	for _, r := range rows {
		if r.Kind == "heading" && strings.HasPrefix(r.Label, "recent") {
			t.Fatal("a heading was drawn over an empty section")
		}
	}
}

func TestServeAnswersDescribeAndIntro(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "repo")
	f := touch(t, filepath.Join(root, "x.go"))
	j := writeJournal(t, dir, f)

	inR, inW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	req := `{"v":1,"id":1,"op":"describe","params":{}}` + "\n" +
		`{"v":1,"id":2,"op":"intro.list","params":{"root":` + quote(root) + `,"limit":64}}` + "\n" +
		`{"v":1,"id":3,"op":"items.list","params":{}}` + "\n"
	go func() {
		inW.WriteString(req)
		inW.Close()
	}()
	done := make(chan struct{})
	go func() {
		serve(testBuilder(t, j, nil), inR, outW)
		outW.Close()
		close(done)
	}()

	var got []map[string]any
	dec := json.NewDecoder(outR)
	for {
		var m map[string]any
		if err := dec.Decode(&m); err != nil {
			break
		}
		got = append(got, m)
	}
	<-done

	if len(got) != 3 {
		t.Fatalf("expected three replies, got %d: %+v", len(got), got)
	}
	caps := got[0]["result"].(map[string]any)["capabilities"].([]any)
	if len(caps) != 1 || caps[0] != "intro.list" {
		t.Fatalf("describe should claim intro.list alone: %+v", caps)
	}
	rows := got[1]["result"].(map[string]any)["rows"].([]any)
	if len(rows) == 0 {
		t.Fatal("intro.list answered with nothing")
	}
	// An op this plugin does not serve is REFUSED, not answered with an
	// empty success — a plugin that says ok to everything is a plugin
	// whose grants mean nothing.
	if got[2]["ok"] != false {
		t.Fatalf("items.list should be refused: %+v", got[2])
	}
}

func quote(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

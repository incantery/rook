package host

import (
	"testing"
)

func recentsReg(t *testing.T) *registry {
	t.Helper()
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	r := loadRegistry()
	if r.db == nil {
		t.Fatal("test registry has no db")
	}
	return r
}

func paths(rs []Recent) []string {
	out := make([]string, len(rs))
	for i, r := range rs {
		out[i] = r.Path
	}
	return out
}

func eq(t *testing.T, got, want []string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}

func TestRecentsNewestFirst(t *testing.T) {
	r := recentsReg(t)
	for _, p := range []string{"a.go", "b.go", "c.go"} {
		if err := r.touchRecent("ws", p); err != nil {
			t.Fatal(err)
		}
	}
	eq(t, paths(r.recentList("ws", 0)), []string{"c.go", "b.go", "a.go"})
}

// Re-opening a file MOVES it rather than duplicating: the primary key is
// (workspace, path), and a greeter that listed the same path three times
// would be showing history instead of a working set.
func TestRecentsRetouchPromotes(t *testing.T) {
	r := recentsReg(t)
	for _, p := range []string{"a.go", "b.go", "c.go", "a.go"} {
		if err := r.touchRecent("ws", p); err != nil {
			t.Fatal(err)
		}
	}
	eq(t, paths(r.recentList("ws", 0)), []string{"a.go", "c.go", "b.go"})
}

func TestRecentsScopedByWorkspace(t *testing.T) {
	r := recentsReg(t)
	if err := r.touchRecent("one", "a.go"); err != nil {
		t.Fatal(err)
	}
	if err := r.touchRecent("two", "b.go"); err != nil {
		t.Fatal(err)
	}
	eq(t, paths(r.recentList("one", 0)), []string{"a.go"})
	eq(t, paths(r.recentList("two", 0)), []string{"b.go"})
}

// The cap is enforced on write, so the table cannot grow for the lifetime of
// a workspace. The OLDEST entries are the ones that go.
func TestRecentsTrimsToCap(t *testing.T) {
	r := recentsReg(t)
	var written []string
	for i := range recentsCap + 10 {
		p := string(rune('a'+i%26)) + string(rune('0'+i/26)) + ".go"
		written = append(written, p)
		if err := r.touchRecent("ws", p); err != nil {
			t.Fatal(err)
		}
	}
	got := r.recentList("ws", recentsCap)
	if len(got) != recentsCap {
		t.Fatalf("kept %d, want the cap %d", len(got), recentsCap)
	}
	// the most recent write survives the trim; the oldest is what goes
	if last := written[len(written)-1]; got[0].Path != last {
		t.Fatalf("newest is %q, want the last write %q", got[0].Path, last)
	}
	for _, r := range got {
		if r.Path == written[0] {
			t.Fatalf("oldest write %q survived the trim", written[0])
		}
	}
}

func TestRecentsForget(t *testing.T) {
	r := recentsReg(t)
	for _, p := range []string{"a.go", "b.go"} {
		if err := r.touchRecent("ws", p); err != nil {
			t.Fatal(err)
		}
	}
	if err := r.forgetRecent("ws", "b.go"); err != nil {
		t.Fatal(err)
	}
	eq(t, paths(r.recentList("ws", 0)), []string{"a.go"})
}

// Fail open, the house rule: no store is an empty list, never a panic and
// never an error the caller has to special-case.
func TestRecentsNoStoreFailsOpen(t *testing.T) {
	r := &registry{}
	if err := r.touchRecent("ws", "a.go"); err != nil {
		t.Fatalf("touch with no db: %v", err)
	}
	if got := r.recentList("ws", 0); len(got) != 0 {
		t.Fatalf("got %v, want empty", got)
	}
	// an empty workspace or path is nothing to remember, not a failure
	if err := r.touchRecent("", ""); err != nil {
		t.Fatal(err)
	}
}

package picker

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// The new-workspace key must not be one of the keys that move through
// the list: fzf's ctrl-n/ctrl-p selection is the behaviour people
// already have, and adding a verb must not cost it. Placing the cursor
// is allowed to bind, but only the `load` event — never a key.
func TestArgsLeaveListMovementAlone(t *testing.T) {
	if NewKey == "ctrl-n" || NewKey == "ctrl-p" {
		t.Fatalf("NewKey %q is a list-movement key", NewKey)
	}
	for _, pos := range []int{0, 1, 2, 7} {
		for _, a := range Args(pos) {
			if strings.HasPrefix(a, "--bind") && !strings.HasPrefix(a, "--bind=load:") {
				t.Fatalf("Args(%d) binds something other than the load event (%q); fzf's own key bindings must stand", pos, a)
			}
			if a != "--expect="+NewKey && (strings.Contains(a, "ctrl-n") || strings.Contains(a, "ctrl-p")) {
				t.Fatalf("Args(%d) touches ctrl-n/ctrl-p: %q", pos, a)
			}
		}
	}
}

// The picker opens pointing at the row it was told to, and asks for
// nothing when there is nothing to point at.
func TestArgsPlaceTheCursor(t *testing.T) {
	for _, pos := range []int{0, 1} {
		for _, a := range Args(pos) {
			if strings.HasPrefix(a, "--bind") {
				t.Errorf("Args(%d) placed the cursor (%q); the top row is where fzf already is", pos, a)
			}
		}
	}
	if got := strings.Join(Args(3), " "); !strings.Contains(got, "--bind=load:pos(3)") {
		t.Errorf("Args(3) does not open on row 3: %v", Args(3))
	}
}

// --print-query and --expect are what let one list answer two verbs.
func TestArgsAskForQueryAndKey(t *testing.T) {
	joined := strings.Join(Args(0), " ")
	for _, want := range []string{"--print-query", "--expect=" + NewKey} {
		if !strings.Contains(joined, want) {
			t.Errorf("Args missing %q: %v", want, Args(0))
		}
	}
	if !strings.Contains(joined, NewKey+" new") {
		t.Errorf("the header does not say how to create: %v", Args(0))
	}
}

// The row the picker opens on is counted over the rows fzf is handed,
// which is not every name given: Run drops the blank ones.
func TestStartPos(t *testing.T) {
	names := []string{"rook", "", "dora", "  ", "weave"}
	cases := []struct {
		name    string
		current string
		want    int
	}{
		{"the first row", "rook", 1},
		{"a blank name does not take a row", "dora", 2},
		{"the last row", "weave", 3},
		{"a workspace that is not listed", "gone", 0},
		{"no current workspace", "", 0},
		{"whitespace is not a name", "   ", 0},
		{"a current name is trimmed like the rows are", "  dora  ", 2},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := StartPos(names, c.current); got != c.want {
				t.Errorf("StartPos(%q) = %d, want %d", c.current, got, c.want)
			}
		})
	}
}

// Placing the cursor needs the `load` event and the `pos` action, both
// fzf 0.36; an fzf too old for them exits on what it cannot parse, so
// an unreadable version means no.
func TestPlacesCursor(t *testing.T) {
	cases := map[string]bool{
		"0.74.3 (Homebrew)\n": true,
		"0.36.0":              true,
		"0.35.0 (brew)":       false,
		"1.0.0":               true,
		"0.24.4-2":            false,
		"":                    false,
		"unknown":             false,
		"x.y.z":               false,
	}
	for out, want := range cases {
		if got := placesCursor(out); got != want {
			t.Errorf("placesCursor(%q) = %v, want %v", out, got, want)
		}
	}
}

func TestDecide(t *testing.T) {
	cases := []struct {
		name string
		out  string
		want Choice
	}{
		{"enter picks the row", "\n\nrook\n", Choice{Switch, "rook"}},
		{"a query that matched still switches", "ro\n\nrook\n", Choice{Switch, "rook"}},
		{"the new key names the workspace", "notes\n" + NewKey + "\n", Choice{New, "notes"}},
		{"the new key beats the highlighted row", "notes\n" + NewKey + "\nrook\n", Choice{New, "notes"}},
		{"an existing name is still a create (the server dedupes)", "rook\n" + NewKey + "\nrook\n", Choice{New, "rook"}},
		{"the new key with nothing typed asks for nothing", "\n" + NewKey + "\nrook\n", Choice{}},
		{"whitespace is not a name", "   \n" + NewKey + "\n", Choice{}},
		{"esc prints nothing", "", Choice{}},
		{"enter with no match does nothing", "zz\n\n", Choice{}},
		{"a row is trimmed", "\n\n  rook  \n", Choice{Switch, "rook"}},
		{"separators in a typed name are flattened", "a\tb\n" + NewKey + "\n", Choice{New, "a b"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := Decide(c.out); got != c.want {
				t.Errorf("Decide(%q) = %+v, want %+v", c.out, got, c.want)
			}
		})
	}
}

// stubFzf points the package at a script that answers --version, records
// the arguments it was called with, prints what it is told to, and exits
// with the given code. It returns the file holding those arguments.
func stubFzf(t *testing.T, stdout string, code int) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "fzf")
	args := filepath.Join(dir, "args")
	script := "#!/bin/sh\n" +
		"if [ \"$1\" = --version ]; then echo '0.74.3 (stub)'; exit 0; fi\n" +
		"printf '%s\\n' \"$@\" > " + shellQuote(args) + "\n" +
		"cat >/dev/null\nprintf %s " + shellQuote(stdout) + "\nexit " + strconv.Itoa(code) + "\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	old := fzf
	fzf = path
	t.Cleanup(func() { fzf = old })
	return args
}

// fzfArgs is what the stub was called with.
func fzfArgs(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("the picker was never run: %v", err)
	}
	return string(b)
}

func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

func TestRun(t *testing.T) {
	cases := []struct {
		name string
		out  string
		code int
		want Choice
	}{
		{"a switch", "\n\nrook\n", 0, Choice{Switch, "rook"}},
		// exit 1 is fzf's "nothing matched" — which is the normal way
		// to reach a workspace that does not exist yet
		{"a create over an empty list", "notes\n" + NewKey + "\n", 1, Choice{New, "notes"}},
		{"esc", "", 130, Choice{}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			stubFzf(t, c.out, c.code)
			got, err := Run([]string{"rook", "dora"}, "")
			if err != nil {
				t.Fatalf("Run: %v", err)
			}
			if got != c.want {
				t.Errorf("Run = %+v, want %+v", got, c.want)
			}
		})
	}
}

// The picker opens on the workspace you are in — that is what makes
// the list say where you are standing before you press anything.
func TestRunOpensOnTheCurrentWorkspace(t *testing.T) {
	cases := []struct {
		name    string
		current string
		want    string
	}{
		{"the workspace you are in", "weave", "--bind=load:pos(3)"},
		{"the top row needs no placing", "rook", ""},
		{"a workspace that is gone", "nope", ""},
		{"nowhere in particular", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			args := stubFzf(t, "\n\nrook\n", 0)
			if _, err := Run([]string{"rook", "dora", "weave"}, c.current); err != nil {
				t.Fatalf("Run: %v", err)
			}
			got := fzfArgs(t, args)
			if c.want == "" {
				if strings.Contains(got, "--bind") {
					t.Errorf("current %q placed the cursor: %q", c.current, got)
				}
				return
			}
			if !strings.Contains(got, c.want) {
				t.Errorf("current %q: args %q do not contain %q", c.current, got, c.want)
			}
		})
	}
}

// An fzf too old to place the cursor still opens; it just opens where
// it always did, rather than dying on a binding it cannot parse.
func TestRunSkipsPlacementOnOldFzf(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "fzf")
	args := filepath.Join(dir, "args")
	script := "#!/bin/sh\n" +
		"if [ \"$1\" = --version ]; then echo '0.35.0'; exit 0; fi\n" +
		"printf '%s\\n' \"$@\" > " + shellQuote(args) + "\ncat >/dev/null\nprintf '\\n\\nrook\\n'\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	old := fzf
	fzf = path
	t.Cleanup(func() { fzf = old })
	got, err := Run([]string{"rook", "dora"}, "dora")
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if got != (Choice{Switch, "rook"}) {
		t.Errorf("Run = %+v", got)
	}
	if a := fzfArgs(t, args); strings.Contains(a, "--bind") {
		t.Errorf("an fzf that cannot place the cursor was handed a placement: %q", a)
	}
}

func TestRunReportsFzfTrouble(t *testing.T) {
	stubFzf(t, "", 2)
	if _, err := Run(nil, ""); err == nil {
		t.Error("an fzf error should not read as a quiet cancel")
	}
}

func TestRunWithoutFzf(t *testing.T) {
	old := fzf
	fzf = "rook-no-such-picker-binary"
	t.Cleanup(func() { fzf = old })
	_, err := Run(nil, "")
	if err == nil || !strings.Contains(err.Error(), "fzf") {
		t.Errorf("want an error naming fzf, got %v", err)
	}
}

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
// already have, and adding a verb must not cost it.
func TestArgsLeaveListMovementAlone(t *testing.T) {
	if NewKey == "ctrl-n" || NewKey == "ctrl-p" {
		t.Fatalf("NewKey %q is a list-movement key", NewKey)
	}
	for _, a := range Args() {
		if strings.HasPrefix(a, "--bind") {
			t.Fatalf("Args rebinds keys (%q); fzf's own bindings must stand", a)
		}
		if a != "--expect="+NewKey && (strings.Contains(a, "ctrl-n") || strings.Contains(a, "ctrl-p")) {
			t.Fatalf("Args touches ctrl-n/ctrl-p: %q", a)
		}
	}
}

// --print-query and --expect are what let one list answer two verbs.
func TestArgsAskForQueryAndKey(t *testing.T) {
	joined := strings.Join(Args(), " ")
	for _, want := range []string{"--print-query", "--expect=" + NewKey} {
		if !strings.Contains(joined, want) {
			t.Errorf("Args missing %q: %v", want, Args())
		}
	}
	if !strings.Contains(joined, NewKey+" new") {
		t.Errorf("the header does not say how to create: %v", Args())
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

// stubFzf points the package at a script that ignores its arguments,
// prints what it is told to, and exits with the given code.
func stubFzf(t *testing.T, stdout string, code int) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "fzf")
	script := "#!/bin/sh\ncat >/dev/null\nprintf %s " + shellQuote(stdout) + "\nexit " + strconv.Itoa(code) + "\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	old := fzf
	fzf = path
	t.Cleanup(func() { fzf = old })
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
			got, err := Run([]string{"rook", "dora"})
			if err != nil {
				t.Fatalf("Run: %v", err)
			}
			if got != c.want {
				t.Errorf("Run = %+v, want %+v", got, c.want)
			}
		})
	}
}

func TestRunReportsFzfTrouble(t *testing.T) {
	stubFzf(t, "", 2)
	if _, err := Run(nil); err == nil {
		t.Error("an fzf error should not read as a quiet cancel")
	}
}

func TestRunWithoutFzf(t *testing.T) {
	old := fzf
	fzf = "rook-no-such-picker-binary"
	t.Cleanup(func() { fzf = old })
	_, err := Run(nil)
	if err == nil || !strings.Contains(err.Error(), "fzf") {
		t.Errorf("want an error naming fzf, got %v", err)
	}
}

package namer

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
)

// world is a fake engine and a fake namer command.
type world struct {
	now      time.Time
	nameBy   string
	name     string
	cwd      string
	title    string
	outputMs int64
	answer   string
	asked    int
	renames  []string
	lastCtx  string
}

func (w *world) engine(args ...string) (string, error) {
	switch args[0] {
	case "state":
		return fmt.Sprintf(`{"workspaces":[{"name":"main","windows":[{"name":%q,"nameBy":%q,
			"layout":{"split":"h","a":{"pane":7},"b":{"pane":3}}}]}],
			"panes":[{"id":3,"program":"claude","cwd":%q,"title":%q,"lastOutputMs":%d},
			         {"id":7,"program":"zsh","cwd":"/elsewhere","lastOutputMs":5}]}`,
			w.name, w.nameBy, w.cwd, w.title, w.outputMs), nil
	case "read":
		return "line one\n\n   \nline two\n", nil
	case "rename":
		w.renames = append(w.renames, strings.Join(args[1:], " "))
		w.name, w.nameBy = args[3], "model"
		return "", nil
	}
	return "", fmt.Errorf("unexpected %v", args)
}

func (w *world) namer() *Namer {
	return New(Options{
		Engine: w.engine,
		Ask: func(_ context.Context, c string) (string, error) {
			w.asked++
			w.lastCtx = c
			return w.answer, nil
		},
		Git: func(dir string) (string, string) { return "rook", "main" },
		Now: func() time.Time { return w.now },
	})
}

func newWorld() *world {
	return &world{now: time.Unix(1_000_000, 0), nameBy: "program", name: "zoxide",
		cwd: "/src/rook", title: "◑ Tab names", outputMs: 10, answer: "rook tab names\n"}
}

func TestSettlesThenNamesOnce(t *testing.T) {
	w := newWorld()
	n := w.namer()
	n.Tick(context.Background())
	if w.asked != 0 {
		t.Fatal("asked before the tab's facts had settled")
	}
	w.now = w.now.Add(settle)
	n.Tick(context.Background())
	if len(w.renames) != 1 || w.renames[0] != "--suggest 3 rook tab names" {
		t.Fatalf("renames = %q", w.renames)
	}
	// the lowest pane speaks for the window, the project is a fact,
	// and blank screen lines are not sent
	for _, want := range []string{"project: rook\n", "program: claude\n", "title: Tab names\n", "screen:\nline one\nline two\n"} {
		if !strings.Contains(w.lastCtx, want) {
			t.Errorf("context lacks %q:\n%s", want, w.lastCtx)
		}
	}
	w.now = w.now.Add(time.Minute)
	n.Tick(context.Background())
	if w.asked != 1 {
		t.Fatalf("asked %d times about unchanged facts", w.asked)
	}
}

func TestASpinningTitleIsNotNews(t *testing.T) {
	w := newWorld()
	n := w.namer()
	n.Tick(context.Background())
	w.now = w.now.Add(settle)
	n.Tick(context.Background())
	w.title = "◐ Tab names"
	w.now = w.now.Add(settle)
	n.Tick(context.Background())
	w.now = w.now.Add(settle)
	n.Tick(context.Background())
	if w.asked != 1 {
		t.Fatalf("a spinner glyph cost %d questions", w.asked-1)
	}
}

func TestNewFactsRenameAtOnce(t *testing.T) {
	w := newWorld()
	n := w.namer()
	n.Tick(context.Background())
	w.now = w.now.Add(settle)
	n.Tick(context.Background())
	w.title, w.answer = "Release notes", "rook release notes"
	n.Tick(context.Background())
	w.now = w.now.Add(settle)
	n.Tick(context.Background())
	if len(w.renames) != 2 || w.name != "rook release notes" {
		t.Fatalf("renames = %q", w.renames)
	}
}

func TestAHandNameIsNeverAskedAbout(t *testing.T) {
	w := newWorld()
	w.nameBy = "hand"
	n := w.namer()
	for i := 0; i < 3; i++ {
		n.Tick(context.Background())
		w.now = w.now.Add(refresh)
	}
	if w.asked != 0 || len(w.renames) != 0 {
		t.Fatalf("asked %d, renamed %q", w.asked, w.renames)
	}
}

func TestARefreshMustSayItTwice(t *testing.T) {
	w := newWorld()
	n := w.namer()
	n.Tick(context.Background())
	w.now = w.now.Add(settle)
	n.Tick(context.Background())

	// same facts, new output, a different answer: once is not enough
	w.now = w.now.Add(refresh)
	w.outputMs, w.answer = 20, "rook flicker"
	n.Tick(context.Background())
	if len(w.renames) != 1 {
		t.Fatalf("a refresh renamed on its first word: %q", w.renames)
	}
	// the second opinion differs: nothing lands
	w.now = w.now.Add(time.Minute)
	w.outputMs, w.answer = 30, "rook other"
	n.Tick(context.Background())
	if len(w.renames) != 1 {
		t.Fatalf("two different answers renamed the tab: %q", w.renames)
	}
	// said twice: it lands
	w.now = w.now.Add(time.Minute)
	w.outputMs = 40
	n.Tick(context.Background())
	if len(w.renames) != 2 || w.name != "rook other" {
		t.Fatalf("renames = %q", w.renames)
	}
	// and with no new output there is nothing to ask about
	asked := w.asked
	w.now = w.now.Add(refresh)
	n.Tick(context.Background())
	if w.asked != asked {
		t.Fatal("asked about a tab that printed nothing since")
	}
}

func TestAnswersThatAreNotNames(t *testing.T) {
	for _, answer := range []string{"", "\n", "claude", "zoxide"} {
		w := newWorld()
		w.answer = answer
		n := w.namer()
		n.Tick(context.Background())
		w.now = w.now.Add(settle)
		n.Tick(context.Background())
		if len(w.renames) != 0 {
			t.Errorf("answer %q renamed the tab: %q", answer, w.renames)
		}
	}
}

func TestClamp(t *testing.T) {
	for in, want := range map[string]string{
		"  rook tab names \nsecond line":            "rook tab names",
		"deployment_tools retention sweep and more": "deployment_tools retention sweep",
		"naïve café naïve café naïve café x":        "naïve café naïve café naïve",
		"a\x1b[31mb": "a[31mb",
	} {
		if got := Clamp(in); got != want || len(got) > maxName {
			t.Errorf("Clamp(%q) = %q, want %q", in, got, want)
		}
	}
}

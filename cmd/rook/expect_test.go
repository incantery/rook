package main

import (
	"encoding/json"
	"regexp"
	"strings"
	"testing"
)

// A small screen: a filled bold header, a highlighted row with a wide
// glyph in it, a plain row, and the cursor.
const testGrid = `{"cols":20,"rows":4,"cursor":{"x":2,"y":3,"visible":true},"lines":[
 {"y":0,"text":" todo  1/3 done","bg":"#0000ff","runs":[{"x":0,"w":20,"text":" todo  1/3 done     ","fg":"#ffffff","bg":"#0000ff","bold":true}]},
 {"y":1,"text":" [x] 日本 ok","runs":[{"x":1,"w":4,"text":"[x] ","bg":"#ffff00"},{"x":5,"w":2,"text":"日","cluster":true,"bg":"#ffff00"},{"x":7,"w":2,"text":"本","cluster":true,"bg":"#ffff00"},{"x":9,"w":3,"text":" ok","bg":"#ffff00"}]},
 {"y":2,"text":" [ ] ok","runs":[{"x":1,"w":6,"text":"[ ] ok"}]},
 {"y":3,"text":"$","runs":[{"x":0,"w":1,"text":"$"}]}]}`

func testScreen(t *testing.T) *screen {
	t.Helper()
	var g shotGrid
	if err := json.Unmarshal([]byte(testGrid), &g); err != nil {
		t.Fatal(err)
	}
	return newScreen(g, 1)
}

func TestFind(t *testing.T) {
	s := testScreen(t)
	// text after wide glyphs is found at its cell, not its character
	ok := s.find("ok", nil, -1)
	if len(ok) != 2 || ok[0].X != 10 || ok[0].Y != 1 || ok[1].X != 5 || ok[1].Y != 2 {
		t.Fatalf("ok found at %v", ok)
	}
	if ok[0].Bg != "#ffff00" || ok[1].Bg != "" {
		t.Errorf("styles: %v", ok)
	}
	// a wide glyph is as wide as its cells
	wide := s.find("日本", nil, -1)
	if len(wide) != 1 || wide[0].X != 5 || wide[0].W != 4 {
		t.Fatalf("wide found at %v", wide)
	}
	if got := s.find("", regexp.MustCompile(`\d/\d done`), 0); len(got) != 1 || got[0].X != 7 || got[0].Text != "1/3 done" || !got[0].Bold {
		t.Fatalf("regex found %v", got)
	}
	if got := s.find("ok", nil, 2); len(got) != 1 || got[0].Y != 2 {
		t.Fatalf("--row found %v", got)
	}
	if got := s.find("nowhere", nil, -1); got != nil {
		t.Fatalf("found %v", got)
	}
	if !strings.HasPrefix(s.text(), " todo  1/3 done\n [x] 日本 ok\n") {
		t.Errorf("text = %q", s.text())
	}
}

func TestExpectCheck(t *testing.T) {
	s := testScreen(t)
	cases := []struct {
		args []string
		ok   bool
		why  string
	}{
		{[]string{"1/3 done"}, true, ""},
		{[]string{"1/3 done", "--row", "0", "--bold", "--fg", "#FFFFFF", "--bg", "#0000ff"}, true, ""},
		{[]string{"1/3 done", "--row", "1"}, false, "not on row 1"},
		{[]string{"2/3 done"}, false, "not on the screen"},
		{[]string{"ok", "--bg", "#ffff00"}, true, ""},
		{[]string{"ok", "--bg", "#ffff00", "--count", "1"}, true, ""},
		{[]string{"ok", "--count", "2"}, true, ""},
		{[]string{"ok", "--count", "3"}, false, "2 times, not 3"},
		{[]string{"ok", "--bg", "#ff0000"}, false, "not drawn as asked"},
		{[]string{"ok", "--row", "2", "--bg", "default"}, true, ""},
		{[]string{"ok", "--row", "1", "--bg", "default"}, false, "not drawn as asked"},
		{[]string{"--no-text", "error"}, true, ""},
		{[]string{"--no-text", "todo"}, false, "is on the screen"},
		{[]string{"--line-bg", "#0000ff", "--row", "0"}, true, ""},
		{[]string{"--line-bg", "#0000ff"}, true, ""},
		{[]string{"--line-bg", "#0000ff", "--row", "1"}, false, "not filled"},
		{[]string{"--line-bg", "#00ff00"}, false, "no row is filled"},
		{[]string{"--cursor", "2,3"}, true, ""},
		{[]string{"--cursor", "0,0"}, false, "cursor is at 2,3"},
		{[]string{"--regex", `\[x\] .* ok`}, true, ""},
		{[]string{"nope", "--count", "0"}, true, ""},
	}
	for _, c := range cases {
		w, said, err := parseWant("expect", c.args)
		if err != nil {
			t.Errorf("%v: %v", c.args, err)
			continue
		}
		w.said = said
		got := w.check(s)
		if (got == nil) != c.ok {
			t.Errorf("%v: got %v, want ok=%v", c.args, got, c.ok)
		} else if got != nil && !strings.Contains(got.Error(), c.why) {
			t.Errorf("%v: said %q, want it to say %q", c.args, got, c.why)
		}
	}
}

func TestParseWant(t *testing.T) {
	// a pane first, when the first word is one
	w, _, err := parseWant("expect", []string{"7", "hello"})
	if err != nil || w.pane != "7" || w.text != "hello" {
		t.Fatalf("pane and text: %+v %v", w, err)
	}
	w, _, _ = parseWant("expect", []string{"hello world"})
	if w.pane != "" || w.text != "hello world" {
		t.Fatalf("text alone: %+v", w)
	}
	// a number that is the text is said with --text
	w, _, _ = parseWant("expect", []string{"--text", "42"})
	if w.pane != "" || w.text != "42" {
		t.Fatalf("--text: %+v", w)
	}
	w, _, err = parseWant("click", []string{"3", "10,4"})
	if err != nil || w.pane != "3" || !w.cellSaid || w.x != 10 || w.y != 4 {
		t.Fatalf("click cell: %+v %v", w, err)
	}
	w, _, err = parseWant("click", []string{"10,4"})
	if err != nil || w.pane != "" || !w.cellSaid || w.x != 10 {
		t.Fatalf("click cell alone: %+v %v", w, err)
	}
	for _, bad := range [][]string{{"--fg", "red"}, {"--row"}, {"--bogus"}, {"a", "b"}, {"--timeout", "-1"}, {"--cursor", "3"}} {
		if _, _, err := parseWant("expect", bad); err == nil {
			t.Errorf("parsed anyway: %v", bad)
		}
	}
}

func TestShellJoin(t *testing.T) {
	for in, want := range map[string]string{
		"key":         "key",
		"hello world": "'hello world'",
		"":            "''",
		"it's":        `'it'\''s'`,
		"--bg=#fff":   "--bg=#fff",
	} {
		if got := shellJoin([]string{in}); got != want {
			t.Errorf("shellJoin(%q) = %s, want %s", in, got, want)
		}
	}
}

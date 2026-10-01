package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/incantery/rook/internal/mux"
)

// find, expect and click: the three verbs that turn a shot into a
// test (docs/play.md). A terminal has no elements to name, so the
// locator is text — where it is on the grid, and how it is drawn.
// All three read `rook shot --json`; none of them holds anything.

// screen is one shot with every cell laid out: what is at (x, y).
type screen struct {
	grid  shotGrid
	cells [][]cell
	// pane is the pane the shot is of, 0 for the whole glass.
	pane int
}

type cell struct {
	text string   // "" for the tail of a wide glyph
	run  *shotRun // nil for a blank in the default style
}

// A match is text found: where, how wide in cells, and how its first
// cell is drawn.
type match struct {
	X     int    `json:"x"`
	Y     int    `json:"y"`
	W     int    `json:"w"`
	Text  string `json:"text"`
	Fg    string `json:"fg,omitempty"`
	Bg    string `json:"bg,omitempty"`
	Bold  bool   `json:"bold,omitempty"`
	Faint bool   `json:"faint,omitempty"`
	Under bool   `json:"underline,omitempty"`
	Inv   bool   `json:"inverse,omitempty"`
	// uniform: every cell of the match is drawn as the first is
	uniform bool
}

// targetPane is the pane a testing verb looks at when none is said:
// the one this command runs in (inside rook, or a `rook play` session,
// which names its pane under test), else the whole glass.
func targetPane(arg string) (int, error) {
	if arg == "" || arg == "." {
		env := os.Getenv("ROOK_MUX_PANE")
		if env == "" {
			if arg == "." {
				return 0, fmt.Errorf("not inside a rook pane, so there is no current one")
			}
			return 0, nil
		}
		arg = env
	}
	n, err := strconv.Atoi(arg)
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("a pane is a number, or . for this one")
	}
	return n, nil
}

func isPaneWord(s string) bool {
	if s == "." {
		return true
	}
	if s == "" {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// takeScreen asks the engine for a shot. settle < 0 leaves the
// engine's own default.
func takeScreen(pane int, settle int) (*screen, error) {
	args := []string{"shot", "--json"}
	if pane > 0 {
		args = append(args, strconv.Itoa(pane))
	}
	if settle >= 0 {
		args = append(args, "--settle", strconv.Itoa(settle))
	}
	cmd := exec.Command(mux.EnginePath(), args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	doc, err := cmd.Output()
	if err != nil {
		if msg := strings.TrimSpace(stderr.String()); msg != "" {
			return nil, fmt.Errorf("%s", strings.TrimPrefix(msg, "rook: "))
		}
		return nil, fmt.Errorf("the engine did not answer — is rook running?")
	}
	var g shotGrid
	if err := json.Unmarshal(doc, &g); err != nil {
		return nil, fmt.Errorf("shot: %w", err)
	}
	return newScreen(g, pane), nil
}

func newScreen(g shotGrid, pane int) *screen {
	s := &screen{grid: g, pane: pane, cells: make([][]cell, g.Rows)}
	for y := range s.cells {
		row := make([]cell, g.Cols)
		for x := range row {
			row[x].text = " "
		}
		s.cells[y] = row
	}
	for li := range g.Lines {
		line := &g.Lines[li]
		if line.Y < 0 || line.Y >= g.Rows {
			continue
		}
		row := s.cells[line.Y]
		for ri := range line.Runs {
			run := &line.Runs[ri]
			if run.Cluster {
				for i := 0; i < run.W && run.X+i < g.Cols; i++ {
					row[run.X+i] = cell{run: run}
				}
				if run.X < g.Cols {
					row[run.X].text = run.Text
				}
				continue
			}
			x := run.X
			for _, r := range run.Text {
				if x >= g.Cols {
					break
				}
				row[x] = cell{text: string(r), run: run}
				x++
			}
		}
	}
	return s
}

// rowText is a row as a string, and for each byte offset in it the
// cell it came from.
func (s *screen) rowText(y int) (string, []int) {
	var b strings.Builder
	var at []int
	for x, c := range s.cells[y] {
		for range len(c.text) {
			at = append(at, x)
		}
		b.WriteString(c.text)
	}
	return b.String(), at
}

func (s *screen) text() string {
	var b strings.Builder
	for y := range s.cells {
		t, _ := s.rowText(y)
		b.WriteString(strings.TrimRight(t, " "))
		b.WriteByte('\n')
	}
	return b.String()
}

func styleOf(c cell) (fg, bg string, bold, faint, under, inv bool) {
	if c.run == nil {
		return
	}
	return strings.ToLower(c.run.Fg), strings.ToLower(c.run.Bg), c.run.Bold, c.run.Faint, c.run.Underline, c.run.Inverse
}

// find is every place the text (or the pattern) is on the screen, a
// row at a time: text on a terminal does not run on from one row to
// the next. row < 0 is every row.
func (s *screen) find(text string, re *regexp.Regexp, row int) []match {
	var out []match
	for y := range s.cells {
		if row >= 0 && y != row {
			continue
		}
		line, at := s.rowText(y)
		var spans [][]int
		if re != nil {
			spans = re.FindAllStringIndex(line, -1)
		} else if text != "" {
			for from := 0; ; {
				i := strings.Index(line[from:], text)
				if i < 0 {
					break
				}
				spans = append(spans, []int{from + i, from + i + len(text)})
				from += i + len(text)
			}
		}
		for _, sp := range spans {
			if sp[1] <= sp[0] {
				continue
			}
			x0, x1 := at[sp[0]], at[sp[1]-1]
			// a wide glyph's last cell is its tail
			for x1+1 < len(s.cells[y]) && s.cells[y][x1+1].text == "" {
				x1++
			}
			m := match{X: x0, Y: y, W: x1 - x0 + 1, Text: line[sp[0]:sp[1]], uniform: true}
			m.Fg, m.Bg, m.Bold, m.Faint, m.Under, m.Inv = styleOf(s.cells[y][x0])
			for x := x0; x <= x1; x++ {
				fg, bg, bold, faint, under, inv := styleOf(s.cells[y][x])
				if fg != m.Fg || bg != m.Bg || bold != m.Bold || faint != m.Faint || under != m.Under || inv != m.Inv {
					m.uniform = false
				}
			}
			out = append(out, m)
		}
	}
	return out
}

func (m match) String() string {
	var style []string
	if m.Fg != "" {
		style = append(style, "fg="+m.Fg)
	}
	if m.Bg != "" {
		style = append(style, "bg="+m.Bg)
	}
	for _, f := range []struct {
		on   bool
		name string
	}{{m.Bold, "bold"}, {m.Faint, "faint"}, {m.Under, "underline"}, {m.Inv, "inverse"}} {
		if f.on {
			style = append(style, f.name)
		}
	}
	return fmt.Sprintf("%d,%d w=%d %q %s", m.X, m.Y, m.W, m.Text, strings.Join(style, " "))
}

// want is what `expect` was asked to see.
type want struct {
	text, noText        string
	re                  *regexp.Regexp
	row                 int
	fg, bg, lineBg      string
	bold, inverse       bool
	cursorX, cursorY    int
	cursor              bool
	count               int // -1: at least one
	timeout, settle     int
	pane                string
	glass, asJSON, list bool
	said                map[string]bool
	x, y                int // click: a cell said outright
	cellSaid            bool
	right, double       bool
}

func colourArg(s string) (string, error) {
	s = strings.ToLower(s)
	if s == "default" || s == "none" {
		return "", nil
	}
	if len(s) != 7 || s[0] != '#' {
		return "", fmt.Errorf("a colour is #rrggbb, or default for the terminal's own")
	}
	if _, err := strconv.ParseUint(s[1:], 16, 32); err != nil {
		return "", fmt.Errorf("a colour is #rrggbb, or default for the terminal's own")
	}
	return s, nil
}

// parseWant reads the flags the three verbs share. verb is for the
// messages.
func parseWant(verb string, args []string) (*want, map[string]bool, error) {
	w := &want{row: -1, count: -1, timeout: 3000, settle: -1}
	said := map[string]bool{}
	need := func(i int) (string, error) {
		if i+1 >= len(args) {
			return "", fmt.Errorf("%s: %s needs a value", verb, args[i])
		}
		return args[i+1], nil
	}
	num := func(i int) (int, error) {
		v, err := need(i)
		if err != nil {
			return 0, err
		}
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 {
			return 0, fmt.Errorf("%s: %s is a number", verb, args[i])
		}
		return n, nil
	}
	var words []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		var err error
		switch a {
		case "--text":
			w.text, err = need(i)
			i++
		case "--no-text":
			w.noText, err = need(i)
			i++
		case "--regex":
			var v string
			if v, err = need(i); err == nil {
				if w.re, err = regexp.Compile(v); err != nil {
					err = fmt.Errorf("%s: --regex: %v", verb, err)
				}
			}
			i++
		case "--row":
			w.row, err = num(i)
			i++
		case "--count":
			w.count, err = num(i)
			i++
		case "--timeout":
			w.timeout, err = num(i)
			i++
		case "--settle":
			w.settle, err = num(i)
			i++
		case "--fg", "--bg", "--line-bg":
			var v, c string
			if v, err = need(i); err == nil {
				if c, err = colourArg(v); err != nil {
					err = fmt.Errorf("%s: %s: %v", verb, a, err)
				}
			}
			switch a {
			case "--fg":
				w.fg = c
			case "--bg":
				w.bg = c
			default:
				w.lineBg = c
			}
			i++
		case "--cursor":
			var v string
			if v, err = need(i); err == nil {
				xs, ys, ok := strings.Cut(v, ",")
				w.cursorX, _ = strconv.Atoi(xs)
				w.cursorY, _ = strconv.Atoi(ys)
				if !ok || !isPaneWord(xs) || !isPaneWord(ys) {
					err = fmt.Errorf("%s: --cursor is X,Y in cells", verb)
				}
				w.cursor = true
			}
			i++
		case "--bold":
			w.bold = true
		case "--inverse":
			w.inverse = true
		case "--glass":
			w.glass = true
		case "--json":
			w.asJSON = true
		case "--all":
			w.list = true
		case "--right":
			w.right = true
		case "--double":
			w.double = true
		default:
			if strings.HasPrefix(a, "--") {
				return nil, nil, fmt.Errorf("%s: unknown option %s", verb, a)
			}
			words = append(words, a)
			continue
		}
		if err != nil {
			return nil, nil, err
		}
		said[a] = true
	}
	// the words: a pane first, if the first is one; then the text
	if len(words) > 0 && isPaneWord(words[0]) && !(verb == "click" && len(words) == 1 && strings.Contains(words[0], ",")) {
		w.pane = words[0]
		words = words[1:]
	}
	if verb == "click" && len(words) == 1 && strings.Contains(words[0], ",") {
		xs, ys, _ := strings.Cut(words[0], ",")
		if !isPaneWord(xs) || !isPaneWord(ys) || xs == "." || ys == "." {
			return nil, nil, fmt.Errorf("click: a cell is X,Y")
		}
		w.x, _ = strconv.Atoi(xs)
		w.y, _ = strconv.Atoi(ys)
		w.cellSaid = true
		words = nil
	}
	if len(words) > 0 {
		if w.text != "" || w.re != nil || len(words) > 1 {
			return nil, nil, fmt.Errorf("%s: one text to look for (quote it)", verb)
		}
		w.text = words[0]
	}
	return w, said, nil
}

func (w *want) screen() (*screen, error) {
	pane := 0
	if !w.glass {
		var err error
		if pane, err = targetPane(w.pane); err != nil {
			return nil, err
		}
	}
	return takeScreen(pane, w.settle)
}

// runFind prints where text is: `x,y w=N "text" style…` a line each,
// or JSON. Exit status 1 when it is nowhere.
func runFind(args []string) error {
	w, _, err := parseWant("find", args)
	if err != nil {
		return err
	}
	if w.text == "" && w.re == nil {
		return fmt.Errorf("usage: rook find [<pane>] <text> | --regex RE  [--row N] [--glass] [--json]")
	}
	s, err := w.screen()
	if err != nil {
		return err
	}
	found := s.find(w.text, w.re, w.row)
	if w.asJSON {
		if found == nil {
			found = []match{}
		}
		json.NewEncoder(os.Stdout).Encode(found)
	} else {
		for _, m := range found {
			fmt.Println(m)
		}
	}
	if len(found) == 0 {
		if !w.asJSON {
			fmt.Fprintln(os.Stderr, "rook: find: not on the screen")
		}
		os.Exit(1)
	}
	return nil
}

// check is one look at the screen: nil when everything asked for
// holds, else what does not.
func (w *want) check(s *screen) error {
	if w.noText != "" {
		if found := s.find(w.noText, nil, w.row); len(found) > 0 {
			return fmt.Errorf("%q is on the screen, at %d,%d", w.noText, found[0].X, found[0].Y)
		}
	}
	if w.cursor {
		c := s.grid.Cursor
		if c == nil || !c.Visible || c.X != w.cursorX || c.Y != w.cursorY {
			if c == nil || !c.Visible {
				return fmt.Errorf("the cursor is not showing (wanted %d,%d)", w.cursorX, w.cursorY)
			}
			return fmt.Errorf("the cursor is at %d,%d, not %d,%d", c.X, c.Y, w.cursorX, w.cursorY)
		}
	}
	if w.said["--line-bg"] {
		ok, got := false, ""
		for _, l := range s.grid.Lines {
			if w.row >= 0 && l.Y != w.row {
				continue
			}
			if w.row >= 0 {
				got = l.Bg
			}
			if strings.EqualFold(l.Bg, w.lineBg) && (w.row >= 0 || w.lineBg != "") {
				ok = true
			}
		}
		if !ok {
			if w.row >= 0 {
				return fmt.Errorf("row %d is not filled %s edge to edge (its fill is %q)", w.row, w.lineBg, got)
			}
			return fmt.Errorf("no row is filled %s edge to edge", w.lineBg)
		}
	}
	if w.text == "" && w.re == nil {
		return nil
	}
	what := strconv.Quote(w.text)
	if w.re != nil {
		what = "/" + w.re.String() + "/"
	}
	found := s.find(w.text, w.re, w.row)
	if len(found) == 0 {
		if w.count == 0 {
			return nil
		}
		if w.row >= 0 {
			line, _ := s.rowText(w.row)
			return fmt.Errorf("%s is not on row %d (which reads %q)", what, w.row, strings.TrimRight(line, " "))
		}
		return fmt.Errorf("%s is not on the screen", what)
	}
	// of those, the ones drawn as asked
	var drawn []match
	for _, m := range found {
		if w.said["--fg"] && (!m.uniform || m.Fg != w.fg) {
			continue
		}
		if w.said["--bg"] && (!m.uniform || m.Bg != w.bg) {
			continue
		}
		if w.bold && !m.Bold {
			continue
		}
		if w.inverse && !m.Inv {
			continue
		}
		drawn = append(drawn, m)
	}
	if len(drawn) == 0 {
		return fmt.Errorf("%s is on the screen, but not drawn as asked: it is %s", what, found[0])
	}
	if w.count >= 0 && len(drawn) != w.count {
		return fmt.Errorf("%s is on the screen %d times, not %d", what, len(drawn), w.count)
	}
	return nil
}

// runExpect looks until what was asked for holds, or the timeout: the
// retrying assertion. Status 0 and silence when it holds; 1, the
// reason, and the screen as it was, when it does not.
func runExpect(args []string) error {
	w, said, err := parseWant("expect", args)
	if err != nil {
		return err
	}
	w.said = said
	if w.text == "" && w.re == nil && w.noText == "" && !w.cursor && !said["--line-bg"] {
		return fmt.Errorf("usage: rook expect [<pane>] [<text> | --regex RE] [--no-text S] [--row N] [--fg #rrggbb] [--bg #rrggbb] [--bold] [--inverse] [--line-bg #rrggbb] [--cursor X,Y] [--count N] [--timeout MS] [--glass]")
	}
	deadline := time.Now().Add(time.Duration(w.timeout) * time.Millisecond)
	for {
		s, err := w.screen()
		if err != nil {
			return err
		}
		why := w.check(s)
		if why == nil {
			return nil
		}
		if !time.Now().Before(deadline) {
			fmt.Fprintf(os.Stderr, "rook: expect: %v, after %d ms\n\n%s", why, w.timeout, s.text())
			os.Exit(1)
		}
		time.Sleep(60 * time.Millisecond)
	}
}

// runClick clicks a cell, or the middle of some text, in a pane whose
// program has asked for the mouse: a press and a release, written the
// way the program asked for mouse events — SGR (1006), or the original
// three bytes an older curses reads.
func runClick(args []string) error {
	w, _, err := parseWant("click", args)
	if err != nil {
		return err
	}
	if !w.cellSaid && w.text == "" && w.re == nil {
		return fmt.Errorf("usage: rook click [<pane>] <text> | X,Y | --regex RE  [--row N] [--right] [--double]")
	}
	pane, err := targetPane(w.pane)
	if err != nil {
		return err
	}
	if pane == 0 {
		return fmt.Errorf("click: say which pane (a number, or . inside one)")
	}
	x, y := w.x, w.y
	if !w.cellSaid {
		deadline := time.Now().Add(time.Duration(w.timeout) * time.Millisecond)
		for {
			s, err := takeScreen(pane, w.settle)
			if err != nil {
				return err
			}
			found := s.find(w.text, w.re, w.row)
			if len(found) == 1 || (len(found) > 1 && w.list) {
				x, y = found[0].X+found[0].W/2, found[0].Y
				break
			}
			if len(found) > 1 {
				var where []string
				for _, m := range found {
					where = append(where, fmt.Sprintf("%d,%d", m.X, m.Y))
				}
				return fmt.Errorf("click: that text is on the screen %d times (%s): say --row, or the cell, or --all for the first", len(found), strings.Join(where, " "))
			}
			if !time.Now().Before(deadline) {
				fmt.Fprintf(os.Stderr, "rook: click: nothing to click: the text is not on the screen, after %d ms\n\n%s", w.timeout, s.text())
				os.Exit(1)
			}
			time.Sleep(60 * time.Millisecond)
		}
	}
	out, err := mux.State()
	if err != nil {
		return fmt.Errorf("the engine did not answer — is rook running?")
	}
	var st struct {
		Panes []struct {
			ID         int  `json:"id"`
			WantsMouse bool   `json:"wantsMouse"`
			Format     string `json:"mouseFormat"`
			Cols       int  `json:"cols"`
			Rows       int  `json:"rows"`
		} `json:"panes"`
	}
	json.Unmarshal([]byte(out), &st)
	known, format := false, "sgr"
	for _, p := range st.Panes {
		if p.ID != pane {
			continue
		}
		known = true
		if !p.WantsMouse {
			return fmt.Errorf("click: the program in pane %d has not asked for the mouse; it would not see a click", pane)
		}
		format = p.Format
		if x >= p.Cols || y >= p.Rows {
			return fmt.Errorf("click: %d,%d is outside pane %d (%dx%d)", x, y, pane, p.Cols, p.Rows)
		}
	}
	if !known {
		return fmt.Errorf("no such pane")
	}
	button := 0
	if w.right {
		button = 2
	}
	one := fmt.Sprintf("\x1b[<%d;%d;%dM\x1b[<%d;%d;%dm", button, x+1, y+1, button, x+1, y+1)
	if format == "x10" {
		// button, column and row as bytes offset by 32; a release is
		// button 3. A byte holds columns and rows up to 222.
		if x > 222 || y > 222 {
			return fmt.Errorf("click: %d,%d is past what this program's mouse encoding can say (223)", x, y)
		}
		one = string([]byte{0x1b, '[', 'M', byte(32 + button), byte(33 + x), byte(33 + y), 0x1b, '[', 'M', 35, byte(33 + x), byte(33 + y)})
	}
	if w.double {
		one += one
	}
	cmd := exec.Command(mux.EnginePath(), "send", strconv.Itoa(pane), one)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("click: %s", strings.TrimPrefix(strings.TrimSpace(stderr.String()), "rook: "))
	}
	fmt.Printf("{\"ok\":true,\"pane\":%d,\"x\":%d,\"y\":%d}\n", pane, x, y)
	return nil
}

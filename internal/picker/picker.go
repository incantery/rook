// Package picker is the workspace picker prefix-s floats in a popup:
// fzf over the workspaces, where enter switches to the row under the
// cursor and ctrl-o creates the one you typed. It opens on the
// workspace you are already in, so the list says where you are before
// you touch a key and enter on it is a no-op rather than a jump. It
// lives here rather than in a shell pipeline baked into the engine so
// the quoting has a home and the decision has tests.
package picker

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// NewKey creates a workspace named by whatever is in the query. It is
// deliberately not ctrl-n: fzf's ctrl-n/ctrl-p are how you move
// through the list, and moving through the list stays exactly as it
// was — the new verb has to cost a key nobody was already using.
const NewKey = "ctrl-o"

// prompt marks the picker as rook's, the way the status line does.
const prompt = "♜ "

// fzf is the picker binary, by name; a test points this at a stub.
var fzf = "fzf"

// placingVersion is the first fzf with the `load` event and the `pos`
// action — both landed in 0.36.0 — which is how the cursor gets placed
// before anyone touches a key. Older fzf exits on an event it does not
// know, so the placement is dropped rather than risking a picker that
// will not open at all.
var placingVersion = [2]int{0, 36}

// Action is what the picker was asked for.
type Action int

const (
	// None: esc, or a key that named nothing.
	None Action = iota
	// Switch to an existing workspace.
	Switch
	// New workspace by that name (the server switches to it).
	New
)

// Choice is the picker's verdict: a verb and the workspace it names.
type Choice struct {
	Action Action
	Name   string
}

// Args are fzf's flags. --print-query and --expect are what turn one
// list into two verbs: the row under the cursor (enter) or the text
// typed above it (NewKey). Nothing here rebinds a movement key, so
// ctrl-n/ctrl-p, the arrows and the mouse keep fzf's own behaviour —
// the one binding here fires on the `load` event, not on a key.
//
// pos is the 1-based row to open the cursor on; 0 (nothing to point
// at) and 1 (already the top) leave fzf's own placement alone.
func Args(pos int) []string {
	args := []string{
		"--reverse",
		"--print-query",
		"--expect=" + NewKey,
		"--prompt", prompt,
		"--header", "workspace — enter switch · " + NewKey + " new",
	}
	if pos > 1 {
		// An event binding, not a key one: it fires once, when the
		// list has loaded, and rebinds nothing anyone can press. It
		// has to be `load` rather than `start` — reading the list
		// puts the cursor back on the top row, so a placement made
		// before that has already been undone by the time anyone
		// sees it.
		args = append(args, fmt.Sprintf("--bind=load:pos(%d)", pos))
	}
	return args
}

// StartPos is the row the picker opens on: the workspace you are in,
// counted from the top of the list fzf is handed. 0 when there is no
// current workspace, or it is not one of the rows.
func StartPos(names []string, current string) int {
	current = clean(current)
	if current == "" {
		return 0
	}
	row := 0
	for _, n := range names {
		if clean(n) == "" {
			continue // Run drops blank rows; the count has to agree
		}
		row++
		if clean(n) == current {
			return row
		}
	}
	return 0
}

// Run shows the picker over names, opening on current, and returns
// what it decided.
func Run(names []string, current string) (Choice, error) {
	bin, err := exec.LookPath(fzf)
	if err != nil {
		return Choice{}, fmt.Errorf("the workspace picker needs fzf, and it is not on $PATH")
	}
	var list strings.Builder
	for _, n := range names {
		if n = strings.TrimSpace(n); n != "" {
			list.WriteString(n)
			list.WriteByte('\n')
		}
	}
	pos := StartPos(names, current)
	if pos > 1 && !placesCursor(version(bin)) {
		pos = 0
	}
	cmd := exec.Command(bin, Args(pos)...)
	cmd.Stdin = strings.NewReader(list.String())
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			return Choice{}, err
		}
		switch ee.ExitCode() {
		case 1:
			// nothing matched — the query still comes back, which is
			// exactly how NewKey names a workspace that has no row yet
		case 130:
			return Choice{}, nil // esc or ctrl-c: the popup just closes
		default:
			return Choice{}, fmt.Errorf("fzf: %w", err)
		}
	}
	return Decide(string(out)), nil
}

// version asks the picker binary what it is; empty when it will not
// say, which reads as too old to place the cursor.
func version(bin string) string {
	out, err := exec.Command(bin, "--version").Output()
	if err != nil {
		return ""
	}
	return string(out)
}

// placesCursor reads `fzf --version` ("0.74.3 (Homebrew)") and reports
// whether this fzf can be told where to open. Anything it cannot read
// is a no: the placement is a nicety, and opening at all is not.
func placesCursor(out string) bool {
	f := strings.Fields(strings.TrimSpace(out))
	if len(f) == 0 {
		return false
	}
	num := strings.SplitN(f[0], "-", 2)[0] // 0.24.4-2 and the like
	parts := strings.Split(num, ".")
	if len(parts) < 2 {
		return false
	}
	major, err := strconv.Atoi(parts[0])
	if err != nil {
		return false
	}
	minor, err := strconv.Atoi(parts[1])
	if err != nil {
		return false
	}
	return major > placingVersion[0] || (major == placingVersion[0] && minor >= placingVersion[1])
}

// Decide reads what fzf prints under Args: the query, then the key
// that ended it (blank for enter), then the selected row.
func Decide(out string) Choice {
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	at := func(i int) string {
		if i >= len(lines) {
			return ""
		}
		return clean(lines[i])
	}
	query, key, row := at(0), at(1), at(2)
	if key == NewKey {
		// Naming is the whole gesture: ctrl-o on an empty query has
		// asked for nothing. A name that already exists is not an
		// error — the server dedupes and switches to it.
		if query == "" {
			return Choice{}
		}
		return Choice{New, query}
	}
	if row == "" {
		return Choice{}
	}
	return Choice{Switch, row}
}

// clean trims a line and flattens the bytes the workspace protocol
// spends on its own separators, so a typed name can never split a
// payload the engine has to parse.
func clean(s string) string {
	return strings.TrimSpace(strings.NewReplacer("\t", " ", "\r", "", "\x00", "").Replace(s))
}

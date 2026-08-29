// Package picker is the workspace picker prefix-s floats in a popup:
// fzf over the workspaces, where enter switches to the row under the
// cursor and ctrl-o creates the one you typed. It lives here rather
// than in a shell pipeline baked into the engine so the quoting has a
// home and the decision has tests.
package picker

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
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
// ctrl-n/ctrl-p, the arrows and the mouse keep fzf's own behaviour.
func Args() []string {
	return []string{
		"--reverse",
		"--print-query",
		"--expect=" + NewKey,
		"--prompt", prompt,
		"--header", "workspace — enter switch · " + NewKey + " new",
	}
}

// Run shows the picker over names and returns what it decided.
func Run(names []string) (Choice, error) {
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
	cmd := exec.Command(bin, Args()...)
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

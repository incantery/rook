package mux

import "testing"

// Rook is the only thing that can say whether the companion is open
// *in rook*, so the snapshot is where that fact lives — and a reader
// of it has to survive an older engine (no field at all), a newer one
// (fields it never heard of) and no server (nothing to read).
func TestCompanionFrom(t *testing.T) {
	const open = `{"rookMuxState":1,"companion":{"name":"vera","open":true,"visible":true,` +
		`"focused":false,"panes":[{"pane":7,"workspace":"rook","window":2,"place":"window",` +
		`"visible":true,"focused":false,"since":1756500000000}]},"workspaces":[]}`

	c := companionFrom(open)
	if c == nil {
		t.Fatal("a snapshot with a companion read as none")
	}
	if c.Name != "vera" || !c.Open || !c.Visible || c.Focused {
		t.Errorf("rollups: %+v", c)
	}
	if len(c.Panes) != 1 {
		t.Fatalf("panes: %+v", c.Panes)
	}
	p := c.Panes[0]
	if p.Pane != 7 || p.Workspace != "rook" || p.Window == nil || *p.Window != 2 ||
		p.Place != "window" || !p.Visible || p.Focused || p.Since != 1756500000000 {
		t.Errorf("where: %+v", p)
	}

	// The slot turned off, an engine too old to have one, and a server
	// that is not running all mean the same thing to a caller: rook
	// knows of no companion.
	for _, s := range []string{
		`{"companion":null,"workspaces":[]}`,
		`{"rookMuxState":1,"workspaces":[]}`,
		"engine: connection refused\n",
		"",
	} {
		if got := companionFrom(s); got != nil {
			t.Errorf("companionFrom(%q) = %+v, want nil", s, got)
		}
	}

	// A field this reader does not know is not a reason to drop the
	// rest (docs/surfaces.md: readers accept newer and skip what they
	// don't know).
	newer := `{"companion":{"name":"vera","open":true,"mood":"chatty",` +
		`"panes":[{"pane":1,"place":"pin","window":null,"since":1,"mood":"new"}]}}`
	c = companionFrom(newer)
	if c == nil || !c.Open || len(c.Panes) != 1 || c.Panes[0].Place != "pin" || c.Panes[0].Window != nil {
		t.Errorf("newer schema: %+v", c)
	}
}

// --json hands over rook's own bytes rather than this struct's idea of
// them, so a consumer sees the fields Go dropped.
func TestCompanionJSON(t *testing.T) {
	in := `{"rookMuxState":1,"companion":{"name":"vera","open":false,"panes":[],"mood":"quiet"},"panes":[]}`
	want := `{"name":"vera","open":false,"panes":[],"mood":"quiet"}`
	if got := companionJSON(in); got != want {
		t.Errorf("companionJSON = %s, want %s", got, want)
	}
	for _, s := range []string{`{"companion":null}`, `{}`, "nope"} {
		if got := companionJSON(s); got != "null" {
			t.Errorf("companionJSON(%q) = %s, want null", s, got)
		}
	}
}

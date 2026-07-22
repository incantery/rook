package vt

import "testing"

// out feeds bytes and returns the emulator's reply, the string it would write
// back to the pty.
func out(e *Emulator, s string) string {
	e.Write([]byte(s))
	return string(e.TakeOutput())
}

func TestDeviceAttributes(t *testing.T) {
	e := New(80, 24)
	if got := out(e, "\x1b[c"); got != "\x1b[?1;2c" {
		t.Errorf("DA1 = %q, want ESC[?1;2c", got)
	}
	if got := out(e, "\x1b[0c"); got != "\x1b[?1;2c" {
		t.Errorf("DA1 (explicit 0) = %q", got)
	}
	if got := out(e, "\x1b[1c"); got != "" {
		t.Errorf("CSI 1 c is not a query, got reply %q", got)
	}
	if got := out(e, "\x1b[>c"); got != "\x1b[>0;276;0c" {
		t.Errorf("DA2 = %q, want ESC[>0;276;0c", got)
	}
}

func TestDeviceStatusReport(t *testing.T) {
	e := New(80, 24)
	if got := out(e, "\x1b[5n"); got != "\x1b[0n" {
		t.Errorf("DSR 5 = %q, want ESC[0n", got)
	}
}

func TestCursorPositionReport(t *testing.T) {
	e := New(80, 24)
	e.Write([]byte("\x1b[3;5H")) // cursor to row 3, col 5 (1-based)
	if got := out(e, "\x1b[6n"); got != "\x1b[3;5R" {
		t.Errorf("CPR = %q, want ESC[3;5R", got)
	}
	// The private variant reports a page parameter too.
	if got := out(e, "\x1b[?6n"); got != "\x1b[?3;5;1R" {
		t.Errorf("DECXCPR = %q, want ESC[?3;5;1R", got)
	}
}

func TestCPROriginMode(t *testing.T) {
	e := New(80, 24)
	e.Write([]byte("\x1b[5;10r")) // scroll region rows 5..10
	e.Write([]byte("\x1b[?6h"))   // origin mode on
	e.Write([]byte("\x1b[2;3H"))  // row 2 within region -> absolute row 6
	if got := out(e, "\x1b[6n"); got != "\x1b[2;3R" {
		t.Errorf("CPR under origin mode = %q, want region-relative ESC[2;3R", got)
	}
}

func TestDECRQM(t *testing.T) {
	e := New(80, 24)
	// Defaults: autowrap (7) set, cursor (25) set, bracketed paste (2004) reset.
	if got := out(e, "\x1b[?7$p"); got != "\x1b[?7;1$y" {
		t.Errorf("DECRQM 7 default = %q, want set", got)
	}
	if got := out(e, "\x1b[?2004$p"); got != "\x1b[?2004;2$y" {
		t.Errorf("DECRQM 2004 default = %q, want reset", got)
	}
	// Turn bracketed paste on, then it must report set.
	e.Write([]byte("\x1b[?2004h"))
	if got := out(e, "\x1b[?2004$p"); got != "\x1b[?2004;1$y" {
		t.Errorf("DECRQM 2004 after set = %q, want set", got)
	}
	// Turn autowrap off, report reset.
	e.Write([]byte("\x1b[?7l"))
	if got := out(e, "\x1b[?7$p"); got != "\x1b[?7;2$y" {
		t.Errorf("DECRQM 7 after reset = %q, want reset", got)
	}
	// A permanently-set mode (8, autorepeat) and an unknown one.
	if got := out(e, "\x1b[?8$p"); got != "\x1b[?8;3$y" {
		t.Errorf("DECRQM 8 = %q, want perm-set (3)", got)
	}
	if got := out(e, "\x1b[?9999$p"); got != "\x1b[?9999;0$y" {
		t.Errorf("DECRQM unknown = %q, want not-recognized (0)", got)
	}
	// ANSI (non-private) insert mode 4, default reset.
	if got := out(e, "\x1b[4$p"); got != "\x1b[4;2$y" {
		t.Errorf("DECRQM ansi 4 = %q, want reset", got)
	}
}

func TestDECRQMMouseExclusive(t *testing.T) {
	e := New(80, 24)
	e.Write([]byte("\x1b[?1002h")) // button-event tracking
	if got := out(e, "\x1b[?1002$p"); got != "\x1b[?1002;1$y" {
		t.Errorf("mouse 1002 = %q, want set", got)
	}
	// 1000 is not the active protocol, so it reports reset even though a mouse
	// mode is on — the modes are exclusive.
	if got := out(e, "\x1b[?1000$p"); got != "\x1b[?1000;2$y" {
		t.Errorf("mouse 1000 while 1002 active = %q, want reset", got)
	}
}

func TestDECRQSS(t *testing.T) {
	e := New(80, 24)
	e.Write([]byte("\x1b[1;31m")) // bold, red fg
	if got := out(e, "\x1bP$qm\x1b\\"); got != "\x1bP1$r0;1;31m\x1b\\" {
		t.Errorf("DECRQSS SGR = %q, want ESC P 1 $ r 0;1;31 m ST", got)
	}
	e.Write([]byte("\x1b[0m\x1b[38;2;10;20;30m")) // truecolor fg
	if got := out(e, "\x1bP$qm\x1b\\"); got != "\x1bP1$r0;38;2;10;20;30m\x1b\\" {
		t.Errorf("DECRQSS truecolor = %q", got)
	}
	e.Write([]byte("\x1b[3;10r")) // scroll region
	if got := out(e, "\x1bP$qr\x1b\\"); got != "\x1bP1$r3;10r\x1b\\" {
		t.Errorf("DECRQSS DECSTBM = %q, want 3;10r", got)
	}
	if got := out(e, "\x1bP$qZ\x1b\\"); got != "\x1bP0$r\x1b\\" {
		t.Errorf("DECRQSS unknown = %q, want invalid (0$r)", got)
	}
}

func TestQuerySplitAcrossWrites(t *testing.T) {
	e := New(80, 24)
	e.Write([]byte("\x1b[")) // half a query
	e.Write([]byte("c"))     // the rest
	if got := string(e.TakeOutput()); got != "\x1b[?1;2c" {
		t.Errorf("split DA1 = %q, want ESC[?1;2c", got)
	}
}

// TestNoQueryReachesClient is the Phase 2b half of the gate: queries produce a
// reply for the pty but never a grid change, so a rendering client sees nothing
// of them.
func TestNoQueryReachesClient(t *testing.T) {
	e := New(80, 24)
	surf := e.NewSurface()
	e.Render(surf) // drain the initial blank->blank frame

	queries := "\x1b[c\x1b[>c\x1b[5n\x1b[6n\x1b[?7$p\x1bP$qm\x1b\\"
	e.Write([]byte(queries))

	if got := e.TakeOutput(); len(got) == 0 {
		t.Fatal("queries produced no reply")
	}
	frame := e.Render(surf)
	for _, row := range frame.Rows {
		if len(row.Runs) > 0 {
			t.Fatalf("a query changed the grid: row %d has %d runs", row.Y, len(row.Runs))
		}
	}
}

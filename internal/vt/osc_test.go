package vt

import "testing"

func TestOSCBackgroundQuery(t *testing.T) {
	e := New(20, 4)
	var ansi [16]uint32
	e.SetPalette(0xd6deeb, 0x0f111a, 0xffcc00, ansi)

	// vim's read of the background color: OSC 11 ; ? ST
	e.Write([]byte("\x1b]11;?\x1b\\"))
	got := string(e.TakeOutput())
	// 0x0f -> 0f0f, 0x11 -> 1111, 0x1a -> 1a1a
	want := "\x1b]11;rgb:0f0f/1111/1a1a\x1b\\"
	if got != want {
		t.Fatalf("OSC 11 reply = %q, want %q", got, want)
	}
}

func TestOSCForegroundAndCursorQuery(t *testing.T) {
	e := New(20, 4)
	var ansi [16]uint32
	e.SetPalette(0xffffff, 0x000000, 0xff8800, ansi)

	e.Write([]byte("\x1b]10;?\x07")) // BEL-terminated query is also valid
	if got := string(e.TakeOutput()); got != "\x1b]10;rgb:ffff/ffff/ffff\x1b\\" {
		t.Fatalf("OSC 10 reply = %q", got)
	}
	e.Write([]byte("\x1b]12;?\x1b\\"))
	if got := string(e.TakeOutput()); got != "\x1b]12;rgb:ffff/8888/0000\x1b\\" {
		t.Fatalf("OSC 12 reply = %q", got)
	}
}

func TestOSCIndexedQuery(t *testing.T) {
	e := New(20, 4)
	ansi := defaultPalette
	ansi[1] = 0xcd0000 // red
	e.SetPalette(0xffffff, 0x000000, 0xffffff, ansi)

	e.Write([]byte("\x1b]4;1;?\x1b\\"))
	if got := string(e.TakeOutput()); got != "\x1b]4;1;rgb:cdcd/0000/0000\x1b\\" {
		t.Fatalf("OSC 4 index reply = %q", got)
	}
}

func TestOSCSetThenQuery(t *testing.T) {
	e := New(20, 4)
	// A program sets the background, then a later query must report the set value.
	e.Write([]byte("\x1b]11;rgb:12/34/56\x1b\\"))
	if out := e.TakeOutput(); len(out) != 0 {
		t.Fatalf("a set must not reply, got %q", out)
	}
	e.Write([]byte("\x1b]11;?\x1b\\"))
	if got := string(e.TakeOutput()); got != "\x1b]11;rgb:1212/3434/5656\x1b\\" {
		t.Fatalf("after set, OSC 11 reply = %q", got)
	}
	// #rrggbb form
	e.Write([]byte("\x1b]10;#abcdef\x1b\\"))
	e.Write([]byte("\x1b]10;?\x1b\\"))
	if got := string(e.TakeOutput()); got != "\x1b]10;rgb:abab/cdcd/efef\x1b\\" {
		t.Fatalf("after #hex set, OSC 10 reply = %q", got)
	}
}

func TestOSCTitleIgnored(t *testing.T) {
	e := New(20, 4)
	// OSC 0/2 (window title) and OSC 8 (hyperlink) must not reach the grid or
	// produce a reply — they never did.
	e.Write([]byte("\x1b]0;my title\x07hello"))
	if out := e.TakeOutput(); len(out) != 0 {
		t.Fatalf("title OSC produced a reply: %q", out)
	}
	if line(e, 0) != "hello" {
		t.Fatalf("title OSC corrupted the grid: row 0 = %q", line(e, 0))
	}
}

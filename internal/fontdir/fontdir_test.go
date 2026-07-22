package fontdir

import (
	"os"
	"path/filepath"
	"testing"
)

// The scan runs against the real machine's font dirs — these tests assert
// mechanics (parsing, style mapping) against fonts that ship with macOS, and
// skip if the environment lacks them.

func TestFindSystemFont(t *testing.T) {
	if _, err := os.Stat("/System/Library/Fonts"); err != nil {
		t.Skip("no macOS font dirs")
	}
	// Menlo ships with every macOS as a .ttc — parsing collections is the
	// harder path, so it doubles as the ttc test.
	if _, ok := Find("Menlo", "regular"); !ok {
		t.Error("Menlo regular not found")
	}
	if _, ok := Find("Menlo", "bold"); !ok {
		t.Error("Menlo bold not found")
	}
}

func TestFindUnknown(t *testing.T) {
	if _, ok := Find("Definitely Not A Font 9000", "regular"); ok {
		t.Error("phantom font found")
	}
}

func TestNamesOnRealFile(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip()
	}
	p := filepath.Join(home, "Library/Fonts/HackNerdFontMono-Regular.ttf")
	if _, err := os.Stat(p); err != nil {
		t.Skip("Hack Nerd Font Mono not installed")
	}
	ns := names(p)
	if len(ns) != 1 {
		t.Fatalf("names = %v, want 1 face", ns)
	}
	if ns[0].family != "Hack Nerd Font Mono" || ns[0].style != "regular" {
		t.Errorf("got %+v", ns[0])
	}
}

func TestNormStyle(t *testing.T) {
	cases := map[string]string{
		"Regular": "regular", "Bold": "bold", "Italic": "italic",
		"Bold Italic": "bolditalic", "BoldOblique": "bolditalic", "": "regular",
	}
	for in, want := range cases {
		if got := normStyle(in); got != want {
			t.Errorf("normStyle(%q) = %q, want %q", in, got, want)
		}
	}
}

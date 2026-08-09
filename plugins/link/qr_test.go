package main

import (
	"strings"
	"testing"

	qrcode "github.com/skip2/go-qrcode"
)

const demoURL = "rook-link://pair?a=192.168.4.23&hid=7nweee2hv5i4d2hxyrrj46dmc4" +
	"&n=Seths-MacBook-Pro-2.local&p=51639&s=bWV_ovg-F356x5VSBZ4zbw" +
	"&spki=rY2OTRahNEZZxMwma42ZEBNhtE6Jhhh9QENlGDiCJ1s&td=a4ba0695-b854-4254-88cf-20c199f0e0b8&v=1"

// A QR that wraps is not a QR: whatever rendering is chosen, every
// line must fit the width it was chosen FOR — that is the whole bug
// this mode once had.
func TestRenderNeverExceedsTheWidthItChose(t *testing.T) {
	q, err := qrcode.New(demoURL, qrcode.Low)
	if err != nil {
		t.Fatal(err)
	}
	modules := len(q.Bitmap())

	for _, width := range []int{200, modules + 2, modules + 1, 55, 40, modules/2 + 3, 20, 5} {
		out := render(q, width)
		if strings.Contains(out, "too narrow") {
			// The prose fallback may wrap; wrapped prose is still prose.
			// What must never render at this width is a code.
			if strings.ContainsAny(out, "█▀▄▌▐▘▝▖▗▚▞▛▜▙▟") {
				t.Fatalf("width %d: fallback message carries code glyphs", width)
			}
			continue
		}
		for _, line := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
			if n := len([]rune(line)); n > width {
				t.Fatalf("width %d: rendered line of %d runes:\n%s", width, n, line)
			}
		}
	}
}

// The two block renderings must draw the same code — same modules,
// different packing.
func TestPackingsAgree(t *testing.T) {
	q, err := qrcode.New(demoURL, qrcode.Low)
	if err != nil {
		t.Fatal(err)
	}
	bitmap := q.Bitmap()

	// Unpack both renderings into module grids and compare.
	fromHalf := map[[2]int]bool{}
	for r, line := range strings.Split(strings.TrimRight(halfBlocks(bitmap), "\n"), "\n") {
		for c, ch := range []rune(strings.TrimPrefix(line, "  ")) {
			top := ch == '▄' || ch == ' '
			bot := ch == '▀' || ch == ' '
			fromHalf[[2]int{2 * r, c}] = top
			fromHalf[[2]int{2*r + 1, c}] = bot
		}
	}
	for r := range bitmap {
		for c := range bitmap[r] {
			if got := fromHalf[[2]int{r, c}]; got != bitmap[r][c] {
				t.Fatalf("halfBlocks disagrees with bitmap at %d,%d", r, c)
			}
		}
	}

	quadLight := map[[2]int]bool{}
	rev := map[rune]int{}
	for i, g := range quadrant {
		rev[g] = i
	}
	for r, line := range strings.Split(strings.TrimRight(quadrants(bitmap), "\n"), "\n") {
		for c, ch := range []rune(strings.TrimPrefix(line, "  ")) {
			bits := rev[ch]
			quadLight[[2]int{2 * r, 2 * c}] = bits&8 != 0
			quadLight[[2]int{2 * r, 2*c + 1}] = bits&4 != 0
			quadLight[[2]int{2*r + 1, 2 * c}] = bits&2 != 0
			quadLight[[2]int{2*r + 1, 2*c + 1}] = bits&1 != 0
		}
	}
	for r := range bitmap {
		for c := range bitmap[r] {
			if quadLight[[2]int{r, c}] != !bitmap[r][c] {
				t.Fatalf("quadrants disagrees with bitmap at %d,%d", r, c)
			}
		}
	}
}

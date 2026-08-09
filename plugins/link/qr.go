// The `qr <url>` argv mode: a pairing QR on a terminal, nothing else.
// No state, no network — the URL already carries everything, and this
// process's whole job is to be looked at by a phone and then closed.
package main

import (
	"bufio"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"

	qrcode "github.com/skip2/go-qrcode"
	"golang.org/x/term"
)

// runQR renders the pairing URL as a terminal QR sized to the pane,
// redraws on resize, prints the URL below it for manual entry, and
// exits on Enter.
//
// A QR that wraps is not a QR, so width is measured, never assumed:
// half-blocks (one module per column — biggest, easiest scan) when
// they fit, 2×2 quadrants (half the width) when they don't, and an
// honest "widen this pane" when even that wraps — which SIGWINCH
// turns into a live redraw the moment the user does.
func runQR(url string) {
	q, err := qrcode.New(url, qrcode.Low)
	if err != nil {
		fmt.Fprintln(os.Stderr, "qr:", err)
		os.Exit(1)
	}

	draw := func() {
		fmt.Print("\x1b[2J\x1b[H") // clear; a resize leaves no half QR behind
		fmt.Println()
		fmt.Println("  pair a phone — scan this with the rook app:")
		fmt.Println()
		fmt.Print(render(q, paneWidth()))
		fmt.Println()
		fmt.Println("  or enter it by hand:")
		fmt.Println("  " + url)
		fmt.Println()
		fmt.Println("  the window closes itself in 2 minutes — press Enter to close this pane")
	}
	draw()

	winch := make(chan os.Signal, 1)
	signal.Notify(winch, syscall.SIGWINCH)
	done := make(chan struct{})
	go func() {
		_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
		close(done)
	}()
	for {
		select {
		case <-winch:
			draw()
		case <-done:
			return
		}
	}
}

// paneWidth is the terminal's current column count, or generous when
// stdout is not a terminal (tests, pipes).
func paneWidth() int {
	if w, _, err := term.GetSize(int(os.Stdout.Fd())); err == nil && w > 0 {
		return w
	}
	return 200
}

// render picks the densest rendering that fits width columns.
func render(q *qrcode.QRCode, width int) string {
	bitmap := q.Bitmap() // quiet zone included, true = dark
	const indent = 2
	if len(bitmap)+indent <= width {
		return halfBlocks(bitmap)
	}
	if (len(bitmap)+1)/2+indent <= width {
		return quadrants(bitmap)
	}
	need := (len(bitmap)+1)/2 + indent
	return fmt.Sprintf("  this pane is too narrow for the code (%d columns, need %d)\n"+
		"  widen it and the code will appear\n", width, need)
}

// Polarity, both renderings: LIGHT modules become foreground blocks,
// dark modules stay the terminal's dark background — standard
// dark-on-light at the glass, which is what scans.

// halfBlocks packs two modules per cell (one column each, upper/lower
// half): modules render large, the easiest scan when the pane is wide
// enough to hold ~60 columns.
func halfBlocks(bitmap [][]bool) string {
	// Indexed top-dark<<1 | bottom-dark: both light → full block,
	// bottom dark → keep the top lit, top dark → keep the bottom lit,
	// both dark → the terminal's own background.
	half := [4]rune{'█', '▀', '▄', ' '}
	dark := func(r, c int) bool {
		if r >= len(bitmap) || c >= len(bitmap[r]) {
			return false // past the edge is quiet zone: light
		}
		return bitmap[r][c]
	}
	var b strings.Builder
	for r := 0; r < len(bitmap); r += 2 {
		b.WriteString("  ")
		for c := 0; c < len(bitmap[r]); c++ {
			idx := 0
			if dark(r, c) {
				idx |= 2
			}
			if dark(r+1, c) {
				idx |= 1
			}
			b.WriteRune(half[idx])
		}
		b.WriteByte('\n')
	}
	return b.String()
}

// quadrant glyphs indexed by which of the 2×2 cell's modules are LIGHT
// (tl<<3 | tr<<2 | bl<<1 | br).
var quadrant = [16]rune{
	' ', '▗', '▖', '▄', '▝', '▐', '▞', '▟',
	'▘', '▚', '▌', '▙', '▀', '▜', '▛', '█',
}

// quadrants packs FOUR modules into every cell — half the width of
// halfBlocks. A pairing URL's QR runs ~60 modules with its quiet
// zone: ~62 columns half-blocked, ~33 here, which fits anywhere a
// pane is usable at all.
func quadrants(bitmap [][]bool) string {
	light := func(r, c int) bool {
		if r >= len(bitmap) || c >= len(bitmap[r]) {
			return true
		}
		return !bitmap[r][c]
	}
	var b strings.Builder
	for r := 0; r < len(bitmap); r += 2 {
		b.WriteString("  ")
		for c := 0; c < len(bitmap[r]); c += 2 {
			idx := 0
			if light(r, c) {
				idx |= 8
			}
			if light(r, c+1) {
				idx |= 4
			}
			if light(r+1, c) {
				idx |= 2
			}
			if light(r+1, c+1) {
				idx |= 1
			}
			b.WriteRune(quadrant[idx])
		}
		b.WriteByte('\n')
	}
	return b.String()
}

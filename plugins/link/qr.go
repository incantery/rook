// The `qr <url>` argv mode: a pairing QR on a terminal, nothing else.
// No state, no network — the URL already carries everything, and this
// process's whole job is to be looked at by a phone and then closed.
package main

import (
	"bufio"
	"fmt"
	"os"

	qrcode "github.com/skip2/go-qrcode"
)

// runQR renders the pairing URL as a terminal QR, prints the URL below
// it for manual entry, and waits for Enter.
//
// Polarity, decided by reading go-qrcode's renderer against a dark
// terminal: ToSmallString(false) draws LIGHT QR modules as block
// characters (the terminal's light foreground) and DARK modules as
// spaces (the terminal's dark background) — a standard dark-on-light
// code when the background is dark, which is what scans. The `true`
// variant inverts that and only scans on light terminals; rook is a
// dark terminal, so false is the choice.
func runQR(url string) {
	q, err := qrcode.New(url, qrcode.Medium)
	if err != nil {
		fmt.Fprintln(os.Stderr, "qr:", err)
		os.Exit(1)
	}
	fmt.Println()
	fmt.Println("  pair a phone — scan this with the rook app:")
	fmt.Println()
	fmt.Print(q.ToSmallString(false))
	fmt.Println()
	fmt.Println("  or enter it by hand:")
	fmt.Println("  " + url)
	fmt.Println()
	fmt.Println("  the window closes itself in 2 minutes — press Enter to close this pane")
	_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
}

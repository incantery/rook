// The candidate under test: feed a corpus capture into charmbracelet/x/vt at
// the capture's geometry and emit its grid in the SAME normalized schema as
// ../termdiff/extract-xterm.js, so termdiff can diff them cell for cell.
//
//	go run ./spike/extract-vt spike/corpus/nvim-edit.raw > /tmp/nvim.vt.json
//
// Emulator.Write parses synchronously in the calling goroutine (no pump, no
// settle), so the grid is complete the instant Write returns.
package main

import (
	"encoding/json"
	"fmt"
	"image/color"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	uv "github.com/charmbracelet/ultraviolet"
	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/vt"
)

type meta struct {
	Name string `json:"name"`
	Cols int    `json:"cols"`
	Rows int    `json:"rows"`
}

type cell struct {
	C  string `json:"c"`
	W  int    `json:"w"`
	Fg string `json:"fg"`
	Bg string `json:"bg"`
	A  string `json:"a"`
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: extract-vt <capture.raw>")
		os.Exit(2)
	}
	rawPath := os.Args[1]
	metaRaw, err := os.ReadFile(strings.TrimSuffix(rawPath, filepath.Ext(rawPath)) + ".meta.json")
	check(err)
	var m meta
	check(json.Unmarshal(metaRaw, &m))
	bytes, err := os.ReadFile(rawPath)
	check(err)

	e := vt.NewEmulator(m.Cols, m.Rows)
	// The emulator ANSWERS queries itself — DA, DSR, DECRQM — by writing the
	// replies to its output (Emulator is an io.Reader). Nobody reading that
	// output deadlocks a synchronous Write the moment a capture asks anything
	// (nvim does, on startup). Drain it. In the real host this same output is
	// what gets written back to the pty as input — the emulator replaces
	// termquery.go's hand-rolled answers with its own.
	drained := make(chan struct{})
	go func() { _, _ = io.Copy(io.Discard, e); close(drained) }()
	_, err = e.Write(bytes) // synchronous parse
	check(err)
	_ = e.Close() // EOF the response reader so the drain goroutine exits
	<-drained

	cells := make([][]cell, m.Rows)
	for y := range m.Rows {
		row := make([]cell, m.Cols)
		for x := range m.Cols {
			row[x] = norm(e.CellAt(x, y))
		}
		cells[y] = row
	}
	out, _ := json.Marshal(map[string]any{
		"name": m.Name, "cols": m.Cols, "rows": m.Rows, "cells": cells,
	})
	os.Stdout.Write(out)
}

// norm mirrors extract-xterm.js's cell shape exactly, so a difference in the
// output is a difference in what the emulators DID, not in how we read them.
func norm(c *uv.Cell) cell {
	if c == nil {
		return cell{C: " ", W: 1, Fg: "d", Bg: "d"}
	}
	content := c.Content
	if content == "" {
		content = " "
	}
	a := ""
	if c.Style.Attrs&uv.AttrBold != 0 {
		a += "B"
	}
	if c.Style.Attrs&uv.AttrItalic != 0 {
		a += "I"
	}
	if c.Style.Underline != 0 {
		a += "U"
	}
	if c.Style.Attrs&uv.AttrReverse != 0 {
		a += "R"
	}
	if c.Style.Attrs&uv.AttrFaint != 0 {
		a += "D"
	}
	if c.Style.Attrs&uv.AttrStrikethrough != 0 {
		a += "S"
	}
	return cell{C: content, W: c.Width, Fg: colorTok(c.Style.Fg), Bg: colorTok(c.Style.Bg), A: a}
}

// colorTok buckets a colour the same three ways extract-xterm.js does: "d"
// default, "p<n>" palette index, "#rrggbb" truecolor. A palette-vs-rgb
// mismatch between the two emulators is a legitimate (usually cosmetic)
// finding the diff should surface, not something to paper over here.
func colorTok(c color.Color) string {
	switch v := c.(type) {
	case nil:
		return "d"
	case ansi.BasicColor:
		return "p" + strconv.Itoa(int(v))
	case ansi.IndexedColor:
		return "p" + strconv.Itoa(int(v))
	default:
		r, g, b, _ := c.RGBA()
		return fmt.Sprintf("#%02x%02x%02x", uint8(r>>8), uint8(g>>8), uint8(b>>8))
	}
}

func check(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "extract-vt:", err)
		os.Exit(1)
	}
}

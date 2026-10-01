package main

import (
	"encoding/json"
	"image"
	"image/color"
	"testing"
)

// A grid the size of two rows, drawn: a filled run is its colour edge
// to edge, a full block is ink edge to edge, a blank default cell is
// the ground, and a glyph leaves ink in its cell.
func TestDrawShot(t *testing.T) {
	doc := `{"cols":6,"rows":2,"cursor":{"x":5,"y":1,"visible":true},"lines":[
		{"y":0,"text":"ab █","runs":[
			{"x":0,"w":2,"text":"ab","fg":"#ffffff","bg":"#ff0000","bold":true},
			{"x":3,"w":1,"text":"█","fg":"#00ff00"}]},
		{"y":1,"text":"x","runs":[{"x":0,"w":1,"text":"x"}]}]}`
	var g shotGrid
	if err := json.Unmarshal([]byte(doc), &g); err != nil {
		t.Fatal(err)
	}
	img, err := drawShot(g)
	if err != nil {
		t.Fatal(err)
	}
	cw, ch := img.Bounds().Dx()/6, img.Bounds().Dy()/2
	if cw < 8 || ch < 12 || img.Bounds().Dx() != 6*cw || img.Bounds().Dy() != 2*ch {
		t.Fatalf("cells are %dx%d in %v", cw, ch, img.Bounds())
	}
	at := func(x, y int) color.RGBA { return img.RGBAAt(x, y) }
	red, green := color.RGBA{0xff, 0, 0, 0xff}, color.RGBA{0, 0xff, 0, 0xff}
	// the filled run: its corners, both cells
	for _, p := range []image.Point{{0, 0}, {2*cw - 1, 0}, {0, ch - 1}, {2*cw - 1, ch - 1}} {
		if at(p.X, p.Y) != red {
			t.Errorf("fill at %v = %v", p, at(p.X, p.Y))
		}
	}
	// the blank between: the ground
	if at(2*cw+cw/2, ch/2) != shotGround {
		t.Errorf("blank cell = %v", at(2*cw+cw/2, ch/2))
	}
	// the full block: ink at every corner of its cell, so segments meet
	for _, p := range []image.Point{{3 * cw, 0}, {4*cw - 1, 0}, {3 * cw, ch - 1}, {4*cw - 1, ch - 1}} {
		if at(p.X, p.Y) != green {
			t.Errorf("block at %v = %v", p, at(p.X, p.Y))
		}
	}
	// a glyph in the default ink leaves something that is not ground
	inked := false
	for y := ch; y < 2*ch; y++ {
		for x := 0; x < cw; x++ {
			if at(x, y) != shotGround {
				inked = true
			}
		}
	}
	if !inked {
		t.Error("the x left no ink")
	}
	// the cursor's outline
	if at(5*cw, ch) != shotInk {
		t.Errorf("cursor corner = %v", at(5*cw, ch))
	}
}

// A cluster is one glyph in its run's cells, wherever a width table
// would have put it: what follows it starts where the engine said.
func TestDrawShotCluster(t *testing.T) {
	doc := `{"cols":6,"rows":1,"cursor":null,"lines":[{"y":0,"text":"✅x","runs":[
		{"x":0,"w":2,"text":"✅","cluster":true},
		{"x":2,"w":1,"text":"█","fg":"#00ff00"}]}]}`
	var g shotGrid
	if err := json.Unmarshal([]byte(doc), &g); err != nil {
		t.Fatal(err)
	}
	img, err := drawShot(g)
	if err != nil {
		t.Fatal(err)
	}
	cw := img.Bounds().Dx() / 6
	green := color.RGBA{0, 0xff, 0, 0xff}
	if img.RGBAAt(2*cw, 0) != green || img.RGBAAt(3*cw-1, 0) != green {
		t.Errorf("the block after a wide glyph is not in column 2")
	}
	if img.RGBAAt(3*cw+1, 2) == green {
		t.Errorf("the block ran into column 3")
	}
}

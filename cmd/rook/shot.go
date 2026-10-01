package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"math"
	"os"
	"os/exec"
	"strconv"
	"unicode"

	"golang.org/x/image/font"
	"golang.org/x/image/font/gofont/gomono"
	"golang.org/x/image/font/gofont/gomonobold"
	"golang.org/x/image/font/opentype"
	"golang.org/x/image/font/sfnt"
	"golang.org/x/image/math/fixed"

	"github.com/incantery/rook/internal/mux"
)

// `rook shot --png FILE`: the engine's grid (`shot --json`), drawn. The
// engine knows cells and colours; putting glyphs on pixels is this
// layer's. It is a picture of rook's grid, not of a terminal: the font
// is this file's, and the terminal's own ground is a colour chosen
// here. What it is good for is what a person would look at the glass
// for — where things are, what is filled, what colour it is.

// shotGrid is the engine's `shot --json`.
type shotGrid struct {
	Cols   int `json:"cols"`
	Rows   int `json:"rows"`
	Cursor *struct {
		X       int  `json:"x"`
		Y       int  `json:"y"`
		Visible bool `json:"visible"`
	} `json:"cursor"`
	Panes []struct {
		ID      int  `json:"id"`
		X       int  `json:"x"`
		Y       int  `json:"y"`
		W       int  `json:"w"`
		H       int  `json:"h"`
		Focused bool `json:"focused"`
	} `json:"panes"`
	Lines []shotLine `json:"lines"`
}

type shotLine struct {
	Y    int       `json:"y"`
	Text string    `json:"text"`
	Bg   string    `json:"bg"`
	Runs []shotRun `json:"runs"`
}

type shotRun struct {
	X             int    `json:"x"`
	W             int    `json:"w"`
	Text          string `json:"text"`
	Cluster       bool   `json:"cluster"`
	Fg            string `json:"fg"`
	Bg            string `json:"bg"`
	Bold          bool   `json:"bold"`
	Faint         bool   `json:"faint"`
	Italic        bool   `json:"italic"`
	Invisible     bool   `json:"invisible"`
	Underline     bool   `json:"underline"`
	Inverse       bool   `json:"inverse"`
	Strikethrough bool   `json:"strikethrough"`
}

// The ground and the ink a cell has when it names none: the terminal's
// own, which rook does not know. Catppuccin mocha's, the palette the
// chrome is built on.
var (
	shotGround = color.RGBA{0x1e, 0x1e, 0x2e, 0xff}
	shotInk    = color.RGBA{0xcd, 0xd6, 0xf4, 0xff}
)

// runShot hands every form but the picture to the engine.
func runShot(args []string) error {
	out, form := "", ""
	var rest []string
	for i := 0; i < len(args); i++ {
		if args[i] == "--png" {
			if i+1 >= len(args) {
				return fmt.Errorf("shot: --png needs a file")
			}
			out = args[i+1]
			i++
			continue
		}
		if args[i] == "--ansi" || args[i] == "--json" || args[i] == "--text" {
			form = args[i]
		}
		rest = append(rest, args[i])
	}
	if out == "" {
		execMux(append([]string{"shot"}, args...))
	}
	if form != "" {
		return fmt.Errorf("shot: --png is a form of its own; %s is another shot", form)
	}
	cmd := exec.Command(mux.EnginePath(), append([]string{"shot", "--json"}, rest...)...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	doc, err := cmd.Output()
	if err != nil {
		if msg := bytes.TrimSpace(stderr.Bytes()); len(msg) > 0 {
			return fmt.Errorf("%s", bytes.TrimPrefix(msg, []byte("rook: ")))
		}
		return fmt.Errorf("shot: the engine did not answer — is rook running?")
	}
	var g shotGrid
	if err := json.Unmarshal(doc, &g); err != nil {
		return fmt.Errorf("shot: %w", err)
	}
	img, err := drawShot(g)
	if err != nil {
		return err
	}
	f, err := os.Create(out)
	if err != nil {
		return err
	}
	if err := png.Encode(f, img); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"ok": true, "png": out, "cols": g.Cols, "rows": g.Rows,
		"width": img.Bounds().Dx(), "height": img.Bounds().Dy(),
	})
}

// shotFonts is the faces a glyph is looked for in, in order: a regular
// and a bold of the main face, then whatever the system has for the
// symbols it lacks.
type shotFonts struct {
	regular, bold []*shotFace
}

type shotFace struct {
	f    *sfnt.Font
	face font.Face
}

const shotPx = 26 // glyph size in pixels: a 13pt cell at 2x

func loadShotFonts() (*shotFonts, error) {
	mk := func(f *sfnt.Font) *shotFace {
		face, err := opentype.NewFace(f, &opentype.FaceOptions{Size: shotPx, DPI: 72, Hinting: font.HintingNone})
		if err != nil {
			return nil
		}
		return &shotFace{f: f, face: face}
	}
	var fs shotFonts
	// Menlo, where there is one: it has the arrows, the dots and the
	// geometric shapes the chrome uses. The Go fonts are the floor.
	if data, err := os.ReadFile("/System/Library/Fonts/Menlo.ttc"); err == nil {
		if col, err := opentype.ParseCollection(data); err == nil {
			for i := 0; i < col.NumFonts(); i++ {
				f, err := col.Font(i)
				if err != nil {
					continue
				}
				var buf sfnt.Buffer
				name, _ := f.Name(&buf, sfnt.NameIDSubfamily)
				switch name {
				case "Regular":
					if sf := mk(f); sf != nil {
						fs.regular = append(fs.regular, sf)
					}
				case "Bold":
					if sf := mk(f); sf != nil {
						fs.bold = append(fs.bold, sf)
					}
				}
			}
		}
	}
	for _, e := range []struct {
		ttf  []byte
		into *[]*shotFace
	}{{gomono.TTF, &fs.regular}, {gomonobold.TTF, &fs.bold}} {
		f, err := opentype.Parse(e.ttf)
		if err != nil {
			return nil, err
		}
		if sf := mk(f); sf != nil {
			*e.into = append(*e.into, sf)
		}
	}
	for _, path := range []string{
		"/System/Library/Fonts/Apple Symbols.ttf",
		"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
	} {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		f, err := opentype.Parse(data)
		if err != nil {
			continue
		}
		if sf := mk(f); sf != nil {
			fs.regular = append(fs.regular, sf)
			fs.bold = append(fs.bold, sf)
		}
	}
	if len(fs.regular) == 0 {
		return nil, fmt.Errorf("shot: no font to draw with")
	}
	return &fs, nil
}

// pick is the first face that has the rune.
func (fs *shotFonts) pick(r rune, bold bool) *shotFace {
	list := fs.regular
	if bold {
		list = fs.bold
	}
	var buf sfnt.Buffer
	for _, sf := range list {
		if i, err := sf.f.GlyphIndex(&buf, r); err == nil && i != 0 {
			return sf
		}
	}
	return nil
}

func hexColor(s string, or color.RGBA) color.RGBA {
	if len(s) != 7 || s[0] != '#' {
		return or
	}
	v, err := strconv.ParseUint(s[1:], 16, 32)
	if err != nil {
		return or
	}
	return color.RGBA{uint8(v >> 16), uint8(v >> 8), uint8(v), 0xff}
}

func mixColor(a, b color.RGBA, t float64) color.RGBA {
	m := func(x, y uint8) uint8 { return uint8(float64(x)*(1-t) + float64(y)*t) }
	return color.RGBA{m(a.R, b.R), m(a.G, b.G), m(a.B, b.B), 0xff}
}

// isMark is a codepoint that rides the one before it.
func isMark(r rune) bool {
	return unicode.Is(unicode.Mn, r) || unicode.Is(unicode.Me, r)
}

func drawShot(g shotGrid) (*image.RGBA, error) {
	fs, err := loadShotFonts()
	if err != nil {
		return nil, err
	}
	main := fs.regular[0].face
	adv, _ := main.GlyphAdvance('M')
	m := main.Metrics()
	cw := adv.Round()
	ch := (m.Ascent + m.Descent).Ceil() + 2
	base := m.Ascent.Ceil() + 1
	img := image.NewRGBA(image.Rect(0, 0, g.Cols*cw, g.Rows*ch))
	draw.Draw(img, img.Bounds(), image.NewUniform(shotGround), image.Point{}, draw.Src)

	for _, line := range g.Lines {
		y0 := line.Y * ch
		for _, run := range line.Runs {
			fg, bg := hexColor(run.Fg, shotInk), hexColor(run.Bg, shotGround)
			if run.Inverse {
				fg, bg = bg, fg
			}
			if run.Faint {
				fg = mixColor(fg, bg, 0.5)
			}
			if bg != shotGround {
				draw.Draw(img, image.Rect(run.X*cw, y0, (run.X+run.W)*cw, y0+ch), image.NewUniform(bg), image.Point{}, draw.Src)
			}
			// One character a cell — the engine says so by making
			// anything else a run of its own (`cluster`): one glyph
			// in the run's cells, its base drawn and its marks over it.
			x := run.X
			for i, r := range run.Text {
				n := 1
				cell := image.Rect(x*cw, y0, (x+1)*cw, y0+ch)
				if run.Cluster {
					n = 0
					cell = image.Rect(run.X*cw, y0, (run.X+run.W)*cw, y0+ch)
					if i > 0 && !isMark(r) {
						continue // a second base in the cluster: fonts here cannot join them
					}
				}
				if run.Invisible {
					x += n
					continue // concealed: the cell has it and does not show it
				}
				if r != ' ' && !drawBuilt(img, r, cell, fg, bg) {
					if sf := fs.pick(r, run.Bold); sf != nil {
						d := font.Drawer{Dst: img, Src: image.NewUniform(fg), Face: sf.face}
						// centred in its cell: a fallback face has its own advance
						a, _ := sf.face.GlyphAdvance(r)
						pad := (cell.Dx() - a.Round()) / 2
						d.Dot = fixed.P(cell.Min.X+max(pad, 0), y0+base)
						d.DrawString(string(r))
					} else {
						// nothing has it: say so, where it is
						outline(img, cell.Inset(cw/4), fg)
					}
				}
				x += n
			}
			if run.Underline {
				draw.Draw(img, image.Rect(run.X*cw, y0+ch-3, (run.X+run.W)*cw, y0+ch-1), image.NewUniform(fg), image.Point{}, draw.Src)
			}
			if run.Strikethrough {
				draw.Draw(img, image.Rect(run.X*cw, y0+ch/2, (run.X+run.W)*cw, y0+ch/2+2), image.NewUniform(fg), image.Point{}, draw.Src)
			}
		}
	}
	if c := g.Cursor; c != nil && c.Visible {
		outline(img, image.Rect(c.X*cw, c.Y*ch, (c.X+1)*cw, (c.Y+1)*ch), shotInk)
	}
	return img, nil
}

func outline(img *image.RGBA, r image.Rectangle, c color.RGBA) {
	u := image.NewUniform(c)
	draw.Draw(img, image.Rect(r.Min.X, r.Min.Y, r.Max.X, r.Min.Y+2), u, image.Point{}, draw.Src)
	draw.Draw(img, image.Rect(r.Min.X, r.Max.Y-2, r.Max.X, r.Max.Y), u, image.Point{}, draw.Src)
	draw.Draw(img, image.Rect(r.Min.X, r.Min.Y, r.Min.X+2, r.Max.Y), u, image.Point{}, draw.Src)
	draw.Draw(img, image.Rect(r.Max.X-2, r.Min.Y, r.Max.X, r.Max.Y), u, image.Point{}, draw.Src)
}

// drawBuilt draws the glyphs that must meet their neighbours exactly —
// box lines, block elements, the powerline caps — as geometry in the
// cell, where a font's version leaves seams. False when the rune is
// not one of them.
func drawBuilt(img *image.RGBA, r rune, c image.Rectangle, fg, bg color.RGBA) bool {
	u := image.NewUniform(fg)
	fill := func(x0, y0, x1, y1 float64) {
		w, h := float64(c.Dx()), float64(c.Dy())
		draw.Draw(img, image.Rect(
			c.Min.X+int(math.Round(x0*w)), c.Min.Y+int(math.Round(y0*h)),
			c.Min.X+int(math.Round(x1*w)), c.Min.Y+int(math.Round(y1*h))), u, image.Point{}, draw.Src)
	}
	// shade: fg where in(x, y) holds, x and y in 0..1 across the cell,
	// with the edge softened by sampling
	shade := func(in func(x, y float64) bool) {
		w, h := c.Dx(), c.Dy()
		for py := 0; py < h; py++ {
			for px := 0; px < w; px++ {
				hit := 0
				for s := 0; s < 16; s++ {
					sx := (float64(px) + (float64(s%4)+0.5)/4) / float64(w)
					sy := (float64(py) + (float64(s/4)+0.5)/4) / float64(h)
					if in(sx, sy) {
						hit++
					}
				}
				if hit > 0 {
					img.SetRGBA(c.Min.X+px, c.Min.Y+py, mixColor(bg, fg, float64(hit)/16))
				}
			}
		}
	}
	// box lines: which arms a glyph has (up, right, down, left), light
	// or heavy
	arms := func(up, right, down, left bool, heavy bool) {
		t := 2.0
		if heavy {
			t = 4.0
		}
		tx, ty := t/float64(c.Dx())/2, t/float64(c.Dy())/2
		if up {
			fill(0.5-tx, 0, 0.5+tx, 0.5+ty)
		}
		if down {
			fill(0.5-tx, 0.5-ty, 0.5+tx, 1)
		}
		if left {
			fill(0, 0.5-ty, 0.5+tx, 0.5+ty)
		}
		if right {
			fill(0.5-tx, 0.5-ty, 1, 0.5+ty)
		}
	}
	switch r {
	case '│':
		arms(true, false, true, false, false)
	case '─':
		arms(false, true, false, true, false)
	case '┃':
		arms(true, false, true, false, true)
	case '━':
		arms(false, true, false, true, true)
	case '┌', '╭':
		arms(false, true, true, false, false)
	case '┐', '╮':
		arms(false, false, true, true, false)
	case '└', '╰':
		arms(true, true, false, false, false)
	case '┘', '╯':
		arms(true, false, false, true, false)
	case '├':
		arms(true, true, true, false, false)
	case '┤':
		arms(true, false, true, true, false)
	case '┬':
		arms(false, true, true, true, false)
	case '┴':
		arms(true, true, false, true, false)
	case '┼':
		arms(true, true, true, true, false)
	case '█':
		fill(0, 0, 1, 1)
	case '▀':
		fill(0, 0, 1, 0.5)
	case '▄':
		fill(0, 0.5, 1, 1)
	case '▌':
		fill(0, 0, 0.5, 1)
	case '▐':
		fill(0.5, 0, 1, 1)
	case '▔':
		fill(0, 0, 1, 0.125)
	case '▕':
		fill(0.875, 0, 1, 1)
	case '▘':
		fill(0, 0, 0.5, 0.5)
	case '▝':
		fill(0.5, 0, 1, 0.5)
	case '▖':
		fill(0, 0.5, 0.5, 1)
	case '▗':
		fill(0.5, 0.5, 1, 1)
	case '▚':
		fill(0, 0, 0.5, 0.5)
		fill(0.5, 0.5, 1, 1)
	case '▞':
		fill(0.5, 0, 1, 0.5)
		fill(0, 0.5, 0.5, 1)
	case '▙':
		fill(0, 0, 0.5, 1)
		fill(0.5, 0.5, 1, 1)
	case '▛':
		fill(0, 0, 0.5, 1)
		fill(0.5, 0, 1, 0.5)
	case '▜':
		fill(0.5, 0, 1, 1)
		fill(0, 0, 0.5, 0.5)
	case '▟':
		fill(0.5, 0, 1, 1)
		fill(0, 0.5, 0.5, 1)
	case '░', '▒', '▓':
		t := map[rune]float64{'░': 0.25, '▒': 0.5, '▓': 0.75}[r]
		draw.Draw(img, c, image.NewUniform(mixColor(bg, fg, t)), image.Point{}, draw.Src)
	// powerline: the caps the tab bar's segments end in
	case 0xe0b0: // right-pointing
		shade(func(x, y float64) bool { return x <= 1-math.Abs(2*y-1) })
	case 0xe0b2: // left-pointing
		shade(func(x, y float64) bool { return 1-x <= 1-math.Abs(2*y-1) })
	case 0xe0b4: // round, bulging right
		shade(func(x, y float64) bool { return x*x+(2*y-1)*(2*y-1) <= 1 })
	case 0xe0b6: // round, bulging left
		shade(func(x, y float64) bool { return (1-x)*(1-x)+(2*y-1)*(2*y-1) <= 1 })
	case 0xe0b8: // lower left
		shade(func(x, y float64) bool { return x <= y })
	case 0xe0ba: // lower right
		shade(func(x, y float64) bool { return 1-x <= y })
	case 0xe0bc: // upper left
		shade(func(x, y float64) bool { return x <= 1-y })
	case 0xe0be: // upper right
		shade(func(x, y float64) bool { return 1-x <= 1-y })
	default:
		// eighths: ▁▂▃▅▆▇ from the bottom, ▏▎▍▋▊▉ from the left
		switch {
		case r >= 0x2581 && r <= 0x2587:
			fill(0, 1-float64(r-0x2580)/8, 1, 1)
		case r >= 0x2589 && r <= 0x258f:
			fill(0, 0, float64(0x2590-r)/8, 1)
		default:
			return false
		}
	}
	return true
}

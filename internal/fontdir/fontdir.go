// Package fontdir locates installed font files by family name and serves
// their bytes to the webview.
//
// Why this exists: WebKit's canvas 2D refuses user-installed fonts (a
// fingerprinting mitigation) — DOM text renders them, fillText silently
// falls back. The WebGL terminal renderer rasterizes its glyph atlas through
// canvas, so the configured terminal font would quietly degrade to Menlo and
// every nerd-font icon to tofu. Fonts loaded via the FontFace API *are*
// visible to canvas, but the webview can't read ~/Library/Fonts itself —
// so the Go side finds the file and hands the bytes over /rookfont.
package fontdir

import (
	"encoding/binary"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unicode/utf16"
)

// face is one style of one family, pointing at the file that carries it.
type face struct {
	path string
}

// key is the lookup identity: lowercased family + normalized style.
type key struct {
	family string
	style  string // "regular" | "bold" | "italic" | "bolditalic"
}

var (
	scanOnce sync.Once
	faces    map[key]face
)

// dirs are macOS font locations, user-installed first (user fonts shadow
// system fonts of the same name, matching how CoreText resolves them).
func dirs() []string {
	var out []string
	if home, err := os.UserHomeDir(); err == nil {
		out = append(out, filepath.Join(home, "Library", "Fonts"))
	}
	return append(out,
		"/Library/Fonts",
		"/System/Library/Fonts",
		"/System/Library/Fonts/Supplemental",
	)
}

// Find returns the font file for a family+style, scanning once and caching.
// Style is one of regular/bold/italic/bolditalic.
func Find(family, style string) (string, bool) {
	scanOnce.Do(scan)
	f, ok := faces[key{strings.ToLower(strings.TrimSpace(family)), style}]
	if !ok {
		return "", false
	}
	return f.path, true
}

func scan() {
	faces = make(map[key]face)
	for _, dir := range dirs() {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			switch strings.ToLower(filepath.Ext(e.Name())) {
			case ".ttf", ".otf", ".ttc":
			default:
				continue
			}
			p := filepath.Join(dir, e.Name())
			for _, n := range names(p) {
				k := key{strings.ToLower(n.family), n.style}
				if _, exists := faces[k]; !exists { // earlier dirs win
					faces[k] = face{path: p}
				}
			}
		}
	}
}

type nameInfo struct {
	family string
	style  string
}

// names parses the sfnt 'name' table(s) of a font file (including .ttc
// collections) and returns each face's family + normalized style. Errors are
// swallowed: an unparseable font is simply not offered.
func names(path string) []nameInfo {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	var tag [4]byte
	if _, err := io.ReadFull(f, tag[:]); err != nil {
		return nil
	}
	var offsets []int64
	if string(tag[:]) == "ttcf" {
		var hdr [8]byte // version u32, numFonts u32
		if _, err := io.ReadFull(f, hdr[:]); err != nil {
			return nil
		}
		n := binary.BigEndian.Uint32(hdr[4:])
		if n > 64 {
			return nil
		}
		offs := make([]byte, 4*n)
		if _, err := io.ReadFull(f, offs); err != nil {
			return nil
		}
		for i := uint32(0); i < n; i++ {
			offsets = append(offsets, int64(binary.BigEndian.Uint32(offs[4*i:])))
		}
	} else {
		offsets = []int64{0}
	}

	var out []nameInfo
	for _, off := range offsets {
		if n, ok := parseOne(f, off); ok {
			out = append(out, n)
		}
	}
	return out
}

// parseOne reads one sfnt directory at off and extracts family/subfamily
// from its 'name' table.
func parseOne(f *os.File, off int64) (nameInfo, bool) {
	var hdr [12]byte // version u32, numTables u16, searchRange u16, entrySelector u16, rangeShift u16
	if _, err := f.ReadAt(hdr[:], off); err != nil {
		return nameInfo{}, false
	}
	numTables := int(binary.BigEndian.Uint16(hdr[4:]))
	if numTables > 512 {
		return nameInfo{}, false
	}
	recs := make([]byte, 16*numTables)
	if _, err := f.ReadAt(recs, off+12); err != nil {
		return nameInfo{}, false
	}
	var nameOff, nameLen uint32
	for i := range numTables {
		r := recs[16*i:]
		if string(r[:4]) == "name" {
			nameOff = binary.BigEndian.Uint32(r[8:])
			nameLen = binary.BigEndian.Uint32(r[12:])
			break
		}
	}
	if nameOff == 0 || nameLen == 0 || nameLen > 1<<20 {
		return nameInfo{}, false
	}
	table := make([]byte, nameLen)
	if _, err := f.ReadAt(table, int64(nameOff)); err != nil {
		return nameInfo{}, false
	}
	if len(table) < 6 {
		return nameInfo{}, false
	}
	count := int(binary.BigEndian.Uint16(table[2:]))
	strOff := int(binary.BigEndian.Uint16(table[4:]))

	// nameID 16/17 (typographic family/subfamily) are preferred over 1/2:
	// they keep "Bold" in the style where 1/2 sometimes bake it into the
	// family. Track both and pick.
	got := map[uint16]string{}
	for i := range count {
		rec := 6 + 12*i
		if rec+12 > len(table) {
			break
		}
		platform := binary.BigEndian.Uint16(table[rec:])
		nameID := binary.BigEndian.Uint16(table[rec+6:])
		length := int(binary.BigEndian.Uint16(table[rec+8:]))
		offset := int(binary.BigEndian.Uint16(table[rec+10:]))
		if nameID != 1 && nameID != 2 && nameID != 16 && nameID != 17 {
			continue
		}
		start := strOff + offset
		if start+length > len(table) {
			continue
		}
		raw := table[start : start+length]
		var s string
		switch platform {
		case 0, 3: // Unicode / Windows: UTF-16BE
			u := make([]uint16, 0, length/2)
			for j := 0; j+1 < length; j += 2 {
				u = append(u, binary.BigEndian.Uint16(raw[j:]))
			}
			s = string(utf16.Decode(u))
		case 1: // Mac Roman; ASCII names are the practical case
			s = string(raw)
		default:
			continue
		}
		if _, seen := got[nameID]; !seen && s != "" {
			got[nameID] = s
		}
	}
	family := got[16]
	if family == "" {
		family = got[1]
	}
	sub := got[17]
	if sub == "" {
		sub = got[2]
	}
	if family == "" {
		return nameInfo{}, false
	}
	return nameInfo{family: family, style: normStyle(sub)}, true
}

func normStyle(sub string) string {
	s := strings.ToLower(sub)
	bold := strings.Contains(s, "bold")
	italic := strings.Contains(s, "italic") || strings.Contains(s, "oblique")
	switch {
	case bold && italic:
		return "bolditalic"
	case bold:
		return "bold"
	case italic:
		return "italic"
	default:
		return "regular"
	}
}

// Middleware serves GET /rookfont?family=...&style=... ahead of the asset
// handler. Unknown families 404 — the frontend fails open to whatever the
// browser's own fallback produces.
func Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/rookfont" {
			next.ServeHTTP(w, r)
			return
		}
		family := r.URL.Query().Get("family")
		style := r.URL.Query().Get("style")
		if style == "" {
			style = "regular"
		}
		path, ok := Find(family, style)
		if !ok {
			http.NotFound(w, r)
			return
		}
		b, err := os.ReadFile(path)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "font/ttf")
		w.Header().Set("Cache-Control", "no-cache") // font installs should show up on reload
		_, _ = w.Write(b)
	})
}

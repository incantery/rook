package vt

// scrollback is a bounded, zero-allocation ring of lines that have scrolled off
// the top of the primary screen. Like the live grid (D3) it is one preallocated
// flat []Cell addressed as a ring, so retaining history costs no per-line
// allocation and the collector never sees it — the property that lets many
// sessions keep scrollback cheaply. When it fills, the oldest line is evicted.
//
// Only the primary screen has scrollback. The alt screen belongs to a
// full-screen program that owns the whole viewport; its scrolls are redraws,
// not history, so nothing there is retained.
type scrollback struct {
	w, cap int
	rows   []Cell // cap*w cells, addressed as a ring of lines
	head   int    // slot of the oldest retained line
	count  int    // lines currently retained, <= cap
	pushed uint64 // lines ever pushed — the absolute index of the next push.
	// Absolute indexing is what lets a client page history without holding
	// it: line i keeps its index for the life of the ring, eviction just
	// moves the retained window's base (pushed-count) past it.
}

func newScrollback(w, capLines int) *scrollback {
	if capLines < 1 {
		capLines = 1
	}
	sb := &scrollback{w: w, cap: capLines, rows: make([]Cell, capLines*w)}
	for i := range sb.rows {
		sb.rows[i] = blank
	}
	return sb
}

// push copies one line (w cells) into the ring, evicting the oldest if full.
func (sb *scrollback) push(line []Cell) {
	sb.pushed++
	var slot int
	if sb.count < sb.cap {
		slot = (sb.head + sb.count) % sb.cap
		sb.count++
	} else {
		slot = sb.head
		sb.head = (sb.head + 1) % sb.cap
	}
	copy(sb.rows[slot*sb.w:slot*sb.w+sb.w], line)
}

// row returns line i as a read-only slice into the ring, where 0 is the oldest
// retained line and count-1 is the most recently scrolled off.
func (sb *scrollback) row(i int) []Cell {
	slot := (sb.head + i) % sb.cap
	return sb.rows[slot*sb.w : slot*sb.w+sb.w]
}

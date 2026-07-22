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
	lens   []int  // used length per slot; cells beyond it are blank (unstored)
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
	return &scrollback{w: w, cap: capLines, rows: make([]Cell, capLines*w), lens: make([]int, capLines)}
}

// push copies one line into the ring, evicting the oldest if full. Callers pass
// only the line's used prefix (the screen's high-water mark) — the copy follows
// content width, not terminal width, which is most of the ring's cost on a wide
// grid. Slots are reused without clearing: lens says where a line ends, and the
// stale cells beyond it are never read.
func (sb *scrollback) push(line []Cell) {
	sb.pushed++
	n := min(len(line), sb.w)
	var slot int
	if sb.count < sb.cap {
		slot = (sb.head + sb.count) % sb.cap
		sb.count++
	} else {
		slot = sb.head
		sb.head = (sb.head + 1) % sb.cap
	}
	copy(sb.rows[slot*sb.w:], line[:n])
	sb.lens[slot] = n
}

// row returns the used prefix of line i as a read-only slice into the ring,
// where 0 is the oldest retained line and count-1 is the most recently scrolled
// off. Cells beyond the prefix are blank; callers pad.
func (sb *scrollback) row(i int) []Cell {
	slot := (sb.head + i) % sb.cap
	return sb.rows[slot*sb.w : slot*sb.w+sb.lens[slot]]
}

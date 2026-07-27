// The scrollback store: a viewport over the host's history ring
// (reverse-paginated virtualized scrolling), shared by every renderer.
//
// History lives host-side; this caches pages of absolute-indexed lines. Rows a
// renderer watches scroll off enter the cache for free; everything else is
// fetched on demand (onFetch → msgSbFetch) and evicted when far from the
// viewport — N sessions of deep history cost the client ~a screenful each,
// not a copy. Extracted from the renderer when the scrollback viewport grew a
// scrollback view; the painting stays in the renderers, the state machine
// lives here where it can be unit-tested.

import type {Frame, SbChunk, WCell} from "./frame";

/** history page size: request granularity and the prefetch unit. */
export const SB_PAGE = 128;
/** an in-flight page request older than this may be re-asked (it was dropped). */
const SB_RETRY_MS = 2000;

export class SbStore {
    private cache = new Map<number, WCell[]>();
    private inflight = new Map<number, number>(); // page start -> request time
    private total = 0; // absolute index of the live screen's top row
    private base = 0; // lowest fetchable index the host has reported
    private epoch = -1; // history numbering; a frame with a new one voids the cache
    private viewOffset = 0; // 0 = pinned to the live bottom, N = N lines back

    constructor(
        private cap = 5000,
        private onFetch?: (start: number, count: number) => void,
    ) {}

    /** how many lines the viewport is scrolled back (0 = live). */
    get offset(): number {
        return this.viewOffset;
    }

    /** how far back the viewport can go (what the host holds). */
    get max(): number {
        return this.total - this.base;
    }

    /** noteFrame ingests a frame's history bookkeeping BEFORE the grid applies
     *  it: void the cache on an epoch change, capture the departing rows at
     *  their absolute indices, and keep a scrolled-up viewport pinned to the
     *  same content. rowCells must read the PRE-scroll grid. */
    noteFrame(frame: Frame, rows: number, rowCells: (y: number) => WCell[]): void {
        const prevTotal = this.total;
        if (frame.epoch !== this.epoch) {
            // history was renumbered (resize, reset) — cached pages are void
            this.epoch = frame.epoch;
            this.cache.clear();
            this.inflight.clear();
            this.base = 0;
            this.viewOffset = 0;
        } else if (frame.scroll > 0) {
            // The departing rows are the OLDEST unseen lines: they live at
            // [prevTotal, prevTotal+scroll). When hist outran the capped scroll
            // (a burst bigger than the screen), the lines in between were never
            // on this screen — they stay uncached, fetchable from the host ring.
            const n = Math.min(frame.scroll, rows);
            for (let y = 0; y < n; y++) this.cache.set(prevTotal + y, rowCells(y));
            this.evictFar();
            // if the viewport is scrolled up, keep it pinned to the same content
            if (this.viewOffset > 0) {
                this.viewOffset = Math.min(
                    this.viewOffset + (frame.hist - prevTotal),
                    frame.hist - this.base,
                );
            }
        }
        this.total = frame.hist;
    }

    /** applyChunk fills the cache from a fetched history page. Returns false
     *  for a stale-epoch chunk (dropped). The caller repaints its viewport when
     *  true and scrolled. */
    applyChunk(ch: SbChunk): boolean {
        if (ch.epoch !== this.epoch) return false; // stale numbering; drop it
        this.base = ch.base;
        this.total = Math.max(this.total, ch.total);
        for (let j = 0; j < ch.lines.length; j++) this.cache.set(ch.start + j, ch.lines[j]);
        // release in-flight pages this reply covered (or that eviction voided)
        const end = ch.start + ch.lines.length;
        for (const p of Array.from(this.inflight.keys())) {
            if ((p < end && p + SB_PAGE > ch.start) || p + SB_PAGE <= ch.base) {
                this.inflight.delete(p);
            }
        }
        this.evictFar();
        // the host may hold less than we hoped — re-clamp, then show what came
        this.viewOffset = Math.min(this.viewOffset, this.max);
        return true;
    }

    /** scroll moves the viewport by delta lines (positive = back into history),
     *  clamped to what the host holds. Returns whether it moved. */
    scroll(delta: number): boolean {
        const next = Math.max(0, Math.min(this.max, this.viewOffset + delta));
        if (next === this.viewOffset) return false;
        this.viewOffset = next;
        return true;
    }

    /** toBottom pins the viewport back to the live screen. */
    toBottom(): boolean {
        if (this.viewOffset === 0) return false;
        this.viewOffset = 0;
        return true;
    }

    /** viewport maps each display row to its cells at the current offset —
     *  live rows from liveRow, history rows from the cache (null while a fetch
     *  is pending; the chunk's arrival repaints them). Requests the missing
     *  pages plus one screenful above as prefetch. */
    viewport(rows: number, liveRow: (y: number) => WCell[]): (WCell[] | null)[] {
        const out: (WCell[] | null)[] = [];
        const missing: number[] = [];
        for (let y = 0; y < rows; y++) {
            const a = this.total - this.viewOffset + y;
            if (a >= this.total) {
                out.push(liveRow(a - this.total));
            } else if (a >= 0) {
                const hit = this.cache.get(a);
                if (hit) out.push(hit);
                else {
                    if (a >= this.base) missing.push(a);
                    out.push(null);
                }
            } else {
                out.push(null);
            }
        }
        this.fetchPages(missing, rows);
        return out;
    }

    /** evictFar trims the cache to cap, dropping the lines farthest from the
     *  viewport — the ones a resumed scroll is least likely to want next. */
    private evictFar(): void {
        if (this.cache.size <= this.cap) return;
        const center = this.total - this.viewOffset;
        const keys = [...this.cache.keys()].sort(
            (a, b) => Math.abs(b - center) - Math.abs(a - center),
        );
        const drop = this.cache.size - Math.floor(this.cap * 0.9);
        for (let i = 0; i < drop; i++) this.cache.delete(keys[i]);
    }

    /** fetchPages requests the page-aligned chunks covering the given absolute
     *  indices, plus one screenful above the viewport as prefetch — so smooth
     *  wheeling stays ahead of the round trip. Deduped against in-flight
     *  requests; a request older than SB_RETRY_MS may be re-asked (dropped). */
    private fetchPages(missing: number[], rows: number): void {
        if (!this.onFetch) return;
        if (this.viewOffset > 0) {
            const top = this.total - this.viewOffset;
            const lo = Math.max(this.base, top - rows);
            for (let a = lo; a < top; a++) {
                if (!this.cache.has(a)) missing.push(a);
            }
        }
        if (missing.length === 0) return;
        const pages = new Set<number>();
        for (const a of missing) pages.add(Math.floor(a / SB_PAGE) * SB_PAGE);
        const now = Date.now();
        for (const p of pages) {
            const asked = this.inflight.get(p);
            if (asked !== undefined && now - asked < SB_RETRY_MS) continue;
            this.inflight.set(p, now);
            this.onFetch(p, SB_PAGE);
        }
    }
}

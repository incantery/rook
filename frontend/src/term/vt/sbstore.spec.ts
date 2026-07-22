import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";
import type {Frame, SbChunk, WCell} from "./frame";
import {SB_PAGE, SbStore} from "./sbstore";

// The scrollback store's state machine: capture labeling, epoch voiding,
// clamping, page-aligned fetch with prefetch and retry, and eviction. The
// wire round trip is e2e territory (scrollback.spec.ts); this owns the pure
// logic both renderers share.

const cell = (ch: string): WCell => ({content: ch, fg: 0, bg: 0, attr: 0, width: 1});
const line = (s: string): WCell[] => [...s].map(cell);
const text = (cells: WCell[] | null): string => (cells ?? []).map((c) => c.content).join("");

/** a scroll frame: rows shifted off since last frame + the new absolute top. */
const frame = (scroll: number, hist: number, epoch = 0): Frame => ({
    cursor: {x: 0, y: 0, visible: true},
    scroll,
    hist,
    epoch,
    rows: [],
});

const chunk = (start: number, lines: WCell[][], base = 0, total = 0, epoch = 0): SbChunk => ({
    epoch,
    base,
    total,
    start,
    lines,
});

const ROWS = 4;

describe("SbStore", () => {
    let fetches: [number, number][];
    let sb: SbStore;
    /** live screen rows: r0..r3 */
    const live = (y: number) => line(`r${y}`);

    beforeEach(() => {
        vi.useFakeTimers();
        fetches = [];
        sb = new SbStore(50, (s, c) => fetches.push([s, c]));
    });
    afterEach(() => {
        vi.useRealTimers();
    });

    it("captures departing rows at their absolute indices", () => {
        sb.noteFrame(frame(0, 0), ROWS, live); // adopt epoch 0 at the start
        sb.noteFrame(frame(2, 2), ROWS, live); // rows 0,1 scrolled off
        sb.scroll(2);
        const view = sb.viewport(ROWS, live);
        expect(view.map(text)).toEqual(["r0", "r1", "r0", "r1"]);
        // history above, then the live screen from its top
    });

    it("a burst bigger than the screen leaves the gap fetchable, view pinned", () => {
        sb.noteFrame(frame(0, 10), ROWS, live);
        sb.scroll(3); // wants lines 7,8,9 — none cached
        fetches = [];
        const view = sb.viewport(ROWS, live);
        expect(view.slice(0, 3)).toEqual([null, null, null]);
        expect(fetches).toEqual([[0, SB_PAGE]]); // page-aligned fetch covers them
        // scroll capped at screen height but hist jumped: capture labels only
        // the rows this client actually saw
        sb.noteFrame(frame(4, 30), ROWS, live);
        expect(sb.offset).toBe(3 + 20); // pinned to the same content
    });

    it("an epoch change voids the cache and re-pins to the bottom", () => {
        sb.noteFrame(frame(0, 0), ROWS, live);
        sb.noteFrame(frame(2, 2), ROWS, live);
        sb.scroll(1);
        expect(sb.offset).toBe(1);
        sb.noteFrame(frame(0, 0, 7), ROWS, live); // resize renumbered history
        expect(sb.offset).toBe(0);
        sb.scroll(5);
        expect(sb.offset).toBe(0); // nothing scrollable: total is 0 again
    });

    it("scroll clamps to what the host holds and chunks re-clamp", () => {
        sb.noteFrame(frame(0, 100), ROWS, live);
        sb.scroll(500);
        expect(sb.offset).toBe(100); // base 0 assumed until the host says less
        // the host ring actually starts at 80 — the chunk teaches us
        expect(sb.applyChunk(chunk(80, [line("h80")], 80, 100))).toBe(true);
        expect(sb.offset).toBe(20);
        expect(sb.max).toBe(20);
    });

    it("drops stale-epoch chunks", () => {
        sb.noteFrame(frame(0, 10), ROWS, live);
        expect(sb.applyChunk(chunk(0, [line("old")], 0, 10, 3))).toBe(false);
        sb.scroll(1);
        expect(text(sb.viewport(ROWS, live)[ROWS - 1 - 1] ?? null)).not.toBe("old");
    });

    it("fetches page-aligned with a screenful of prefetch, deduped until retry", () => {
        sb.noteFrame(frame(0, 300), ROWS, live);
        sb.scroll(2); // viewport rows at 298,299 + prefetch [294,298)
        sb.viewport(ROWS, live);
        expect(fetches).toEqual([[Math.floor(294 / SB_PAGE) * SB_PAGE, SB_PAGE]]); // one page: 256
        fetches = [];
        sb.viewport(ROWS, live); // immediately again — in-flight, no re-ask
        expect(fetches).toEqual([]);
        vi.advanceTimersByTime(2500); // the request evidently fell on the floor
        sb.viewport(ROWS, live);
        expect(fetches).toEqual([[256, SB_PAGE]]);
    });

    it("chunk arrival satisfies the viewport and releases in-flight pages", () => {
        sb.noteFrame(frame(0, 300), ROWS, live);
        sb.scroll(2);
        sb.viewport(ROWS, live);
        const lines = Array.from({length: SB_PAGE}, (_, j) => line(`h${256 + j}`));
        expect(sb.applyChunk(chunk(256, lines, 0, 300))).toBe(true);
        fetches = [];
        const view = sb.viewport(ROWS, live);
        expect(view.map(text)).toEqual(["h298", "h299", "r0", "r1"]);
        expect(fetches).toEqual([]); // nothing missing, in-flight released
    });

    it("evicts the lines farthest from the viewport once over cap", () => {
        sb = new SbStore(10, (s, c) => fetches.push([s, c]));
        sb.noteFrame(frame(0, 0), ROWS, live);
        // scroll 20 lines past: each frame captures ROWS rows
        for (let t = 0; t < 20; t += 2) {
            sb.noteFrame(frame(2, t + 2), ROWS, (y) => line(`h${t + y}`));
        }
        // cap 10 → trimmed to 9; the survivors hug the live end (viewport at bottom)
        const view20 = sb.viewport(ROWS, live);
        expect(view20.map(text)).toEqual(["r0", "r1", "r2", "r3"]); // live untouched
        sb.scroll(4);
        const view = sb.viewport(ROWS, live);
        // the most recent history lines survived eviction
        expect(text(view[3] ?? null)).toBe("h19");
        expect(text(view[2] ?? null)).toBe("h18");
    });
});

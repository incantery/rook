// The finder: telescope's shape, which is one picker engine over pluggable
// SOURCES. Rook already had two pickers (files, grep) that agreed on the
// overlay, the fzf motions, and the sequence-guarded fetch, and disagreed
// on everything else by accident — this is that agreement made explicit so
// the third source is a data file, not a fourth copy of the shell.
//
// The split telescope draws, and the reason it earns a preview pane:
//   finder   → load(): where the candidates come from
//   sorter   → rank(): which ones survive the query, and where the hits are
//   previewer→ preview(): what the selection looks like before you commit
//
// Two fetch shapes, because the sources genuinely differ. A STATIC source
// lists once on open and every keystroke re-ranks that list in memory (the
// file picker: 10k paths, zero wire traffic while you type). A LIVE source
// re-queries the host per keystroke and the host does the matching (grep:
// the corpus is every byte in the repo, which is not coming over the wire).
// Static sources get fuzzy highlight positions for free; live sources own
// their own relevance and report no positions.
//
// The API here is extracted from the two sources that exist, per the
// quickfix rule — it is not a plugin system, and a source is a plain
// record, not a registered lifecycle.

import {fuzzySegments} from "./fuzzy";

/** One highlight-segmented run of a row's primary text. */
export interface Segment {
    text: string;
    hit: boolean;
}

/** What the preview pane should show for the current selection. */
export interface PreviewSpec {
    /** full, openable path — already joined against any scope base */
    path: string;
    /** 1-based; the preview centers here and marks the line */
    line?: number;
    col?: number;
}

/** A row's CONTENT. The shell owns the cursor, hover, and click wrapper —
 *  a source describes what to draw, never how it is selected. */
export interface FinderRow {
    /** primary text, pre-split so fuzzy hits can be drawn accented */
    segments: Segment[];
    /** trailing mono detail (grep's matched line; the picker's "buffer") */
    detail?: string;
    /** leading mono locator (grep's path:line) drawn before the primary */
    locator?: string;
    /** dim the primary — the file picker's non-buffer tail */
    muted?: boolean;
    /** heading drawn above this row when it differs from the row before */
    group?: string;
}

/** A verb the footer advertises and the keymap dispatches. `key` is the
 *  literal chord as the shell reports it: "enter", "ctrl+q", "ctrl+v". */
export interface FinderAction<T> {
    key: string;
    /** footer keycap text ("↵", "^q") and its label */
    cap: string;
    label: string;
    /** sel is undefined on an empty list; `all` is every ranked item, which
     *  is what a send-to-quickfix verb consumes. The shell closes first. */
    run(sel: T | undefined, all: T[], query: string): void;
}

export interface LoadResult<T> {
    items: T[];
    /** scope prefix the host resolved `dir` to — shown in the footer */
    base?: string;
    /** the host capped the result set */
    truncated?: boolean;
    /** a host-side remark to show instead of rows (404s, bad regex) */
    note?: string;
}

export interface FinderSource<T> {
    id: string;
    /** the glyph in the input row — the source's identity at a glance */
    sigil: string;
    placeholder: string;
    /** static: load once, rank in memory. live: re-load per keystroke. */
    mode: "static" | "live";
    /** live sources only: don't go to the wire under this many chars */
    minQuery?: number;
    /** hint shown before a live source has enough query to run */
    prompt?: string;
    empty: string;
    load(query: string): Promise<LoadResult<T>>;
    /** static sources: rank + highlight. Omit for live (host-ranked). */
    rank?(query: string, items: T[]): Ranked<T>[];
    /** stable list key — must survive a re-rank */
    key(item: T): string;
    row(item: T, positions: number[]): FinderRow;
    /** null suppresses the preview pane for this row (a command, say) */
    preview(item: T): PreviewSpec | null;
    actions: FinderAction<T>[];
}

export interface Ranked<T> {
    item: T;
    positions: number[];
}

/** Re-export so sources build rows without importing fuzzy directly. */
export function segments(text: string, positions: number[]): Segment[] {
    return fuzzySegments(text, positions);
}

// The two sources the finder ships with. Each is a plain record — the
// picker's behavior minus everything the shell already owns, which turns
// out to be about forty lines apiece.

// The store is NOT imported here: what a source needs from it (the
// workspace, the open buffers) arrives as deps. `buffers` is a GETTER rather
// than an array because rank() runs inside the shell's $derived — calling it
// there is what keeps the buffer tier live while the picker is up, and it
// leaves these sources testable without a runes runtime.

import {joinBase, type GrepHit, type HostAPI} from "./hostapi";
import {fuzzyRank} from "./fuzzy";
import {segments, type FinderSource, type Ranked} from "./finder";

/** A candidate path, plus the two things the row needs to know about it:
 *  what to display (scope-relative) and what to open (joined). */
export interface FileItem {
    /** display form — base-relative in a scoped listing */
    path: string;
    /** openable form */
    full: string;
    /** already open — this picker is `:ls` and `:find` in one box */
    buffer: boolean;
}

export function filesSource(deps: {
    api: HostAPI;
    workspace: string;
    /** the focused shell's cwd — scopes the listing; undefined = ws root */
    dir?: string;
    /** open buffers, read at rank time so the tier stays live */
    buffers(): string[];
    open(path: string): void;
}): FinderSource<FileItem> {
    let base = "";
    return {
        id: "files",
        sigil: "›",
        placeholder: "Open file…",
        mode: "static",
        empty: "no matching files",
        async load() {
            const res = await deps.api.listFiles(deps.workspace, deps.dir);
            base = res.base ?? "";
            return {
                items: res.files.map((f) => ({
                    path: f,
                    full: joinBase(base, f),
                    buffer: false,
                })),
                base,
                truncated: res.truncated,
            };
        },
        // Two tiers, each ranked within itself: open buffers first, then the
        // rest of the repo. Buffers are read here rather than folded into
        // load() so the list stays true if one opens while the picker is up.
        rank(query, files): Ranked<FileItem>[] {
            const open = fuzzyRank(query, deps.buffers(), 200);
            const openSet = new Set(open.map((r) => r.item));
            // buffers hold FULL paths; a scoped listing's names are
            // base-relative, so dedup on the joined form
            const rest = fuzzyRank(
                query,
                files.filter((f) => !openSet.has(f.full)).map((f) => f.path),
                200,
            );
            const byPath = new Map(files.map((f) => [f.path, f]));
            return [
                ...open.map((r) => ({
                    item: {path: r.item, full: r.item, buffer: true},
                    positions: r.positions,
                })),
                ...rest.flatMap((r) => {
                    const item = byPath.get(r.item);
                    return item ? [{item, positions: r.positions}] : [];
                }),
            ];
        },
        key: (f) => (f.buffer ? `b:${f.full}` : `f:${f.full}`),
        row: (f, positions) => ({
            segments: segments(f.path, positions),
            muted: !f.buffer,
            detail: f.buffer ? "buffer" : undefined,
            group: f.buffer ? "Open buffers" : "All files",
        }),
        preview: (f) => ({path: f.full}),
        actions: [
            {
                key: "enter",
                cap: "↵",
                label: "open",
                run: (f) => f && deps.open(f.full),
            },
        ],
    };
}

export function grepSource(deps: {
    api: HostAPI;
    workspace: string;
    dir?: string;
    open(path: string, line: number, col: number): void;
    quickfix(hits: GrepHit[], query: string): void;
}): FinderSource<GrepHit> {
    return {
        id: "grep",
        sigil: "/",
        placeholder: "Grep the workspace…",
        mode: "live",
        // single chars match half the repo — wait for two
        minQuery: 2,
        prompt: "type to search file contents",
        empty: "no matches",
        async load(query) {
            const res = await deps.api.grep(deps.workspace, query, deps.dir);
            const base = res.base ?? "";
            return {
                // join once, here: every consumer downstream (open, preview,
                // quickfix) then gets a path it can use as-is
                items: res.hits.map((h) => ({...h, path: joinBase(base, h.path)})),
                base,
                truncated: res.truncated,
                note: res.note,
            };
        },
        key: (h) => `${h.path}:${h.line}:${h.col}`,
        row: (h) => ({
            // host-ranked, so no fuzzy positions — the whole matched line is
            // the content and the accent belongs on the locator instead
            segments: [{text: h.text.trim(), hit: false}],
            locator: `${h.path}:${h.line}`,
        }),
        preview: (h) => ({path: h.path, line: h.line, col: h.col}),
        actions: [
            {
                key: "enter",
                cap: "↵",
                label: "open at line",
                run: (h) => h && deps.open(h.path, h.line, h.col),
            },
            {
                key: "ctrl+q",
                cap: "^q",
                label: "→ quickfix",
                // telescope's send_to_qflist: every hit, not just the cursor
                run: (_sel, all, query) => all.length > 0 && deps.quickfix(all, query),
            },
        ],
    };
}

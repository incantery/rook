// The two sources the finder ships with. Each is a plain record — the
// picker's behavior minus everything the shell already owns, which turns
// out to be about forty lines apiece.

// The store is NOT imported here: what a source needs from it (the
// workspace, the open buffers) arrives as deps. `buffers` is a GETTER rather
// than an array because rank() runs inside the shell's $derived — calling it
// there is what keeps the buffer tier live while the picker is up, and it
// leaves these sources testable without a runes runtime.

import {joinBase, type GrepHit, type HostAPI, type ThreadInfo} from "./hostapi";
import {fuzzyRank} from "./fuzzy";
import {segments, type FinderSource, type Ranked} from "./finder";
import {statusMeta, threadStatus, STATUS_ORDER} from "./term/threadview";

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

/** Every thread in the workspace, as a finder — `,t`. The quickfix list
 *  (` t) is still the place to WORK a list down; this is the place to find
 *  one, which is a different verb and wants fuzzy matching plus a preview
 *  of the code the thread is arguing about. */
export function threadsSource(deps: {
    threads(): ThreadInfo[];
    open(id: number): void;
    source(path: string, line: number): void;
    /** hand the whole matched set to the quickfix — ⌃Q, as in grep */
    quickfix(threads: ThreadInfo[], query: string): void;
}): FinderSource<ThreadInfo> {
    return {
        id: "threads",
        sigil: "◈",
        placeholder: "Find a thread…",
        mode: "static",
        empty: "no threads here — ,c writes one",
        // the store already holds them; there is no wire call to make
        load: async () => ({items: deps.threads()}),
        // Match on everything you'd remember a thread BY — the file, the
        // status, and what was actually said. Searching "waiting auth" or
        // "grep.go cap" both have to land, which a path-only match can't do.
        rank(query, threads): Ranked<ThreadInfo>[] {
            const text = (t: ThreadInfo) => projectThread(t);
            const ranked = fuzzyRank(query, threads.map(text), 500);
            // fuzzyRank works on strings, so walk back to the threads by
            // projection. Two threads CAN project identically (the same note
            // twice on one file), so each key holds a list, not one thread.
            const byText = new Map<string, ThreadInfo[]>();
            for (const t of threads) {
                const k = text(t);
                const bucket = byText.get(k);
                if (bucket) bucket.push(t);
                else byText.set(k, [t]);
            }
            const out: Ranked<ThreadInfo>[] = [];
            for (const r of ranked) {
                for (const t of byText.get(r.item) ?? []) {
                    // positions index the projected string, which starts
                    // with the path — so highlights land on the path only
                    // while the match is inside it, and are dropped after
                    out.push({item: t, positions: r.positions});
                }
                byText.delete(r.item);
            }
            // Most-demanding first WITHIN the fuzzy order would fight the
            // ranking; instead sort by status only when there's no query,
            // which is the "show me what needs me" case.
            return query
                ? out
                : out.sort(
                      (a, b) =>
                          STATUS_ORDER[threadStatus(a.item)] - STATUS_ORDER[threadStatus(b.item)] ||
                          a.item.path.localeCompare(b.item.path) ||
                          a.item.currentStart - b.item.currentStart,
                  );
        },
        key: (t) => `t:${t.id}`,
        // Rows are grouped BY FILE, so the row itself must not repeat the
        // path — the header already said it. What's left is the thing you're
        // actually scanning for: the line, and what was said about it.
        row: (t, positions) => {
            const body = oneLineBody(t.comments[0]?.body ?? "");
            return {
                segments: segments(body, bodyPositions(t, positions, body.length)),
                locator: `${Math.max(1, t.currentStart)}`,
                detail: statusMeta(threadStatus(t)).label,
                muted: threadStatus(t) === "resolved",
                // a review is a walk through files, and a flat list of forty
                // threads hides that shape
                group: t.path,
            };
        },
        preview: (t) => ({path: t.path, line: Math.max(1, t.currentStart)}),
        actions: [
            {
                key: "enter",
                cap: "↵",
                label: "open thread",
                run: (t) => t && deps.open(t.id),
            },
            {
                key: "ctrl+s",
                cap: "^s",
                label: "jump to code",
                run: (t) => t && deps.source(t.path, Math.max(1, t.currentStart)),
            },
            {
                key: "ctrl+q",
                cap: "^q",
                label: "→ quickfix",
                run: (_sel, all, query) => all.length > 0 && deps.quickfix(all, query),
            },
        ],
    };
}

/** What a thread is matched against: the file, its status, and everything
 *  said in it — so "waiting auth" and "grep.go cap" both find their thread. */
function projectThread(t: ThreadInfo): string {
    return `${t.path} ${threadStatus(t)} ${t.comments.map((c) => c.body).join(" ")}`;
}

/** Highlight positions index the PROJECTED string; the row renders only the
 *  first comment. Translate the positions that fall inside that comment and
 *  drop the rest — a position from the path or the status would otherwise
 *  draw an accent on whatever character happened to sit at that offset. */
function bodyPositions(t: ThreadInfo, positions: number[], shown: number): number[] {
    const start = projectThread(t).length - t.comments.map((c) => c.body).join(" ").length;
    return positions.map((p) => p - start).filter((p) => p >= 0 && p < shown);
}

/** one line, short enough that a row never wraps */
function oneLineBody(s: string): string {
    const flat = s.replace(/\s+/g, " ").trim();
    return flat.length > 80 ? flat.slice(0, 80) + "…" : flat;
}

// Fuzzy path matching for the pickers — the fzf v1 shape: a forward scan
// proves the query is a subsequence (cheap rejection over 10k paths), a
// backward scan tightens the window so the alignment lands as late as it
// can (in a path, late means the basename — which is what a human means
// by "conf"), then the window is scored char-by-char with boundary/camel/
// consecutive bonuses and gap penalties. Positions come out with the
// score so the list can underline what matched.

export interface FuzzyHit {
    score: number;
    /** candidate indices that matched, ascending */
    positions: number[];
}

const MATCH = 16;
const GAP_START = -3;
const GAP_EXT = -1;
/** char after / — the start of a path segment (basenames win ties) */
const AFTER_SEP = 10;
/** char after . _ - space, or the very start */
const BOUNDARY = 8;
/** lower→upper seam inside an identifier */
const CAMEL = 7;
const CONSECUTIVE = 8;

function bonusAt(cand: string, i: number): number {
    if (i === 0) return BOUNDARY;
    const prev = cand[i - 1];
    if (prev === "/") return AFTER_SEP;
    if (prev === "." || prev === "_" || prev === "-" || prev === " ") return BOUNDARY;
    const c = cand[i];
    if (prev >= "a" && prev <= "z" && c >= "A" && c <= "Z") return CAMEL;
    return 0;
}

/** null when query isn't a subsequence of candidate (case-insensitive). */
export function fuzzyMatch(query: string, candidate: string): FuzzyHit | null {
    if (query.length === 0) return {score: 0, positions: []};
    if (query.length > candidate.length) return null;
    const q = query.toLowerCase();
    const cl = candidate.toLowerCase();

    // forward: leftmost end of any match
    let qi = 0;
    let end = -1;
    for (let ci = 0; ci < cl.length && qi < q.length; ci++) {
        if (cl[ci] === q[qi]) {
            qi++;
            end = ci;
        }
    }
    if (qi < q.length) return null;

    // backward from that end: the latest start the window allows
    const positions: number[] = [];
    for (let ci = end, qj = q.length - 1; qj >= 0; ci--) {
        if (cl[ci] === q[qj]) {
            positions.push(ci);
            qj--;
        }
    }
    positions.reverse();

    let score = 0;
    let prev = -2;
    for (const p of positions) {
        score += MATCH + bonusAt(candidate, p);
        if (p === prev + 1) score += CONSECUTIVE;
        else if (prev >= 0) score += GAP_START + GAP_EXT * (p - prev - 2);
        prev = p;
    }
    // a match that begins the basename is what path-typers mean
    const base = candidate.lastIndexOf("/") + 1;
    if (positions[0] === base) score += AFTER_SEP;
    // unmatched tail drags a little, so exact-ish names float over deep paths
    score += GAP_EXT * Math.max(0, candidate.length - 1 - positions[positions.length - 1]);
    return {score, positions};
}

/** Rank candidates; empty query keeps the given order (score 0, no marks).
 *  Ties break toward shorter paths, then the original order. */
export function fuzzyRank(
    query: string,
    candidates: string[],
    cap: number,
): {item: string; positions: number[]}[] {
    if (query.length === 0) {
        return candidates.slice(0, cap).map((item) => ({item, positions: []}));
    }
    const hits: {item: string; positions: number[]; score: number; idx: number}[] = [];
    for (let i = 0; i < candidates.length; i++) {
        const h = fuzzyMatch(query, candidates[i]);
        if (h) hits.push({item: candidates[i], positions: h.positions, score: h.score, idx: i});
    }
    hits.sort((a, b) => b.score - a.score || a.item.length - b.item.length || a.idx - b.idx);
    return hits.slice(0, cap).map(({item, positions}) => ({item, positions}));
}

/** Runs of matched/unmatched text — the list renders a few spans per row
 *  instead of a span per character. */
export function fuzzySegments(text: string, positions: number[]): {text: string; hit: boolean}[] {
    if (positions.length === 0) return [{text, hit: false}];
    const out: {text: string; hit: boolean}[] = [];
    const set = new Set(positions);
    let start = 0;
    let hit = set.has(0);
    for (let i = 1; i <= text.length; i++) {
        const h = i < text.length && set.has(i);
        if (i === text.length || h !== hit) {
            out.push({text: text.slice(start, i), hit});
            start = i;
            hit = h;
        }
    }
    return out;
}

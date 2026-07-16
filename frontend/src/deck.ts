// The command deck's view logic: every agent across every workspace as one
// flat, ordered, filterable list. Pure — no DOM, no fetch, no Svelte — so the
// ordering and filtering rules are testable without a host.
//
// The unit here is the AGENT, not the workspace. That's the whole reframe:
// the question you bring to this screen is "who needs me", and that's a
// property of an agent, so an agent is a row and its workspace is a column.
// Home.svelte used to answer it workspace-first, with agents reduced to chips
// inside a card — which meant the thing you were looking for was never
// addressable, only countable.
//
// The state vocabulary is deliberately the host's three (needs_input,
// working, quiet) and not a richer invented one. A classifier that guessed
// "planning" vs "coding" vs "testing" would be inventing signal the
// transcript does not carry, and a confident wrong label on this screen costs
// more than an honest coarse one.

import type {OverviewAgent, OverviewItem, PRInfo} from "./hostapi";

export type AgentState = "needs_input" | "working" | "quiet";

/** One agent, flattened out of its workspace and carrying enough of the
 *  workspace with it to render and to act. */
export interface DeckRow {
    /** stable identity for a keyed each. The transcript id when we have one;
     *  otherwise the pty; otherwise position — see rowKey. */
    key: string;
    workspace: string;
    /** set = the workspace is a task tree carved off this source */
    worktreeOf?: string;
    branch?: string;
    state: AgentState;
    /** what the agent is doing — its ai-title, or a stand-in when untitled */
    title: string;
    ask?: string;
    tool?: string;
    model?: string;
    costUsd?: number;
    lastEvent?: string;
    /** transcript id — absent means the conversation view can't open */
    session?: string;
    /** pty id — absent means raw attach can't open */
    rookSession?: string;
    pr?: PRInfo;
}

const RANK: Record<AgentState, number> = {needs_input: 0, working: 1, quiet: 2};

/** Ordering: whoever needs you first, then whoever's moving, then the quiet —
 *  and within a band, most recent first. This is triage order, and it is the
 *  same rule the workspace grid used; only the unit changed. */
export function compare(a: DeckRow, b: DeckRow): number {
    const byState = RANK[a.state] - RANK[b.state];
    if (byState !== 0) return byState;
    return time(b.lastEvent) - time(a.lastEvent);
}

function time(iso?: string): number {
    if (!iso) return 0;
    const t = Date.parse(iso);
    return Number.isNaN(t) ? 0 : t;
}

/** A row's identity, most-stable-first. The transcript id is the real one: it
 *  survives the pty being re-correlated. Position is the last resort and is
 *  only reached by an agent with neither id, which an old daemon sends for
 *  every row — keyed by position they'd at least stop colliding. */
function rowKey(a: OverviewAgent, workspace: string, i: number): string {
    if (a.sessionId) return a.sessionId;
    if (a.rookSession) return `pty:${a.rookSession}`;
    return `${workspace}#${i}`;
}

/** An untitled agent still needs a line. Prefer the ai-title, fall back to
 *  what it's asking, then to the tool it's running — and only then to a
 *  placeholder, because a row reading "untitled" tells you nothing but a row
 *  reading "Edit" tells you where it is. */
function titleOf(a: OverviewAgent): string {
    return a.title || a.ask || a.tool || "untitled session";
}

export function rows(items: OverviewItem[]): DeckRow[] {
    const out: DeckRow[] = [];
    for (const w of items) {
        for (const [i, a] of (w.agents ?? []).entries()) {
            out.push({
                key: rowKey(a, w.name, i),
                workspace: w.name,
                worktreeOf: w.worktreeOf,
                branch: w.branch,
                state: a.state,
                title: titleOf(a),
                ask: a.ask,
                tool: a.tool,
                model: a.model,
                costUsd: a.costUsd,
                lastEvent: a.lastEvent,
                session: a.sessionId,
                rookSession: a.rookSession,
                pr: w.pr,
            });
        }
    }
    return out.sort(compare);
}

export interface Counts {
    all: number;
    needs_input: number;
    working: number;
    quiet: number;
}

export function counts(rs: DeckRow[]): Counts {
    const c: Counts = {all: rs.length, needs_input: 0, working: 0, quiet: 0};
    for (const r of rs) c[r.state]++;
    return c;
}

/** The `/` filter. Bare words match anywhere in the row's text; `state:` and
 *  `ws:` (alias `project:`) narrow by field. Every term must match — typing
 *  more can only ever narrow, which is the property that makes a filter safe
 *  to type into blind.
 *
 *  Unknown prefixes are NOT treated as field filters: `foo:bar` is a plain
 *  substring search, so a typo shows you nothing-found rather than silently
 *  matching everything. */
export function match(r: DeckRow, query: string): boolean {
    const terms = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    if (terms.length === 0) return true;
    const haystack = [r.title, r.ask, r.workspace, r.branch, r.tool, r.model]
        .filter(Boolean)
        .join(" ")
        .toLowerCase();
    return terms.every((t) => {
        const state = prefix(t, "state:");
        if (state !== null) return r.state.startsWith(state) || short(r.state).startsWith(state);
        const ws = prefix(t, "ws:") ?? prefix(t, "project:");
        if (ws !== null) return r.workspace.toLowerCase().includes(ws);
        return haystack.includes(t);
    });
}

function prefix(term: string, p: string): string | null {
    return term.startsWith(p) ? term.slice(p.length) : null;
}

/** The state column's fixed-width label. Short so the column can be, since
 *  everything to its right is what you're actually reading. */
export function short(state: AgentState): string {
    return state === "needs_input" ? "needs" : state === "working" ? "works" : "quiet";
}

export function glyph(state: AgentState): string {
    return state === "needs_input" ? "◉" : state === "working" ? "●" : "◌";
}

export interface Group {
    workspace: string;
    rows: DeckRow[];
}

/** Group-by-workspace (the `g` toggle). Group order follows the best row in
 *  each group, so a workspace with something blocked floats up — grouping
 *  must not cost you the triage ordering it sits on top of. */
export function group(rs: DeckRow[]): Group[] {
    const by = new Map<string, DeckRow[]>();
    for (const r of rs) {
        const g = by.get(r.workspace);
        if (g) g.push(r);
        else by.set(r.workspace, [r]);
    }
    return [...by.entries()]
        .map(([workspace, rows]) => ({workspace, rows}))
        .sort((a, b) => compare(a.rows[0], b.rows[0]));
}

/** Move the cursor within a list, clamping at both ends.
 *
 *  Clamp, not wrap: j at the bottom of a triage list must not silently land
 *  you back on the first row, which is the one you most likely just acted on.
 *  Returns 0 for an empty list so the caller has no special case. */
export function move(index: number, delta: number, len: number): number {
    if (len === 0) return 0;
    return Math.min(len - 1, Math.max(0, index + delta));
}

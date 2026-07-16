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
const STATES: readonly string[] = ["needs_input", "working", "quiet"];

/** Narrow the wire's `state` to one this build understands.
 *
 *  The TS union is an assertion, not a check: the host types the field as a
 *  bare Go string, and a NEWER daemon adding a fourth state is exactly the
 *  skew this repo has been bitten by before. Left unguarded it poisoned four
 *  functions at once — NaN through compare (arbitrary sort order), a phantom
 *  NaN key in counts, and — worst — short()/glyph()'s ternaries falling
 *  through to "quiet".
 *
 *  Unknown lands in `working`, never `quiet`. Quiet is the bucket you ignore,
 *  so it is the one label that must never be applied by accident; working is
 *  the honest middle — visible, not alarming. One seam instead of four
 *  defensive lookups. */
function stateOf(raw: string): AgentState {
    return (STATES.includes(raw) ? raw : "working") as AgentState;
}

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

/** A timestamp, or undefined when there isn't a real one.
 *
 *  The zero date is the trap. A Go `time.Time` zero marshals as
 *  "0001-01-01T00:00:00Z" — a string, so it is TRUTHY, so the view's
 *  `{r.lastEvent ? ago(r.lastEvent) : ""}` guard sails straight past it and
 *  renders "739812d ago" into a 56px column. Date.parse doesn't help either:
 *  it returns a large negative number, not NaN. Normalising here means every
 *  reader's obvious guard is the correct one. */
function stampOf(iso?: string): string | undefined {
    if (!iso) return undefined;
    const t = Date.parse(iso);
    return Number.isNaN(t) || t <= 0 ? undefined : iso;
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
                state: stateOf(a.state),
                title: titleOf(a),
                ask: a.ask,
                tool: a.tool,
                model: a.model,
                costUsd: a.costUsd,
                lastEvent: stampOf(a.lastEvent),
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

/** Group-by-workspace (the `w` toggle). Group order follows the best row in
 *  each group, so a workspace with something blocked floats up — grouping
 *  must not cost you the triage ordering it sits on top of.
 *
 *  Sorts BOTH levels, and does not assume its input is ordered. It used to,
 *  silently: its only caller hands it triage-sorted rows, which made the
 *  group-level sort a no-op over an already-correct sequence — dead code that
 *  its own test could not fail, because the test fed it rows() output that
 *  was sorted before group() ever saw it. A function that is only correct for
 *  one caller's happens-to-be-sorted input is a trap for the second caller. */
export function group(rs: DeckRow[]): Group[] {
    const by = new Map<string, DeckRow[]>();
    for (const r of rs) {
        const g = by.get(r.workspace);
        if (g) g.push(r);
        else by.set(r.workspace, [r]);
    }
    return [...by.entries()]
        .map(([workspace, rows]) => ({workspace, rows: [...rows].sort(compare)}))
        .sort((a, b) => compare(a.rows[0], b.rows[0]));
}

/** The deck's tabs, in cycle order. The four agent states FILTER the list;
 *  queue and workspaces swap what the list is. They share one strip because
 *  they answer one question in descending urgency — who needs me, what's
 *  running, what could start, what exists. */
export const TABS = ["all", "needs_input", "working", "quiet", "queue", "workspaces"] as const;
export type Tab = (typeof TABS)[number];

const AGENT_TABS: readonly string[] = ["all", "needs_input", "working", "quiet"];

/** Does this tab show agent rows (vs. the queue or the workspace grid)? */
export function isAgentTab(t: Tab): boolean {
    return AGENT_TABS.includes(t);
}

/** Which rows a tab shows.
 *
 *  The non-agent tabs show NO agent rows — not "all of them unfiltered". That
 *  distinction is the whole bug: with the permissive reading the cursor still
 *  walked the full agent list behind the workspace grid, so ↵ on the
 *  workspaces tab threw you into the conversation of a row you never selected
 *  and could not see. An empty list makes every row verb a natural no-op
 *  instead of something each key has to remember to check. */
export function inTab(r: DeckRow, t: Tab): boolean {
    return isAgentTab(t) && (t === "all" || r.state === t);
}

/** gt / gT. Wraps, unlike the cursor: a tab strip is a ring you're cycling on
 *  purpose, whereas j at the bottom of a triage list must not silently land
 *  you back on the row you just acted on.
 *
 *  Modulo, not remainder. JS `%` keeps the sign, so the naive `(i + delta + n)
 *  % n` only survives ONE step of underflow and returns undefined from a
 *  function typed to return Tab — through a signature that forbids it. Only
 *  ±1 is reachable today, which is exactly how it would have sat there. */
export function cycle(tab: Tab, delta: number): Tab {
    const i = TABS.indexOf(tab);
    const n = TABS.length;
    return TABS[(((i + delta) % n) + n) % n];
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

// The terminal runtime — the imperative island of README decision 7.
// Owns every xterm instance, its WebSocket data plane, the write path,
// resize, focus, and disposal. Svelte places the container and renders the
// strip FROM this manager's state; it never drives the terminals. Nothing
// in this file may import Svelte, and no reactive system may sit between
// pty bytes and term.write().
//
// Shape (tmux model): a strip entry is a WINDOW; a window holds a layout
// tree (term/layout.ts) whose leaves are PANES; each terminal pane wraps
// one host session. view.ts projects the tree into DOM.
//
// Lifecycle rule (host-owned sessions outlive the UI): a terminal's DOM
// lives in manager-owned window containers and is removed only when its
// host session dies — screen and pane switches are CSS, never unmounts.

import type {ITheme, Terminal} from "@xterm/xterm";
import type {FitAddon} from "@xterm/addon-fit";
import type {HostAPI, SessionInfo} from "../hostapi";
import {
    leafOf,
    leaves,
    neighborOf,
    newEditorLeaf,
    newLeaf,
    normalize,
    reconcile,
    removeAt,
    setWeight,
    splitAt,
    termOnly,
} from "./layout";
import type {Dir, Edge, LayoutNode, SplitNode, StoredState, StoredWindow} from "./layout";
import {applyFocus, applyZoom, project} from "./view";
import type {ViewHooks} from "./view";

export type TermFactory = () => {term: Terminal; fit: FitAddon};

/** The UI-rate projection of a WINDOW — what the Svelte strip renders. */
export interface TabInfo {
    /** window id (uuid) — NOT a host session id */
    id: string;
    /** the focused pane's session name */
    name: string;
    workspace: string;
    /** host session ids of every pane, in leaf order — attention pulses
     *  and dashboard numbering match sessions to strip slots with this */
    sessions: string[];
}

/** UI-rate events out of the island. All of them are "state changed,
 *  re-project" signals — none carry terminal output. */
export interface TermEvents {
    /** tabs / active window / current workspace changed */
    changed(): void;
    /** the current workspace lost its last window → manager screen */
    workspaceGone(): void;
    /** a window was activated — overlays (dashboard) dismiss */
    activated(): void;
}

/** What a pane shows — the seam the editor pane will slot into. The
 *  manager only ever talks to pane content through this. */
export interface PaneContent {
    /** the pane's root element, moved (never rebuilt) by the projector */
    readonly el: HTMLElement;
    /** term panes expose their host session (attention, jump, kill,
     *  cwd-from); other pane kinds return null */
    readonly sessionId: string | null;
    /** what the strip shows while this pane is focused */
    readonly title: string;
    focus(): void;
    /** size the content to its cell and tell whoever needs to know */
    fit(force?: boolean): void;
    dispose(): void;
}

interface Tab {
    id: string;
    name: string;
    workspace: string;
    term: Terminal;
    fit: FitAddon;
    ws: WebSocket | null;
    wrap: HTMLElement;
    lastSize: string;
    /** Ring replay in flight: xterm's auto-replies to replayed queries
     *  must be filtered out of onData — their askers are long gone, and
     *  the shell would echo them as junk input. Typing passes through. */
    replaying: boolean;
}

/** A terminal pane: PaneContent over a Tab. The Tab keeps the whole
 *  replay/reconnect machinery; this is just the pane-shaped view. */
class TermPane implements PaneContent {
    constructor(
        private tab: Tab,
        private api: HostAPI,
    ) {}

    get el(): HTMLElement {
        return this.tab.wrap;
    }

    get sessionId(): string {
        return this.tab.id;
    }

    get title(): string {
        return this.tab.name;
    }

    focus(): void {
        this.tab.term.focus();
    }

    /** Fit the grid to the cell and tell the PTY, deduped on colsxrows. */
    fit(force = false): void {
        const {tab} = this;
        tab.fit.fit();
        const key = `${tab.term.cols}x${tab.term.rows}`;
        if (!force && key === tab.lastSize) return;
        tab.lastSize = key;
        this.api.resize(tab.id, tab.term.cols, tab.term.rows).catch((err) => {
            console.error("resize failed", err);
        });
    }

    /** The ONLY place terminal DOM is removed — session death. */
    dispose(): void {
        this.tab.term.dispose();
        this.tab.wrap.remove();
    }
}

/** A strip entry: the layout tree plus its runtime panes and DOM. */
interface Win {
    id: string;
    workspace: string;
    root: LayoutNode;
    panes: Map<string, PaneContent>;
    /** pane id */
    focused: string;
    /** pane id; transient — zoom never persists */
    zoomed: string | null;
    /** the .window element in #terminals */
    el: HTMLElement;
    /** paneId → .pane cell, rebuilt by project() */
    cells: Map<string, HTMLElement>;
}

// The response sequences xterm generates on its own while parsing: cursor
// position reports (CSI R), device attributes (CSI c), status reports
// (CSI n), color reports (OSC 4/10-12), and DCS replies. During replay
// these answer queries from programs that already exited; nothing here
// overlaps what a keyboard can produce (arrows/function keys use other
// finals — except modifier+F3, which collides with CPR and is an accepted
// loss inside the sub-second gate).
const AUTO_REPLY =
    /\x1b(?:\[\??\d+(?:;\d+)*[Rn]|\[[>?]?\d*(?:;\d+)*c|\](?:4|1[0-2]);[^\x07\x1b]*(?:\x07|\x1b\\)|P[^\x1b]*\x1b\\)/g;

export class TermManager {
    private sessions = new Map<string, Tab>();
    private windows: Win[] = [];
    private active: Win | null = null;
    private current = "main";
    private lastActive = new Map<string, Win>();
    /** drag-start weights of the divider being dragged — onDrag applies
     *  the TOTAL delta against these, so clamping stays cursor-true */
    private dragStart: {split: SplitNode; i: number; w: [number, number]} | null = null;
    private fitQueued = 0;

    constructor(
        private container: HTMLElement,
        private api: HostAPI,
        private mkTerm: TermFactory,
        private events: TermEvents,
    ) {}

    get workspace(): string {
        return this.current;
    }

    /** the active WINDOW id (strip identity) */
    get activeId(): string | null {
        return this.active?.id ?? null;
    }

    /** the focused pane's host session — what "the current shell" means
     *  for kill, cwd inheritance, set-root, literal-` input */
    get focusedSessionId(): string | null {
        if (!this.active) return null;
        return this.active.panes.get(this.active.focused)?.sessionId ?? null;
    }

    /** Snapshot for the strip and pickers: windows in the current workspace. */
    currentTabs(): TabInfo[] {
        return this.wsWins().map((w) => this.tabInfo(w));
    }

    private tabInfo(w: Win): TabInfo {
        const sessions = leaves(w.root).flatMap((l) =>
            l.content.type === "term" ? [l.content.session] : [],
        );
        return {
            id: w.id,
            name: w.panes.get(w.focused)?.title || "",
            workspace: w.workspace,
            sessions,
        };
    }

    workspaces(): {name: string; count: number}[] {
        const out: {name: string; count: number}[] = [];
        for (const w of this.windows) {
            const e = out.find((x) => x.name === w.workspace);
            if (e) e.count++;
            else out.push({name: w.workspace, count: 1});
        }
        return out;
    }

    private wsWins(ws = this.current): Win[] {
        return this.windows.filter((w) => w.workspace === ws);
    }

    /** Attach every live session (background-warm), rebuilding stored
     *  windows where the layout and the host agree — the host is truth,
     *  and anything unclaimed lands as a single-pane window. Activation
     *  waits for openWorkspace — the manager screen decides what to open. */
    async init(): Promise<void> {
        const sessions = await this.api.list();
        let stored: StoredState | null = null;
        try {
            const raw = localStorage.getItem("rook.layout.v1");
            stored = raw === null ? null : normalize(JSON.parse(raw));
        } catch {
            // unparseable — fail open to all-single-pane, never a broken boot
        }
        for (const s of sessions) this.addTab(s);
        for (const w of reconcile(stored, sessions)) {
            this.makeWindow(w.root, w.workspace, w.focused);
        }
        this.save(); // reconcile's repairs become the new truth
    }

    /** Persist windows (order, trees, weights, focus) — zoom stays
     *  transient, editor panes strip out entirely (rook.layout.v1 is
     *  term-only; an editor-only window has no persistent form). Called
     *  on every layout-affecting mutation. */
    private save(): void {
        const windows: StoredWindow[] = [];
        for (const w of this.windows) {
            const root = termOnly(w.root);
            if (root === null) continue;
            const ids = new Set(leaves(root).map((l) => l.id));
            windows.push({
                workspace: w.workspace,
                root,
                // focus pointing at a stripped editor pane repairs to the
                // first surviving terminal
                focused: ids.has(w.focused) ? w.focused : leaves(root)[0].id,
            });
        }
        const state: StoredState = {version: 1, windows};
        try {
            localStorage.setItem("rook.layout.v1", JSON.stringify(state));
        } catch (err) {
            console.warn("layout save failed", err);
        }
    }

    /** Enter a workspace: activate its remembered window. Returns false
     *  when it has no windows — the caller picks the landing (dashboard);
     *  switching must not force a shell into a session-less workspace. */
    openWorkspace(name: string): boolean {
        this.current = name;
        localStorage.setItem("rook.workspace", name);
        const target = this.lastActive.get(name) ?? this.wsWins(name)[0];
        if (target) {
            this.activate(target);
            return true;
        }
        // clear the stage so the previous workspace's terminal doesn't
        // linger behind the dashboard, and re-project the (empty) strip
        for (const w of this.windows) w.el.classList.remove("active");
        this.active = null;
        this.events.changed();
        return false;
    }

    /** Create the Tab for a session: terminal, wrap element, data plane.
     *  The wrap lands in the container only until a window's projector
     *  claims it (same synchronous task — nothing paints in between). */
    private addTab(s: SessionInfo): Tab {
        const wrap = document.createElement("div");
        wrap.className = "term-wrap";
        const box = document.createElement("div");
        box.className = "term-box";
        wrap.appendChild(box);
        this.container.appendChild(wrap);

        const {term, fit} = this.mkTerm();
        term.open(box);
        // Parse the replay at the pty's real grid, not xterm's 80×24
        // default — init() attaches while terminals are hidden, so fit
        // hasn't run yet. At the wrong width zsh's prompt-EOL trick
        // (inverse "%" + a row of spaces) wraps and the % stays visible;
        // reflow-on-fit can't unwrap what parsed wrong.
        if (s.cols > 0 && s.rows > 0) term.resize(s.cols, s.rows);

        const tab: Tab = {
            id: s.id,
            name: s.name,
            workspace: s.workspace || "main",
            term,
            fit,
            ws: null,
            wrap,
            lastSize: "",
            replaying: true,
        };
        term.onData((data) => {
            if (tab.ws?.readyState !== WebSocket.OPEN) return;
            if (tab.replaying) {
                data = data.replace(AUTO_REPLY, "");
                if (!data) return;
            }
            tab.ws.send(data);
        });
        this.connect(tab);
        this.sessions.set(tab.id, tab);
        return tab;
    }

    /** Build a window around a layout tree, project it (hidden until
     *  activated), and put it on the strip. Term leaves fill from their
     *  Tabs; other pane kinds arrive pre-built via `panes`. */
    private makeWindow(
        root: LayoutNode,
        workspace: string,
        focused?: string,
        panes = new Map<string, PaneContent>(),
    ): Win {
        const el = document.createElement("div");
        el.className = "window";
        this.container.appendChild(el);
        for (const l of leaves(root)) {
            if (panes.has(l.id) || l.content.type !== "term") continue;
            const tab = this.sessions.get(l.content.session);
            if (tab) panes.set(l.id, new TermPane(tab, this.api));
        }
        const win: Win = {
            id: crypto.randomUUID(),
            workspace,
            root,
            panes,
            focused: focused ?? leaves(root)[0].id,
            zoomed: null,
            el,
            cells: new Map(),
        };
        project(win, this.hooks(win));
        this.windows.push(win);
        this.save();
        this.events.changed();
        return win;
    }

    private hooks(win: Win): ViewHooks {
        return {
            onFocusPane: (paneId) => this.setFocusedPane(win, paneId),
            onDrag: (split, i, dxFrac, minFrac) => {
                if (
                    this.dragStart === null ||
                    this.dragStart.split !== split ||
                    this.dragStart.i !== i
                ) {
                    this.dragStart = {split, i, w: [split.weights[i], split.weights[i + 1]]};
                }
                split.weights[i] = this.dragStart.w[0];
                split.weights[i + 1] = this.dragStart.w[1];
                setWeight(split, i, dxFrac, minFrac);
                // rAF-throttled live refit of the two dragged subtrees;
                // the colsxrows dedupe in fit() bounds api.resize spam
                if (this.fitQueued === 0) {
                    this.fitQueued = requestAnimationFrame(() => {
                        this.fitQueued = 0;
                        for (const side of [split.children[i], split.children[i + 1]]) {
                            for (const l of leaves(side)) win.panes.get(l.id)?.fit();
                        }
                    });
                }
            },
            onDragEnd: () => {
                this.dragStart = null;
                this.syncSize(true);
                this.save(); // weights settled
            },
        };
    }

    /** Route focus to a pane (click, and later ` o / ` arrows). */
    private setFocusedPane(win: Win, paneId: string): void {
        if (!win.panes.has(paneId) || win.focused === paneId) return;
        win.focused = paneId;
        applyFocus(win);
        win.panes.get(paneId)?.focus();
        this.save(); // focus survives reload
        this.events.changed(); // the strip shows the focused pane's name
    }

    private connect(tab: Tab): void {
        tab.replaying = true;
        const ws = this.api.attach(tab.id);
        ws.binaryType = "arraybuffer";
        // While the gate is up, onData drops AUTO_REPLY sequences (answers
        // to replayed queries) and passes typing through untouched — so the
        // gate costs no input latency, only response filtering. It still
        // MUST fail open: past the replay, a live program's query answers
        // are load-bearing (vim theme detection), and a filter only a host
        // signal can lift would eat them forever under protocol skew (a
        // host predating the marker). The timer bounds the gate; the
        // marker just ends it early and precisely.
        let gate = 0;
        const lift = () => {
            if (tab.ws === ws) tab.replaying = false; // stale timers stay quiet
        };
        ws.onopen = () => {
            // The host replays its whole ring on every attach — start from
            // a blank grid or a reconnect renders the history twice.
            tab.term.reset();
            tab.ws = ws;
            gate = window.setTimeout(lift, 1500);
            this.paneInActive(tab.id)?.fit(true);
        };
        ws.onmessage = (e: MessageEvent<ArrayBuffer | string>) => {
            if (typeof e.data === "string") {
                // the replay→live seam ("live" text frame). Lift only once
                // xterm has PARSED the replay, not merely queued it — an
                // empty write's callback marks that point.
                clearTimeout(gate);
                tab.term.write("", lift);
                return;
            }
            tab.term.write(new Uint8Array(e.data));
        };
        ws.onclose = async (ev) => {
            clearTimeout(gate);
            if (tab.ws === ws) tab.ws = null;
            if (ev.reason === "replaced") return; // a newer attach owns the session
            try {
                const list = await this.api.list();
                if (list.some((s) => s.id === tab.id)) {
                    setTimeout(() => this.connect(tab), 500);
                    return;
                }
            } catch {
                // host unreachable — treat as gone
            }
            this.removeSession(tab);
        };
    }

    /** The tab's pane IF it belongs to the active window. */
    private paneInActive(sessionId: string): PaneContent | null {
        if (!this.active) return null;
        for (const p of this.active.panes.values()) {
            if (p.sessionId === sessionId) return p;
        }
        return null;
    }

    private focusedTab(win: Win): Tab | undefined {
        const sid = win.panes.get(win.focused)?.sessionId;
        return sid ? this.sessions.get(sid) : undefined;
    }

    /** New window in the current workspace, inheriting the focused
     *  shell's cwd (every window binding in the tmux config carries
     *  `-c "#{pane_current_path}"`). */
    async newSession(): Promise<void> {
        const fromWin = this.lastActive.get(this.current) ?? this.active ?? undefined;
        const from = fromWin ? this.focusedTab(fromWin) : undefined;
        const s = await this.api.create(
            from?.term.cols ?? 100,
            from?.term.rows ?? 30,
            from?.id,
            this.current,
        );
        const tab = this.addTab(s);
        this.activate(this.makeWindow(newLeaf(s.id), tab.workspace));
    }

    private activate(win: Win): void {
        this.current = win.workspace;
        localStorage.setItem("rook.workspace", this.current);
        for (const w of this.windows) w.el.classList.toggle("active", w === win);
        this.active = win;
        this.lastActive.set(win.workspace, win);
        this.syncSize(true);
        win.panes.get(win.focused)?.focus();
        this.events.changed();
        this.events.activated();
    }

    activateId(id: string): void {
        const win = this.windows.find((w) => w.id === id);
        if (win) this.activate(win);
    }

    /** Fit every pane of the active window to its cell, deduped. */
    syncSize(force = false): void {
        if (!this.active) return;
        for (const p of this.active.panes.values()) p.fit(force);
    }

    /** New single-pane window around non-terminal content — ` g's entry.
     *  The manager stays Monaco-free: the caller builds the PaneContent
     *  for the fresh leaf. */
    openPaneWindow(mk: (leafId: string) => PaneContent): void {
        const leaf = newEditorLeaf();
        const panes = new Map<string, PaneContent>([[leaf.id, mk(leaf.id)]]);
        this.activate(this.makeWindow(leaf, this.current, leaf.id, panes));
    }

    /** Close the focused pane: terminals die host-side (kill; the ws
     *  close collapses the pane), editor panes are purely local. */
    async closeActive(): Promise<void> {
        const win = this.active;
        const pane = win?.panes.get(win.focused);
        if (!win || !pane) return;
        if (pane.sessionId !== null) {
            await this.api.kill(pane.sessionId);
        } else {
            this.removePaneLocal(win, win.focused);
        }
    }

    /** Close a specific pane by its leaf id, wherever it lives — the
     *  editor's :q / :qa path, which targets panes by identity, not focus
     *  (closeActive would keep closing whatever ends up focused). */
    closePane(leafId: string): void {
        const win = this.windows.find((w) => w.panes.has(leafId));
        if (!win) return;
        const pane = win.panes.get(leafId);
        if (pane && pane.sessionId !== null) {
            void this.api.kill(pane.sessionId);
        } else {
            this.removePaneLocal(win, leafId);
        }
    }

    next(): void {
        this.step(1);
    }

    prev(): void {
        this.step(-1);
    }

    private step(d: number): void {
        const ws = this.wsWins();
        if (!this.active || ws.length < 2) return;
        const i = ws.indexOf(this.active);
        this.activate(ws[(i + d + ws.length) % ws.length]);
    }

    switchTo(index: number): void {
        const win = this.wsWins()[index];
        if (win) this.activate(win);
    }

    /** New window in the given workspace (root-seeded cwd) and jump to
     *  it — the spawner's landing pad. Returns the session id so the
     *  caller can type into it. */
    async spawnIn(workspace: string): Promise<string> {
        const from = this.active ? this.focusedTab(this.active) : undefined;
        const s = await this.api.create(
            from?.term.cols ?? 100,
            from?.term.rows ?? 30,
            undefined,
            workspace,
        );
        const tab = this.addTab(s);
        this.activate(this.makeWindow(newLeaf(s.id), tab.workspace));
        return s.id;
    }

    /** Jump to a pane by host session id, across windows and workspaces —
     *  the inbox's "take me there". activate() switches the workspace too. */
    switchToId(sessionId: string): boolean {
        for (const win of this.windows) {
            const leaf = leafOf(win.root, sessionId);
            if (!leaf) continue;
            if (win.zoomed && win.zoomed !== leaf.id) {
                win.zoomed = null; // jumping to a hidden sibling unzooms
                applyZoom(win);
            }
            if (win.focused !== leaf.id) {
                win.focused = leaf.id;
                applyFocus(win);
                this.save();
            }
            this.activate(win);
            return true;
        }
        return false;
    }

    focusActive(): void {
        this.active?.panes.get(this.active.focused)?.focus();
    }

    /** Re-theme every live terminal — the theme service calls this on a swap.
     *  New terminals pick up the theme via mkTerm (main.ts reads the service). */
    setTerminalTheme(theme: ITheme): void {
        for (const tab of this.sessions.values()) tab.term.options.theme = theme;
    }

    /** Split the focused pane: a new session (cwd inherited from the
     *  focused shell) lands in the second half — tmux ` % / ` ". */
    async splitFocused(dir: Dir): Promise<void> {
        const win = this.active;
        if (!win) return;
        this.unzoom(win); // splitting a zoomed pane unzooms first
        // no shell under the focused pane (editor) → default grid and no
        // cwd inheritance; the host seeds the workspace root instead
        const from = this.focusedTab(win);
        const baseCols = from?.term.cols ?? 100;
        const baseRows = from?.term.rows ?? 30;
        // spawn at roughly the post-split grid so the shell's first
        // prompt parses near-right; the post-project fit trues it up
        const cols = dir === "row" ? Math.max(2, Math.floor(baseCols / 2)) : baseCols;
        const rows = dir === "col" ? Math.max(2, Math.floor(baseRows / 2)) : baseRows;
        const s = await this.api.create(cols, rows, from?.id, win.workspace);
        const tab = this.addTab(s);
        const leaf = newLeaf(s.id);
        // the target pane can die during the await — the new session
        // must still land somewhere, so it falls back to its own window
        if (!this.windows.includes(win) || !win.panes.has(win.focused)) {
            this.activate(this.makeWindow(leaf, tab.workspace));
            return;
        }
        win.root = splitAt(win.root, win.focused, dir, leaf);
        win.panes.set(leaf.id, new TermPane(tab, this.api));
        win.focused = leaf.id;
        project(win, this.hooks(win));
        this.save();
        if (win === this.active) {
            // the user may have switched windows during the await — a
            // background split must not steal fit-timing or focus
            this.syncSize(true);
            win.panes.get(leaf.id)?.focus();
        }
        this.events.changed();
    }

    /** Move focus to the pane across the shared edge — ` arrows. No
     *  wrap at the layout's edge (tmux default). */
    focusPane(dir: Edge): void {
        const win = this.active;
        if (!win) return;
        const target = neighborOf(win.root, win.focused, dir);
        if (!target) return;
        this.unzoom(win); // like tmux select-pane: leaving zoom shows where you land
        this.setFocusedPane(win, target);
    }

    /** Cycle panes in leaf order — ` o. */
    cyclePane(): void {
        const win = this.active;
        if (!win) return;
        const ls = leaves(win.root);
        if (ls.length < 2) return;
        const i = ls.findIndex((l) => l.id === win.focused);
        this.unzoom(win);
        this.setFocusedPane(win, ls[(i + 1) % ls.length].id);
    }

    /** Zoom the focused pane to the full window — ` z. Transient: zoom
     *  never persists, and any structural change clears it. */
    toggleZoom(): void {
        const win = this.active;
        if (!win) return;
        if (win.zoomed === null && leaves(win.root).length < 2) return;
        win.zoomed = win.zoomed === null ? win.focused : null;
        applyZoom(win);
        this.syncSize(true);
        win.panes.get(win.focused)?.focus();
    }

    private unzoom(win: Win): void {
        if (win.zoomed === null) return;
        win.zoomed = null;
        applyZoom(win);
        if (win === this.active) this.syncSize(true);
    }

    sendToActive(data: string): void {
        const tab = this.active ? this.focusedTab(this.active) : undefined;
        if (tab?.ws?.readyState === WebSocket.OPEN) tab.ws.send(data);
    }

    /** Session death: drop its pane, collapse the tree; a window losing
     *  its last pane leaves the strip. */
    private removeSession(tab: Tab): void {
        if (!this.sessions.delete(tab.id)) return;
        const win = this.windows.find((w) => leafOf(w.root, tab.id));
        const leaf = win ? leafOf(win.root, tab.id) : null;
        if (!win || !leaf) {
            // never made it into a window — still must not leak
            tab.term.dispose();
            tab.wrap.remove();
            return;
        }
        this.removePaneLocal(win, leaf.id);
    }

    /** Drop a pane from its window and collapse the tree — the shared
     *  tail of session death and editor-pane close. The sibling absorbs
     *  the space and the focus; the last pane takes the window with it. */
    private removePaneLocal(win: Win, leafId: string): void {
        win.panes.get(leafId)?.dispose(); // the only DOM-removal site
        win.panes.delete(leafId);
        const {root, neighbor} = removeAt(win.root, leafId);
        if (root === null) {
            this.removeWindow(win);
            return;
        }
        win.root = root;
        win.zoomed = null; // any structural change clears zoom
        if (win.focused === leafId) win.focused = neighbor?.id ?? leaves(root)[0].id;
        project(win, this.hooks(win));
        if (win === this.active) {
            this.syncSize(true);
            win.panes.get(win.focused)?.focus();
        }
        this.save();
        this.events.changed();
    }

    private removeWindow(win: Win): void {
        const idx = this.windows.indexOf(win);
        if (idx !== -1) this.windows.splice(idx, 1);
        if (this.lastActive.get(win.workspace) === win) this.lastActive.delete(win.workspace);
        win.el.remove();
        this.save();
        this.events.changed();
        if (this.active !== win) return;
        this.active = null;
        const sameWs = this.wsWins(win.workspace);
        if (sameWs.length > 0) {
            this.activate(sameWs[0]);
        } else {
            // workspace died with its last window → back to the manager
            this.events.workspaceGone();
        }
    }
}

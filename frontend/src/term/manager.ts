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

import type {Terminal} from "@xterm/xterm";
import type {FitAddon} from "@xterm/addon-fit";
import type {HostAPI, SessionInfo} from "../hostapi";
import {leafOf, leaves, newLeaf, removeAt, setWeight} from "./layout";
import type {LayoutNode, SplitNode} from "./layout";
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
     *  cwd-from); future pane kinds return null */
    readonly sessionId: string | null;
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
        const sessions = leaves(w.root).map((l) => l.content.session);
        const focusedSession = w.panes.get(w.focused)?.sessionId;
        return {
            id: w.id,
            name: (focusedSession && this.sessions.get(focusedSession)?.name) || "",
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

    /** Attach every live session (background-warm) as a single-pane
     *  window; activation waits for openWorkspace — the manager screen
     *  decides what to open. */
    async init(): Promise<void> {
        const sessions = await this.api.list();
        for (const s of sessions) {
            const tab = this.addTab(s);
            this.makeWindow(newLeaf(s.id), tab.workspace);
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

    /** Build a window around a layout tree whose sessions already have
     *  Tabs, project it (hidden until activated), and put it on the strip. */
    private makeWindow(root: LayoutNode, workspace: string, focused?: string): Win {
        const el = document.createElement("div");
        el.className = "window";
        this.container.appendChild(el);
        const panes = new Map<string, PaneContent>();
        for (const l of leaves(root)) {
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
            },
        };
    }

    /** Route focus to a pane (click, and later ` o / ` arrows). */
    private setFocusedPane(win: Win, paneId: string): void {
        if (!win.panes.has(paneId) || win.focused === paneId) return;
        win.focused = paneId;
        applyFocus(win);
        win.panes.get(paneId)?.focus();
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

    /** Kill the focused pane's session (ws close does the rest). */
    async closeActive(): Promise<void> {
        const id = this.focusedSessionId;
        if (id) await this.api.kill(id);
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
            win.focused = leaf.id;
            applyFocus(win);
            this.activate(win);
            return true;
        }
        return false;
    }

    focusActive(): void {
        this.active?.panes.get(this.active.focused)?.focus();
    }

    sendToActive(data: string): void {
        const tab = this.active ? this.focusedTab(this.active) : undefined;
        if (tab?.ws?.readyState === WebSocket.OPEN) tab.ws.send(data);
    }

    /** Session death: drop its pane, collapse the tree; a window losing
     *  its last pane leaves the strip (today's exact tail). */
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
        win.panes.get(leaf.id)?.dispose(); // the only DOM-removal site
        win.panes.delete(leaf.id);
        const {root, neighbor} = removeAt(win.root, leaf.id);
        if (root === null) {
            this.removeWindow(win);
            return;
        }
        win.root = root;
        win.zoomed = null; // any structural change clears zoom
        if (win.focused === leaf.id) win.focused = neighbor?.id ?? leaves(root)[0].id;
        project(win, this.hooks(win));
        if (win === this.active) {
            this.syncSize(true);
            win.panes.get(win.focused)?.focus();
        }
        this.events.changed();
    }

    private removeWindow(win: Win): void {
        const idx = this.windows.indexOf(win);
        if (idx !== -1) this.windows.splice(idx, 1);
        if (this.lastActive.get(win.workspace) === win) this.lastActive.delete(win.workspace);
        win.el.remove();
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

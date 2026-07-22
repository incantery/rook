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

import type {HostAPI, SessionInfo} from "../hostapi";
import {decodeServerMessage, encodeInput, encodeResize} from "./vt/framed";
import {GridRenderer} from "./vt/renderer";
import "./vt/renderer.css";
import {
    findLeafBy,
    leafOf,
    leaves,
    neighborOf,
    newLeaf,
    normalize,
    reconcile,
    removeAt,
    retarget,
    setLeafFraction,
    setWeight,
    splitAt,
    termOnly,
} from "./layout";
import type {
    Dir,
    Edge,
    LayoutNode,
    LeafNode,
    PaneRef,
    SplitNode,
    StoredState,
    StoredWindow,
} from "./layout";

import {applyFocus, applyZoom, project} from "./view";
import type {ViewHooks} from "./view";

/** Where a pane lives, by id — the manager hands these out instead of its
 *  internal Win, so callers can name a pane without holding one. */
export interface PaneAt {
    winId: string;
    leafId: string;
    content: PaneRef;
}

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
    /** the host-side-emulator renderer (term/vt) that replaced xterm */
    renderer: GridRenderer;
    /** the element the renderer paints into — measured to compute the grid */
    box: HTMLElement;
    /** last geometry sent to the host (was term.cols/term.rows) */
    cols: number;
    rows: number;
    /** alt-screen state, from the host's msgState — drives keybind routing */
    alt: boolean;
    ws: WebSocket | null;
    wrap: HTMLElement;
    lastSize: string;
}

/** A terminal pane: PaneContent over a Tab. The Tab keeps the whole
 *  replay/reconnect machinery; this is just the pane-shaped view. */
class TermPane implements PaneContent {
    constructor(private tab: Tab) {}

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
        this.tab.renderer.focus();
    }

    /** Fit the grid to the cell and tell the host, deduped on colsxrows. The
     *  grid is computed from the box's pixel size and the measured cell — the
     *  work FitAddon did — then the renderer and the host are resized together. */
    fit(force = false): void {
        const {tab} = this;
        const {w, h} = tab.renderer.cellSize();
        if (!w || !h) return; // not laid out yet; a later fit trues it up
        const cols = Math.max(2, Math.floor(tab.box.clientWidth / w));
        const rows = Math.max(1, Math.floor(tab.box.clientHeight / h));
        const key = `${cols}x${rows}`;
        if (!force && key === tab.lastSize) return;
        tab.lastSize = key;
        tab.cols = cols;
        tab.rows = rows;
        tab.renderer.resize(cols, rows);
        if (tab.ws?.readyState === WebSocket.OPEN) tab.ws.send(encodeResize(cols, rows));
    }

    /** The ONLY place terminal DOM is removed — session death. */
    dispose(): void {
        this.tab.renderer.destroy();
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

    /** Is the focused pane a terminal running a FULLSCREEN app (vim, less,
     *  htop) rather than sitting at a shell prompt?
     *
     *  This is rook's answer to vim-tmux-navigator's `is_vim`, and a better
     *  one. That plugin shells out per keypress to grep `ps` for the pane's
     *  foreground process — which breaks on wrappers, ssh and sudo, and costs
     *  a fork. Entering the alternate screen buffer is instead a fact of the
     *  terminal protocol (smcup/rmcup): every full-screen TUI sets it, no
     *  shell prompt does, and xterm already tracks it for us. No poll, no
     *  staleness, no race — which matters, because the host's `fg` signal is
     *  polled at 3s and would mis-route every key between opening vim and the
     *  next tick.
     *
     *  The tradeoff vs is_vim: this is broader. `less` and `htop` are also
     *  full-screen, so they keep ⌃hjkl too, where tmux would have navigated
     *  away. "A full-screen app owns the keyboard" is the simpler rule, and
     *  the leader (` + arrows) always navigates regardless.
     *
     *  The alt-screen fact now comes from the host emulator over the wire
     *  (msgState → tab.alt), not from reading xterm's buffer. */
    get focusedInAltScreen(): boolean {
        const win = this.active;
        if (!win) return false;
        // an editor pane has no session and no TUI — it never yields
        if (!win.panes.get(win.focused)?.sessionId) return false;
        return this.focusedTab(win)?.alt ?? false;
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

        // Start at the pty's real grid, not a default — init() attaches while
        // terminals are hidden, so fit hasn't run yet. The host also parses at
        // this size until a fit resizes it.
        const cols = s.cols > 0 ? s.cols : 100;
        const rows = s.rows > 0 ? s.rows : 30;
        // eslint-disable-next-line prefer-const -- assigned below; the onInput
        // closure reads tab.ws lazily, at keypress time, when it is set.
        let tab: Tab;
        const renderer = new GridRenderer(box, cols, rows, {
            onInput: (data) => {
                if (tab.ws?.readyState === WebSocket.OPEN) tab.ws.send(encodeInput(data));
            },
        });
        tab = {
            id: s.id,
            name: s.name,
            workspace: s.workspace || "main",
            renderer,
            box,
            cols,
            rows,
            alt: false,
            ws: null,
            wrap,
            lastSize: "",
        };
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
            if (tab) panes.set(l.id, new TermPane(tab));
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
        const ws = this.api.attachFramed(tab.id);
        ws.binaryType = "arraybuffer";
        ws.onopen = () => {
            // A fresh attach: the host renders a full snapshot against a blank
            // Surface, so blank the client grid first — no replay gate, no
            // "live" seam, no query-suppression. The snapshot repaints it.
            tab.renderer.reset();
            tab.ws = ws;
            // resize the host to our current grid, and true up once laid out
            ws.send(encodeResize(tab.cols, tab.rows));
            this.paneInActive(tab.id)?.fit(true);
        };
        ws.onmessage = (e: MessageEvent<ArrayBuffer>) => {
            const msg = decodeServerMessage(e.data);
            if (msg.kind === "frame") {
                tab.renderer.applyBytes(msg.payload);
            } else if (msg.kind === "state") {
                tab.alt = msg.alt; // keybind routing reads this via focusedInAltScreen
                tab.renderer.setMouseMode(msg.mouseLevel, msg.mouseSgr);
            }
        };
        ws.onclose = async (ev) => {
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
            from?.cols ?? 100,
            from?.rows ?? 30,
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

    /** New single-pane window around non-terminal content. The manager stays
     *  Monaco-free: the caller builds the PaneContent for the fresh leaf, and
     *  passes the ref so the tree knows WHAT the pane shows. */
    openPaneWindow(content: PaneRef, mk: (leafId: string) => PaneContent): void {
        const leaf: LeafNode = {kind: "leaf", id: crypto.randomUUID(), content};
        const panes = new Map<string, PaneContent>([[leaf.id, mk(leaf.id)]]);
        this.activate(this.makeWindow(leaf, this.current, leaf.id, panes));
    }

    /** Find a pane by what it shows, current workspace only. Prefers the
     *  ACTIVE window, so "is this file already open?" answers with the copy
     *  in front of you rather than one three windows away. Returns opaque
     *  ids — Win is the manager's own business. */
    findPane(pred: (c: PaneRef) => boolean): PaneAt | null {
        const wins = this.wsWins();
        const ordered = this.active
            ? [this.active, ...wins.filter((w) => w !== this.active)]
            : wins;
        for (const win of ordered) {
            const leaf = findLeafBy(win.root, pred);
            if (leaf) return {winId: win.id, leafId: leaf.id, content: leaf.content};
        }
        return null;
    }

    /** Reveal a pane found via findPane: switch to its window, focus it. */
    revealPane(at: PaneAt): void {
        const win = this.windows.find((w) => w.id === at.winId);
        if (!win) return;
        if (this.active !== win) this.activate(win);
        this.unzoom(win);
        this.setFocusedPane(win, at.leafId);
        win.panes.get(at.leafId)?.focus();
    }

    /** Record that a pane now shows different content. The PaneContent object
     *  is untouched — it retargeted itself; this only keeps the TREE honest,
     *  which is what findPane and the strip's title read. */
    retargetPane(at: PaneAt, content: PaneRef): void {
        const win = this.windows.find((w) => w.id === at.winId);
        if (!win) return;
        win.root = retarget(win.root, at.leafId, content);
        this.save();
        this.events.changed();
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
        const s = await this.api.create(from?.cols ?? 100, from?.rows ?? 30, undefined, workspace);
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

    // The renderer reads its colors from --term-* CSS custom properties, which
    // the theme service writes onto :root on every swap (theme/cssvars.ts). A
    // theme change re-tints every live terminal with no per-tab call — so the
    // old setTerminalTheme is gone.

    /** What the focused pane SHOWS. Chrome needs this to refuse a verb that
     *  belongs to a source buffer when the keyboard is actually in a draft or
     *  a thread — activeEditor deliberately keeps pointing at the source, so
     *  it cannot answer this question. */
    focusedContent(): PaneRef | null {
        const win = this.active;
        if (!win) return null;
        return leaves(win.root).find((l) => l.id === win.focused)?.content ?? null;
    }

    /** Split the focused pane and put ARBITRARY content in the new half.
     *
     *  splitFocused is terminal-only — it unconditionally spawns a session —
     *  so until now the only way to open a non-terminal pane was
     *  openPaneWindow, which mints a whole new strip window. A comment draft
     *  wants neither: it belongs BESIDE the code it annotates, in the window
     *  already showing it, and it must not take a strip digit for the ten
     *  seconds it exists.
     *
     *  Same mk(leafId) inversion as openPaneWindow: the manager stays
     *  Monaco-free, and chrome gets the leaf id before the pane exists so it
     *  can close over it. Returns the leaf id, since a transient pane's owner
     *  needs to be able to close exactly itself later.
     *
     *  Synchronous on purpose — there's no api.create to await, so none of
     *  splitFocused's did-the-target-die-during-the-await dance applies. */
    splitWith(
        dir: Dir,
        content: PaneRef,
        mk: (leafId: string) => PaneContent,
        frac?: number,
    ): string | null {
        const win = this.active;
        if (!win) return null;
        this.unzoom(win);
        const leaf: LeafNode = {kind: "leaf", id: crypto.randomUUID(), content};
        win.root = splitAt(win.root, win.focused, dir, leaf);
        if (frac !== undefined) setLeafFraction(win.root, leaf.id, frac);
        win.panes.set(leaf.id, mk(leaf.id));
        win.focused = leaf.id;
        project(win, this.hooks(win));
        this.save();
        this.syncSize(true);
        win.panes.get(leaf.id)?.focus();
        this.events.changed();
        return leaf.id;
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
        const baseCols = from?.cols ?? 100;
        const baseRows = from?.rows ?? 30;
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
        win.panes.set(leaf.id, new TermPane(tab));
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
    /** Move focus one pane in `dir`. Returns false when the layout has no
     *  neighbour that way — i.e. we're at its edge. The workbench uses that
     *  as its hand-off signal: past the edge lies a side pane, not nothing. */
    focusPane(dir: Edge): boolean {
        const win = this.active;
        if (!win) return false;
        const target = neighborOf(win.root, win.focused, dir);
        if (!target) return false;
        this.unzoom(win); // like tmux select-pane: leaving zoom shows where you land
        this.setFocusedPane(win, target);
        return true;
    }

    /** Put DOM focus back on the focused pane — the way home from a side pane. */
    refocusPane(): void {
        const win = this.active;
        if (!win) return;
        win.panes.get(win.focused)?.focus();
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

    /** Session death: drop its pane, collapse the tree; a window losing
     *  its last pane leaves the strip. */
    private removeSession(tab: Tab): void {
        if (!this.sessions.delete(tab.id)) return;
        const win = this.windows.find((w) => leafOf(w.root, tab.id));
        const leaf = win ? leafOf(win.root, tab.id) : null;
        if (!win || !leaf) {
            // never made it into a window — still must not leak
            tab.renderer.destroy();
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

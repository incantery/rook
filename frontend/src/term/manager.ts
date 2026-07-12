// The terminal runtime — the imperative island of README decision 7.
// Owns every xterm instance, its WebSocket data plane, the write path,
// resize, focus, and disposal. Svelte places the container and renders the
// strip FROM this manager's state; it never drives the terminals. Nothing
// in this file may import Svelte, and no reactive system may sit between
// pty bytes and term.write().
//
// Lifecycle rule (host-owned sessions outlive the UI): a terminal's DOM
// lives in the manager-owned container and is removed only when its host
// session dies — screen switches are CSS visibility, never unmounts.

import type {Terminal} from "@xterm/xterm";
import type {FitAddon} from "@xterm/addon-fit";
import type {HostAPI, SessionInfo} from "../hostapi";

export type TermFactory = () => {term: Terminal; fit: FitAddon};

/** The UI-rate projection of a terminal — what the Svelte strip renders. */
export interface TabInfo {
    id: string;
    name: string;
    workspace: string;
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

interface Tab {
    id: string;
    name: string;
    workspace: string;
    term: Terminal;
    fit: FitAddon;
    ws: WebSocket | null;
    wrap: HTMLElement;
    lastSize: string;
}

export class TermManager {
    private tabs: Tab[] = [];
    private active: Tab | null = null;
    private current = "main";
    private lastActive = new Map<string, Tab>();

    constructor(
        private container: HTMLElement,
        private api: HostAPI,
        private mkTerm: TermFactory,
        private events: TermEvents,
    ) {}

    get workspace(): string {
        return this.current;
    }

    get activeId(): string | null {
        return this.active?.id ?? null;
    }

    /** Snapshot for the strip and pickers: tabs in the current workspace. */
    currentTabs(): TabInfo[] {
        return this.wsTabs().map(({id, name, workspace}) => ({id, name, workspace}));
    }

    workspaces(): {name: string; count: number}[] {
        const out: {name: string; count: number}[] = [];
        for (const t of this.tabs) {
            const w = out.find((x) => x.name === t.workspace);
            if (w) w.count++;
            else out.push({name: t.workspace, count: 1});
        }
        return out;
    }

    private wsTabs(ws = this.current): Tab[] {
        return this.tabs.filter((t) => t.workspace === ws);
    }

    /** Attach every live session (background-warm); activation waits for
     *  openWorkspace — the manager screen decides what to open. */
    async init(): Promise<void> {
        const sessions = await this.api.list();
        for (const s of sessions) this.addTab(s);
    }

    /** Enter a workspace: activate its remembered window, or spawn its
     *  first shell (the host seeds cwd from the workspace root). */
    async openWorkspace(name: string): Promise<void> {
        this.current = name;
        localStorage.setItem("rook.workspace", name);
        const target = this.lastActive.get(name) ?? this.wsTabs(name)[0];
        if (target) {
            this.activate(target);
            return;
        }
        const s = await this.api.create(100, 30, undefined, name);
        this.activate(this.addTab(s));
    }

    private addTab(s: SessionInfo): Tab {
        const wrap = document.createElement("div");
        wrap.className = "term-wrap";
        const box = document.createElement("div");
        box.className = "term-box";
        wrap.appendChild(box);
        this.container.appendChild(wrap);

        const {term, fit} = this.mkTerm();
        term.open(box);

        const tab: Tab = {
            id: s.id,
            name: s.name,
            workspace: s.workspace || "main",
            term,
            fit,
            ws: null,
            wrap,
            lastSize: "",
        };
        term.onData((data) => {
            if (tab.ws?.readyState === WebSocket.OPEN) tab.ws.send(data);
        });
        this.connect(tab);
        this.tabs.push(tab);
        this.events.changed();
        return tab;
    }

    private connect(tab: Tab): void {
        const ws = this.api.attach(tab.id);
        ws.binaryType = "arraybuffer";
        ws.onopen = () => {
            tab.ws = ws;
            if (tab === this.active) this.syncSize(true);
        };
        ws.onmessage = (e: MessageEvent<ArrayBuffer>) => {
            tab.term.write(new Uint8Array(e.data));
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
            this.removeTab(tab);
        };
    }

    /** New window in the current workspace, inheriting the active shell's
     *  cwd (every window binding in the tmux config carries
     *  `-c "#{pane_current_path}"`). */
    async newSession(): Promise<void> {
        const from = this.lastActive.get(this.current) ?? this.active ?? undefined;
        const s = await this.api.create(from?.term.cols ?? 100, from?.term.rows ?? 30, from?.id, this.current);
        this.activate(this.addTab(s));
    }

    private activate(tab: Tab): void {
        this.current = tab.workspace;
        localStorage.setItem("rook.workspace", this.current);
        for (const t of this.tabs) t.wrap.classList.toggle("active", t === tab);
        this.active = tab;
        this.lastActive.set(tab.workspace, tab);
        this.syncSize(true);
        tab.term.focus();
        this.events.changed();
        this.events.activated();
    }

    activateId(id: string): void {
        const tab = this.tabs.find((t) => t.id === id);
        if (tab) this.activate(tab);
    }

    /** Fit the active grid to its container and tell the PTY, deduped. */
    syncSize(force = false): void {
        const tab = this.active;
        if (!tab) return;
        tab.fit.fit();
        const key = `${tab.term.cols}x${tab.term.rows}`;
        if (!force && key === tab.lastSize) return;
        tab.lastSize = key;
        this.api.resize(tab.id, tab.term.cols, tab.term.rows).catch((err) => {
            console.error("resize failed", err);
        });
    }

    async closeActive(): Promise<void> {
        if (!this.active) return;
        await this.api.kill(this.active.id); // ws close does the rest
    }

    next(): void {
        this.step(1);
    }

    prev(): void {
        this.step(-1);
    }

    private step(d: number): void {
        const ws = this.wsTabs();
        if (!this.active || ws.length < 2) return;
        const i = ws.indexOf(this.active);
        this.activate(ws[(i + d + ws.length) % ws.length]);
    }

    switchTo(index: number): void {
        const tab = this.wsTabs()[index];
        if (tab) this.activate(tab);
    }

    /** New window in the given workspace (root-seeded cwd) and jump to
     *  it — the spawner's landing pad. Returns the session id so the
     *  caller can type into it. */
    async spawnIn(workspace: string): Promise<string> {
        const from = this.active ?? undefined;
        const s = await this.api.create(from?.term.cols ?? 100, from?.term.rows ?? 30, undefined, workspace);
        this.activate(this.addTab(s));
        return s.id;
    }

    /** Jump to a window by host session id, across workspaces — the
     *  inbox's "take me there". activate() switches the workspace too. */
    switchToId(sessionId: string): boolean {
        const tab = this.tabs.find((t) => t.id === sessionId);
        if (!tab) return false;
        this.activate(tab);
        return true;
    }

    focusActive(): void {
        this.active?.term.focus();
    }

    sendToActive(data: string): void {
        if (this.active?.ws?.readyState === WebSocket.OPEN) this.active.ws.send(data);
    }

    private removeTab(tab: Tab): void {
        const idx = this.tabs.indexOf(tab);
        if (idx === -1) return;
        this.tabs.splice(idx, 1);
        if (this.lastActive.get(tab.workspace) === tab) this.lastActive.delete(tab.workspace);
        tab.term.dispose();
        tab.wrap.remove();
        this.events.changed();
        if (this.active !== tab) return;
        this.active = null;
        const sameWs = this.wsTabs(tab.workspace);
        if (sameWs.length > 0) {
            this.activate(sameWs[0]);
        } else {
            // workspace died with its last window → back to the manager
            this.events.workspaceGone();
        }
    }
}

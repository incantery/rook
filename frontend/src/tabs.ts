// Workspace-aware session tabs, tmux-shaped: workspace = tmux session,
// window = host session (tab), numbered 1-based per workspace. Every tab in
// every workspace stays attached (the host keeps producing into rings
// either way); the strip renders only the current workspace, so switching
// is instant and background workspaces stay warm.

import type {Terminal} from "@xterm/xterm";
import type {FitAddon} from "@xterm/addon-fit";
import type {HostAPI, SessionInfo} from "./hostapi";

export type TermFactory = () => {term: Terminal; fit: FitAddon};

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

export class Tabs {
    private tabs: Tab[] = [];
    private active: Tab | null = null;
    private current = "main";
    private lastActive = new Map<string, Tab>();
    private dashActive = false;

    /** Called when the active workspace loses its last window — the
     *  manager (home) takes over, VS Code-style. */
    onWorkspaceGone: () => void = () => {};
    /** Called whenever the current workspace (or its tab set) changes. */
    onChange: () => void = () => {};
    /** Called when a window is activated — dismisses overlays (dashboard). */
    onActivate: () => void = () => {};
    /** The strip's window-0 button — toggles the workspace dashboard. */
    onDashboard: () => void = () => {};

    constructor(
        private stripEl: HTMLElement,
        private termsEl: HTMLElement,
        private api: HostAPI,
        private mkTerm: TermFactory,
    ) {}

    get workspace(): string {
        return this.current;
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
        this.termsEl.appendChild(wrap);

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
        this.renderStrip();
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

    activate(tab: Tab): void {
        this.current = tab.workspace;
        localStorage.setItem("rook.workspace", this.current);
        for (const t of this.tabs) t.wrap.classList.toggle("active", t === tab);
        this.active = tab;
        this.lastActive.set(tab.workspace, tab);
        this.renderStrip();
        this.syncSize(true);
        tab.term.focus();
        this.onChange();
        this.onActivate();
    }

    /** Strip state for the dashboard: window 0 lights up, the active
     *  window number dims (tmux current-window semantics). */
    setDashboardActive(v: boolean): void {
        if (this.dashActive === v) return;
        this.dashActive = v;
        this.renderStrip();
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

    focusActive(): void {
        this.active?.term.focus();
    }

    get activeId(): string | null {
        return this.active?.id ?? null;
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
        this.renderStrip();
        if (this.active !== tab) return;
        this.active = null;
        const sameWs = this.wsTabs(tab.workspace);
        if (sameWs.length > 0) {
            this.activate(sameWs[0]);
        } else {
            // workspace died with its last window → back to the manager
            this.onWorkspaceGone();
        }
    }

    /** tmux-style strip: bare 1-based window numbers within the current
     *  workspace (window-status-format ' #{window_index} ' — no names). */
    private renderStrip(): void {
        this.stripEl.innerHTML = "";
        // window 0: the workspace dashboard
        const dash = document.createElement("button");
        dash.className = "tab tab-dash" + (this.dashActive ? " active" : "");
        dash.style.setProperty("--wails-draggable", "no-drag");
        dash.textContent = "0";
        dash.title = "Dashboard (` d)";
        dash.addEventListener("click", () => this.onDashboard());
        this.stripEl.appendChild(dash);
        this.wsTabs().forEach((tab, i) => {
            const btn = document.createElement("button");
            btn.className = "tab" + (tab === this.active && !this.dashActive ? " active" : "");
            btn.style.setProperty("--wails-draggable", "no-drag");
            btn.textContent = String(i + 1);
            btn.title = tab.name;
            btn.addEventListener("click", () => this.activate(tab));
            this.stripEl.appendChild(btn);
        });
        const plus = document.createElement("button");
        plus.className = "tab tab-new";
        plus.style.setProperty("--wails-draggable", "no-drag");
        plus.textContent = "+";
        plus.title = "New window (` c)";
        plus.addEventListener("click", () => void this.newSession());
        this.stripEl.appendChild(plus);
        this.onChange();
    }
}

// Session tabs: each tab is one host session with its own xterm instance,
// kept alive in the DOM while inactive (client-side scrollback survives tab
// switches). Reattach-on-launch is what makes host sessions feel like tmux:
// the strip is rebuilt from GET /sessions, and the ring buffer replays.

import type {Terminal} from "@xterm/xterm";
import type {FitAddon} from "@xterm/addon-fit";
import type {HostAPI, SessionInfo} from "./hostapi";

export type TermFactory = () => {term: Terminal; fit: FitAddon};

interface Tab {
    id: string;
    name: string;
    term: Terminal;
    fit: FitAddon;
    ws: WebSocket | null;
    wrap: HTMLElement;
    lastSize: string;
}

export class Tabs {
    private tabs: Tab[] = [];
    private active: Tab | null = null;

    constructor(
        private stripEl: HTMLElement,
        private termsEl: HTMLElement,
        private api: HostAPI,
        private mkTerm: TermFactory,
    ) {}

    async init(): Promise<void> {
        const sessions = await this.api.list();
        for (const s of sessions) this.addTab(s);
        if (this.tabs.length === 0) {
            await this.newSession();
        } else {
            this.activate(this.tabs[0]);
        }
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

        const tab: Tab = {id: s.id, name: s.name, term, fit, ws: null, wrap, lastSize: ""};
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
            // Session gone (shell exited / killed) vs transport hiccup:
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

    async newSession(): Promise<void> {
        const cols = this.active?.term.cols ?? 100;
        const rows = this.active?.term.rows ?? 30;
        const s = await this.api.create(cols, rows);
        const tab = this.addTab(s);
        this.activate(tab);
    }

    activate(tab: Tab): void {
        for (const t of this.tabs) t.wrap.classList.toggle("active", t === tab);
        this.active = tab;
        this.renderStrip();
        this.syncSize(true);
        tab.term.focus();
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
        if (!this.active || this.tabs.length < 2) return;
        const i = this.tabs.indexOf(this.active);
        this.activate(this.tabs[(i + d + this.tabs.length) % this.tabs.length]);
    }

    switchTo(index: number): void {
        const tab = this.tabs[index];
        if (tab) this.activate(tab);
    }

    focusActive(): void {
        this.active?.term.focus();
    }

    private removeTab(tab: Tab): void {
        const idx = this.tabs.indexOf(tab);
        if (idx === -1) return;
        this.tabs.splice(idx, 1);
        tab.term.dispose();
        tab.wrap.remove();
        this.renderStrip();
        if (this.active === tab) {
            this.active = null;
            const next = this.tabs[Math.min(idx, this.tabs.length - 1)];
            if (next) this.activate(next);
            else void this.newSession(); // never leave a dead window
        }
    }

    private renderStrip(): void {
        this.stripEl.innerHTML = "";
        for (const tab of this.tabs) {
            const btn = document.createElement("button");
            btn.className = "tab" + (tab === this.active ? " active" : "");
            btn.style.setProperty("--wails-draggable", "no-drag");
            btn.innerHTML = `<span class="dot"></span><span class="tab-name"></span>`;
            btn.querySelector(".tab-name")!.textContent = tab.name;
            btn.addEventListener("click", () => this.activate(tab));
            this.stripEl.appendChild(btn);
        }
        const plus = document.createElement("button");
        plus.className = "tab tab-new";
        plus.style.setProperty("--wails-draggable", "no-drag");
        plus.textContent = "+";
        plus.title = "New session (⌘T)";
        plus.addEventListener("click", () => void this.newSession());
        this.stripEl.appendChild(plus);
    }
}

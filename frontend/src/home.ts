// The workspace manager — the app's landing screen, per the Rook.dc.html
// home design: workspace cards (persistent, VS Code-style), a resume banner
// when shells are live, scratch workspaces for one-off tasks, and a
// new-workspace modal (name + root directory). Branch/services/attention
// from the design arrive when git/process awareness exists.

import type {CostsSnapshot, HostAPI, UsageSnapshot, WorkspaceInfo} from "./hostapi";
import {shortWindow} from "./hostapi";

export function ago(iso: string): string {
    const ms = Date.now() - new Date(iso).getTime();
    if (ms < 90_000) return "just now";
    const m = Math.floor(ms / 60_000);
    if (m < 60) return `${m}m ago`;
    const h = Math.floor(m / 60);
    if (h < 48) return `${h}h ago`;
    return `${Math.floor(h / 24)}d ago`;
}

export class Home {
    private el: HTMLElement;
    private grid: HTMLElement;
    private banner: HTMLElement;
    private modal: HTMLElement;
    private nameInput: HTMLInputElement;
    private rootInput: HTMLInputElement;
    private workspaces: WorkspaceInfo[] = [];
    private attention = new Map<string, number>();
    private costs: CostsSnapshot | null = null;
    private costTimer: number | null = null;

    constructor(
        private api: HostAPI,
        private onOpen: (name: string) => void,
    ) {
        this.el = document.getElementById("home")!;
        this.grid = this.el.querySelector("#home-grid")!;
        this.banner = this.el.querySelector("#home-resume")!;
        this.modal = document.getElementById("ws-modal")!;
        this.nameInput = this.modal.querySelector("#ws-modal-name")!;
        this.rootInput = this.modal.querySelector("#ws-modal-root")!;

        this.el.querySelector("#home-new")!.addEventListener("click", () => this.openModal());
        this.el.querySelector("#home-scratch")!.addEventListener("click", () => void this.scratch());
        this.modal.addEventListener("mousedown", (e) => {
            if (e.target === this.modal) this.closeModal();
        });
        this.modal.querySelector("#ws-modal-cancel")!.addEventListener("click", () => this.closeModal());
        this.modal.querySelector("#ws-modal-create")!.addEventListener("click", () => void this.createFromModal());
        this.modal.addEventListener("keydown", (e: KeyboardEvent) => {
            if (e.key === "Enter") void this.createFromModal();
            else if (e.key === "Escape") {
                e.stopPropagation();
                this.closeModal();
            }
        });
    }

    get visible(): boolean {
        return !this.el.hidden;
    }

    async show(): Promise<void> {
        this.el.hidden = false;
        // the cost picture refreshes while the manager is on screen — it's
        // the "app wide status" surface, not a per-open snapshot
        void this.refreshCosts();
        if (this.costTimer === null) {
            this.costTimer = window.setInterval(() => void this.refreshCosts(), 30_000);
        }
        await this.refresh();
    }

    hide(): void {
        this.el.hidden = true;
        if (this.costTimer !== null) {
            clearInterval(this.costTimer);
            this.costTimer = null;
        }
        this.closeModal();
    }

    async refresh(): Promise<void> {
        this.workspaces = await this.api.listWorkspaces();
        this.renderBanner();
        this.renderGrid();
    }

    /** Workspace → waiting-session count, from the global /attention poll
     *  (main.ts). Cards get the amber "needs you" tag. */
    setAttention(counts: Map<string, number>): void {
        const same =
            counts.size === this.attention.size &&
            [...counts].every(([k, v]) => this.attention.get(k) === v);
        this.attention = counts;
        if (!same && this.visible) this.renderGrid();
    }

    /** The strip's status line — usage windows + cost picture + per-card
     *  live tags (NOTES: app-wide status on the manager). Zeros render:
     *  "$0.00 today" on a fresh start is information, not absence. */
    private async refreshCosts(): Promise<void> {
        let c: CostsSnapshot;
        try {
            c = await this.api.costs();
        } catch {
            return; // host briefly unreachable — keep the last known line
        }
        let u: UsageSnapshot | null = null;
        try {
            u = await this.api.usage();
        } catch {
            // usage is garnish here — the cost line still renders
        }
        this.costs = c;
        const usageEl = this.el.querySelector<HTMLElement>("#home-usage")!;
        if (u && u.windows.length) {
            usageEl.hidden = false;
            usageEl.textContent = u.windows
                .map((w) => `${shortWindow(w.label)} ${w.pct}%`)
                .join(" · ");
            usageEl.title = u.windows.map((w) => `${w.label}: ${w.pct}% — resets ${w.resets}`).join("\n");
            const worst = Math.max(...u.windows.map((w) => w.pct));
            usageEl.classList.toggle("warn", worst >= 70 && worst < 90);
            usageEl.classList.toggle("hot", worst >= 90);
        } else {
            usageEl.hidden = true; // first probe pending, or API billing
        }
        const el = this.el.querySelector<HTMLElement>("#home-costs")!;
        const parts = [`claude $${c.todayUsd.toFixed(2)} today`, `$${c.weekUsd.toFixed(2)} 7d`];
        if (c.drafterTodayUsd > 0) parts.push(`drafter $${c.drafterTodayUsd.toFixed(2)}`);
        el.textContent = parts.join(" · ");
        el.hidden = false;
        if (this.visible) this.renderGrid();
    }

    /** Surface a failure on the manager instead of a blank screen. */
    showError(msg: string): void {
        let el = this.el.querySelector<HTMLElement>("#home-error");
        if (!el) {
            el = document.createElement("div");
            el.id = "home-error";
            this.grid.parentElement!.insertBefore(el, this.grid);
        }
        el.textContent = msg;
        setTimeout(() => el?.remove(), 6000);
    }

    private renderBanner(): void {
        const live = this.workspaces.filter((w) => w.sessions > 0);
        this.banner.innerHTML = "";
        if (live.length === 0) {
            this.banner.hidden = true;
            return;
        }
        this.banner.hidden = false;
        const total = live.reduce((n, w) => n + w.sessions, 0);
        const target = live[0]; // list is lastUsed-desc
        const text = document.createElement("div");
        text.className = "resume-text";
        text.innerHTML = `<div class="resume-kicker">Resume where you left off</div><div class="resume-body"></div>`;
        text.querySelector(".resume-body")!.textContent =
            `${total} shell${total === 1 ? "" : "s"} still running across ` +
            `${live.length} workspace${live.length === 1 ? "" : "s"} — most recently ${target.name}.`;
        const btn = document.createElement("button");
        btn.className = "resume-btn";
        btn.textContent = "Resume →";
        btn.addEventListener("click", () => this.onOpen(target.name));
        this.banner.append(text, btn);
    }

    private renderGrid(): void {
        this.grid.innerHTML = "";
        for (const ws of this.workspaces) {
            const card = document.createElement("div");
            card.className = "ws-card";
            card.innerHTML = `
              <div class="ws-card-head">
                <span class="ws-card-name"></span>
                <button class="ws-card-del" title="Delete workspace (kills its shells)">✕</button>
                <span class="ws-card-when"></span>
              </div>
              <div class="ws-card-root"></div>
              <div class="ws-card-tags"></div>`;
            card.querySelector(".ws-card-name")!.textContent = ws.name;
            card.querySelector(".ws-card-when")!.textContent = ago(ws.lastUsed || ws.created);
            card.querySelector(".ws-card-root")!.textContent = ws.root || "~";
            const tags = card.querySelector(".ws-card-tags")!;
            const status = document.createElement("span");
            status.className = "ws-tag " + (ws.sessions > 0 ? "live" : "idle");
            status.textContent = ws.sessions > 0 ? `● ${ws.sessions} live` : "idle";
            tags.appendChild(status);
            const attn = this.attention.get(ws.name);
            if (attn) {
                const a = document.createElement("span");
                a.className = "ws-tag attn";
                a.textContent = `◉ ${attn} needs you`;
                tags.appendChild(a);
            }
            const burn = this.costs?.live.find((l) => l.workspace === ws.name)?.usd ?? 0;
            if (burn >= 0.01) {
                const c = document.createElement("span");
                c.className = "ws-tag cost";
                c.textContent = `$${burn.toFixed(2)}`;
                c.title = "live claude sessions here, priced as API tokens";
                tags.appendChild(c);
            }
            if (ws.scratch) {
                const s = document.createElement("span");
                s.className = "ws-tag scratch";
                s.textContent = "scratch";
                tags.appendChild(s);
            }
            card.addEventListener("click", () => this.onOpen(ws.name));
            card.querySelector(".ws-card-del")!.addEventListener("click", async (e) => {
                e.stopPropagation();
                await this.api.deleteWorkspace(ws.name);
                await this.refresh();
            });
            this.grid.appendChild(card);
        }
        if (this.workspaces.length === 0) {
            const empty = document.createElement("div");
            empty.className = "home-empty";
            empty.textContent = "No workspaces yet — create one, or grab a scratch shell.";
            this.grid.appendChild(empty);
        }
    }

    /** One-off task: auto-named ephemeral workspace, straight into a shell.
     *  The host discards it when its last session exits. */
    async scratch(): Promise<void> {
        const taken = new Set(this.workspaces.map((w) => w.name));
        let n = 1;
        while (taken.has(`scratch-${n}`)) n++;
        const name = `scratch-${n}`;
        await this.api.createWorkspace(name, "", true);
        this.onOpen(name);
    }

    openModal(): void {
        this.modal.hidden = false;
        this.nameInput.value = "";
        this.rootInput.value = "";
        this.nameInput.focus();
    }

    closeModal(): void {
        this.modal.hidden = true;
    }

    private async createFromModal(): Promise<void> {
        const name = this.nameInput.value.trim();
        if (!name) {
            this.nameInput.focus();
            return;
        }
        await this.api.createWorkspace(name, this.rootInput.value.trim(), false);
        this.closeModal();
        this.onOpen(name);
    }
}

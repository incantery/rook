// The workspace dashboard — window 0 of every workspace. First slice of
// the design's overview surface: what's running in each window, where, on
// which branch. It renders exactly what GET /workspaces/{name}/status
// reports, which is the same context the attention router (docs/agent.md)
// will consume — if the dashboard can't show it, the agent can't know it.

import type {AgentStatus, AttentionItem, HostAPI, WorkspaceStatus} from "./hostapi";
import type {Tabs} from "./tabs";
import {ago} from "./home";

/** One line of agent state on a window card: what claude is doing, and —
 *  at needs_input — what it's asking. */
function agentLine(a: AgentStatus): HTMLElement {
    const el = document.createElement("div");
    el.className = "dash-agent " + a.state;
    const label =
        a.state === "needs_input"
            ? "◉ needs you"
            : a.state === "quiet"
              ? `◌ quiet${a.tool ? " — " + a.tool : ""}`
              : `● working${a.tool ? " — " + a.tool : ""}`;
    const chip = document.createElement("span");
    chip.className = "dash-agent-chip";
    chip.textContent = label + (a.costUsd ? ` · $${a.costUsd.toFixed(2)}` : "");
    el.appendChild(chip);
    const text = a.state === "needs_input" ? a.ask || a.title : a.title;
    if (text) {
        const t = document.createElement("div");
        t.className = "dash-agent-text";
        t.textContent = text;
        t.title = text;
        el.appendChild(t);
    }
    return el;
}

function tilde(p: string): string {
    return p.replace(/^\/Users\/[^/]+/, "~");
}

/** Middle-ellipsis long paths: the tail is the informative end. */
function squeeze(p: string, max = 46): string {
    return p.length <= max ? p : p.slice(0, 14) + "…" + p.slice(-(max - 15));
}

export class Dashboard {
    private el: HTMLElement;
    private timer: number | null = null;
    private attention: AttentionItem[] = [];

    onJump: (index: number) => void = () => {};

    /** Latest /attention items (main.ts's global poll) — cards flag when
     *  the drafter has a reply waiting in the inbox. */
    setAttention(items: AttentionItem[]): void {
        this.attention = items;
    }

    constructor(
        private api: HostAPI,
        private tabs: Tabs,
        run: (cmd: string) => void,
    ) {
        this.el = document.getElementById("dashboard")!;
        this.el.querySelectorAll<HTMLElement>("[data-cmd]").forEach((btn) => {
            btn.addEventListener("click", () => run(btn.dataset.cmd!));
        });
    }

    get visible(): boolean {
        return !this.el.hidden;
    }

    show(): void {
        this.el.hidden = false;
        this.tabs.setDashboardActive(true);
        void this.refresh();
        // fg process / cwd / git all drift while you watch — poll cheaply
        this.timer = window.setInterval(() => void this.refresh(), 3000);
    }

    hide(): void {
        if (this.el.hidden) return;
        this.el.hidden = true;
        this.tabs.setDashboardActive(false);
        if (this.timer !== null) {
            clearInterval(this.timer);
            this.timer = null;
        }
    }

    toggle(): void {
        if (this.visible) {
            this.hide();
            this.tabs.focusActive();
        } else {
            this.show();
        }
    }

    private async refresh(): Promise<void> {
        let st: WorkspaceStatus;
        try {
            st = await this.api.workspaceStatus(this.tabs.workspace);
        } catch (err) {
            console.error("dashboard refresh failed", err);
            return;
        }
        if (this.el.hidden) return; // hidden while the fetch was in flight
        this.render(st);
    }

    private render(st: WorkspaceStatus): void {
        this.el.querySelector(".dash-name")!.textContent = st.name;
        this.el.querySelector(".dash-root")!.textContent = st.root
            ? tilde(st.root)
            : "no root — cd somewhere, then ` .";

        const pills = this.el.querySelector(".dash-pills")!;
        pills.innerHTML = "";
        const pill = (text: string, cls: string) => {
            const s = document.createElement("span");
            s.className = "dash-pill " + cls;
            s.textContent = text;
            pills.appendChild(s);
        };
        if (st.git) {
            pill(`⎇ ${st.git.branch}`, "branch");
            if (st.git.dirty > 0) pill(`● ${st.git.dirty} modified`, "dirty");
            else pill("✓ clean", "clean");
            if (st.git.ahead > 0) pill(`↑${st.git.ahead}`, "sync");
            if (st.git.behind > 0) pill(`↓${st.git.behind}`, "sync");
        }

        const grid = this.el.querySelector("#dash-grid")!;
        grid.innerHTML = "";
        st.sessions.forEach((s, i) => {
            const card = document.createElement("div");
            card.className = "dash-card";
            card.innerHTML = `
              <div class="dash-card-top">
                <span class="dash-num"></span>
                <span class="dash-fg"></span>
                <span class="dash-spacer"></span>
                <span class="dash-when"></span>
              </div>
              <div class="dash-cwd"></div>`;
            card.querySelector(".dash-num")!.textContent = String(this.tabs.dashTab + 1 + i);
            const fg = card.querySelector(".dash-fg")!;
            fg.textContent = s.fg || "?";
            // agent sessions get the accent — the attention router's
            // targets, visible at a glance
            if (s.fg === "claude") fg.classList.add("agent");
            card.querySelector(".dash-when")!.textContent = ago(s.created);
            const cwd = card.querySelector<HTMLElement>(".dash-cwd")!;
            cwd.textContent = squeeze(tilde(s.cwd || "")) || "—";
            cwd.title = s.cwd;
            if (s.agent) card.appendChild(agentLine(s.agent));
            const draft = this.attention.find(
                (a) => a.rookSession === s.id && a.draft?.action === "draft",
            );
            if (draft) {
                const d = document.createElement("div");
                d.className = "dash-draft";
                d.textContent = "↳ draft ready — ` a";
                d.title = draft.draft!.reply ?? "";
                card.appendChild(d);
            }
            card.addEventListener("click", () => this.onJump(i));
            grid.appendChild(card);
        });
        if (st.sessions.length === 0) {
            const empty = document.createElement("div");
            empty.className = "home-empty";
            empty.textContent = "No windows — ` c opens one.";
            grid.appendChild(empty);
        }
    }
}

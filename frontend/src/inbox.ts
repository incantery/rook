// The attention inbox (` a): every claude session waiting on you, across
// workspaces, in one overlay — with the drafter's proposed replies once
// rook-agent is running (docs/agent.md). Same overlay pattern as the
// palette; rows are keyed (sessionId, askSeq) so a poll refresh never
// steals the selection, and a snooze dies with its ask.

import type {AttentionItem, HostAPI} from "./hostapi";
import {ago} from "./home";

// Keyed on the transcript session, not the window: a new claude process in
// the same window is a new identity (askSeq restarts with it).
const key = (it: AttentionItem) => `${it.agentSession}:${it.askSeq}`;

export class Inbox {
    private overlay: HTMLElement;
    private listEl: HTMLElement;
    private items: AttentionItem[] = [];
    private selKey: string | null = null;
    private snoozed = new Set<string>();
    private editingKey: string | null = null;
    private timer: number | null = null;

    /** Where the dashboard sits in the strip — window N displays as
     *  dashTab+1+index, same math as tabs.ts. */
    dashTab = 1;

    constructor(
        private api: HostAPI,
        private onJump: (sessionId: string) => void,
        private onClose: () => void,
    ) {
        this.overlay = document.createElement("div");
        this.overlay.id = "inbox";
        this.overlay.className = "overlay";
        this.overlay.hidden = true;
        this.overlay.innerHTML = `
          <div class="pal-panel">
            <div class="pal-inputrow">
              <span class="inbox-title">Attention</span>
              <span class="pal-spacer"></span>
              <span class="pal-esc">esc</span>
            </div>
            <div class="pal-list inbox-list"></div>
            <div class="pal-footer">
              <span>↑↓ / j k navigate</span><span>↵ approve / jump</span><span>o open</span>
              <span>e edit</span><span>x dismiss</span>
              <span class="pal-spacer"></span>
              <span>drafts are suggestions — you send them</span>
            </div>
          </div>`;
        document.body.appendChild(this.overlay);
        this.listEl = this.overlay.querySelector(".inbox-list")!;
        this.overlay.addEventListener("mousedown", (e) => {
            if (e.target === this.overlay) this.close();
        });
        // Capture-phase so the terminal (and main.ts's ladder) never see
        // keys while the inbox is up; main.ts also bails on inbox.visible.
        window.addEventListener("keydown", (e) => this.onKey(e), {capture: true});
    }

    get visible(): boolean {
        return !this.overlay.hidden;
    }

    open(): void {
        this.overlay.hidden = false;
        this.editingKey = null;
        void this.refresh();
        this.timer = window.setInterval(() => void this.refresh(), 2000);
    }

    close(): void {
        if (this.overlay.hidden) return;
        this.overlay.hidden = true;
        this.editingKey = null;
        if (this.timer !== null) {
            clearInterval(this.timer);
            this.timer = null;
        }
        this.onClose();
    }

    toggle(): void {
        this.visible ? this.close() : this.open();
    }

    private async refresh(): Promise<void> {
        let items: AttentionItem[];
        try {
            items = await this.api.attention();
        } catch (err) {
            console.error("inbox refresh failed", err);
            return;
        }
        if (!this.visible) return;
        this.items = items.filter((it) => !this.snoozed.has(key(it)));
        // snoozes for asks that no longer exist can be forgotten
        const live = new Set(items.map(key));
        for (const k of this.snoozed) if (!live.has(k)) this.snoozed.delete(k);
        if (this.editingKey && !this.items.some((it) => key(it) === this.editingKey)) {
            this.editingKey = null; // the ask moved on under the editor
        }
        this.render();
    }

    private get selIndex(): number {
        const i = this.items.findIndex((it) => key(it) === this.selKey);
        return i === -1 ? (this.items.length ? 0 : -1) : i;
    }

    private selected(): AttentionItem | undefined {
        return this.items[this.selIndex];
    }

    private onKey(e: KeyboardEvent): void {
        if (!this.visible) return;
        // Edit mode: the textarea owns typing; we only intercept its exits.
        if (this.editingKey) {
            if (e.key === "Escape") {
                e.preventDefault();
                e.stopPropagation();
                this.editingKey = null;
                this.render();
            } else if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                e.stopPropagation();
                const it = this.selected();
                const ta = this.listEl.querySelector<HTMLTextAreaElement>(".inbox-edit");
                if (it?.draft && ta) void this.decide(it, "approve", ta.value.trim());
            }
            return;
        }
        e.preventDefault();
        e.stopPropagation();
        const it = this.selected();
        switch (e.key) {
            case "Escape":
                this.close();
                break;
            case "ArrowDown":
            case "j": // no filter input here, so bare vim motions work
                this.move(1);
                break;
            case "ArrowUp":
            case "k":
                this.move(-1);
                break;
            case "o":
                if (it) this.jump(it);
                break;
            case "Enter":
                if (!it) break;
                if (it.draft?.action === "draft" || it.draft?.action === "spawn") void this.decide(it, "approve");
                else this.jump(it);
                break;
            case "e":
                if (it?.draft?.action === "draft" || it?.draft?.action === "spawn") {
                    this.editingKey = key(it);
                    this.render();
                }
                break;
            case "x":
                if (!it) break;
                if (it.draft) void this.decide(it, "reject");
                else {
                    this.snoozed.add(key(it));
                    this.items = this.items.filter((o) => o !== it);
                    this.render();
                }
                break;
        }
    }

    private move(d: number): void {
        if (this.items.length === 0) return;
        const i = Math.min(Math.max(this.selIndex + d, 0), this.items.length - 1);
        this.selKey = key(this.items[i]);
        this.render();
    }

    private jump(it: AttentionItem): void {
        this.close();
        this.onJump(it.rookSession);
    }

    private async decide(it: AttentionItem, action: "approve" | "reject", text?: string): Promise<void> {
        if (!it.draft) return;
        this.editingKey = null;
        try {
            if (action === "approve") await this.api.approveDraft(it.draft.id, text);
            else await this.api.rejectDraft(it.draft.id);
        } catch (err) {
            console.error(`${action} draft failed`, err);
        }
        // approved: claude is working again, the row leaves on its own;
        // rejected: the ask still stands, draft-less — either way, refetch
        await this.refresh();
    }

    private render(): void {
        this.listEl.innerHTML = "";
        if (this.items.length === 0) {
            const empty = document.createElement("div");
            empty.className = "inbox-empty";
            empty.textContent = "Nobody needs you.";
            this.listEl.appendChild(empty);
            return;
        }
        const sel = this.selIndex;
        this.items.forEach((it, i) => {
            const row = document.createElement("div");
            row.className = "pal-item inbox-row" + (i === sel ? " sel" : "");
            const head = document.createElement("div");
            head.className = "inbox-head";
            const chip = document.createElement("span");
            chip.className = "inbox-chip";
            chip.textContent = `${it.workspace} · window ${this.dashTab + 1 + it.window}`;
            const age = document.createElement("span");
            age.className = "inbox-age";
            age.textContent = ago(it.since);
            head.append(chip, age);
            row.appendChild(head);
            if (it.ask) {
                const ask = document.createElement("div");
                ask.className = "inbox-ask";
                ask.textContent = it.ask.replace(/\n/g, " ");
                ask.title = it.ask;
                row.appendChild(ask);
            }
            row.appendChild(this.draftSlot(it));
            row.addEventListener("mousedown", (e) => {
                e.preventDefault();
                if (this.editingKey) return;
                this.selKey = key(it);
                this.jump(it);
            });
            this.listEl.appendChild(row);
        });
        this.listEl.querySelector(".sel")?.scrollIntoView({block: "nearest"});
        const ta = this.listEl.querySelector<HTMLTextAreaElement>(".inbox-edit");
        if (ta) {
            ta.focus();
            ta.setSelectionRange(ta.value.length, ta.value.length);
        }
    }

    /** The draft area of a row: proposal, escalation badge, or editor. */
    private draftSlot(it: AttentionItem): HTMLElement {
        const slot = document.createElement("div");
        slot.className = "inbox-draft";
        if (this.editingKey === key(it) && (it.draft?.action === "draft" || it.draft?.action === "spawn")) {
            const ta = document.createElement("textarea");
            ta.className = "inbox-edit";
            ta.value = it.draft.reply ?? "";
            ta.rows = 2;
            ta.spellcheck = false;
            slot.appendChild(ta);
            const hint = document.createElement("div");
            hint.className = "inbox-edit-hint";
            hint.textContent = "↵ send edited · esc cancel";
            slot.appendChild(hint);
            return slot;
        }
        if (it.interactive) {
            slot.classList.add("escalate");
            slot.textContent = "⌨ pick an option in the window — ↵ jumps";
            return slot;
        }
        if (it.draft?.action === "draft" || it.draft?.action === "spawn") {
            slot.classList.add("ready");
            const pct = it.draft.confidence ? ` ${Math.round(it.draft.confidence * 100)}%` : "";
            const mark = it.draft.action === "spawn" ? "▶ new session:" : "✎";
            slot.textContent = `${mark} ${it.draft.reply ?? ""}`;
            slot.title = `${it.draft.action}${pct} — ↵ approve, e edit, x reject`;
        } else if (it.draft?.action === "escalate") {
            slot.classList.add("escalate");
            slot.textContent = "⚑ yours to answer";
        } else {
            slot.classList.add("pending");
            slot.textContent = "";
        }
        return slot;
    }
}

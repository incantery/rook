// Workspace switcher (` s) — tmux choose-session. Lists workspaces with
// window counts; typing filters, and a name that matches nothing offers
// "create workspace" (tmux new-session). Reuses the palette's styling.

import type {Tabs} from "./tabs";

interface Item {
    label: string;
    detail: string;
    create: boolean;
}

export class WorkspacePicker {
    private overlay: HTMLElement;
    private input: HTMLInputElement;
    private listEl: HTMLElement;
    private sel = 0;
    private items: Item[] = [];

    constructor(
        private tabs: Tabs,
        private onPick: (name: string) => void,
        private onManager: () => void,
        private onClose: () => void,
    ) {
        this.overlay = document.createElement("div");
        this.overlay.id = "ws-picker";
        this.overlay.className = "overlay";
        this.overlay.hidden = true;
        this.overlay.innerHTML = `
          <div class="pal-panel">
            <div class="pal-inputrow">
              <span class="pal-chevron">›</span>
              <input class="pal-input" placeholder="Switch workspace — or type a new name…" spellcheck="false" />
              <span class="pal-esc">esc</span>
            </div>
            <div class="pal-list"></div>
            <div class="pal-footer">
              <button class="home-btn pal-manager-btn">workspace manager</button>
              <span>↑↓ / ^j ^k navigate</span><span>↵ switch / create</span>
              <span class="pal-spacer"></span>
              <span>workspace = tmux session</span>
            </div>
          </div>`;
        document.body.appendChild(this.overlay);
        this.input = this.overlay.querySelector(".pal-input")!;
        this.listEl = this.overlay.querySelector(".pal-list")!;

        this.overlay.addEventListener("mousedown", (e) => {
            if (e.target === this.overlay) this.close();
        });
        this.overlay.querySelector(".pal-manager-btn")!.addEventListener("click", () => {
            this.close();
            this.onManager();
        });
        this.input.addEventListener("input", () => {
            this.sel = 0;
            this.render();
        });
        this.input.addEventListener("keydown", (e) => {
            // vim/fzf motions — bare j/k must keep typing into the filter
            const down = e.key === "ArrowDown" || (e.ctrlKey && (e.key === "j" || e.key === "n"));
            const up = e.key === "ArrowUp" || (e.ctrlKey && (e.key === "k" || e.key === "p"));
            if (down) {
                e.preventDefault();
                this.sel = Math.min(this.sel + 1, this.items.length - 1);
                this.render();
            } else if (up) {
                e.preventDefault();
                this.sel = Math.max(this.sel - 1, 0);
                this.render();
            } else if (e.key === "Enter") {
                e.preventDefault();
                this.pick(this.items[this.sel]);
            } else if (e.key === "Escape") {
                e.preventDefault();
                e.stopPropagation();
                this.close();
            }
        });
    }

    get visible(): boolean {
        return !this.overlay.hidden;
    }

    open(): void {
        this.overlay.hidden = false;
        this.input.value = "";
        // Empty query means items mirror workspaces() order, so the active
        // workspace's index is valid here.
        this.sel = Math.max(
            0,
            this.tabs.workspaces().findIndex((w) => w.name === this.tabs.workspace),
        );
        this.render();
        this.input.focus();
    }

    close(): void {
        if (this.overlay.hidden) return;
        this.overlay.hidden = true;
        this.onClose();
    }

    private pick(item: Item | undefined): void {
        if (!item) return;
        this.close();
        this.onPick(item.label); // create and switch are the same door
    }

    private render(): void {
        const q = this.input.value.trim();
        const ql = q.toLowerCase();
        const existing = this.tabs.workspaces();
        this.items = existing
            .filter((w) => !ql || w.name.toLowerCase().includes(ql))
            .map((w) => ({
                label: w.name,
                detail:
                    `${w.count} window${w.count === 1 ? "" : "s"}` +
                    (w.name === this.tabs.workspace ? " · current" : ""),
                create: false,
            }));
        if (q && !existing.some((w) => w.name.toLowerCase() === ql)) {
            this.items.push({label: q, detail: "create workspace", create: true});
        }
        this.listEl.innerHTML = "";
        this.items.forEach((item, i) => {
            const row = document.createElement("div");
            row.className = "pal-item" + (i === this.sel ? " sel" : "");
            row.innerHTML = `<span class="pal-title"></span><span class="pal-cat"></span>`;
            row.querySelector(".pal-title")!.textContent = (item.create ? "＋ " : "") + item.label;
            row.querySelector(".pal-cat")!.textContent = item.detail;
            row.addEventListener("mousedown", (e) => {
                e.preventDefault();
                this.pick(item);
            });
            this.listEl.appendChild(row);
        });
        this.listEl.querySelector(".sel")?.scrollIntoView({block: "nearest"});
    }
}

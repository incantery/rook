// Command palette (⌘K), per the Rook.dc.html design: overlay, fuzzy-ish
// filter, arrow navigation, enter to run. Purely a view over the Registry.

import type {Command, Registry} from "./registry";

export class Palette {
    private overlay: HTMLElement;
    private input: HTMLInputElement;
    private listEl: HTMLElement;
    private sel = 0;
    private current: Command[] = [];

    constructor(
        private registry: Registry,
        private onClose: () => void,
    ) {
        this.overlay = document.createElement("div");
        this.overlay.id = "palette";
        this.overlay.className = "overlay";
        this.overlay.hidden = true;
        this.overlay.innerHTML = `
          <div class="pal-panel">
            <div class="pal-inputrow">
              <span class="pal-chevron">›</span>
              <input class="pal-input" placeholder="Run a command…" spellcheck="false" />
              <span class="pal-esc">esc</span>
            </div>
            <div class="pal-list"></div>
            <div class="pal-footer">
              <span>↑↓ navigate</span><span>↵ run</span>
              <span class="pal-spacer"></span>
              <span>humans + agents share this registry</span>
            </div>
          </div>`;
        document.body.appendChild(this.overlay);
        this.input = this.overlay.querySelector(".pal-input")!;
        this.listEl = this.overlay.querySelector(".pal-list")!;

        this.overlay.addEventListener("mousedown", (e) => {
            if (e.target === this.overlay) this.close();
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
                this.sel = Math.min(this.sel + 1, this.current.length - 1);
                this.render();
            } else if (up) {
                e.preventDefault();
                this.sel = Math.max(this.sel - 1, 0);
                this.render();
            } else if (e.key === "Enter") {
                e.preventDefault();
                const cmd = this.current[this.sel];
                if (cmd) {
                    this.close();
                    this.registry.run(cmd.id);
                }
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
        this.sel = 0;
        this.render();
        this.input.focus();
    }

    close(): void {
        if (this.overlay.hidden) return;
        this.overlay.hidden = true;
        this.onClose();
    }

    toggle(): void {
        this.visible ? this.close() : this.open();
    }

    private render(): void {
        const q = this.input.value.trim().toLowerCase();
        this.current = this.registry
            .all()
            .filter((c) => !q || c.title.toLowerCase().includes(q) || c.category.toLowerCase().includes(q));
        this.listEl.innerHTML = "";
        this.current.forEach((cmd, i) => {
            const row = document.createElement("div");
            row.className = "pal-item" + (i === this.sel ? " sel" : "");
            row.innerHTML = `
              <span class="pal-title"></span>
              <span class="pal-cat"></span>
              <span class="pal-keys"></span>`;
            row.querySelector(".pal-title")!.textContent = cmd.title;
            row.querySelector(".pal-cat")!.textContent = cmd.category;
            row.querySelector(".pal-keys")!.textContent = cmd.keys ?? "";
            row.addEventListener("mousedown", (e) => {
                e.preventDefault();
                this.close();
                this.registry.run(cmd.id);
            });
            this.listEl.appendChild(row);
        });
        this.listEl.querySelector(".sel")?.scrollIntoView({block: "nearest"});
    }
}

// The spawn modal (` n / palette "New agent session"): type a task, get a
// window with claude already working on it. This is the user-invoked rung
// of the spawner ladder (docs/agent.md step 4) — zero LLM; nano earns
// routing and unsolicited proposals later, through the same actuator.

/** Single-quote for a POSIX shell; newlines flatten to spaces because the
 *  command is typed into a live terminal, where \n would submit early. */
export function shellQuote(s: string): string {
    return "'" + s.replace(/\s*\n\s*/g, " ").replace(/'/g, "'\\''") + "'";
}

export class SpawnModal {
    private overlay: HTMLElement;
    private task: HTMLTextAreaElement;
    private ws: HTMLInputElement;
    private error: HTMLElement;

    constructor(
        private currentWorkspace: () => string,
        private onSpawn: (task: string, workspace: string) => Promise<void>,
        private onClose: () => void,
    ) {
        this.overlay = document.createElement("div");
        this.overlay.id = "spawn-modal";
        this.overlay.className = "overlay";
        this.overlay.hidden = true;
        this.overlay.innerHTML = `
          <div class="pal-panel">
            <div class="ws-modal-title">New agent session</div>
            <div class="ws-form">
              <label><span>Task — becomes <code>claude "…"</code> in a fresh window</span>
                <textarea class="spawn-task" rows="3" spellcheck="false"
                  placeholder="fix the flaky picker test and run the suite"></textarea></label>
              <label><span>Workspace</span><input class="spawn-ws" spellcheck="false" /></label>
              <div class="key-error" hidden></div>
            </div>
            <div class="ws-modal-foot">
              <button class="home-btn spawn-cancel">Cancel</button>
              <button class="home-btn primary spawn-go">Start session</button>
            </div>
          </div>`;
        document.body.appendChild(this.overlay);
        this.task = this.overlay.querySelector(".spawn-task")!;
        this.ws = this.overlay.querySelector(".spawn-ws")!;
        this.error = this.overlay.querySelector(".key-error")!;

        this.overlay.addEventListener("mousedown", (e) => {
            if (e.target === this.overlay) this.close();
        });
        this.overlay.querySelector(".spawn-cancel")!.addEventListener("click", () => this.close());
        this.overlay.querySelector(".spawn-go")!.addEventListener("click", () => void this.go());
        this.overlay.addEventListener("keydown", (e: KeyboardEvent) => {
            if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                void this.go();
            } else if (e.key === "Escape") this.close();
            e.stopPropagation();
        });
    }

    get visible(): boolean {
        return !this.overlay.hidden;
    }

    open(): void {
        this.overlay.hidden = false;
        this.task.value = "";
        this.ws.value = this.currentWorkspace();
        this.error.hidden = true;
        this.task.focus();
    }

    close(): void {
        if (this.overlay.hidden) return;
        this.overlay.hidden = true;
        this.onClose();
    }

    private async go(): Promise<void> {
        const task = this.task.value.trim();
        if (!task) {
            this.task.focus();
            return;
        }
        const ws = this.ws.value.trim() || this.currentWorkspace();
        try {
            await this.onSpawn(task, ws);
            this.close();
        } catch (err) {
            this.error.textContent = `spawn failed: ${err}`;
            this.error.hidden = false;
        }
    }
}

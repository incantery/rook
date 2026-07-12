// The OpenAI-key modal (palette → "Set OpenAI API key"): the one setting
// the app writes, and it goes to the login keychain, never to the config
// file — that stays user-owned. Calls config.Service by FQN, same
// no-generated-bindings pattern as notifications.

import {Call} from "@wailsio/runtime";

const SVC = "github.com/incantery/rook/internal/config.Service.";

export class KeyModal {
    private overlay: HTMLElement;
    private input: HTMLInputElement;
    private status: HTMLElement;
    private error: HTMLElement;

    constructor(private onClose: () => void) {
        this.overlay = document.createElement("div");
        this.overlay.id = "key-modal";
        this.overlay.className = "overlay";
        this.overlay.hidden = true;
        this.overlay.innerHTML = `
          <div class="pal-panel">
            <div class="ws-modal-title">OpenAI API key — the drafter's credential</div>
            <div class="ws-form">
              <div class="key-status"></div>
              <label><span>Stored in the macOS login keychain (service “rook”), not in a file</span>
                <input type="password" placeholder="sk-…" spellcheck="false" autocomplete="off" /></label>
              <div class="key-error" hidden></div>
            </div>
            <div class="ws-modal-foot">
              <button class="home-btn key-clear">Remove key</button>
              <span class="home-spacer"></span>
              <button class="home-btn key-cancel">Cancel</button>
              <button class="home-btn primary key-save">Save to keychain</button>
            </div>
          </div>`;
        document.body.appendChild(this.overlay);
        this.input = this.overlay.querySelector("input")!;
        this.status = this.overlay.querySelector(".key-status")!;
        this.error = this.overlay.querySelector(".key-error")!;

        this.overlay.addEventListener("mousedown", (e) => {
            if (e.target === this.overlay) this.close();
        });
        this.overlay.querySelector(".key-cancel")!.addEventListener("click", () => this.close());
        this.overlay.querySelector(".key-save")!.addEventListener("click", () => void this.save());
        this.overlay.querySelector(".key-clear")!.addEventListener("click", () => void this.clear());
        this.overlay.addEventListener("keydown", (e: KeyboardEvent) => {
            if (e.key === "Enter") void this.save();
            else if (e.key === "Escape") this.close();
            e.stopPropagation();
        });
    }

    get visible(): boolean {
        return !this.overlay.hidden;
    }

    open(): void {
        this.overlay.hidden = false;
        this.input.value = "";
        this.showError("");
        this.status.textContent = "checking…";
        void Call.ByName(SVC + "OpenAIKeyStatus").then(
            (s: string) => {
                this.status.textContent =
                    s === "keychain"
                        ? "✓ a key is stored in the keychain — saving replaces it"
                        : s === "file"
                          ? "a key file exists (~/.config/rook/openai-key) — the keychain takes precedence once set"
                          : "no key configured — the agent idles until one exists (and agent = on in the config)";
                this.status.className = "key-status" + (s ? " ok" : "");
            },
            () => (this.status.textContent = ""),
        );
        this.input.focus();
    }

    close(): void {
        if (this.overlay.hidden) return;
        this.overlay.hidden = true;
        this.onClose();
    }

    private showError(msg: string): void {
        this.error.textContent = msg;
        this.error.hidden = !msg;
    }

    private async save(): Promise<void> {
        const key = this.input.value.trim();
        if (!key) {
            this.input.focus();
            return;
        }
        try {
            await Call.ByName(SVC + "SetOpenAIKey", key);
            this.close();
        } catch (err) {
            this.showError(`keychain write failed: ${err}`);
        }
    }

    private async clear(): Promise<void> {
        try {
            await Call.ByName(SVC + "ClearOpenAIKey");
            this.close();
        } catch (err) {
            this.showError(`keychain delete failed: ${err}`);
        }
    }
}

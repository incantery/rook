// RookVimStatusBar — rook's own monaco-vim status bar. initVimMode accepts a
// custom StatusBar class; this one renders the surface rook wants instead of
// the library default:
//
//   - the mode as a COLORED badge (data-mode drives the tint from the theme
//     vars — normal accent, insert green, visual magenta, replace red)
//   - the `:` / `/` prompt in a centered MODAL over the editor, not inline —
//     a command line you look at, not a strip you squint at (the scrim stays
//     light so incremental search is visible behind it)
//   - vim's messages (":set wrap?" answers, E486…) inline in the bar
//   - the pending key buffer ("d2…") right-aligned
//
// The class implements the whole call surface monaco-vim uses (index.ts +
// cm_adapter openDialog/openNotification) rather than subclassing the shipped
// StatusBar — the base keeps its nodes TS-private, and the contract is small.
// All DOM here is imperative island territory: classes styled in app.css.

interface InputOptions {
    selectValueOnOpen?: boolean;
    value?: string;
    onKeyUp?: (e: KeyboardEvent, value: string, close: () => void) => void;
    onKeyDown?: (e: KeyboardEvent, value: string, close: () => void) => boolean | void;
    onKeyInput?: (e: InputEvent, value: string, close: () => void) => void;
    onBlur?: (e: FocusEvent, close: () => void) => void;
    closeOnBlur?: boolean;
    closeOnEnter?: boolean;
}

interface ActiveInput {
    callback?: (value: string) => void;
    options?: InputOptions;
    node: HTMLInputElement;
}

/** a minimal editor shape — enough to hand focus back on close */
interface FocusableEditor {
    focus(): void;
}

// ---- the command-line modal: ONE for the whole app. There is one keyboard,
// so there is never more than one open prompt; every status bar instance
// shares this element and stamps its own close handler while it holds it. ----
let modalEl: HTMLDivElement | null = null;
let panelEl: HTMLDivElement | null = null;
let scrimClose: (() => void) | null = null;

function openModal(content: Node | string, close: () => void): HTMLInputElement | null {
    if (!modalEl || !panelEl) {
        modalEl = document.createElement("div");
        modalEl.className = "vim-cmdline";
        panelEl = document.createElement("div");
        panelEl.className = "vim-cmdline-panel";
        modalEl.appendChild(panelEl);
        // clicking the scrim cancels, like Esc — mousedown so the editor
        // never sees a stray click-through on the way out
        modalEl.addEventListener("mousedown", (e) => {
            if (e.target === modalEl) scrimClose?.();
        });
        document.body.appendChild(modalEl);
    }
    scrimClose = close;
    if (typeof content === "string") panelEl.replaceChildren(document.createTextNode(content));
    else panelEl.replaceChildren(content);
    // the prompt's prefix (":", "/", "?") arrives as a bare text node before
    // the input — wrap it so the accent can land on it alone
    const wrap = panelEl.querySelector("span");
    if (wrap?.firstChild?.nodeType === Node.TEXT_NODE) {
        const prefix = document.createElement("span");
        prefix.className = "vim-prefix";
        wrap.insertBefore(prefix, wrap.firstChild);
        prefix.appendChild(prefix.nextSibling as Node);
    }
    modalEl.style.display = "flex";
    return panelEl.querySelector("input");
}

function closeModal(): void {
    if (!modalEl || !panelEl) return;
    modalEl.style.display = "none";
    panelEl.replaceChildren();
    scrimClose = null;
}

export class RookVimStatusBar {
    private readonly node: HTMLElement;
    private readonly modeNode: HTMLSpanElement;
    private readonly notifNode: HTMLSpanElement;
    private readonly keyNode: HTMLSpanElement;
    private readonly editor: FocusableEditor | null;
    private input: ActiveInput | null = null;
    private notifTimeout: ReturnType<typeof setTimeout> | undefined;

    constructor(node: HTMLElement, editor: FocusableEditor | null) {
        this.node = node;
        this.editor = editor;
        this.modeNode = document.createElement("span");
        this.modeNode.className = "vim-mode";
        this.notifNode = document.createElement("span");
        this.notifNode.className = "vim-notif";
        this.keyNode = document.createElement("span");
        this.keyNode.className = "vim-keys";
        this.node.replaceChildren(this.modeNode, this.notifNode, this.keyNode);
        this.toggleVisibility(false);
    }

    setMode(ev: {mode: string; subMode?: string}): void {
        let label = ev.mode.toUpperCase();
        if (ev.mode === "visual") {
            label =
                ev.subMode === "linewise"
                    ? "V-LINE"
                    : ev.subMode === "blockwise"
                      ? "V-BLOCK"
                      : "VISUAL";
        }
        this.modeNode.textContent = label;
        this.modeNode.dataset.mode = ev.mode;
    }

    /** the base class routes plain text through here too — keep the surface */
    setText(text: string): void {
        this.modeNode.textContent = text;
    }

    setKeyBuffer(key: string): void {
        this.keyNode.textContent = key;
    }

    /** vim's dialog seam: `:`/`/`/`?` prompts arrive as a fragment holding
     *  the prefix and an <input>. It opens the modal; "" closes it (that is
     *  how the library's own closeInput signals teardown). */
    setSec(
        text: Node | string | null | undefined,
        callback?: (value: string) => void,
        options?: InputOptions,
    ): (() => void) | undefined {
        this.notifNode.textContent = "";
        if (text === undefined) return this.closeInput;
        if (!text) {
            // setSec("") — the close half of the contract
            this.removeInputListeners();
            this.input = null;
            closeModal();
            return this.closeInput;
        }

        const input = openModal(text, this.closeInput);
        if (input) {
            input.focus();
            this.input = {callback, options, node: input};
            if (options?.value) input.value = options.value;
            if (options?.selectValueOnOpen) input.select();
            this.addInputListeners();
        }
        return this.closeInput;
    }

    toggleVisibility(toggle: boolean): void {
        // flex, not the library's block — the bar is a status-bar segment
        this.node.style.display = toggle ? "flex" : "none";
        if (!toggle && this.input) this.closeInput();
        if (this.notifTimeout) clearTimeout(this.notifTimeout);
    }

    closeInput = (): void => {
        this.removeInputListeners();
        this.input = null;
        closeModal();
        this.editor?.focus();
    };

    clear = (): void => {
        this.node.replaceChildren();
    };

    showNotification(text: string | Node): void {
        // vim sends errors as a red-styled <pre> (showConfirm); read the tone
        // off the node so E486 lands red and ":set wrap?" answers stay calm
        const err = text instanceof HTMLElement && text.style.color === "red";
        this.notifNode.textContent = typeof text === "string" ? text : (text.textContent ?? "");
        this.notifNode.classList.toggle("err", err);
        if (this.notifTimeout) clearTimeout(this.notifTimeout);
        this.notifTimeout = setTimeout(() => {
            this.notifNode.textContent = "";
        }, 5000);
    }

    private inputKeyDown = (e: KeyboardEvent): void => {
        if (!this.input) return;
        const {options, callback} = this.input;
        if (options?.onKeyDown?.(e, this.input.node.value, this.closeInput)) return;
        if (e.key === "Escape" || (options?.closeOnEnter !== false && e.key === "Enter")) {
            this.input.node.blur();
            e.stopPropagation();
            this.closeInput();
        }
        if (e.key === "Enter" && callback) {
            e.stopPropagation();
            e.preventDefault();
            callback((e.target as HTMLInputElement).value);
        }
    };

    private inputKeyUp = (e: KeyboardEvent): void => {
        if (!this.input) return;
        this.input.options?.onKeyUp?.(e, (e.target as HTMLInputElement).value, this.closeInput);
    };

    private inputKeyInput = (e: InputEvent): void => {
        if (!this.input) return;
        this.input.options?.onKeyInput?.(e, (e.target as HTMLInputElement).value, this.closeInput);
    };

    private inputBlur = (e: FocusEvent): void => {
        if (!this.input) return;
        const {options} = this.input;
        options?.onBlur?.(e, this.closeInput);
        if (options?.closeOnBlur) this.closeInput();
    };

    private addInputListeners(): void {
        const node = this.input?.node;
        if (!node) return;
        node.addEventListener("keyup", this.inputKeyUp);
        node.addEventListener("keydown", this.inputKeyDown);
        node.addEventListener("input", this.inputKeyInput as EventListener);
        node.addEventListener("blur", this.inputBlur);
    }

    private removeInputListeners(): void {
        const node = this.input?.node;
        if (!node) return;
        node.removeEventListener("keyup", this.inputKeyUp);
        node.removeEventListener("keydown", this.inputKeyDown);
        node.removeEventListener("input", this.inputKeyInput as EventListener);
        node.removeEventListener("blur", this.inputBlur);
    }
}

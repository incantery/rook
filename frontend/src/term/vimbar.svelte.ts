// The vim command line's seam between the imperative editor island and the
// Svelte chrome. monaco-vim renders its status (mode indicator, `:` input,
// search, messages) into a DOM node it holds a reference to — so the node
// can't be re-created by a template, but it CAN be adopted: each editor pane
// keeps owning its node, and the focused pane's node is moved into the global
// status bar's slot. That is vim's own model — every window has state, but
// the command line is one, and it reflects the active window.

class VimBarState {
    /** a pane's vim node currently holds the slot — StatusBar renders it */
    active = $state(false);
    /** the focused editor's cursor, 1-based — the bar's "Ln 16, Col 34" */
    pos = $state<{ln: number; col: number} | null>(null);
    private slot: HTMLElement | null = null;
    private node: HTMLElement | null = null;

    /** StatusBar's slot element (bind:this via $effect — null on teardown) */
    mountSlot(el: HTMLElement | null): void {
        this.slot = el;
        this.attach();
    }

    /** an editor pane gained focus: adopt its vim node (null = a pane with
     *  no vim line, e.g. a review diff — clears the slot) */
    publish(el: HTMLElement | null): void {
        if (this.node !== el) this.pos = null; // the old pane's cursor is a lie
        this.node = el;
        this.active = !!el;
        this.attach();
    }

    /** cursor updates from the pane that OWNS `el` — ignored unless that pane
     *  currently holds the slot, so a background pane's edits never move the
     *  bar's numbers */
    setPos(el: HTMLElement | null, pos: {ln: number; col: number}): void {
        if (el && this.node === el) this.pos = pos;
    }

    /** a pane is going away — release the slot iff it still holds its node */
    retract(el: HTMLElement | null): void {
        if (el && this.node === el) this.publish(null);
    }

    private attach(): void {
        if (!this.slot) return;
        if (this.node) this.slot.replaceChildren(this.node);
        else this.slot.replaceChildren();
    }
}

export const vimbar = new VimBarState();

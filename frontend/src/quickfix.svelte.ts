// Quickfix: vim's best idea after modal editing, generalized — ONE traversal
// muscle memory (open/close/next/prev) over heterogeneous work lists, where
// the CONTEXT owns the rows, the detail surface, and the verbs. Review is the
// first context; attention/threads/issues are the obvious next tenants.
//
// The state here is deliberately dumb: a context, a cursor, two visibility
// bits. A context is a plain object handed to set() (the PaneRef idiom — a
// tagged record, NOT a plugin registry with lifecycle); the API gets extracted
// from the contexts we actually build, not designed up front.
//
// Traversal state survives UI visibility (vim: close the window, :cnext still
// works): the cursor lives here, never in the list component. Items are ids
// resolved through the context's own store, so the list never holds copies
// that could go stale.

import type {Component} from "svelte";

export interface QfAction {
    /** single key when a quickfix surface holds the keyboard, e.g. "a" */
    key: string;
    /** button label, glyph included, e.g. "✓ Approve" */
    label: string;
    /** tone → literal Tailwind classes live in the components (scan rule) */
    tone: "grn" | "red" | "amber" | "acc";
    /** move the cursor to the next item after running (disposition verbs) */
    advance: boolean;
    run(id: number): void | Promise<void>;
}

export interface QfContext {
    id: string; // "review"
    title: string; // the side-pane header
    /** item ids in list order — a getter over the context's own store */
    ids(): number[];
    /** one row's CONTENT; the panel owns the interactive wrapper/cursor */
    Row: Component<{id: number; focused: boolean; open: boolean}>;
    /** the hero surface (center overlay); contract is {id, pos} + whatever
     *  detailProps() supplies — typed loose because each context spreads its
     *  own dependencies (api, workspace, …) */
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    Detail: Component<any> | null;
    detailProps?(): Record<string, unknown>;
    /** header line above the list (review: the gate); optional */
    Header: Component | null;
    actions: QfAction[];
    /** right-side footer verbs as key/label pairs, so every surface renders
     *  its triggers as keycaps rather than burying them in prose */
    hint: [key: string, label: string][];
    empty: string;
    /** the prepare/refresh affordance, when the context has one */
    prepare?: {label(): string; run(): void | Promise<void>};
}

class QuickfixState {
    context = $state<QfContext | null>(null);
    cursor = $state(0);
    listOpen = $state(false);
    detailOpen = $state(false);

    get ids(): number[] {
        return this.context?.ids() ?? [];
    }
    get currentId(): number | null {
        return this.ids[this.cursor] ?? null;
    }

    /** populate/replace the list — whoever fills it owns the context (vim's
     *  semantics: the last producer wins; nothing is inferred) */
    set(ctx: QfContext): void {
        if (this.context?.id !== ctx.id) {
            this.cursor = 0;
            this.detailOpen = false;
        }
        this.context = ctx;
    }

    move(d: number): void {
        const n = this.ids.length;
        if (n === 0) return;
        this.cursor = Math.min(Math.max(this.cursor + d, 0), n - 1);
    }

    /** clamp after the context's items changed underneath the cursor */
    clamp(): void {
        if (this.cursor >= this.ids.length) this.cursor = Math.max(0, this.ids.length - 1);
        if (this.detailOpen && this.currentId == null) this.detailOpen = false;
    }

    /** run the context action bound to `key` on the current item — the ONE
     *  implementation every surface (list keys, hero keys, hero buttons,
     *  registry commands) dispatches through, which is also what makes the
     *  verbs agent-invokable via the command registry. */
    async act(key: string): Promise<void> {
        const a = this.context?.actions.find((x) => x.key === key);
        const id = this.currentId;
        if (!a || id == null) return;
        await a.run(id);
        if (a.advance) this.move(1);
    }
}

export const qf = new QuickfixState();

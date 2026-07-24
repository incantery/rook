/** The ask pane: an agent's question (ask.go) rendered as a form in a split
 *  beside the pane that asked. Same posture as MonitorPane: a Svelte view
 *  behind the narrow PaneContent seam — the manager never learns what's
 *  inside. The pane settles its ask exactly once, whichever door closes it
 *  first: answer, Esc, or ` x (dispose without a decision = dismissal, so
 *  the blocked rookctl never hangs). */

import {mount, unmount} from "svelte";

import AskView from "../AskView.svelte";
import type {AskAnswer} from "../AskView.svelte";
import type {AskQuestion} from "./manager";

import type {PaneContent} from "./manager";

export interface AskPaneOpts {
    questions: AskQuestion[];
    /** the human decided — deliver {answers} to the blocked asker */
    onAnswer: (answers: AskAnswer[]) => void;
    /** Esc / closed without a decision — deliver {canceled:true} */
    onCancel: () => void;
    /** the pane is gone — drop the chrome's index entry */
    onDispose?: () => void;
}

export class AskPane implements PaneContent {
    readonly el: HTMLElement;
    /** not a terminal: kill, cwd-from and the attention jump all skip it */
    readonly sessionId = null;

    private view: Record<string, unknown> | null = null;
    private settled = false;
    private opts: AskPaneOpts;

    constructor(opts: AskPaneOpts) {
        this.opts = opts;
        this.el = document.createElement("div");
        this.el.className = "ask-wrap h-full";
        this.el.tabIndex = -1;
        this.view = mount(AskView, {
            target: this.el,
            props: {
                questions: opts.questions,
                onAnswer: (answers: AskAnswer[]) => this.settle(() => opts.onAnswer(answers)),
                onCancel: () => this.settle(() => opts.onCancel()),
            },
        });
    }

    private settle(deliver: () => void): void {
        if (this.settled) return;
        this.settled = true;
        deliver();
    }

    get title(): string {
        return "claude asks";
    }

    focus(): void {
        (this.el.querySelector("[data-ask-root]") as HTMLElement | null)?.focus();
    }

    /** The view is CSS; flexbox sizes it. */
    fit(): void {}

    dispose(): void {
        // closed without a decision (` x, window teardown) — a dismissal,
        // not a leak: the blocked asker gets {canceled:true}
        this.settle(() => this.opts.onCancel());
        if (this.view) {
            void unmount(this.view);
            this.view = null;
        }
        this.opts.onDispose?.();
    }
}

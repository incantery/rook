/** The editor's start screen — what bare `re` lands on instead of an empty
 *  buffer. alpha-nvim's job: recents to jump back into, the verbs worth
 *  knowing, and a wordmark.
 *
 *  Same posture as MonitorPane: a Svelte view behind the narrow PaneContent
 *  seam, so the manager never learns what's inside. A start pane is a surface
 *  with no identity — it never persists, and picking a file RETARGETS it into
 *  a file pane rather than opening a second one, which is what keeps a bare
 *  `re` a single-pane experience the way `nvim` is.
 *
 *  It also carries the `re` takeover's contract: the greeter is what the
 *  blocked rookctl is waiting on, so `q` has to finish the edit exactly as
 *  `:q` would from an editor. */

import {mount, unmount} from "svelte";

import StartView from "../StartView.svelte";
import type {HostAPI} from "../hostapi";
import type {Command} from "../registry";
import type {PaneContent} from "./manager";

export interface StartPaneOpts {
    api: HostAPI;
    workspace: string;
    /** the anchor `re` launched from — recents open relative to the same
     *  place an editor pane in this slot would use */
    dir?: string;
    /** rows to draw, already resolved to real registry commands with their
     *  live keycaps — the view never hardcodes a verb or a chord */
    actions: () => {cmd: Command; keys: string}[];
    /** open a remembered path, retargeting this pane in place */
    onOpen: (path: string) => void;
    /** q — hand the pane back, releasing a waiting `re` with exit 0 */
    onQuit: () => void;
    /** the pane is gone — drop the chrome's index entry */
    onDispose?: () => void;
}

export class StartPane implements PaneContent {
    readonly el: HTMLElement;
    /** not a terminal: kill, cwd-from and the attention jump all skip it */
    readonly sessionId = null;

    private view: Record<string, unknown> | null = null;
    private onDispose?: () => void;

    constructor(opts: StartPaneOpts) {
        this.el = document.createElement("div");
        this.el.className = "start-wrap";
        // focusable so the pane can take the keyboard: the greeter's keys are
        // its own (q, 1-9), not vim's — there is no buffer here to motion over
        this.el.tabIndex = -1;
        this.onDispose = opts.onDispose;
        this.view = mount(StartView, {
            target: this.el,
            props: {
                api: opts.api,
                workspace: opts.workspace,
                dir: opts.dir,
                actions: opts.actions,
                onopen: opts.onOpen,
                onquit: opts.onQuit,
            },
        });
    }

    get title(): string {
        return "start";
    }

    /** The view's root owns the keydown handler (the greeter's keys are its
     *  own), so focus has to land THERE — focusing the wrapper would leave
     *  1-9 and q going nowhere. */
    focus(): void {
        const root = this.el.querySelector<HTMLElement>("[data-start-root]");
        (root ?? this.el).focus({preventScroll: true});
    }

    /** The view is CSS; flexbox sizes it. */
    fit(): void {}

    dispose(): void {
        if (this.view) {
            void unmount(this.view);
            this.view = null;
        }
        this.onDispose?.();
    }
}

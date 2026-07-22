/** The performance pane: what rook costs the machine vs what the user's own
 *  processes cost, charted from the host monitor's stored series with a live
 *  per-session breakdown. Opened by the titlebar footprint chip.
 *
 *  Same posture as AgentPane: a Svelte view behind the narrow PaneContent
 *  seam — the manager never learns what's inside. A monitor pane is a surface
 *  with no identity (there is one machine), so like `review` it never
 *  persists and never retargets. */

import {mount, unmount} from "svelte";

import MonitorView from "../MonitorView.svelte";
import type {HostAPI} from "../hostapi";
import type {PaneContent} from "./manager";

export interface MonitorPaneOpts {
    api: HostAPI;
    /** the pane is gone — drop the chrome's index entry */
    onDispose?: () => void;
}

export class MonitorPane implements PaneContent {
    readonly el: HTMLElement;
    /** not a terminal: kill, cwd-from and the attention jump all skip it */
    readonly sessionId = null;

    private view: Record<string, unknown> | null = null;
    private onDispose?: () => void;

    constructor(opts: MonitorPaneOpts) {
        this.el = document.createElement("div");
        this.el.className = "monitor-wrap";
        this.el.tabIndex = -1;
        this.onDispose = opts.onDispose;
        this.view = mount(MonitorView, {target: this.el, props: {api: opts.api}});
    }

    get title(): string {
        return "performance";
    }

    focus(): void {
        this.el.focus({preventScroll: true});
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

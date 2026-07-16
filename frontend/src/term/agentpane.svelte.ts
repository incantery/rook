/** The agent-session pane: a claude session rendered as a conversation,
 *  living in the pane tree beside the terminals (docs/agent.md, amendment
 *  2026-07-15).
 *
 *  It is a pane and not an overlay so that an agent session is a buffer like
 *  everything else — it splits, it sits beside the pty it is a view of, and
 *  `:e`-style retargeting points it at a different session in place.
 *
 *  This is the first Svelte mounted outside main.ts, and the seam is narrow
 *  on purpose: the manager holds this as an opaque PaneContent and never
 *  learns what is inside, exactly as it stays Monaco-free about EditorPane.
 *  The file is .svelte.ts because the props handed to a mounted component
 *  are only reactive through $state, and retarget()/setStatus() must reach
 *  the running view.
 *
 *  Like EditorPane, an agent pane does not persist: layout.ts's normalize()
 *  accepts only `term` leaves and termOnly() strips the rest before save.
 *  A {type:"agent", session} IS restorable — it carries identity — so that
 *  is a choice a later slice can revisit, not a limitation. */

import {mount, unmount} from "svelte";

import AgentSession from "../AgentSession.svelte";
import type {HostAPI} from "../hostapi";
import type {PaneContent} from "./manager";

export interface AgentPaneOpts {
    api: HostAPI;
    /** the claude transcript session id — NOT a rook pty session */
    session: string;
    /** jump to the live pty this session is paired with, when there is one */
    onjump?: () => void;
    /** the pane is gone — drop the chrome's index entry */
    onDispose?: () => void;
}

export class AgentPane implements PaneContent {
    readonly el: HTMLElement;
    /** not a terminal: kill, cwd-from and the attention jump all skip this
     *  pane. The claude session id lives in props.session, and chrome keeps
     *  its own index — the same shape as App's editorPanes map. */
    readonly sessionId = null;

    private props = $state({
        api: null as unknown as HostAPI,
        session: "",
        onjump: undefined as (() => void) | undefined,
    });
    private view: Record<string, unknown> | null = null;
    private onDispose?: () => void;

    constructor(opts: AgentPaneOpts) {
        this.el = document.createElement("div");
        this.el.className = "agent-wrap";
        this.el.tabIndex = -1;

        this.props.api = opts.api;
        this.props.session = opts.session;
        this.props.onjump = opts.onjump;
        this.onDispose = opts.onDispose;

        this.view = mount(AgentSession, {target: this.el, props: this.props});
    }

    /** What the strip shows while this pane is focused. The session's title
     *  rides in with the transcript, but it lives inside the view — the strip
     *  gets the id, which is stable and never lies. */
    get title(): string {
        return `agent ${this.props.session.slice(0, 8)}`;
    }

    /** the claude session this pane currently shows */
    get session(): string {
        return this.props.session;
    }

    /** Point the pane at a different session, in place. The view refetches;
     *  the caller keeps the tree honest via mgr.retargetPane. */
    retarget(session: string, onjump?: () => void): void {
        this.props.session = session;
        this.props.onjump = onjump;
    }

    focus(): void {
        this.el.focus({preventScroll: true});
    }

    /** Nothing to measure: the view is CSS, not a canvas. Terminals and
     *  Monaco need to be told their size; flexbox does not. */
    fit(): void {}

    dispose(): void {
        if (this.view) {
            void unmount(this.view);
            this.view = null;
        }
        this.onDispose?.();
    }
}

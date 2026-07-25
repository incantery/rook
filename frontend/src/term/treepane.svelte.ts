/** The file tree as a WINDOW.
 *
 *  It used to be a left SidePane tenant, and that placement is why it could
 *  never be full screen (a fixed-width flex sibling is not a node in the
 *  layout) and why closing the editor took it with it — it was "the editor's
 *  furniture". As a pane it is nerdtree instead: ` z zooms it, ⌃hjkl reaches
 *  it, q closes it, closing the editor beside it leaves it standing, and a
 *  tree alone in a window IS full screen with no special case.
 *
 *  Same posture as MonitorPane/StartPane: a Svelte view behind the narrow
 *  PaneContent seam. FileExplorer itself is unchanged in what it draws — it
 *  only stopped being told when it has focus, because a pane answers that
 *  for itself. */

import {mount, unmount} from "svelte";

import FileExplorer from "../FileExplorer.svelte";
import type {HostAPI} from "../hostapi";
import type {PaneContent} from "./manager";

export interface TreePaneOpts {
    api: HostAPI;
    workspace: string;
    /** the tree's root — a shell's cwd, or `re .`'s directory. undefined
     *  means the workspace root. */
    dir?: string;
    /** a file row was chosen — the workbench's openFile ladder takes it */
    onOpen: (path: string) => void;
    /** q — close this pane */
    onClose: () => void;
    /** the pane is gone — drop the chrome's index entry */
    onDispose?: () => void;
}

export class TreePane implements PaneContent {
    readonly el: HTMLElement;
    /** not a terminal: kill, cwd-from and the attention jump all skip it */
    readonly sessionId = null;

    private view: {revealPath?: (path: string) => void} | null = null;
    private opts: TreePaneOpts;

    constructor(opts: TreePaneOpts) {
        this.opts = opts;
        this.el = document.createElement("div");
        this.el.className = "tree-wrap flex h-full min-h-0 flex-col";
        this.el.tabIndex = -1;
        this.view = mount(FileExplorer, {
            target: this.el,
            props: {
                api: opts.api,
                workspace: opts.workspace,
                dir: opts.dir,
                onopen: opts.onOpen,
                onclose: opts.onClose,
            },
        });
    }

    /** The strip shows where the tree is rooted, not just "tree" — two of
     *  them (the repo, and wherever `re .` ran) have to be tellable apart. */
    get title(): string {
        const d = this.opts.dir;
        return d ? `tree ${d.slice(d.lastIndexOf("/") + 1)}` : "tree";
    }

    /** ` f — put the cursor on a path, expanding whatever it takes to get
     *  there. The view queues it until its listing has loaded. */
    revealPath(path: string): void {
        this.view?.revealPath?.(path);
    }

    /** The keyboard target is the listing itself (role=tree), which owns the
     *  j/k/h/l/q handler — focusing the wrapper would leave those keys going
     *  nowhere. */
    focus(): void {
        const t = this.el.querySelector<HTMLElement>('[role="tree"]');
        (t ?? this.el).focus({preventScroll: true});
    }

    /** The view is CSS; flexbox sizes it. */
    fit(): void {}

    dispose(): void {
        if (this.view) {
            void unmount(this.view);
            this.view = null;
        }
        this.opts.onDispose?.();
    }
}

// UI-rate app state — the reactive layer every Svelte surface reads.
// The terminal runtime (term/manager.ts) writes projections INTO this via
// its events; terminal output itself never passes through here.

import type {AttentionItem, CostsSnapshot, UsageSnapshot, WorkspaceInfo} from "./hostapi";
import type {TabInfo} from "./term/manager";

/** the workbench mode — which surface owns the viewport. Chrome reads this
 *  to pick context-aware defaults instead of branching on any one surface. */
export type Mode = "home" | "terminal" | "review" | "file";

/** each mode declares its chrome defaults; the right pane opens by default
 *  only where a mode asks for it (today: review). Keep the default OUT of the
 *  pane wiring — a new mode that wants the pane just flips its flag here. */
export const MODES: Record<Mode, {rightPaneDefault: boolean}> = {
    home: {rightPaneDefault: false},
    terminal: {rightPaneDefault: false},
    review: {rightPaneDefault: true},
    file: {rightPaneDefault: false},
};

class AppState {
    /** which screen owns the viewport; the app-screen is CSS-hidden on
     *  "home", never unmounted — terminals live inside it */
    screen = $state<"home" | "app">("home");
    workspace = $state("main");
    tabs = $state<TabInfo[]>([]);
    activeId = $state<string | null>(null);
    /** the focused pane's host session — null when an editor pane (Monaco)
     *  is focused, a session id when a terminal is. Mirrors mgr.focusedSessionId. */
    focusedSessionId = $state<string | null>(null);
    dashVisible = $state(false);
    prefixArmed = $state(false);
    /** which surface owns the viewport; App.svelte derives this from screen,
     *  the focused editor's kind, and terminal focus. Entering a mode applies
     *  MODES[mode].rightPaneDefault to the right pane. */
    mode = $state<Mode>("home");
    /** the workbench side pane (VS Code-style); threads are its first tenant.
     *  Closed at boot — the mode you enter opens it (review does today). */
    threadPaneOpen = $state(false);

    /** the left side pane: the file explorer. A plain toggle (` b), not
     *  mode-derived — like VS Code's sidebar it persists across modes. */
    explorerOpen = $state(false);

    /** The open file buffers for the CURRENT workspace, most-recent first —
     *  vim's `:ls`. A buffer is not a pane and not a strip entry: it's the
     *  document itself, which is why opening a file must never mint a window.
     *  Panes reference buffers ({type:"file", path} in the layout tree); this
     *  list outlives them, so retargeting a pane off a file leaves the file
     *  open. Reset on workspace switch — paths are repo-relative. */
    buffers = $state<string[]>([]);

    /** Which REGION of the workbench holds focus. The terminal manager tracks
     *  focus as a pane id inside its layout tree, which by construction can't
     *  say "focus is in the explorer" — so the zone sits a level above it and
     *  the two compose: ⌃hjkl walks panes until the tree has no neighbour that
     *  way, then hands off across this boundary to an open side pane.
     *  Always "terms" while the side pane in question is closed. */
    focusZone = $state<"terms" | "left" | "right">("terms");

    // overlays (at most one open; the keybinding ladder checks these)
    paletteOpen = $state(false);
    pickerOpen = $state(false);
    filePickerOpen = $state(false);
    inboxOpen = $state(false);
    spawnOpen = $state(false);
    settingsOpen = $state(false);

    // host polls (App.svelte owns the timers)
    attention = $state<AttentionItem[]>([]);
    usage = $state<UsageSnapshot | null>(null);
    costs = $state<CostsSnapshot | null>(null);
    /** registry snapshot — lineage (worktreeOf/branch) for every surface
     *  that names a workspace; Home refreshes it eagerly after mutations */
    workspaces = $state<WorkspaceInfo[]>([]);

    /** the current workspace's registry entry — undefined until the
     *  workspaces poll lands (surfaces must fail open to a bare name) */
    get workspaceInfo(): WorkspaceInfo | undefined {
        return this.workspaces.find((w) => w.name === this.workspace);
    }

    /** strip slot of the dashboard (config dashboard-tab) */
    dashTab = 1;

    get anyOverlayOpen(): boolean {
        return (
            this.paletteOpen ||
            this.pickerOpen ||
            this.filePickerOpen ||
            this.inboxOpen ||
            this.spawnOpen ||
            this.settingsOpen
        );
    }

    closeOverlays(): void {
        this.paletteOpen = false;
        this.pickerOpen = false;
        this.filePickerOpen = false;
        this.inboxOpen = false;
        this.spawnOpen = false;
        this.settingsOpen = false;
    }
}

export const app = new AppState();

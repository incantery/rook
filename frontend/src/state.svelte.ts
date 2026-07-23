// UI-rate app state — the reactive layer every Svelte surface reads.
// The terminal runtime (term/manager.ts) writes projections INTO this via
// its events; terminal output itself never passes through here.

import type {Tab} from "./deck";
import type {
    AttentionItem,
    CostsSnapshot,
    ReviewRoot,
    RookTask,
    RuntimeSnapshot,
    ThreadInfo,
    UpdateStatus,
    UsageSnapshot,
    WorkspaceInfo,
    WorkspaceStatus,
} from "./hostapi";
import type {TabInfo} from "./term/manager";

/** the workbench mode — which surface owns the viewport. Chrome reads this
 *  to pick context-aware defaults instead of branching on any one surface. */
export type Mode = "home" | "terminal" | "review" | "file";

/** One gr hit in the refs quickfix — 1-based editor coordinates; external
 *  hits (stdlib/deps) carry an absolute path the file surface can't open. */
export interface RefHit {
    id: number;
    path: string;
    line: number;
    col: number;
    text: string;
    external?: boolean;
}

class AppState {
    /** which screen owns the viewport; the app-screen is CSS-hidden on
     *  "home", never unmounted — terminals live inside it. Boots on "app":
     *  opening rook is opening a terminal, and mission control is a surface
     *  you summon (` h), not the place you land. */
    screen = $state<"home" | "app">("app");
    workspace = $state("main");
    /** transient titlebar message — the workspace chip shows it for 2.5s.
     *  Its own slot so a flash can never leak into API workspace params. */
    flashMsg = $state<string | null>(null);
    tabs = $state<TabInfo[]>([]);
    activeId = $state<string | null>(null);
    /** the focused pane's host session — null when an editor pane (Monaco)
     *  is focused, a session id when a terminal is. Mirrors mgr.focusedSessionId. */
    focusedSessionId = $state<string | null>(null);
    dashVisible = $state(false);
    prefixArmed = $state(false);
    /** which surface owns the viewport; App.svelte derives this from screen,
     *  the focused editor's kind, and terminal focus. */
    mode = $state<Mode>("home");
    /** Every thread in the workspace — the threads QUICKFIX context's store.
     *  Threads used to have a bespoke side panel; they're a work list like
     *  every other, so they read through the one traversal muscle memory
     *  (` t opens it, j/k moves, o opens the thread buffer). Kept here rather
     *  than in a pane because the list outlives whichever pane has focus. */
    threads = $state<ThreadInfo[]>([]);

    /** the left side pane: the file explorer. A plain toggle (` b), not
     *  mode-derived — like VS Code's sidebar it persists across modes. */
    explorerOpen = $state(false);

    /** Review DATA, owned here so every review surface (the quickfix list's
     *  rows, the gate header, the hunk hero) reads one source. Traversal state
     *  (cursor, open/closed) lives in quickfix.svelte.ts — the generic layer;
     *  this is only the work-type's data. App.svelte drives load/dispose/
     *  prepare against the host. */
    reviewRoot = $state<ReviewRoot | null>(null);

    get reviewHunks(): RookTask[] {
        return this.reviewRoot?.children ?? [];
    }

    /** The last location list — the refs quickfix context's data (vim
     *  semantics: the last producer owns the list; a new gr or a grep ⌃Q
     *  replaces it wholesale). Ids are 1-based positions in this array,
     *  minted at fill time. refTitle names the producer for the list header. */
    refHits = $state<RefHit[]>([]);
    refTitle = $state("References");

    /** The ACTIVE investigation (explore root, children = the breadcrumb
     *  trail) — while one is open, every navigation through the opener seam
     *  appends a visit. Durable on the host; this is just the live mirror,
     *  reloaded on boot and workspace switch. */
    exploreTask = $state<RookTask | null>(null);

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
     *  Always "terms" while the side pane in question is closed. "bottom" is
     *  the quickfix strip. */
    focusZone = $state<"terms" | "left" | "right" | "bottom">("terms");

    /** Mission control's own state — which tab, what filter, where the cursor
     *  is, flat or grouped.
     *
     *  Up here rather than inside Home because Home is an `{#if}` and remounts
     *  on every trip out to a workspace and back. Held locally, the deck lost
     *  your filter, your grouping and your place every time you opened a row —
     *  and opening a row IS the triage loop, so the loop reset its own context
     *  once per iteration. #terminals survives the same switch by being a
     *  display toggle; the deck gets there by keeping its state outside the
     *  component instead, which also lets its polls stop while you're away. */
    deck = $state<{tab: Tab; query: string; cursor: number; grouped: boolean}>({
        tab: "all",
        query: "",
        cursor: 0,
        grouped: false,
    });

    // overlays (at most one open; the keybinding ladder checks these)
    paletteOpen = $state(false);
    pickerOpen = $state(false);
    filePickerOpen = $state(false);
    grepOpen = $state(false);
    /** the threads finder (,t) — the quickfix list is still ` t */
    threadFinderOpen = $state(false);
    exploreOpen = $state(false);
    inboxOpen = $state(false);
    spawnOpen = $state(false);
    settingsOpen = $state(false);
    /** the quick-action modal: the current quickfix context's verbs (,a) */
    quickActionOpen = $state(false);

    // host polls (App.svelte owns the timers)
    attention = $state<AttentionItem[]>([]);
    /** the CURRENT workspace's live status — per-pane agent chips + git.
     *  Polled only while the app screen is up; feeds the titlebar tab dots
     *  and the status bar. Null until the first poll lands (fail open). */
    wsStatus = $state<WorkspaceStatus | null>(null);
    usage = $state<UsageSnapshot | null>(null);
    costs = $state<CostsSnapshot | null>(null);
    runtime = $state<RuntimeSnapshot | null>(null);
    /** the host's release check — the status bar's update chip. Null until
     *  the poll lands or on an old host without the route (fail open). */
    update = $state<UpdateStatus | null>(null);
    /** registry snapshot — lineage (worktreeOf/branch) for every surface
     *  that names a workspace; Home refreshes it eagerly after mutations */
    workspaces = $state<WorkspaceInfo[]>([]);

    /** the current workspace's registry entry — undefined until the
     *  workspaces poll lands (surfaces must fail open to a bare name) */
    get workspaceInfo(): WorkspaceInfo | undefined {
        return this.workspaces.find((w) => w.name === this.workspace);
    }

    get anyOverlayOpen(): boolean {
        return (
            this.paletteOpen ||
            this.pickerOpen ||
            this.filePickerOpen ||
            this.grepOpen ||
            this.threadFinderOpen ||
            this.exploreOpen ||
            this.inboxOpen ||
            this.spawnOpen ||
            this.settingsOpen ||
            this.quickActionOpen
        );
    }

    closeOverlays(): void {
        this.paletteOpen = false;
        this.pickerOpen = false;
        this.filePickerOpen = false;
        this.grepOpen = false;
        this.threadFinderOpen = false;
        this.exploreOpen = false;
        this.inboxOpen = false;
        this.spawnOpen = false;
        this.settingsOpen = false;
        this.quickActionOpen = false;
    }
}

export const app = new AppState();

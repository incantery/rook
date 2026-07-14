// UI-rate app state — the reactive layer every Svelte surface reads.
// The terminal runtime (term/manager.ts) writes projections INTO this via
// its events; terminal output itself never passes through here.

import type {AttentionItem, CostsSnapshot, UsageSnapshot, WorkspaceInfo} from "./hostapi";
import type {TabInfo} from "./term/manager";

class AppState {
    /** which screen owns the viewport; the app-screen is CSS-hidden on
     *  "home", never unmounted — terminals live inside it */
    screen = $state<"home" | "app">("home");
    workspace = $state("main");
    tabs = $state<TabInfo[]>([]);
    activeId = $state<string | null>(null);
    dashVisible = $state(false);
    prefixArmed = $state(false);
    /** the workbench side pane (VS Code-style); threads are its first tenant */
    threadPaneOpen = $state(true);

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

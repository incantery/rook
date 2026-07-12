// UI-rate app state — the reactive layer every Svelte surface reads.
// The terminal runtime (term/manager.ts) writes projections INTO this via
// its events; terminal output itself never passes through here.

import type {AttentionItem, CostsSnapshot, UsageSnapshot} from "./hostapi";
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

    // overlays (at most one open; the keybinding ladder checks these)
    paletteOpen = $state(false);
    pickerOpen = $state(false);
    inboxOpen = $state(false);
    spawnOpen = $state(false);
    keyOpen = $state(false);

    // host polls (App.svelte owns the timers)
    attention = $state<AttentionItem[]>([]);
    usage = $state<UsageSnapshot | null>(null);
    costs = $state<CostsSnapshot | null>(null);

    /** strip slot of the dashboard (config dashboard-tab) */
    dashTab = 1;

    get anyOverlayOpen(): boolean {
        return this.paletteOpen || this.pickerOpen || this.inboxOpen || this.spawnOpen || this.keyOpen;
    }

    closeOverlays(): void {
        this.paletteOpen = false;
        this.pickerOpen = false;
        this.inboxOpen = false;
        this.spawnOpen = false;
        this.keyOpen = false;
    }
}

export const app = new AppState();

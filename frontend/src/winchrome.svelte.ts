// Per-window editor chrome state — the file tree's open/closed and anchor
// directory, keyed by WINDOW id (vim's tab page: each layout carries its
// own furniture). The DOM follows: App renders one FileExplorer INSTANCE
// per window, so no state — reactive or internal to the component — is
// ever costume-changed between windows.
//
// Entries are created eagerly when windows appear (App's changed() event)
// so template reads never mutate the map mid-render.

import {SvelteMap} from "svelte/reactivity";

export interface WinChrome {
    explorerOpen: boolean;
    /** the tree's anchor: a takeover's cwd, or the shell's cwd at first
     *  toggle; undefined roots at the workspace */
    explorerDir: string | undefined;
}

const NONE = "(none)";

function fresh(): WinChrome {
    const c: WinChrome = $state({explorerOpen: false, explorerDir: undefined});
    return c;
}

const chrome = new SvelteMap<string, WinChrome>([[NONE, fresh()]]);

/** Get (or create) a window's chrome. Idempotent — call from changed()
 *  when windows appear so templates only ever read existing entries. */
export function chromeFor(id: string | null): WinChrome {
    const key = id ?? NONE;
    let c = chrome.get(key);
    if (!c) {
        c = fresh();
        chrome.set(key, c);
    }
    return c;
}

/** Drop entries for windows that no longer exist. */
export function pruneChrome(alive: (id: string) => boolean): void {
    for (const id of chrome.keys()) {
        if (id !== NONE && !alive(id)) chrome.delete(id);
    }
}

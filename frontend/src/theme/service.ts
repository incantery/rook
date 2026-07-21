// The ThemeService: holds the active Theme and applies it to all three
// surfaces at runtime. This is where the four hardcoded palettes collapse
// into one. Type-only imports of ITheme / editor keep it out of the boot
// bundle's weight — no monaco/xterm runtime is pulled in here.
//
// Live swap fans out through subscriptions: xterm terminals (the manager
// subscribes) and Monaco (term/monaco.ts subscribes when it loads). Chrome
// re-themes by writing the CSS vars onto documentElement, which the Tailwind
// utilities and imperative islands both read.

import type {ITheme} from "@xterm/xterm";
import type {editor} from "monaco-editor";
import {withAlpha} from "./color";
import {cssVars} from "./cssvars";
import {ONE_DARK, ONE_LIGHT} from "./builtins";
import {
    CATPPUCCIN_FRAPPE,
    CATPPUCCIN_LATTE,
    CATPPUCCIN_MACCHIATO,
    CATPPUCCIN_MOCHA,
} from "./catppuccin";
import {buildMonacoTheme} from "./monaco-theme";
import {MATERIAL_OCEAN, type Theme} from "./palette";
import {buildXtermTheme} from "./xterm";

// Insertion order is what the Settings picker lists, so keep it meaningful:
// rook's own default first, then each family light→dark.
const BUILTINS: Record<string, Theme> = {
    [MATERIAL_OCEAN.name]: MATERIAL_OCEAN,
    [ONE_DARK.name]: ONE_DARK,
    [ONE_LIGHT.name]: ONE_LIGHT,
    [CATPPUCCIN_LATTE.name]: CATPPUCCIN_LATTE,
    [CATPPUCCIN_FRAPPE.name]: CATPPUCCIN_FRAPPE,
    [CATPPUCCIN_MACCHIATO.name]: CATPPUCCIN_MACCHIATO,
    [CATPPUCCIN_MOCHA.name]: CATPPUCCIN_MOCHA,
};

/** Register a built-in theme (called by theme/builtins). Last write wins. */
export function registerTheme(theme: Theme): void {
    BUILTINS[theme.name] = theme;
}

let active: Theme = MATERIAL_OCEAN;
let opacity = 1;
const xtermSubs = new Set<(t: ITheme) => void>();
const monacoSubs = new Set<(d: editor.IStandaloneThemeData) => void>();

export const themeService = {
    builtins(): string[] {
        return Object.keys(BUILTINS);
    },
    activeName(): string {
        return active.name;
    },
    active(): Theme {
        return active;
    },
    xtermTheme(): ITheme {
        return buildXtermTheme(active.palette);
    },
    monacoTheme(): editor.IStandaloneThemeData {
        return buildMonacoTheme(active.palette);
    },

    /** The window/body tint opacity (config's background-opacity). Stored; the
     *  body tint is painted from the palette bg at this alpha in applyChrome. */
    setOpacity(o: number): void {
        opacity = o;
    },

    /** Terminals re-theme through this hook (the manager subscribes). */
    onXterm(cb: (t: ITheme) => void): () => void {
        xtermSubs.add(cb);
        return () => xtermSubs.delete(cb);
    },
    /** Monaco re-themes through this hook (term/monaco.ts subscribes on load).
     *  No subscriber until an editor pane has opened — a swap with no editor
     *  open is a no-op, and the next open builds the current theme. */
    onMonaco(cb: (d: editor.IStandaloneThemeData) => void): () => void {
        monacoSubs.add(cb);
        return () => monacoSubs.delete(cb);
    },

    /** Write the chrome vars + body tint to the DOM. Safe before Svelte mounts;
     *  documentElement (html) inline style beats app.css :root, so this wins. */
    applyChrome(): void {
        const root = document.documentElement;
        for (const [k, v] of Object.entries(cssVars(active.palette))) {
            root.style.setProperty(k, v);
        }
        const tint = withAlpha(active.palette.bg, opacity);
        document.body.style.background = tint;
        // The same tint as a var, for the panes that must MASK what's under
        // them (the editor's status overlay) rather than let the body show
        // through. Opaque --bg would read as a slab against the tint.
        root.style.setProperty("--bg-tint", tint);
    },

    /** Switch themes at runtime: chrome + every live terminal + Monaco. */
    apply(name: string): void {
        const t = BUILTINS[name];
        if (!t) return;
        active = t;
        this.applyChrome();
        const xt = buildXtermTheme(active.palette);
        for (const cb of xtermSubs) cb(xt);
        const mt = buildMonacoTheme(active.palette);
        for (const cb of monacoSubs) cb(mt);
    },
};

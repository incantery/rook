// The command registry — README decision 3, and the design's load-bearing
// idea ("humans + agents share this registry"). Every action is a named
// command: keybindings dispatch commands, the palette dispatches commands,
// and later the agent's tool surface IS this registry.

export interface Command {
    id: string;
    title: string;
    category: string;
    /** display-only key hint, e.g. "⌘T" */
    keys?: string;
    run: () => void | Promise<void>;
}

/** A command id as an ex-command name: "thread.ask" → "ThreadAsk",
 *  "pane.split-right" → "PaneSplitRight". Every non-alphanumeric run is a
 *  segment break; each segment is capitalized. The result is vim's own
 *  user-command shape (leading uppercase), which keeps derived names out
 *  of the built-ins' namespace by construction. */
export function exNameOf(id: string): string {
    return id
        .split(/[^a-zA-Z0-9]+/)
        .filter(Boolean)
        .map((s) => s[0].toUpperCase() + s.slice(1))
        .join("");
}

/** Vim's rule for user-defined commands, enforced on config aliases too:
 *  a lowercase alias could shadow :w or :q, so it never registers. */
const EX_NAME = /^[A-Z][A-Za-z0-9]*$/;

export class Registry {
    private cmds = new Map<string, Command>();

    register(...cmds: Command[]): void {
        for (const c of cmds) this.cmds.set(c.id, c);
    }

    /** Every command as an ex-command entry (derived name → run thunk),
     *  plus config's [commands] aliases layered on top. App pushes this map
     *  into the editor module (setExCommands), where each name becomes a
     *  defineEx registration on the shared Vim singleton. Fail open on user
     *  input, the keymap's rule: an alias naming an unknown command, or one
     *  that isn't vim's user-command shape, drops with a console.warn. */
    exNames(aliases: Record<string, string | undefined> = {}): Map<string, () => void> {
        const out = new Map<string, () => void>();
        for (const c of this.cmds.values()) out.set(exNameOf(c.id), () => this.run(c.id));
        for (const [alias, id] of Object.entries(aliases)) {
            if (typeof id !== "string" || id === "") continue;
            if (!EX_NAME.test(alias)) {
                console.warn("command alias ignored (must be CamelCase, vim-style):", alias);
                continue;
            }
            if (!this.cmds.has(id)) {
                console.warn("command alias ignored (unknown command):", alias, "=", id);
                continue;
            }
            out.set(alias, () => this.run(id));
        }
        return out;
    }

    all(): Command[] {
        return [...this.cmds.values()];
    }

    /** Does a command exist? Keybind dispatch checks before running so a
     *  typo'd id in config gets user-visible feedback, not a console line. */
    has(id: string): boolean {
        return this.cmds.has(id);
    }

    run(id: string): void {
        const c = this.cmds.get(id);
        if (!c) {
            console.warn("unknown command:", id);
            return;
        }
        void c.run();
    }
}

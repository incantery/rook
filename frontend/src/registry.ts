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

export class Registry {
    private cmds = new Map<string, Command>();

    register(...cmds: Command[]): void {
        for (const c of cmds) this.cmds.set(c.id, c);
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

<!-- The editor's start screen (alpha-nvim's job), recents-forward: a
     wordmark, the documents worth going back to, and the verbs worth
     knowing. Bare `re` lands here instead of on an empty buffer.

     The action rows are NOT a hardcoded list — they are real registry
     commands carrying their live keycaps (keymap.display), so a rebind in
     config shows up here and an advertised chord is one that actually
     works. That is decision 3 paying out: the greeter is a view over the
     registry, not a second copy of it.

     Keys are the pane's own (1-9, j/k, enter, q), because there is no
     buffer here to motion over. Anything else falls through to the app's
     own keymap, which is what makes the advertised ⌃p / ⌘k real. -->
<script lang="ts">
    import type {HostAPI, RecentFile} from "./hostapi";
    import type {Command} from "./registry";

    let {
        api,
        workspace,
        dir,
        actions,
        onopen,
        onquit,
    }: {
        api: HostAPI;
        workspace: string;
        dir?: string;
        actions: () => {cmd: Command; keys: string}[];
        onopen: (path: string) => void;
        onquit: () => void;
    } = $props();

    /** How many recents the list offers. Nine because the jump keys are
     *  1-9 — a tenth row would be reachable only by cursor, which reads as
     *  a bug rather than a limit. */
    const MAX_ROWS = 9;

    let recents = $state<RecentFile[]>([]);
    let cursor = $state(0);
    let version = $state("");

    const rows = $derived(actions());

    $effect(() => {
        void (async () => {
            recents = await api.recents(workspace, MAX_ROWS);
        })();
    });

    $effect(() => {
        void (async () => {
            try {
                version = (await api.update()).current;
            } catch {
                /* the wordmark does not need a version to be a wordmark */
            }
        })();
    });

    function open(i: number): void {
        const r = recents[i];
        if (r) onopen(r.path);
    }

    function onkeydown(e: KeyboardEvent): void {
        if (e.metaKey || e.ctrlKey || e.altKey) return; // the app's chords win
        if (e.key >= "1" && e.key <= "9") {
            e.preventDefault();
            open(Number(e.key) - 1);
            return;
        }
        switch (e.key) {
            case "j":
            case "ArrowDown":
                e.preventDefault();
                cursor = Math.min(cursor + 1, Math.max(recents.length - 1, 0));
                break;
            case "k":
            case "ArrowUp":
                e.preventDefault();
                cursor = Math.max(cursor - 1, 0);
                break;
            case "Enter":
                e.preventDefault();
                open(cursor);
                break;
            case "q":
                // the greeter is what a blocked `re` is waiting on, so
                // quitting it has to release the shell exactly as :q would
                e.preventDefault();
                onquit();
                break;
        }
    }

    /** Long paths lose their middle, not their name: the basename is what
     *  you recognize and the leading directories are what you can spare. */
    function short(p: string, max = 58): string {
        if (p.length <= max) return p;
        const name = p.slice(p.lastIndexOf("/") + 1);
        return "…/" + (name.length + 2 >= max ? name.slice(-(max - 2)) : name);
    }
</script>

<!-- svelte-ignore a11y_no_static_element_interactions — the keys here are a
     SHORTCUT layer (1-9, j/k, q) over rows that are already real buttons and
     already reachable by tab and click. Giving the container an interactive
     role would announce it as something it isn't. -->
<section
    data-start-root
    class="flex h-full w-full flex-col overflow-auto bg-bg px-8 py-6 font-mono text-fg outline-none"
    tabindex="-1"
    {onkeydown}
>
    <header class="flex items-baseline gap-4">
        <pre
            aria-label="rook"
            class="text-acc select-none text-[0.75rem] leading-[1.15]">▄▀▀▄ ▄▀▀▄ ▄▀▀▄ █  █
█▀▄  █  █ █  █ █▄▀
▀  ▀  ▀▀   ▀▀  ▀  ▀</pre>
        <span class="text-[0.6875rem] text-lo">
            {version || "rook"}
        </span>
    </header>

    <h2 class="mt-6 text-[0.6875rem] tracking-wide text-dim uppercase">Recent</h2>
    {#if recents.length === 0}
        <p class="mt-2 text-[0.75rem] text-lo">
            nothing yet — <span class="text-dim">⌃p</span> finds a file
        </p>
    {:else}
        <ul class="mt-2 flex flex-col">
            {#each recents as r, i (r.path)}
                <li>
                    <button
                        type="button"
                        class="flex w-full items-baseline gap-3 rounded px-2 py-[0.1875rem] text-left text-[0.75rem] hover:bg-raise"
                        class:bg-raise={i === cursor}
                        class:text-acc={i === cursor}
                        onclick={() => open(i)}
                    >
                        <span class="w-3 shrink-0 text-right text-[0.6875rem] text-lo">{i + 1}</span
                        >
                        <span class="min-w-0 truncate">{short(r.path)}</span>
                    </button>
                </li>
            {/each}
        </ul>
    {/if}

    <h2 class="mt-6 text-[0.6875rem] tracking-wide text-dim uppercase">Actions</h2>
    <ul class="mt-2 grid grid-cols-1 gap-x-8 gap-y-[0.1875rem] sm:grid-cols-2">
        {#each rows as row (row.cmd.id)}
            <li>
                <button
                    type="button"
                    class="flex w-full items-baseline gap-3 rounded px-2 py-[0.1875rem] text-left text-[0.75rem] hover:bg-raise"
                    onclick={() => void row.cmd.run()}
                >
                    <span class="w-10 shrink-0 text-[0.6875rem] text-acc">{row.keys}</span>
                    <span class="min-w-0 truncate text-dim">{row.cmd.title}</span>
                </button>
            </li>
        {/each}
    </ul>

    <footer class="mt-auto pt-6 text-[0.6875rem] text-lo">
        {workspace}{dir ? ` · ${short(dir, 40)}` : ""} · <span class="text-dim">q</span> to close
    </footer>
</section>

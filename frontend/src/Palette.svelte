<!-- Command palette (⌘K): overlay, fuzzy-ish filter, arrow navigation,
     enter to run. Purely a view over the Registry. -->
<script lang="ts">
    import type {Registry} from "./registry";

    let {registry, onclose}: {registry: Registry; onclose: () => void} = $props();

    let query = $state("");
    let sel = $state(0);
    let inputEl: HTMLInputElement;
    let listEl: HTMLElement;

    const current = $derived(
        registry.all().filter((c) => {
            const q = query.trim().toLowerCase();
            return !q || c.title.toLowerCase().includes(q) || c.category.toLowerCase().includes(q);
        }),
    );

    function run(id: string) {
        onclose();
        registry.run(id);
    }

    function onKeydown(e: KeyboardEvent) {
        // vim/fzf motions — bare j/k must keep typing into the filter
        const down = e.key === "ArrowDown" || (e.ctrlKey && (e.key === "j" || e.key === "n"));
        const up = e.key === "ArrowUp" || (e.ctrlKey && (e.key === "k" || e.key === "p"));
        if (down) {
            e.preventDefault();
            sel = Math.min(sel + 1, current.length - 1);
        } else if (up) {
            e.preventDefault();
            sel = Math.max(sel - 1, 0);
        } else if (e.key === "Enter") {
            e.preventDefault();
            const cmd = current[sel];
            if (cmd) run(cmd.id);
        } else if (e.key === "Escape") {
            e.preventDefault();
            e.stopPropagation();
            onclose();
        }
    }

    $effect(() => {
        inputEl.focus();
    });
    $effect(() => {
        void sel;
        listEl?.querySelector(".sel")?.scrollIntoView({block: "nearest"});
    });
</script>

<div
    class="fixed inset-0 z-50 flex items-start justify-center bg-black/55 pt-[12vh]"
    onmousedown={(e) => e.target === e.currentTarget && onclose()}
    role="presentation"
>
    <div
        class="w-150 max-w-[92vw] overflow-hidden rounded-xl border border-line/30 bg-overlay shadow-2xl"
    >
        <div class="flex items-center gap-2.5 border-b border-line/15 px-4 py-3">
            <span class="font-mono text-sm text-lo">›</span>
            <input
                class="flex-1 font-[inherit] text-base text-fg outline-none"
                placeholder="Run a command…"
                spellcheck="false"
                bind:this={inputEl}
                bind:value={query}
                oninput={() => (sel = 0)}
                onkeydown={onKeydown}
            />
            <span class="rounded border border-line/15 px-1.5 py-0.5 font-mono text-xs text-lo"
                >esc</span
            >
        </div>
        <div class="max-h-[48vh] overflow-y-auto p-1.5" bind:this={listEl}>
            {#each current as cmd, i (cmd.id)}
                <!-- .sel stays as a JS scroll-into-view hook, not a style -->
                <div
                    class={[
                        "flex cursor-pointer items-center gap-3 rounded-md px-3 py-2 hover:bg-fg/6",
                        i === sel && "bg-acc/15",
                    ]}
                    class:sel={i === sel}
                    onmousedown={(e) => {
                        e.preventDefault();
                        run(cmd.id);
                    }}
                    role="presentation"
                >
                    <span class="flex-1 text-sm text-fg">{cmd.title}</span>
                    <span class="text-xs uppercase tracking-wider text-lo">{cmd.category}</span>
                    <span class="min-w-10 text-right font-mono text-xs text-dim"
                        >{cmd.keys ?? ""}</span
                    >
                </div>
            {/each}
        </div>
        <div
            class="flex items-center gap-4 border-t border-line/15 px-4 py-2 font-mono text-xs text-lo"
        >
            <span>↑↓ navigate</span><span>↵ run</span>
            <span class="flex-1"></span>
            <span>humans + agents share this registry</span>
        </div>
    </div>
</div>

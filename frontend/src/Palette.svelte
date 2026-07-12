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
        registry
            .all()
            .filter((c) => {
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

<div id="palette" class="overlay" onmousedown={(e) => e.target === e.currentTarget && onclose()} role="presentation">
    <div class="pal-panel">
        <div class="pal-inputrow">
            <span class="pal-chevron">›</span>
            <input
                class="pal-input"
                placeholder="Run a command…"
                spellcheck="false"
                bind:this={inputEl}
                bind:value={query}
                oninput={() => (sel = 0)}
                onkeydown={onKeydown}
            />
            <span class="pal-esc">esc</span>
        </div>
        <div class="pal-list" bind:this={listEl}>
            {#each current as cmd, i (cmd.id)}
                <div
                    class="pal-item"
                    class:sel={i === sel}
                    onmousedown={(e) => {
                        e.preventDefault();
                        run(cmd.id);
                    }}
                    role="presentation"
                >
                    <span class="pal-title">{cmd.title}</span>
                    <span class="pal-cat">{cmd.category}</span>
                    <span class="pal-keys">{cmd.keys ?? ""}</span>
                </div>
            {/each}
        </div>
        <div class="pal-footer">
            <span>↑↓ navigate</span><span>↵ run</span>
            <span class="pal-spacer"></span>
            <span>humans + agents share this registry</span>
        </div>
    </div>
</div>

<!-- The quickfix list — a GENERIC side-pane tenant. It knows traversal (roving
     cursor, j/k/g/G, Enter opens the detail) and dispatches everything else to
     the current context: rows, header, actions, hints. It never imports a
     context's data store; rows resolve their own ids. One keyboard
     implementation for every list-shaped surface (review today; attention/
     threads/issues are the intended next tenants). Styled with inline
     Tailwind (README decision 7). -->
<script lang="ts">
    import {flip} from "svelte/animate";
    import {qf} from "./quickfix.svelte";
    import Kbd from "./Kbd.svelte";

    let {active}: {active: boolean} = $props();

    let listEl = $state<HTMLDivElement | undefined>(undefined);

    // When this pane owns the keyboard (focus zone), take the DOM focus.
    $effect(() => {
        if (active) listEl?.focus();
    });

    function moveTo(i: number): void {
        const n = qf.ids.length;
        if (n === 0) return;
        qf.cursor = Math.min(Math.max(i, 0), n - 1);
        queueMicrotask(() =>
            listEl?.querySelector('[data-cursor="1"]')?.scrollIntoView({block: "nearest"}),
        );
    }

    function onKey(e: KeyboardEvent): void {
        if (e.metaKey || e.ctrlKey || e.altKey) return; // chords belong to the workbench
        switch (e.key) {
            case "j":
            case "ArrowDown":
                moveTo(qf.cursor + 1);
                break;
            case "k":
            case "ArrowUp":
                moveTo(qf.cursor - 1);
                break;
            case "g":
                moveTo(0);
                break;
            case "G":
                moveTo(qf.ids.length - 1);
                break;
            case "l":
            case "Enter":
                if (qf.ids.length > 0) qf.detailOpen = true;
                break;
            default: {
                // context verbs (a/r/d/o…) — one dispatch path for every surface
                if (!qf.context?.actions.some((a) => a.key === e.key)) return;
                void qf.act(e.key);
                break;
            }
        }
        e.preventDefault();
        e.stopPropagation();
    }
</script>

{#if qf.context}
    {@const ctx = qf.context}
    <div class="flex h-full min-h-0 flex-col text-fg">
        <!-- header: context header (review: the gate) + prepare/refresh -->
        <div class="flex shrink-0 items-center gap-2 border-b border-line/15 px-3 py-2">
            {#if ctx.Header}
                {@const Header = ctx.Header}
                <Header />
            {/if}
            <span class="flex-1"></span>
            {#if qf.ids.length > 0}
                <span
                    class="border-r border-line/15 pr-2 font-mono text-[10px] text-lo tabular-nums"
                    >{qf.cursor + 1}/{qf.ids.length}</span
                >
            {/if}
            {#if ctx.prepare}
                {@const prep = ctx.prepare}
                <button
                    class="cursor-pointer rounded-lg border border-line/15 bg-fg/5 px-2.5 py-1 text-[11px] font-semibold text-fg hover:border-acc"
                    aria-label="prepare"
                    title="prepare / re-run"
                    onclick={() => void prep.run()}>{prep.label()}</button
                >
            {/if}
        </div>

        <!-- the list is the only scroll region -->
        <div
            id="quickfix-list"
            class="min-h-0 flex-1 overflow-y-auto py-1 outline-none"
            tabindex="-1"
            role="listbox"
            aria-label={ctx.title}
            bind:this={listEl}
            onkeydown={onKey}
        >
            {#each qf.ids as id, i (id)}
                {@const focused = i === qf.cursor}
                {@const open = qf.detailOpen && focused}
                {@const Row = ctx.Row}
                <div
                    animate:flip={{duration: 160}}
                    class={"flex cursor-pointer items-center gap-2 border-l-2 px-3 py-1.5 " +
                        (focused
                            ? "border-acc bg-acc/12 "
                            : "border-transparent hover:bg-fg/[0.04] ")}
                    role="option"
                    aria-selected={focused}
                    tabindex="-1"
                    data-cursor={focused ? "1" : "0"}
                    onclick={() => {
                        qf.cursor = i;
                        qf.detailOpen = true;
                    }}
                    onkeydown={() => {}}
                >
                    <Row {id} {focused} {open} />
                </div>
            {/each}

            {#if qf.ids.length === 0}
                <div class="px-3 py-6 text-center text-xs leading-relaxed text-lo">
                    {ctx.empty}
                </div>
            {/if}
        </div>

        <!-- footer: traversal on the left, the context's verbs on the right -->
        <div
            class="flex shrink-0 items-center gap-2 border-t border-line/15 px-3 py-2 text-[10px] text-lo"
        >
            <div class="flex items-baseline gap-3">
                <Kbd k="j/k" label="move" />
                <Kbd k="↵" label="open" />
            </div>
            <span class="flex-1"></span>
            <div class="flex items-baseline gap-3">
                {#each ctx.hint as [k, label] (k)}
                    <Kbd {k} {label} />
                {/each}
            </div>
        </div>
    </div>
{/if}

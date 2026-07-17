<!-- The quick-action modal (,a): a which-key popup for the CURRENT quickfix
     context's verbs. Rendered FROM qf.context.actions and dispatched through
     qf.act — the same path as the list keys, the hero keys, and the registry
     commands, so it can never drift from what the keys actually do. Generic:
     it knows a context has a title, a cursor position, and actions; nothing
     review-specific lives here. Screen-centered, palette-style: j/k moves a
     selection, Enter runs it, an action's own key fires it directly. NOTE:
     buttons must set their bg explicitly — no Tailwind preflight here, so a
     bare <button> renders the UA's light-gray chrome. -->
<script lang="ts">
    import {fly} from "svelte/transition";
    import {qf, type QfAction} from "./quickfix.svelte";

    let {onclose}: {onclose: () => void} = $props();

    // tone → literal classes (Tailwind scans source; never interpolate)
    const TONE_KEY: Record<QfAction["tone"], string> = {
        grn: "border-grn/35 bg-grn/10 text-grn",
        red: "border-red/35 bg-red/10 text-red",
        amber: "border-amber/35 bg-amber/10 text-amber",
        acc: "border-acc/35 bg-acc/10 text-acc",
    };

    let rootEl = $state<HTMLDivElement | undefined>(undefined);
    let sel = $state(0);
    // the modal owns the keyboard while open — focus lands here on mount
    $effect(() => rootEl?.focus());

    const actions = $derived(qf.context?.actions ?? []);

    async function run(a: QfAction | undefined): Promise<void> {
        if (!a) return;
        await qf.act(a.key);
        onclose();
    }

    function onKey(e: KeyboardEvent): void {
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        switch (e.key) {
            case "Escape":
                onclose();
                break;
            case "j":
            case "ArrowDown":
                sel = Math.min(sel + 1, actions.length - 1);
                break;
            case "k":
            case "ArrowUp":
                sel = Math.max(sel - 1, 0);
                break;
            case "Enter":
                void run(actions[sel]);
                break;
            default: {
                const a = actions.find((x) => x.key === e.key);
                if (!a) return;
                void run(a);
                break;
            }
        }
        e.preventDefault();
        e.stopPropagation();
    }
</script>

<!-- backdrop: click closes; the panel sits screen-center, palette-style -->
<div
    class="fixed inset-0 z-40 flex items-center justify-center bg-bg/40"
    role="presentation"
    onclick={onclose}
>
    <div
        class="w-96 rounded-xl border border-line/15 bg-overlay p-2 shadow-2xl outline-none"
        role="dialog"
        aria-label="quick actions"
        tabindex="-1"
        bind:this={rootEl}
        transition:fly={{y: 8, duration: 140}}
        onclick={(e) => e.stopPropagation()}
        onkeydown={onKey}
    >
        <div class="flex items-center gap-2 px-2 pb-2 pt-1">
            <span class="text-[10px] font-bold uppercase tracking-wider text-lo"
                >{qf.context?.title ?? "Quickfix"}</span
            >
            {#if qf.ids.length > 0}
                <span class="font-mono text-[10px] text-lo">{qf.cursor + 1} / {qf.ids.length}</span>
            {/if}
            <span class="flex-1"></span>
            <span class="font-mono text-[10px] text-lo">j/k select · ↵ run · esc</span>
        </div>
        {#if actions.length === 0 || qf.ids.length === 0}
            <div class="px-2 py-3 text-center text-xs text-lo">
                Nothing to act on — the list is empty.
            </div>
        {:else}
            <div class="flex flex-col gap-1" role="listbox" aria-label="actions">
                {#each actions as act, i (act.key)}
                    <button
                        class={"flex w-full cursor-pointer items-center gap-3 rounded-lg border-0 px-2 py-1.5 text-left " +
                            (i === sel ? "bg-acc/15" : "bg-transparent hover:bg-fg/[0.06]")}
                        role="option"
                        aria-selected={i === sel}
                        onmouseenter={() => (sel = i)}
                        onclick={() => void run(act)}
                    >
                        <kbd
                            class={"inline-flex size-6 items-center justify-center rounded-md border font-mono text-xs " +
                                TONE_KEY[act.tone]}>{act.key}</kbd
                        >
                        <span class="text-[13px] text-fg">{act.label}</span>
                    </button>
                {/each}
            </div>
        {/if}
    </div>
</div>

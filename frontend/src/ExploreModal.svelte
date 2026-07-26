<!-- Start an investigation — one input, because an investigation is a
     question. Enter starts it; the trail then fills itself as you
     navigate. The picker's shell. -->
<script lang="ts">
    interface Props {
        onstart: (title: string) => void;
        onclose: () => void;
    }
    let {onstart, onclose}: Props = $props();

    let title = $state("");
    let inputEl: HTMLInputElement;

    function submit() {
        const q = title.trim();
        if (!q) return;
        onclose();
        onstart(q);
    }

    function onKeydown(e: KeyboardEvent) {
        if (e.key === "Enter") {
            e.preventDefault();
            submit();
        } else if (e.key === "Escape") {
            e.preventDefault();
            e.stopPropagation();
            onclose();
        }
    }

    $effect(() => {
        inputEl.focus();
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
            <span class="font-mono text-sm text-lo">?</span>
            <input
                class="flex-1 font-[inherit] text-base text-fg outline-none"
                placeholder="What are you trying to find out?"
                spellcheck="false"
                bind:this={inputEl}
                bind:value={title}
                onkeydown={onKeydown}
            />
            <span class="rounded border border-line/15 px-1.5 py-0.5 font-mono text-xs text-lo"
                >esc</span
            >
        </div>
        <div
            class="flex items-center gap-4 border-t border-line/15 px-4 py-2 font-mono text-xs text-lo"
        >
            <span>↵ start investigating</span>
            <span class="flex-1"></span>
            <span>every jump leaves a breadcrumb until you finish</span>
        </div>
    </div>
</div>

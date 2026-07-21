<!-- A keycap. Every hint row in rook names keys inline in prose ("j/k move ·
     ↵ open"), which makes the KEY — the only part you act on — the hardest
     part to find. A chip separates the verb from its trigger at a glance, and
     is the one piece of visual vocabulary shared by every hint surface. -->
<script lang="ts">
    let {k, label}: {k: string; label?: string} = $props();
</script>

<span class="inline-flex items-baseline gap-1.5 whitespace-nowrap">
    <kbd
        class="rounded border border-line/20 bg-fg/[0.06] px-1 py-px font-mono text-[10px] leading-none font-semibold text-dim"
        >{k}</kbd
    >
    {#if label}<span class="text-lo">{label}</span>{/if}
</span>

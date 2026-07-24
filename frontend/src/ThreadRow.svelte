<!-- One thread as a quickfix row — CONTENT only; QuickfixPanel owns the
     wrapper, cursor and keyboard. Same shape as a grep hit (path:line · text)
     so the list reads consistently whatever produced it. Resolves its own data
     from the app store by id (the quickfix rule: rows never hold copies that
     could go stale). -->
<script lang="ts">
    import {app} from "./state.svelte";
    import {snippetOf, statusMeta, threadStatus, type StateTone} from "./term/threadview";

    let {id}: {id: number; focused: boolean; open: boolean} = $props();

    const t = $derived(app.threads.find((x) => x.id === id));
    // Tone → literal class names; Tailwind scans source for literal strings,
    // so this can never be `text-${tone}`.
    const TONE: Record<StateTone, string> = {
        amber: "text-amber",
        acc: "text-acc",
        grn: "text-grn",
        red: "text-red",
        magenta: "text-magenta",
    };
</script>

{#if t}
    {@const meta = statusMeta(threadStatus(t))}
    <!-- status, not stored state: the list has to agree with the gutter about
         whose move it is, and "open" alone never said that -->
    <span class={"shrink-0 text-[0.625rem] " + TONE[meta.tone]} title={meta.label}>●</span>
    <!-- location in mono (it's a coordinate), the comment in the BODY font:
         prose set in a code face is measurably harder to scan, and the comment
         is the part you read to decide whether to open the thread -->
    <span class="shrink-0 truncate font-mono text-[0.65625rem] text-dim"
        >{t.path}<span class="text-lo">:{t.currentStart}</span></span
    >
    <span class="min-w-0 flex-1 truncate text-[0.71875rem] text-fg"
        >{t.comments[0]?.body ?? snippetOf(t)}</span
    >
    {#if t.draft}
        <!-- an uncommitted tail is waiting in the buffer — your words, not sent -->
        <span class="shrink-0 text-[0.5625rem] text-amber">draft</span>
    {/if}
    {#if t.outdated}
        <span class="shrink-0 text-[0.5625rem] text-lo">outdated</span>
    {/if}
    {#if t.comments.length > 1}
        <span class="shrink-0 text-[0.5625rem] text-lo">{t.comments.length}</span>
    {/if}
{/if}

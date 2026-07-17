<!-- The bespoke hunk detail — the center of the review experience (NOT the
     Monaco editor). One hunk as a decision object: Haiku's read of it up top
     (what it does / what to check), the hunk's own diff as evidence below, a
     note box (the whiteboard), and disposition. Renders the diff itself from
     the stored patch body (anchorText), so review is self-contained and owes
     nothing to the editor+thread-panel setup. Styled with inline Tailwind
     (README decision 7); model of quality is ThreadPanel.svelte. -->
<script lang="ts">
    import type {HostAPI, RookTask} from "./hostapi";

    let {
        api,
        workspace,
        hunk,
        pos,
        onDispose,
        onClose,
        onNav,
    }: {
        api: HostAPI;
        workspace: string;
        hunk: RookTask;
        pos: {i: number; n: number}; // 1-based position for the "3 / 14" counter
        onDispose: (state: string) => void;
        onClose: () => void;
        onNav: (dir: number) => void;
    } = $props();

    const GLYPH: Record<string, string> = {
        proposed: "○",
        approved: "✓",
        rejected: "✗",
        deferred: "»",
        pending: "…",
    };
    const TONE: Record<string, string> = {
        proposed: "text-lo",
        approved: "text-grn",
        rejected: "text-red",
        deferred: "text-amber",
        pending: "text-acc",
    };

    let note = $state("");
    let noteBusy = $state(false);
    let noteDone = $state(false);
    let err = $state("");

    const detail = $derived(hunk.detail ?? {});
    const lines = $derived((hunk.anchorText ?? "").split("\n"));

    // a diff line's colour by its +/-/context prefix
    function lineClass(ln: string): string {
        switch (ln[0]) {
            case "+":
                return "bg-grn/[0.08] text-fg";
            case "-":
                return "bg-red/[0.08] text-dim";
            case "\\":
                return "text-lo italic";
            default:
                return "text-dim";
        }
    }

    async function addNote(): Promise<void> {
        const body = note.trim();
        if (!body || !hunk.path || !hunk.startLine) return;
        noteBusy = true;
        err = "";
        try {
            // a code-anchored note on the hunk's lines — persists today; wiring
            // it to the review task + a Claude reply is the next step.
            await api.createThread(workspace, {
                path: hunk.path,
                startLine: hunk.startLine,
                endLine: hunk.endLine ?? hunk.startLine,
                side: hunk.side ?? "modified",
                body,
            });
            note = "";
            noteDone = true;
        } catch (e) {
            err = String(e);
        } finally {
            noteBusy = false;
        }
    }

    let rootEl: HTMLDivElement | undefined;
    // grab the keyboard when the overlay opens (and when it swaps hunks) so
    // a/r/d/j/k/esc act here, not in a terminal behind it.
    $effect(() => {
        hunk.id; // re-focus on hunk swap
        rootEl?.focus();
    });

    function key(e: KeyboardEvent): void {
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        // don't hijack typing in the note box
        const el = e.target as HTMLElement;
        if (el.tagName === "TEXTAREA") {
            if (e.key === "Escape") (el as HTMLTextAreaElement).blur();
            return;
        }
        switch (e.key) {
            case "a":
                onDispose("approved");
                break;
            case "r":
                onDispose("rejected");
                break;
            case "d":
                onDispose("deferred");
                break;
            case "j":
            case "ArrowDown":
                onNav(1);
                break;
            case "k":
            case "ArrowUp":
                onNav(-1);
                break;
            case "Escape":
                onClose();
                break;
            default:
                return;
        }
        e.preventDefault();
    }
</script>

<div
    class="absolute inset-0 z-20 flex flex-col bg-bg text-fg outline-none"
    role="dialog"
    aria-label="review hunk"
    tabindex="-1"
    bind:this={rootEl}
    onkeydown={key}
>
    <!-- header -->
    <div class="flex shrink-0 items-center gap-3 border-b border-line/15 px-5 py-3">
        <span class={"text-lg " + (TONE[hunk.state] ?? "text-lo")}>{GLYPH[hunk.state] ?? "○"}</span>
        <div class="min-w-0">
            <div class="truncate font-mono text-sm text-fg">
                {hunk.path}<span class="text-lo">:{hunk.startLine}</span>
            </div>
            <div class="text-[11px] uppercase tracking-wider {TONE[hunk.state] ?? 'text-lo'}">
                {hunk.state}
            </div>
        </div>
        <span class="flex-1"></span>
        <span class="font-mono text-xs text-lo">{pos.i} / {pos.n}</span>
        <button
            class="cursor-pointer rounded-md border border-line/15 px-2 py-0.5 font-mono text-xs text-dim hover:border-acc hover:text-fg"
            aria-label="previous hunk"
            onclick={() => onNav(-1)}>k ↑</button
        >
        <button
            class="cursor-pointer rounded-md border border-line/15 px-2 py-0.5 font-mono text-xs text-dim hover:border-acc hover:text-fg"
            aria-label="next hunk"
            onclick={() => onNav(1)}>j ↓</button
        >
        <button
            class="cursor-pointer rounded-md border border-line/15 px-2 py-0.5 font-mono text-xs text-dim hover:border-acc hover:text-fg"
            aria-label="close"
            onclick={onClose}>esc ✕</button
        >
    </div>

    <!-- body: analysis, then the diff as evidence -->
    <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4">
        <!-- Haiku's read of the hunk -->
        <div class="mb-4 rounded-xl border border-line/15 bg-raise px-4 py-3">
            {#if detail.summary || detail.category}
                <div class="mb-2 flex items-center gap-2">
                    {#if detail.category}
                        <span class="rounded-md bg-acc/15 px-2 py-0.5 text-[11px] font-semibold text-acc"
                            >{detail.category}</span
                        >
                    {/if}
                    {#if detail.score?.risk}
                        <span class="font-mono text-[11px] text-lo"
                            >risk {detail.score.risk}/5 · understand {detail.score
                                ?.understand ?? "–"}/5</span
                        >
                    {/if}
                </div>
                {#if detail.summary}
                    <p class="text-[13px] leading-relaxed text-fg">{detail.summary}</p>
                {/if}
                {#if detail.concerns && detail.concerns.length > 0}
                    <ul class="mt-2 flex flex-col gap-1">
                        {#each detail.concerns as c (c)}
                            <li class="flex gap-2 text-[12px] text-dim">
                                <span class="text-amber">→</span>{c}
                            </li>
                        {/each}
                    </ul>
                {/if}
            {:else}
                <p class="text-[12px] text-lo">
                    No analysis yet — run <span class="font-mono">rookctl review score-all</span> to
                    have Haiku triage each hunk.
                </p>
            {/if}
        </div>

        <!-- the diff, rendered from the stored patch -->
        <div class="overflow-x-auto rounded-xl border border-line/15 bg-sunken">
            {#each lines as ln, i (i)}
                <div class={"whitespace-pre px-4 font-mono text-[12px] leading-[1.5] " + lineClass(ln)}>
                    {ln || " "}
                </div>
            {/each}
        </div>
    </div>

    <!-- footer: note box + disposition -->
    <div class="shrink-0 border-t border-line/15 px-5 py-3">
        <div class="mb-3 flex items-start gap-2">
            <textarea
                class="min-h-9 flex-1 resize-y rounded-lg border border-line/15 bg-sunken px-3 py-2 text-[13px] text-fg focus:border-acc focus:outline-none"
                rows="1"
                placeholder="Drop a thought on this hunk — a question, a doubt, a gut reaction…"
                bind:value={note}
                oninput={() => (noteDone = false)}
            ></textarea>
            <button
                class="shrink-0 cursor-pointer rounded-lg border border-line/15 bg-fg/5 px-3 py-2 text-[12px] font-semibold text-fg hover:border-acc disabled:opacity-50"
                disabled={noteBusy || !note.trim()}
                onclick={addNote}>{noteDone ? "added ✓" : "Note"}</button
            >
        </div>
        {#if err}<div class="mb-2 text-xs text-red [overflow-wrap:anywhere]">{err}</div>{/if}
        <div class="flex gap-2">
            <button
                class="flex-1 cursor-pointer rounded-lg border border-grn/35 bg-grn/10 px-3 py-2 text-[13px] font-semibold text-grn hover:bg-grn/20"
                onclick={() => onDispose("approved")}>✓ Approve <span class="opacity-60">a</span></button
            >
            <button
                class="flex-1 cursor-pointer rounded-lg border border-red/35 bg-red/10 px-3 py-2 text-[13px] font-semibold text-red hover:bg-red/20"
                onclick={() => onDispose("rejected")}>✗ Reject <span class="opacity-60">r</span></button
            >
            <button
                class="flex-1 cursor-pointer rounded-lg border border-amber/35 bg-amber/10 px-3 py-2 text-[13px] font-semibold text-amber hover:bg-amber/20"
                onclick={() => onDispose("deferred")}>» Defer <span class="opacity-60">d</span></button
            >
        </div>
    </div>
</div>

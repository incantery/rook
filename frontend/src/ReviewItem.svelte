<!-- The bespoke hunk detail — the review context's quickfix HERO (center
     overlay, NOT the Monaco editor). One hunk as a decision object: Haiku's
     read of it up top (what it does / what to check), the hunk's own diff as
     evidence below, a note box (the whiteboard), and the context's verbs.
     Traversal and verbs dispatch through the quickfix state (qf) — the same
     path the list, the registry commands, and (by extension) agents use.
     Renders the diff itself from the stored patch body (anchorText), so
     review owes nothing to the editor. Styled with inline Tailwind (README
     decision 7); model of quality is ThreadPanel.svelte. -->
<script lang="ts">
    import type {HostAPI} from "./hostapi";
    import {qf, type QfAction} from "./quickfix.svelte";
    import {app} from "./state.svelte";

    let {
        id,
        pos,
        api,
        workspace,
        onTriage,
    }: {
        id: number;
        pos: {i: number; n: number}; // 1-based position for the "3 / 14" counter
        api: HostAPI;
        workspace: string;
        /** kick the host's Haiku triage fan-out for this review */
        onTriage: () => Promise<void>;
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
    // action tone → literal button classes (Tailwind scans source; never
    // interpolate class fragments)
    const TONE_BTN: Record<QfAction["tone"], string> = {
        grn: "border-grn/35 bg-grn/10 text-grn hover:bg-grn/20",
        red: "border-red/35 bg-red/10 text-red hover:bg-red/20",
        amber: "border-amber/35 bg-amber/10 text-amber hover:bg-amber/20",
        acc: "border-acc/35 bg-acc/10 text-acc hover:bg-acc/20",
    };

    const hunk = $derived(app.reviewHunks.find((h) => h.id === id));
    const detail = $derived(hunk?.detail ?? {});
    const lines = $derived((hunk?.anchorText ?? "").split("\n"));
    const actions = $derived(qf.context?.actions ?? []);

    let note = $state("");
    let noteBusy = $state(false);
    let noteDone = $state(false);
    let err = $state("");
    let rootEl = $state<HTMLDivElement | undefined>(undefined);

    // grab the keyboard when the overlay opens (and when it swaps hunks) so
    // the verbs land here, not in a terminal behind it. Also reclaims focus
    // when the quick-action modal closes over this hero.
    $effect(() => {
        id; // re-focus on hunk swap
        if (!app.quickActionOpen) rootEl?.focus();
    });

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
        if (!body || !hunk?.path || !hunk.startLine) return;
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

    function key(e: KeyboardEvent): void {
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        // don't hijack typing in the note box
        const el = e.target as HTMLElement;
        if (el.tagName === "TEXTAREA") {
            if (e.key === "Escape") (el as HTMLTextAreaElement).blur();
            return;
        }
        switch (e.key) {
            case "j":
            case "ArrowDown":
                qf.move(1);
                break;
            case "k":
            case "ArrowUp":
                qf.move(-1);
                break;
            case "Escape":
                qf.detailOpen = false;
                break;
            default: {
                if (!actions.some((a) => a.key === e.key)) return;
                void qf.act(e.key);
                break;
            }
        }
        e.preventDefault();
    }
</script>

{#if hunk}
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
            <span class={"text-lg " + (TONE[hunk.state] ?? "text-lo")}
                >{GLYPH[hunk.state] ?? "○"}</span
            >
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
                onclick={() => qf.move(-1)}>k ↑</button
            >
            <button
                class="cursor-pointer rounded-md border border-line/15 px-2 py-0.5 font-mono text-xs text-dim hover:border-acc hover:text-fg"
                aria-label="next hunk"
                onclick={() => qf.move(1)}>j ↓</button
            >
            <button
                class="cursor-pointer rounded-md border border-line/15 px-2 py-0.5 font-mono text-xs text-dim hover:border-acc hover:text-fg"
                aria-label="close"
                onclick={() => (qf.detailOpen = false)}>esc ✕</button
            >
        </div>

        <!-- body: analysis, then the diff as evidence -->
        <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4">
            <!-- Haiku's read of the hunk -->
            <div class="mb-4 rounded-xl border border-line/15 bg-raise px-4 py-3">
                {#if detail.summary || detail.category}
                    <div class="mb-2 flex items-center gap-2">
                        {#if detail.category}
                            <span
                                class="rounded-md bg-acc/15 px-2 py-0.5 text-[11px] font-semibold text-acc"
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
                {:else if app.reviewRoot?.scoring}
                    <p class="flex items-center gap-2 text-[12px] text-lo">
                        <span class="size-1.5 animate-pulse rounded-full bg-acc"></span>
                        Haiku is triaging the batch — analyses land here as they finish.
                    </p>
                {:else}
                    <div class="flex items-center gap-3">
                        <button
                            class="cursor-pointer rounded-lg border border-acc/35 bg-acc/15 px-3 py-1.5 text-[12px] font-semibold text-acc hover:bg-acc/25"
                            onclick={() => void onTriage()}>✦ Triage with Haiku</button
                        >
                        <span class="text-[12px] text-lo"
                            >score every hunk — risk, summary, what to check</span
                        >
                    </div>
                {/if}
            </div>

            <!-- the diff, rendered from the stored patch -->
            <div class="overflow-x-auto rounded-xl border border-line/15 bg-sunken">
                {#each lines as ln, i (i)}
                    <div
                        class={"whitespace-pre px-4 font-mono text-[12px] leading-[1.5] " +
                            lineClass(ln)}
                    >
                        {ln || " "}
                    </div>
                {/each}
            </div>
        </div>

        <!-- footer: note box + the context's verbs -->
        <div class="shrink-0 border-t border-line/15 px-5 py-3">
            <div class="mb-3 flex items-start gap-2">
                <textarea
                    class="min-h-9 flex-1 resize-y rounded-lg border border-line/15 bg-sunken px-3 py-2 text-[13px] text-fg focus:border-acc focus:outline-none"
                    rows="1"
                    placeholder="Drop a thought on this hunk — a question, a doubt, a gut reaction…"
                    bind:value={note}
                    oninput={() => (noteDone = false)}></textarea>
                <button
                    class="shrink-0 cursor-pointer rounded-lg border border-line/15 bg-fg/5 px-3 py-2 text-[12px] font-semibold text-fg hover:border-acc disabled:opacity-50"
                    disabled={noteBusy || !note.trim()}
                    onclick={addNote}>{noteDone ? "added ✓" : "Note"}</button
                >
            </div>
            {#if err}<div class="mb-2 text-xs text-red [overflow-wrap:anywhere]">{err}</div>{/if}
            <div class="flex gap-2">
                {#each actions as act (act.key)}
                    <button
                        class={"flex-1 cursor-pointer rounded-lg border px-3 py-2 text-[13px] font-semibold " +
                            TONE_BTN[act.tone]}
                        onclick={() => void qf.act(act.key)}
                        >{act.label} <span class="opacity-60">{act.key}</span></button
                    >
                {/each}
            </div>
        </div>
    </div>
{/if}

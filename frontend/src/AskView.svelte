<!-- The ask form — an agent's question as a RUI, rendered in a split beside
     the pane that asked (askpane.svelte.ts wraps this behind PaneContent).
     One question at a time, keyboard-first with the review hero's vocabulary:
     j/k move, 1-9 pick, space toggles (multi), Enter commits, Esc dismisses
     the whole ask. "Other" is the last row — picking it opens a text input,
     the user's own words ride the answer as `other`; a question with no
     options at all IS that input. Every keyboard path has a pointer twin:
     rows click, and multi-select commits with the Send button, because a
     phone has no Enter key worth the name. The rules about what an answer
     means live in askform.ts — this file is state and pixels. Styled with
     inline Tailwind (README decision 7). -->
<script lang="ts">
    import {untrack} from "svelte";

    import {
        canSend,
        enterPicks,
        formQuestion,
        initialCursor,
        initialPicks,
        shapeAnswer,
        toggle,
        type AskAnswer,
        type AskQuestion,
    } from "./askform";

    let {
        questions,
        onAnswer,
        onCancel,
    }: {
        questions: AskQuestion[];
        /** every question decided — the blocked asker gets this */
        onAnswer: (answers: AskAnswer[]) => void;
        /** Esc — the asker sees {canceled:true} */
        onCancel: () => void;
    } = $props();

    // the first question's shape, read once to seed the state below — the
    // questions prop never changes identity for a mounted ask
    const first = untrack(() => formQuestion(questions[0]));

    let qi = $state(0);
    let sel = $state(initialCursor(first));
    /** picked option indexes for the CURRENT question (multi accumulates) */
    let picked = $state<Set<number>>(initialPicks(first));
    /** has the user toggled anything here? Enter's meaning turns on it */
    let touched = $state(false);
    let otherOpen = $state(first.freeText);
    let otherText = $state("");
    let done = $state(false);
    const answers: AskAnswer[] = [];

    let rootEl = $state<HTMLDivElement | undefined>(undefined);
    let otherEl = $state<HTMLInputElement | undefined>(undefined);

    const q = $derived(formQuestion(questions[qi]));
    /** the focused row's artifact, if it brought one */
    const preview = $derived(sel < q.options.length ? q.options[sel]?.preview : undefined);
    /** any preview in this question widens the body into two columns */
    const hasPreviews = $derived(q.options.some((o) => o.preview));
    const sendable = $derived(canSend(q, picked, otherText));

    // the keyboard lands here when the pane opens and when questions advance
    $effect(() => {
        void qi;
        if (otherOpen) otherEl?.focus();
        else rootEl?.focus();
    });

    function commitQuestion(): void {
        answers.push(shapeAnswer(q, picked, otherText));
        if (qi + 1 < questions.length) {
            const next = formQuestion(questions[qi + 1]);
            qi += 1;
            sel = initialCursor(next);
            picked = initialPicks(next);
            touched = false;
            otherOpen = next.freeText;
            otherText = "";
        } else {
            done = true;
            onAnswer(answers);
        }
    }

    /** land on a row: options pick (single-select commits), Other opens text */
    function choose(i: number): void {
        sel = i;
        if (i === q.otherIdx) {
            otherOpen = true;
            return;
        }
        if (q.multi) {
            picked = toggle(picked, i);
            touched = true;
        } else {
            picked = new Set([i]);
            commitQuestion();
        }
    }

    /** the pointer's Enter — multi and free-text have no other way home */
    function send(): void {
        if (!sendable) return;
        commitQuestion();
    }

    function key(e: KeyboardEvent): void {
        if (done || e.metaKey || e.ctrlKey || e.altKey) return;
        const el = e.target as HTMLElement;
        if (el.tagName === "INPUT") {
            // typing the "other" answer: Enter commits it, Esc backs out —
            // except in a free-text question, where there is no row list
            // behind the input and Esc can only mean "dismiss the ask"
            if (e.key === "Enter") {
                if (sendable) commitQuestion();
                e.preventDefault();
            } else if (e.key === "Escape") {
                if (q.freeText) {
                    onCancel();
                } else {
                    otherOpen = false;
                    rootEl?.focus();
                }
                e.preventDefault();
            }
            e.stopPropagation();
            return;
        }
        switch (e.key) {
            case "j":
            case "ArrowDown":
                sel = Math.min(sel + 1, q.rowCount - 1);
                break;
            case "k":
            case "ArrowUp":
                sel = Math.max(sel - 1, 0);
                break;
            case " ":
                if (q.multi && sel !== q.otherIdx) choose(sel);
                break;
            case "Enter":
                if (q.multi && sel !== q.otherIdx) {
                    picked = enterPicks(picked, touched, sel);
                    commitQuestion();
                } else {
                    choose(sel);
                }
                break;
            case "Escape":
                onCancel();
                break;
            default: {
                const n = Number.parseInt(e.key, 10);
                if (!Number.isInteger(n) || n < 1 || n > q.rowCount) return;
                choose(n - 1);
                break;
            }
        }
        e.preventDefault();
    }
</script>

<div
    class="flex h-full flex-col overflow-hidden bg-bg text-fg outline-none"
    role="dialog"
    aria-label="agent question"
    tabindex="-1"
    data-ask-root
    bind:this={rootEl}
    onkeydown={key}
>
    {#if !done}
        <!-- header: who's asking + progress -->
        <div class="flex shrink-0 items-center gap-3 border-b border-line/15 px-4 py-3">
            <span class="size-2 animate-pulse rounded-full bg-acc"></span>
            <div class="min-w-0 flex-1">
                <div class="text-[0.6875rem] uppercase tracking-wider text-lo">
                    claude is asking
                </div>
                {#if q.header}
                    <span
                        class="mt-1 inline-block rounded-md bg-acc/15 px-2 py-0.5 text-[0.6875rem] font-semibold text-acc"
                        >{q.header}</span
                    >
                {/if}
            </div>
            {#if questions.length > 1}
                <span class="font-mono text-xs text-lo">{qi + 1} / {questions.length}</span>
            {/if}
        </div>

        <!-- the question, then its options (and their artifacts, if any) -->
        <div class="@container min-h-0 flex-1 overflow-y-auto px-4 py-5">
            <div class={"mx-auto w-full " + (hasPreviews ? "max-w-5xl" : "max-w-xl")}>
                <p class="mb-4 text-[0.9375rem] leading-relaxed text-fg">{q.question}</p>
                <div class={"grid gap-4 " + (hasPreviews ? "@3xl:grid-cols-2" : "")}>
                    <div class="flex min-w-0 flex-col gap-1.5" role="listbox" aria-label="options">
                        {#each q.options as opt, i}
                            <button
                                class={"flex cursor-pointer items-start gap-3 rounded-lg border px-3 py-2 text-left " +
                                    (i === sel
                                        ? "border-acc/50 bg-acc/10"
                                        : "border-line/15 bg-transparent hover:border-line/40 hover:bg-fg/5")}
                                role="option"
                                aria-selected={picked.has(i)}
                                onclick={() => choose(i)}
                            >
                                <span
                                    class="mt-0.5 rounded border border-line/25 px-1.5 font-mono text-[0.6875rem] text-lo"
                                    >{i + 1}</span
                                >
                                {#if q.multi}
                                    <!-- the mode, visible before you touch it -->
                                    <span
                                        class={"mt-px font-mono text-[0.8125rem] " +
                                            (picked.has(i) ? "text-grn" : "text-lo")}
                                        aria-hidden="true">{picked.has(i) ? "☑" : "☐"}</span
                                    >
                                {/if}
                                <span class="min-w-0">
                                    <span class="block text-[0.8125rem] font-semibold text-fg">
                                        {#if !q.multi && picked.has(i)}<span class="text-grn"
                                                >✓</span
                                            >{/if}
                                        {opt.label}
                                        {#if opt.recommended}
                                            <span
                                                class="ml-1 rounded bg-acc/15 px-1.5 py-0.5 text-[0.625rem] font-semibold uppercase tracking-wide text-acc"
                                                >rec</span
                                            >
                                        {/if}
                                    </span>
                                    {#if opt.description}
                                        <span class="block text-[0.75rem] leading-snug text-dim"
                                            >{opt.description}</span
                                        >
                                    {/if}
                                </span>
                            </button>
                        {/each}

                        <!-- the escape hatch: the user's own words. A question
                             with no options is nothing but this. -->
                        {#if otherOpen}
                            <div
                                class="flex items-center gap-3 rounded-lg border border-acc/50 bg-acc/10 px-3 py-2"
                            >
                                {#if !q.freeText}
                                    <span
                                        class="rounded border border-line/25 px-1.5 font-mono text-[0.6875rem] text-lo"
                                        >{q.otherIdx + 1}</span
                                    >
                                {/if}
                                <input
                                    class="min-w-0 flex-1 bg-transparent text-[0.8125rem] text-fg placeholder:text-lo focus:outline-none"
                                    placeholder="Type your own answer — Enter sends it"
                                    bind:value={otherText}
                                    bind:this={otherEl}
                                />
                            </div>
                        {:else}
                            <button
                                class={"flex cursor-pointer items-center gap-3 rounded-lg border px-3 py-2 text-left " +
                                    (sel === q.otherIdx
                                        ? "border-acc/50 bg-acc/10"
                                        : "border-line/15 bg-transparent hover:border-line/40 hover:bg-fg/5")}
                                onclick={() => choose(q.otherIdx)}
                            >
                                <span
                                    class="rounded border border-line/25 px-1.5 font-mono text-[0.6875rem] text-lo"
                                    >{q.otherIdx + 1}</span
                                >
                                <span class="text-[0.8125rem] text-dim">Other…</span>
                            </button>
                        {/if}
                    </div>

                    {#if hasPreviews}
                        <!-- the focused row's artifact, verbatim: what the
                             description can only gesture at -->
                        <div class="min-w-0">
                            {#if preview}
                                <pre
                                    data-ask-preview
                                    class="max-h-[60vh] overflow-auto rounded-lg border border-line/15 bg-fg/5 px-3 py-2 font-mono text-[0.75rem] leading-snug text-fg">{preview}</pre>
                            {:else}
                                <div
                                    class="rounded-lg border border-dashed border-line/15 px-3 py-2 text-[0.75rem] text-lo"
                                >
                                    no preview for this option
                                </div>
                            {/if}
                        </div>
                    {/if}
                </div>
            </div>
        </div>

        <!-- footer: the keyboard contract, and the pointer's way out -->
        <div
            class="flex shrink-0 items-center gap-3 border-t border-line/15 px-4 py-2 font-mono text-[0.6875rem] text-lo"
        >
            {#if !q.freeText}
                <span><span class="text-dim">j/k</span> move</span>
                <span><span class="text-dim">1-{q.rowCount}</span> pick</span>
            {/if}
            {#if q.multi}
                <span><span class="text-dim">space</span> toggle</span>
            {/if}
            <span><span class="text-dim">↵</span> send</span>
            <span class="flex-1"></span>
            {#if q.multi || q.freeText || otherOpen}
                <!-- multi and free-text never commit on a click, so without
                     this there is no pointer-only path to an answer -->
                <button
                    class={"rounded-md border px-2 py-0.5 font-semibold " +
                        (sendable
                            ? "cursor-pointer border-acc/50 bg-acc/15 text-acc hover:bg-acc/25"
                            : "cursor-not-allowed border-line/15 text-lo opacity-60")}
                    disabled={!sendable}
                    data-ask-send
                    onclick={send}
                >
                    {q.multi && picked.size === 0 && !otherText.trim() ? "none of these" : "send"}
                </button>
            {/if}
            <span><span class="text-dim">esc</span> dismiss</span>
        </div>
    {:else}
        <div class="flex h-full items-center justify-center text-[0.8125rem] text-lo">
            answered — claude has it
        </div>
    {/if}
</div>

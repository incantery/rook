<!-- The ask form — an agent's question as a RUI, rendered in a split beside
     the pane that asked (askpane.svelte.ts wraps this behind PaneContent).
     One question at a time, keyboard-first with the review hero's vocabulary:
     j/k move, 1-9 pick, space toggles (multi), Enter commits, Esc dismisses
     the whole ask. "Other" is the last row — picking it opens a text input,
     the user's own words ride the answer as `other`. Styled with inline
     Tailwind (README decision 7). -->
<script lang="ts">
    import type {AskQuestion} from "./term/manager";

    export interface AskAnswer {
        question: string;
        header?: string;
        selected: string[];
        other?: string;
    }

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

    let qi = $state(0);
    let sel = $state(0);
    /** picked option indexes for the CURRENT question (multi accumulates) */
    let picked = $state<Set<number>>(new Set());
    let otherOpen = $state(false);
    let otherText = $state("");
    let done = $state(false);
    const answers: AskAnswer[] = [];

    let rootEl = $state<HTMLDivElement | undefined>(undefined);
    let otherEl = $state<HTMLInputElement | undefined>(undefined);

    const q = $derived(questions[qi]);
    /** option rows plus the trailing "Other…" row */
    const rowCount = $derived((q?.options.length ?? 0) + 1);
    const otherIdx = $derived(q?.options.length ?? 0);

    // the keyboard lands here when the pane opens and when questions advance
    $effect(() => {
        void qi;
        if (otherOpen) otherEl?.focus();
        else rootEl?.focus();
    });

    function commitQuestion(): void {
        if (!q) return;
        const selected = [...picked].sort((a, b) => a - b).map((i) => q.options[i].label);
        const other = otherText.trim();
        answers.push({
            question: q.question,
            header: q.header,
            selected,
            ...(other ? {other} : {}),
        });
        if (qi + 1 < questions.length) {
            qi += 1;
            sel = 0;
            picked = new Set();
            otherOpen = false;
            otherText = "";
        } else {
            done = true;
            onAnswer(answers);
        }
    }

    /** land on a row: options pick (single-select commits), Other opens text */
    function choose(i: number): void {
        if (!q) return;
        sel = i;
        if (i === otherIdx) {
            otherOpen = true;
            return;
        }
        if (q.multiSelect) {
            const next = new Set(picked);
            if (next.has(i)) next.delete(i);
            else next.add(i);
            picked = next;
        } else {
            picked = new Set([i]);
            commitQuestion();
        }
    }

    function key(e: KeyboardEvent): void {
        if (done || e.metaKey || e.ctrlKey || e.altKey) return;
        const el = e.target as HTMLElement;
        if (el.tagName === "INPUT") {
            // typing the "other" answer: Enter commits it, Esc backs out
            if (e.key === "Enter") {
                if (otherText.trim()) commitQuestion();
                e.preventDefault();
            } else if (e.key === "Escape") {
                otherOpen = false;
                rootEl?.focus();
                e.preventDefault();
            }
            e.stopPropagation();
            return;
        }
        switch (e.key) {
            case "j":
            case "ArrowDown":
                sel = Math.min(sel + 1, rowCount - 1);
                break;
            case "k":
            case "ArrowUp":
                sel = Math.max(sel - 1, 0);
                break;
            case " ":
                if (q?.multiSelect && sel !== otherIdx) choose(sel);
                break;
            case "Enter":
                if (q?.multiSelect && sel !== otherIdx) {
                    // Enter always progresses: none picked yet → pick this one
                    if (picked.size === 0) picked = new Set([sel]);
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
                if (!Number.isInteger(n) || n < 1 || n > rowCount) return;
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
    {#if q && !done}
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

        <!-- the question, then its options -->
        <div class="min-h-0 flex-1 overflow-y-auto px-4 py-5">
            <div class="mx-auto w-full max-w-xl">
                <p class="mb-4 text-[0.9375rem] leading-relaxed text-fg">{q.question}</p>
                <div class="flex flex-col gap-1.5" role="listbox" aria-label="options">
                    {#each q.options as opt, i (opt.label)}
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
                            <span class="min-w-0">
                                <span class="block text-[0.8125rem] font-semibold text-fg">
                                    {#if picked.has(i)}<span class="text-grn">✓</span>{/if}
                                    {opt.label}
                                </span>
                                {#if opt.description}
                                    <span class="block text-[0.75rem] leading-snug text-dim"
                                        >{opt.description}</span
                                    >
                                {/if}
                            </span>
                        </button>
                    {/each}

                    <!-- the escape hatch: the user's own words -->
                    {#if otherOpen}
                        <div
                            class="flex items-center gap-3 rounded-lg border border-acc/50 bg-acc/10 px-3 py-2"
                        >
                            <span
                                class="rounded border border-line/25 px-1.5 font-mono text-[0.6875rem] text-lo"
                                >{otherIdx + 1}</span
                            >
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
                                (sel === otherIdx
                                    ? "border-acc/50 bg-acc/10"
                                    : "border-line/15 bg-transparent hover:border-line/40 hover:bg-fg/5")}
                            onclick={() => choose(otherIdx)}
                        >
                            <span
                                class="rounded border border-line/25 px-1.5 font-mono text-[0.6875rem] text-lo"
                                >{otherIdx + 1}</span
                            >
                            <span class="text-[0.8125rem] text-dim">Other…</span>
                        </button>
                    {/if}
                </div>
            </div>
        </div>

        <!-- footer: the keyboard contract -->
        <div
            class="flex shrink-0 items-center gap-3 border-t border-line/15 px-4 py-2 font-mono text-[0.6875rem] text-lo"
        >
            <span><span class="text-dim">j/k</span> move</span>
            <span><span class="text-dim">1-{rowCount}</span> pick</span>
            {#if q.multiSelect}
                <span><span class="text-dim">space</span> toggle</span>
                <span><span class="text-dim">↵</span> send</span>
            {:else}
                <span><span class="text-dim">↵</span> send</span>
            {/if}
            <span class="flex-1"></span>
            <span><span class="text-dim">esc</span> dismiss</span>
        </div>
    {:else}
        <div class="flex h-full items-center justify-center text-[0.8125rem] text-lo">
            answered — claude has it
        </div>
    {/if}
</div>

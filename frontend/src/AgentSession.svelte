<script lang="ts">
    /** The agent session view: a claude session rendered as a conversation
     *  rather than as a terminal (docs/agent.md, amendment 2026-07-15).
     *
     *  This is the 90% surface. The pty is still there and still real —
     *  `jump` goes to it, and everything rook has not reimplemented still
     *  works there. That is the whole bargain: this is not a replacement for
     *  the TUI, it is the view you use when you are not in it.
     *
     *  Dumb by design: every decision lives in agentview.ts, which is tested
     *  against the shapes claude actually writes. */
    import {onMount} from "svelte";

    import {
        build,
        outstanding,
        pickerOptions,
        summarize,
        type Item,
        type ToolCall,
    } from "./agentview";
    import {HostError, type AgentStatus, type HostAPI, type TranscriptRecord} from "./hostapi";
    import {ago} from "./util";

    let {
        api,
        session,
        onjump,
    }: {
        api: HostAPI;
        session: string;
        onjump?: () => void;
    } = $props();

    const WINDOW = 200;

    let records = $state<TranscriptRecord[]>([]);
    let status = $state<AgentStatus | null>(null);
    let more = $state(false);
    let err = $state("");
    let loading = $state(true);
    let paging = $state(false);
    let open = $state<Record<string, boolean>>({});
    let scroller = $state<HTMLElement | null>(null);
    /** stick to the bottom unless the reader has scrolled up to read */
    let pinned = true;

    const items = $derived(build(records));

    async function refresh() {
        try {
            const r = await api.agentTranscript(session, WINDOW);
            records = r.records;
            status = r.status ?? null;
            more = r.more;
            err = "";
        } catch (e) {
            // A 404 is not "the host is down". rook-host outlives the app,
            // and `make dev` deliberately rides the running daemon instead of
            // replacing it (internal/hostclient/service.go) — so the endpoint
            // is missing far more often than the session is. Say the thing
            // that gets someone unstuck; a raw "404 not found" costs an hour.
            if (e instanceof HostError && e.status === 404) {
                err =
                    "no transcript — this rook-host may predate the session view. " +
                    "Restart the daemon (an unstamped build never replaces it).";
            } else {
                // keep the last good render: the host is briefly unreachable
                // far more often than it is broken
                err = String(e);
            }
        } finally {
            loading = false;
        }
    }

    /** Page into the past. The first record's offset is the cursor. */
    async function older() {
        if (paging || !more || records.length === 0) return;
        paging = true;
        const before = records[0].offset;
        const keepHeight = scroller?.scrollHeight ?? 0;
        try {
            const r = await api.agentTranscript(session, WINDOW, before);
            records = [...r.records, ...records];
            more = r.more;
            // hold the reader's place: new content above must not move what
            // they are looking at
            if (scroller) scroller.scrollTop += scroller.scrollHeight - keepHeight;
        } catch (e) {
            err = String(e);
        } finally {
            paging = false;
        }
    }

    function onScroll() {
        if (!scroller) return;
        const gap = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight;
        pinned = gap < 40;
    }

    $effect(() => {
        // re-read whenever the pane retargets to a different session
        void session;
        records = [];
        loading = true;
        pinned = true;
        void refresh();
    });

    $effect(() => {
        const t = setInterval(() => void refresh(), 2000);
        return () => clearInterval(t);
    });

    // follow the tail as the agent works, unless the reader has scrolled away
    $effect(() => {
        void items;
        if (pinned && scroller) scroller.scrollTop = scroller.scrollHeight;
    });

    onMount(() => {
        if (scroller) scroller.scrollTop = scroller.scrollHeight;
    });

    /** Tailwind scans source for literal strings, so these must never be
     *  built by interpolation. */
    const STATE_TEXT: Record<string, string> = {
        working: "text-grn",
        needs_input: "text-amber",
        quiet: "text-lo",
    };
    const STATE_BG: Record<string, string> = {
        working: "bg-grn",
        needs_input: "bg-amber",
        quiet: "bg-lo",
    };
    const STATE_LABEL: Record<string, string> = {
        working: "working",
        needs_input: "needs you",
        quiet: "quiet",
    };

    function tsOf(it: Item): string {
        return it.ts ? ago(it.ts) : "";
    }

    function took(c: ToolCall): string {
        if (c.ms === null) return "";
        return c.ms < 1000 ? `${c.ms}ms` : `${(c.ms / 1000).toFixed(1)}s`;
    }

    function bodyOf(c: ToolCall): string {
        if (!c.result) return "";
        return c.result.content;
    }
</script>

<div class="flex h-full min-h-0 flex-col bg-bg text-fg">
    <header class="flex shrink-0 items-center gap-2 border-b border-line/15 px-3 py-2">
        {#if status}
            <span class={"size-2 shrink-0 rounded-full " + (STATE_BG[status.state] ?? "bg-lo")}
            ></span>
            <span
                class={"text-[10px] font-bold uppercase tracking-wider " +
                    (STATE_TEXT[status.state] ?? "text-lo")}
            >
                {STATE_LABEL[status.state] ?? status.state}
            </span>
        {/if}
        <span class="min-w-0 flex-1 truncate text-xs text-dim">
            {status?.title || session}
        </span>
        {#if status?.model}
            <span class="shrink-0 font-mono text-[10px] text-lo">{status.model}</span>
        {/if}
        {#if onjump}
            <button
                class="shrink-0 cursor-pointer rounded-md border border-line/30 px-2 py-0.5 font-mono text-[10px] text-dim hover:bg-fg/5"
                onclick={onjump}
                title="Jump to the live terminal">terminal ↗</button
            >
        {/if}
    </header>

    {#if err}
        <div
            class="shrink-0 border-b border-red/30 bg-red/10 px-3 py-1 font-mono text-[10px] text-red"
        >
            {err}
        </div>
    {/if}

    <div bind:this={scroller} onscroll={onScroll} class="min-h-0 flex-1 overflow-y-auto px-3 py-2">
        {#if loading}
            <div class="py-8 text-center text-xs text-lo">reading transcript…</div>
        {:else if items.length === 0}
            <div class="py-8 text-center text-xs text-lo">nothing in this session yet</div>
        {:else}
            {#if more}
                <button
                    class="mb-2 w-full cursor-pointer rounded-lg border border-line/15 py-1.5 text-[11px] text-dim hover:bg-fg/5 disabled:opacity-50"
                    disabled={paging}
                    onclick={older}>{paging ? "loading…" : "older"}</button
                >
            {/if}

            {#each items as it (it.key)}
                {#if it.kind === "prompt"}
                    <div class="mt-3 rounded-xl border border-acc/30 bg-acc/5 px-3 py-2">
                        <div class="mb-1 flex items-center gap-2">
                            <span class="text-[10px] font-bold uppercase tracking-wider text-acc"
                                >you</span
                            >
                            <span class="font-mono text-[10px] text-lo">{tsOf(it)}</span>
                        </div>
                        <div class="whitespace-pre-wrap break-words text-[13px] text-fg">
                            {it.text}
                        </div>
                    </div>
                {:else if it.kind === "say"}
                    <div
                        class="mt-3 whitespace-pre-wrap break-words text-[13px] leading-relaxed text-fg"
                    >
                        {it.text}
                    </div>
                {:else if it.kind === "tool"}
                    {@const c = it.call}
                    {@const pending = outstanding(c)}
                    {@const opts = c.name === "AskUserQuestion" ? pickerOptions(c.input) : []}
                    <div
                        class={"mt-1.5 overflow-hidden rounded-lg border " +
                            (pending
                                ? "border-amber/40 bg-amber/5"
                                : c.result?.isError
                                  ? "border-red/30 bg-red/5"
                                  : "border-line/15 bg-fg/[0.03]")}
                    >
                        <div
                            class="flex cursor-pointer items-center gap-2 px-2.5 py-1.5"
                            role="button"
                            tabindex="0"
                            onclick={() => (open[it.key] = !open[it.key])}
                            onkeydown={(e) => {
                                if (e.key === "Enter" || e.key === " ") {
                                    e.preventDefault();
                                    open[it.key] = !open[it.key];
                                }
                            }}
                        >
                            <span
                                class={"shrink-0 font-mono text-[10px] font-bold " +
                                    (pending
                                        ? "text-amber"
                                        : c.result?.isError
                                          ? "text-red"
                                          : "text-magenta")}
                            >
                                {c.name || "↩"}
                            </span>
                            <span class="min-w-0 flex-1 truncate font-mono text-[11px] text-dim">
                                {c.name ? summarize(c.name, c.input) : bodyOf(c).split("\n")[0]}
                            </span>
                            {#if pending}
                                <!-- the signal agentmon could not carry: a call
                                     with no result yet. An AskUserQuestion has
                                     no long-running variant, so an outstanding
                                     one is a person who has not answered. -->
                                <span class="shrink-0 font-mono text-[10px] text-amber"
                                    >waiting…</span
                                >
                            {:else}
                                <span class="shrink-0 font-mono text-[10px] text-lo">{took(c)}</span
                                >
                            {/if}
                        </div>

                        {#if opts.length > 0}
                            <div class="border-t border-line/15 px-2.5 py-2">
                                {#each opts as o, i (o.label)}
                                    <div class="mb-1 last:mb-0">
                                        <span class="font-mono text-[11px] text-fg"
                                            >{i + 1}) {o.label}</span
                                        >
                                        {#if o.description}
                                            <div class="ml-4 text-[11px] leading-snug text-lo">
                                                {o.description}
                                            </div>
                                        {/if}
                                    </div>
                                {/each}
                                <div class="mt-1.5 font-mono text-[10px] text-lo">
                                    rook will not type into a picker — jump to answer
                                </div>
                            </div>
                        {:else if open[it.key] && (c.input !== undefined || c.result)}
                            <div class="border-t border-line/15 px-2.5 py-2">
                                {#if c.input !== undefined}
                                    <pre
                                        class="mb-2 overflow-x-auto whitespace-pre-wrap break-words font-mono text-[10px] text-dim">{JSON.stringify(
                                            c.input,
                                            null,
                                            2,
                                        )}</pre>
                                {/if}
                                {#if c.result}
                                    <pre
                                        class={"max-h-80 overflow-auto whitespace-pre-wrap break-words font-mono text-[10px] " +
                                            (c.result.isError ? "text-red" : "text-lo")}>{bodyOf(
                                            c,
                                        )}</pre>
                                {/if}
                            </div>
                        {/if}
                    </div>
                {:else if it.kind === "turn"}
                    <div class="my-3 flex items-center gap-2">
                        <div class="h-px flex-1 bg-line/15"></div>
                        <span class="font-mono text-[10px] text-lo">
                            turn ended{it.ms ? ` · ${(it.ms / 1000).toFixed(1)}s` : ""}
                        </span>
                        <div class="h-px flex-1 bg-line/15"></div>
                    </div>
                {/if}
            {/each}
        {/if}
    </div>

    {#if status?.state === "needs_input" && status.ask}
        <div class="shrink-0 border-t border-amber/30 bg-amber/5 px-3 py-2">
            <div class="mb-0.5 text-[10px] font-bold uppercase tracking-wider text-amber">
                waiting on you
            </div>
            <div class="line-clamp-3 text-[12px] text-fg">{status.ask}</div>
        </div>
    {/if}
</div>

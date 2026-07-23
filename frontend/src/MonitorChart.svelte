<script lang="ts">
    // A multi-line time chart for the performance pane, built to the dataviz
    // method: 2px round lines, hairline solid gridlines one step off the
    // surface, clean y ticks, a crosshair that snaps to the nearest sample
    // with ONE tooltip listing every series (values lead, line-keys carry
    // identity), and text in text tokens — never the series color.
    interface Series {
        label: string;
        color: string;
        values: number[]; // aligned to times
    }
    let {
        title,
        times,
        series,
        fmt,
        height = 150,
    }: {
        title: string;
        times: number[]; // ms epoch, ascending
        series: Series[];
        fmt: (v: number) => string;
        height?: number;
    } = $props();

    let width = $state(0); // bind:clientWidth — pixel-true, no stroke distortion
    let hoverIdx = $state<number | null>(null);
    let hoverPx = $state(0);

    const PAD = {l: 46, r: 10, t: 8, b: 18};

    // niceCeil rounds up to 1/2/5 × 10^k so ticks are clean numbers.
    function niceCeil(v: number): number {
        if (v <= 0) return 1;
        const p = 10 ** Math.floor(Math.log10(v));
        for (const m of [1, 2, 5, 10]) {
            if (m * p >= v) return m * p;
        }
        return 10 * p;
    }

    const yMax = $derived(niceCeil(Math.max(1e-9, ...series.flatMap((s) => s.values))));
    const t0 = $derived(times[0] ?? 0);
    const t1 = $derived(times[times.length - 1] ?? 1);
    const plotW = $derived(Math.max(10, width - PAD.l - PAD.r));
    const plotH = $derived(height - PAD.t - PAD.b);

    function x(t: number): number {
        return PAD.l + (t1 === t0 ? 0 : ((t - t0) / (t1 - t0)) * plotW);
    }
    function y(v: number): number {
        return PAD.t + plotH - (v / yMax) * plotH;
    }
    function path(values: number[]): string {
        let d = "";
        for (let i = 0; i < times.length; i++) {
            d += `${i === 0 ? "M" : "L"}${x(times[i]).toFixed(1)},${y(values[i] ?? 0).toFixed(1)}`;
        }
        return d;
    }

    function clock(t: number): string {
        const d = new Date(t);
        return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
    }

    function onmove(e: PointerEvent): void {
        if (times.length < 2) return;
        const rect = (e.currentTarget as SVGElement).getBoundingClientRect();
        const px = e.clientX - rect.left;
        const t = t0 + ((px - PAD.l) / plotW) * (t1 - t0);
        let best = 0;
        for (let i = 1; i < times.length; i++) {
            if (Math.abs(times[i] - t) < Math.abs(times[best] - t)) best = i;
        }
        hoverIdx = best;
        hoverPx = x(times[best]);
    }
</script>

<div class="relative min-w-0" bind:clientWidth={width}>
    <div class="mb-1 flex items-baseline justify-between">
        <span class="text-[0.6875rem] font-medium text-dim">{title}</span>
        {#if hoverIdx !== null}
            <span class="text-[0.6875rem] tabular-nums text-lo">{clock(times[hoverIdx])}</span>
        {/if}
    </div>
    {#if times.length < 2}
        <div
            class="flex items-center justify-center text-[0.6875rem] text-lo"
            style:height="{height}px"
        >
            collecting samples…
        </div>
    {:else}
        <!-- svelte-ignore a11y_no_static_element_interactions -->
        <svg
            {height}
            width={Math.max(10, width)}
            onpointermove={onmove}
            onpointerleave={() => (hoverIdx = null)}
        >
            <!-- gridlines: hairline, solid, recessive; ticks are clean numbers -->
            {#each [0.5, 1] as f (f)}
                <line
                    x1={PAD.l}
                    x2={PAD.l + plotW}
                    y1={y(yMax * f)}
                    y2={y(yMax * f)}
                    class="stroke-line/25"
                    stroke-width="1"
                />
                <text
                    x={PAD.l - 6}
                    y={y(yMax * f) + 3}
                    text-anchor="end"
                    class="fill-lo text-[0.625rem] tabular-nums">{fmt(yMax * f)}</text
                >
            {/each}
            <line
                x1={PAD.l}
                x2={PAD.l + plotW}
                y1={y(0)}
                y2={y(0)}
                class="stroke-line/40"
                stroke-width="1"
            />
            <!-- time labels: start / end -->
            <text x={PAD.l} y={height - 4} class="fill-lo text-[0.625rem] tabular-nums"
                >{clock(t0)}</text
            >
            <text
                x={PAD.l + plotW}
                y={height - 4}
                text-anchor="end"
                class="fill-lo text-[0.625rem] tabular-nums">{clock(t1)}</text
            >
            <!-- the data: 2px lines, round join/cap -->
            {#each series as s (s.label)}
                <path
                    d={path(s.values)}
                    fill="none"
                    stroke={s.color}
                    stroke-width="2"
                    stroke-linejoin="round"
                    stroke-linecap="round"
                />
            {/each}
            <!-- crosshair: the reader aims at a time, not at a 2px line -->
            {#if hoverIdx !== null}
                <line
                    x1={hoverPx}
                    x2={hoverPx}
                    y1={PAD.t}
                    y2={PAD.t + plotH}
                    class="stroke-line/60"
                    stroke-width="1"
                />
                {#each series as s (s.label)}
                    <circle
                        cx={hoverPx}
                        cy={y(s.values[hoverIdx] ?? 0)}
                        r="3.5"
                        fill={s.color}
                        class="stroke-bg"
                        stroke-width="2"
                    />
                {/each}
            {/if}
        </svg>
        {#if hoverIdx !== null}
            <!-- one tooltip, every series: values lead, line-keys carry identity -->
            <div
                class="pointer-events-none absolute top-6 z-10 rounded border border-line/25 bg-overlay/95 px-2 py-1.5 shadow"
                style:left="{Math.min(Math.max(0, hoverPx + 8), Math.max(0, width - 150))}px"
            >
                {#each series as s (s.label)}
                    <div
                        class="flex items-center gap-1.5 whitespace-nowrap text-[0.6875rem] leading-4"
                    >
                        <span class="inline-block h-[2px] w-3" style:background={s.color}></span>
                        <span class="font-medium tabular-nums text-fg"
                            >{fmt(s.values[hoverIdx] ?? 0)}</span
                        >
                        <span class="text-dim">{s.label}</span>
                    </div>
                {/each}
            </div>
        {/if}
    {/if}
</div>

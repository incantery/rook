<script lang="ts">
    // The performance pane: rook's own cost vs the user's workload, over time
    // and live. Charts read the host monitor's stored series (30s cadence);
    // the table reads the live per-session breakdown (/runtime?detail=1) —
    // "how much is rook and how much is the migration", answered.
    import {onMount} from "svelte";
    import MonitorChart from "./MonitorChart.svelte";
    import {
        gaugeOf,
        shortBytes,
        type HostAPI,
        type RuntimeDetail,
        type StoredSample,
    } from "./hostapi";

    let {api}: {api: HostAPI} = $props();

    // The five buckets, in FIXED categorical slot order (never re-ordered by
    // rank — color follows the entity). Palette = the validated reference
    // instance, slots 1-5, stepped per surface mode; both modes pass the
    // dataviz gates on rook's default surfaces (dark #0f111a, light #fafafa).
    // Light mode's sub-3:1 slots are relieved by the table + tooltips.
    const BUCKETS = [
        {key: "workload", label: "workload", roles: ["workload"]},
        {key: "app", label: "app", roles: ["app"]},
        {key: "webkit", label: "webview", roles: ["webkit"]},
        {key: "host", label: "host", roles: ["host"]},
        {key: "agents", label: "agents", roles: ["coder", "agent"]},
    ] as const;
    const DARK = ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181"];
    const LIGHT = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4"];

    const RANGES = ["15m", "1h", "6h", "24h"] as const;
    let range = $state<(typeof RANGES)[number]>("15m");

    let detail = $state<RuntimeDetail | null>(null);
    let samples = $state<StoredSample[]>([]);
    let seriesStale = $state(false); // refetch keeps the frame, dimmed

    // dark or light chart palette follows the theme's surface luminance
    let dark = $state(true);
    function surfaceIsDark(): boolean {
        const bg = getComputedStyle(document.documentElement).getPropertyValue("--bg").trim();
        const m = /^#?([0-9a-f]{6})/i.exec(bg);
        if (!m) return true;
        const v = parseInt(m[1], 16);
        const lum =
            (0.2126 * ((v >> 16) & 0xff) + 0.7152 * ((v >> 8) & 0xff) + 0.0722 * (v & 0xff)) / 255;
        return lum < 0.5;
    }
    const colors = $derived(dark ? DARK : LIGHT);

    async function pollDetail(): Promise<void> {
        try {
            detail = await api.runtimeDetail();
            dark = surfaceIsDark();
        } catch {
            // host briefly unreachable — keep the last reading
        }
    }
    async function fetchSeries(): Promise<void> {
        seriesStale = true;
        try {
            samples = (await api.runtimeSeries(range)).series ?? [];
        } catch {
            // keep the stale chart rather than blanking it
        }
        seriesStale = false;
    }

    onMount(() => {
        void pollDetail();
        const live = setInterval(() => void pollDetail(), 3000);
        const hist = setInterval(() => void fetchSeries(), 30_000);
        return () => {
            clearInterval(live);
            clearInterval(hist);
        };
    });
    $effect(() => {
        void range; // refetch when the range preset changes
        void fetchSeries();
    });

    /** Fold the stored samples of one metric into per-bucket series aligned on
     *  a shared time axis (the sampler writes every role at the same tick). */
    function bucketed(metric: string): {times: number[]; values: number[][]} {
        const byTime = new Map<number, Map<string, number>>();
        for (const s of samples) {
            if (s.metric !== metric) continue;
            const role = s.labels?.role;
            if (!role) continue;
            const t = Date.parse(s.at);
            let roles = byTime.get(t);
            if (!roles) byTime.set(t, (roles = new Map()));
            roles.set(role, (roles.get(role) ?? 0) + s.value);
        }
        const times = [...byTime.keys()].sort((a, b) => a - b);
        const values = BUCKETS.map((b) =>
            times.map((t) => {
                const roles = byTime.get(t);
                let v = 0;
                for (const r of b.roles) v += roles?.get(r) ?? 0;
                return v;
            }),
        );
        return {times, values};
    }
    const mem = $derived(bucketed("rook_process_rss_bytes"));
    const cpu = $derived(bucketed("rook_process_cpu_percent"));
    function chartSeries(values: number[][]): {label: string; color: string; values: number[]}[] {
        return BUCKETS.map((b, i) => ({label: b.label, color: colors[i], values: values[i]}));
    }

    // live headline numbers, from the same gauges the chip reads
    function live(metric: string, roles: readonly string[]): number {
        const g = detail?.gauges;
        if (!g) return 0;
        let v = 0;
        for (const r of roles) v += gaugeOf(g, metric, {role: r});
        return v;
    }
    const ROOK_ROLES = ["app", "webkit", "host", "coder", "agent"] as const;
    const tiles = $derived([
        {label: "workload memory", value: shortBytes(live("rook_process_rss_bytes", ["workload"]))},
        {label: "rook memory", value: shortBytes(live("rook_process_rss_bytes", ROOK_ROLES))},
        {label: "workload cpu", value: pct(live("rook_process_cpu_percent", ["workload"]))},
        {label: "rook cpu", value: pct(live("rook_process_cpu_percent", ROOK_ROLES))},
    ]);

    function pct(v: number): string {
        return `${v >= 100 ? Math.round(v) : v.toFixed(1)}%`;
    }
    function topProcs(s: {procs: {comm: string; rss: number}[] | null}): string {
        return (s.procs ?? [])
            .slice(0, 3)
            .map((p) => `${p.comm} ${shortBytes(p.rss)}`)
            .join(" · ");
    }
</script>

<div class="flex h-full flex-col gap-4 overflow-y-auto p-4" data-testid="monitor-pane">
    <!-- filters: one row, above everything they scope; range first -->
    <div class="flex items-center gap-1">
        <span class="mr-2 text-xs font-medium text-fg">performance</span>
        {#each RANGES as r (r)}
            <button
                class={[
                    "rounded border px-2 py-0.5 text-[0.6875rem]",
                    range === r
                        ? "border-acc/40 bg-acc/15 text-acc"
                        : "border-line/20 text-dim hover:bg-raise",
                ]}
                onclick={() => (range = r)}>{r}</button
            >
        {/each}
    </div>

    <!-- headline numbers: the split, at a glance -->
    <div class="grid grid-cols-4 gap-3">
        {#each tiles as t (t.label)}
            <div class="rounded border border-line/15 px-3 py-2">
                <div class="text-[0.6875rem] text-dim">{t.label}</div>
                <div class="text-lg font-semibold text-fg">{t.value}</div>
            </div>
        {/each}
    </div>

    <!-- one legend for both charts: same series, same fixed order -->
    <div class="flex items-center gap-3">
        {#each BUCKETS as b, i (b.key)}
            <span class="flex items-center gap-1.5 text-[0.6875rem] text-dim">
                <span class="inline-block h-[2px] w-3.5" style:background={colors[i]}></span>
                {b.label}
            </span>
        {/each}
    </div>

    <div class={["flex flex-col gap-4", seriesStale && "opacity-60"]}>
        <MonitorChart
            title="memory"
            times={mem.times}
            series={chartSeries(mem.values)}
            fmt={shortBytes}
        />
        <MonitorChart
            title="cpu (% of one core)"
            times={cpu.times}
            series={chartSeries(cpu.values)}
            fmt={(v) => `${Math.round(v)}%`}
        />
    </div>

    <!-- the table view: live, per session — which window is the migration -->
    <div>
        <div class="mb-1 text-[0.6875rem] font-medium text-dim">sessions, live</div>
        {#if !detail?.sessions?.length}
            <div class="text-[0.6875rem] text-lo">no sessions</div>
        {:else}
            <table class="w-full text-left text-[0.75rem]">
                <thead>
                    <tr class="text-[0.6875rem] text-lo">
                        <th class="py-1 pr-3 font-normal">session</th>
                        <th class="py-1 pr-3 font-normal">workspace</th>
                        <th class="py-1 pr-3 text-right font-normal">cpu</th>
                        <th class="py-1 pr-3 text-right font-normal">mem</th>
                        <th class="py-1 font-normal">top processes</th>
                    </tr>
                </thead>
                <tbody>
                    {#each detail.sessions as s (s.id)}
                        <tr class="border-t border-line/10 text-fg">
                            <td class="py-1 pr-3">{s.name}</td>
                            <td class="py-1 pr-3 text-dim">{s.workspace}</td>
                            <td class="py-1 pr-3 text-right tabular-nums">{pct(s.cpu)}</td>
                            <td class="py-1 pr-3 text-right tabular-nums">{shortBytes(s.rss)}</td>
                            <td class="py-1 text-dim">{topProcs(s)}</td>
                        </tr>
                    {/each}
                </tbody>
            </table>
        {/if}
    </div>
</div>

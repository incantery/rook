<!-- Experimental: opt-in flags for features mid-bake-off. Everything here is
     deliberately reversible and fails open — an experiment must never brick
     the daily driver. Flags live in localStorage (per-install, no config-file
     ceremony) and apply at boot, so toggling offers a reload. -->
<script lang="ts">
    import {
        activeRendererKind,
        rendererKind,
        setRendererKind,
        type RendererKind,
    } from "./term/vt/registry";

    let renderer = $state<RendererKind>(rendererKind());
    // a reload changes anything only if the choice differs from what this
    // session actually runs
    const dirty = $derived(renderer !== activeRendererKind());

    function choose(kind: RendererKind) {
        setRendererKind(kind);
        renderer = kind;
    }
</script>

<div class="max-w-2xl">
    <div class="mb-1 text-sm font-semibold text-fg">Terminal renderer</div>
    <p class="mb-3 text-xs text-dim">
        The DOM renderer is the default and the accessible one. The WebGL renderer (beamterm) is a
        performance experiment — typing latency measured lower and firehose output is cheaper to
        paint, but it is missing pieces: <span class="text-fg"
            >scrollback view, mouse support for TUI apps (Claude Code scroll, vim mouse), and
            screen-reader text</span
        >. If it fails to load, the DOM renderer takes over automatically.
    </p>

    <div class="flex flex-col gap-2">
        <label class="flex cursor-pointer items-start gap-2.5">
            <input
                type="radio"
                name="renderer"
                class="mt-0.5 accent-acc"
                checked={renderer === "dom"}
                onchange={() => choose("dom")}
            />
            <span>
                <span class="text-sm text-fg">DOM</span>
                <span class="ml-1.5 rounded border border-line/20 px-1.5 py-px text-[10px] text-lo"
                    >default</span
                >
                <span class="block text-xs text-dim">Full feature set. The safe choice.</span>
            </span>
        </label>
        <label class="flex cursor-pointer items-start gap-2.5">
            <input
                type="radio"
                name="renderer"
                class="mt-0.5 accent-acc"
                checked={renderer === "webgl"}
                onchange={() => choose("webgl")}
            />
            <span>
                <span class="text-sm text-fg">WebGL (beamterm)</span>
                <span
                    class="ml-1.5 rounded border border-amber/35 bg-amber/12 px-1.5 py-px text-[10px] text-amber"
                    >experimental</span
                >
                <span class="block text-xs text-dim">
                    GPU-rendered grid. Feels faster; incomplete. Switch back any time.
                </span>
            </span>
        </label>
    </div>

    {#if dirty}
        <div class="mt-4 flex items-center gap-3">
            <button
                class="cursor-pointer rounded-lg border border-acc/40 bg-acc/15 px-3 py-1.5 text-xs font-semibold text-acc hover:bg-acc/25"
                onclick={() => location.reload()}>Reload to apply</button
            >
            <span class="text-xs text-lo">the renderer is chosen at startup</span>
        </div>
    {/if}
</div>

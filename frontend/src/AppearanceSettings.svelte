<!-- Appearance: a read-only view of the config surface plus a LIVE theme
     preview. The app no longer writes config (ghostty model — the file is
     user-owned, hand-edited); this panel shows the effective values and
     points at ~/.config/rook/config.toml. Theme changes apply live so you
     can shop for one, then copy the config line to keep it. -->
<script lang="ts">
    import type {Config as ConfigModel} from "../bindings/github.com/incantery/rook/internal/config/models";
    import {themeService} from "./theme/service";
    import {effectiveKeybindRows} from "./keymap";

    let {cfg}: {cfg: ConfigModel} = $props();

    const themes = themeService.builtins();
    // svelte-ignore state_referenced_locally
    let theme = $state(cfg.theme || themeService.activeName());
    // live preview only — nothing is persisted, a reload reverts to config
    const previewing = $derived(theme !== (cfg.theme || themeService.activeName()));

    // svelte-ignore state_referenced_locally — seeded once; the shell reloads cfg on open
    const rows = effectiveKeybindRows(cfg.keybinds ?? {});
    // svelte-ignore state_referenced_locally
    const editorRows = Object.entries(cfg.editorKeybinds?.normal ?? {});
</script>

<div class="flex flex-col gap-4 p-4.5">
    <div class="border-b border-line/15 px-4.5 py-3.5 text-sm font-bold text-fg">Appearance</div>

    <div class="mx-4.5 rounded-lg border border-line/15 bg-sunken/50 px-3 py-2.5 text-xs text-dim">
        Settings live in <span class="font-mono text-fg">~/.config/rook/config.toml</span> — edit
        the file and press <span class="font-mono text-fg">` r</span> to reload. Every key is
        documented in <span class="font-mono text-fg">docs/config.sample.toml</span>.
    </div>

    <label class="my-2 flex items-center gap-2 px-4.5"
        ><span class="mb-1.5 block text-xs font-semibold text-dim">Theme</span>
        <select
            id="theme-select"
            class="box-border w-full min-w-0 flex-1 rounded-lg border border-line/15 bg-sunken/80 px-2.5 py-2 font-mono text-sm text-fg outline-none focus:border-acc"
            bind:value={theme}
            onchange={() => themeService.apply(theme)}
        >
            {#each themes as t (t)}
                <option value={t}>{t}</option>
            {/each}
        </select>
    </label>
    {#if previewing}
        <div class="px-4.5 text-xs text-dim">
            Previewing — to keep it, set
            <span class="font-mono text-fg">theme = "{theme}"</span> in your config.
        </div>
    {/if}

    <div class="my-2 flex flex-col gap-2 px-4.5 text-sm">
        <div class="flex items-center gap-2">
            <span class="w-32 text-xs font-semibold text-dim">Leader</span>
            <span class="font-mono text-fg">{cfg.leader || "`"}</span>
        </div>
        <div class="flex items-center gap-2">
            <span class="w-32 text-xs font-semibold text-dim">Editor leader</span>
            <span class="font-mono text-fg">{cfg.editorLeader || ","}</span>
        </div>
        <div class="flex items-center gap-2">
            <span class="w-32 text-xs font-semibold text-dim">Font family</span>
            <span class="font-mono text-fg">{cfg.fontFamily}</span>
        </div>
        <div class="flex items-center gap-2">
            <span class="w-32 text-xs font-semibold text-dim">Font size</span>
            <span class="font-mono text-fg">{cfg.fontSize}</span>
        </div>
    </div>

    <div class="border-b border-line/15 px-4.5 py-3.5 text-sm font-bold text-fg">Keybinds</div>
    <div class="flex flex-col gap-1.5 px-4.5 pb-3">
        {#each rows as row (row.trigger)}
            <div class="flex items-center gap-2 text-sm">
                <span class="w-44 font-mono text-fg">{row.trigger}</span>
                <span class="text-dim">{row.command}</span>
            </div>
        {/each}
    </div>

    {#if editorRows.length > 0}
        <div class="border-b border-line/15 px-4.5 py-3.5 text-sm font-bold text-fg">
            Editor keybinds (normal)
        </div>
        <div class="flex flex-col gap-1.5 px-4.5 pb-3">
            {#each editorRows as [trigger, command] (trigger)}
                <div class="flex items-center gap-2 text-sm">
                    <span class="w-44 font-mono text-fg">{trigger}</span>
                    <span class="text-dim">{command}</span>
                </div>
            {/each}
        </div>
    {/if}
</div>

<!-- Appearance: leader, pane font, and the keybind editor. These are read at
     boot (main.ts) and passed as props, so saving reloads the page to re-read.
     The keybind editor is trigger-centric — one row per bound trigger, seeded
     from effectiveKeybindRows so multi-trigger commands keep every binding —
     and reuses keymap.ts for parsing, conflict, reserved, and override math. -->
<script lang="ts">
    import {Call} from "@wailsio/runtime";
    import type {Config as ConfigModel} from "../bindings/github.com/incantery/rook/internal/config/models";
    import {themeService} from "./theme/service";
    import {
        DEFAULTS,
        effectiveKeybindRows,
        computeKeybindOverrides,
        triggerSig,
        isReservedTrigger,
        type KeybindRow,
    } from "./keymap";

    const SVC = "github.com/incantery/rook/internal/config.Service.";

    let {cfg}: {cfg: ConfigModel} = $props();

    const themes = themeService.builtins();
    // svelte-ignore state_referenced_locally
    let theme = $state(cfg.theme || themeService.activeName());
    // svelte-ignore state_referenced_locally
    let leader = $state(cfg.leader || "`");
    // svelte-ignore state_referenced_locally
    let fontFamily = $state(cfg.fontFamily || "");
    // svelte-ignore state_referenced_locally
    let fontSize = $state(cfg.fontSize || 18);
    // svelte-ignore state_referenced_locally — seeded once; the shell reloads cfg on open
    let rows = $state<KeybindRow[]>(effectiveKeybindRows(cfg.keybinds ?? {}));

    let error = $state("");
    let saved = $state(false);
    // index of the row currently capturing a chord, or -1
    let capturing = $state(-1);

    // the "add binding" command picker: every command that ships with a default
    const allCommands = [...new Set(DEFAULTS.map(([, c]) => c))].sort();
    let addCommand = $state("");

    // per-row problem: "reserved", "unparsable", or "conflict" (sig shared by
    // 2+ rows). Empty-trigger rows are ignored (dropped on save), not flagged.
    const problems = $derived.by(() => {
        const bySig = new Map<string, number[]>();
        const out: Record<number, string> = {};
        rows.forEach((r, i) => {
            if (!r.trigger) return; // unbound row — ignored on save
            if (isReservedTrigger(r.trigger)) {
                out[i] = "reserved";
                return;
            }
            const sig = triggerSig(r.trigger);
            if (sig == null) {
                out[i] = "unparsable";
                return;
            }
            bySig.set(sig, [...(bySig.get(sig) ?? []), i]);
        });
        for (const idxs of bySig.values()) {
            if (idxs.length > 1) for (const i of idxs) out[i] ??= "conflict";
        }
        return out;
    });
    const hasProblem = $derived(Object.keys(problems).length > 0);

    // Turn a keydown into a trigger string keymap.ts can parse. Named keys
    // (arrows) map to keymap's short names; bare modifiers wait for the real key.
    function triggerFromEvent(e: KeyboardEvent): string | null {
        const named: Record<string, string> = {
            arrowup: "up",
            arrowdown: "down",
            arrowleft: "left",
            arrowright: "right",
        };
        const base = named[e.key.toLowerCase()] ?? e.key.toLowerCase();
        if (["shift", "meta", "alt", "control"].includes(base)) return null;
        const mods: string[] = [];
        if (e.metaKey) mods.push("cmd");
        if (e.ctrlKey) mods.push("ctrl");
        if (e.altKey) mods.push("alt");
        if (e.shiftKey) mods.push("shift");
        return mods.length ? [...mods, base].join("+") : base;
    }

    function onCaptureKey(e: KeyboardEvent, i: number) {
        if (capturing !== i) return;
        e.preventDefault();
        e.stopPropagation(); // don't let Escape bubble to the shell (which would close Settings)
        if (e.key === "Escape") {
            capturing = -1;
            return;
        }
        const trigger = triggerFromEvent(e);
        if (trigger == null) return; // bare modifier — keep waiting
        rows[i] = {...rows[i], trigger};
        rows = [...rows];
        capturing = -1;
    }

    function removeRow(i: number) {
        capturing = -1; // structural edit shifts indices — cancel any in-progress capture
        rows = rows.filter((_, j) => j !== i);
    }

    function addRow() {
        if (!addCommand) return;
        capturing = -1;
        rows = [...rows, {command: addCommand, trigger: ""}];
        addCommand = "";
    }

    // Theme applies LIVE (the ThemeService re-colors chrome, terminals, and
    // Monaco at runtime) — no reload, unlike font/leader/keybinds. Persist the
    // choice surgically so it survives relaunch.
    async function applyTheme() {
        themeService.apply(theme);
        try {
            await Call.ByName(SVC + "SetConfig", {theme});
        } catch (err) {
            error = `theme save failed: ${err}`;
        }
    }

    async function save() {
        error = "";
        saved = false;
        if (hasProblem) {
            error = "resolve keybind conflicts before saving";
            return;
        }
        const size = Number(fontSize);
        if (!Number.isInteger(size) || size <= 0) {
            error = "font size must be a positive integer";
            return;
        }
        try {
            await Call.ByName(SVC + "SetConfig", {
                leader: leader.trim() || "`",
                fontFamily: fontFamily.trim(),
                fontSize: size,
                keybinds: computeKeybindOverrides(rows),
            });
            saved = true;
            // leader/font/keybinds are boot-cached — reload to re-read
            setTimeout(() => location.reload(), 300);
        } catch (err) {
            error = `save failed: ${err}`;
        }
    }
</script>

<div class="flex flex-col gap-4 p-4.5">
    <div class="border-b border-line/15 px-4.5 py-3.5 text-sm font-bold text-fg">Appearance</div>
    <label class="my-2 flex items-center gap-2"
        ><span class="mb-1.5 block text-xs font-semibold text-dim">Theme</span>
        <select
            id="theme-select"
            class="box-border w-full min-w-0 flex-1 rounded-lg border border-line/15 bg-sunken/80 px-2.5 py-2 font-mono text-sm text-fg outline-none focus:border-acc"
            bind:value={theme}
            onchange={() => void applyTheme()}
        >
            {#each themes as t (t)}
                <option value={t}>{t}</option>
            {/each}
        </select>
    </label>
    <label class="my-2 flex items-center gap-2"
        ><span class="mb-1.5 block text-xs font-semibold text-dim">Leader</span>
        <input
            type="text"
            class="box-border w-full min-w-0 flex-1 rounded-lg border border-line/15 bg-sunken/80 px-2.5 py-2 font-mono text-sm text-fg outline-none focus:border-acc"
            placeholder="` or ctrl+b"
            bind:value={leader}
            spellcheck="false"
            autocomplete="off"
        />
    </label>
    <label class="my-2 flex items-center gap-2"
        ><span class="mb-1.5 block text-xs font-semibold text-dim">Font family</span>
        <input
            type="text"
            class="box-border w-full min-w-0 flex-1 rounded-lg border border-line/15 bg-sunken/80 px-2.5 py-2 font-mono text-sm text-fg outline-none focus:border-acc"
            placeholder="Hack Nerd Font Mono"
            bind:value={fontFamily}
            spellcheck="false"
            autocomplete="off"
        />
    </label>
    <label class="my-2 flex items-center gap-2"
        ><span class="mb-1.5 block text-xs font-semibold text-dim">Font size</span>
        <input
            type="number"
            class="box-border w-full min-w-0 flex-1 rounded-lg border border-line/15 bg-sunken/80 px-2.5 py-2 font-mono text-sm text-fg outline-none focus:border-acc"
            min="6"
            max="72"
            bind:value={fontSize}
        />
    </label>

    <div class="border-b border-line/15 px-4.5 py-3.5 text-sm font-bold text-fg">Keybinds</div>
    {#each rows as row, i (i)}
        <div class="my-2 flex items-center gap-2">
            <span>{row.command}</span>
            <input
                type="text"
                class="box-border w-full min-w-0 flex-1 rounded-lg border border-line/15 bg-sunken/80 px-2.5 py-2 font-mono text-sm text-fg outline-none focus:border-acc"
                readonly
                value={capturing === i ? "press keys…" : row.trigger || "(unbound)"}
                onclick={() => (capturing = i)}
                onkeydown={(e) => onCaptureKey(e, i)}
                onblur={() => {
                    if (capturing === i) capturing = -1;
                }}
            />
            {#if problems[i]}<span class="text-red">⚠ {problems[i]}</span>{/if}
            <button
                class="flex cursor-pointer items-center gap-2 rounded-lg border border-line/15 bg-white/5 px-3 py-1.5 font-[inherit] text-xs font-semibold text-fg hover:bg-white/10"
                onclick={() => removeRow(i)}>Remove</button
            >
        </div>
    {/each}

    <div class="my-2 flex items-center gap-2">
        <select bind:value={addCommand}>
            <option value="">+ add binding…</option>
            {#each allCommands as c (c)}
                <option value={c}>{c}</option>
            {/each}
        </select>
        <button
            class="flex cursor-pointer items-center gap-2 rounded-lg border border-line/15 bg-white/5 px-3 py-1.5 font-[inherit] text-xs font-semibold text-fg hover:bg-white/10"
            disabled={!addCommand}
            onclick={addRow}>Add</button
        >
    </div>

    {#if error}<div class="mt-2 text-red">{error}</div>{/if}
    <div class="flex justify-end gap-2 border-t border-line/15 px-4.5 py-3.5">
        <span class="flex-1"></span>
        {#if saved}<span class="ml-2 text-grn">saved — reloading…</span>{/if}
        <button
            class="flex cursor-pointer items-center gap-2 rounded-lg border-0 bg-acc px-3 py-1.5 font-[inherit] text-xs font-semibold text-on-acc"
            disabled={hasProblem}
            onclick={() => void save()}>Save &amp; reload</button
        >
    </div>
</div>

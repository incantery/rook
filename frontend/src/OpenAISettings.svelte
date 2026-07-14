<!-- OpenAI drafter key — keychain only (replaces the old KeyModal). -->
<script lang="ts">
    import {Call} from "@wailsio/runtime";

    const SVC = "github.com/incantery/rook/internal/config.Service.";

    let key = $state("");
    let status = $state("checking…");
    let statusOk = $state(false);
    let error = $state("");
    let saved = $state(false);

    $effect(() => {
        Call.ByName(SVC + "OpenAIKeyStatus").then(
            (s: string) => {
                status =
                    s === "keychain"
                        ? "✓ a key is stored in the keychain — saving replaces it"
                        : s === "file"
                          ? "a key file exists (~/.config/rook/openai-key) — the keychain takes precedence once set"
                          : "no key configured — the agent idles until one exists (and agent = on in the config)";
                statusOk = !!s;
            },
            () => (status = ""),
        );
    });

    async function save() {
        error = "";
        saved = false;
        const k = key.trim();
        if (!k) return;
        try {
            await Call.ByName(SVC + "SetOpenAIKey", k);
            key = "";
            statusOk = true;
            status = "✓ a key is stored in the keychain — saving replaces it";
            saved = true;
        } catch (err) {
            error = `keychain write failed: ${err}`;
        }
    }

    async function clear() {
        try {
            await Call.ByName(SVC + "ClearOpenAIKey");
            statusOk = false;
            status =
                "no key configured — the agent idles until one exists (and agent = on in the config)";
        } catch (err) {
            error = `keychain delete failed: ${err}`;
        }
    }
</script>

<div class="flex flex-col gap-4 p-4.5">
    <div class="border-b border-line/15 px-4.5 py-3.5 text-sm font-bold text-fg">
        OpenAI API key — the drafter's credential
    </div>
    <div class={["mt-1.5 mb-3.5", statusOk ? "text-grn" : "text-dim"]}>{status}</div>
    <label class="my-2 flex items-center gap-2"
        ><span class="mb-1.5 block text-xs font-semibold text-dim">Key</span>
        <input
            type="password"
            class="box-border w-full min-w-0 flex-1 rounded-lg border border-line/15 bg-[#0a0c14]/80 px-2.5 py-2 font-mono text-sm text-fg outline-none focus:border-acc"
            placeholder="sk-…"
            bind:value={key}
            spellcheck="false"
            autocomplete="off"
        />
        <button
            class="flex cursor-pointer items-center gap-2 rounded-lg border border-line/15 bg-white/5 px-3 py-1.5 font-[inherit] text-xs font-semibold text-fg hover:bg-white/10"
            onclick={() => void clear()}>Remove</button
        >
    </label>
    {#if error}<div class="mt-2 text-red">{error}</div>{/if}
    <div class="flex justify-end gap-2 border-t border-line/15 px-4.5 py-3.5">
        <span class="flex-1"></span>
        {#if saved}<span class="ml-2 text-grn">saved ✓</span>{/if}
        <button
            class="flex cursor-pointer items-center gap-2 rounded-lg border-0 bg-acc px-3 py-1.5 font-[inherit] text-xs font-semibold text-[#10131c]"
            onclick={() => void save()}>Save to keychain</button
        >
    </div>
</div>

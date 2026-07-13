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

<div class="ws-form">
    <div class="ws-modal-title">OpenAI API key — the drafter's credential</div>
    <div class="settings-status" class:ok={statusOk}>{status}</div>
    <label class="settings-row"
        ><span>Key</span>
        <input
            type="password"
            placeholder="sk-…"
            bind:value={key}
            spellcheck="false"
            autocomplete="off"
        />
        <button class="home-btn" onclick={() => void clear()}>Remove</button>
    </label>
    {#if error}<div class="settings-error">{error}</div>{/if}
    <div class="ws-modal-foot">
        <span class="home-spacer"></span>
        {#if saved}<span class="settings-saved">saved ✓</span>{/if}
        <button class="home-btn primary" onclick={() => void save()}>Save to keychain</button>
    </div>
</div>

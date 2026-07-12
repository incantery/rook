<!-- The OpenAI-key modal (palette → "Set OpenAI API key"): the one setting
     the app writes, and it goes to the login keychain, never to the config
     file — that stays user-owned. Calls config.Service by FQN, same
     no-generated-bindings pattern as notifications. -->
<script lang="ts">
    import {Call} from "@wailsio/runtime";

    const SVC = "github.com/incantery/rook/internal/config.Service.";

    let {onclose}: {onclose: () => void} = $props();

    let key = $state("");
    let status = $state("checking…");
    let statusOk = $state(false);
    let error = $state("");
    let inputEl: HTMLInputElement;

    $effect(() => {
        inputEl.focus();
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
        const k = key.trim();
        if (!k) {
            inputEl.focus();
            return;
        }
        try {
            await Call.ByName(SVC + "SetOpenAIKey", k);
            onclose();
        } catch (err) {
            error = `keychain write failed: ${err}`;
        }
    }

    async function clear() {
        try {
            await Call.ByName(SVC + "ClearOpenAIKey");
            onclose();
        } catch (err) {
            error = `keychain delete failed: ${err}`;
        }
    }

    function onKeydown(e: KeyboardEvent) {
        if (e.key === "Enter") void save();
        else if (e.key === "Escape") onclose();
        e.stopPropagation();
    }
</script>

<div
    id="key-modal"
    class="overlay"
    onmousedown={(e) => e.target === e.currentTarget && onclose()}
    onkeydown={onKeydown}
    role="presentation"
>
    <div class="pal-panel">
        <div class="ws-modal-title">OpenAI API key — the drafter's credential</div>
        <div class="ws-form">
            <div class="key-status" class:ok={statusOk}>{status}</div>
            <label>
                <span>Stored in the macOS login keychain (service “rook”), not in a file</span>
                <input type="password" placeholder="sk-…" spellcheck="false" autocomplete="off" bind:value={key} bind:this={inputEl} />
            </label>
            <div class="key-error" hidden={!error}>{error}</div>
        </div>
        <div class="ws-modal-foot">
            <button class="home-btn key-clear" onclick={() => void clear()}>Remove key</button>
            <span class="home-spacer"></span>
            <button class="home-btn key-cancel" onclick={onclose}>Cancel</button>
            <button class="home-btn primary key-save" onclick={() => void save()}>Save to keychain</button>
        </div>
    </div>
</div>

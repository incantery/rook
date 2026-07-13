<script lang="ts">
    import type {Config as ConfigModel} from "../bindings/github.com/incantery/rook/internal/config/models";
    let {cfg}: {cfg: ConfigModel} = $props();
</script>

<div class="ws-form"><div class="settings-loading">Jira — {cfg.jiraUrl || "unset"}</div></div>

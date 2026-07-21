<!-- The finder's preview pane — telescope's defining feature, and the reason
     the picker got wide. Answers "is this the hit I meant?" without paying
     the cost of opening a buffer to find out, which is what makes ⌃j through
     forty grep hits actually usable.

     Monaco, not a <pre>: the preview has to agree with the editor about
     syntax, theme, and font or it reads as a different application. One
     instance is created lazily on first preview and lives until the picker
     closes, with a model cache keyed by path — moving the cursor swaps a
     model, it never rebuilds an editor. Same retarget-in-place idea the
     panes use for :e. -->
<script lang="ts">
    import type {HostAPI} from "./hostapi";
    import type {PreviewSpec} from "./finder";
    import type * as monacoTypes from "monaco-editor";

    interface Props {
        api: HostAPI;
        workspace: string;
        spec: PreviewSpec | null;
    }
    let {api, workspace, spec}: Props = $props();

    /** j/k through a list must not put a request on the wire per row */
    const DEBOUNCE_MS = 90;
    /** a preview is a glance, not a file viewer — don't ship a 4MB minified
     *  bundle into a model to show twelve lines of it */
    const MAX_BYTES = 400_000;

    let mountEl: HTMLDivElement;
    let note = $state("");
    let loading = $state(false);

    let monaco: typeof import("./term/monaco").monaco | undefined;
    let editor: monacoTypes.editor.IStandaloneCodeEditor | undefined;
    const models = new Map<string, monacoTypes.editor.ITextModel>();
    let decorations: monacoTypes.editor.IEditorDecorationsCollection | undefined;
    let seq = 0;
    let uriSeq = 0;

    async function ensureEditor(): Promise<monacoTypes.editor.IStandaloneCodeEditor> {
        if (!monaco) monaco = (await import("./term/monaco")).monaco;
        if (!editor) {
            editor = monaco.editor.create(mountEl, {
                readOnly: true,
                theme: "rook",
                // The picker is a fixed overlay with no fit() manager driving
                // it, so Monaco watches its own box here — the opposite of the
                // pane editors, and correct for exactly that reason.
                automaticLayout: true,
                minimap: {enabled: false},
                scrollBeyondLastLine: false,
                lineNumbers: "on",
                glyphMargin: false,
                folding: false,
                renderLineHighlight: "none",
                overviewRulerLanes: 0,
                scrollbar: {vertical: "auto", horizontalScrollbarSize: 6},
                fontSize: 12,
                // a preview is read-only scenery: nothing here should look
                // like it is waiting for a caret
                domReadOnly: true,
                contextmenu: false,
            });
            decorations = editor.createDecorationsCollection();
        }
        return editor;
    }

    // `monaco` is only ever assigned inside ensureEditor, so every read below
    // is after an await of it — the non-null assertions are load-order facts.

    /** null = don't paint (a stale row, or a reason already in `note`) */
    async function modelFor(
        s: PreviewSpec,
        mine: number,
    ): Promise<monacoTypes.editor.ITextModel | null> {
        const cached = models.get(s.path);
        if (cached) return cached;
        try {
            const res = await api.readFile(workspace, s.path);
            if (mine !== seq) return null;
            if (res.binary) {
                note = "binary file";
                return null;
            }
            if (res.content.length > MAX_BYTES) {
                note = "too large to preview";
                return null;
            }
            await ensureEditor(); // also the import that defines `monaco`
            if (mine !== seq) return null;
            const m = monaco!;
            // the URI must keep the extension — that's what Monaco reads to
            // infer the language — and stay unique per model
            const model = m.editor.createModel(
                res.content,
                undefined,
                m.Uri.parse(`rook-preview://${++uriSeq}/${s.path}`),
            );
            models.set(s.path, model);
            return model;
        } catch (err) {
            if (mine !== seq) return null;
            note = String(err).includes(" 404 ") ? "not found" : "couldn't read this file";
            return null;
        }
    }

    async function show(s: PreviewSpec, mine: number): Promise<void> {
        loading = true;
        note = "";
        const model = await modelFor(s, mine);
        if (!model) {
            if (mine === seq) loading = false;
            return;
        }
        const ed = await ensureEditor();
        if (mine !== seq) return; // a later row won while we awaited
        ed.setModel(model);
        const line = Math.min(Math.max(s.line ?? 1, 1), model.getLineCount());
        // ScrollType.Immediate (1): j/k must not animate a scroll per row
        ed.revealLineInCenter(line, 1);
        // mark the hit line itself; without it a centered viewport still
        // leaves you hunting for which line matched
        decorations?.set(
            s.line
                ? [
                      {
                          range: new monaco!.Range(line, 1, line, 1),
                          options: {
                              isWholeLine: true,
                              className: "finder-hit-line",
                              marginClassName: "finder-hit-line",
                          },
                      },
                  ]
                : [],
        );
        loading = false;
    }

    // Debounced, sequence-guarded: the same discipline the live grep uses,
    // for the same reason — a slow row's answer must never paint over the
    // row you have since moved to.
    $effect(() => {
        const s = spec;
        const mine = ++seq;
        if (!s) {
            note = "";
            loading = false;
            return;
        }
        const t = setTimeout(() => void show(s, mine), DEBOUNCE_MS);
        return () => clearTimeout(t);
    });

    $effect(() => () => {
        // the picker unmounts per close; models and the editor go with it
        seq++;
        for (const m of models.values()) m.dispose();
        models.clear();
        editor?.dispose();
    });
</script>

<div class="relative flex-1 overflow-hidden border-l border-line/15">
    <div class="absolute inset-0" bind:this={mountEl}></div>
    {#if note || (!spec && !loading)}
        <div class="absolute inset-0 flex items-center justify-center bg-overlay">
            <span class="text-xs uppercase tracking-wider text-lo">{note || "no preview"}</span>
        </div>
    {/if}
</div>

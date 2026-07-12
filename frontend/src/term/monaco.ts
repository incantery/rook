// Monaco, assembled for rook: editor core + all editor features and ZERO
// language services (no TS worker, no JSON smarts — Monarch colorizing
// only). This module is loaded exclusively via await import() so vite
// splits it and its worker into their own lazy chunks — boot stays
// xterm-only. Deep-import paths are pinned-0.55.1 facts; re-verify them
// on any monaco bump (vite-env.d.ts carries the edcore type shim).

import * as edcore from "monaco-editor/esm/vs/editor/edcore.main";
import type * as monacoTypes from "monaco-editor";
import "monaco-editor/esm/vs/basic-languages/go/go.contribution";
import "monaco-editor/esm/vs/basic-languages/typescript/typescript.contribution";
import "monaco-editor/esm/vs/basic-languages/javascript/javascript.contribution";
import "monaco-editor/esm/vs/basic-languages/html/html.contribution";
import "monaco-editor/esm/vs/basic-languages/css/css.contribution";
import "monaco-editor/esm/vs/basic-languages/markdown/markdown.contribution";
import "monaco-editor/esm/vs/basic-languages/shell/shell.contribution";
import "monaco-editor/esm/vs/basic-languages/yaml/yaml.contribution";
import "monaco-editor/esm/vs/basic-languages/rust/rust.contribution";
import "monaco-editor/esm/vs/basic-languages/python/python.contribution";
import EditorWorker from "monaco-editor/esm/vs/editor/editor.worker?worker";

// edcore ships no .d.ts; the package types (editor.api.d.ts) describe
// exactly the surface it re-exports.
const monaco = edcore as unknown as typeof monacoTypes;

// One worker serves everything here, the DiffEditor's diff computation
// included — there are no language workers to route to.
self.MonacoEnvironment = {
    getWorker: () => new EditorWorker(),
};

// Material Ocean, mirroring main.ts's xterm THEME — but on an OPAQUE
// panel: Monaco can't render transparent, so the editor pane owns its
// background (#0f111a, the body tint at full opacity).
monaco.editor.defineTheme("rook", {
    base: "vs-dark",
    inherit: true,
    rules: [
        {token: "comment", foreground: "546e7a"},
        {token: "string", foreground: "c3e88d"},
        {token: "number", foreground: "f78c6c"},
        {token: "keyword", foreground: "c792ea"},
        {token: "type", foreground: "ffcb6b"},
        {token: "delimiter", foreground: "89ddff"},
        {token: "tag", foreground: "ff5370"},
        {token: "attribute.name", foreground: "ffcb6b"},
        {token: "attribute.value", foreground: "c3e88d"},
    ],
    colors: {
        "editor.background": "#0f111a",
        "editor.foreground": "#8f93a2",
        "editorCursor.foreground": "#ffcc00",
        "editor.selectionBackground": "#717cb4",
        "editorLineNumber.foreground": "#3a3f58",
        "editorLineNumber.activeForeground": "#8f93a2",
        "editorWidget.background": "#151928",
        "editorWidget.border": "#252a3d",
        "diffEditor.insertedTextBackground": "#c3e88d22",
        "diffEditor.removedTextBackground": "#ff537022",
        "diffEditor.insertedLineBackground": "#c3e88d12",
        "diffEditor.removedLineBackground": "#ff537012",
    },
});

export {monaco};

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
import {buildMonacoTheme} from "../theme/monaco-theme";
import {themeService} from "../theme/service";

// edcore ships no .d.ts; the package types (editor.api.d.ts) describe
// exactly the surface it re-exports.
const monaco = edcore as unknown as typeof monacoTypes;

// One worker serves everything here, the DiffEditor's diff computation
// included — there are no language workers to route to.
self.MonacoEnvironment = {
    getWorker: () => new EditorWorker(),
};

// The "rook" theme is built from the active Palette (theme/service.ts) — the
// single source of truth, mirroring the xterm + chrome colors. Monaco can't
// render transparent, so the editor owns an opaque background (the palette bg).
// Redefining + setTheme on a live swap re-colors every open editor.
monaco.editor.defineTheme("rook", buildMonacoTheme(themeService.active().palette));
themeService.onMonaco((data) => {
    monaco.editor.defineTheme("rook", data);
    monaco.editor.setTheme("rook");
});

export {monaco};

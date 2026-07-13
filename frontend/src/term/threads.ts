// The thread layer on ONE Monaco editor: gutter markers for the file's
// threads on one diff side, later widgets and the composer. Framework-
// free DOM like the rest of the island. Monaco arrives as a constructor
// param (types only here) — this module must never grow an import edge
// that drags Monaco into an eager chunk.

import type * as monacoTypes from "monaco-editor";
import type {ThreadInfo} from "../hostapi";
import {bandThreads, glyphClass, markerLines, type Side} from "./threadview";

type Monaco = typeof monacoTypes;
type ICodeEditor = monacoTypes.editor.ICodeEditor;

export class ThreadBand {
    private decorations: monacoTypes.editor.IEditorDecorationsCollection;
    private threads: ThreadInfo[] = [];

    constructor(
        private monaco: Monaco,
        readonly editor: ICodeEditor,
        readonly side: Side,
    ) {
        this.decorations = editor.createDecorationsCollection();
    }

    /** all = the workspace's threads; the band slices its own. */
    render(all: ThreadInfo[], path: string): void {
        this.threads = bandThreads(all, path, this.side);
        const decs: monacoTypes.editor.IModelDeltaDecoration[] = [];
        for (const [line, group] of markerLines(this.threads)) {
            decs.push({
                range: new this.monaco.Range(line, 1, line, 1),
                options: {
                    glyphMarginClassName: glyphClass(group),
                    glyphMarginHoverMessage: {
                        value: `${group.length} thread${group.length === 1 ? "" : "s"}`,
                    },
                },
            });
        }
        this.decorations.set(decs);
    }

    dispose(): void {
        this.decorations.clear();
    }
}

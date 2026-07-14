// The thread layer on ONE Monaco editor, read-only: gutter markers and a
// single active-anchor highlight. All conversation UI lives in the Svelte
// ThreadPanel (chrome); this band only paints the code surface and reports
// marker clicks up through onMarkerClick.
//
// Framework-free DOM like the rest of the island. Monaco arrives as a
// constructor param (types only here) — this module must never grow an
// import edge that drags Monaco into an eager chunk.

import type * as monacoTypes from "monaco-editor";
import type {ThreadInfo} from "../hostapi";
import {bandThreads, glyphClass, markerLines, type Side} from "./threadview";

type Monaco = typeof monacoTypes;
type ICodeEditor = monacoTypes.editor.ICodeEditor;

export class ThreadBand {
    private glyphs: monacoTypes.editor.IEditorDecorationsCollection;
    private active: monacoTypes.editor.IEditorDecorationsCollection;
    private threads: ThreadInfo[] = [];
    private mouseSub: monacoTypes.IDisposable;

    constructor(
        private monaco: Monaco,
        readonly editor: ICodeEditor,
        readonly side: Side,
        private onMarkerClick: (line: number, side: Side, threadIds: number[]) => void,
    ) {
        this.glyphs = editor.createDecorationsCollection();
        this.active = editor.createDecorationsCollection();
        this.mouseSub = editor.onMouseDown((e) => {
            if (e.target.type !== this.monaco.editor.MouseTargetType.GUTTER_GLYPH_MARGIN) return;
            const line = e.target.position?.lineNumber;
            if (!line) return;
            const group = markerLines(this.threads).get(line);
            if (group)
                this.onMarkerClick(
                    line,
                    this.side,
                    group.map((t) => t.id),
                );
        });
    }

    /** all = the workspace's threads; the band slices its own (path, side)
     *  and repaints one glyph per anchor line. */
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
        this.glyphs.set(decs);
    }

    /** The read-only highlight for the active thread's anchor lines. */
    highlight(startLine: number, endLine: number): void {
        const a = Math.max(1, startLine);
        const b = Math.max(a, endLine);
        this.active.set([
            {
                range: new this.monaco.Range(a, 1, b, 1),
                options: {isWholeLine: true, className: "thread-active-line"},
            },
        ]);
    }

    clearHighlight(): void {
        this.active.clear();
    }

    dispose(): void {
        this.mouseSub.dispose();
        this.glyphs.clear();
        this.active.clear();
    }
}

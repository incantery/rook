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
import {
    bandThreads,
    glyphClass,
    markerLines,
    statusMeta,
    threadStatus,
    STATUS_ORDER,
    type Side,
} from "./threadview";

type Monaco = typeof monacoTypes;
type ICodeEditor = monacoTypes.editor.ICodeEditor;

/** How much of the latest comment the inline row carries. Long enough to
 *  recognise which comment it is, short enough that the row never wraps. */
const PREVIEW_CHARS = 90;

function oneLine(s: string, max: number): string {
    const flat = s.replace(/\s+/g, " ").trim();
    return flat.length > max ? flat.slice(0, max) + "…" : flat;
}

export class ThreadBand {
    private glyphs: monacoTypes.editor.IEditorDecorationsCollection;
    private active: monacoTypes.editor.IEditorDecorationsCollection;
    private threads: ThreadInfo[] = [];
    private mouseSub: monacoTypes.IDisposable;
    /** ids of the view zones currently in the editor, so a re-render can
     *  take down exactly what it put up */
    private zoneIds: string[] = [];

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
        this.renderZones();
    }

    /** The inline status row: one real inserted line under each anchor,
     *  saying whose move it is and which comment is waiting.
     *
     *  A view zone, not ghost text at end-of-line, because the thing worth
     *  reading here is a sentence — end-of-line text is truncated by
     *  whatever the code happens to be, which is exactly backwards for a
     *  status you're meant to act on. The cost is honest and accepted: every
     *  thread shifts the lines below it.
     *
     *  Note this does NOT contradict the rule that thread text is edited in
     *  a buffer. This row is read-only chrome — it holds no caret, takes no
     *  focus, and answers "is anything happening here?" so you can decide
     *  whether to open the buffer at all.
     *
     *  Resolved threads get no row. A finished conversation is exactly the
     *  one that shouldn't still be occupying a line of the file. */
    private renderZones(): void {
        const rows = [...markerLines(this.threads)]
            .map(([, group]) => group.filter((t) => threadStatus(t) !== "resolved"))
            .filter((live) => live.length > 0);

        this.editor.changeViewZones((acc) => {
            for (const id of this.zoneIds) acc.removeZone(id);
            this.zoneIds = [];
            for (const live of rows) {
                // the most-demanding thread speaks for the line, matching
                // what the gutter glyph already chose
                const lead = [...live].sort(
                    (a, b) => STATUS_ORDER[threadStatus(a)] - STATUS_ORDER[threadStatus(b)],
                )[0];
                this.zoneIds.push(
                    acc.addZone({
                        // under the anchor's LAST line: the row belongs to the
                        // whole range, not just the line the glyph sits on
                        afterLineNumber: Math.max(1, lead.currentEnd || lead.currentStart),
                        heightInLines: 1,
                        domNode: this.zoneNode(lead, live),
                    }),
                );
            }
        });
    }

    private zoneNode(lead: ThreadInfo, live: ThreadInfo[]): HTMLElement {
        const status = threadStatus(lead);
        const meta = statusMeta(status);
        // Two elements, not one: Monaco writes `display` (and position, and
        // width) onto the zone's own domNode as INLINE styles while it lays
        // zones out, which silently beats any display we set in the sheet —
        // the first version of this was a flex row that Monaco turned back
        // into a block, so gap did nothing and the words ran together. The
        // outer node is Monaco's to style; everything we lay out lives in
        // the inner one.
        const outer = document.createElement("div");
        outer.className = "thread-zone-host";
        const el = document.createElement("div");
        el.className = `thread-zone thread-zone-${status}`;
        outer.appendChild(el);

        const dot = document.createElement("span");
        dot.className = `thread-glyph thread-glyph-${status}`;
        el.appendChild(dot);

        const label = document.createElement("span");
        label.className = "thread-zone-label";
        label.textContent = meta.label;
        el.appendChild(label);

        const last = lead.comments[lead.comments.length - 1];
        if (last) {
            const body = document.createElement("span");
            body.className = "thread-zone-body";
            // the failure itself is the useful text when nothing was
            // delivered — the comment is not what went wrong
            body.textContent =
                status === "failed" && lead.deliverError
                    ? oneLine(lead.deliverError, PREVIEW_CHARS)
                    : oneLine(last.body, PREVIEW_CHARS);
            el.appendChild(body);
        }

        const tail = document.createElement("span");
        tail.className = "thread-zone-tail";
        const replies = Math.max(0, lead.comments.length - 1);
        const parts: string[] = [];
        if (replies > 0) parts.push(`${replies} repl${replies === 1 ? "y" : "ies"}`);
        if (live.length > 1) parts.push(`+${live.length - 1} more`);
        if (lead.outdated) parts.push("anchor moved");
        tail.textContent = parts.join(" · ");
        el.appendChild(tail);

        // clicking the row is the same gesture as clicking the glyph
        el.addEventListener("mousedown", (e) => {
            e.preventDefault();
            this.onMarkerClick(
                Math.max(1, lead.currentStart),
                this.side,
                live.map((t) => t.id),
            );
        });
        return outer;
    }

    /** The mark for the active thread's anchor lines.
     *
     *  A RULE IN THE MARGIN, not a wash over the text. The whole-line tint
     *  this replaced covered the code it was pointing at — it made the source
     *  read as inactive, as though the annotation had taken it over, which is
     *  backwards: the code is the subject and the comment is attached to it.
     *  A 2px rule in the line-decorations margin says exactly as much (here,
     *  and this far) while leaving every character its own colour. */
    highlight(startLine: number, endLine: number): void {
        const a = Math.max(1, startLine);
        const b = Math.max(a, endLine);
        this.active.set([
            {
                range: new this.monaco.Range(a, 1, b, 1),
                options: {isWholeLine: true, linesDecorationsClassName: "thread-anchor-rule"},
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
        // zones outlive decorations — Monaco keeps them until removed, so a
        // disposed band that skipped this would leave rows floating in the
        // editor it no longer owns
        this.editor.changeViewZones((acc) => {
            for (const id of this.zoneIds) acc.removeZone(id);
            this.zoneIds = [];
        });
    }
}

// The thread layer on ONE Monaco editor: gutter markers, and view-zone
// widgets for reading and driving conversations on one diff side.
// Framework-free DOM like the rest of the island. Monaco arrives as a
// constructor param (types only here) — this module must never grow an
// import edge that drags Monaco into an eager chunk.
//
// Zone mechanics (verified against pinned 0.55.1): zone domNodes receive
// pointer events as long as suppressMouseDown stays unset; heights are
// fixed, so every content change re-measures the card and layoutZone()s.

import type * as monacoTypes from "monaco-editor";
import type {ThreadInfo} from "../hostapi";
import {bandThreads, glyphClass, markerLines, type Side} from "./threadview";

type Monaco = typeof monacoTypes;
type ICodeEditor = monacoTypes.editor.ICodeEditor;

/** Mutations, owned by the pane: it calls the API, refetches, and
 *  re-renders every band — the band never patches its own data. Hooks
 *  reject on failure; the band shows the error inline. */
export interface BandHooks {
    reply(id: number, body: string): Promise<void>;
    resolve(id: number): Promise<void>;
    reopen(id: number): Promise<void>;
    create(startLine: number, endLine: number, body: string): Promise<void>;
}

interface Zone {
    id: string;
    zone: monacoTypes.editor.IViewZone;
    dom: HTMLElement; // .thread-zone (the zone's domNode)
    card: HTMLElement; // .thread-card inside it
}

export class ThreadBand {
    private decorations: monacoTypes.editor.IEditorDecorationsCollection;
    private threads: ThreadInfo[] = [];
    private zones = new Map<number, Zone>(); // thread id → open widget
    private mouseSub: monacoTypes.IDisposable;
    /** focus this thread's reply box on its next refresh (post-reopen) */
    private focusReply: number | null = null;
    private composer: Zone | null = null;

    constructor(
        private monaco: Monaco,
        readonly editor: ICodeEditor,
        readonly side: Side,
        private hooks: BandHooks,
    ) {
        this.decorations = editor.createDecorationsCollection();
        this.mouseSub = editor.onMouseDown((e) => {
            if (e.target.type !== this.monaco.editor.MouseTargetType.GUTTER_GLYPH_MARGIN) return;
            const line = e.target.position?.lineNumber;
            if (line && markerLines(this.threads).has(line)) this.toggleLine(line);
        });
    }

    /** all = the workspace's threads; the band slices its own. Open
     *  widgets refresh against the new data — except any holding a draft
     *  (the user is mid-thought; never yank the DOM out from under them).
     *  reopen = widget ids to restore after a band rebuild. */
    render(all: ThreadInfo[], path: string, reopen?: Set<number>): void {
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
        for (const [tid, z] of Array.from(this.zones)) {
            if (this.zoneBusy(z)) {
                // a skipped refresh must not leave the one-shot focus
                // request armed — it would fire on some later render and
                // yank focus into a thread the user moved on from
                if (this.focusReply === tid) this.focusReply = null;
                continue;
            }
            const t = this.threads.find((x) => x.id === tid);
            if (t) this.refreshZone(t, z);
            else this.closeZone(tid);
        }
        if (reopen) {
            for (const t of this.threads) if (reopen.has(t.id)) this.openZone(t);
        }
    }

    openThreadIds(): number[] {
        return [...this.zones.keys()];
    }

    /** True while any textarea in this band holds unsent text — the
     *  signal that auto-refetch must keep its hands off. */
    hasDraft(): boolean {
        for (const z of this.zones.values()) if (this.zoneBusy(z)) return true;
        return this.composer !== null && this.zoneBusy(this.composer);
    }

    dispose(): void {
        this.mouseSub.dispose();
        this.decorations.clear();
        for (const tid of Array.from(this.zones.keys())) this.closeZone(tid);
        this.closeComposer();
    }

    // ---- composer: selection → new pending thread ----

    /** One composer per band; opening again moves it. The pane maps the
     *  editor selection to lines and routes ⌘⇧M/context-menu here. */
    openComposer(startLine: number, endLine: number): void {
        this.closeComposer();
        // identity for the async save path: a second composer may replace
        // this one while a create is in flight — its completion must not
        // touch the replacement
        let mine: Zone | null = null;
        const dom = document.createElement("div");
        dom.className = "thread-zone";
        const card = document.createElement("div");
        card.className = "thread-card";
        const meta = document.createElement("div");
        meta.className = "thread-meta";
        const lines = startLine === endLine ? `L${startLine}` : `L${startLine}–${endLine}`;
        meta.textContent = `new thread on ${lines}${this.side === "original" ? " (original side)" : ""}`;
        const input = document.createElement("textarea");
        input.className = "thread-input";
        input.rows = 3;
        input.placeholder = "start a thread… (⌘⏎ comments · esc cancels)";
        const err = document.createElement("div");
        err.className = "thread-err";
        err.hidden = true;
        const row = document.createElement("div");
        row.className = "thread-row";
        const save = this.actBtn("comment", async () => {
            const body = input.value.trim();
            if (!body) return;
            err.hidden = true;
            save.disabled = true;
            try {
                await this.hooks.create(startLine, endLine, body);
                if (this.composer === mine) this.closeComposer(); // the refetch renders the pending marker
            } catch (e) {
                err.textContent = String(e);
                err.hidden = false;
                if (this.composer === mine && mine) this.sizeZone(mine);
            } finally {
                save.disabled = false;
            }
        });
        row.append(
            save,
            this.actBtn("cancel", () => this.closeComposer()),
        );
        input.addEventListener("keydown", (e) => {
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                e.preventDefault();
                save.click();
            } else if (e.key === "Escape") {
                this.closeComposer();
            }
        });
        card.append(meta, input, row, err);
        dom.appendChild(card);
        const zone: monacoTypes.editor.IViewZone = {
            afterLineNumber: endLine,
            heightInPx: 120,
            domNode: dom,
        };
        let id = "";
        this.editor.changeViewZones((a) => {
            id = a.addZone(zone);
        });
        this.composer = {id, zone, dom, card};
        mine = this.composer;
        this.sizeZone(this.composer);
        this.editor.revealLinesInCenterIfOutsideViewport(startLine, endLine);
        requestAnimationFrame(() => input.focus());
    }

    closeComposer(): void {
        const c = this.composer;
        if (!c) return;
        this.composer = null;
        this.editor.changeViewZones((a) => a.removeZone(c.id));
    }

    // ---- widgets ----

    private zoneBusy(z: Zone): boolean {
        for (const i of z.dom.querySelectorAll("textarea")) {
            if (i.value.trim() !== "") return true;
        }
        return false;
    }

    private toggleLine(line: number): void {
        const group = markerLines(this.threads).get(line) ?? [];
        const allOpen = group.every((t) => this.zones.has(t.id));
        for (const t of group) {
            if (allOpen) this.closeZone(t.id);
            else this.openZone(t);
        }
    }

    private openZone(t: ThreadInfo): void {
        if (this.zones.has(t.id)) return;
        const dom = document.createElement("div");
        dom.className = "thread-zone";
        const card = this.buildCard(t);
        dom.appendChild(card);
        const zone: monacoTypes.editor.IViewZone = {
            afterLineNumber: Math.max(1, t.currentEnd),
            heightInPx: 60,
            domNode: dom,
        };
        let id = "";
        this.editor.changeViewZones((a) => {
            id = a.addZone(zone);
        });
        const z: Zone = {id, zone, dom, card};
        this.zones.set(t.id, z);
        this.sizeZone(z);
    }

    private closeZone(tid: number): void {
        const z = this.zones.get(tid);
        if (!z) return;
        this.zones.delete(tid);
        this.editor.changeViewZones((a) => a.removeZone(z.id));
    }

    private refreshZone(t: ThreadInfo, z: Zone): void {
        const card = this.buildCard(t);
        z.card.replaceWith(card);
        z.card = card;
        this.sizeZone(z);
        if (this.focusReply === t.id) {
            this.focusReply = null;
            requestAnimationFrame(() => card.querySelector("textarea")?.focus());
        }
    }

    /** Zones are fixed-height; measure the card once it's laid out and
     *  tell Monaco. layoutZone re-reads the SAME zone object's height. */
    private sizeZone(z: Zone): void {
        requestAnimationFrame(() => {
            const h = z.card.offsetHeight + 8;
            if (h === z.zone.heightInPx) return;
            z.zone.heightInPx = h;
            this.editor.changeViewZones((a) => a.layoutZone(z.id));
        });
    }

    private buildCard(t: ThreadInfo): HTMLElement {
        const card = document.createElement("div");
        card.className = "thread-card";
        const head = document.createElement("div");
        head.className = "thread-row";
        const state = document.createElement("span");
        state.className = `thread-state thread-state-${t.state}`;
        state.textContent = t.state;
        const meta = document.createElement("span");
        meta.className = "thread-meta";
        const range =
            t.currentStart === t.currentEnd
                ? `L${t.currentStart}`
                : `L${t.currentStart}–${t.currentEnd}`;
        meta.textContent =
            `#${t.id} · ${range}` +
            (t.outdated ? " · outdated" : "") +
            (t.resolvedBy ? ` · by ${t.resolvedBy}` : "");
        head.append(state, meta);
        card.appendChild(head);
        if (t.outdated && t.anchorText) {
            // the lines commented on, as they were — the live file moved on
            const anchor = document.createElement("pre");
            anchor.className = "thread-anchor";
            anchor.textContent = t.anchorText;
            card.appendChild(anchor);
        }
        for (const c of t.comments) {
            const row = document.createElement("div");
            row.className = "thread-comment";
            const who = document.createElement("span");
            who.className = `thread-author thread-author-${c.author}`;
            who.textContent = c.author;
            const body = document.createElement("div");
            body.className = "thread-body";
            body.textContent = c.body;
            row.append(who, body);
            card.appendChild(row);
        }
        card.appendChild(this.buildActions(t));
        return card;
    }

    private buildActions(t: ThreadInfo): HTMLElement {
        const wrap = document.createElement("div");
        wrap.className = "thread-reply";
        const input = document.createElement("textarea");
        input.className = "thread-input";
        input.rows = 1;
        input.placeholder = "reply… (⌘⏎ sends · esc collapses)";
        const err = document.createElement("div");
        err.className = "thread-err";
        err.hidden = true;
        const row = document.createElement("div");
        row.className = "thread-row";
        const run = (fn: () => Promise<void>) => async () => {
            err.hidden = true;
            for (const b of row.querySelectorAll("button")) b.disabled = true;
            try {
                await fn();
            } catch (e) {
                err.textContent = String(e);
                err.hidden = false;
            } finally {
                for (const b of row.querySelectorAll("button")) b.disabled = false;
                const z = this.zones.get(t.id);
                if (z) this.sizeZone(z);
            }
        };
        const reply = this.actBtn(
            "reply",
            run(async () => {
                const body = input.value.trim();
                if (!body) return;
                // clear BEFORE the hook: its refetch skips draft-holding
                // widgets, and this reply must render as a comment
                input.value = "";
                try {
                    await this.hooks.reply(t.id, body);
                } catch (e) {
                    input.value = body; // a failed reply is not an eaten draft
                    throw e;
                }
            }),
        );
        row.appendChild(reply);
        row.appendChild(
            t.state === "resolved"
                ? this.actBtn(
                      "reopen",
                      run(async () => {
                          // a reopen without a why isn't actionable — cursor
                          // goes to the reply box once the refresh lands
                          this.focusReply = t.id;
                          try {
                              await this.hooks.reopen(t.id);
                          } catch (e) {
                              this.focusReply = null;
                              throw e;
                          }
                      }),
                  )
                : this.actBtn(
                      "resolve",
                      run(() => this.hooks.resolve(t.id)),
                  ),
        );
        input.addEventListener("keydown", (e) => {
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                e.preventDefault();
                reply.click();
            } else if (e.key === "Escape") {
                this.closeZone(t.id);
            }
        });
        input.addEventListener("input", () => {
            input.rows = Math.min(6, input.value.split("\n").length);
            const z = this.zones.get(t.id);
            if (z) this.sizeZone(z);
        });
        wrap.append(input, row, err);
        return wrap;
    }

    private actBtn(label: string, onClick: () => void | Promise<void>): HTMLButtonElement {
        const b = document.createElement("button");
        b.className = "editor-btn thread-act";
        b.textContent = label;
        b.addEventListener("click", () => void onClick());
        return b;
    }
}

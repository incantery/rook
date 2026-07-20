// The vim jumplist, chrome-owned — one list for the workbench, living at
// the openFile seam because that's where every navigation (gd, a grep
// hit, a picker open, a refs `o`) already flows. Vim semantics: a new
// jump records where you WERE and discards forward history; ⌃O from the
// live position first saves it, so ⌃I can come back.

export interface JumpLoc {
    path: string;
    line: number;
    col: number;
}

const CAP = 100;

export class Jumplist {
    private entries: JumpLoc[] = [];
    /** entries.length means "at the live position" (not inside history) */
    private idx = 0;

    /** Record cur (the position BEFORE a jump). Forward history dies —
     *  branching timelines are undo-tree territory, not the jumplist. */
    push(cur: JumpLoc | null): void {
        if (!cur) return;
        this.entries.splice(this.idx);
        const last = this.entries[this.entries.length - 1];
        if (!last || last.path !== cur.path || last.line !== cur.line) {
            this.entries.push(cur);
        }
        if (this.entries.length > CAP) this.entries.shift();
        this.idx = this.entries.length;
    }

    /** ⌃O. cur is the live position — saved on the first step back so the
     *  list can walk forward to it again. Null at the oldest entry. */
    back(cur: JumpLoc | null): JumpLoc | null {
        if (this.idx === 0) return null;
        if (this.idx === this.entries.length && cur) {
            const last = this.entries[this.entries.length - 1];
            if (!last || last.path !== cur.path || last.line !== cur.line) {
                this.entries.push(cur);
            } else {
                this.idx--; // live position IS the newest entry — step past it
            }
        }
        this.idx--;
        if (this.idx < 0) {
            this.idx = 0;
            return null;
        }
        return this.entries[this.idx] ?? null;
    }

    /** ⌃I. Null at the newest entry. */
    forward(): JumpLoc | null {
        if (this.idx >= this.entries.length - 1) return null;
        this.idx++;
        return this.entries[this.idx];
    }

    /** Workspace switch — paths are workspace-relative, history can't cross. */
    clear(): void {
        this.entries = [];
        this.idx = 0;
    }
}

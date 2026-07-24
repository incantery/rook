import {describe, expect, it, vi} from "vitest";
import {exNameOf, Registry} from "./registry";

function cmd(id: string, run: () => void = () => {}) {
    return {id, title: id, category: "Test", run};
}

describe("exNameOf", () => {
    it("capitalizes dot-separated segments", () => {
        expect(exNameOf("thread.ask")).toBe("ThreadAsk");
        expect(exNameOf("review.approve")).toBe("ReviewApprove");
    });

    it("treats every non-alphanumeric run as a segment break", () => {
        expect(exNameOf("pane.split-right")).toBe("PaneSplitRight");
        expect(exNameOf("workspace.set-root")).toBe("WorkspaceSetRoot");
    });

    it("yields vim's user-command shape (leading uppercase)", () => {
        expect(exNameOf("quickfix.toggle")).toMatch(/^[A-Z][A-Za-z0-9]*$/);
    });
});

describe("Registry.exNames", () => {
    it("maps every command under its derived name, wired to run", () => {
        const r = new Registry();
        let ran = 0;
        r.register(cmd("thread.ask", () => ran++));
        const m = r.exNames();
        expect([...m.keys()]).toContain("ThreadAsk");
        m.get("ThreadAsk")!();
        expect(ran).toBe(1);
    });

    it("layers config aliases over the derived names", () => {
        const r = new Registry();
        let ran = 0;
        r.register(cmd("thread.ask", () => ran++));
        const m = r.exNames({Ta: "thread.ask"});
        m.get("Ta")!();
        expect(ran).toBe(1);
        expect(m.has("ThreadAsk")).toBe(true); // the derived name survives
    });

    it("drops aliases naming unknown commands, keeping the rest", () => {
        const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
        const r = new Registry();
        r.register(cmd("thread.ask"));
        const m = r.exNames({Nope: "no.such.command", Ta: "thread.ask"});
        expect(m.has("Nope")).toBe(false);
        expect(m.has("Ta")).toBe(true);
        expect(warn).toHaveBeenCalled();
        warn.mockRestore();
    });

    it("refuses aliases that could shadow vim built-ins", () => {
        const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
        const r = new Registry();
        r.register(cmd("thread.ask"));
        const m = r.exNames({w: "thread.ask", "9Lives": "thread.ask", "": "thread.ask"});
        expect(m.has("w")).toBe(false);
        expect(m.has("9Lives")).toBe(false);
        warn.mockRestore();
    });
});

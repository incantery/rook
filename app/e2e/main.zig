//! e2e scenarios — `make e2e`, or `make e2e ARGS=splits` for one.
//!
//! Each scenario gets a fresh sandboxed instance (own socket, config,
//! state) and is responsible for closing it. Scenarios abort at their
//! first failed assertion, because their state is sequential and every
//! later assertion would just report the same cause again.
//!
//! What belongs here: things an agent would otherwise have to ask a
//! human to eyeball. What does NOT belong here: anything already
//! covered by `zig build test` — rope/editor/paste/config are pure
//! models with headless suites, and they run in CI where this cannot.

const std = @import("std");
const h = @import("harness.zig");

const Scenario = struct {
    name: []const u8,
    what: []const u8,
    run: *const fn (std.mem.Allocator, []const u8) anyerror!void,
};

const scenarios = [_]Scenario{
    .{ .name = "boot", .what = "one pane, one tab, a live shell", .run = boot },
    .{ .name = "echo", .what = "typed command reaches the pty and echoes back", .run = echo },
    .{ .name = "splits", .what = "split right, focus moves, close returns", .run = splits },
    .{ .name = "tabs", .what = "new tab, cycle, pane counts stay separate", .run = tabs },
    .{ .name = "editor", .what = "edit a file, change it, :w reaches disk", .run = editor },
    .{ .name = "pixels", .what = "the renderer actually drew (shot, decoded)", .run = pixels },
    .{ .name = "commands", .what = "registry lists, runs by name, and drives the ⌘K palette", .run = commands },
    .{ .name = "excmd", .what = "the editor's : reaches the registry (:PaneSplitRight)", .run = excmd },
    .{ .name = "sidepane", .what = "side pane retiles the grid, flips edges, and holds the inbox", .run = sidepane },
    .{ .name = "asks", .what = "a question renders, takes keys, and produces the answer JSON", .run = asks },
};

// ---------------------------------------------------------------- boot

fn boot(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    try h.expectEq("panes", 1, try app.paneCount());
    try h.expectEq("tabs", 1, try app.tabCount());
    // start() already proved the shell answers; this pins the prompt so a
    // regression in PS1 handling or pty setup shows up here rather than
    // as a mystery timeout in every other scenario.
    var buf: [64 * 1024]u8 = undefined;
    try h.expectContains(try app.screen(&buf), "e2e$", "prompt");
}

// ---------------------------------------------------------------- echo

fn echo(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    _ = try app.ctl("type echo hello-from-e2e");
    _ = try app.ctl("enter");
    // Twice: the echoed command line, then the command's output. Waiting
    // for one would pass on the echo alone and prove nothing ran.
    try app.waitTextCount("hello-from-e2e", 2, 10_000);
}

// -------------------------------------------------------------- splits

fn splits(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    const first = try app.focusedPane();

    _ = try app.ctl("split right");
    try h.expectEq("panes after split", 2, try app.paneCount());
    const second = try app.focusedPane();
    try h.expect(second != first, "split should focus the NEW pane (still on {d})", .{first});

    // Focus moves by direction, and back.
    _ = try app.ctl("focus left");
    try h.expectEq("focus left returns to the first pane", first, try app.focusedPane());
    _ = try app.ctl("focus right");
    try h.expectEq("focus right returns to the new pane", second, try app.focusedPane());

    // The new pane is a real shell, not just a rectangle.
    _ = try app.ctlFmt("type@{d} echo split-lives", .{second});
    _ = try app.ctlFmt("enter@{d}", .{second});
    try app.waitTextCount("split-lives", 2, 10_000);

    _ = try app.ctl("close");
    // The shell has to die and be reaped before the tree collapses.
    var waited: u32 = 0;
    while (waited < 5000 and try app.paneCount() != 1) : (waited += 100) {
        h.sleepMs(100);
    }
    try h.expectEq("panes after close", 1, try app.paneCount());
    try h.expectEq("focus back on the survivor", first, try app.focusedPane());
}

// ---------------------------------------------------------------- tabs

fn tabs(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    _ = try app.ctl("tab new");
    try h.expectEq("tabs after new", 2, try app.tabCount());
    // Two tabs, one pane each — `panes` spans every tab, so this also
    // catches a new tab that accidentally inherits the old one's panes.
    try h.expectEq("panes across both tabs", 2, try app.paneCount());

    const on_second = try app.focusedPane();
    _ = try app.ctl("tab prev");
    const on_first = try app.focusedPane();
    try h.expect(on_first != on_second, "tab prev should change the focused pane", .{});
    _ = try app.ctl("tab next");
    try h.expectEq("tab next returns", on_second, try app.focusedPane());
}

// -------------------------------------------------------------- editor

fn editor(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    var path_buf: [192]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/edit-me.txt", .{app.dirPath()});
    try h.writeFile(path, "alpha\nbravo\ncharlie\n");

    _ = try app.ctlFmt("edit {s}", .{path});
    // TAKEOVER, not a split: the editor overlays the focused pane and the
    // shell parks underneath still running, the way vim does. A pane
    // count of 2 here would mean the takeover regressed into a split.
    try h.expectEq("editor takes over the pane", 1, try app.paneCount());
    try app.waitText("bravo", 5_000);

    // dd on line one, then :w. `type` is the editor's input stream.
    _ = try app.ctl("type dd");
    _ = try app.ctl("type :w");
    _ = try app.ctl("enter");

    // The assertion that matters is on DISK, not on screen: a buffer
    // that renders correctly but never writes is the bug worth catching.
    var waited: u32 = 0;
    var content: [256]u8 = undefined;
    while (waited < 5000) : (waited += 100) {
        const got = h.readFile(path, &content) catch "";
        if (std.mem.indexOf(u8, got, "alpha") == null and got.len > 0) break;
        h.sleepMs(100);
    }
    const got = try h.readFile(path, &content);
    try h.expect(std.mem.indexOf(u8, got, "alpha") == null, "dd should have removed the first line, file is: \"{s}\"", .{got});
    try h.expectContains(got, "bravo", "the other lines survive");
    try h.expectContains(got, "charlie", "the other lines survive");

    // :q drops back to the parked shell — the other half of takeover, and
    // the half that actually loses work if it breaks.
    _ = try app.ctl("type :q");
    _ = try app.ctl("enter");
    try app.waitText("e2e$", 5_000);
    try h.expectEq("still one pane after :q", 1, try app.paneCount());
}

// -------------------------------------------------------------- pixels

fn pixels(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    // Something visually distinctive, so a blank window and a drawn one
    // cannot both pass.
    _ = try app.ctl("type echo PIXELPROOF");
    _ = try app.ctl("enter");
    try app.waitTextCount("PIXELPROOF", 2, 10_000);

    var path_buf: [192]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/shot.png", .{app.dirPath()});
    var s = try app.shot(path);
    defer s.deinit();

    try h.expect(s.width > 100 and s.height > 100, "drawable looks wrong: {d}x{d}", .{ s.width, s.height });
    // The atlas-flip bug was invisible to `dump` and obvious in pixels;
    // a uniform frame is the cheap signature of "drew nothing at all".
    const colors = s.distinctColors(8);
    try h.expect(colors >= 3, "frame has only {d} distinct colour(s) — the renderer drew nothing", .{colors});
}

// ------------------------------------------------------------ commands

fn commands(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }

    // The table an agent reads to know what rook can do.
    const list = try app.ctl("commands");
    try h.expectContains(list, "pane.split-right", "registry lists split");
    try h.expectContains(list, "palette.commands", "registry lists itself");
    try h.expectContains(list, ":PaneSplitRight", "ex-name is derived and printed");

    // Run by canonical id.
    _ = try app.ctl("run pane.split-right");
    try h.expectEq("split ran", 2, try app.paneCount());

    // Run by ALIAS — a config written in the wails keymap's vocabulary
    // and an agent using the canonical id must reach the same code.
    _ = try app.ctl("run session.new");
    try h.expectEq("session.new is tab.new", 2, try app.tabCount());

    // An unknown name declines rather than doing something surprising.
    const bad = try app.ctl("run nope.nothing");
    try h.expectContains(bad, "err", "unknown command is refused");

    // The ⌘K palette, driven blind: open it, type a filter, press Enter.
    // This is the path that deadlocks if a command is dispatched while
    // the palette still holds draw_lock -- every dispatch target takes
    // it again -- so the assertion after Enter is really a liveness test.
    const before = try app.paneCount();
    _ = try app.ctl("run palette.commands");
    const st = try app.ctl("palette");
    try h.expectContains(st, "mode:commands", "palette opened in command mode");

    _ = try app.ctl("type split right");
    const filtered = try app.ctl("palette");
    try h.expectContains(filtered, "*pane.split-right", "filter selects the split command");

    _ = try app.ctl("enter");
    // If this times out rather than failing, suspect the deadlock.
    var waited: u32 = 0;
    while (waited < 5000 and try app.paneCount() == before) : (waited += 100) {
        h.sleepMs(100);
    }
    try h.expectEq("palette Enter dispatched the command", before + 1, try app.paneCount());
    try h.expectContains(try app.ctl("palette"), "closed", "palette closed after activating");

    // The OTHER picker still works and still knows which one it is. The
    // two share one widget, so a mode leak would show up as the command
    // list appearing under the workspace prompt. (The sandbox has no
    // rook.db, so the list itself is legitimately empty here.)
    _ = try app.ctl("run workspace.switch");
    try h.expectContains(try app.ctl("palette"), "mode:workspaces", "workspace picker unaffected");
    _ = try app.ctl("key 1b"); // ESC
    try h.expectContains(try app.ctl("palette"), "closed", "ESC closes it");

    // The REAL ⌘K, as an NSEvent through AppKit's dispatch and our local
    // monitor. `run` above proves dispatch; only this proves the CHORD
    // reaches it. keycode 40 = 'k', modmask 0x100000 = command.
    _ = try app.ctl("nskey 40 100000 k");
    var waited2: u32 = 0;
    while (waited2 < 3000) : (waited2 += 100) {
        const s = try app.ctl("palette");
        if (std.mem.indexOf(u8, s, "mode:commands") != null) break;
        h.sleepMs(100);
    }
    try h.expectContains(try app.ctl("palette"), "mode:commands", "⌘K opens the command palette");
    _ = try app.ctl("key 1b");
}

// --------------------------------------------------------------- excmd

fn excmd(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    var path_buf: [192]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/ex.txt", .{app.dirPath()});
    try h.writeFile(path, "one\ntwo\n");
    _ = try app.ctlFmt("edit {s}", .{path});
    try app.waitText("two", 5_000);
    // Takeover, so still one pane — the split below is what changes it.
    try h.expectEq("editor took over", 1, try app.paneCount());

    // The negative cases FIRST, while the editor still has focus. A
    // successful split moves focus to the new pane, so anything typed
    // after it goes to a SHELL — which is how the first version of this
    // scenario ended up asserting against `sh: command not found`.

    // An unknown CamelCase name is refused by the registry, not silently
    // swallowed.
    _ = try app.ctl("type :NoSuchCommand");
    _ = try app.ctl("enter");
    try app.waitText("not a command", 5_000);

    // The editor's own namespace is untouched: a lowercase typo still
    // gets the EDITOR's message, because the bridge only ever sees
    // leading-capital verbs.
    _ = try app.ctl("type :wq2");
    _ = try app.ctl("enter");
    try app.waitText("not an editor command", 5_000);

    // :w still works — the bridge sits in the fallthrough, so a
    // regression here would mean it captured a verb it should not.
    _ = try app.ctl("type :w");
    _ = try app.ctl("enter");
    try app.waitText("wrote", 5_000);

    // The bridge itself, last. Same deferred route as the palette's
    // Enter: this runs inside the editor's key handling, under
    // draw_lock, and a self-deadlock here would time out rather than
    // fail.
    _ = try app.ctl("type :PaneSplitRight");
    _ = try app.ctl("enter");
    var waited: u32 = 0;
    while (waited < 5000 and try app.paneCount() == 1) : (waited += 100) {
        h.sleepMs(100);
    }
    try h.expectEq(":PaneSplitRight split the pane", 2, try app.paneCount());
}

// ------------------------------------------------------------ sidepane

/// Columns of the focused pane, from `panes` ("… grid 80x24").
fn paneCols(app: *h.Instance) !usize {
    const r = try app.ctl("panes");
    const g = std.mem.indexOf(u8, r, " grid ") orelse return error.AssertFailed;
    const rest = r[g + 6 ..];
    const x = std.mem.indexOfScalar(u8, rest, 'x') orelse return error.AssertFailed;
    return std.fmt.parseInt(usize, rest[0..x], 10) catch error.AssertFailed;
}

fn sidepane(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    try h.expectContains(try app.ctl("sidepane"), "closed", "starts closed");
    // Measured immediately before each toggle, never once at the top.
    // A tiling WM re-assigns the launch size ASYNCHRONOUSLY, so a column
    // count taken at startup can go stale mid-scenario — that made this
    // flake roughly one run in six with an exact-equality assertion.
    // Every claim here is relative to an adjacent measurement.
    const wide = try paneCols(app);

    // The assertion that separates a real container from a slab painted
    // OVER the panes: opening it must narrow the terminal's grid, which
    // means a pty resize reached the shell.
    _ = try app.ctl("run attention.inbox");
    const st = try app.ctl("sidepane");
    try h.expectContains(st, "open side:right panel:attention", "opened on the right");
    const narrow = try paneCols(app);
    try h.expect(narrow < wide, "pane should narrow: {d} cols before, {d} after", .{ wide, narrow });

    // The sandbox has no rook-host (XDG_STATE_HOME is unwritable on
    // purpose), so the honest render is "unreachable" — NOT an empty
    // list, which would read as "nothing needs you" and be a lie.
    try h.expectContains(try app.ctl("sidepane"), "host unreachable", "fails open, and says which");

    // Placement-agnostic: same tenant, other edge, same width.
    _ = try app.ctl("run panel.flip");
    try h.expectContains(try app.ctl("sidepane"), "open side:left", "flipped to the left");
    try h.expectEq("flip keeps the width", narrow, try paneCols(app));

    // It is chrome, not a pane: it must not appear in `panes`.
    try h.expectEq("side pane is not a pane", 1, try app.paneCount());

    // Toggling the SAME panel closes and gives the columns back. Compared
    // against the OPEN width, not the startup one: the direction is what
    // this asserts, and it is the part that cannot drift.
    const still_narrow = try paneCols(app);
    _ = try app.ctl("run attention.inbox");
    try h.expectContains(try app.ctl("sidepane"), "closed", "toggled shut");
    const restored = try paneCols(app);
    try h.expect(restored > still_narrow, "closing should give columns back: {d} open, {d} closed", .{ still_narrow, restored });

    // And the real chord, through AppKit's leader machine.
    _ = try app.ctl("press `");
    _ = try app.ctl("press a");
    var waited: u32 = 0;
    while (waited < 3000) : (waited += 100) {
        if (std.mem.indexOf(u8, try app.ctl("sidepane"), "open") != null) break;
        h.sleepMs(100);
    }
    try h.expectContains(try app.ctl("sidepane"), "open", "<leader>a toggles it");
}

// ---------------------------------------------------------------- asks

fn asks(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }

    // --- single select, with a recommendation ---
    _ = try app.ctl(
        \\ask {"questions":[{"question":"Ship it?","options":[{"label":"Yes","recommended":true},{"label":"No"}]}]}
    );
    const st = try app.ctl("sidepane");
    try h.expectContains(st, "panel:ask", "the ask takes the side pane");
    try h.expectContains(st, "Ship it?", "the question renders");
    // The asker's recommendation starts under the cursor, so Enter alone
    // is a complete answer — that is what `recommended` is FOR.
    try h.expectContains(st, "*( ) Yes", "recommended option is preselected");

    // Enter alone answers, because the recommendation was already under
    // the cursor. Nothing typed, so no `other`.
    _ = try app.ctl("enter");
    const ans = try app.ctl("ask-answer");
    try h.expectContains(ans, "\"selected\":[\"Yes\"]", "the picked label is in the answer");
    try h.expectContains(ans, "\"question\":\"Ship it?\"", "the question is echoed back");
    try h.expect(std.mem.indexOf(u8, ans, "other") == null, "no `other` when nothing was typed, got: {s}", .{ans});

    // --- the form owns the key path ---
    // If this leaks, a human's keystrokes go to a pty instead of the
    // form — and typing JUMPS TO OTHER, which is the whole point of that
    // row: never be forced to pick from options that miss the point.
    _ = try app.ctl(
        \\ask {"questions":[{"question":"Pick?","options":[{"label":"One"}]}]}
    );
    _ = try app.ctl("type xyzzy");
    try h.expectContains(try app.ctl("dump"), "e2e$", "typing did NOT reach the shell");
    try h.expectContains(try app.ctl("sidepane"), "*other: xyzzy", "typing moved to Other and wrote there");
    _ = try app.ctl("enter");
    const other = try app.ctl("ask-answer");
    try h.expectContains(other, "\"other\":\"xyzzy\"", "typed text becomes `other`");
    // Choosing your own words is NOT also choosing an option.
    try h.expectContains(other, "\"selected\":[]", "Other does not pick an option too");

    // The form yields the key path back when it is done.
    try h.expectContains(try app.ctl("sidepane"), "panel:attention", "form closes to the inbox");
    _ = try app.ctl("type back-to-shell");
    _ = try app.ctl("enter");
    try app.waitTextCount("back-to-shell", 2, 5_000);

    // --- multi select ---
    _ = try app.ctl(
        \\ask {"questions":[{"question":"Which?","multiSelect":true,"options":[{"label":"A"},{"label":"B"},{"label":"C"}]}]}
    );
    try h.expectContains(try app.ctl("sidepane"), "multi", "multi-select is marked as such");
    _ = try app.ctl("key 20"); // space: tick A
    _ = try app.ctl("key 0e"); // ⌃N: down to B
    _ = try app.ctl("key 20"); // space: tick B
    try h.expectContains(try app.ctl("sidepane"), "[x] A", "A stayed ticked after moving");
    _ = try app.ctl("enter");
    const multi = try app.ctl("ask-answer");
    try h.expectContains(multi, "\"selected\":[\"A\",\"B\"]", "both ticks are in the answer");

    // --- dismissal ---
    // ESC must post a real {"canceled":true}: silence would leave
    // `rookctl ask` blocked until someone kills it.
    _ = try app.ctl(
        \\ask {"questions":[{"question":"Nope?","options":[{"label":"X"}]}]}
    );
    _ = try app.ctl("key 1b"); // ESC
    try h.expectContains(try app.ctl("ask-answer"), "{\"canceled\":true}", "ESC produces a dismissal");
    try h.expectContains(try app.ctl("sidepane"), "panel:attention", "dismissal closes the form");

    // --- free text (a question with no options) ---
    _ = try app.ctl(
        \\ask {"questions":[{"question":"Name it"}]}
    );
    _ = try app.ctl("type widget");
    _ = try app.ctl("enter");
    try h.expectContains(try app.ctl("ask-answer"), "\"other\":\"widget\"", "free-text answers land in `other`");

    // --- a label with characters that would break the JSON ---
    // A stray quote in a body the host rejects means the answer is lost
    // and the asker blocks forever, so this is the sharp edge.
    _ = try app.ctl(
        \\ask {"questions":[{"question":"Quote \"this\"?","options":[{"label":"a\"b"}]}]}
    );
    _ = try app.ctl("enter");
    const esc = try app.ctl("ask-answer");
    try h.expectContains(esc, "\\\"", "quotes are escaped in the answer");
}

// ---------------------------------------------------------------- runner

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const argv = init.minimal.args.vector;
    // argv[1] is the rook binary (build.zig passes the artifact path);
    // anything after is a substring filter over scenario names.
    if (argv.len < 2) {
        std.debug.print("usage: e2e <path-to-rook> [filter...]\n", .{});
        return error.Usage;
    }
    const bin = std.mem.span(argv[1]);
    const filters = argv[2..];

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;

    std.debug.print("\nrook e2e — {s}\n\n", .{bin});
    for (scenarios) |s| {
        if (filters.len > 0) {
            var match = false;
            for (filters) |f| {
                if (std.mem.indexOf(u8, s.name, std.mem.span(f)) != null) match = true;
            }
            if (!match) {
                skipped += 1;
                continue;
            }
        }
        // Printed BEFORE the run, and deliberately not overwritten after.
        // No \r or erase-line: the main consumer of this output is an
        // agent reading a pipe, where a cursor trick is just noise — and
        // a scenario that hangs has to have already named itself.
        std.debug.print("  · {s} — {s}\n", .{ s.name, s.what });
        const t0 = h.nowMs();
        if (s.run(gpa, bin)) |_| {
            passed += 1;
            std.debug.print("    \u{2713} {s} ({d}ms)\n", .{ s.name, h.nowMs() - t0 });
        } else |err| {
            failed += 1;
            std.debug.print("    \u{2717} {s} ({s}, {d}ms)\n", .{ s.name, @errorName(err), h.nowMs() - t0 });
        }
    }

    std.debug.print("\n  {d} passed, {d} failed", .{ passed, failed });
    if (skipped > 0) std.debug.print(", {d} filtered out", .{skipped});
    std.debug.print("\n", .{});

    if (failed == 0) {
        h.cleanupSandboxes();
    } else {
        // The sandbox holds the app's own log and any shot the scenario
        // took. Keeping it is the difference between a failure you can
        // read and one you have to reproduce.
        std.debug.print("\n  {d} sandbox(es) kept for inspection: /tmp/rook-e2e-*\n", .{h.sandboxCount()});
        std.debug.print("  (make e2e-clean to remove them)\n", .{});
    }
    std.debug.print("\n", .{});
    if (failed > 0) return error.E2eFailed;
}

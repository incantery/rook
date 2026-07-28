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

//! The state feed: everything rook-mux knows, as one JSON snapshot.
//!
//! Rook is the single writer of this state. Consumers replicate it and
//! change it only by issuing commands — see docs/surfaces.md. The
//! whole snapshot goes out on every change rather than a delta: it is
//! small, it changes at human rate, and a consumer that misses a
//! snapshot is correct on the next one where a consumer that misses a
//! delta is wrong forever. It is also what lets a slow reader be
//! served by dropping the older snapshot instead of buffering.
//!
//! `sv` is a *server.Server; taken as anytype so the server that
//! imports this file does not have to be imported back.
const std = @import("std");

/// Schema version. Readers accept newer and skip what they don't know.
pub const version: u32 = 1;

/// A JSON string literal, escaped. Control bytes go to \u00XX; the
/// rest rides through, so UTF-8 in a cwd or a title survives.
pub fn str(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    out.append(gpa, '"') catch return;
    for (s) |c| switch (c) {
        '"' => out.appendSlice(gpa, "\\\"") catch return,
        '\\' => out.appendSlice(gpa, "\\\\") catch return,
        '\n' => out.appendSlice(gpa, "\\n") catch return,
        '\r' => out.appendSlice(gpa, "\\r") catch return,
        '\t' => out.appendSlice(gpa, "\\t") catch return,
        0...8, 11, 12, 14...31 => out.print(gpa, "\\u{x:0>4}", .{c}) catch return,
        else => out.append(gpa, c) catch return,
    };
    out.append(gpa, '"') catch return;
}

fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

/// Which fields a build emits. The feed detects change by diffing
/// snapshots, so the form it diffs has to leave out anything that
/// would make the diff see itself.
pub const Form = struct {
    /// The fields that move with pty output: the foreground program, a
    /// window's name (which is that program), the cwd, and the activity
    /// stamp. A shell loop respawns its child faster than the poll
    /// floor, so diffing on these pushes to every subscriber twenty
    /// times a second for as long as a build is running. They get a
    /// slower cadence of their own.
    drift: bool = true,
    /// `epoch` and `serial`. Omitted when diffing: bumping the serial
    /// must not itself read as a change, or the feed feeds itself.
    identity: bool = true,
};

/// Build the snapshot into `out` (cleared first).
pub fn build(sv: anytype, out: *std.ArrayList(u8), form: Form) void {
    const gpa = sv.gpa;
    out.clearRetainingCapacity();
    const g = sv.geometry();

    out.print(gpa, "{{\"rookMuxState\":{d}", .{version}) catch return;
    if (form.identity) {
        out.appendSlice(gpa, ",\"epoch\":") catch return;
        str(gpa, out, &sv.epoch);
        out.print(gpa, ",\"serial\":{d}", .{sv.serial}) catch return;
    }
    out.print(gpa, ",\"pid\":{d}", .{sv.pid}) catch return;
    out.print(gpa, ",\"geometry\":{{\"cols\":{d},\"rows\":{d}}}", .{ g.cols, g.rows }) catch return;

    // Focus: the pane input goes to, and whether the mux is holding it
    // (copy mode and popups take the keyboard away from the pane).
    out.print(gpa, ",\"focus\":{{\"pane\":{d},\"mode\":\"{s}\"}}", .{
        sv.focusedId(),
        if (sv.popup != null) "popup" else if (sv.scrolling) "copy" else "pane",
    }) catch return;

    // ---- workspaces → windows → layout
    out.appendSlice(gpa, ",\"workspaces\":[") catch return;
    for (sv.sessions.items, 0..) |sn, si| {
        if (si > 0) out.append(gpa, ',') catch return;
        out.appendSlice(gpa, "{\"name\":") catch return;
        str(gpa, out, sn.label());
        out.print(gpa, ",\"current\":{s},\"windows\":[", .{boolStr(si == sv.cur_sess)}) catch return;
        for (sn.windows.items, 0..) |w, wi| {
            if (wi > 0) out.append(gpa, ',') catch return;
            var nb: [64]u8 = undefined;
            const name: []const u8 = if (!form.drift) "" else if (sv.pane(w.focused)) |p| (p.fgName(&nb) orelse "shell") else "shell";
            out.print(gpa, "{{\"index\":{d},\"name\":", .{wi + 1}) catch return;
            str(gpa, out, name);
            out.print(gpa, ",\"current\":{s},\"zoomed\":{s},\"focus\":{d},\"layout\":", .{
                boolStr(wi == sn.cur),
                boolStr(w.zoomed),
                w.focused,
            }) catch return;
            w.layout.writeJson(gpa, out);
            out.append(gpa, '}') catch return;
        }
        out.appendSlice(gpa, "],\"pins\":[") catch return;
        for (sn.pins.items, 0..) |id, i| {
            if (i > 0) out.append(gpa, ',') catch return;
            out.print(gpa, "{d}", .{id}) catch return;
        }
        out.appendSlice(gpa, "]}") catch return;
    }
    out.appendSlice(gpa, "]") catch return;

    // ---- panes, flat: every id above resolves here
    out.appendSlice(gpa, ",\"panes\":[") catch return;
    for (sv.panes.items, 0..) |p, i| {
        if (i > 0) out.append(gpa, ',') catch return;
        var nb: [64]u8 = undefined;
        var cb: [1024]u8 = undefined;
        out.print(gpa, "{{\"id\":{d},\"pid\":{d},\"program\":", .{ p.id, p.pid }) catch return;
        str(gpa, out, if (!form.drift) "" else p.fgName(&nb) orelse "shell");
        out.appendSlice(gpa, ",\"cwd\":") catch return;
        str(gpa, out, if (!form.drift) "" else if (p.fgCwd(&cb)) |c| c else "");
        out.print(gpa, ",\"cols\":{d},\"rows\":{d}", .{ p.cols, p.rows }) catch return;
        // where it is on the glass right now, if it is placed at all
        var rect: ?@TypeOf(sv.placed.items[0].rect) = null;
        for (sv.placed.items) |pl| {
            if (pl.pane == p.id) rect = pl.rect;
        }
        if (rect) |r| {
            out.print(gpa, ",\"rect\":{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}}", .{ r.x, r.y, r.w, r.h }) catch return;
        } else {
            out.appendSlice(gpa, ",\"rect\":null") catch return;
        }
        out.print(gpa, ",\"focused\":{s},\"visible\":{s},\"wantsMouse\":{s},\"exited\":{s}", .{
            boolStr(p.id == sv.focusedId()),
            boolStr(rect != null),
            boolStr(p.wantsMouse()),
            boolStr(p.exited.load(.acquire)),
        }) catch return;
        if (form.drift) {
            out.print(gpa, ",\"lastOutputMs\":{d}", .{p.last_output_ms.load(.acquire)}) catch return;
        }
        out.append(gpa, '}') catch return;
    }
    out.appendSlice(gpa, "]") catch return;

    // ---- pins, surfaces, clients
    out.appendSlice(gpa, ",\"pins\":[") catch return;
    for (sv.global_pins.items, 0..) |id, i| {
        if (i > 0) out.append(gpa, ',') catch return;
        out.print(gpa, "{{\"pane\":{d},\"scope\":\"global\"}}", .{id}) catch return;
    }
    for (sv.sessions.items) |sn| {
        for (sn.pins.items) |id| {
            if (out.items[out.items.len - 1] != '[') out.append(gpa, ',') catch return;
            out.print(gpa, "{{\"pane\":{d},\"scope\":", .{id}) catch return;
            str(gpa, out, sn.label());
            out.append(gpa, '}') catch return;
        }
    }
    out.appendSlice(gpa, "]") catch return;

    // The side rail is two surfaces sharing one left dock. Each
    // republishes the last model pushed to it *verbatim*: rook is
    // already holding those bytes because it paints them, it never
    // interprets them, and a second glass can render the rail without
    // talking to whoever produced it.
    out.appendSlice(gpa, ",\"surfaces\":[") catch return;
    const rail = [_]struct { name: []const u8, raw: []const u8 }{
        .{ .name = "spaces", .raw = sv.side.spaces.raw },
        .{ .name = "agents", .raw = sv.side.agents.raw },
    };
    for (rail, 0..) |sf, i| {
        if (i > 0) out.append(gpa, ',') catch return;
        out.appendSlice(gpa, "{\"name\":") catch return;
        str(gpa, out, sf.name);
        out.print(gpa, ",\"place\":\"dock:left\",\"size\":{d},\"shown\":{s},\"model\":", .{
            sv.side_w orelse sv.conf.sidebar_width,
            boolStr(sv.side_w != null),
        }) catch return;
        // A stored frame is one line of valid JSON — that is checked
        // when it is taken — so it embeds as-is.
        if (sf.raw.len > 0) {
            out.appendSlice(gpa, sf.raw) catch return;
        } else {
            out.appendSlice(gpa, "null") catch return;
        }
        out.append(gpa, '}') catch return;
    }
    out.appendSlice(gpa, "]") catch return;

    out.appendSlice(gpa, ",\"clients\":[") catch return;
    var n: usize = 0;
    for (sv.clients.items) |c| {
        if (c.dead) continue;
        if (n > 0) out.append(gpa, ',') catch return;
        n += 1;
        out.print(gpa, "{{\"cols\":{d},\"rows\":{d},\"attached\":{s},\"block\":{d}}}", .{
            c.cols,
            c.rows,
            boolStr(c.attached),
            c.block orelse 0,
        }) catch return;
    }
    out.appendSlice(gpa, "]}\n") catch return;
}

//! The session view — a claude transcript, rendered to text.
//!
//! `GET /agents/{id}/transcript` serves whole records (the host reads the
//! jsonl on demand and never retains it). This turns them into a
//! DOCUMENT, which is the whole design: rook's editor is already a
//! renderer with scrolling, search, motions and yank, so a transcript
//! becomes a buffer rather than a bespoke viewer. The same simplification
//! threads will want.
//!
//! Unlike the other panels this ALLOCATES — a timeline is a document,
//! not a status line. It is built on a background thread and handed to
//! the editor, which then owns it; nothing here is read from the render
//! path.

const std = @import("std");
const hostc = @import("hostc.zig");

/// One content block. `thinking` carries no text on purpose: Claude Code
/// writes those with an encrypted signature and nothing renderable — the
/// host strips the signature and keeps the block so a turn's SHAPE
/// survives, and so should we.
const Block = struct {
    type: []const u8 = "",
    text: []const u8 = "",
    name: []const u8 = "",
    input: std.json.Value = .null,
    content: []const u8 = "",
    isError: bool = false,
};

const Record = struct {
    offset: i64 = 0,
    type: []const u8 = "",
    model: []const u8 = "",
    subtype: []const u8 = "",
    durationMs: i64 = 0,
    blocks: []const Block = &.{},
};

const Body = struct {
    sessionId: []const u8 = "",
    records: []const Record = &.{},
    more: bool = false,
};

/// How many records to pull. The host's own note: the last 200 records of
/// a real 1.3MB transcript are ~485KB, and the window is what bounds the
/// response — the fix for a painful session is a smaller window, never
/// truncated content.
pub const window = 200;

/// Fetch and render. Caller owns the returned text.
pub fn fetchRendered(gpa: std.mem.Allocator, io: std.Io, id: []const u8) ?[]u8 {
    const info = hostc.readInfo(gpa, io) orelse return null;
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/agents/{s}/transcript?limit={d}", .{ id, window }) catch return null;
    var resp = hostc.get(gpa, &info, path, 4 * 1024 * 1024) orelse return null;
    defer resp.deinit(gpa);
    if (resp.status != 200) return null;
    return render(gpa, resp.body);
}

/// Body → document. Split from the fetch so the shape can be tested
/// without a daemon.
pub fn render(gpa: std.mem.Allocator, body: []const u8) ?[]u8 {
    // Say WHY on failure. A silent null here reads as "the transcript is
    // empty", which is the least useful thing it could mean — the wire is
    // the host's to change and a type mismatch has to be findable.
    const parsed = std.json.parseFromSlice(Body, gpa, body, .{ .ignore_unknown_fields = true }) catch |e| {
        std.debug.print("rook transcript: parse failed ({s}), {d} bytes\n", .{ @errorName(e), body.len });
        return null;
    };
    defer parsed.deinit();

    // Zig 0.16: ArrayList has no `.writer()` any more — a growable
    // formatted sink is `std.Io.Writer.Allocating`. (Fourth std removal
    // this codebase has had to absorb; see the harness for the others.)
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    if (parsed.value.more)
        w.print("… older records not shown (window is {d})\n\n", .{window}) catch return null;

    for (parsed.value.records) |rec| {
        // A turn-duration system record is a footer for the turn above
        // it, not a speaker — rendering it as one would put an empty
        // block between every exchange.
        if (std.mem.eql(u8, rec.type, "system")) {
            if (rec.durationMs > 0)
                w.print("    ({d}ms)\n\n", .{rec.durationMs}) catch {};
            continue;
        }

        // A `user` record carrying only tool_result blocks is the TOOL
        // answering, not the human speaking — that is just how Claude
        // Code's wire works. Heading it "user" makes a build log look
        // like something you said, which is actively misleading in the
        // one view whose whole job is showing who said what. The `→`
        // marks already identify the lines, so it gets no heading.
        if (!onlyToolResults(rec.blocks)) {
            const who = if (std.mem.eql(u8, rec.type, "user")) "user" else "assistant";
            if (rec.model.len > 0) {
                w.print("── {s} · {s} ──\n", .{ who, rec.model }) catch {};
            } else {
                w.print("── {s} ──\n", .{who}) catch {};
            }
        }

        for (rec.blocks) |b| {
            if (std.mem.eql(u8, b.type, "text")) {
                if (b.text.len > 0) w.print("{s}\n", .{b.text}) catch {};
            } else if (std.mem.eql(u8, b.type, "thinking")) {
                // Empty by construction — say it happened, not what it was.
                _ = w.write("  · thinking\n") catch {};
            } else if (std.mem.eql(u8, b.type, "tool_use")) {
                w.print("  ⚒ {s}", .{b.name}) catch {};
                writeToolInput(w, b.input);
                _ = w.write("\n") catch {};
            } else if (std.mem.eql(u8, b.type, "tool_result")) {
                const mark: []const u8 = if (b.isError) "  ✗ " else "  → ";
                writeIndented(w, mark, b.content, 6);
            }
        }
        _ = w.write("\n") catch {};
    }
    var list = aw.toArrayList();
    return list.toOwnedSlice(gpa) catch null;
}

/// Is this record purely a tool answering? (Empty blocks is not — that
/// is a record with nothing in it, and suppressing its heading would
/// hide the turn entirely.)
fn onlyToolResults(blocks: []const Block) bool {
    if (blocks.len == 0) return false;
    for (blocks) |b| {
        if (!std.mem.eql(u8, b.type, "tool_result")) return false;
    }
    return true;
}

/// A tool call's arguments, on one line and readable.
///
/// The whole input is often a file's new contents — rendering it inline
/// would bury the conversation in the thing it was about. The path (or
/// command, or pattern) is what identifies the call; the rest is noise
/// at this altitude.
fn writeToolInput(w: anytype, input: std.json.Value) void {
    const obj = switch (input) {
        .object => |o| o,
        else => return,
    };
    // Ordered by how much each identifies a call, first hit wins.
    for ([_][]const u8{ "file_path", "path", "command", "pattern", "url", "query", "prompt" }) |key| {
        const v = obj.get(key) orelse continue;
        const s = switch (v) {
            .string => |str| str,
            else => continue,
        };
        const one = s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
        const clipped = one[0..@min(one.len, 90)];
        w.print(" {s}{s}", .{ clipped, @as([]const u8, if (clipped.len < s.len) "…" else "") }) catch {};
        return;
    }
}

/// A tool result, clipped and indented under its call.
///
/// Results are the bulk of a transcript and most of them are long — a
/// full `cat` of a file, a build log. Six lines is enough to see WHAT
/// came back; the transcript is not the place to read it in full.
fn writeIndented(w: anytype, mark: []const u8, text: []const u8, max_lines: usize) void {
    if (text.len == 0) return;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        if (n >= max_lines) {
            _ = w.write("    …\n") catch {};
            return;
        }
        const clipped = line[0..@min(line.len, 100)];
        if (n == 0) {
            w.print("{s}{s}\n", .{ mark, clipped }) catch return;
        } else {
            w.print("    {s}\n", .{clipped}) catch return;
        }
        n += 1;
    }
}

// ----------------------------------------------------------------- tests

const t = std.testing;

test "renders a conversation with tools" {
    const body =
        \\{"sessionId":"s","more":false,"records":[
        \\ {"offset":0,"type":"user","blocks":[{"type":"text","text":"fix the parser"}]},
        \\ {"offset":1,"type":"assistant","model":"claude-opus-5","blocks":[
        \\   {"type":"text","text":"Reading it now."},
        \\   {"type":"tool_use","name":"Read","input":{"file_path":"/tmp/parser.zig"}},
        \\   {"type":"tool_result","content":"line one\nline two"}]},
        \\ {"offset":2,"type":"system","subtype":"turn_duration","durationMs":1234}]}
    ;
    const got = render(t.allocator, body).?;
    defer t.allocator.free(got);
    try t.expect(std.mem.indexOf(u8, got, "── user ──") != null);
    try t.expect(std.mem.indexOf(u8, got, "fix the parser") != null);
    try t.expect(std.mem.indexOf(u8, got, "── assistant · claude-opus-5 ──") != null);
    // The tool call shows WHICH file, not the whole input.
    try t.expect(std.mem.indexOf(u8, got, "⚒ Read /tmp/parser.zig") != null);
    try t.expect(std.mem.indexOf(u8, got, "→ line one") != null);
    try t.expect(std.mem.indexOf(u8, got, "(1234ms)") != null);
}

test "a tool result is not attributed to the user" {
    // Claude Code sends tool results back as `user` records. Heading them
    // "user" makes a build log read as something the human said.
    const body =
        \\{"records":[
        \\ {"type":"user","blocks":[{"type":"tool_result","content":"build ok"}]},
        \\ {"type":"user","blocks":[{"type":"text","text":"now ship it"}]}]}
    ;
    const got = render(t.allocator, body).?;
    defer t.allocator.free(got);
    try t.expect(std.mem.indexOf(u8, got, "→ build ok") != null);
    // Exactly one "user" heading — the real one.
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, got, i, "── user ──")) |at| : (i = at + 1) n += 1;
    try t.expectEqual(@as(usize, 1), n);
    try t.expect(std.mem.indexOf(u8, got, "now ship it") != null);
}

test "a thinking block is reported, not rendered" {
    // Claude Code writes these with an encrypted signature and no text.
    // Dropping them entirely would silently change a turn's shape.
    const body =
        \\{"records":[{"type":"assistant","blocks":[
        \\  {"type":"thinking","text":""},{"type":"text","text":"done"}]}]}
    ;
    const got = render(t.allocator, body).?;
    defer t.allocator.free(got);
    try t.expect(std.mem.indexOf(u8, got, "· thinking") != null);
    try t.expect(std.mem.indexOf(u8, got, "done") != null);
}

test "an error result is marked as one" {
    const body =
        \\{"records":[{"type":"assistant","blocks":[
        \\  {"type":"tool_result","content":"boom","isError":true}]}]}
    ;
    const got = render(t.allocator, body).?;
    defer t.allocator.free(got);
    try t.expect(std.mem.indexOf(u8, got, "✗ boom") != null);
}

test "a long tool result is clipped, and says so" {
    const body =
        \\{"records":[{"type":"assistant","blocks":[
        \\  {"type":"tool_result","content":"1\n2\n3\n4\n5\n6\n7\n8\n9"}]}]}
    ;
    const got = render(t.allocator, body).?;
    defer t.allocator.free(got);
    try t.expect(std.mem.indexOf(u8, got, "→ 1") != null);
    try t.expect(std.mem.indexOf(u8, got, "…") != null);
    // Never silently: line 9 must be gone AND the ellipsis present.
    try t.expect(std.mem.indexOf(u8, got, "\n    9\n") == null);
}

test "a windowed response says older records exist" {
    const got = render(t.allocator, "{\"more\":true,\"records\":[]}").?;
    defer t.allocator.free(got);
    try t.expect(std.mem.indexOf(u8, got, "older records not shown") != null);
}

test "malformed JSON declines rather than half-rendering" {
    try t.expect(render(t.allocator, "not json") == null);
}

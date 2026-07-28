//! Paste encoding: pasteboard bytes → what actually goes down the pty.
//!
//! Pure data in, data out — no AppKit, no session, no allocator tricks —
//! so the rules that matter for safety are headless-testable (`zig test
//! src/paste.zig`). The rules themselves are xterm's, by way of ghostty:
//! they are not ours to invent, because every shell and TUI on the other
//! side of the pty was written against them.

const std = @import("std");

/// xterm's insertion strip set: bytes replaced by a SPACE for any text
/// insertion (paste, drag-and-drop), bracketed or not.
///
/// ESC is the load-bearing one. It is what makes an injected end-fence
/// ("\x1b[201~ rm -rf /") inert — the escape can never survive the strip,
/// so pasted text cannot close its own bracket and become commands. The
/// terminal control characters below it (VINTR, VSUSP, …) are stripped
/// for the same reason: paste is text, and text should not be able to
/// signal the foreground process. They're hardcoded like xterm's are —
/// tcsetattr can technically remap them, but nothing modern does.
pub const STRIP = [_]u8{
    0x00, // NUL
    0x03, // VINTR   ⌃C
    0x04, // EOT     ⌃D
    0x05, // ENQ
    0x08, // BS
    0x0f, // VDISCARD ⌃O
    0x11, // VSTART  ⌃Q
    0x12, // VREPRINT ⌃R
    0x13, // VSTOP   ⌃S
    0x15, // VKILL   ⌃U
    0x16, // VLNEXT  ⌃V
    0x17, // VWERASE ⌃W
    0x1a, // VSUSP   ⌃Z
    0x1b, // ESC
    0x1c, // VQUIT   ⌃\
    0x7f, // DEL
};

/// Does this data look safe to paste unframed? Unsafe means it can turn
/// into commands on its own: a newline (the shell runs the line) or an
/// end-fence (it escapes bracketed paste). Judged on the RAW data,
/// independent of terminal state — a paste carrying "\x1b[201~" is
/// suspicious even when nothing is bracketed.
///
/// rookz does not yet gate on this (no confirmation modal — see
/// PARITY.md §0); it exists so the gate has something to ask.
pub fn isSafe(data: []const u8) bool {
    return std.mem.indexOfScalar(u8, data, '\n') == null and
        std.mem.indexOf(u8, data, "\x1b[201~") == null;
}

/// Encode `data` for writing to a pty. Caller owns the result.
///
/// Bracketed (DECSET 2004): fence it and leave the newlines alone — the
/// fence is the whole point, the app reads the run as one insertion and
/// decides what a newline means. Unbracketed: '\n' becomes '\r', because
/// the pty is a terminal line discipline and CR is what Return sends.
/// "\r\n" therefore becomes "\r\r", which looks wrong and is exactly
/// what xterm does; a shell treats the second one as an empty line.
pub fn encode(gpa: std.mem.Allocator, data: []const u8, bracketed: bool) ![]u8 {
    const fence_in = "\x1b[200~";
    const fence_out = "\x1b[201~";
    const extra = if (bracketed) fence_in.len + fence_out.len else 0;

    var out = try gpa.alloc(u8, data.len + extra);
    errdefer gpa.free(out);

    var body = out;
    if (bracketed) {
        @memcpy(out[0..fence_in.len], fence_in);
        @memcpy(out[out.len - fence_out.len ..], fence_out);
        body = out[fence_in.len .. out.len - fence_out.len];
    }
    @memcpy(body, data);

    for (body) |*b| {
        if (std.mem.indexOfScalar(u8, &STRIP, b.*) != null) {
            b.* = ' ';
        } else if (!bracketed and b.* == '\n') {
            b.* = '\r';
        }
    }
    return out;
}

const testing = std.testing;

test "bracketed keeps newlines and fences the run" {
    const out = try encode(testing.allocator, "ls -la\necho hi", true);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\x1b[200~ls -la\necho hi\x1b[201~", out);
}

test "unbracketed turns newlines into carriage returns" {
    const out = try encode(testing.allocator, "ls\r\necho hi\n", false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("ls\r\recho hi\r", out);
}

test "the fence cannot be smuggled in: ESC becomes a space" {
    // The attack: a clipboard payload that closes the bracket itself and
    // runs what follows. The stripped ESC leaves inert text behind.
    const out = try encode(testing.allocator, "x\x1b[201~rm -rf /", true);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\x1b[200~x [201~rm -rf /\x1b[201~", out);
    // ...and the only 201~ fence in the result is the one we wrote.
    try testing.expectEqual(@as(usize, out.len - 6), std.mem.indexOf(u8, out, "\x1b[201~").?);
}

test "control characters that would signal the foreground process" {
    const out = try encode(testing.allocator, "a\x03b\x1ac\x00d", true);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\x1b[200~a b c d\x1b[201~", out);
}

test "plain text is untouched either way" {
    const b = try encode(testing.allocator, "hello", true);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("\x1b[200~hello\x1b[201~", b);
    const u = try encode(testing.allocator, "hello", false);
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("hello", u);
}

test "tabs survive: shells and editors both want them" {
    const out = try encode(testing.allocator, "a\tb", false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a\tb", out);
}

test isSafe {
    try testing.expect(isSafe("one line"));
    try testing.expect(!isSafe("two\nlines"));
    try testing.expect(!isSafe("sneaky\x1b[201~"));
}

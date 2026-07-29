//! Guards `width.zig` against drifting away from the terminal.
//!
//! The editor's width table is generated FROM ghostty's, because the
//! editor is a pure model and ghostty-vt costs a C++ dependency
//! (simdutf, highway) that its headless test root is deliberately
//! without. Generated data goes stale, so this root — which does have
//! the dependency — re-derives the answer for every codepoint and
//! asserts the two agree. A ghostty upgrade that moves a boundary fails
//! here, rather than showing up as a cursor landing one cell off in a
//! Japanese file.

const std = @import("std");
const vt = @import("ghostty-vt");
const width = @import("width.zig");

test "the editor and the terminal agree on which codepoints are wide" {
    var cp: u21 = 0;
    var wide: usize = 0;
    while (cp < 0x110000) : (cp += 1) {
        const want = vt.unicode.codepointWidth(cp) == 2;
        if (want) wide += 1;
        if (want != width.isWide(cp)) {
            std.debug.print(
                "U+{X}: ghostty wide={}, width.zig wide={}\n",
                .{ cp, want, width.isWide(cp) },
            );
            return error.WidthDrift;
        }
    }
    // A table that matched because it said "no" to everything would
    // pass the loop above.
    try std.testing.expect(wide > 100_000);
}

test "zero width is deliberately NOT adopted" {
    // This renderer maps one cell to one atlas glyph and cannot compose
    // a combining mark onto the glyph before it, so a zero-width
    // codepoint keeps a cell of its own here. If that ever changes,
    // this test is the reminder that width.zig has to change with it.
    try std.testing.expectEqual(@as(u2, 0), vt.unicode.codepointWidth(0x301));
    try std.testing.expectEqual(@as(u2, 1), width.cellWidth(0x301));
}

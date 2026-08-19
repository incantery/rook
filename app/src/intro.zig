//! The start screen's model.
//!
//! Its own file, and a leaf one — no imports beyond std. The renderer
//! (`editor.zig`) and the plugin client (`plugins.zig`) both have to
//! name this type, and neither can import the other: the editor is its
//! own test root and must not drag in config parsing, and the plugin
//! client's test root has no terminal library. A shared leaf is what
//! keeps that from becoming two types that drift.

const std = @import("std");

/// The start screen's content — what a bare `re` paints over an empty
/// scratch buffer, when something has filled it in.
///
/// A MODEL, not a frame. Each row says WHAT it is and what pressing it
/// reaches; the editor decides where every one of them lands, how wide
/// the block is, and what colour a jump letter wears. That line is
/// `docs/environments/VISION.md`'s, and it is the whole reason this can
/// come from a plugin: a supplier that shipped coordinates would be
/// drawing into the editor, and the next theme, font or pane width
/// would prove it wrong with nobody able to fix it from in here.
///
/// Fixed buffers and no allocation on the draw path, the same shape and
/// the same reason as `plugins.Snapshot`: this is filled once, off the
/// key path, and read by a renderer that must not touch a heap.
pub const Intro = struct {
    pub const max_rows = 64;
    pub const max_label = 120;
    pub const max_detail = 24;
    pub const max_target = 512;
    pub const max_cmd = 48;

    pub const Kind = enum {
        /// A line of the header, drawn as it arrives and centred as one
        /// block with its neighbours.
        art,
        /// A section heading — "recent", "sessions".
        heading,
        /// A row a letter reaches.
        entry,
        /// Vertical space. A row rather than a rule the renderer
        /// invented, so the rhythm between sections belongs to whoever
        /// knows what the sections mean.
        blank,
    };

    pub fn Text(comptime n: usize) type {
        return struct {
            b: [n]u8 = @splat(0),
            n: usize = 0,
            pub fn set(self: *@This(), s: []const u8) void {
                self.n = @min(n, s.len);
                @memcpy(self.b[0..self.n], s[0..self.n]);
            }
            pub fn get(self: *const @This()) []const u8 {
                return self.b[0..self.n];
            }
        };
    }

    pub const Row = struct {
        kind: Kind = .blank,
        /// The letter that reaches this row, or 0 for none. The editor
        /// never assigns these: two sections that both start at `a` are
        /// a collision the supplier can see across the whole screen and
        /// the renderer cannot see at all.
        key: u8 = 0,
        label: Text(max_label) = .{},
        /// The dim right-hand column — an age, a branch, a count.
        detail: Text(max_detail) = .{},
        /// Pressing the key opens this path in THIS pane...
        path: Text(max_target) = .{},
        /// ...or runs this registry command through the app seam. A row
        /// with neither is text you cannot press.
        cmd: Text(max_cmd) = .{},
    };

    rows: [max_rows]Row = @splat(.{}),
    n: usize = 0,

    pub fn add(self: *Intro, row: Row) void {
        if (self.n >= max_rows) return;
        self.rows[self.n] = row;
        self.n += 1;
    }

    pub fn slice(self: *const Intro) []const Row {
        return self.rows[0..self.n];
    }
};

//! Themes — one flat palette struct covering the terminal, the
//! chrome, and the editor. Slice one: builtins only, chosen by
//! `theme = "nocturne"` in config.toml; the wails app's semantic
//! theme engine (runtime swap, VS Code import) comes later.

const std = @import("std");

pub const Theme = struct {
    name: []const u8,

    /// When false, the emulator keeps ghostty's stock defaults
    /// (black bg / white fg / xterm palette).
    override_term: bool,
    term_bg: [3]u8,
    term_fg: [3]u8,
    cursor: [3]u8,
    ansi: [16][3]u8,
    /// Mouse-selection tint (terminal cells).
    sel_bg: [3]u8,

    // Chrome.
    sep: [4]u8,
    accent: [4]u8,
    on_accent: [4]u8,
    bar_bg: [4]u8,
    bar_fg: [4]u8,
    bar_value: [4]u8,
    chip_active_bg: [4]u8,

    // Editor pane.
    ed_bg: [4]u8,
    ed_fg: [4]u8,
    ed_dim: [4]u8,
    ed_sel_bg: [4]u8,
    ed_err: [4]u8,

    // Editor syntax (tree-sitter capture buckets).
    syn_comment: [4]u8,
    syn_string: [4]u8,
    syn_number: [4]u8,
    syn_keyword: [4]u8,
    syn_type: [4]u8,
    syn_func: [4]u8,
};

/// The colors rookz shipped with — kept exactly, as the fallback.
pub const default: Theme = .{
    .name = "default",
    .override_term = false,
    .term_bg = .{ 0, 0, 0 },
    .term_fg = .{ 255, 255, 255 },
    .cursor = .{ 255, 255, 255 },
    .ansi = undefined, // unused when override_term = false
    .sel_bg = .{ 58, 62, 88 },
    .sep = .{ 60, 60, 68, 255 },
    .accent = .{ 122, 162, 247, 255 },
    .on_accent = .{ 30, 30, 38, 255 },
    .bar_bg = .{ 30, 30, 38, 255 },
    .bar_fg = .{ 148, 150, 166, 255 },
    .bar_value = .{ 205, 208, 220, 255 },
    .chip_active_bg = .{ 48, 50, 62, 255 },
    .ed_bg = .{ 18, 19, 26, 255 },
    .ed_fg = .{ 205, 208, 220, 255 },
    .ed_dim = .{ 96, 99, 116, 255 },
    .ed_sel_bg = .{ 58, 62, 88, 255 },
    .ed_err = .{ 247, 118, 142, 255 },
    .syn_comment = .{ 96, 99, 116, 255 },
    .syn_string = .{ 158, 206, 106, 255 },
    .syn_number = .{ 255, 158, 100, 255 },
    .syn_keyword = .{ 187, 154, 247, 255 },
    .syn_type = .{ 115, 218, 202, 255 },
    .syn_func = .{ 122, 162, 247, 255 },
};

/// Nocturne — rook's own (the Claude Design boards, 2026-07-22).
/// Deep indigo grounds, blurple accent, deliberately muted hues.
/// Values lifted from frontend/src/theme/nocturne.ts: bg #14161f,
/// sunken #12141d (bar), raise #1a1c2e (chips), hairline #232637,
/// accent #9184d9, cursor #8f84c9, selection #393757.
pub const nocturne: Theme = .{
    .name = "nocturne",
    .override_term = true,
    .term_bg = .{ 0x14, 0x16, 0x1f },
    .term_fg = .{ 0xcd, 0xd0, 0xdd }, // editorFg — body text stock
    .cursor = .{ 0x8f, 0x84, 0xc9 },
    .ansi = .{
        .{ 0x23, 0x26, 0x37 }, // 0 black — a surface step
        .{ 0xd9, 0x8a, 0x8a }, // 1 red
        .{ 0x79, 0xb9, 0x8a }, // 2 green
        .{ 0xd9, 0xbd, 0x7f }, // 3 yellow
        .{ 0x8e, 0xa9, 0xdd }, // 4 blue
        .{ 0xb8, 0xab, 0xee }, // 5 magenta
        .{ 0x89, 0xc2, 0xc5 }, // 6 cyan
        .{ 0xcd, 0xd0, 0xdd }, // 7 white
        .{ 0x56, 0x5a, 0x70 }, // 8 bright black
        .{ 0xe8, 0xa3, 0xa3 }, // 9 bright red
        .{ 0x94, 0xcc, 0xa3 }, // 10 bright green
        .{ 0xe8, 0xd0, 0x9a }, // 11 bright yellow
        .{ 0xa3, 0xc0, 0xe8 }, // 12 bright blue
        .{ 0xcb, 0xc2, 0xf5 }, // 13 bright magenta
        .{ 0xa3, 0xd5, 0xd8 }, // 14 bright cyan
        .{ 0xe9, 0xe9, 0xed }, // 15 bright white
    },
    .sel_bg = .{ 0x39, 0x37, 0x57 },
    .sep = .{ 0x23, 0x26, 0x37, 255 },
    .accent = .{ 0x91, 0x84, 0xd9, 255 },
    .on_accent = .{ 0x10, 0x12, 0x1c, 255 },
    .bar_bg = .{ 0x12, 0x14, 0x1d, 255 }, // sunken
    .bar_fg = .{ 0x8b, 0x8f, 0xa8, 255 }, // dim
    .bar_value = .{ 0xcd, 0xd0, 0xdd, 255 },
    .chip_active_bg = .{ 0x1a, 0x1c, 0x2e, 255 }, // raise
    .ed_bg = .{ 0x14, 0x16, 0x1f, 255 },
    .ed_fg = .{ 0xcd, 0xd0, 0xdd, 255 },
    .ed_dim = .{ 0x56, 0x5a, 0x70, 255 }, // lo
    .ed_sel_bg = .{ 0x39, 0x37, 0x57, 255 },
    .ed_err = .{ 0xd9, 0x8a, 0x8a, 255 },
    // nocturne.ts syntax block: comments deliberately readable.
    .syn_comment = .{ 0x8d, 0x92, 0xad, 255 },
    .syn_string = .{ 0x9e, 0xc4, 0x9a, 255 },
    .syn_number = .{ 0xd4, 0xbd, 0x85, 255 },
    .syn_keyword = .{ 0xb8, 0xab, 0xee, 255 },
    .syn_type = .{ 0xd4, 0xbd, 0x85, 255 },
    .syn_func = .{ 0xa3, 0xc0, 0xe8, 255 },
};

const builtins = [_]*const Theme{ &default, &nocturne };

pub fn byName(name: []const u8) ?*const Theme {
    for (builtins) |t| {
        if (std.ascii.eqlIgnoreCase(name, t.name)) return t;
    }
    return null;
}

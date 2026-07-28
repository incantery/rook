//! rookz config: $XDG_CONFIG_HOME/rookz/config.toml (default
//! ~/.config/rookz/config.toml). A deliberate TOML subset — flat
//! `key = value` lines, # comments, quoted strings, numbers; [sections]
//! are skipped, not errors. Dashes and underscores in keys are
//! interchangeable (font-size == font_size). Missing file = defaults.

const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub const Config = struct {
    font_size: f64 = 13,
    font_family: [:0]const u8 = "FiraCode Nerd Font Mono",
};

pub fn load(io: std.Io, gpa: std.mem.Allocator) Config {
    var cfg: Config = .{};

    var pathbuf: [1024]u8 = undefined;
    const path = blk: {
        if (getenv("XDG_CONFIG_HOME")) |x| {
            break :blk std.fmt.bufPrint(&pathbuf, "{s}/rookz/config.toml", .{std.mem.span(x)}) catch return cfg;
        }
        const home = getenv("HOME") orelse return cfg;
        break :blk std.fmt.bufPrint(&pathbuf, "{s}/.config/rookz/config.toml", .{std.mem.span(home)}) catch return cfg;
    };

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return cfg;
    defer gpa.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;

        const key_raw = std.mem.trim(u8, line[0..eq], " \t");
        var keybuf: [64]u8 = undefined;
        if (key_raw.len > keybuf.len) continue;
        for (key_raw, 0..) |c, i| keybuf[i] = if (c == '-') '_' else c;
        const key = keybuf[0..key_raw.len];

        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        // Strip a trailing comment on unquoted values.
        if (val.len == 0 or val[0] != '"') {
            if (std.mem.indexOfScalar(u8, val, '#')) |hash| {
                val = std.mem.trim(u8, val[0..hash], " \t");
            }
        }

        if (std.mem.eql(u8, key, "font_size")) {
            cfg.font_size = std.fmt.parseFloat(f64, val) catch blk: {
                std.debug.print("rookz config: bad font-size '{s}'\n", .{val});
                break :blk cfg.font_size;
            };
        } else if (std.mem.eql(u8, key, "font_family")) {
            const stripped = std.mem.trim(u8, val, "\"");
            if (stripped.len > 0) {
                cfg.font_family = gpa.dupeZ(u8, stripped) catch cfg.font_family;
            }
        } else {
            std.debug.print("rookz config: unknown key '{s}' (known: font-size, font-family)\n", .{key_raw});
        }
    }

    if (cfg.font_size < 6 or cfg.font_size > 72) {
        std.debug.print("rookz config: font-size {d} out of range, using 13\n", .{cfg.font_size});
        cfg.font_size = 13;
    }
    return cfg;
}

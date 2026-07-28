//! Subscription usage — READ side of rook-host's cost-weighted prober.
//! The host scrapes `claude -p /usage` and caches the windows; rookz
//! GETs the cached snapshot through hostc (port + bearer token re-read
//! from host.json every fetch — a host restart changes both). Fail-open
//! everywhere: no host.json, dead host, bad JSON → an empty cluster,
//! never an error. Labels compact the wails way: session → 5h,
//! week (all models) → wk, week (X) → lowercased X.

const std = @import("std");
const hostc = @import("hostc.zig");

pub const Snapshot = struct {
    text: [96]u8 = undefined,
    len: usize = 0,
    /// Worst window's percentage — drives the cluster's color.
    worst: u8 = 0,

    pub fn slice(self: *const Snapshot) []const u8 {
        return self.text[0..self.len];
    }
};

fn shortWindow(label: []const u8) []const u8 {
    if (std.mem.eql(u8, label, "session")) return "5h";
    if (std.mem.startsWith(u8, label, "week (all")) return "wk";
    if (std.mem.startsWith(u8, label, "week (") and label.len > 7)
        return label[6 .. label.len - 1]; // "week (Fable)" → "Fable"
    return label;
}

const UsageWindow = struct { label: []const u8 = "", pct: i64 = 0 };
const UsageBody = struct { windows: []UsageWindow = &.{} };

/// One fetch, blocking (3s socket timeouts) — call from a background
/// thread, never the render path.
pub fn fetch(gpa: std.mem.Allocator, io: std.Io) Snapshot {
    var snap: Snapshot = .{};

    const info = hostc.readInfo(gpa, io) orelse return snap;
    var resp = hostc.get(gpa, &info, "/usage", 64 * 1024) orelse return snap;
    defer resp.deinit(gpa);
    if (resp.status != 200) return snap;

    const parsed = std.json.parseFromSlice(UsageBody, gpa, resp.body, .{ .ignore_unknown_fields = true }) catch return snap;
    defer parsed.deinit();

    // "5h 27% · wk 44% · fable 73%"
    var w: std.Io.Writer = .fixed(&snap.text);
    for (parsed.value.windows, 0..) |win, i| {
        const pct: u8 = @intCast(std.math.clamp(win.pct, 0, 100));
        if (pct > snap.worst) snap.worst = pct;
        var lbl_buf: [24]u8 = undefined;
        const short = shortWindow(win.label);
        const lbl = std.ascii.lowerString(lbl_buf[0..@min(short.len, lbl_buf.len)], short[0..@min(short.len, lbl_buf.len)]);
        w.print("{s}{s} {d}%", .{ @as([]const u8, if (i == 0) "" else " · "), lbl, pct }) catch break;
    }
    snap.len = w.end;
    return snap;
}

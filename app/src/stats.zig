//! Always-on perf stats. Cheap enough to never turn off: recording is one
//! atomic increment + one array store; no allocation, no locks. The same
//! counters serve self-monitoring (ctl `stats`) and benchmarking (driven
//! workloads + `stats reset` between phases).
//!
//! All time series are microseconds. Percentiles are exact over the last
//! 1024 samples (copy + sort at query time — queries are rare and cold).

const std = @import("std");

pub const Ring = struct {
    buf: [1024]u32 = @splat(0),
    head: std.atomic.Value(u32) = .init(0),

    pub fn record(self: *Ring, us: u64) void {
        const v: u32 = @intCast(@min(us, std.math.maxInt(u32)));
        const i = self.head.fetchAdd(1, .monotonic);
        self.buf[i & 1023] = v;
    }

    pub fn recordSeconds(self: *Ring, s: f64) void {
        if (s <= 0) return;
        self.record(@intFromFloat(s * 1e6));
    }

    pub const Summary = struct { n: u32, p50: u32 = 0, p95: u32 = 0, p99: u32 = 0, max: u32 = 0 };

    pub fn summarize(self: *Ring) Summary {
        var tmp: [1024]u32 = undefined;
        const h = self.head.load(.monotonic);
        const n: u32 = @min(h, 1024);
        if (n == 0) return .{ .n = 0 };
        @memcpy(tmp[0..n], self.buf[0..n]);
        std.mem.sort(u32, tmp[0..n], {}, std.sort.asc(u32));
        return .{
            .n = n,
            .p50 = tmp[n / 2],
            .p95 = tmp[@min(n - 1, n * 95 / 100)],
            .p99 = tmp[@min(n - 1, n * 99 / 100)],
            .max = tmp[n - 1],
        };
    }

    pub fn reset(self: *Ring) void {
        self.head.store(0, .monotonic);
    }
};

pub const Stats = struct {
    /// Keystroke (NSEvent kernel timestamp, or ctl receipt) → drawable
    /// presentedTime, consumed only by a frame that carried grid changes.
    /// THE number: key to photon.
    key_present: Ring = .{},
    /// Same start, but to command-buffer commit — the CPU-side share.
    key_commit: Ring = .{},

    /// Per drawn frame: RenderState.update under the session lock.
    frame_update: Ring = .{},
    /// Per drawn frame: cell-buffer fill (incl. lazy glyph rasterization).
    frame_fill: Ring = .{},
    /// The editor's tree-sitter reparse, inside frame_fill. A FULL
    /// parse of the whole document on every edit — the one thing in the
    /// fill whose cost is the file's size rather than the screen's, and
    /// the first suspect whenever typing stops feeling free.
    hl_reparse: Ring = .{},
    /// The as-you-type completion menu's buffer-word scan, in the key
    /// handler rather than the fill. Windowed, and this is the check
    /// that the window is doing its job.
    cpl_build: Ring = .{},
    /// Per drawn frame: encoder setup + draw calls + commit — measured
    /// from drawable ACQUISITION, so backpressure never reads as cost.
    frame_encode: Ring = .{},
    /// Per drawn frame: nextDrawable wait. Backpressure/pacing, not
    /// work — kept out of frame_encode so capability math stays honest.
    drawable_wait: Ring = .{},
    /// GPU execution time per command buffer (GPUEndTime - GPUStartTime).
    frame_gpu: Ring = .{},
    /// Interval between consecutive presented frames (only frames we drew;
    /// idle frames are skipped entirely, so this measures active pacing).
    present_interval: Ring = .{},
    /// Commit → presentedTime per drawn frame: the display pipeline's
    /// share of latency. ~12ms avg says the WindowServer is compositing
    /// us (latch + compose); ~4ms avg says direct-to-display scan-out.
    /// This ring IS the direct-to-display detector.
    present_lag: Ring = .{},

    bytes_in: std.atomic.Value(u64) = .init(0),
    frames_drawn: std.atomic.Value(u64) = .init(0),
    frames_skipped: std.atomic.Value(u64) = .init(0),
    glyphs_rasterized: std.atomic.Value(u64) = .init(0),

    pub fn reset(self: *Stats) void {
        self.key_present.reset();
        self.key_commit.reset();
        self.frame_update.reset();
        self.frame_fill.reset();
        self.hl_reparse.reset();
        self.cpl_build.reset();
        self.frame_encode.reset();
        self.drawable_wait.reset();
        self.frame_gpu.reset();
        self.present_interval.reset();
        self.present_lag.reset();
        self.bytes_in.store(0, .monotonic);
        self.frames_drawn.store(0, .monotonic);
        self.frames_skipped.store(0, .monotonic);
        self.glyphs_rasterized.store(0, .monotonic);
    }
};

pub var global: Stats = .{};

const rusage = extern struct {
    ru_utime: extern struct { tv_sec: i64, tv_usec: i32 },
    ru_stime: extern struct { tv_sec: i64, tv_usec: i32 },
    ru_maxrss: i64,
    rest: [14]i64,
};
extern "c" fn getrusage(who: c_int, usage: *rusage) c_int;

/// Peak RSS in MB, for the HUD and the report.
/// Seconds, for anything outside macos.zig that has to time itself.
///
/// NOT CACurrentMediaTime: the headless test roots (editor.zig and its
/// neighbours) do not link QuartzCore, and a timer that costs them a
/// framework is a timer that gets deleted the next time somebody wants
/// a test to build.
pub fn nowSeconds() f64 {
    var ts: TimeSpec = .{ .sec = 0, .nsec = 0 };
    if (clock_gettime(clock_monotonic, &ts) != 0) return 0;
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1e9;
}

const TimeSpec = extern struct { sec: isize, nsec: isize };
const clock_monotonic: u32 = 6; // Darwin's CLOCK_MONOTONIC
extern "c" fn clock_gettime(clock_id: u32, ts: *TimeSpec) c_int;

pub fn maxRssMb() u64 {
    var ru: rusage = undefined;
    if (getrusage(0, &ru) != 0) return 0;
    return @intCast(@divTrunc(ru.ru_maxrss, 1024 * 1024));
}

pub fn writeReport(w: *std.Io.Writer) !void {
    const s = &global;
    const series = [_]struct { name: []const u8, ring: *Ring }{
        .{ .name = "key_present_us", .ring = &s.key_present },
        .{ .name = "key_commit_us", .ring = &s.key_commit },
        .{ .name = "frame_update_us", .ring = &s.frame_update },
        .{ .name = "frame_fill_us", .ring = &s.frame_fill },
        .{ .name = "hl_reparse_us", .ring = &s.hl_reparse },
        .{ .name = "cpl_build_us", .ring = &s.cpl_build },
        .{ .name = "frame_encode_us", .ring = &s.frame_encode },
        .{ .name = "drawable_wait_us", .ring = &s.drawable_wait },
        .{ .name = "frame_gpu_us", .ring = &s.frame_gpu },
        .{ .name = "present_interval_us", .ring = &s.present_interval },
        .{ .name = "present_lag_us", .ring = &s.present_lag },
    };
    for (series) |ser| {
        const sum = ser.ring.summarize();
        try w.print("{s} n={d} p50={d} p95={d} p99={d} max={d}\n", .{ ser.name, sum.n, sum.p50, sum.p95, sum.p99, sum.max });
    }
    try w.print("bytes_in={d} frames_drawn={d} frames_skipped={d} glyphs_rasterized={d}\n", .{
        s.bytes_in.load(.monotonic),
        s.frames_drawn.load(.monotonic),
        s.frames_skipped.load(.monotonic),
        s.glyphs_rasterized.load(.monotonic),
    });

    var ru: rusage = undefined;
    if (getrusage(0, &ru) == 0) {
        const cpu_us: i64 = ru.ru_utime.tv_sec * 1_000_000 + ru.ru_utime.tv_usec +
            ru.ru_stime.tv_sec * 1_000_000 + ru.ru_stime.tv_usec;
        try w.print("cpu_ms={d} maxrss_mb={d}\n", .{ @divTrunc(cpu_us, 1000), @divTrunc(ru.ru_maxrss, 1024 * 1024) });
    }
}

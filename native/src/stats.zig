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
    /// Per drawn frame: encoder setup + draw calls + commit.
    frame_encode: Ring = .{},
    /// GPU execution time per command buffer (GPUEndTime - GPUStartTime).
    frame_gpu: Ring = .{},
    /// Interval between consecutive presented frames (only frames we drew;
    /// idle frames are skipped entirely, so this measures active pacing).
    present_interval: Ring = .{},

    bytes_in: std.atomic.Value(u64) = .init(0),
    frames_drawn: std.atomic.Value(u64) = .init(0),
    frames_skipped: std.atomic.Value(u64) = .init(0),
    glyphs_rasterized: std.atomic.Value(u64) = .init(0),

    pub fn reset(self: *Stats) void {
        self.key_present.reset();
        self.key_commit.reset();
        self.frame_update.reset();
        self.frame_fill.reset();
        self.frame_encode.reset();
        self.frame_gpu.reset();
        self.present_interval.reset();
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

pub fn writeReport(w: *std.Io.Writer) !void {
    const s = &global;
    const series = [_]struct { name: []const u8, ring: *Ring }{
        .{ .name = "key_present_us", .ring = &s.key_present },
        .{ .name = "key_commit_us", .ring = &s.key_commit },
        .{ .name = "frame_update_us", .ring = &s.frame_update },
        .{ .name = "frame_fill_us", .ring = &s.frame_fill },
        .{ .name = "frame_encode_us", .ring = &s.frame_encode },
        .{ .name = "frame_gpu_us", .ring = &s.frame_gpu },
        .{ .name = "present_interval_us", .ring = &s.present_interval },
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

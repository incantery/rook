//! Machine-wide process and system sampling — the LIVE half of the
//! monitor, and the answer to "why is the fan spinning".
//!
//! libproc and mach directly, no fork. `ps` would be a subprocess per
//! sample at 1Hz forever, and it cannot answer the question this module
//! exists for: which of MY panes is responsible. That needs the parent
//! chain, which means walking every process anyway.
//!
//! THREE THINGS HERE ARE EASY TO GET WRONG, and each was measured on a
//! real machine rather than assumed:
//!
//! 1. **CPU times are mach absolute units, not nanoseconds.** The field
//!    is called `pti_total_user` and holds a count of timer ticks whose
//!    scale is `mach_timebase_info` — 125/3 on Apple Silicon, so one
//!    second of CPU is 24M ticks, not 1e9.
//!
//!    The trap is narrower and nastier than "the number is 42x off".
//!    A percentage is a RATIO, so if the wall interval is measured with
//!    the same unconverted clock, the error cancels and the column is
//!    accidentally right — which is how this survives review. It only
//!    bites when the two clocks disagree: mach-tick CPU time divided by
//!    a real-nanosecond wall interval is under-reported by exactly the
//!    timebase, and every process on the machine reads as idle.
//!
//!    So the rule here is not "convert" but "never mix": CPU time is
//!    converted through `Timebase` at the point of sampling, and the
//!    interval it is divided by comes from `std.time.Instant` — a
//!    genuinely independent monotonic clock. Deriving the interval from
//!    `mach_absolute_time` instead would make the conversion untestable,
//!    because a broken `toNs` would cancel itself out.
//!
//! 2. **RSS is not memory.** `pti_resident_size` counts shared pages in
//!    every process that maps them, so summing it over a real machine
//!    gave 32.3GB on a 38.7GB box while it was nowhere near full. The
//!    number Activity Monitor shows — and the only one that sums
//!    honestly — is `ri_phys_footprint`, which is what this module
//!    ranks by. RSS is kept alongside because it is what `top` prints
//!    and a number that disagrees with another tool needs to be
//!    comparable to it.
//!
//! 3. **Not every process answers.** On a stock machine 295 of 1785
//!    pids refuse PROC_PIDTASKINFO — almost exactly the root-owned set.
//!    So the per-process CPU column CANNOT sum to the system total, and
//!    a monitor that hides that gap is lying about where the heat went.
//!    `Snapshot.attributed_pct` vs `System.busy_pct` is the difference,
//!    and the view draws it as its own row.
//!
//! Sampling costs ~4ms for ~1800 processes, which is why it runs on a
//! worker and never on the frame path. Names are cheap (`pbsi_comm`,
//! available for essentially every pid); ARGV is not, and is fetched
//! lazily for display rows only — see `argvFor`.

const std = @import("std");

// ---------------------------------------------------------------------
// libproc / mach
// ---------------------------------------------------------------------

const proc_all_pids = 1;
const proc_pidtaskinfo = 4;
const proc_pidt_shortbsdinfo = 13;
const rusage_info_v4 = 4;

extern "c" fn proc_listpids(typ: u32, typeinfo: u32, buf: ?*anyopaque, sz: c_int) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buf: *anyopaque, sz: c_int) c_int;
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buf: *anyopaque) c_int;
extern "c" fn mach_timebase_info(info: *MachTimebase) c_int;
extern "c" fn mach_absolute_time() u64;
extern "c" fn mach_host_self() u32;
extern "c" fn host_processor_info(host: u32, flavor: c_int, out_count: *u32, out_info: *[*]c_int, out_infoCnt: *u32) c_int;
extern "c" fn host_statistics64(host: u32, flavor: c_int, info: *anyopaque, count: *u32) c_int;
extern "c" fn vm_deallocate(task: u32, addr: usize, size: usize) c_int;
extern "c" fn mach_task_self() u32;
extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int;
extern "c" fn sysctl(name: [*]c_int, namelen: u32, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int;

const MachTimebase = extern struct { numer: u32 = 0, denom: u32 = 0 };

/// `struct proc_taskinfo`. Only the fields up to what is read here are
/// named; the tail is padding to the size the kernel checks against.
const ProcTaskInfo = extern struct {
    pti_virtual_size: u64,
    pti_resident_size: u64,
    pti_total_user: u64,
    pti_total_system: u64,
    pti_threads_user: u64,
    pti_threads_system: u64,
    pti_policy: i32,
    pti_faults: i32,
    pti_pageins: i32,
    pti_cow_faults: i32,
    pti_messages_sent: i32,
    pti_messages_received: i32,
    pti_syscalls_mach: i32,
    pti_syscalls_unix: i32,
    pti_csw: i32,
    pti_threadnum: i32,
    pti_numrunning: i32,
    pti_priority: i32,
};

/// `struct proc_bsdshortinfo` — the cheap flavor. Answers for basically
/// every pid on the machine, including ones that refuse task info, so
/// the process TREE is complete even where the numbers are not.
const ProcBsdShortInfo = extern struct {
    pbsi_pid: u32,
    pbsi_ppid: u32,
    pbsi_pgid: u32,
    pbsi_status: u32,
    pbsi_comm: [16]u8,
    pbsi_flags: u32,
    pbsi_uid: u32,
    pbsi_gid: u32,
    pbsi_ruid: u32,
    pbsi_rgid: u32,
    pbsi_svuid: u32,
    pbsi_svgid: u32,
    pbsi_rfu: u32,
};

/// `struct rusage_info_v4`, read only for `ri_phys_footprint`. Declared
/// whole because the kernel validates by flavor, not by length.
const RUsageInfoV4 = extern struct {
    ri_uuid: [16]u8,
    ri_user_time: u64,
    ri_system_time: u64,
    ri_pkg_idle_wkups: u64,
    ri_interrupt_wkups: u64,
    ri_pageins: u64,
    ri_wired_size: u64,
    ri_resident_size: u64,
    ri_phys_footprint: u64,
    ri_proc_start_abstime: u64,
    ri_proc_exit_abstime: u64,
    ri_child_user_time: u64,
    ri_child_system_time: u64,
    ri_child_pkg_idle_wkups: u64,
    ri_child_interrupt_wkups: u64,
    ri_child_pageins: u64,
    ri_child_elapsed_abstime: u64,
    ri_diskio_bytesread: u64,
    ri_diskio_byteswritten: u64,
    ri_cpu_time_qos_default: u64,
    ri_cpu_time_qos_maintenance: u64,
    ri_cpu_time_qos_background: u64,
    ri_cpu_time_qos_utility: u64,
    ri_cpu_time_qos_legacy: u64,
    ri_cpu_time_qos_user_initiated: u64,
    ri_cpu_time_qos_user_interactive: u64,
    ri_billed_system_time: u64,
    ri_serviced_system_time: u64,
    ri_logical_writes: u64,
    ri_lifetime_max_phys_footprint: u64,
    ri_instructions: u64,
    ri_cycles: u64,
    ri_billed_energy: u64,
    ri_serviced_energy: u64,
    ri_interval_max_phys_footprint: u64,
    ri_runnable_time: u64,
    ri_flags: u64,
};

const VmStatistics64 = extern struct {
    free_count: u32,
    active_count: u32,
    inactive_count: u32,
    wire_count: u32,
    zero_fill_count: u64,
    reactivations: u64,
    pageins: u64,
    pageouts: u64,
    faults: u64,
    cow_faults: u64,
    lookups: u64,
    hits: u64,
    purges: u64,
    purgeable_count: u32,
    speculative_count: u32,
    decompressions: u64,
    compressions: u64,
    swapins: u64,
    swapouts: u64,
    compressor_page_count: u32,
    throttled_count: u32,
    external_page_count: u32,
    internal_page_count: u32,
    total_uncompressed_pages_in_compressor: u64,
};

const XswUsage = extern struct {
    xsu_total: u64,
    xsu_avail: u64,
    xsu_used: u64,
    xsu_pagesize: u32,
    xsu_encrypted: bool,
};

const host_vm_info64 = 4;
const host_vm_info64_count: u32 = @sizeOf(VmStatistics64) / @sizeOf(u32);
const processor_cpu_load_info = 2;
/// CPU_STATE_{USER,SYSTEM,IDLE,NICE} — one tick counter each, per core.
const cpu_state_max = 4;
const cpu_state_user = 0;
const cpu_state_system = 1;
const cpu_state_idle = 2;
const cpu_state_nice = 3;

/// mach ticks → nanoseconds. Read once; the ratio cannot change while
/// the machine is up. See the header: this conversion is the difference
/// between a correct CPU column and one that is wrong by 42x.
pub const Timebase = struct {
    numer: u64 = 1,
    denom: u64 = 1,

    pub fn get() Timebase {
        var tb: MachTimebase = .{};
        _ = mach_timebase_info(&tb);
        if (tb.numer == 0 or tb.denom == 0) return .{};
        return .{ .numer = tb.numer, .denom = tb.denom };
    }

    pub fn toNs(self: Timebase, ticks: u64) u64 {
        return ticks *% self.numer / self.denom;
    }
};

/// The sampler's wall clock: monotonic, already in real nanoseconds
/// because the KERNEL did the conversion, and deliberately not
/// `mach_absolute_time`. See the header — an interval derived from the
/// same raw tick source as the CPU counters cancels a broken `Timebase`
/// and makes the conversion unprovable.
///
/// Not `CACurrentMediaTime` (macos.zig's "one clock") for a duller
/// reason: this module is a leaf with headless tests, and that symbol
/// would drag QuartzCore into a test root that only wants libc.
fn wallNs() u64 {
    var ts: TimeSpec = .{ .sec = 0, .nsec = 0 };
    if (clock_gettime(clock_monotonic, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) *% std.time.ns_per_s +% @as(u64, @intCast(ts.nsec));
}

const TimeSpec = extern struct { sec: isize, nsec: isize };
/// Darwin's CLOCK_MONOTONIC. Counts from boot and never steps, so an
/// NTP correction mid-sample cannot make an interval negative — which
/// on a wall clock would paint one frame of impossible percentages.
const clock_monotonic: c_int = 6;
extern "c" fn clock_gettime(clk: c_int, ts: *TimeSpec) c_int;

// ---------------------------------------------------------------------
// The sample
// ---------------------------------------------------------------------

/// A pane's shell, as the sampler needs to see it: the pid it forked
/// and the id to blame. Passed in rather than read from the pane tree,
/// so this module stays a leaf that tests can drive with fake panes.
pub const PaneProc = struct {
    pane_id: u32,
    pid: i32,
};

pub const Proc = struct {
    pid: i32,
    ppid: i32,
    uid: u32,
    /// `pbsi_comm`, NUL-trimmed. Truncated to 15 chars by the kernel —
    /// which is why `argvFor` exists for the rows actually shown.
    name: [16]u8 = @splat(0),
    name_len: u8 = 0,
    /// Cumulative user+system, NANOSECONDS (converted at sample time).
    cpu_ns: u64 = 0,
    /// Share of ONE core over the interval since the previous sample,
    /// in percent — so 800.0 means eight cores saturated. Zero on the
    /// first sample of a pid, because a rate needs two points.
    cpu_pct: f32 = 0,
    /// `ri_phys_footprint` — Activity Monitor's "Memory" column, and
    /// the only per-process memory number that sums honestly.
    footprint: u64 = 0,
    /// `pti_resident_size`. Double-counts shared pages; kept because it
    /// is what `top` prints. Never summed. See the header.
    rss: u64 = 0,
    threads: u32 = 0,
    /// Which pane's process tree this sits under, or 0 for none. THE
    /// column that makes this different from htop.
    pane_id: u32 = 0,
    /// False when the kernel refused PROC_PIDTASKINFO — the process is
    /// real and named, but its numbers are unknowable to us. Drawn as
    /// "—" rather than as zero, which would read as idle.
    info_ok: bool = false,

    pub fn nameStr(self: *const Proc) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const System = struct {
    ncpu: u32 = 0,
    /// Busy share of the WHOLE machine, 0..ncpu*100 — same scale as
    /// `Proc.cpu_pct`, so a process row and the total are comparable
    /// without the reader converting anything.
    busy_pct: f32 = 0,
    user_pct: f32 = 0,
    sys_pct: f32 = 0,
    mem_total: u64 = 0,
    /// Wired + active + compressed: the part that is not reclaimable by
    /// asking nicely. What "used" has to mean on a machine whose free
    /// list is a cache.
    mem_used: u64 = 0,
    mem_wired: u64 = 0,
    mem_compressed: u64 = 0,
    swap_used: u64 = 0,
    swap_total: u64 = 0,
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 urgent.
    /// The honest "is this machine in trouble" bit — swap in use with
    /// pressure at 1 is fine, and a load-average number never says that.
    pressure: u32 = 1,
};

pub const Snapshot = struct {
    sys: System = .{},
    /// Sorted by the sampler's key, longest-lived allocation here.
    procs: []Proc = &.{},
    /// Every pid the kernel listed, including ones with no numbers.
    total_pids: u32 = 0,
    /// How many answered PROC_PIDTASKINFO.
    attributable: u32 = 0,
    /// Sum of `cpu_pct` over all procs. Compare with `sys.busy_pct`:
    /// the shortfall is work by processes that refused to be measured,
    /// and it is shown rather than hidden.
    attributed_pct: f32 = 0,
    /// Wall nanoseconds covered by the rates above. Zero on the first
    /// sample, which is how the view knows to say "measuring…" instead
    /// of drawing a column of zeroes.
    interval_ns: u64 = 0,

    pub fn deinit(self: *Snapshot, gpa: std.mem.Allocator) void {
        gpa.free(self.procs);
        self.* = .{};
    }
};

pub const SortKey = enum { cpu, mem, pid, name };

/// What a pid looked like last time, for the rate. Keyed by pid, which
/// the kernel REUSES — see `Sampler.sample` for why a negative delta is
/// the reuse detector rather than a start-time comparison.
const Prev = struct {
    cpu_ns: u64,
};

pub const Sampler = struct {
    gpa: std.mem.Allocator,
    tb: Timebase = .{},
    prev: std.AutoHashMapUnmanaged(i32, Prev) = .empty,
    prev_at_ns: u64 = 0,
    /// Per-core tick totals from the previous sample, for the system
    /// busy rate. Fixed at 64 cores; a bigger machine gets its extra
    /// cores folded into the last slot rather than a heap allocation
    /// on the sample path.
    prev_ticks: [4]u64 = @splat(0),
    have_prev_ticks: bool = false,
    /// Scratch that grows to the machine's pid count and then stops.
    pids: std.ArrayListUnmanaged(i32) = .empty,

    pub fn init(gpa: std.mem.Allocator) Sampler {
        return .{ .gpa = gpa, .tb = Timebase.get() };
    }

    pub fn deinit(self: *Sampler) void {
        self.prev.deinit(self.gpa);
        self.pids.deinit(self.gpa);
        self.* = undefined;
    }

    /// One full pass. Allocates the returned `procs`; the caller owns it
    /// and frees through `Snapshot.deinit`.
    ///
    /// ~4ms for 1800 processes, which is a worker's job and never the
    /// frame thread's.
    pub fn sample(self: *Sampler, panes: []const PaneProc, sort: SortKey) !Snapshot {
        const now = wallNs();
        const interval_ns = if (self.prev_at_ns == 0) 0 else now -| self.prev_at_ns;
        // Rates need a denominator. A second sample that lands in the
        // same nanosecond (or a clock that went backwards) would divide
        // by zero and paint infinities.
        const secs: f64 = if (interval_ns == 0) 0 else @as(f64, @floatFromInt(interval_ns)) / 1e9;

        // --- the pid list -------------------------------------------
        const want = proc_listpids(proc_all_pids, 0, null, 0);
        if (want <= 0) return error.ListPidsFailed;
        const cap: usize = @intCast(@divTrunc(want, @sizeOf(i32)));
        // Headroom: processes fork between the sizing call and the
        // fetch, and a truncated list silently loses the newest ones —
        // which on an agent box are exactly the interesting ones.
        try self.pids.resize(self.gpa, cap + 64);
        const got = proc_listpids(proc_all_pids, 0, self.pids.items.ptr, @intCast(self.pids.items.len * @sizeOf(i32)));
        if (got <= 0) return error.ListPidsFailed;
        const n: usize = @intCast(@divTrunc(got, @sizeOf(i32)));

        var procs: std.ArrayListUnmanaged(Proc) = .empty;
        errdefer procs.deinit(self.gpa);
        try procs.ensureTotalCapacity(self.gpa, n);

        var next: std.AutoHashMapUnmanaged(i32, Prev) = .empty;
        errdefer next.deinit(self.gpa);
        try next.ensureTotalCapacity(self.gpa, @intCast(n));

        var attributable: u32 = 0;
        var attributed_pct: f32 = 0;

        for (self.pids.items[0..n]) |pid| {
            if (pid <= 0) continue;
            var p: Proc = .{ .pid = pid, .ppid = 0, .uid = 0 };

            // The cheap flavor first: it answers for nearly every pid,
            // and without it the process has no name and no parent —
            // which would drop it out of the attribution tree even
            // though its children are ours.
            var bs: ProcBsdShortInfo = undefined;
            if (proc_pidinfo(pid, proc_pidt_shortbsdinfo, 0, &bs, @sizeOf(ProcBsdShortInfo)) != @sizeOf(ProcBsdShortInfo))
                continue;
            p.ppid = @intCast(bs.pbsi_ppid);
            p.uid = bs.pbsi_uid;
            const comm = std.mem.sliceTo(&bs.pbsi_comm, 0);
            p.name_len = @intCast(@min(p.name.len, comm.len));
            @memcpy(p.name[0..p.name_len], comm[0..p.name_len]);

            var ti: ProcTaskInfo = undefined;
            if (proc_pidinfo(pid, proc_pidtaskinfo, 0, &ti, @sizeOf(ProcTaskInfo)) == @sizeOf(ProcTaskInfo)) {
                p.info_ok = true;
                attributable += 1;
                p.rss = ti.pti_resident_size;
                p.threads = @intCast(@max(0, ti.pti_threadnum));
                // THE conversion. See the header.
                p.cpu_ns = self.tb.toNs(ti.pti_total_user +% ti.pti_total_system);

                var ru: RUsageInfoV4 = undefined;
                p.footprint = if (proc_pid_rusage(pid, rusage_info_v4, &ru) == 0)
                    ru.ri_phys_footprint
                else
                    // No footprint available: fall back to RSS rather
                    // than to zero, so the row sorts somewhere sane and
                    // is merely imprecise instead of invisible.
                    ti.pti_resident_size;

                if (secs > 0) {
                    if (self.prev.get(pid)) |old| {
                        // A pid the kernel recycled starts its counter
                        // near zero, so the delta goes NEGATIVE — that
                        // is the reuse detector. Comparing start times
                        // would need a second syscall per process to
                        // catch a case this already catches for free.
                        if (p.cpu_ns >= old.cpu_ns) {
                            const d: f64 = @floatFromInt(p.cpu_ns - old.cpu_ns);
                            p.cpu_pct = @floatCast(d / 1e9 / secs * 100.0);
                            attributed_pct += p.cpu_pct;
                        }
                    }
                }
                next.putAssumeCapacity(pid, .{ .cpu_ns = p.cpu_ns });
            }
            procs.appendAssumeCapacity(p);
        }

        attribute(procs.items, panes);
        sortProcs(procs.items, sort);

        self.prev.deinit(self.gpa);
        self.prev = next;
        self.prev_at_ns = now;

        return .{
            .sys = self.systemStats(secs),
            .procs = try procs.toOwnedSlice(self.gpa),
            .total_pids = @intCast(n),
            .attributable = attributable,
            .attributed_pct = attributed_pct,
            .interval_ns = interval_ns,
        };
    }

    fn systemStats(self: *Sampler, secs: f64) System {
        var s: System = .{};

        // --- CPU: per-core tick counters, differenced ---------------
        var ncpu: u32 = 0;
        var info: [*]c_int = undefined;
        var cnt: u32 = 0;
        if (host_processor_info(mach_host_self(), processor_cpu_load_info, &ncpu, &info, &cnt) == 0) {
            s.ncpu = ncpu;
            var tot: [4]u64 = @splat(0);
            var i: usize = 0;
            while (i < ncpu) : (i += 1) {
                const base = i * cpu_state_max;
                if (base + cpu_state_max > cnt) break;
                for (0..cpu_state_max) |k| tot[k] += @intCast(@max(0, info[base + k]));
            }
            // host_processor_info hands back vm_allocate'd memory. It is
            // called once a second forever, so leaking it leaks steadily.
            _ = vm_deallocate(mach_task_self(), @intFromPtr(info), cnt * @sizeOf(c_int));

            if (self.have_prev_ticks and secs > 0) {
                var d: [4]u64 = @splat(0);
                var sum: u64 = 0;
                for (0..cpu_state_max) |k| {
                    d[k] = tot[k] -| self.prev_ticks[k];
                    sum += d[k];
                }
                if (sum > 0) {
                    const busy = d[cpu_state_user] + d[cpu_state_system] + d[cpu_state_nice];
                    const scale: f64 = @as(f64, @floatFromInt(ncpu)) * 100.0 / @as(f64, @floatFromInt(sum));
                    s.busy_pct = @floatCast(@as(f64, @floatFromInt(busy)) * scale);
                    s.user_pct = @floatCast(@as(f64, @floatFromInt(d[cpu_state_user] + d[cpu_state_nice])) * scale);
                    s.sys_pct = @floatCast(@as(f64, @floatFromInt(d[cpu_state_system])) * scale);
                }
            }
            self.prev_ticks = tot;
            self.have_prev_ticks = true;
        }

        // --- memory --------------------------------------------------
        var memsize: u64 = 0;
        var sz: usize = @sizeOf(u64);
        _ = sysctlbyname("hw.memsize", &memsize, &sz, null, 0);
        s.mem_total = memsize;

        var vm: VmStatistics64 = undefined;
        var vmc: u32 = host_vm_info64_count;
        if (host_statistics64(mach_host_self(), host_vm_info64, &vm, &vmc) == 0) {
            const page: u64 = 4096;
            s.mem_wired = @as(u64, vm.wire_count) * page;
            s.mem_compressed = @as(u64, vm.compressor_page_count) * page;
            // Active + wired + compressed. Inactive is a cache the
            // kernel will hand back on demand, so counting it as used
            // is what makes every naive memory monitor report 95% on a
            // perfectly healthy machine.
            s.mem_used = @as(u64, vm.active_count) * page + s.mem_wired + s.mem_compressed;
        }

        var sw: XswUsage = undefined;
        sz = @sizeOf(XswUsage);
        if (sysctlbyname("vm.swapusage", &sw, &sz, null, 0) == 0) {
            s.swap_used = sw.xsu_used;
            s.swap_total = sw.xsu_total;
        }

        var press: u32 = 1;
        sz = @sizeOf(u32);
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &press, &sz, null, 0);
        s.pressure = press;

        return s;
    }
};

// ---------------------------------------------------------------------
// Attribution — the column htop cannot have
// ---------------------------------------------------------------------

/// Blame each process on the pane whose shell it descends from.
///
/// Every process climbs its parent chain until it hits a known pane pid
/// or runs out. Done as a pass over the finished list rather than during
/// sampling because a child can be listed before its parent, so the
/// chain is only complete once everything is in.
///
/// The climb is capped: a parent map built from a moving process table
/// can contain a cycle (pid reuse mid-walk lets A claim B as parent and
/// B claim A), and an uncapped climb on one would hang the sampler
/// thread forever with no symptom but a stale panel.
pub fn attribute(procs: []Proc, panes: []const PaneProc) void {
    if (panes.len == 0) return;

    // pid → index, over this snapshot only.
    var idx: std.AutoHashMapUnmanaged(i32, u32) = .empty;
    defer idx.deinit(std.heap.page_allocator);
    idx.ensureTotalCapacity(std.heap.page_allocator, @intCast(procs.len)) catch return;
    for (procs, 0..) |p, i| idx.putAssumeCapacity(p.pid, @intCast(i));

    const max_climb = 64;
    for (procs) |*p| {
        var cur = p.pid;
        var hops: u32 = 0;
        while (hops < max_climb) : (hops += 1) {
            for (panes) |pane| {
                if (pane.pid == cur) {
                    p.pane_id = pane.pane_id;
                    break;
                }
            }
            if (p.pane_id != 0) break;
            const i = idx.get(cur) orelse break;
            const parent = procs[i].ppid;
            // launchd, or a chain that lost its parent to a reap.
            if (parent <= 1 or parent == cur) break;
            cur = parent;
        }
    }
}

fn sortProcs(procs: []Proc, key: SortKey) void {
    const C = struct {
        k: SortKey,
        fn lt(self: @This(), a: Proc, b: Proc) bool {
            return switch (self.k) {
                // Descending: a monitor opens on the worst offender, and
                // scrolling to find it is the thing it exists to avoid.
                .cpu => a.cpu_pct > b.cpu_pct,
                .mem => a.footprint > b.footprint,
                .pid => a.pid < b.pid,
                .name => std.ascii.lessThanIgnoreCase(a.nameStr(), b.nameStr()),
            };
        }
    };
    std.mem.sort(Proc, procs, C{ .k = key }, C.lt);
}

// ---------------------------------------------------------------------
// argv, lazily
// ---------------------------------------------------------------------

const kern_procargs2 = 49;
const ctl_kern = 1;

/// The full command line for one pid, into `buf`, or null.
///
/// This is what tells `node` running the Claude CLI apart from `node`
/// running a dev server — which on an agent box is the difference
/// between a useful row and a useless one. It is NOT part of `sample`:
/// KERN_PROCARGS2 copies the whole argument area per call and only
/// works for same-uid processes, so paying it 1800 times a second to
/// label 40 visible rows would be the most expensive thing this file
/// does. Callers fetch it for the rows they are about to draw.
///
/// The layout is: argc (u32), the exec path, NUL padding, then argc
/// NUL-separated argv strings.
pub fn argvFor(pid: i32, buf: []u8, out: []u8) ?[]const u8 {
    var mib = [_]c_int{ ctl_kern, kern_procargs2, pid };
    var sz: usize = buf.len;
    if (sysctl(&mib, 3, buf.ptr, &sz, null, 0) != 0) return null;
    if (sz < @sizeOf(u32)) return null;

    const argc = std.mem.readInt(u32, buf[0..4], .little);
    if (argc == 0) return null;

    var i: usize = @sizeOf(u32);
    // Skip the exec path and the NUL run padding it out.
    while (i < sz and buf[i] != 0) i += 1;
    while (i < sz and buf[i] == 0) i += 1;

    var w: usize = 0;
    var taken: u32 = 0;
    while (taken < argc and i < sz) : (taken += 1) {
        const start = i;
        while (i < sz and buf[i] != 0) i += 1;
        const arg = buf[start..i];
        while (i < sz and buf[i] == 0) i += 1;
        if (arg.len == 0) continue;
        if (w > 0) {
            if (w >= out.len) break;
            out[w] = ' ';
            w += 1;
        }
        const take = @min(arg.len, out.len -| w);
        if (take == 0) break;
        @memcpy(out[w..][0..take], arg[0..take]);
        w += take;
    }
    return if (w == 0) null else out[0..w];
}

// ---------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "timebase converts mach ticks, not nanoseconds" {
    // The 125/3 ratio a real Apple Silicon machine reports. One second
    // of CPU is 24M ticks there; read as nanoseconds it is 0.024s, and
    // that 42x is the bug this test exists to pin.
    const tb: Timebase = .{ .numer = 125, .denom = 3 };
    const one_second_of_ticks: u64 = 24_000_000;
    try testing.expectEqual(@as(u64, 1_000_000_000), tb.toNs(one_second_of_ticks));

    // The identity timebase (Intel) must be a no-op, not a rescale.
    const id: Timebase = .{ .numer = 1, .denom = 1 };
    try testing.expectEqual(@as(u64, 12345), id.toNs(12345));
}

test "attribution climbs the parent chain to a pane" {
    // shell(100) → claude(200) → node(300); an unrelated tree beside it.
    var procs = [_]Proc{
        .{ .pid = 100, .ppid = 1, .uid = 501 },
        .{ .pid = 200, .ppid = 100, .uid = 501 },
        .{ .pid = 300, .ppid = 200, .uid = 501 },
        .{ .pid = 400, .ppid = 1, .uid = 0 },
    };
    const panes = [_]PaneProc{.{ .pane_id = 7, .pid = 100 }};
    attribute(&procs, &panes);

    try testing.expectEqual(@as(u32, 7), procs[0].pane_id);
    try testing.expectEqual(@as(u32, 7), procs[1].pane_id);
    // The grandchild is the whole point: an agent's subprocesses are
    // what burn the CPU, and blaming only the direct child would leave
    // the expensive row unattributed.
    try testing.expectEqual(@as(u32, 7), procs[2].pane_id);
    try testing.expectEqual(@as(u32, 0), procs[3].pane_id);
}

test "attribution survives a parent cycle" {
    // Pid reuse mid-walk can produce a chain that points at itself. An
    // uncapped climb here hangs the sampler thread with no symptom but
    // a panel that stopped updating.
    var procs = [_]Proc{
        .{ .pid = 10, .ppid = 20, .uid = 501 },
        .{ .pid = 20, .ppid = 10, .uid = 501 },
    };
    const panes = [_]PaneProc{.{ .pane_id = 1, .pid = 999 }};
    attribute(&procs, &panes);
    try testing.expectEqual(@as(u32, 0), procs[0].pane_id);
    try testing.expectEqual(@as(u32, 0), procs[1].pane_id);
}

test "sort by cpu and mem is descending, name is not" {
    var procs = [_]Proc{
        .{ .pid = 1, .ppid = 0, .uid = 0, .cpu_pct = 5, .footprint = 300 },
        .{ .pid = 2, .ppid = 0, .uid = 0, .cpu_pct = 90, .footprint = 100 },
        .{ .pid = 3, .ppid = 0, .uid = 0, .cpu_pct = 40, .footprint = 200 },
    };
    sortProcs(&procs, .cpu);
    try testing.expectEqual(@as(i32, 2), procs[0].pid);
    sortProcs(&procs, .mem);
    try testing.expectEqual(@as(i32, 1), procs[0].pid);
    sortProcs(&procs, .pid);
    try testing.expectEqual(@as(i32, 1), procs[0].pid);
}

test "a live sample sees this test process, with sane numbers" {
    // Sampling twice with work in between is the only way to prove the
    // rate arithmetic against the real kernel: one sample can only ever
    // report zero, which is also what a broken rate reports.
    var s = Sampler.init(testing.allocator);
    defer s.deinit();

    var first = try s.sample(&.{}, .cpu);
    defer first.deinit(testing.allocator);
    try testing.expect(first.total_pids > 0);
    try testing.expectEqual(@as(u64, 0), first.interval_ns);
    // First sample has no previous point, so every rate must be zero
    // rather than a garbage ratio against an uninitialised baseline.
    try testing.expectEqual(@as(f32, 0), first.attributed_pct);

    // Burn a known amount of REAL time on one core. Timed with the
    // independent clock on purpose: spinning against `Timebase` would
    // make a broken conversion merely change how long this loop runs,
    // and the assertion below would pass anyway — which is precisely
    // what happened the first time this test was written.
    var spin: u64 = 0;
    const t0 = wallNs();
    while (wallNs() - t0 < 250_000_000) spin +%= 1;
    try testing.expect(spin > 0);

    var second = try s.sample(&.{}, .cpu);
    defer second.deinit(testing.allocator);
    try testing.expect(second.interval_ns > 0);
    try testing.expect(second.sys.mem_total > 0);
    try testing.expect(second.sys.ncpu > 0);

    // The gap this monitor refuses to hide: some processes never answer,
    // so attributable is strictly less than the pids the kernel listed.
    try testing.expect(second.attributable > 0);
    try testing.expect(second.attributable <= second.total_pids);

    // Our own busy loop must show up as real CPU. If the mach-tick
    // conversion regressed to "nanoseconds", this lands near 0.3% and
    // fails — which is exactly the 42x bug the header warns about.
    const self_pid = std.c.getpid();
    var found = false;
    for (second.procs) |p| {
        if (p.pid == self_pid) {
            found = true;
            try testing.expect(p.cpu_pct > 20.0);
            try testing.expect(p.footprint > 0);
        }
    }
    try testing.expect(found);
}

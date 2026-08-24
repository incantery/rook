const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // target+optimize MUST flow to the dependency or ghostty-vt builds
    // at its own default (Debug) even in a release build — the 100x
    // parse-throughput hole the old app's first benchmark found.
    // emit-xcframework=false: we consume ghostty as a Zig module; the
    // default ON retargets to iOS and dies without full Xcode.
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-xcframework" = false,
    })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }
    exe_mod.link_libc = true;

    const exe = b.addExecutable(.{ .name = "engine", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the engine").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}

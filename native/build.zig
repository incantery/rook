const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const run_step = b.step("run", "Run the app");
    const test_step = b.step("test", "Run unit tests");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // target+optimize MUST flow to the dependency or ghostty-vt builds at
    // its own default (Debug) even in a ReleaseFast bench build — which
    // showed up as a 100x parse throughput hole in the first benchmark.
    if (b.lazyDependency("ghostty", .{ .target = target, .optimize = optimize })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }
    if (b.lazyDependency("zig_objc", .{ .target = target, .optimize = optimize })) |dep| {
        exe_mod.addImport("objc", dep.module("objc"));
    }
    exe_mod.link_libc = true;

    // Tree-sitter runtime + vendored grammars (parser-table C files).
    exe_mod.addIncludePath(b.path("vendor/tree-sitter/include"));
    exe_mod.addIncludePath(b.path("vendor/tree-sitter/src"));
    exe_mod.addCSourceFile(.{ .file = b.path("vendor/tree-sitter/src/lib.c"), .flags = &.{"-std=c11"} });
    exe_mod.addCSourceFile(.{ .file = b.path("vendor/grammars/zig/parser.c"), .flags = &.{"-std=c11"} });
    exe_mod.addCSourceFile(.{ .file = b.path("vendor/grammars/go/parser.c"), .flags = &.{"-std=c11"} });
    exe_mod.linkFramework("AppKit", .{});
    exe_mod.linkFramework("Metal", .{});
    exe_mod.linkFramework("QuartzCore", .{});
    exe_mod.linkFramework("CoreVideo", .{});
    exe_mod.linkFramework("CoreGraphics", .{});
    exe_mod.linkFramework("CoreText", .{});
    exe_mod.linkFramework("ImageIO", .{});
    // The workspace registry: rook's own sqlite db, read via the
    // system libsqlite3 (macOS ships it; no vendored dependency).
    exe_mod.linkSystemLibrary("sqlite3", .{});

    const exe = b.addExecutable(.{
        .name = "rookz",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    test_step.dependOn(&run_exe_unit_tests.step);

    // The editor suite (editor+buffer+rope, headless, no C deps) roots
    // at editor.zig — the exe module's test collection never reaches
    // those test decls, so it gets its own test root. This hole once
    // let a broken build read as green.
    const editor_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/editor.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    test_step.dependOn(&b.addRunArtifact(editor_tests).step);
}

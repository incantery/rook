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

    // Build identity. The Makefile stamps ONE id per `make` run into every
    // binary it produces (see internal/version) and passes the same string
    // here, so app and daemon built together report the same build — the
    // compatibility key rookctl warns on and rook-host replaces across.
    // Unstamped local builds are "dev", exactly like the Go side.
    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "id", b.option([]const u8, "build", "build identity (matches the Go BUILD id)") orelse "dev");
    build_opts.addOption([]const u8, "version", b.option([]const u8, "version", "release version (e.g. v0.38.0)") orelse "dev");
    exe_mod.addOptions("build_options", build_opts);

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
    // OSC 9 / OSC 777 desktop notifications (UNUserNotificationCenter).
    exe_mod.linkFramework("UserNotifications", .{});
    // The workspace registry: rook's own sqlite db, read via the
    // system libsqlite3 (macOS ships it; no vendored dependency).
    exe_mod.linkSystemLibrary("sqlite3", .{});

    const exe = b.addExecutable(.{
        .name = "rook",
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

    // Same reason, same shape: paste encoding is pure data rules, and
    // they're security rules, so they get a root that definitely runs.
    const paste_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/paste.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    test_step.dependOn(&b.addRunArtifact(paste_tests).step);

    // Config parsing, likewise — and this one is the sharpest of the
    // three, because sharing a file with rook-host means every failure
    // here is SILENT by design. A bad rule reads as "that keybind just
    // doesn't work", with nothing printed to say why.
    const config_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    test_step.dependOn(&b.addRunArtifact(config_tests).step);

    // e2e: spawns the real app and drives its ctl socket.
    //
    // NOT part of `test`, and not in CI — it needs a window server, a
    // Metal device, and real shells, so it is the local pixel-and-pty
    // gate the headless suites structurally cannot be. Keeping it off
    // `test` is deliberate: CI's value is that it is fast and never
    // flaky, and this is neither.
    const e2e_step = b.step("e2e", "Drive the real app end to end (local only)");
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("e2e/main.zig"),
        .target = target,
        .optimize = .Debug,
    });
    e2e_mod.link_libc = true;
    // Reading a `shot` back as pixels — the half of visibility a text
    // dump cannot give. Same frameworks png.zig writes through.
    e2e_mod.linkFramework("CoreGraphics", .{});
    e2e_mod.linkFramework("ImageIO", .{});
    e2e_mod.linkFramework("CoreFoundation", .{});
    const e2e_exe = b.addExecutable(.{ .name = "e2e", .root_module = e2e_mod });
    const e2e_run = b.addRunArtifact(e2e_exe);
    // The app under test, by path — so `zig build e2e` builds it first
    // and the harness can never drive a stale binary.
    e2e_run.addArtifactArg(exe);
    if (b.args) |args| e2e_run.addArgs(args);
    e2e_step.dependOn(&e2e_run.step);
}

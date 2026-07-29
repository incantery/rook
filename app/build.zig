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

    // The editor suite (editor+buffer+rope) roots at editor.zig — the
    // exe module's test collection never reaches those test decls, so it
    // gets its own test root. This hole once let a broken build read as
    // green.
    //
    // It takes ghostty-vt for its UNICODE tables, and nothing else: the
    // editor and the terminal panes have to agree about how wide a
    // Japanese line is and where a grapheme cluster ends, and the only
    // way two tables cannot disagree is to be one table. Measured at
    // ~150ms on this root once the module is cached.
    const editor_mod = b.createModule(.{
        .root_source_file = b.path("src/editor.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (b.lazyDependency("ghostty", .{ .target = target, .optimize = optimize })) |dep| {
        editor_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }
    const editor_tests = b.addTest(.{ .root_module = editor_mod });
    test_step.dependOn(&b.addRunArtifact(editor_tests).step);

    // The regex engine. It rides in under editor.zig's root already,
    // but it gets its own too: it is pure data rules with a step budget
    // holding back the pathological cases, and a root of its own is
    // what makes `zig build test` name it when one of those slips.
    const regex_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/regex.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    test_step.dependOn(&b.addRunArtifact(regex_tests).step);

    // The case table is generated data, so its tests are the only thing
    // standing between a bad generator run and silently wrong `gU`.
    const unicase_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/unicase.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    test_step.dependOn(&b.addRunArtifact(unicase_tests).step);

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

    // The command registry: pure data + string logic, and the thing four
    // surfaces agree through (keybinds, ⌘ chords, palette, ctl `run`).
    // Its own root for the same reason the three above have one — and
    // because its tests are the only thing checking that ids stay unique
    // and derived ex-names stay legal.
    const registry_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/registry.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    test_step.dependOn(&b.addRunArtifact(registry_tests).step);

    // The ask form's wire shape and JSON escaping. Its own root because a
    // malformed answer body is silently catastrophic: the host rejects
    // it, the answer is lost, and the asker stays blocked forever.
    const asks_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/asks.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    test_step.dependOn(&b.addRunArtifact(asks_tests).step);

    // The agent deck's wire mapping, pinned against a real /agents
    // response — a field renamed upstream shows up as a failing test
    // rather than as a silently empty deck.
    const agents_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/agents.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    test_step.dependOn(&b.addRunArtifact(agents_tests).step);

    // The session view's record→document rendering. Its own root because
    // the shape is the host's to change and a silent mismatch would show
    // up as an empty or misleading transcript, not a crash.
    const transcript_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/transcript.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    test_step.dependOn(&b.addRunArtifact(transcript_tests).step);

    // hostc's HTTP framing. Its own root because of the chunked-encoding
    // bug this exists to prevent: Go switches to chunked once a response
    // outgrows its write buffer, so EVERY panel worked until the first
    // big one, and the symptom was a JSON parse error that read as "the
    // host sent garbage" rather than "we failed to decode it".
    const hostc_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/hostc.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    hostc_tests.root_module.link_libc = true;
    test_step.dependOn(&b.addRunArtifact(hostc_tests).step);

    // The thread-document contract: the prefix arithmetic and the
    // concurrent-reply splice. Its own root because getting the prefix
    // wrong loses a draft — the host 409s and the client has to merge,
    // and a merge that splices at the wrong place eats what you typed.
    const threads_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/threads.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    threads_tests.root_module.link_libc = true;
    test_step.dependOn(&b.addRunArtifact(threads_tests).step);

    // The review gate's rules. Its own root because a client that
    // disagreed with the host about what BLOCKS would render a gate the
    // host will not honour — the worst kind of wrong for this panel.
    const review_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/review.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    review_tests.root_module.link_libc = true;
    test_step.dependOn(&b.addRunArtifact(review_tests).step);

    // The UI layer's text fitting. Its own root for the reason logged
    // above editor_tests — the exe module's test collection does not
    // reach these decls, and a suite that is never run is worse than no
    // suite. It needs objc and the renderer's frameworks because ui.zig
    // sits on render.zig; the tests themselves touch neither.
    const ui_mod = b.createModule(.{
        .root_source_file = b.path("src/ui.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    if (b.lazyDependency("zig_objc", .{ .target = b.graph.host, .optimize = .Debug })) |dep| {
        ui_mod.addImport("objc", dep.module("objc"));
    }
    ui_mod.link_libc = true;
    ui_mod.linkFramework("AppKit", .{});
    ui_mod.linkFramework("Metal", .{});
    ui_mod.linkFramework("QuartzCore", .{});
    ui_mod.linkFramework("CoreGraphics", .{});
    ui_mod.linkFramework("CoreText", .{});
    const ui_tests = b.addTest(.{ .root_module = ui_mod });
    test_step.dependOn(&b.addRunArtifact(ui_tests).step);

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

    // Compile the harness without running it — the CI half of e2e.
    //
    // `zig build e2e` RUNS the suite, which CI cannot: no window server,
    // no Metal device, no shells. But nothing else in the default build
    // graph reaches e2e/, so without this step the harness compiles only
    // when someone runs it, and Zig's std churn rots it silently in
    // between (writing it cost three removals in one file:
    // std.Thread.sleep, std.time.milliTimestamp, std.fs.cwd). This turns
    // that into a red build instead of a compile error discovered at the
    // moment you actually needed the suite.
    const e2e_check = b.step("e2e-check", "Compile the e2e harness without running it");
    e2e_check.dependOn(&e2e_exe.step);
}

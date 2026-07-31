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
    //
    // emit-xcframework=false because we consume ghostty as a Zig module,
    // not as a framework. Left at its default it is ON for a macOS host,
    // and building it retargets to iOS — which wants the iphoneos SDK that
    // only full Xcode ships. On a Command Line Tools-only machine ghostty's
    // build.zig then dies at configure time with DarwinSdkNotFound, before
    // one line of rook compiles. Off also defaults emit-macos-app off, so
    // we never shell out to xcodebuild for an app bundle we don't want.
    // One args value for every ghostty dep call below: differing args mean
    // a differently-configured second instance, so this has to stay shared.
    const ghostty_args = .{
        .target = target,
        .optimize = optimize,
        .@"emit-xcframework" = false,
    };
    if (b.lazyDependency("ghostty", ghostty_args)) |dep| {
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

    // Syntax highlighting used to live here: the tree-sitter runtime plus
    // five vendored grammars, compiled straight into the binary. That was
    // 4.6MB of generated parse table in a 7.1MB rook — 940k lines of C
    // nobody reads — and it is not how anyone else does it. neovim, helix,
    // emacs and zed all LOAD grammars (dylibs, or wasm in zed's case);
    // vscode does not even have parse tables, it interprets TextMate
    // grammars as data.
    //
    // So it is out, and highlighting is gone with it until the loader
    // lands. The seam survives: editor.Editor's hl_* hooks are nullable
    // function pointers and an editor with none set renders plain text,
    // which is exactly what headless tests have always exercised.
    // docs/OWED.md carries what comes back and in what shape.
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
    if (b.lazyDependency("ghostty", ghostty_args)) |dep| {
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

    // The ⌘P index's ignore rules. Its own root because "why is my file
    // missing from the picker" is unanswerable from the app: a skipped
    // directory looks exactly like a directory that had nothing in it.
    const filelist_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/filelist.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    }) });
    test_step.dependOn(&b.addRunArtifact(filelist_tests).step);

    // Search's matching rules: smartcase, the binary probe, and the
    // line-trim that has to keep the match visible. Pure data logic
    // behind a panel, which is the shape that earns a headless root.
    const search_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/search.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    }) });
    test_step.dependOn(&b.addRunArtifact(search_tests).step);

    // Key encoding. The strongest case in the tree for a headless root:
    // every one of these is an exact byte sequence, the failure mode is
    // a key that silently does nothing in one program, and you cannot
    // see any of it without a window unless the table is testable
    // alone. shift+Tab reached Claude Code as 0x19 for weeks.
    const keyenc_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/keyenc.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    }) });
    test_step.dependOn(&b.addRunArtifact(keyenc_tests).step);

    // The open-document table. Its own root because what it guards is
    // an OWNERSHIP invariant, and both ways of getting it wrong are
    // silent: one reference too many leaks a document for the life of
    // the process, one too few frees a rope two panes are still
    // drawing from.
    const docs_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/docs.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    }) });
    test_step.dependOn(&b.addRunArtifact(docs_tests).step);

    // The LSP client. Its own root because the whole module is a
    // contract with a process we did not write: every failure it guards
    // is a stall or a silence rather than a crash — a server→client
    // request we never answered (the session hangs), a LocationLink we
    // failed to read (go-to-definition "does nothing"), a reply we
    // dropped (a spinner nobody can clear). Sans-IO exists so those are
    // testable without spawning gopls, and libc is here for the two
    // tests that DO spawn, which prove the pipe and the teardown.
    const lsp_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/lsp.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    }) });
    test_step.dependOn(&b.addRunArtifact(lsp_tests).step);

    // Running git, and the repo-path guard. Its own root because both
    // halves fail silently when wrong: `git diff --no-index` exits 1 for
    // "the files differ", so a runner that read nonzero as failure would
    // report every changed file as having no hunks and every anchor
    // would quietly stop moving — and confine() is a traversal guard, so
    // its bugs are the kind you only notice from the outside.
    const git_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/git.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    test_step.dependOn(&b.addRunArtifact(git_tests).step);

    // The plugin client: grant enforcement and the frame reader. Its own
    // root because the frame reader is the part that has to be right — a
    // plugin that answers in pieces, or never, is the normal case rather
    // than the edge one, and neither is reachable from a unit test that
    // does not open a real pipe.
    const plugins_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/plugins.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    plugins_tests.root_module.link_libc = true;
    test_step.dependOn(&b.addRunArtifact(plugins_tests).step);

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
    // The suite re-execs itself as a FAKE language server (`--fake-lsp`),
    // so the lsp scenario needs no gopls installed — a suite that failed
    // on a fresh machine for want of a toolchain would be testing the
    // machine. It speaks real framing through the real parser, which is
    // also the point: the fake cannot drift from the client.
    e2e_mod.addImport("lsp", b.createModule(.{
        .root_source_file = b.path("src/lsp.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    }));
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

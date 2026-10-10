// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("serial", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = needsLibC(target),
    });

    const mod_tests = b.addTest(.{
        .name = "serial-test",
        .root_module = mod,
        // kcov reads nothing from the self-hosted backend's debug info.
        .use_llvm = true,
    });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    // The same tests as a program to carry to another machine, which is how
    // they reach a platform this one cannot run: build with
    // `-Dtarget=x86_64-freebsd`, say, and run zig-out/bin/serial-test there.
    const test_exe_step = b.step("test-exe", "Install the test binary, for running elsewhere");
    test_exe_step.dependOn(&b.addInstallArtifact(mod_tests, .{}).step);

    const check_step = b.step("check", "Compile everything without running it");

    // The other platforms cannot be tested from here, but they can be
    // compiled, and a backend nobody compiles is a backend that has stopped
    // compiling. Nothing asks for the binaries, so none is linked -- which is
    // what lets DragonFly, whose libc Zig does not ship, be checked at all.
    for ([_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .linux },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .freebsd },
        .{ .cpu_arch = .aarch64, .os_tag = .freebsd },
        .{ .cpu_arch = .x86_64, .os_tag = .netbsd },
        .{ .cpu_arch = .x86_64, .os_tag = .openbsd },
        .{ .cpu_arch = .x86_64, .os_tag = .dragonfly },
    }) |query| {
        const other = b.resolveTargetQuery(query);
        check_step.dependOn(&b.addTest(.{
            .name = b.fmt("serial-{s}-{s}", .{ @tagName(query.cpu_arch.?), @tagName(query.os_tag.?) }),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = other,
                .optimize = optimize,
                .link_libc = needsLibC(other),
            }),
        }).step);
    }

    // -- documentation -------------------------------------------------------
    //
    // Zig emits the API documentation as a side effect of compiling, so the
    // module is built as a library purely to get at it.
    const library = b.addLibrary(.{ .name = "serial", .root_module = mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Build the API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    // The viewer fetches `sources.tar` and `main.wasm` at runtime, which a
    // browser refuses to do from a `file://` page, so reading the docs
    // locally means serving them.
    const docs_port = b.option(u16, "docs-port", "Port for `zig build docs-serve` (default 8000)") orelse 8000;

    const docs_server = b.addExecutable(.{
        .name = "docs-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/docs_server.zig"),
            // Always the machine running the build, never whatever -Dtarget
            // the library is being built for.
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run_docs_server = b.addRunArtifact(docs_server);
    run_docs_server.step.dependOn(&install_docs.step);
    run_docs_server.addDirectoryArg(library.getEmittedDocs());
    run_docs_server.addArg(b.fmt("{d}", .{docs_port}));
    // It runs until interrupted, so its output has to reach the terminal
    // rather than being captured by the build runner.
    run_docs_server.stdio = .inherit;

    const docs_serve_step = b.step("docs-serve", "Serve the API documentation over HTTP");
    docs_serve_step.dependOn(&run_docs_server.step);

    test_step.dependOn(&b.addRunArtifact(
        b.addTest(.{ .root_module = docs_server.root_module }),
    ).step);
    check_step.dependOn(&docs_server.step);
}

/// The Linux backend is raw system calls and the Windows one is kernel32, but
/// macOS and the BSDs are reached through their libc, which is the only
/// interface to the terminal those systems promise to keep stable.
fn needsLibC(target: std.Build.ResolvedTarget) ?bool {
    return switch (target.result.os.tag) {
        .linux, .windows => null,
        else => true,
    };
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const Backend = enum {
        wayland,
        x11,
    };

    const backend = b.option(
        Backend,
        "backend",
        "Window backend (x11 or wayland)",
    ) orelse .wayland;

    const options = b.addOptions();
    options.addOption(Backend, "backend", backend);

    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const c_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    c_translate.linkSystemLibrary("wayland-client", .{});
    c_translate.linkSystemLibrary("xkbcommon", .{});
    c_translate.addIncludePath(b.path("deps/wayland-protocols/"));
    const c = c_translate.createModule();
    c.addCSourceFile(.{ .file = b.path("deps/wayland-protocols/wp-cursor-shape-v1.c") });
    c.addCSourceFile(.{ .file = b.path("deps/wayland-protocols/zwp-tablet-v2.c") });
    c.addCSourceFile(.{ .file = b.path("deps/wayland-protocols/xdg-shell.c") });
    c.addCSourceFile(.{ .file = b.path("deps/wayland-protocols/zxdg-decoration-v1.c") });

    const platform = b.addModule("platform", .{
        .root_source_file = b.path("src/platform/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = c },
            .{ .name = "core", .module = core },
        },
    });
    platform.addOptions("options", options);

    const exe = b.addExecutable(.{
        .name = "term",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "platform", .module = platform },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}

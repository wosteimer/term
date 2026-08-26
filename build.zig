const std = @import("std");

const Backend = enum {
    wayland,
    x11,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const backend = b.option(
        Backend,
        "backend",
        "Window backend (x11 or wayland)",
    ) orelse .wayland;

    const options = b.addOptions();
    options.addOption(Backend, "backend", backend);

    const c_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    c_translate.linkSystemLibrary("pixman-1", .{});
    c_translate.linkSystemLibrary("fontconfig", .{});
    c_translate.linkSystemLibrary("harfbuzz", .{});
    c_translate.linkSystemLibrary("freetype2", .{});
    c_translate.addIncludePath(b.path("deps/stb_rect_pack/"));
    c_translate.addIncludePath(b.path("deps/utf8proc"));
    switch (backend) {
        .wayland => {
            c_translate.defineCMacro("LINUX_PLATFORM_WAYLAND", null);
            c_translate.linkSystemLibrary("wayland-client", .{});
            c_translate.linkSystemLibrary("xkbcommon", .{});
            c_translate.addIncludePath(b.path("deps/wayland-protocols/"));
        },
        .x11 => {
            c_translate.defineCMacro("LINUX_PLATFORM_X11", null);
        },
    }

    const c = c_translate.createModule();
    c.addIncludePath(b.path("deps/stb_rect_pack/"));
    c.addCSourceFile(.{ .file = b.path("deps/stb_rect_pack/stb_rect_pack.c") });
    c.addCSourceFile(.{ .file = b.path("deps/utf8proc/utf8proc.c") });
    switch (backend) {
        .wayland => {
            c.addCSourceFile(.{ .file = b.path("deps/wayland-protocols/wp-cursor-shape-v1.c") });
            c.addCSourceFile(.{ .file = b.path("deps/wayland-protocols/zwp-tablet-v2.c") });
            c.addCSourceFile(.{ .file = b.path("deps/wayland-protocols/xdg-shell.c") });
            c.addCSourceFile(.{ .file = b.path("deps/wayland-protocols/zxdg-decoration-v1.c") });
        },
        .x11 => {},
    }

    const generator = b.addExecutable(.{
        .name = "generator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/generate-emoji-sequences.zig"),
            .target = b.graph.host,
        }),
    });
    const generator_run = b.addRunArtifact(generator);
    const generator_output = generator_run.addOutputFileArg("emoji.zig");
    generator_run.addFileArg(b.path("emoji/emoji-sequences.txt"));
    generator_run.addFileArg(b.path("emoji/emoji-zwj-sequences.txt"));

    const emoji = b.addModule("emoji", .{
        .root_source_file = generator_output,
        .target = target,
        .optimize = optimize,
    });

    const term = b.addModule("term", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = c },
            .{ .name = "emoji", .module = emoji },
        },
    });
    term.addOptions("options", options);

    const exe = b.addExecutable(.{
        .name = "term",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "term", .module = term },
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

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}

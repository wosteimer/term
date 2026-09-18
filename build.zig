const std = @import("std");

const Backend = enum {
    wayland,
    x11,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const backend = b.option(
        Backend,
        "backend",
        "Window backend (x11 or wayland)",
    ) orelse .wayland;

    const options = b.addOptions();
    options.addOption(Backend, "backend", backend);

    var protocols = std.ArrayList(WaylandProtocol).empty;
    const wayland_protocols_dir = try b.build_root.handle.openDir(
        b.graph.io,
        "wayland-protocols/",
        .{ .iterate = true },
    );
    var iter = wayland_protocols_dir.iterate();
    while (try iter.next(b.graph.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".xml")) continue;
        const protocol = genWaylandProtocol(b, try b.path("wayland-protocols/").join(b.allocator, entry.name));
        try protocols.append(b.allocator, protocol);
    }

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
    switch (backend) {
        .wayland => {
            c_translate.defineCMacro("LINUX_PLATFORM_WAYLAND", null);
            c_translate.linkSystemLibrary("wayland-client", .{});
            c_translate.linkSystemLibrary("xkbcommon", .{});

            const wayland_protocol_headers = b.addWriteFiles();
            for (protocols.items) |protocol| {
                _ = wayland_protocol_headers.addCopyFile(protocol.header, protocol.header_name);
            }
            c_translate.addIncludePath(wayland_protocol_headers.getDirectory());
        },
        .x11 => {
            c_translate.defineCMacro("LINUX_PLATFORM_X11", null);
        },
    }

    const c = c_translate.createModule();
    c.addIncludePath(b.path("deps/stb_rect_pack/"));
    c.addCSourceFile(.{ .file = b.path("deps/stb_rect_pack/stb_rect_pack.c") });
    switch (backend) {
        .wayland => {
            for (protocols.items) |protocol| {
                c.addCSourceFile(.{ .file = protocol.source });
            }
        },
        .x11 => {},
    }

    const zg = b.dependency("zg", .{});

    const term = b.addModule("term", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = c },
            .{ .name = "Graphemes", .module = zg.module("Graphemes") },
            .{ .name = "Emoji", .module = zg.module("Emoji") },
            .{ .name = "code_point", .module = zg.module("code_point") },
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

const WaylandProtocol = struct {
    source_name: []const u8,
    header_name: []const u8,
    source: std.Build.LazyPath,
    header: std.Build.LazyPath,
};

fn genWaylandProtocol(b: *std.Build, protocol_xml_path: std.Build.LazyPath) WaylandProtocol {
    const name = std.mem.cutSuffix(u8, std.Io.Dir.path.basename(protocol_xml_path.getDisplayName()), ".xml").?;

    const source_name = b.fmt("{s}.c", .{name});
    const source = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    source.addFileArg(protocol_xml_path);
    const source_file = source.addOutputFileArg(source_name);

    const header_name = b.fmt("{s}.h", .{name});
    const header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    header.addFileArg(protocol_xml_path);
    const header_file = header.addOutputFileArg(header_name);

    return .{
        .header_name = header_name,
        .source_name = source_name,
        .source = source_file,
        .header = header_file,
    };
}

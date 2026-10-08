const std = @import("std");
const Platform = @import("term").platform.Platform;
const Event = @import("term").platform.Event;
const Modifiers = @import("term").platform.Modifiers;
const Render = @import("term").Render;
const Rect = @import("term").Render.Rect;
const DateTime = @import("term").core.DateTime;
const Term = @import("term").Term;
const Tty = @import("term").Tty;
const c = @import("term").c;
const Key = @import("term").platform.Key;
const Pallete = @import("term").colors.Pallete;

pub const std_options = std.Options{
    .logFn = logFn,
};

const log = std.log.scoped(.main);

const esc = "\x1B";

const Escape = struct {
    pub const Modifier = enum(u8) {
        none = 1,
        shift = 2,
        alt = 3,
        alt_shift = 4,
        ctrl = 5,
        ctrl_shift = 6,
        ctrl_alt = 7,
        ctrl_alt_shift = 8,
    };

    const fmts = std.static_string_map.StaticStringMap([]const u8).initComptime(&.{
        .{ "up", esc ++ "[{s}A" },
        .{ "down", esc ++ "[{s}B" },
        .{ "right", esc ++ "[{s}C" },
        .{ "left", esc ++ "[{s}D" },
        .{ "home", esc ++ "[{s}H" },
        .{ "end", esc ++ "[{s}F" },
        .{ "insert", esc ++ "[2{s}~" },
        .{ "delete", esc ++ "[3{s}~" },
        .{ "page_up", esc ++ "[5{s}~" },
        .{ "page_down", esc ++ "[6{s}~" },
        .{ "f1", esc ++ "[{s}P" },
        .{ "f2", esc ++ "[{s}Q" },
        .{ "f3", esc ++ "[{s}R" },
        .{ "f4", esc ++ "[{s}S" },
        .{ "f5", esc ++ "[15{s}~" },
        .{ "f6", esc ++ "[17{s}~" },
        .{ "f7", esc ++ "[18{s}~" },
        .{ "f8", esc ++ "[19{s}~" },
        .{ "f9", esc ++ "[20{s}~" },
        .{ "f10", esc ++ "[21{s}~" },
        .{ "f11", esc ++ "[23{s}~" },
        .{ "f12", esc ++ "[24{s}~" },
    });

    pub fn toString(buf: []u8, key: Key, modifier: Modifier) ![]const u8 {
        var modifiers_buf: [8]u8 = undefined;
        var modifiers_text: []const u8 = undefined;
        switch (key) {
            .up, .down, .right, .left, .home, .end => {
                if (modifier == .none) {
                    modifiers_text = "";
                } else {
                    modifiers_text = try std.fmt.bufPrint(&modifiers_buf, "1;{d}", .{@intFromEnum(modifier)});
                }
            },
            .insert, .delete, .page_up, .page_down, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => {
                if (modifier == .none) {
                    modifiers_text = "";
                } else {
                    modifiers_text = try std.fmt.bufPrint(&modifiers_buf, ";{d}", .{@intFromEnum(modifier)});
                }
            },
            .f1, .f2, .f3, .f4 => {
                if (modifier == .none) {
                    modifiers_text = "O";
                } else {
                    modifiers_text = try std.fmt.bufPrint(&modifiers_buf, "1;{d}", .{@intFromEnum(modifier)});
                }
            },
            else => return error.InvalidKey,
        }
        return switch (key) {
            .up => std.fmt.bufPrint(buf, esc ++ "[{s}A", .{modifiers_text}),
            .down => std.fmt.bufPrint(buf, esc ++ "[{s}B", .{modifiers_text}),
            .right => std.fmt.bufPrint(buf, esc ++ "[{s}C", .{modifiers_text}),
            .left => std.fmt.bufPrint(buf, esc ++ "[{s}D", .{modifiers_text}),
            .home => std.fmt.bufPrint(buf, esc ++ "[{s}H", .{modifiers_text}),
            .end => std.fmt.bufPrint(buf, esc ++ "[{s}F", .{modifiers_text}),
            .insert => std.fmt.bufPrint(buf, esc ++ "[2{s}~", .{modifiers_text}),
            .delete => std.fmt.bufPrint(buf, esc ++ "[3{s}~", .{modifiers_text}),
            .page_up => std.fmt.bufPrint(buf, esc ++ "[5{s}~", .{modifiers_text}),
            .page_down => std.fmt.bufPrint(buf, esc ++ "[6{s}~", .{modifiers_text}),
            .f1 => std.fmt.bufPrint(buf, esc ++ "[{s}P", .{modifiers_text}),
            .f2 => std.fmt.bufPrint(buf, esc ++ "[{s}Q", .{modifiers_text}),
            .f3 => std.fmt.bufPrint(buf, esc ++ "[{s}R", .{modifiers_text}),
            .f4 => std.fmt.bufPrint(buf, esc ++ "[{s}S", .{modifiers_text}),
            .f5 => std.fmt.bufPrint(buf, esc ++ "[15{s}~", .{modifiers_text}),
            .f6 => std.fmt.bufPrint(buf, esc ++ "[17{s}~", .{modifiers_text}),
            .f7 => std.fmt.bufPrint(buf, esc ++ "[18{s}~", .{modifiers_text}),
            .f8 => std.fmt.bufPrint(buf, esc ++ "[19{s}~", .{modifiers_text}),
            .f9 => std.fmt.bufPrint(buf, esc ++ "[20{s}~", .{modifiers_text}),
            .f10 => std.fmt.bufPrint(buf, esc ++ "[21{s}~", .{modifiers_text}),
            .f11 => std.fmt.bufPrint(buf, esc ++ "[23{s}~", .{modifiers_text}),
            .f12 => std.fmt.bufPrint(buf, esc ++ "[24{s}~", .{modifiers_text}),
            else => return error.InvalidKey,
        };
    }

    pub fn parseModifier(modifiers: Modifiers) Modifier {
        var modifier: Escape.Modifier = .none;
        if (modifiers.shift and !modifiers.alt and !modifiers.control) {
            modifier = .shift;
        } else if (!modifiers.shift and modifiers.alt and !modifiers.control) {
            modifier = .alt;
        } else if (!modifiers.shift and !modifiers.alt and modifiers.control) {
            modifier = .ctrl;
        } else if (modifiers.shift and modifiers.alt and !modifiers.control) {
            modifier = .alt_shift;
        } else if (modifiers.shift and !modifiers.alt and modifiers.control) {
            modifier = .ctrl_shift;
        } else if (!modifiers.shift and modifiers.alt and modifiers.control) {
            modifier = .ctrl_alt;
        } else if (modifiers.shift and modifiers.alt and modifiers.control) {
            modifier = .ctrl_alt_shift;
        }
        return modifier;
    }
};

pub fn main(init: std.process.Init) !void {
    var platform: Platform = undefined;
    platform.init(init.gpa, 1240, 720);
    defer platform.deinit();

    platform.setTitle("hello world");
    platform.enableTextInput();
    platform.enableKeyboardRepeat();

    var render = try Render.init(init.gpa, &platform);
    defer render.deinit();

    const regular_font: Render.DrawTextInfo.Font = .{
        .name = "JetBrains Mono",
        .weight = .light,
        .size = 16,
        .monospace = true,
    };

    var italic_font = regular_font;
    italic_font.italic = true;

    var bold_font = regular_font;
    bold_font.weight = .bold;

    var bold_italic_font = regular_font;
    bold_italic_font.italic = true;
    bold_italic_font.weight = .bold;

    var term = try Term.init(
        init.gpa,
        &render,
        regular_font,
        bold_font,
        italic_font,
        bold_italic_font,
        Pallete.init,
        1240,
        720,
    );
    defer term.deinit();

    var tty: Tty = undefined;
    try tty.init(init.io, init.environ_map, &platform, &term);

    var scratch_alloc = std.heap.ArenaAllocator.init(init.gpa);
    defer scratch_alloc.deinit();
    var presented = false;
    var resized_event: ?Event.WindowResized = null;

    mainloop: while (true) {
        std.debug.assert(scratch_alloc.reset(.{ .retain_with_limit = 1024 * 64 }));
        if (tty.closed) break;
        platform.pumpEvents();
        while (platform.pollEvent()) |ev| {
            switch (ev) {
                .window_close_requested => break :mainloop,
                .window_resized => |resized_ev| {
                    term.need_redraw = true;
                    resized_event = resized_ev;
                },
                .text_input_preedit_changed => |t| log.debug("text input preedit event \"{s}\"", .{t}),
                .text_input_changed => |t| {
                    if (!std.mem.eql(u8, t, &.{std.ascii.control_code.del})) {
                        try tty.writer.writeAll(t);
                        try tty.writer.flush();
                    }
                },
                .keyboard_key_down => |key_ev| {
                    const modifier = Escape.parseModifier(key_ev.modifiers);
                    var buf: [32]u8 = undefined;
                    if (Escape.toString(&buf, key_ev.key, modifier)) |t| {
                        try tty.writer.writeAll(t);
                        try tty.writer.flush();
                    } else |err| switch (err) {
                        error.InvalidKey => {},
                        else => return err,
                    }
                },
                .frame => presented = true,
                else => {},
            }
        }

        if (term.need_redraw and presented) {
            if (resized_event) |ev| {
                try term.resize(ev.width, ev.height);
                tty.resize(ev.width, ev.height, @intCast(term.cols), @intCast(term.rows));
                resized_event = null;
            }
            try draw(scratch_alloc.allocator(), &render, &term);
            presented = false;
        }
    }
}

fn draw(scratch: std.mem.Allocator, render: *Render, term: *Term) !void {
    if (try render.startDraw()) |image| {
        defer render.endDraw(image) catch {};
        try render.fill(image, term.pallete.default_background);
        try term.draw(scratch);
        try render.drawImage(image, .{
            .src = .{ .image = term.image },
            .rect = .{
                .x = 0,
                .y = 0,
                .width = @intCast(term.pixel_width),
                .height = @intCast(term.pixel_height),
            },
            .blend = .none,
        });
    }
}

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();

    stderr.setColor(switch (level) {
        .err => .red,
        .warn => .yellow,
        .info => .green,
        .debug => .magenta,
    }) catch {};
    stderr.setColor(.bold) catch {};
    stderr.writer.writeAll(level.asText()) catch {};
    stderr.setColor(.reset) catch {};
    stderr.setColor(.dim) catch {};
    stderr.setColor(.bold) catch {};
    const now = DateTime.init(@intCast(std.Io.Timestamp.now(io, .real).toSeconds()));
    if (scope != .default) stderr.writer.print("({t})[{f}]", .{ scope, now }) catch {};
    stderr.writer.writeAll(": ") catch {};
    stderr.setColor(.reset) catch {};
    stderr.writer.print(format ++ "\n", args) catch {};
}

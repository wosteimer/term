const std = @import("std");

const Size = @import("common.zig").Size;
const Rect = @import("common.zig").Rect;
const Shape = @import("common.zig").Shape;
const Button = @import("common.zig").Button;
const Modifiers = @import("common.zig").Modifiers;
const Key = @import("common.zig").Key;
const Event = @import("common.zig").Event;

const log = std.log.scoped(.x11);

const Self = @This();

pub fn init() !Self {
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn deinit(self: *Self) void {
    _ = self;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn present(self: *Self) void {
    _ = self;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn getTitle(self: *Self) []const u8 {
    _ = self;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn setTitle(self: *Self, title: []const u8) void {
    _ = self;
    _ = title;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn setFullscreen(self: *Self) void {
    _ = self;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn unsetFullscreen(self: *Self) void {
    _ = self;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn maximize(self: *Self) void {
    _ = self;
}

pub fn minimize(self: *Self) void {
    _ = self;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn restore(self: *Self) void {
    _ = self;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn getMaxSize(self: *Self) Size {
    _ = self;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn setMaxSize(self: *Self, width: u32, height: u32) void {
    _ = self;
    _ = width;
    _ = height;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn getMinSize(self: *Self) Size {
    _ = self;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn setMinSize(self: *Self, width: u32, height: u32) void {
    _ = self;
    _ = width;
    _ = height;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn getSize(self: *Self) Size {
    _ = self;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn getBuffer(self: *Self) []u32 {
    _ = self;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn pollEvent(self: *Self) ?Event {
    _ = self;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn setPointerShape(self: *Self, shape: Shape) void {
    _ = self;
    _ = shape;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn buttonIsPressed(self: *Self, button: Button) bool {
    _ = self;
    _ = button;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn keyIsPressed(self: *Self, key: Key) bool {
    _ = self;
    _ = key;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn getModifiers(self: *Self) Modifiers {
    _ = self;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn textInputEnable(self: *Self) void {
    _ = self;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn textInputDisable(self: *Self) void {
    _ = self;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn textInputSetRect(self: *Self, rect: Rect) void {
    _ = self;
    _ = rect;
    log.err("Not Implemented", .{});
    unreachable;
}

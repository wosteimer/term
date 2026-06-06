const std = @import("std");
const c = @import("c");

const Size = @import("common.zig").Size;
const Rect = @import("common.zig").Rect;
const Shape = @import("common.zig").Shape;
const Button = @import("common.zig").Button;
const Event = @import("common.zig").Event;

const log = std.log.scoped(.wayland);

const Self = @This();

const wl_registry_listener = c.wl_registry_listener{
    .global = wlRegistryGlobal,
    .global_remove = wlRegistryGlobalRemove,
};

wl_display: ?*c.wl_display,
wl_registry: ?*c.wl_registry,

pub fn init() Self {
    const wl_display = c.wl_display_connect(null);
    const wl_registry = c.wl_display_get_registry(wl_display);
    _ = c.wl_registry_add_listener(wl_registry, &wl_registry_listener, null);
    _ = c.wl_display_roundtrip(wl_display);
    return .{
        .wl_display = wl_display,
        .wl_registry = wl_registry,
    };
}

pub fn deinit(self: *Self) void {
    c.wl_registry_destroy(self.wl_registry);
    c.wl_display_disconnect(self.wl_display);
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

pub fn setFullscreen(self: *Self, is_fullscreen: bool) void {
    _ = self;
    _ = is_fullscreen;
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

pub fn setCursorRect(self: *Self, rect: Rect) void {
    _ = self;
    _ = rect;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn setPointerShape(self: *Self, shape: Shape) void {
    _ = self;
    _ = shape;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn pointerButtonIsPressed(self: *Self, button: Button) bool {
    _ = self;
    _ = button;
    log.err("Not Implemented", .{});
    unreachable;
}

fn wlRegistryGlobal(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;

    log.debug("{s} is available in {d} version", .{ interface, version });
}

fn wlRegistryGlobalRemove(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
}

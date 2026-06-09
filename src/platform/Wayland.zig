const std = @import("std");
const c = @import("c");

const Size = @import("common.zig").Size;
const Rect = @import("common.zig").Rect;
const Shape = @import("common.zig").Shape;
const Button = @import("common.zig").Button;
const Key = @import("common.zig").Key;
const Modifiers = @import("common.zig").Modifiers;
const Event = @import("common.zig").Event;
const Queue = @import("core").Queue;

const log = std.log.scoped(.wayland);

const Self = @This();

const TextInputState = enum {
    none,
    pressed,
    holding,
    repeating,
};

const wl_registry_listener = c.wl_registry_listener{
    .global = wlRegistryGlobal,
    .global_remove = wlRegistryGlobalRemove,
};

const xdg_wm_base_listener = c.xdg_wm_base_listener{
    .ping = xdgWmBasePing,
};

const wl_seat_listener = c.wl_seat_listener{
    .capabilities = wlSeatCapabilities,
    .name = wlSeatName,
};

const xdg_surface_listener = c.xdg_surface_listener{
    .configure = xdgSurfaceConfigure,
};

const xdg_toplevel_listener = c.xdg_toplevel_listener{
    .close = xdgToplevelClose,
    .configure = xdgToplevelConfigure,
    .configure_bounds = xdgToplevelConfigureBounds,
    .wm_capabilities = xdgToplevelWmCapabilities,
};

const wl_callback_listener = c.wl_callback_listener{
    .done = wlCallbackDone,
};

const wl_buffer_listener = c.wl_buffer_listener{
    .release = wlBufferRelease,
};

const wl_keyboard_listener = c.wl_keyboard_listener{
    .enter = wlKeyboardEnter,
    .leave = wlKeyboardLeave,
    .keymap = wlKeyboardKeymap,
    .key = wlKeyboardKey,
    .modifiers = wlKeyboardModifiers,
    .repeat_info = wlKeyboardRepeatInfo,
};

const wl_pointer_listener = c.wl_pointer_listener{
    .enter = wlPointerEnter,
    .leave = wlPointerLeave,
    .motion = wlPointerMotion,
    .button = wlPointerButton,
    .axis = wlPointerAxis,
    .frame = wlPointerFrame,
    .axis_source = wlPointerAxisSource,
    .axis_stop = wlPointerAxisStop,
    .axis_discrete = wlPointerAxisDiscrete,
    .axis_relative_direction = wlPointerAxisRelativeDirection,
    .axis_value120 = wlPointerAxisValue120,
};

const evdev_key_max = 256;
const evdev_to_key = blk: {
    var table: [evdev_key_max]Key = undefined;
    for (&table) |*value| value.* = .unknown;
    for (std.ascii.lowercase) |letter| {
        table[@field(c, "KEY_" ++ .{std.ascii.toUpper(letter)})] = @field(Key, &.{letter});
    }
    for ('0'..'9' + 1) |digit| {
        table[@field(c, "KEY_" ++ .{std.ascii.toUpper(digit)})] = @field(Key, &.{digit});
        table[@field(c, "KEY_KP" ++ .{std.ascii.toUpper(digit)})] = @field(Key, "numpad_" ++ .{digit});
    }
    for (0..10) |i| {
        table[c.KEY_F1 + i] = @enumFromInt(@as(u32, @intFromEnum(Key.f1)) + i);
    }
    table[c.KEY_F11] = .f11;
    table[c.KEY_F12] = .f12;

    table[c.KEY_KPENTER] = .numpad_enter;
    table[c.KEY_KPPLUS] = .numpad_plus;
    table[c.KEY_KPMINUS] = .numpad_minus;
    table[c.KEY_KPASTERISK] = .numpad_asterisk;
    table[c.KEY_KPSLASH] = .numpad_slash;
    table[c.KEY_KPDOT] = .numpad_dot;

    table[c.KEY_ENTER] = .enter;
    table[c.KEY_ESC] = .escape;
    table[c.KEY_BACKSPACE] = .backspace;
    table[c.KEY_TAB] = .tab;
    table[c.KEY_SPACE] = .space;

    table[c.KEY_LEFTSHIFT] = .left_shift;
    table[c.KEY_RIGHTSHIFT] = .right_shift;
    table[c.KEY_LEFTCTRL] = .left_control;
    table[c.KEY_RIGHTCTRL] = .right_control;
    table[c.KEY_LEFTALT] = .left_alt;
    table[c.KEY_RIGHTALT] = .right_alt;
    table[c.KEY_LEFTMETA] = .left_meta;
    table[c.KEY_RIGHTMETA] = .right_meta;
    table[c.KEY_MENU] = .menu;

    table[c.KEY_GRAVE] = .back_quote;
    table[c.KEY_MINUS] = .minus;
    table[c.KEY_EQUAL] = .equal;
    table[c.KEY_BACKSLASH] = .backslash;
    table[c.KEY_LEFTBRACE] = .left_brace;
    table[c.KEY_RIGHTBRACE] = .right_brace;
    table[c.KEY_CAPSLOCK] = .caps_lock;
    table[c.KEY_SEMICOLON] = .semicolon;
    table[c.KEY_APOSTROPHE] = .apostrophe;
    table[c.KEY_COMMA] = .comma;
    table[c.KEY_DOT] = .dot;
    table[c.KEY_SLASH] = .slash;

    table[c.KEY_INSERT] = .insert;
    table[c.KEY_HOME] = .home;
    table[c.KEY_PAGEUP] = .page_up;
    table[c.KEY_DELETE] = .delete;
    table[c.KEY_END] = .end;
    table[c.KEY_PAGEDOWN] = .page_down;

    table[c.KEY_UP] = .up;
    table[c.KEY_DOWN] = .down;
    table[c.KEY_LEFT] = .left;
    table[c.KEY_RIGHT] = .right;

    table[c.KEY_PRINT] = .print;
    table[c.KEY_SCROLLLOCK] = .scroll_lock;
    table[c.KEY_PAUSE] = .pause;

    table[c.KEY_102ND] = .@"102nd";
    table[c.KEY_RO] = .ro;
    table[c.KEY_COMPOSE] = .compose;

    break :blk table;
};

const keyboard_state_len = @typeInfo(Key).@"enum".fields.len;
const pointer_state_len = @typeInfo(Button).@"enum".fields.len;

const Impl = struct {
    io: std.Io,

    wl_display: ?*c.wl_display = null,
    wl_registry: ?*c.wl_registry = null,
    wl_compositor: ?*c.wl_compositor = null,
    wl_surface: ?*c.wl_surface = null,
    wl_seat: ?*c.wl_seat = null,
    wl_shm: ?*c.wl_shm = null,
    wl_shm_pool: ?*c.wl_shm_pool = null,
    wl_buffer: ?*c.wl_buffer = null,
    wl_callback: ?*c.wl_callback = null,
    wl_keyboard: ?*c.wl_keyboard = null,
    wl_pointer: ?*c.wl_pointer = null,

    wp_cursor_shape_manager_v1: ?*c.wp_cursor_shape_manager_v1 = null,
    wp_cursor_shape_device_v1: ?*c.wp_cursor_shape_device_v1 = null,

    xdg_wm_base: ?*c.xdg_wm_base = null,
    xdg_surface: ?*c.xdg_surface = null,
    xdg_toplevel: ?*c.xdg_toplevel = null,

    xkb_context: ?*c.xkb_context = null,
    xkb_state: ?*c.xkb_state = null,
    xkb_keymap: ?*c.xkb_keymap = null,
    xkb_compose_table: ?*c.xkb_compose_table = null,
    xkb_compose_state: ?*c.xkb_compose_state = null,

    events: Queue(Event, 256) = .empty,
    resized: bool = false,
    title: [4096:0]u8 = .{0} ** 4096,
    width: u32 = 200,
    height: u32 = 200,
    min_width: u32 = 200,
    min_height: u32 = 200,
    max_width: u32 = 200,
    max_height: u32 = 200,
    buffer: ?[]u32 = null,

    pointer_shape: Shape = .default,
    pointer_state: [pointer_state_len]bool = .{false} ** pointer_state_len,
    pointer_serial: u32 = 0,
    pointer_position_changed: bool = false,
    pointer_position_x: u32 = 0,
    pointer_position_y: u32 = 0,
    pointer_axis_changed: bool = false,
    pointer_axis_x: f32 = 0,
    pointer_axis_y: f32 = 0,

    keyboard_state: [keyboard_state_len]bool = .{false} ** keyboard_state_len,
    text_input_rate: u32 = 0,
    text_input_delay: u32 = 0,
    text_input_enabled: bool = false,
    text_input_preedit: [4096:0]u8 = .{0} ** 4096,
    text_input_state: TextInputState = .none,
    text_input_time: i64 = 0,
    text_input_last_keysym: u32 = 0,
};

impl: *Impl,

pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
    var self = Self{
        .impl = try allocator.create(Impl),
    };
    self.impl.* = .{ .io = io };
    self.impl.wl_display = c.wl_display_connect(null);
    self.impl.wl_registry = c.wl_display_get_registry(self.impl.wl_display);
    _ = c.wl_registry_add_listener(self.impl.wl_registry, &wl_registry_listener, self.impl);
    _ = c.wl_display_roundtrip(self.impl.wl_display);

    _ = c.xdg_wm_base_add_listener(self.impl.xdg_wm_base, &xdg_wm_base_listener, self.impl);
    _ = c.wl_seat_add_listener(self.impl.wl_seat, &wl_seat_listener, self.impl);

    self.impl.wl_surface = c.wl_compositor_create_surface(self.impl.wl_compositor);
    self.impl.xdg_surface = c.xdg_wm_base_get_xdg_surface(self.impl.xdg_wm_base, self.impl.wl_surface);
    self.impl.xdg_toplevel = c.xdg_surface_get_toplevel(self.impl.xdg_surface);

    _ = c.xdg_surface_add_listener(self.impl.xdg_surface, &xdg_surface_listener, self.impl);
    _ = c.xdg_toplevel_add_listener(self.impl.xdg_toplevel, &xdg_toplevel_listener, self.impl);
    configureWlShmPool(self.impl);
    self.impl.wl_callback = c.wl_surface_frame(self.impl.wl_surface);
    _ = c.wl_callback_add_listener(self.impl.wl_callback, &wl_callback_listener, self.impl);

    self.impl.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
    const locale = std.c.setlocale(.ALL, null) orelse std.c.setlocale(.CTYPE, null) orelse "C";
    self.impl.xkb_compose_table = c.xkb_compose_table_new_from_locale(
        self.impl.xkb_context,
        locale,
        c.XKB_COMPOSE_COMPILE_NO_FLAGS,
    );
    self.impl.xkb_compose_state = c.xkb_compose_state_new(
        self.impl.xkb_compose_table,
        c.XKB_COMPOSE_STATE_NO_FLAGS,
    );
    c.wl_surface_commit(self.impl.wl_surface);
    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    secureDeinit(self.impl.wl_buffer, c.wl_buffer_destroy);
    secureDeinit(self.impl.wl_callback, c.wl_callback_destroy);
    secureDeinit(self.impl.wl_shm_pool, c.wl_shm_pool_destroy);
    secureDeinit(self.impl.wl_keyboard, c.wl_keyboard_destroy);

    secureDeinit(self.impl.xkb_keymap, c.xkb_keymap_unref);
    secureDeinit(self.impl.xkb_state, c.xkb_state_unref);
    secureDeinit(self.impl.xkb_context, c.xkb_context_unref);
    secureDeinit(self.impl.xkb_compose_table, c.xkb_compose_table_unref);
    secureDeinit(self.impl.xkb_compose_state, c.xkb_compose_state_unref);

    secureDeinit(self.impl.xdg_toplevel, c.xdg_toplevel_destroy);
    secureDeinit(self.impl.xdg_surface, c.xdg_surface_destroy);
    secureDeinit(self.impl.xdg_wm_base, c.xdg_wm_base_destroy);

    secureDeinit(self.impl.wl_surface, c.wl_surface_destroy);
    secureDeinit(self.impl.wl_seat, c.wl_seat_destroy);
    secureDeinit(self.impl.wl_shm, c.wl_shm_destroy);
    secureDeinit(self.impl.wl_compositor, c.wl_compositor_destroy);
    secureDeinit(self.impl.wl_registry, c.wl_registry_destroy);
    secureDeinit(self.impl.wl_display, c.wl_display_disconnect);

    allocator.destroy(self.impl);
}

inline fn secureDeinit(obj: anytype, deinitFn: fn (@TypeOf(obj)) callconv(.c) void) void {
    if (obj) |o| deinitFn(o);
}

pub fn present(self: *Self) void {
    self.impl.events.clear();
    _ = c.wl_display_dispatch(self.impl.wl_display);
    if (!self.impl.text_input_enabled) return;
    const current = std.Io.Timestamp.now(self.impl.io, .awake).toMilliseconds();
    const elapsed = current - self.impl.text_input_time;
    switch (self.impl.text_input_state) {
        .pressed => {
            self.impl.text_input_time = current;
            self.impl.text_input_state = .holding;
        },
        .holding => {
            if (self.impl.text_input_delay <= elapsed) {
                c.xkb_compose_state_reset(self.impl.xkb_compose_state);
                self.impl.text_input_state = .repeating;
                self.impl.events.put(.{ .text_input_changed = getUtf8FromKeysym(self.impl.text_input_last_keysym) }) catch {
                    log.warn("Event queue full, a text input event missed", .{});
                };
                self.impl.text_input_time = current;
                self.impl.text_input_preedit = .{0} ** 4096;
            }
        },
        .repeating => {
            if (std.time.ms_per_s / self.impl.text_input_rate <= elapsed) {
                self.impl.events.put(.{ .text_input_changed = getUtf8FromKeysym(self.impl.text_input_last_keysym) }) catch {
                    log.warn("Event queue full, a text input event missed", .{});
                };
                self.impl.text_input_time = current;
            }
        },
        .none => {},
    }
}

fn getUtf8FromKeysym(keysym: u32) []const u8 {
    return switch (keysym) {
        c.XKB_KEY_dead_grave => "`",
        c.XKB_KEY_dead_acute => "´",
        c.XKB_KEY_dead_circumflex => "^",
        c.XKB_KEY_dead_tilde => "~",
        c.XKB_KEY_dead_diaeresis => "¨",
        c.XKB_KEY_dead_cedilla => "¸",
        c.XKB_KEY_dead_caron => "ˇ",
        c.XKB_KEY_dead_macron => "¯",
        c.XKB_KEY_dead_breve => "˘",
        c.XKB_KEY_dead_abovering => "˚",
        c.XKB_KEY_dead_doubleacute => "˝",
        else => blk: {
            var tmp: [4096:0]u8 = .{0} ** 4096;
            _ = c.xkb_keysym_to_utf8(keysym, &tmp, tmp.len);
            break :blk std.mem.span(@as([*:0]u8, &tmp));
        },
    };
}

pub fn getTitle(self: *Self) []const u8 {
    return std.mem.span(@as([*:0]u8, &self.impl.title));
}

pub fn setTitle(self: *Self, title: []const u8) void {
    const len = @min(title.len, self.impl.title.len - 1);
    _ = std.fmt.bufPrintSentinel(&self.impl.title, "{s}", .{title[0..len]}, 0) catch unreachable;
    c.xdg_toplevel_set_title(self.impl.xdg_toplevel, &self.impl.title);
}

pub fn setFullscreen(self: *Self) void {
    c.xdg_toplevel_set_fullscreen(self.impl.xdg_toplevel, null);
}

pub fn unsetFullscreen(self: *Self) void {
    c.xdg_toplevel_unset_fullscreen(self.impl.xdg_toplevel);
}

pub fn maximize(self: *Self) void {
    c.xdg_toplevel_set_maximized(self.impl.xdg_toplevel);
}

pub fn restore(self: *Self) void {
    c.xdg_toplevel_unset_maximized(self.impl.xdg_toplevel);
}

pub fn minimize(self: *Self) void {
    c.xdg_toplevel_set_minimized(self.impl.xdg_toplevel);
}

pub fn getMaxSize(self: *Self) Size {
    return .{ .width = self.impl.max_width, .height = self.impl.max_height };
}

pub fn setMaxSize(self: *Self, width: u32, height: u32) void {
    c.xdg_toplevel_set_max_size(self.impl.xdg_toplevel, @intCast(width), @intCast(height));
    self.impl.max_width = width;
    self.impl.max_height = height;
}

pub fn getMinSize(self: *Self) Size {
    return .{ .width = self.impl.min_width, .height = self.impl.min_height };
}

pub fn setMinSize(self: *Self, width: u32, height: u32) void {
    c.xdg_toplevel_set_min_size(self.impl.xdg_toplevel, @intCast(width), @intCast(height));
    self.impl.min_width = width;
    self.impl.min_height = height;
}

pub fn getSize(self: *Self) Size {
    return .{ .width = self.impl.width, .height = self.impl.height };
}

pub fn getBuffer(self: *Self) []u32 {
    return self.impl.buffer.?;
}

pub fn pollEvent(self: *Self) ?Event {
    return self.impl.events.get();
}

pub fn setPointerShape(self: *Self, shape: Shape) void {
    if (self.impl.wp_cursor_shape_device_v1) |wp_cursor_shape_device_v1| {
        self.impl.pointer_shape = shape;
        c.wp_cursor_shape_device_v1_set_shape(
            wp_cursor_shape_device_v1,
            self.impl.pointer_serial,
            @intFromEnum(shape),
        );
    } else {
        log.warn("cursor shape protocol not supported", .{});
    }
}

pub fn buttonIsPressed(self: *Self, button: Button) bool {
    _ = self;
    _ = button;
    log.err("Not Implemented", .{});
    unreachable;
}

pub fn keyIsPressed(self: *Self, key: Key) bool {
    return self.impl.keyboard_state[@intFromEnum(key)];
}

pub fn getModifiers(self: *Self) Modifiers {
    return makeModifiers(self.impl);
}

pub fn textInputEnable(self: *Self) void {
    self.impl.text_input_enabled = true;
}

pub fn textInputDisable(self: *Self) void {
    self.impl.text_input_enabled = false;
}

pub fn textInputSetRect(self: *Self, rect: Rect) void {
    _ = self;
    _ = rect;
    log.err("Not Implemented", .{});
    unreachable;
}

fn wlRegistryGlobal(
    user_data: ?*anyopaque,
    wl_registry: ?*c.wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    _ = version;
    const impl: *Impl = @ptrCast(@alignCast(user_data));
    if (std.mem.eql(u8, std.mem.span(interface), std.mem.span(c.wl_compositor_interface.name))) {
        impl.wl_compositor = @ptrCast(
            @alignCast(c.wl_registry_bind(wl_registry, name, &c.wl_compositor_interface, 6)),
        );
    } else if (std.mem.eql(u8, std.mem.span(interface), std.mem.span(c.xdg_wm_base_interface.name))) {
        impl.xdg_wm_base = @ptrCast(
            @alignCast(c.wl_registry_bind(wl_registry, name, &c.xdg_wm_base_interface, 1)),
        );
    }
    if (std.mem.eql(u8, std.mem.span(interface), std.mem.span(c.wl_shm_interface.name))) {
        impl.wl_shm = @ptrCast(@alignCast(c.wl_registry_bind(wl_registry, name, &c.wl_shm_interface, 1)));
        return;
    }
    if (std.mem.eql(u8, std.mem.span(interface), std.mem.span(c.wl_seat_interface.name))) {
        impl.wl_seat = @ptrCast(@alignCast(c.wl_registry_bind(wl_registry, name, &c.wl_seat_interface, 9)));
        return;
    }
    if (std.mem.eql(u8, std.mem.span(interface), std.mem.span(c.wp_cursor_shape_manager_v1_interface.name))) {
        impl.wp_cursor_shape_manager_v1 = @ptrCast(
            @alignCast(c.wl_registry_bind(wl_registry, name, &c.wp_cursor_shape_manager_v1_interface, 1)),
        );
    }
}

fn wlRegistryGlobalRemove(user_data: ?*anyopaque, wl_registry: ?*c.wl_registry, name: u32) callconv(.c) void {
    _ = user_data;
    _ = wl_registry;
    _ = name;
}

fn xdgWmBasePing(user_data: ?*anyopaque, wm_base: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
    _ = user_data;
    c.xdg_wm_base_pong(wm_base, serial);
}

fn wlSeatCapabilities(user_data: ?*anyopaque, wl_seat: ?*c.wl_seat, capabilities: u32) callconv(.c) void {
    const impl: *Impl = @ptrCast(@alignCast(user_data));
    if (capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD == c.WL_SEAT_CAPABILITY_KEYBOARD) {
        impl.wl_keyboard = c.wl_seat_get_keyboard(wl_seat);
        _ = c.wl_keyboard_add_listener(impl.wl_keyboard, &wl_keyboard_listener, impl);
    }
    if (capabilities & c.WL_SEAT_CAPABILITY_POINTER == c.WL_SEAT_CAPABILITY_POINTER) {
        const wl_pointer = c.wl_seat_get_pointer(wl_seat);
        impl.wl_pointer = wl_pointer;
        _ = c.wl_pointer_add_listener(wl_pointer, &wl_pointer_listener, impl);
        if (impl.wp_cursor_shape_manager_v1) |wp_cursor_shape_manager_v1| {
            const wp_cursor_shape_device_v1 = c.wp_cursor_shape_manager_v1_get_pointer(
                wp_cursor_shape_manager_v1,
                wl_pointer,
            );
            impl.wp_cursor_shape_device_v1 = wp_cursor_shape_device_v1;
        }
    }
}

fn wlSeatName(user_data: ?*anyopaque, wl_seat: ?*c.wl_seat, name: [*c]const u8) callconv(.c) void {
    _ = user_data;
    _ = wl_seat;
    _ = name;
}

fn xdgSurfaceConfigure(user_data: ?*anyopaque, xdg_surface: ?*c.xdg_surface, serial: u32) callconv(.c) void {
    const impl: *Impl = @ptrCast(@alignCast(user_data));
    c.xdg_surface_ack_configure(xdg_surface, serial);
    if (impl.resized) {
        impl.events.put(
            .{ .window_resized = .{
                .width = impl.width,
                .height = impl.height,
            } },
        ) catch {
            log.warn("Event queue full, a resizing event missed", .{});
        };
        impl.resized = false;
        configureWlShmPool(impl);
    }
    drawFrame(impl);
    c.wl_surface_commit(impl.wl_surface);
}

fn drawFrame(impl: *Impl) void {
    impl.wl_buffer = c.wl_shm_pool_create_buffer(
        impl.wl_shm_pool,
        0,
        @intCast(impl.width),
        @intCast(impl.height),
        @intCast(impl.width * 4),
        c.WL_SHM_FORMAT_ARGB8888,
    );
    _ = c.wl_buffer_add_listener(impl.wl_buffer, &wl_buffer_listener, impl);
    c.wl_surface_attach(impl.wl_surface, impl.wl_buffer, 0, 0);
    c.wl_surface_damage(impl.wl_surface, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
}

fn configureWlShmPool(impl: *Impl) void {
    if (impl.buffer) |buffer| {
        _ = std.os.linux.munmap(@ptrCast(buffer.ptr), buffer.len);
    }
    const width: i32, const height: i32 = .{ @intCast(impl.width), @intCast(impl.height) };
    const stride = width * 4;
    const size = stride * height;
    const fd: i32 = @intCast(std.os.linux.memfd_create("/wl_shm", 0));
    defer _ = std.os.linux.close(fd);
    _ = std.os.linux.ftruncate(fd, size);
    const map = std.os.linux.mmap(
        null,
        @intCast(size),
        .{ .READ = true, .WRITE = true },
        std.os.linux.MAP{ .TYPE = .SHARED },
        fd,
        0,
    );
    const len: usize = @intCast(width * height);
    impl.buffer = @as([*]u32, @ptrFromInt(map))[0..len];
    const clear_color: u32 = 0xFF000000;
    @memset(impl.buffer.?, @bitCast(clear_color));
    if (impl.wl_shm_pool) |wl_shm_pool| {
        c.wl_shm_pool_destroy(wl_shm_pool);
    }
    impl.wl_shm_pool = c.wl_shm_create_pool(impl.wl_shm, fd, size);
}

fn xdgToplevelClose(user_data: ?*anyopaque, toplevel: ?*c.xdg_toplevel) callconv(.c) void {
    _ = toplevel;
    const impl: *Impl = @ptrCast(@alignCast(user_data));
    impl.events.put(.{ .window_close_requested = {} }) catch {
        log.warn("Event queue full, event closing missed", .{});
    };
}

fn xdgToplevelConfigure(
    user_data: ?*anyopaque,
    toplevel: ?*c.xdg_toplevel,
    width: i32,
    height: i32,
    states: [*c]c.wl_array,
) callconv(.c) void {
    _ = toplevel;
    _ = states;
    const impl: *Impl = @ptrCast(@alignCast(user_data));
    if ((width != 0 and height != 0) and (impl.width != width or impl.height != height)) {
        impl.resized = true;
        impl.width = @intCast(width);
        impl.height = @intCast(height);
    }
}

fn xdgToplevelConfigureBounds(
    user_data: ?*anyopaque,
    toplevel: ?*c.xdg_toplevel,
    width: i32,
    height: i32,
) callconv(.c) void {
    _ = toplevel;
    _ = user_data;
    _ = width;
    _ = height;
}

fn xdgToplevelWmCapabilities(
    user_data: ?*anyopaque,
    toplevel: ?*c.xdg_toplevel,
    capabilities: [*c]c.wl_array,
) callconv(.c) void {
    _ = toplevel;
    _ = capabilities;
    _ = user_data;
}

fn wlCallbackDone(user_data: ?*anyopaque, wl_callback: ?*c.wl_callback, time: u32) callconv(.c) void {
    _ = time;
    const impl: *Impl = @ptrCast(@alignCast(user_data));
    c.wl_callback_destroy(wl_callback);
    drawFrame(impl);
    const new_wl_callback = c.wl_surface_frame(impl.wl_surface);
    impl.wl_callback = new_wl_callback;
    _ = c.wl_callback_add_listener(new_wl_callback, &wl_callback_listener, impl);
    c.wl_surface_commit(impl.wl_surface);
}

fn wlBufferRelease(user_data: ?*anyopaque, wl_buffer: ?*c.wl_buffer) callconv(.c) void {
    const impl: *Impl = @ptrCast(@alignCast(user_data));
    if (wl_buffer == impl.wl_buffer) {
        impl.wl_buffer = null;
    }
    c.wl_buffer_destroy(wl_buffer);
}

pub fn wlKeyboardEnter(
    user_data: ?*anyopaque,
    wl_keyboard: ?*c.struct_wl_keyboard,
    serial: u32,
    wl_surface: ?*c.struct_wl_surface,
    evdev_keys: ?*c.struct_wl_array,
) callconv(.c) void {
    _ = wl_keyboard;
    _ = serial;
    _ = wl_surface;
    const impl: *Impl = @ptrCast(@alignCast(user_data));
    const arr_evdev_keys = @as([*]u32, @ptrCast(@alignCast(evdev_keys.?.data)))[0..evdev_keys.?.size];
    for (arr_evdev_keys) |evdev_key| {
        const key = evdev_to_key[if (evdev_key < evdev_key_max) evdev_key else 0];
        impl.keyboard_state[@intFromEnum(key)] = true;
        impl.events.put(.{
            .key_down = .{
                .key = key,
                .modifiers = makeModifiers(impl),
                .raw = evdev_key,
            },
        }) catch {
            log.warn("Event queue full, key down event missed", .{});
        };
    }
}

pub fn wlKeyboardLeave(
    user_data: ?*anyopaque,
    wl_keyboard: ?*c.struct_wl_keyboard,
    serial: u32,
    wl_surface: ?*c.struct_wl_surface,
) callconv(.c) void {
    _ = wl_keyboard;
    _ = serial;
    _ = wl_surface;
    const impl: *Impl = @ptrCast(@alignCast(user_data));
    impl.keyboard_state = .{false} ** keyboard_state_len;
}

pub fn wlKeyboardKey(
    user_data: ?*anyopaque,
    wl_keyboard: ?*c.struct_wl_keyboard,
    serial: u32,
    time: u32,
    evdev_key: u32,
    state: u32,
) callconv(.c) void {
    _ = wl_keyboard;
    _ = serial;
    _ = time;
    const impl: *Impl = @ptrCast(@alignCast(user_data));
    const modifiers = makeModifiers(impl);
    const key = evdev_to_key[evdev_key];
    switch (state) {
        c.WL_KEYBOARD_KEY_STATE_PRESSED => {
            _ = c.xkb_state_update_key(impl.xkb_state, evdev_key + 8, c.XKB_KEY_DOWN);
            impl.events.put(.{
                .key_down = .{
                    .key = key,
                    .modifiers = modifiers,
                    .raw = evdev_key,
                },
            }) catch {
                log.warn("Event Queue is full, key down event missed", .{});
            };
            impl.keyboard_state[@intFromEnum(key)] = true;
        },
        c.WL_KEYBOARD_KEY_STATE_RELEASED => {
            _ = c.xkb_state_update_key(impl.xkb_state, evdev_key + 8, c.XKB_KEY_UP);
            impl.events.put(.{
                .key_up = .{
                    .key = key,
                    .modifiers = modifiers,
                    .raw = evdev_key,
                },
            }) catch {
                log.warn("Event Queue is full, key up event missed", .{});
            };
            impl.keyboard_state[@intFromEnum(key)] = false;
        },
        else => {},
    }
    if (!impl.text_input_enabled) return;
    switch (state) {
        c.WL_KEYBOARD_KEY_STATE_PRESSED => {
            _ = c.xkb_state_update_key(impl.xkb_state, evdev_key + 8, c.XKB_KEY_DOWN);
            const keysym = c.xkb_state_key_get_one_sym(impl.xkb_state, evdev_key + 8);
            const result = c.xkb_compose_state_feed(impl.xkb_compose_state, keysym);
            if (result == 0) return;
            var tmp: [4096:0]u8 = .{0} ** 4096;
            switch (c.xkb_compose_state_get_status(impl.xkb_compose_state)) {
                c.XKB_COMPOSE_COMPOSED => {
                    if (c.xkb_compose_state_get_utf8(impl.xkb_compose_state, &tmp, tmp.len) > 0) {
                        impl.text_input_last_keysym = keysym;
                        impl.text_input_state = .pressed;
                        impl.events.put(.{ .text_input_changed = std.mem.span(@as([*:0]u8, &tmp)) }) catch {
                            log.warn("Event queue full, a text input event missed", .{});
                        };
                    }
                    impl.text_input_preedit = .{0} ** 4096;
                },
                c.XKB_COMPOSE_NOTHING => {
                    if (c.xkb_state_key_get_utf8(impl.xkb_state, evdev_key + 8, &tmp, tmp.len) > 0) {
                        impl.text_input_last_keysym = keysym;
                        impl.text_input_state = .pressed;
                        impl.events.put(.{ .text_input_changed = std.mem.span(@as([*:0]u8, &tmp)) }) catch {
                            log.warn("Event queue full, a text input event missed", .{});
                        };
                    }
                },
                c.XKB_COMPOSE_COMPOSING => {
                    impl.text_input_last_keysym = keysym;
                    impl.text_input_state = .pressed;
                    const current = std.mem.span(@as([*:0]u8, &impl.text_input_preedit));
                    const preedit = std.fmt.bufPrintSentinel(&tmp, "{s}{s}", .{ current, getUtf8FromKeysym(keysym) }, 0) catch "";
                    impl.text_input_preedit = tmp;
                    impl.events.put(.{ .text_input_preedit_changed = preedit }) catch {
                        log.warn("Event queue full, a text input event missed", .{});
                    };
                },
                c.XKB_COMPOSE_CANCELLED => {
                    impl.text_input_preedit = .{0} ** 4096;
                    impl.events.put(.{ .text_input_preedit_changed = "" }) catch {
                        log.warn("Event queue full, a text input event missed", .{});
                    };
                },
                else => {},
            }
        },
        c.WL_KEYBOARD_KEY_STATE_RELEASED => {
            _ = c.xkb_state_update_key(impl.xkb_state, evdev_key + 8, c.XKB_KEY_UP);
            impl.text_input_state = .none;
        },
        else => {},
    }
}

fn makeModifiers(impl: *Impl) Modifiers {
    return .{
        .caps_lock = c.xkb_state_mod_name_is_active(
            impl.xkb_state,
            c.XKB_MOD_NAME_CAPS,
            c.XKB_STATE_MODS_LOCKED,
        ) != 0,
        .num_lock = c.xkb_state_mod_name_is_active(
            impl.xkb_state,
            c.XKB_MOD_NAME_NUM,
            c.XKB_STATE_MODS_LOCKED,
        ) != 0,
        .shift = c.xkb_state_mod_name_is_active(
            impl.xkb_state,
            c.XKB_MOD_NAME_SHIFT,
            c.XKB_STATE_MODS_EFFECTIVE,
        ) != 0,
        .control = c.xkb_state_mod_name_is_active(
            impl.xkb_state,
            c.XKB_MOD_NAME_CTRL,
            c.XKB_STATE_MODS_EFFECTIVE,
        ) != 0,
        .alt = c.xkb_state_mod_name_is_active(
            impl.xkb_state,
            c.XKB_MOD_NAME_ALT,
            c.XKB_STATE_MODS_EFFECTIVE,
        ) != 0,
        .super = c.xkb_state_mod_name_is_active(
            impl.xkb_state,
            c.XKB_MOD_NAME_LOGO,
            c.XKB_STATE_MODS_EFFECTIVE,
        ) != 0,
    };
}

pub fn wlKeyboardModifiers(
    user_data: ?*anyopaque,
    keyboard: ?*c.struct_wl_keyboard,
    serial: u32,
    mods_depressed: u32,
    mods_latched: u32,
    mods_locked: u32,
    group: u32,
) callconv(.c) void {
    _ = serial;
    _ = keyboard;
    const impl: *Impl = @ptrCast(@alignCast(user_data));
    _ = c.xkb_state_update_mask(impl.xkb_state, mods_depressed, mods_latched, mods_locked, 0, 0, group);
}

pub fn wlKeyboardKeymap(
    user_data: ?*anyopaque,
    keyboard: ?*c.wl_keyboard,
    format: u32,
    fd: i32,
    size: u32,
) callconv(.c) void {
    _ = keyboard;
    _ = format;
    const impl: *Impl = @ptrCast(@alignCast(user_data.?));
    const map_shm: [*:0]u8 = @ptrFromInt(
        std.os.linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0),
    );
    defer _ = std.os.linux.munmap(map_shm, size);
    defer _ = std.os.linux.close(fd);
    if (impl.xkb_keymap) |xkb_keymap| {
        c.xkb_keymap_unref(xkb_keymap);
    }
    const xkb_keymap = c.xkb_keymap_new_from_string(
        impl.xkb_context,
        map_shm,
        c.XKB_KEYMAP_FORMAT_TEXT_V1,
        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
    );
    impl.xkb_keymap = xkb_keymap;

    if (impl.xkb_state) |xkb_state| {
        c.xkb_state_unref(xkb_state);
    }
    const xkb_state = c.xkb_state_new(xkb_keymap).?;
    impl.xkb_state = xkb_state;
}

fn wlKeyboardRepeatInfo(
    user_data: ?*anyopaque,
    wl_keyboard: ?*c.struct_wl_keyboard,
    rate: i32,
    delay: i32,
) callconv(.c) void {
    _ = wl_keyboard;
    const impl: *Impl = @ptrCast(@alignCast(user_data.?));
    impl.text_input_rate = @intCast(rate);
    impl.text_input_delay = @intCast(delay);
}

fn wlPointerEnter(
    data: ?*anyopaque,
    wl_pointer: ?*c.wl_pointer,
    serial: u32,
    wl_surface: ?*c.wl_surface,
    surface_x: i32,
    surface_y: i32,
) callconv(.c) void {
    _ = wl_pointer;
    _ = wl_surface;
    const impl: *Impl = @ptrCast(@alignCast(data));
    impl.pointer_serial = serial;
    impl.pointer_position_changed = true;
    impl.pointer_position_x = @intCast(c.wl_fixed_to_int(surface_x));
    impl.pointer_position_y = @intCast(c.wl_fixed_to_int(surface_y));

    if (impl.wp_cursor_shape_device_v1) |wp_cursor_shape_device_v1| {
        c.wp_cursor_shape_device_v1_set_shape(
            wp_cursor_shape_device_v1,
            serial,
            @intFromEnum(impl.pointer_shape),
        );
    }
}

fn wlPointerLeave(
    data: ?*anyopaque,
    wl_pointer: ?*c.wl_pointer,
    serial: u32,
    wl_surface: ?*c.wl_surface,
) callconv(.c) void {
    _ = data;
    _ = wl_pointer;
    _ = serial;
    _ = wl_surface;
}

fn wlPointerMotion(
    data: ?*anyopaque,
    wl_pointer: ?*c.wl_pointer,
    serial: u32,
    surface_x: i32,
    surface_y: i32,
) callconv(.c) void {
    _ = wl_pointer;
    _ = serial;
    const impl: *Impl = @ptrCast(@alignCast(data));
    impl.pointer_position_changed = true;
    impl.pointer_position_x = @intCast(c.wl_fixed_to_int(surface_x));
    impl.pointer_position_y = @intCast(c.wl_fixed_to_int(surface_y));
}

fn wlPointerButton(
    data: ?*anyopaque,
    wl_pointer: ?*c.wl_pointer,
    serial: u32,
    time: u32,
    button: u32,
    state: u32,
) callconv(.c) void {
    _ = serial;
    _ = time;
    _ = wl_pointer;
    const impl: *Impl = @ptrCast(@alignCast(data));
    const mapped_button: Button = switch (button) {
        c.BTN_LEFT => .left,
        c.BTN_RIGHT => .right,
        c.BTN_MIDDLE => .middle,
        c.BTN_SIDE => .side,
        c.BTN_EXTRA => .extra,
        c.BTN_FORWARD => .forward,
        c.BTN_BACK => .back,
        c.BTN_TASK => .task,
        else => unreachable,
    };
    if (state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
        impl.pointer_state[@intFromEnum(mapped_button)] = true;
        impl.events.put(.{ .pointer_button_down = .{
            .button = mapped_button,
            .raw = button,
        } }) catch {
            std.log.warn("event queue full, a pointer button down event missed", .{});
        };
        return;
    }
    impl.pointer_state[@intFromEnum(mapped_button)] = false;
    impl.events.put(.{ .pointer_button_up = .{
        .button = mapped_button,
        .raw = button,
    } }) catch {
        std.log.warn("event queue full, a pointer button up event missed", .{});
    };
}

fn wlPointerAxis(
    data: ?*anyopaque,
    wl_pointer: ?*c.wl_pointer,
    time: u32,
    axis: u32,
    value: i32,
) callconv(.c) void {
    _ = data;
    _ = wl_pointer;
    _ = time;
    _ = axis;
    _ = value;
}

fn wlPointerFrame(data: ?*anyopaque, wl_pointer: ?*c.wl_pointer) callconv(.c) void {
    _ = wl_pointer;
    const impl: *Impl = @ptrCast(@alignCast(data));
    if (impl.pointer_position_changed) {
        impl.events.put(.{ .pointer_motion = .{
            .x = impl.pointer_position_x,
            .y = impl.pointer_position_y,
        } }) catch {
            std.log.warn("event queue full, a pointer moved event missed", .{});
        };
        impl.pointer_position_changed = false;
    }
    if (impl.pointer_axis_changed) {
        impl.events.put(.{ .pointer_wheel = .{
            .x = impl.pointer_axis_x / 120,
            .y = impl.pointer_axis_y / 120,
        } }) catch {
            std.log.warn("event queue full, a pointer wheel event missed", .{});
        };
        impl.pointer_axis_x = 0;
        impl.pointer_axis_y = 0;
        impl.pointer_axis_changed = false;
    }
}

fn wlPointerAxisSource(data: ?*anyopaque, wl_pointer: ?*c.wl_pointer, axis_source: u32) callconv(.c) void {
    _ = data;
    _ = wl_pointer;
    _ = axis_source;
}

fn wlPointerAxisStop(data: ?*anyopaque, wl_pointer: ?*c.wl_pointer, time: u32, axis: u32) callconv(.c) void {
    _ = data;
    _ = wl_pointer;
    _ = time;
    _ = axis;
}

fn wlPointerAxisDiscrete(
    data: ?*anyopaque,
    wl_pointer: ?*c.wl_pointer,
    axis: u32,
    discrete: i32,
) callconv(.c) void {
    _ = data;
    _ = wl_pointer;
    _ = axis;
    _ = discrete;
}

fn wlPointerAxisValue120(
    data: ?*anyopaque,
    wl_pointer: ?*c.wl_pointer,
    axis: u32,
    value120: i32,
) callconv(.c) void {
    _ = wl_pointer;
    const impl: *Impl = @ptrCast(@alignCast(data));
    impl.pointer_axis_changed = true;
    if (axis == c.WL_POINTER_AXIS_VERTICAL_SCROLL) {
        impl.pointer_axis_y += @floatFromInt(value120);
        return;
    }
    impl.pointer_axis_x += @floatFromInt(value120);
}

fn wlPointerAxisRelativeDirection(
    data: ?*anyopaque,
    wl_pointer: ?*c.wl_pointer,
    axis: u32,
    direction: u32,
) callconv(.c) void {
    _ = data;
    _ = wl_pointer;
    _ = axis;
    _ = direction;
}

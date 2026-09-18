const std = @import("std");
const c = @import("c");

const Size = @import("common.zig").Size;
const Shape = @import("common.zig").Shape;
const Button = @import("common.zig").Button;
const Key = @import("common.zig").Key;
const Modifiers = @import("common.zig").Modifiers;
const Event = @import("common.zig").Event;
const Queue = @import("../core/queue.zig").Queue;
const DateTime = @import("../core/DateTime.zig").DateTime;
const FdListenerCallback = @import("common.zig").FdListenerCallback;

const log = std.log.scoped(.wayland);

const Self = @This();

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
    var table: [evdev_key_max]Key = [_]Key{.unknown} ** evdev_key_max;
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

const buffers_len = 2;
const keyboard_self_len = @typeInfo(Key).@"enum".fields.len;
const pointer_self_len = @typeInfo(Button).@"enum".fields.len;
const text_input_buf_len = 64;

const Buffer = struct {
    wl_buffer: ?*c.wl_buffer = null,
    pixels: []u32 = undefined,
    busy: bool = true,
};

wl_display: ?*c.wl_display = null,
wl_registry: ?*c.wl_registry = null,
wl_compositor: ?*c.wl_compositor = null,
wl_surface: ?*c.wl_surface = null,
wl_seat: ?*c.wl_seat = null,
wl_shm: ?*c.wl_shm = null,
wl_shm_pool: ?*c.wl_shm_pool = null,
wl_shm_pool_size: u32 = 0,
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

zxdg_decoration_manager_v1: ?*c.zxdg_decoration_manager_v1 = null,
zxdg_toplevel_decoration_v1: ?*c.zxdg_toplevel_decoration_v1 = null,

wp_tearing_control_manager_v1: ?*c.wp_tearing_control_manager_v1 = null,
wp_tearing_control_v1: ?*c.wp_tearing_control_v1 = null,

events: Queue(Event, 256) = .empty,
clk_id: std.os.linux.clockid_t = @enumFromInt(0),
next_refresh: u64 = 0,
resize_pending: bool = false,
title: [4096:0]u8 = .{0} ** 4096,
width: u32 = 200,
height: u32 = 200,
buffers: [buffers_len]Buffer = [_]Buffer{.{}} ** buffers_len,
pending_present: ?*Buffer = null,
min_width: u32 = 0,
min_height: u32 = 0,
max_width: u32 = 0,
max_height: u32 = 0,
pixels: ?[]u32 = null,
epoll_fd: std.os.linux.fd_t = -1,
fd_map: std.AutoHashMap(i32, struct { callback: FdListenerCallback, user_data: ?*anyopaque }) = undefined,

pointer_shape: Shape = .default,
pointer_self: [pointer_self_len]bool = .{false} ** pointer_self_len,
pointer_serial: u32 = 0,
pointer_position_changed: bool = false,
pointer_position_x: i32 = 0,
pointer_position_y: i32 = 0,
pointer_axis_changed: bool = false,
pointer_axis_x: f32 = 0,
pointer_axis_y: f32 = 0,

keyboard_self: [keyboard_self_len]bool = .{false} ** keyboard_self_len,
keyboard_last_key: u32 = 0,
keyboard_repeat_mode: bool = false,
keyboard_repeat_rate: u32 = 0,
keyboard_repeat_delay: u32 = 0,
text_input_enabled: bool = false,
text_input_buf: [text_input_buf_len:0]u8 = .{0} ** text_input_buf_len,
text_input_timer_fd: std.os.linux.fd_t = -1,

pub fn init(self: *Self, allocator: std.mem.Allocator) void {
    self.* = .{};
    self.wl_display = c.wl_display_connect(null);
    self.wl_registry = c.wl_display_get_registry(self.wl_display);
    _ = c.wl_registry_add_listener(self.wl_registry, &wl_registry_listener, self);
    _ = c.wl_display_roundtrip(self.wl_display);

    _ = c.xdg_wm_base_add_listener(self.xdg_wm_base, &xdg_wm_base_listener, self);
    _ = c.wl_seat_add_listener(self.wl_seat, &wl_seat_listener, self);

    self.wl_surface = c.wl_compositor_create_surface(self.wl_compositor);
    self.xdg_surface = c.xdg_wm_base_get_xdg_surface(self.xdg_wm_base, self.wl_surface);
    self.xdg_toplevel = c.xdg_surface_get_toplevel(self.xdg_surface);

    if (self.zxdg_decoration_manager_v1) |zxdg_decoration_manager_v1| {
        self.zxdg_toplevel_decoration_v1 = c.zxdg_decoration_manager_v1_get_toplevel_decoration(
            zxdg_decoration_manager_v1,
            self.xdg_toplevel,
        );
    } else {
        log.warn("xdg toplevel decoration protocol not supported", .{});
    }

    if (self.wp_tearing_control_manager_v1) |wp_tearing_control_manager_v1| {
        self.wp_tearing_control_v1 = c.wp_tearing_control_manager_v1_get_tearing_control(
            wp_tearing_control_manager_v1,
            self.wl_surface,
        );
    }

    _ = c.xdg_surface_add_listener(self.xdg_surface, &xdg_surface_listener, self);
    _ = c.xdg_toplevel_add_listener(self.xdg_toplevel, &xdg_toplevel_listener, self);

    self.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
    const locale = std.c.setlocale(.ALL, null) orelse std.c.setlocale(.CTYPE, null) orelse "C";
    self.xkb_compose_table = c.xkb_compose_table_new_from_locale(
        self.xkb_context,
        locale,
        c.XKB_COMPOSE_COMPILE_NO_FLAGS,
    );
    self.xkb_compose_state = c.xkb_compose_state_new(
        self.xkb_compose_table,
        c.XKB_COMPOSE_STATE_NO_FLAGS,
    );

    const epoll_fd = std.os.linux.epoll_create1(0);
    std.debug.assert(epoll_fd != -1);
    self.epoll_fd = @intCast(epoll_fd);

    const wayland_fd = c.wl_display_get_fd(self.wl_display);
    var wayland_event: std.os.linux.epoll_event = .{
        .data = .{
            .fd = wayland_fd,
        },
        .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ERR | std.os.linux.EPOLL.HUP,
    };
    var ok = std.os.linux.epoll_ctl(@intCast(epoll_fd), std.os.linux.EPOLL.CTL_ADD, wayland_fd, &wayland_event);
    std.debug.assert(ok == 0);

    const text_input_timer_fd = std.os.linux.timerfd_create(
        std.os.linux.timerfd_clockid_t.MONOTONIC,
        std.os.linux.TFD{ .NONBLOCK = true },
    );
    std.debug.assert(text_input_timer_fd != -1);
    var text_input_timer_event: std.os.linux.epoll_event = .{
        .data = .{
            .fd = @intCast(text_input_timer_fd),
        },
        .events = std.os.linux.EPOLL.IN,
    };
    ok = std.os.linux.epoll_ctl(
        @intCast(epoll_fd),
        std.os.linux.EPOLL.CTL_ADD,
        @intCast(text_input_timer_fd),
        &text_input_timer_event,
    );
    std.debug.assert(ok == 0);
    self.text_input_timer_fd = @intCast(text_input_timer_fd);

    self.fd_map = .init(allocator);

    c.wl_surface_commit(self.wl_surface);
}

pub fn deinit(self: *Self) void {
    for (&self.buffers) |*buffer| {
        cleanup(c.wl_buffer_destroy, &buffer.wl_buffer, .{});
    }

    self.fd_map.deinit();

    cleanup(c.wl_shm_pool_destroy, &self.wl_shm_pool, .{});
    cleanup(c.wl_keyboard_destroy, &self.wl_keyboard, .{});
    cleanup(c.wl_pointer_destroy, &self.wl_pointer, .{});

    cleanup(c.zxdg_decoration_manager_v1_destroy, &self.zxdg_decoration_manager_v1, .{});
    cleanup(c.zxdg_toplevel_decoration_v1_destroy, &self.zxdg_toplevel_decoration_v1, .{});

    cleanup(c.wp_cursor_shape_manager_v1_destroy, &self.wp_cursor_shape_manager_v1, .{});
    cleanup(c.wp_cursor_shape_device_v1_destroy, &self.wp_cursor_shape_device_v1, .{});

    cleanup(c.xkb_keymap_unref, &self.xkb_keymap, .{});
    cleanup(c.xkb_state_unref, &self.xkb_state, .{});
    cleanup(c.xkb_context_unref, &self.xkb_context, .{});
    cleanup(c.xkb_compose_table_unref, &self.xkb_compose_table, .{});
    cleanup(c.xkb_compose_state_unref, &self.xkb_compose_state, .{});

    cleanup(c.xdg_toplevel_destroy, &self.xdg_toplevel, .{});
    cleanup(c.xdg_surface_destroy, &self.xdg_surface, .{});
    cleanup(c.xdg_wm_base_destroy, &self.xdg_wm_base, .{});

    cleanup(c.wl_surface_destroy, &self.wl_surface, .{});
    cleanup(c.wl_seat_destroy, &self.wl_seat, .{});
    cleanup(c.wl_shm_destroy, &self.wl_shm, .{});
    cleanup(c.wl_compositor_destroy, &self.wl_compositor, .{});
    cleanup(c.wl_registry_destroy, &self.wl_registry, .{});
    cleanup(c.wl_display_disconnect, &self.wl_display, .{});
}

fn cleanup(cleanupFn: anytype, ptr_to_opt_ptr: anytype, extra_args: anytype) void {
    if (ptr_to_opt_ptr.*) |ptr| {
        @call(.auto, cleanupFn, .{ptr} ++ extra_args);
        ptr_to_opt_ptr.* = null;
    }
}

const wl_callback_listener = c.wl_callback_listener{
    .done = wlCallbackDone,
};

fn wlCallbackDone(user_data: ?*anyopaque, wl_callback: ?*c.wl_callback, callback_data: u32) callconv(.c) void {
    _ = callback_data;
    const self: *Self = @ptrCast(@alignCast(user_data));

    self.events.put(.{ .frame = {} }) catch {
        log.warn("Event queue full, a frame discarted event missed", .{});
    };

    c.wl_callback_destroy(wl_callback);
}

pub fn present(self: *Self) void {
    if (self.pending_present) |buffer| {
        const callback = c.wl_surface_frame(self.wl_surface);
        _ = c.wl_callback_add_listener(callback, &wl_callback_listener, self);

        c.wl_surface_attach(self.wl_surface, buffer.wl_buffer, 0, 0);
        c.wl_surface_damage(self.wl_surface, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
        c.wl_surface_commit(self.wl_surface);

        buffer.busy = true;
        self.pending_present = null;
    }
}

fn getUtf8FromKeysym(buf: [:0]u8, keysym: u32) []const u8 {
    const result = switch (keysym) {
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
        else => {
            _ = c.xkb_keysym_to_utf8(keysym, buf.ptr, buf.len);
            return std.mem.sliceTo(buf, 0);
        },
    };
    _ = std.fmt.bufPrintSentinel(buf, "{s}", .{result}, 0) catch 0;
    return result;
}

pub fn getTitle(self: *Self) []const u8 {
    return std.mem.span(@as([*:0]u8, &self.title));
}

pub fn setTitle(self: *Self, title: []const u8) void {
    const len = @min(title.len, self.title.len - 1);
    _ = std.fmt.bufPrintSentinel(&self.title, "{s}", .{title[0..len]}, 0) catch unreachable;
    c.xdg_toplevel_set_title(self.xdg_toplevel, &self.title);
}

pub fn setFullscreen(self: *Self) void {
    c.xdg_toplevel_set_fullscreen(self.xdg_toplevel, null);
}

pub fn unsetFullscreen(self: *Self) void {
    c.xdg_toplevel_unset_fullscreen(self.xdg_toplevel);
}

pub fn setVsync(self: *Self) void {
    if (self.wp_tearing_control_v1) |wp_tearing_control_v1| {
        c.wp_tearing_control_v1_set_presentation_hint(
            wp_tearing_control_v1,
            c.WP_TEARING_CONTROL_V1_PRESENTATION_HINT_VSYNC,
        );
        c.wl_surface_commit(self.wl_surface);
    } else {
        log.warn("tearing control v1 protocol not supported", .{});
    }
}

pub fn unsetVsync(self: *Self) void {
    if (self.wp_tearing_control_v1) |wp_tearing_control_v1| {
        c.wp_tearing_control_v1_set_presentation_hint(
            wp_tearing_control_v1,
            c.WP_TEARING_CONTROL_V1_PRESENTATION_HINT_ASYNC,
        );
        c.wl_surface_commit(self.wl_surface);
    } else {
        log.warn("tearing control v1 protocol not supported", .{});
    }
}

pub fn setBorderless(self: *Self) void {
    if (self.zxdg_toplevel_decoration_v1) |zxdg_toplevel_decoration_v1| {
        c.zxdg_toplevel_decoration_v1_set_mode(
            zxdg_toplevel_decoration_v1,
            c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE,
        );
    } else {
        log.warn("xdg toplevel decoration protocol not supported", .{});
    }
}

pub fn unsetBorderless(self: *Self) void {
    if (self.zxdg_toplevel_decoration_v1) |zxdg_toplevel_decoration_v1| {
        c.zxdg_toplevel_decoration_v1_set_mode(
            zxdg_toplevel_decoration_v1,
            c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE,
        );
    } else {
        log.warn("xdg toplevel decoration protocol not supported", .{});
    }
}

pub fn maximize(self: *Self) void {
    c.xdg_toplevel_set_maximized(self.xdg_toplevel);
}

pub fn restore(self: *Self) void {
    c.xdg_toplevel_unset_maximized(self.xdg_toplevel);
}

pub fn minimize(self: *Self) void {
    c.xdg_toplevel_set_minimized(self.xdg_toplevel);
}

pub fn getMaxSize(self: *Self) Size {
    return .{ .width = self.max_width, .height = self.max_height };
}

pub fn setMaxSize(self: *Self, width: u32, height: u32) void {
    c.xdg_toplevel_set_max_size(self.xdg_toplevel, @intCast(width), @intCast(height));
    self.max_width = width;
    self.max_height = height;
}

pub fn getMinSize(self: *Self) Size {
    return .{ .width = self.min_width, .height = self.min_height };
}

pub fn setMinSize(self: *Self, width: u32, height: u32) void {
    c.xdg_toplevel_set_min_size(self.xdg_toplevel, @intCast(width), @intCast(height));
    self.min_width = width;
    self.min_height = height;
}

pub fn getSize(self: *Self) Size {
    return .{ .width = self.width, .height = self.height };
}

pub fn getBuffer(self: *Self) ?[]u32 {
    for (&self.buffers) |*buffer| {
        if (!buffer.busy) {
            self.pending_present = buffer;
            return buffer.pixels;
        }
    }
    return null;
}

pub fn pumpEvents(self: *Self) void {
    self.events.clear();

    const wayland_fd = c.wl_display_get_fd(self.wl_display);
    const events_capacity = 32;
    var wayland_readable: bool = false;
    var events: [events_capacity]std.os.linux.epoll_event = undefined;

    _ = c.wl_display_dispatch_pending(self.wl_display);
    while (c.wl_display_prepare_read(self.wl_display) != 0) {
        _ = c.wl_display_dispatch_pending(self.wl_display);
    }
    _ = c.wl_display_flush(self.wl_display);

    const events_len = std.os.linux.epoll_wait(self.epoll_fd, &events, events_capacity, -1);
    for (events[0..events_len]) |event| {
        if (event.data.fd == wayland_fd) {
            wayland_readable = true;
        } else if (event.data.fd == self.text_input_timer_fd) {
            var expirations: u64 = undefined;
            _ = std.os.linux.read(self.text_input_timer_fd, std.mem.asBytes(&expirations), @sizeOf(u64));
            self.events.put(.{ .keyboard_key_down = .{
                .key = evdev_to_key[self.keyboard_last_key],
                .modifiers = self.getKeyboardModifiers(),
                .raw = self.keyboard_last_key,
                .repeat = true,
            } }) catch log.warn("Event queue full, a key down event missed", .{});
            if (self.text_input_enabled and self.text_input_buf[0] != 0) {
                self.events.put(.{
                    .text_input_changed = std.mem.sliceTo(&self.text_input_buf, 0),
                }) catch {
                    log.warn("Event queue full, a text input event missed", .{});
                };
            }
            c.xkb_compose_state_reset(self.xkb_compose_state);
        } else {
            var event_type: Event.Fd.Type = undefined;
            if (event.events & std.os.linux.EPOLL.IN == std.os.linux.EPOLL.IN) {
                event_type = .in;
            } else if (event.events & std.os.linux.EPOLL.OUT == std.os.linux.EPOLL.OUT) {
                event_type = .out;
            } else if (event.events & std.os.linux.EPOLL.ERR == std.os.linux.EPOLL.ERR) {
                event_type = .err;
            } else if (event.events & std.os.linux.EPOLL.HUP == std.os.linux.EPOLL.HUP) {
                event_type = .hup;
            }
            self.events.put(.{ .fd = .{
                .fd = @intCast(event.data.fd),
                .type = event_type,
            } }) catch {
                log.warn("Event queue full, a fd event missed", .{});
            };
            if (self.fd_map.get(event.data.fd)) |entry| {
                entry.callback(entry.user_data, event_type);
            }
        }
    }

    if (wayland_readable) {
        // var t_spec: std.os.linux.timespec = undefined;
        // const err = std.os.linux.errno(std.os.linux.clock_gettime(self.clk_id, &t_spec));
        // std.debug.assert(err == .SUCCESS);
        // const nsecs = std.time.ns_per_s * t_spec.sec + t_spec.nsec;
        // if (nsecs >= self.next_refresh) {
        //     self.events.put(.{ .frame = {} }) catch {
        //         log.warn("Event queue full, a frame discarted event missed", .{});
        //     };
        // }
        _ = c.wl_display_read_events(self.wl_display);
        _ = c.wl_display_dispatch_pending(self.wl_display);
    } else {
        _ = c.wl_display_cancel_read(self.wl_display);
    }
}

pub fn pollEvent(self: *Self) ?Event {
    return self.events.take();
}

pub const FdEventsFlags = packed struct {
    in: bool = false,
    out: bool = false,
    err: bool = false,
    hup: bool = false,
};

pub fn addFdListener(
    self: *Self,
    fd: i32,
    events: FdEventsFlags,
    callback: ?FdListenerCallback,
    user_data: ?*anyopaque,
) error{ InvalidFd, AlreadyRegistered, OutOfMemory }!void {
    var flags: u32 = 0;
    if (events.in) flags |= std.os.linux.EPOLL.IN;
    if (events.out) flags |= std.os.linux.EPOLL.OUT;
    if (events.err) flags |= std.os.linux.EPOLL.ERR;
    if (events.hup) flags |= std.os.linux.EPOLL.HUP;

    var event: std.os.linux.epoll_event = .{
        .data = .{ .fd = fd },
        .events = flags,
    };

    const ok = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, &event);
    switch (std.os.linux.errno(ok)) {
        .SUCCESS => {},
        .EXIST => return error.AlreadyRegistered,
        else => return error.InvalidFd,
    }

    if (callback) |cb| {
        try self.fd_map.put(fd, .{ .callback = cb, .user_data = user_data });
    }
}

pub fn modifyFdListener(self: *Self, fd: i32, events: FdEventsFlags) error{ InvalidFd, NotRegistered }!void {
    var flags: u32 = 0;
    if (events.in) flags |= std.os.linux.EPOLL.IN;
    if (events.out) flags |= std.os.linux.EPOLL.OUT;
    if (events.err) flags |= std.os.linux.EPOLL.ERR;
    if (events.hup) flags |= std.os.linux.EPOLL.HUP;

    var event: std.os.linux.epoll_event = .{
        .data = .{ .fd = fd },
        .events = flags,
    };

    const ok = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_MOD, fd, &event);
    switch (std.os.linux.errno(ok)) {
        .SUCCESS => {},
        .NOENT => return error.NotRegistered,
        else => return error.InvalidFd,
    }
}

pub fn removeFdListener(self: *Self, fd: i32) error{ InvalidFd, NotRegistered }!void {
    const ok = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, fd, null);
    switch (std.os.linux.errno(ok)) {
        .SUCCESS => {},
        .NOENT => return error.NotRegistered,
        else => return error.InvalidFd,
    }

    _ = self.fd_map.remove(fd);
}

pub fn setPointerShape(self: *Self, shape: Shape) void {
    if (self.wp_cursor_shape_device_v1) |wp_cursor_shape_device_v1| {
        self.pointer_shape = shape;
        c.wp_cursor_shape_device_v1_set_shape(
            wp_cursor_shape_device_v1,
            self.pointer_serial,
            @intFromEnum(shape),
        );
    } else {
        log.warn("cursor shape protocol not supported", .{});
    }
}

pub fn buttonIsPressed(self: *Self, button: Button) bool {
    return self.pointer_self[@intFromEnum(button)];
}

pub fn keyIsPressed(self: *Self, key: Key) bool {
    return self.keyboard_self[@intFromEnum(key)];
}

pub fn enableKeyboardRepeat(self: *Self) void {
    self.keyboard_repeat_mode = true;
}

pub fn disableKeyboardRepeat(self: *Self) void {
    self.keyboard_repeat_mode = false;
}

pub fn setKeyboardRepeatRateAndDelay(self: *Self, rate: u32, delay: u32) void {
    self.keyboard_repeat_rate = rate;
    self.keyboard_repeat_delay = delay;
}

pub fn getKeyboardModifiers(self: *Self) Modifiers {
    return makeModifiers(self);
}

pub fn enableTextInput(self: *Self) void {
    self.text_input_enabled = true;
}

pub fn disableTextInput(self: *Self) void {
    self.text_input_enabled = false;
}

fn wlRegistryGlobal(
    user_data: ?*anyopaque,
    wl_registry: ?*c.wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    _ = version;
    const self: *Self = @ptrCast(@alignCast(user_data));
    var logging: bool = false;
    if (std.mem.eql(u8, std.mem.span(interface), std.mem.span(c.wl_compositor_interface.name))) {
        self.wl_compositor = @ptrCast(
            @alignCast(c.wl_registry_bind(wl_registry, name, &c.wl_compositor_interface, 6)),
        );
        logging = true;
    } else if (std.mem.eql(u8, std.mem.span(interface), std.mem.span(c.xdg_wm_base_interface.name))) {
        self.xdg_wm_base = @ptrCast(
            @alignCast(c.wl_registry_bind(wl_registry, name, &c.xdg_wm_base_interface, 1)),
        );
        logging = true;
    } else if (std.mem.eql(u8, std.mem.span(interface), std.mem.span(c.wl_shm_interface.name))) {
        self.wl_shm = @ptrCast(@alignCast(c.wl_registry_bind(wl_registry, name, &c.wl_shm_interface, 1)));
        logging = true;
    } else if (std.mem.eql(u8, std.mem.span(interface), std.mem.span(c.wl_seat_interface.name))) {
        self.wl_seat = @ptrCast(@alignCast(c.wl_registry_bind(wl_registry, name, &c.wl_seat_interface, 9)));
        logging = true;
    } else if (std.mem.eql(u8, std.mem.span(interface), std.mem.span(c.wp_cursor_shape_manager_v1_interface.name))) {
        self.wp_cursor_shape_manager_v1 = @ptrCast(@alignCast(
            c.wl_registry_bind(wl_registry, name, &c.wp_cursor_shape_manager_v1_interface, 1),
        ));
        logging = true;
    } else if (std.mem.eql(u8, std.mem.span(interface), std.mem.span(c.zxdg_decoration_manager_v1_interface.name))) {
        self.zxdg_decoration_manager_v1 = @ptrCast(@alignCast(
            c.wl_registry_bind(wl_registry, name, &c.zxdg_decoration_manager_v1_interface, 1),
        ));
        logging = true;
    } else if (std.mem.eql(u8, std.mem.span(interface), std.mem.span(c.wp_tearing_control_manager_v1_interface.name))) {
        self.wp_tearing_control_manager_v1 = @ptrCast(@alignCast(
            c.wl_registry_bind(wl_registry, name, &c.wp_tearing_control_manager_v1_interface, 1),
        ));
        logging = true;
    }
    if (logging) {
        log.debug("wlRegistryGlobal binding {s}", .{interface});
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
    log.debug("xdgWmBasePing", .{});
}

fn wlSeatCapabilities(user_data: ?*anyopaque, wl_seat: ?*c.wl_seat, capabilities: u32) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(user_data));
    if (capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD == c.WL_SEAT_CAPABILITY_KEYBOARD) {
        self.wl_keyboard = c.wl_seat_get_keyboard(wl_seat);
        _ = c.wl_keyboard_add_listener(self.wl_keyboard, &wl_keyboard_listener, self);
        log.debug("xdgSeatCapabilities set keyboard capabilities", .{});
    }
    if (capabilities & c.WL_SEAT_CAPABILITY_POINTER == c.WL_SEAT_CAPABILITY_POINTER) {
        const wl_pointer = c.wl_seat_get_pointer(wl_seat);
        self.wl_pointer = wl_pointer;
        _ = c.wl_pointer_add_listener(wl_pointer, &wl_pointer_listener, self);
        if (self.wp_cursor_shape_manager_v1) |wp_cursor_shape_manager_v1| {
            const wp_cursor_shape_device_v1 = c.wp_cursor_shape_manager_v1_get_pointer(
                wp_cursor_shape_manager_v1,
                wl_pointer,
            );
            self.wp_cursor_shape_device_v1 = wp_cursor_shape_device_v1;
        }
        log.debug("xdgSeatCapabilities set pointer capabilities", .{});
    }
}

fn wlSeatName(user_data: ?*anyopaque, wl_seat: ?*c.wl_seat, name: [*c]const u8) callconv(.c) void {
    _ = user_data;
    _ = wl_seat;
    _ = name;
}

fn xdgSurfaceConfigure(user_data: ?*anyopaque, xdg_surface: ?*c.xdg_surface, serial: u32) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(user_data));
    c.xdg_surface_ack_configure(xdg_surface, serial);
    if (self.wl_shm_pool == null) {
        createBuffers(self);
        self.buffers[0].busy = true;

        const callback = c.wl_surface_frame(self.wl_surface);
        _ = c.wl_callback_add_listener(callback, &wl_callback_listener, self);

        c.wl_surface_attach(self.wl_surface, self.buffers[0].wl_buffer, 0, 0);
        c.wl_surface_damage(self.wl_surface, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
        c.wl_surface_commit(self.wl_surface);
    } else if (self.resize_pending) {
        self.events.put(
            .{
                .window_resized = .{
                    .width = self.width,
                    .height = self.height,
                },
            },
        ) catch log.warn("Event queue full, a resizing event missed", .{});
        createBuffers(self);
        self.resize_pending = false;
    }

    log.debug("xdgSurfaceConfigure", .{});
}

fn createBuffers(self: *Self) void {
    const width: i32, const height: i32 = .{ @intCast(self.width), @intCast(self.height) };
    const stride = width * 4;
    const size = stride * height * buffers_len;

    if (self.wl_shm_pool_size < size or self.wl_shm_pool == null) {
        cleanup(c.wl_shm_pool_destroy, &self.wl_shm_pool, .{});
        if (self.pixels) |*pixels| {
            _ = std.os.linux.munmap(@ptrCast(pixels.ptr), pixels.len);
        }

        const memfd_create_flags = std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING;
        const fd: i32 = @intCast(std.os.linux.memfd_create("/wl_shm", memfd_create_flags));
        defer _ = std.os.linux.close(fd);
        std.debug.assert(fd != 0);
        const fcntl_flags = std.os.linux.F.SEAL_SHRINK | std.os.linux.F.SEAL_SEAL;
        std.debug.assert(std.os.linux.fcntl(fd, std.os.linux.F.ADD_SEALS, fcntl_flags) != -1);

        _ = std.os.linux.ftruncate(fd, size);
        const map = std.os.linux.mmap(
            null,
            @intCast(size),
            .{ .READ = true, .WRITE = true },
            std.os.linux.MAP{ .TYPE = .SHARED },
            fd,
            0,
        );
        const len: usize = @intCast(width * height * buffers_len);
        self.pixels = @as([*]u32, @ptrFromInt(map))[0..len];

        self.wl_shm_pool = c.wl_shm_create_pool(self.wl_shm, fd, size);

        self.wl_shm_pool_size = @intCast(size);
    }

    for (0..buffers_len) |i| {
        cleanup(c.wl_buffer_destroy, &self.buffers[i].wl_buffer, .{});
        self.buffers[i] = .{
            .wl_buffer = c.wl_shm_pool_create_buffer(
                self.wl_shm_pool,
                stride * height * @as(i32, @intCast(i)),
                width,
                height,
                stride,
                c.WL_SHM_FORMAT_ARGB8888,
            ),
            .pixels = self.pixels.?[@intCast(width * height * @as(i32, @intCast(i)))..],
            .busy = false,
        };
        _ = c.wl_buffer_add_listener(self.buffers[i].wl_buffer, &wl_buffer_listener, &self.buffers[i]);
    }
}

fn xdgToplevelClose(user_data: ?*anyopaque, toplevel: ?*c.xdg_toplevel) callconv(.c) void {
    _ = toplevel;
    const self: *Self = @ptrCast(@alignCast(user_data));
    self.events.put(.{ .window_close_requested = {} }) catch {
        log.warn("Event queue full, event closing missed", .{});
    };
    log.debug("xdgToplevelClose", .{});
}

fn xdgToplevelConfigure(
    user_data: ?*anyopaque,
    toplevel: ?*c.xdg_toplevel,
    width: i32,
    height: i32,
    selfs: [*c]c.wl_array,
) callconv(.c) void {
    _ = toplevel;
    _ = selfs;
    const self: *Self = @ptrCast(@alignCast(user_data));
    if ((width != 0 and height != 0) and (self.width != width or self.height != height)) {
        self.resize_pending = true;
        self.width = @intCast(width);
        self.height = @intCast(height);
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

fn wlBufferRelease(user_data: ?*anyopaque, wl_buffer: ?*c.wl_buffer) callconv(.c) void {
    _ = wl_buffer;
    const buffer: *Buffer = @ptrCast(@alignCast(user_data));
    buffer.busy = false;
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
    const self: *Self = @ptrCast(@alignCast(user_data));
    const arr_evdev_keys = @as([*]u32, @ptrCast(@alignCast(evdev_keys.?.data)))[0..evdev_keys.?.size];
    for (arr_evdev_keys) |evdev_key| {
        const key = evdev_to_key[if (evdev_key < evdev_key_max) evdev_key else 0];
        self.keyboard_self[@intFromEnum(key)] = true;
    }
    self.events.put(.{
        .keyboard_focus = .{ .focus = true },
    }) catch {
        log.warn("Event Queue is full, keyboard focus event missed", .{});
    };
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
    const self: *Self = @ptrCast(@alignCast(user_data));
    self.keyboard_self = .{false} ** keyboard_self_len;
    unsetTextInputTimer(self);
    self.events.put(.{
        .keyboard_focus = .{ .focus = false },
    }) catch {
        log.warn("Event Queue is full, keyboard focus event missed", .{});
    };
}

pub fn wlKeyboardKey(
    user_data: ?*anyopaque,
    wl_keyboard: ?*c.struct_wl_keyboard,
    serial: u32,
    time: u32,
    evdev_key: u32,
    keyboard_self: u32,
) callconv(.c) void {
    _ = wl_keyboard;
    _ = serial;
    _ = time;
    const self: *Self = @ptrCast(@alignCast(user_data));
    const modifiers = makeModifiers(self);
    const key = evdev_to_key[evdev_key];
    switch (keyboard_self) {
        c.WL_KEYBOARD_KEY_STATE_PRESSED => {
            if (self.keyboard_repeat_mode and self.keyboard_repeat_rate > 0) {
                setTextInputTimer(self);
            }
            _ = c.xkb_state_update_key(self.xkb_state, evdev_key + 8, c.XKB_KEY_DOWN);
            self.keyboard_last_key = evdev_key;
            self.events.put(.{
                .keyboard_key_down = .{
                    .key = key,
                    .repeat = false,
                    .modifiers = modifiers,
                    .raw = evdev_key,
                },
            }) catch {
                log.warn("Event Queue is full, key down event missed", .{});
            };
            self.keyboard_self[@intFromEnum(key)] = true;

            if (!self.text_input_enabled) return;

            const keysym = c.xkb_state_key_get_one_sym(self.xkb_state, evdev_key + 8);
            const result = c.xkb_compose_state_feed(self.xkb_compose_state, keysym);
            if (result == 0) {
                self.text_input_buf = .{0} ** text_input_buf_len;
                return;
            }

            switch (c.xkb_compose_state_get_status(self.xkb_compose_state)) {
                c.XKB_COMPOSE_COMPOSED => {
                    if (c.xkb_compose_state_get_utf8(self.xkb_compose_state, &self.text_input_buf, self.text_input_buf.len) > 0) {
                        self.events.put(.{ .text_input_changed = std.mem.sliceTo(&self.text_input_buf, 0) }) catch {
                            log.warn("Event queue full, a text input event missed", .{});
                        };
                    }
                },
                c.XKB_COMPOSE_NOTHING => {
                    if (c.xkb_state_key_get_utf8(self.xkb_state, evdev_key + 8, &self.text_input_buf, self.text_input_buf.len) > 0) {
                        self.events.put(.{ .text_input_changed = std.mem.sliceTo(&self.text_input_buf, 0) }) catch {
                            log.warn("Event queue full, a text input event missed", .{});
                        };
                    }
                },
                c.XKB_COMPOSE_COMPOSING => {
                    _ = getUtf8FromKeysym(&self.text_input_buf, keysym);
                    self.events.put(.{ .text_input_preedit_changed = std.mem.sliceTo(&self.text_input_buf, 0) }) catch {
                        log.warn("Event queue full, a text input event missed", .{});
                    };
                },
                c.XKB_COMPOSE_CANCELLED => {
                    self.events.put(.{ .text_input_preedit_cancel = {} }) catch {
                        log.warn("Event queue full, a text input event missed", .{});
                    };
                    self.text_input_buf = .{0} ** text_input_buf_len;
                },
                else => {},
            }
        },
        c.WL_KEYBOARD_KEY_STATE_RELEASED => {
            if (self.keyboard_repeat_mode and self.keyboard_repeat_rate > 0) {
                unsetTextInputTimer(self);
            }
            _ = c.xkb_state_update_key(self.xkb_state, evdev_key + 8, c.XKB_KEY_UP);
            self.events.put(.{
                .keyboard_key_up = .{
                    .key = key,
                    .modifiers = modifiers,
                    .repeat = false,
                    .raw = evdev_key,
                },
            }) catch {
                log.warn("Event Queue is full, key up event missed", .{});
            };
            self.keyboard_self[@intFromEnum(key)] = false;

            if (!self.text_input_enabled) return;
        },
        else => {},
    }
}

fn setTextInputTimer(self: *Self) void {
    const delay_ns = self.keyboard_repeat_delay * std.time.ns_per_ms;
    const interval_ns = std.time.ns_per_s / self.keyboard_repeat_rate;

    const timer_spec = std.os.linux.itimerspec{
        .it_value = .{
            .sec = @intCast(delay_ns / std.time.ns_per_s),
            .nsec = @intCast(delay_ns % std.time.ns_per_s),
        },
        .it_interval = .{
            .sec = @intCast(interval_ns / std.time.ns_per_s),
            .nsec = @intCast(interval_ns % std.time.ns_per_s),
        },
    };
    const ok = std.os.linux.timerfd_settime(
        self.text_input_timer_fd,
        std.os.linux.TFD.TIMER{},
        &timer_spec,
        null,
    );
    std.debug.assert(ok != -1);
}

fn unsetTextInputTimer(self: *Self) void {
    const ok = std.os.linux.timerfd_settime(
        self.text_input_timer_fd,
        std.os.linux.TFD.TIMER{},
        &std.mem.zeroes(std.os.linux.itimerspec),
        null,
    );
    std.debug.assert(ok != -1);
}

fn makeModifiers(self: *Self) Modifiers {
    return .{
        .caps_lock = c.xkb_state_mod_name_is_active(
            self.xkb_state,
            c.XKB_MOD_NAME_CAPS,
            c.XKB_STATE_MODS_LOCKED,
        ) != 0,
        .num_lock = c.xkb_state_mod_name_is_active(
            self.xkb_state,
            c.XKB_MOD_NAME_NUM,
            c.XKB_STATE_MODS_LOCKED,
        ) != 0,
        .shift = c.xkb_state_mod_name_is_active(
            self.xkb_state,
            c.XKB_MOD_NAME_SHIFT,
            c.XKB_STATE_MODS_EFFECTIVE,
        ) != 0,
        .control = c.xkb_state_mod_name_is_active(
            self.xkb_state,
            c.XKB_MOD_NAME_CTRL,
            c.XKB_STATE_MODS_EFFECTIVE,
        ) != 0,
        .alt = c.xkb_state_mod_name_is_active(
            self.xkb_state,
            c.XKB_MOD_NAME_ALT,
            c.XKB_STATE_MODS_EFFECTIVE,
        ) != 0,
        .super = c.xkb_state_mod_name_is_active(
            self.xkb_state,
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
    const self: *Self = @ptrCast(@alignCast(user_data));
    _ = c.xkb_state_update_mask(self.xkb_state, mods_depressed, mods_latched, mods_locked, 0, 0, group);
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
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const map_shm: [*:0]u8 = @ptrFromInt(
        std.os.linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0),
    );
    defer _ = std.os.linux.munmap(map_shm, size);
    defer _ = std.os.linux.close(fd);
    if (self.xkb_keymap) |xkb_keymap| {
        c.xkb_keymap_unref(xkb_keymap);
    }
    const xkb_keymap = c.xkb_keymap_new_from_string(
        self.xkb_context,
        map_shm,
        c.XKB_KEYMAP_FORMAT_TEXT_V1,
        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
    );
    self.xkb_keymap = xkb_keymap;

    if (self.xkb_state) |xkb_state| {
        c.xkb_state_unref(xkb_state);
    }
    const xkb_state = c.xkb_state_new(xkb_keymap).?;
    self.xkb_state = xkb_state;
}

fn wlKeyboardRepeatInfo(
    user_data: ?*anyopaque,
    wl_keyboard: ?*c.struct_wl_keyboard,
    rate: i32,
    delay: i32,
) callconv(.c) void {
    _ = wl_keyboard;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    self.keyboard_repeat_rate = @intCast(rate);
    self.keyboard_repeat_delay = @intCast(delay);
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
    const self: *Self = @ptrCast(@alignCast(data));
    self.pointer_serial = serial;
    self.pointer_position_changed = true;
    self.pointer_position_x = @intCast(c.wl_fixed_to_int(surface_x));
    self.pointer_position_y = @intCast(c.wl_fixed_to_int(surface_y));

    if (self.wp_cursor_shape_device_v1) |wp_cursor_shape_device_v1| {
        c.wp_cursor_shape_device_v1_set_shape(
            wp_cursor_shape_device_v1,
            serial,
            @intFromEnum(self.pointer_shape),
        );
    }
}

fn wlPointerLeave(
    data: ?*anyopaque,
    wl_pointer: ?*c.wl_pointer,
    serial: u32,
    wl_surface: ?*c.wl_surface,
) callconv(.c) void {
    _ = wl_pointer;
    _ = serial;
    _ = wl_surface;
    const self: *Self = @ptrCast(@alignCast(data));
    self.pointer_self = [_]bool{false} ** pointer_self_len;
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
    const self: *Self = @ptrCast(@alignCast(data));
    self.pointer_position_changed = true;
    self.pointer_position_x = @intCast(c.wl_fixed_to_int(surface_x));
    self.pointer_position_y = @intCast(c.wl_fixed_to_int(surface_y));
}

fn wlPointerButton(
    data: ?*anyopaque,
    wl_pointer: ?*c.wl_pointer,
    serial: u32,
    time: u32,
    button: u32,
    pointer_self: u32,
) callconv(.c) void {
    _ = serial;
    _ = time;
    _ = wl_pointer;
    const self: *Self = @ptrCast(@alignCast(data));
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
    if (pointer_self == c.WL_POINTER_BUTTON_STATE_PRESSED) {
        self.pointer_self[@intFromEnum(mapped_button)] = true;
        self.events.put(.{ .pointer_button_down = .{
            .button = mapped_button,
            .raw = button,
        } }) catch {
            std.log.warn("event queue full, a pointer button down event missed", .{});
        };
        return;
    }
    self.pointer_self[@intFromEnum(mapped_button)] = false;
    self.events.put(.{ .pointer_button_up = .{
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
    const self: *Self = @ptrCast(@alignCast(data));
    if (self.pointer_position_changed) {
        self.events.put(.{ .pointer_motion = .{
            .x = self.pointer_position_x,
            .y = self.pointer_position_y,
        } }) catch {
            std.log.warn("event queue full, a pointer moved event missed", .{});
        };
        self.pointer_position_changed = false;
    }
    if (self.pointer_axis_changed) {
        self.events.put(.{ .pointer_wheel = .{
            .x = self.pointer_axis_x / 120,
            .y = self.pointer_axis_y / 120,
        } }) catch {
            std.log.warn("event queue full, a pointer wheel event missed", .{});
        };
        self.pointer_axis_x = 0;
        self.pointer_axis_y = 0;
        self.pointer_axis_changed = false;
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
    const self: *Self = @ptrCast(@alignCast(data));
    self.pointer_axis_changed = true;
    if (axis == c.WL_POINTER_AXIS_VERTICAL_SCROLL) {
        self.pointer_axis_y += @floatFromInt(value120);
        return;
    }
    self.pointer_axis_x += @floatFromInt(value120);
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

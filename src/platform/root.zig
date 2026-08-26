const std = @import("std");
const Wayland = @import("Wayland.zig");
const options = @import("options");
const X11 = @import("X11.zig");

pub const Event = @import("common.zig").Event;
pub const Key = @import("common.zig").Key;
pub const Button = @import("common.zig").Button;
pub const FdListenerCallback = @import("common.zig").FdListenerCallback;
pub const Modifiers = @import("common.zig").Modifiers;
pub const Shape = @import("common.zig").Shape;

pub const Platform = switch (options.backend) {
    .wayland => Wayland,
    .x11 => X11,
};

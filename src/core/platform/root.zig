const std = @import("std");
const Wayland = @import("Wayland.zig");
const options = @import("options");
const X11 = @import("X11.zig");

pub const Platform = switch (options.backend) {
    .wayland => Wayland,
    .x11 => X11,
};

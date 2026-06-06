const std = @import("std");
const Platform = @import("platform").Platform;
const Io = std.Io;

pub fn main(_: std.process.Init) !void {
    var platform = Platform.init();
    defer platform.deinit();
}

const std = @import("std");
const Event = @import("platform/root.zig").Event;
const Platform = @import("platform/root.zig").Platform;
const Term = @import("Term.zig");
const Ansi = @import("Ansi.zig");

const c = @import("c");

pub const Tty = @This();

platform: *Platform,
term: *Term,
master: std.Io.File,
future: std.Io.Future(std.Io.Cancelable!void) = undefined,
closed: std.atomic.Value(bool) = .init(false),

pub fn init(self: *Tty, io: std.Io, environ_map: *std.process.Environ.Map, platform: *Platform, term: *Term) !void {
    var master_fd: i32 = undefined;
    const fork = c.forkpty(&master_fd, null, null, null);
    std.debug.assert(fork != -1);
    if (fork == 0) {
        try environ_map.put("TERM", "xterm-256color");
        try std.process.setCurrentPath(io, environ_map.get("HOME") orelse "");
        return std.process.replace(io, .{
            .argv = &.{environ_map.get("SHELL") orelse "sh"},
            .environ_map = environ_map,
        });
    }
    self.* = .{
        .master = std.Io.File{ .handle = master_fd, .flags = .{ .nonblocking = false } },
        .term = term,
        .platform = platform,
        .future = try io.concurrent(readFromMaster, .{ self, io }),
    };
}

pub fn deinit(self: *Tty, io: std.Io) void {
    self.future.cancel(io) catch {};
    self.master.close(io);
}

pub fn resize(self: *Tty, width: u32, height: u32, cols: u32, rows: u32) void {
    const winsize: c.winsize = .{
        .ws_xpixel = @intCast(width),
        .ws_ypixel = @intCast(height),
        .ws_col = @intCast(cols),
        .ws_row = @intCast(rows),
    };
    var result = std.os.linux.ioctl(self.master.handle, std.os.linux.T.IOCSWINSZ, @intFromPtr(&winsize));
    std.debug.assert(std.os.linux.errno(result) == .SUCCESS);
    var pgid: i32 = undefined;
    result = std.os.linux.tcgetpgrp(self.master.handle, &pgid);
    std.debug.assert(std.os.linux.errno(result) == .SUCCESS);
    result = std.os.linux.kill(pgid, std.os.linux.SIG.WINCH);
    std.debug.assert(std.os.linux.errno(result) == .SUCCESS);
}

fn readFromMaster(self: *Tty, io: std.Io) std.Io.Cancelable!void {
    const buf_len = 4096;
    var reader_buf: [buf_len]u8 = undefined;
    var reader_impl = self.master.reader(io, &reader_buf);
    const reader = &reader_impl.interface;

    var writer_buf: [buf_len]u8 = undefined;
    var writer_impl = self.master.writer(io, &writer_buf);
    const writer = &writer_impl.interface;

    var scratch_buf: [buf_len]u8 = undefined;
    var scratch = std.Io.Writer.fixed(&scratch_buf);

    var ansi = Ansi.init(writer, self.term, self.platform);

    while (true) {
        _ = reader.stream(&scratch, .limited(scratch_buf.len - scratch.end)) catch break;
        const rest = ansi.parse(io, scratch_buf[0..scratch.end]) catch unreachable;
        _ = scratch.consume(scratch.end - rest);
    }
    self.closed.store(true, .release);
}

pub fn isClosed(self: *Tty) bool {
    return self.closed.load(.acquire);
}

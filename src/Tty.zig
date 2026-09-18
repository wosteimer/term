const std = @import("std");
const Event = @import("platform/root.zig").Event;
const Platform = @import("platform/root.zig").Platform;
const Term = @import("Term.zig");
const Ansi = @import("Ansi.zig");

const c = @import("c");

pub const Tty = @This();

const io_buf_len = 4096;
pub const max_iovecs_len = 8;

master_fd: i32,
master_buf: [io_buf_len]u8 = undefined,
master_end: usize = 0,
writer_buf: [io_buf_len]u8 = undefined,
writer: std.Io.Writer,
closed: bool = false,
platform: *Platform,
term: *Term,

pub fn init(self: *Tty, io: std.Io, environ_map: *std.process.Environ.Map, platform: *Platform, term: *Term) !void {
    var master_fd: i32 = undefined;
    const fork = c.forkpty(&master_fd, null, null, null);
    std.debug.assert(fork != -1);
    if (fork == 0) {
        try environ_map.put("TERM", "xterm-256color");
        return std.process.replace(io, .{
            .argv = &.{environ_map.get("SHELL") orelse "sh"},
            .environ_map = environ_map,
        });
    }

    var flags = std.os.linux.fcntl(master_fd, std.os.linux.F.GETFL, 0);
    flags |= @as(u32, @bitCast(std.os.linux.O{ .NONBLOCK = true }));
    const ok = std.os.linux.fcntl(master_fd, std.os.linux.F.SETFL, flags);
    std.debug.assert(std.os.linux.errno(ok) == .SUCCESS);

    self.* = .{
        .master_fd = master_fd,
        .writer = .{ .buffer = &self.writer_buf, .end = 0, .vtable = &.{ .drain = drain } },
        .term = term,
        .platform = platform,
    };

    try platform.addFdListener(master_fd, .{ .in = true }, &Tty.readFromMaster, self);
}

pub fn resize(self: *Tty, width: u32, height: u32, cols: u32, rows: u32) void {
    const winsize: c.winsize = .{
        .ws_xpixel = @intCast(width),
        .ws_ypixel = @intCast(height),
        .ws_col = @intCast(cols),
        .ws_row = @intCast(rows),
    };
    var result = std.os.linux.ioctl(self.master_fd, std.os.linux.T.IOCSWINSZ, @intFromPtr(&winsize));
    std.debug.assert(std.os.linux.errno(result) == .SUCCESS);
    var pgid: i32 = undefined;
    result = std.os.linux.tcgetpgrp(self.master_fd, &pgid);
    std.debug.assert(std.os.linux.errno(result) == .SUCCESS);
    result = std.os.linux.kill(pgid, std.os.linux.SIG.WINCH);
    std.debug.assert(std.os.linux.errno(result) == .SUCCESS);
}

pub fn readFromMaster(user_data: ?*anyopaque, event_type: Event.Fd.Type) void {
    const self: *Tty = @ptrCast(@alignCast(user_data));

    if (event_type == .hup or event_type == .err) {
        self.closed = true;
        return;
    }

    const buf = self.master_buf[self.master_end..];
    const readed = std.os.linux.read(self.master_fd, buf.ptr, buf.len);
    const err = std.os.linux.errno(readed);
    switch (err) {
        .SUCCESS, .AGAIN => {},
        else => unreachable, // TODO: error handling
    }

    const end = readed + self.master_end;
    std.log.debug("input \"{f}\"", .{std.ascii.hexEscape(self.master_buf[0..end], .lower)});
    var reader = std.Io.Reader.fixed(self.master_buf[0..end]);
    var ansi: Ansi = undefined;
    ansi.init(&reader, self.term, self.platform);
    const rest = ansi.parse() catch unreachable;
    std.log.debug("readed {d} rest {d}", .{ readed, rest });
    @memmove(self.master_buf[0..rest], self.master_buf[end - rest .. end]);
    self.master_end = rest;
}

fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *Tty = @fieldParentPtr("writer", w);

    var len: usize = 0;
    var err: std.os.linux.E = .SUCCESS;

    if (w.end != 0) {
        const buf = w.buffer[0..w.end];
        len = std.os.linux.write(self.master_fd, buf.ptr, buf.len);
        err = std.os.linux.errno(len);
        w.end = w.end - len;
        switch (err) {
            .SUCCESS, .AGAIN => {},
            else => return std.Io.Writer.Error.WriteFailed,
        }
    }

    var iovecs: [max_iovecs_len]std.posix.iovec_const = undefined;
    if (data.len > 1) {
        for (data[0 .. data.len - 1], 0..) |data_buf, i| {
            iovecs[i] = .{
                .base = data_buf.ptr,
                .len = data_buf.len,
            };
        }

        const iovecs_slice = iovecs[0 .. data.len - 1];
        len += std.os.linux.writev(self.master_fd, iovecs_slice.ptr, iovecs_slice.len);
        err = std.os.linux.errno(len);
        switch (err) {
            .SUCCESS, .AGAIN => {},
            else => return std.Io.Writer.Error.WriteFailed,
        }
    }

    for (0..splat) |_| {
        const l = std.os.linux.write(self.master_fd, data[data.len - 1].ptr, data[data.len - 1].len);
        err = std.os.linux.errno(l);
        switch (err) {
            .SUCCESS, .AGAIN => {},
            else => return std.Io.Writer.Error.WriteFailed,
        }
        len += l;
    }
    return len;
}

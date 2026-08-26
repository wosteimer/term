const std = @import("std");
const Term = @import("Term.zig");
const Platform = @import("platform/root.zig").Platform;
const unicode = @import("unicode.zig");

pub const Ansi = @This();

const Arg = struct {
    a: usize,
    b: ?usize = null,
};

const args_capacity = 32;
const accum_capacity = 4096;

reader: *std.Io.Reader,
platform: *Platform,
term: *Term,
count: usize,
accum_buf: [accum_capacity]u8 = undefined,
accum: std.ArrayList(u8),

pub fn init(self: *Ansi, reader: *std.Io.Reader, term: *Term, platform: *Platform) void {
    self.* = .{
        .reader = reader,
        .term = term,
        .platform = platform,
        .accum = .initBuffer(&self.accum_buf),
        .count = 0,
    };
}

pub fn parse(self: *Ansi) !usize {
    loop: switch (try self.take()) {
        std.ascii.control_code.esc => {
            switch (try self.take()) {
                '[' => {
                    self.count = 2;
                    switch (try self.peek()) {
                        '?' => { // TODO:
                            _ = try self.take();
                            var buf: [args_capacity]Arg = undefined;
                            _ = try self.parseArgs(&buf);
                            _ = try self.take();
                        },
                        '0'...'9', 'a'...'z', 'A'...'Z', '@' => {
                            var buf: [args_capacity]Arg = undefined;
                            if (try self.parseArgs(&buf)) |args| {
                                switch (try self.take()) {
                                    'a'...'z', 'A'...'Z', '@' => |c| try self.parseCSI(args, c),
                                    else => {},
                                }
                            } else {
                                return self.count;
                            }
                        },
                        0 => return 2,
                        else => {},
                    }
                    continue :loop try self.take();
                },
                ']' => {
                    self.count = 2;
                    if (!try self.parseOSC()) {
                        return self.count;
                    }
                    continue :loop try self.take();
                },
                'M' => {
                    continue :loop try self.take();
                },
                '7' => {
                    self.term.decSave();
                    continue :loop try self.take();
                },
                '8' => {
                    self.term.decRestore();
                    continue :loop try self.take();
                },
                0 => return 1,
                else => {
                    continue :loop try self.take();
                },
            }
        },
        std.ascii.control_code.lf => {
            try self.term.lineFeed();
            continue :loop try self.take();
        },
        std.ascii.control_code.cr => {
            self.term.carriageReturn();
            continue :loop try self.take();
        },
        std.ascii.control_code.bs => {
            self.term.moveCursor(1, .left);
            continue :loop try self.take();
        },
        std.ascii.control_code.del => {
            self.term.moveCursor(1, .right);
            // const cursor = self.term.cursor;
            // const x = cursor.x + 1;
            // const y = cursor.y;
            // self.term.setCursor(x, y);
            continue :loop try self.take();
        },
        std.ascii.control_code.ht => {
            self.term.moveCursor(8, .right);
            // for (0..8) |_| {
            //     try self.term.insert(" ", 1);
            // }
            continue :loop try self.take();
        },
        std.ascii.control_code.vt => {
            self.term.moveCursor(1, .down);
            // const cursor = self.term.cursor;
            // const x = cursor.x;
            // const y = cursor.y + 1;
            // self.term.setCursor(x, y);
            continue :loop try self.take();
        },
        0 => {},
        else => |first| {
            if (std.ascii.isControl(first)) {
                continue :loop try self.take();
            }
            self.accum.clearRetainingCapacity();
            self.accum.appendBounded(first) catch {};
            text: switch (try self.peek()) {
                0 => {
                    const rest = self.parseText(self.accum.items);
                    return rest;
                },
                else => |c| {
                    if (std.ascii.isControl(c)) {
                        _ = self.parseText(self.accum.items);
                        continue :loop try self.take();
                    }
                    self.accum.appendBounded(try self.take()) catch {};
                    continue :text try self.peek();
                },
            }
        },
    }
    return 0;
}

fn parseText(self: *Ansi, text: []const u8) usize {
    var iter: unicode.GraphemeIter = undefined;
    iter.init(text);
    var grapheme_opt: ?unicode.GraphemeIter.Grapheme = null;
    var len: usize = 0;
    while (true) {
        if (grapheme_opt) |grapheme| {
            const bytes, const codepoints = .{ grapheme.bytes, grapheme.codepoints };
            len += bytes.len;
            self.term.insert(bytes, unicode.charWidth(codepoints)) catch unreachable;
        }
        grapheme_opt = iter.next() catch return text.len - len - 1;
        if (grapheme_opt == null) break;
    }
    return 0;
}

fn parseArgs(self: *Ansi, buf: []Arg) !?[]Arg {
    var args = std.ArrayList(Arg).initBuffer(buf);
    var fill_b: bool = false;
    args: switch (try self.peek()) {
        '0'...'9' => {
            self.accum.clearRetainingCapacity();
            self.accum.appendBounded(try self.take()) catch {};
            arg: switch (try self.peek()) {
                '0'...'9' => {
                    self.accum.appendBounded(try self.take()) catch {};
                    continue :arg try self.peek();
                },
                ';', ':' => |sep| {
                    _ = try self.take();
                    const arg = std.fmt.parseInt(usize, self.accum.items, 10) catch unreachable;
                    if (fill_b) {
                        args.items[args.items.len - 1].b = arg;
                        fill_b = false;
                    } else {
                        args.appendBounded(.{ .a = arg }) catch {};
                    }
                    if (sep == ':') {
                        fill_b = true;
                    }
                    continue :args try self.peek();
                },
                0 => return null,
                else => {
                    if (self.accum.items.len > 0) {
                        const arg = std.fmt.parseInt(usize, self.accum.items, 10) catch unreachable;
                        if (fill_b) {
                            args.items[args.items.len - 1].b = arg;
                            fill_b = false;
                        } else {
                            args.appendBounded(.{ .a = arg }) catch {};
                        }
                    }
                },
            }
        },
        0 => return null,
        else => {},
    }
    return args.items;
}

const csi_ops = struct {
    pub const scroll_left = '@';
    pub const move_cursor_to_H = 'H';
    pub const move_cursor_to_f = 'f';
    pub const move_cursor_up = 'A';
    pub const move_cursor_down = 'B';
    pub const move_cursor_right = 'C';
    pub const move_cursor_left = 'D';
    pub const move_cursor_beginning_next_line = 'E';
    pub const move_cursor_beginning_previous_line = 'F';
    pub const move_cursor_to_column = 'G';
    pub const delete = 'P';
    pub const sco_save_cursor = 's';
    pub const sco_restore_cursor = 'u';
    pub const erase = 'J';
    pub const erase_line = 'K';
};

fn parseCSI(self: *Ansi, args: []Arg, c: u8) !void {
    switch (c) {
        csi_ops.scroll_left => {
            const arg = if (args.len > 0) args[0].a else 1;
            try self.term.scrollLeft(arg);
        },
        csi_ops.move_cursor_to_H, csi_ops.move_cursor_to_f => {
            const y = if (args.len > 0) args[0].a else 0;
            const x = if (args.len > 1) args[1].a else 0;
            self.term.setCursor(x, y, false);
        },
        csi_ops.move_cursor_up => {
            const amount = if (args.len > 0) args[0].a else 1;
            self.term.moveCursor(amount, .up);
            // const cursor = self.term.cursor;
            // const x = cursor.x;
            // const y = if (args.len > 0) cursor.y - args[0].a else @max(1, cursor.y) - 1;
            // self.term.setCursor(x, y);
        },
        csi_ops.move_cursor_down => {
            const amount = if (args.len > 0) args[0].a else 1;
            self.term.moveCursor(amount, .down);
            // const cursor = self.term.cursor;
            // const x = cursor.x;
            // const y = if (args.len > 0) cursor.y + args[0].a else cursor.y + 1;
            // self.term.setCursor(x, y);
        },
        csi_ops.move_cursor_right => {
            const amount = if (args.len > 0) args[0].a else 1;
            self.term.moveCursor(amount, .right);
            // const cursor = self.term.cursor;
            // const x = if (args.len > 0) cursor.x + args[0].a else cursor.x + 1;
            // const y = cursor.y;
            // self.term.setCursor(x, y);
        },
        csi_ops.move_cursor_left => {
            const amount = if (args.len > 0) args[0].a else 1;
            self.term.moveCursor(amount, .left);
            // const cursor = self.term.cursor;
            // const x = if (args.len > 0) cursor.x - args[0].a else @max(1, cursor.x) - 1;
            // const y = cursor.y;
            // self.term.setCursor(x, y);
        },
        csi_ops.move_cursor_beginning_next_line => {
            self.term.moveCursorBeginningNextLine();
            // const cursor = self.term.cursor;
            // const x = 0;
            // const y = if (args.len > 0) cursor.y + args[0].a else cursor.y + 1;
            // self.term.setCursor(x, y);
        },
        csi_ops.move_cursor_beginning_previous_line => {
            self.term.moveCursorBeginningPreviousLine();
            // const cursor = self.term.cursor;
            // const x = 0;
            // const y = if (args.len > 0) cursor.y - args[0].a else cursor.y - 1;
            // self.term.setCursor(x, y);
        },
        csi_ops.move_cursor_to_column => {
            const col = if (args.len > 0) args[0].a else 0;
            self.term.moveCursorToColumn(col);
            // const cursor = self.term.cursor;
            // const x = if (args.len > 0) args[0].a else 0;
            // const y = cursor.y;
            // self.term.setCursor(x, y);
        },
        csi_ops.delete => {
            const arg = if (args.len > 0) args[0].a else 1;
            try self.term.delete(arg);
        },
        'n' => {}, // TODO:
        csi_ops.sco_save_cursor => self.term.scoSave(),
        csi_ops.sco_restore_cursor => self.term.scoRestore(),
        csi_ops.erase => {
            const arg = if (args.len > 0) args[0].a else 0;
            switch (arg) {
                0 => try self.term.eraseEndScreen(),
                1 => try self.term.eraseBeginScreen(),
                2 => self.term.eraseAllScreen(),
                3 => self.term.eraseAllScreenAndScrollback(),
                else => {},
            }
        },
        csi_ops.erase_line => {
            const arg = if (args.len > 0) args[0].a else 0;
            switch (arg) {
                0 => try self.term.eraseEndLine(),
                1 => try self.term.eraseBeginLine(),
                2 => try self.term.eraseAllLine(),
                else => {},
            }
        },
        else => {},
    }
}

const osc_ops = struct {
    const set_window_title = '0';
};

pub fn parseOSC(self: *Ansi) !bool {
    switch (try self.take()) {
        osc_ops.set_window_title => {
            switch (try self.take()) {
                ';' => {
                    self.accum.clearRetainingCapacity();
                    title: switch (try self.take()) {
                        std.ascii.control_code.bel => {
                            self.platform.setTitle(self.accum.items);
                        },
                        0 => return false,
                        else => |c| {
                            self.accum.appendBounded(c) catch {};
                            continue :title try self.take();
                        },
                    }
                },
                else => {},
            }
        },
        else => {},
    }
    return true;
}

fn take(self: *Ansi) !u8 {
    const result = self.reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => return 0,
        else => return err,
    };
    self.count += 1;
    return result;
}

fn peek(self: *Ansi) !u8 {
    return self.reader.peekByte() catch |err| switch (err) {
        error.EndOfStream => 0,
        else => err,
    };
}

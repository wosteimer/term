const std = @import("std");
const Term = @import("Term.zig");
const Platform = @import("platform/root.zig").Platform;
const Graphemes = @import("Graphemes");
const ARGB = @import("colors.zig").ARGB;
const Pallete = @import("colors.zig").Pallete;

pub const Ansi = @This();

const log = std.log.scoped(.ansi);

const Arg = struct {
    first: usize,
    second: ?usize = null,
};

const args_capacity = 32;
const accum_capacity = 4096;

reader: *std.Io.Reader,
platform: *Platform,
writer: *std.Io.Writer,
term: *Term,
count: usize,
accum_buf: [accum_capacity]u8 = undefined,
accum: std.ArrayList(u8),

pub fn init(self: *Ansi, writer: *std.Io.Writer, reader: *std.Io.Reader, term: *Term, platform: *Platform) void {
    self.* = .{
        .reader = reader,
        .writer = writer,
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
                '(' => {
                    // HACK: currently just ignoring this ansi sequence
                    self.count = 2;
                    if (try self.take() == 0) {
                        return self.count;
                    }
                    continue :loop try self.take();
                },
                '[' => {
                    self.count = 2;
                    switch (try self.peek()) {
                        '?', '>' => {
                            // HACK: currently just ignoring this ansi sequence
                            _ = try self.take();
                            var buf: [args_capacity]Arg = undefined;
                            if (try self.parseArgs(&buf)) |_| {
                                if (try self.take() == 0) {
                                    return self.count;
                                }
                            } else {
                                return self.count;
                            }
                        },
                        '0'...'9', 'a'...'z', 'A'...'Z', '@', ';' => {
                            var buf: [args_capacity]Arg = undefined;
                            if (try self.parseArgs(&buf)) |args| {
                                switch (try self.take()) {
                                    'm' => try self.parseSGR(args),
                                    'a'...'l', 'n'...'z', 'A'...'Z', '@' => |c| try self.parseCSI(args, c),
                                    ' ' => {
                                        // HACK: currently just ignoring this ansi sequence
                                        if (try self.take() == 0) {
                                            return self.count;
                                        }
                                    },
                                    0 => return self.count,
                                    else => |c| log.warn("unknown escape code: args: {any} code: {c}", .{ args, c }),
                                }
                            } else {
                                return self.count;
                            }
                        },
                        0 => return 2,
                        else => |c| log.warn("unknown escape code: {c}", .{c}),
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
            continue :loop try self.take();
        },
        std.ascii.control_code.ht => {
            self.term.moveCursor(8, .right);
            continue :loop try self.take();
        },
        std.ascii.control_code.vt => {
            self.term.moveCursor(1, .down);
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
    var iter = Graphemes.iterator(text);
    var grapheme_opt: ?Graphemes.Grapheme = null;
    var len: usize = 0;
    while (true) {
        if (grapheme_opt) |grapheme| {
            const bytes = grapheme.bytes(text);
            len += bytes.len;
            self.term.insert(bytes, @intCast(grapheme.displayWidth(text))) catch unreachable;
        }
        grapheme_opt = iter.next();
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
                        args.items[args.items.len - 1].second = arg;
                        fill_b = false;
                    } else {
                        args.appendBounded(.{ .first = arg }) catch {};
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
                            args.items[args.items.len - 1].second = arg;
                            fill_b = false;
                        } else {
                            args.appendBounded(.{ .first = arg }) catch {};
                        }
                    }
                },
            }
        },
        ';' => {
            _ = try self.take();
            args.appendBounded(.{ .first = 0 }) catch {};
            continue :args try self.peek();
        },
        0 => return null,
        else => {},
    }
    return args.items;
}

const sgr_ops = struct {
    pub const bold = 1;
    pub const dim = 2;
    pub const italic = 3;
    pub const underline = 4;
    pub const blink = 5;
    pub const fast_blink = 6;
    pub const inverse = 7;
    pub const hidden = 8;

    pub const reset_all = 0;
    pub const reset_bold_dim = 22;
    pub const reset_italic = 23;
    pub const reset_underline = 24;
    pub const reset_blink = 25;
    pub const reset_inverse = 27;
    pub const reset_hidden = 28;
};

const underline_shape = struct {
    pub const none = 0;
    pub const single = 1;
    pub const double = 2;
    pub const curly = 3;
    pub const dotted = 4;
    pub const dashed = 5;
};

fn parseSGR(self: *Ansi, args: []Arg) !void {
    if (args.len == 0) {
        self.term.resetStyle();
        return;
    }
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        switch (arg.first) {
            sgr_ops.bold => self.term.setStyle(.{ .bold = true }),
            sgr_ops.dim => self.term.setStyle(.{ .dim = true }),
            sgr_ops.italic => self.term.setStyle(.{ .italic = true }),
            sgr_ops.underline => {
                const b = arg.second orelse underline_shape.single;
                self.term.setStyle(.{ .underline = .{
                    .color = self.term.style.underline.color,
                    .shape = switch (b) {
                        underline_shape.none => .none,
                        underline_shape.single => .single,
                        underline_shape.double => .double,
                        underline_shape.curly => .curly,
                        underline_shape.dotted => .dotted,
                        underline_shape.dashed => .dashed,
                        else => .single,
                    },
                } });
            },
            sgr_ops.blink => self.term.setStyle(.{ .blink = .slow }),
            sgr_ops.fast_blink => self.term.setStyle(.{ .blink = .fast }),
            sgr_ops.inverse => self.term.setStyle(.{ .inverse = true }),
            sgr_ops.hidden => self.term.setStyle(.{ .hidden = true }),
            sgr_ops.reset_all => self.term.resetStyle(),
            sgr_ops.reset_bold_dim => self.term.setStyle(.{ .bold = false, .dim = false }),
            sgr_ops.reset_italic => self.term.setStyle(.{ .italic = false }),
            sgr_ops.reset_underline => self.term.setStyle(.{ .underline = .{
                .color = self.term.style.underline.color,
                .shape = .none,
            } }),
            sgr_ops.reset_blink => self.term.setStyle(.{ .blink = .static }),
            sgr_ops.reset_inverse => self.term.setStyle(.{ .inverse = false }),
            sgr_ops.reset_hidden => self.term.setStyle(.{ .hidden = false }),
            30...37, 39 => |code| {
                const color = code - 30;
                if (color == Pallete.default) {
                    self.term.setStyle(.{ .foreground = self.term.pallete.default_foreground });
                } else {
                    self.term.setStyle(.{ .foreground = self.term.pallete.colors_8[color] });
                }
            },
            40...47, 49 => |code| {
                const color = code - 40;
                if (color == Pallete.default) {
                    self.term.setStyle(.{ .background = self.term.pallete.default_background });
                } else {
                    self.term.setStyle(.{ .background = self.term.pallete.colors_8[color] });
                }
            },
            90...97 => |code| {
                const color = code - 90;
                self.term.setStyle(.{ .foreground = self.term.pallete.colors_16[color] });
            },
            100...107 => |code| {
                const color = code - 100;
                self.term.setStyle(.{ .background = self.term.pallete.colors_16[color] });
            },
            38 => {
                if (i + 2 < args.len and args[i + 1].first == 5) {
                    const code = args[i + 2].first;
                    self.term.setStyle(.{ .foreground = Pallete.colors_256[code] });
                    i += 2;
                } else if (i + 4 < args.len and args[i + 1].first == 2) {
                    self.term.setStyle(.{ .foreground = ARGB{
                        .a = 255,
                        .r = @intCast(args[i + 2].first),
                        .g = @intCast(args[i + 3].first),
                        .b = @intCast(args[i + 4].first),
                    } });
                    i += 4;
                }
            },
            48 => {
                if (i + 2 < args.len and args[i + 1].first == 5) {
                    const code = args[i + 2].first;
                    self.term.setStyle(.{ .background = Pallete.colors_256[code] });
                    i += 2;
                } else if (i + 4 < args.len and args[i + 1].first == 2) {
                    self.term.setStyle(.{ .background = ARGB{
                        .a = 255,
                        .r = @intCast(args[i + 2].first),
                        .g = @intCast(args[i + 3].first),
                        .b = @intCast(args[i + 4].first),
                    } });
                    i += 4;
                }
            },
            else => {},
        }
    }
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
    pub const request_cursor_position = 'n';
};

fn parseCSI(self: *Ansi, args: []Arg, c: u8) !void {
    switch (c) {
        csi_ops.request_cursor_position => {
            const arg = if (args.len > 0) args[0].first else 1;
            if (arg == 6) {
                try self.writer.print("\x1b[{d};{d}R", .{ self.term.cursor.y + 1, self.term.cursor.x + 1 });
                try self.writer.flush();
            }
        },
        csi_ops.scroll_left => {
            const arg = if (args.len > 0) args[0].first else 1;
            try self.term.scrollLeft(arg);
        },
        csi_ops.move_cursor_to_H, csi_ops.move_cursor_to_f => {
            const y = if (args.len > 0) args[0].first -| 1 else 0;
            const x = if (args.len > 1) args[1].first -| 1 else 0;
            self.term.setCursor(x, y, false);
        },
        csi_ops.move_cursor_up => {
            const amount = if (args.len > 0) args[0].first else 1;
            self.term.moveCursor(amount, .up);
        },
        csi_ops.move_cursor_down => {
            const amount = if (args.len > 0) args[0].first else 1;
            self.term.moveCursor(amount, .down);
        },
        csi_ops.move_cursor_right => {
            const amount = if (args.len > 0) args[0].first else 1;
            self.term.moveCursor(amount, .right);
        },
        csi_ops.move_cursor_left => {
            const amount = if (args.len > 0) args[0].first else 1;
            self.term.moveCursor(amount, .left);
        },
        csi_ops.move_cursor_beginning_next_line => {
            self.term.moveCursorBeginningNextLine();
        },
        csi_ops.move_cursor_beginning_previous_line => {
            self.term.moveCursorBeginningPreviousLine();
        },
        csi_ops.move_cursor_to_column => {
            const col = if (args.len > 0) args[0].first -| 1 else 0;
            self.term.moveCursorToColumn(col);
        },
        csi_ops.delete => {
            const arg = if (args.len > 0) args[0].first else 1;
            try self.term.delete(arg);
        },
        csi_ops.sco_save_cursor => self.term.scoSave(),
        csi_ops.sco_restore_cursor => self.term.scoRestore(),
        csi_ops.erase => {
            const arg = if (args.len > 0) args[0].first else 0;
            switch (arg) {
                0 => try self.term.eraseEndScreen(),
                1 => try self.term.eraseBeginScreen(),
                2 => self.term.eraseAllScreen(),
                3 => self.term.eraseAllScreenAndScrollback(),
                else => {},
            }
        },
        csi_ops.erase_line => {
            const arg = if (args.len > 0) args[0].first else 0;
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

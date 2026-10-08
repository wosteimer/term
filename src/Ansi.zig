const std = @import("std");
const Term = @import("Term.zig");
const Platform = @import("platform/root.zig").Platform;
const Graphemes = @import("Graphemes");
const ARGB = @import("colors.zig").ARGB;
const Pallete = @import("colors.zig").Pallete;

pub const Ansi = @This();

const log = std.log.scoped(.ansi);

const sgr_ops = struct {
    pub const bold = 1;
    pub const dim = 2;
    pub const italic = 3;
    pub const underline = 4;
    pub const blink = 5;
    pub const fast_blink = 6;
    pub const inverse = 7;
    pub const hidden = 8;
    pub const strikethrough = 9;

    pub const reset_all = 0;
    pub const reset_bold_dim = 22;
    pub const reset_italic = 23;
    pub const reset_underline = 24;
    pub const reset_blink = 25;
    pub const reset_inverse = 27;
    pub const reset_hidden = 28;
    pub const reset_strikethrough = 29;
    pub const reset_underline_color = 59;
};

const underline_shape = struct {
    pub const none = 0;
    pub const single = 1;
    pub const double = 2;
    pub const curly = 3;
    pub const dotted = 4;
    pub const dashed = 5;
};

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

const osc_ops = struct {
    const set_window_title = '0';
};

const Arg = struct {
    first: usize,
    second: ?usize = null,
};

const ArgsIterator = struct {
    internal_iter: SimdSplitAnyIterator(&.{ ':', ';' }),

    pub fn init(input: []const u8) ArgsIterator {
        return .{ .internal_iter = .{ .input = input } };
    }

    pub fn next(self: *ArgsIterator) ?Arg {
        if (self.internal_iter.next()) |split| {
            const first = std.fmt.parseInt(usize, split.text, 10) catch 0;
            var second: ?usize = null;
            if (split.delimiter == ':') {
                const next_split = self.internal_iter.next().?;
                second = std.fmt.parseInt(usize, next_split.text, 10) catch 0;
            }
            return Arg{ .first = first, .second = second };
        }
        return null;
    }
};

fn SimdSplitAnyIterator(comptime needles: []const u8) type {
    return struct {
        pub const Value = struct { text: []const u8, delimiter: u8 };

        input: []const u8,
        count: usize = 0,

        pub fn next(self: *@This()) ?Value {
            const start = self.count;
            if (start > self.input.len) return null;
            if (simdIndexOfAny(self.input[self.count..], needles)) |index| {
                const end = self.count + index;
                self.count = end + 1;
                return .{ .text = self.input[start..end], .delimiter = self.input[end] };
            }
            self.count = self.input.len + 1;
            return .{ .text = self.input[start..], .delimiter = 0 };
        }
    };
}

const SimdSplitControlIterator = struct {
    pub const Value = struct { text: []const u8, control: ?u8 };

    input: []const u8,
    count: usize = 0,
    control: ?u8 = null,

    pub fn next(self: *@This()) ?Value {
        const start = self.count;
        if (start > self.input.len) return null;
        if (simdIndexOfControl(self.input[self.count..])) |index| {
            const end = self.count + index;
            self.count = end + 1;
            const result = Value{ .text = self.input[start..end], .control = self.control };
            self.control = self.input[end];
            return result;
        }
        self.count = self.input.len + 1;
        return .{ .text = self.input[start..], .control = self.control };
    }
};

platform: *Platform,
term: *Term,
writer: *std.Io.Writer,

pub fn init(writer: *std.Io.Writer, term: *Term, platform: *Platform) Ansi {
    return .{
        .writer = writer,
        .term = term,
        .platform = platform,
    };
}

pub fn parse(self: *Ansi, input: []const u8) !usize {
    var iter = SimdSplitControlIterator{ .input = input };
    var rest: usize = 0;

    while (iter.next()) |current| {
        const text = current.text;
        var text_start: usize = 0;
        if (current.control) |control| switch (control) {
            std.ascii.control_code.esc => if (text.len > 0) {
                switch (text[0]) {
                    '(' => {
                        // HACK: currently just ignoring this ansi sequence
                        const offset = 1;
                        var escape_last_char_index = simdIndexOfAnyInRange(
                            text[offset..],
                            0x40,
                            0x7f,
                        ) orelse {
                            // INFO: incomplete escape code wait for next chunk to parse
                            rest = text.len + 1;
                            break;
                        };
                        escape_last_char_index += offset;
                        text_start = escape_last_char_index + 1;
                        log.warn("escape code ignored: ESC{s}", .{text[0..text_start]});
                    },
                    '[' => if (text.len >= 2) {
                        switch (text[1]) {
                            '<'...'?' => {
                                // HACK: currently just ignoring this ansi sequence
                                const offset = 2;
                                var escape_last_char_index = simdIndexOfAnyInRange(
                                    text[offset..],
                                    0x40,
                                    0x7f,
                                ) orelse {
                                    // INFO: incomplete escape code wait for next chunk to parse
                                    rest = text.len + 1;
                                    break;
                                };
                                escape_last_char_index += offset;
                                text_start = escape_last_char_index + 1;
                                log.warn("escape code ignored: ESC{s}", .{text[0..text_start]});
                            },
                            else => {
                                const offset = 1;
                                var escape_last_char_index = simdIndexOfAnyInRange(
                                    text[offset..],
                                    0x40,
                                    0x7f,
                                ) orelse {
                                    // INFO: incomplete escape code wait for next chunk to parse
                                    rest = text.len + 1;
                                    break;
                                };
                                escape_last_char_index += offset;
                                text_start = escape_last_char_index + 1;
                                switch (text[escape_last_char_index]) {
                                    'm' => self.parseSGR(text[offset..escape_last_char_index]),
                                    'a'...'l', 'n'...'z', 'A'...'Z', '@' => |c| {
                                        try self.parseCSI(text[offset..escape_last_char_index], c);
                                    },
                                    // ...
                                    else => {},
                                }
                                log.debug("escape parsed: ESC{s}", .{text[0..text_start]});
                            },
                        }
                    } else {
                        // INFO: incomplete escape code wait for next chunk to parse
                        rest = text.len + 1;
                        break;
                    },
                    ']' => {
                        if (!self.parseOSC(text[1..])) {
                            // INFO: incomplete escape code wait for next chunk to parse
                            rest = text.len + 1;
                            break;
                        }
                        text_start = text.len;
                    },
                    'M' => {
                        // HACK: currently just ignoring this ansi sequence
                        log.warn("escape code ignored: ESC[M", .{});
                        text_start = 1;
                    },
                    '7' => {
                        self.term.decSave();
                        text_start = 1;
                    },
                    '8' => {
                        self.term.decRestore();
                        text_start = 1;
                    },
                    else => {},
                }
            } else {
                // INFO: incomplete escape code wait for next chunk to parse
                rest = 1;
                break;
            },
            std.ascii.control_code.bs => self.term.moveCursor(1, .left),
            std.ascii.control_code.ht => self.term.moveCursor(8, .right),
            std.ascii.control_code.lf => try self.term.lineFeed(),
            std.ascii.control_code.vt => self.term.moveCursor(1, .down),
            std.ascii.control_code.cr => self.term.carriageReturn(),
            else => {},
        };

        if (text_start < text.len) {
            rest = self.parseText(text[text_start..]);
        }
    }

    return rest;
}

fn parseSGR(self: *Ansi, input: []const u8) void {
    var iter = ArgsIterator.init(input);
    var is_empty = true;
    while (iter.next()) |arg| {
        is_empty = false;
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
                        else => .none,
                    },
                } });
            },
            sgr_ops.blink => self.term.setStyle(.{ .blink = .slow }),
            sgr_ops.fast_blink => self.term.setStyle(.{ .blink = .fast }),
            sgr_ops.inverse => self.term.setStyle(.{ .inverse = true }),
            sgr_ops.hidden => self.term.setStyle(.{ .hidden = true }),
            sgr_ops.strikethrough => self.term.setStyle(.{ .strikethrough = true }),
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
            sgr_ops.reset_strikethrough => self.term.setStyle(.{ .strikethrough = false }),
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
                if (iter.next()) |pallete_type_arg| {
                    if (pallete_type_arg.first == 5) {
                        const code = if (iter.next()) |code_arg| code_arg.first else 0;
                        self.term.setStyle(.{ .foreground = Pallete.colors_256[code] });
                    } else if (pallete_type_arg.first == 2) {
                        self.term.setStyle(.{ .foreground = ARGB{
                            .a = 255,
                            .r = @intCast(if (iter.next()) |red_arg| red_arg.first else 0),
                            .g = @intCast(if (iter.next()) |green_arg| green_arg.first else 0),
                            .b = @intCast(if (iter.next()) |blue_arg| blue_arg.first else 0),
                        } });
                    }
                }
            },
            48 => {
                if (iter.next()) |pallete_type_arg| {
                    if (pallete_type_arg.first == 5) {
                        const code = if (iter.next()) |code_arg| code_arg.first else 0;
                        self.term.setStyle(.{ .background = Pallete.colors_256[code] });
                    } else if (pallete_type_arg.first == 2) {
                        self.term.setStyle(.{ .background = ARGB{
                            .a = 255,
                            .r = @intCast(if (iter.next()) |red_arg| red_arg.first else 0),
                            .g = @intCast(if (iter.next()) |green_arg| green_arg.first else 0),
                            .b = @intCast(if (iter.next()) |blue_arg| blue_arg.first else 0),
                        } });
                    }
                }
            },
            58 => {
                if (iter.next()) |pallete_type_arg| {
                    if (pallete_type_arg.first == 5) {
                        const code = if (iter.next()) |code_arg| code_arg.first else 0;
                        self.term.setStyle(.{ .underline = .{
                            .shape = self.term.style.underline.shape,
                            .color = Pallete.colors_256[code],
                        } });
                    } else if (pallete_type_arg.first == 2) {
                        self.term.setStyle(.{ .underline = .{
                            .shape = self.term.style.underline.shape,
                            .color = ARGB{
                                .a = 255,
                                .r = @intCast(if (iter.next()) |red_arg| red_arg.first else 0),
                                .g = @intCast(if (iter.next()) |green_arg| green_arg.first else 0),
                                .b = @intCast(if (iter.next()) |blue_arg| blue_arg.first else 0),
                            },
                        } });
                    }
                }
            },
            sgr_ops.reset_underline_color => self.term.style.underline.color = null,
            else => {},
        }
    }
    if (is_empty) {
        self.term.resetStyle();
    }
}

fn parseCSI(self: *Ansi, input: []const u8, c: u8) !void {
    var iter = ArgsIterator.init(input);
    switch (c) {
        csi_ops.request_cursor_position => {
            const code = if (iter.next()) |arg| arg.first else return;
            if (code == 6) {
                try self.writer.print("\x1b[{d};{d}R", .{ self.term.cursor.y + 1, self.term.cursor.x + 1 });
                try self.writer.flush();
            }
        },
        csi_ops.scroll_left => {
            const amount = if (iter.next()) |arg| @max(arg.first, 1) else 1;
            try self.term.scrollLeft(amount);
        },
        csi_ops.move_cursor_to_H, csi_ops.move_cursor_to_f => {
            const y = if (iter.next()) |arg| arg.first -| 1 else 0;
            const x = if (iter.next()) |arg| arg.first -| 1 else 0;
            self.term.setCursor(x, y, false);
        },
        csi_ops.move_cursor_up => {
            const amount = if (iter.next()) |arg| @max(arg.first, 1) else 1;
            self.term.moveCursor(amount, .up);
        },
        csi_ops.move_cursor_down => {
            const amount = if (iter.next()) |arg| @max(arg.first, 1) else 1;
            self.term.moveCursor(amount, .down);
        },
        csi_ops.move_cursor_right => {
            const amount = if (iter.next()) |arg| @max(arg.first, 1) else 1;
            self.term.moveCursor(amount, .right);
        },
        csi_ops.move_cursor_left => {
            const amount = if (iter.next()) |arg| @max(arg.first, 1) else 1;
            self.term.moveCursor(amount, .left);
        },
        csi_ops.move_cursor_beginning_next_line => {
            self.term.moveCursorBeginningNextLine();
        },
        csi_ops.move_cursor_beginning_previous_line => {
            self.term.moveCursorBeginningPreviousLine();
        },
        csi_ops.move_cursor_to_column => {
            const col = if (iter.next()) |arg| arg.first -| 1 else 0;
            self.term.moveCursorToColumn(col);
        },
        csi_ops.delete => {
            const arg = if (iter.next()) |arg| @max(arg.first, 1) else 1;
            try self.term.delete(arg);
        },
        csi_ops.sco_save_cursor => self.term.scoSave(),
        csi_ops.sco_restore_cursor => self.term.scoRestore(),
        csi_ops.erase => {
            const arg = if (iter.next()) |arg| arg.first else 0;
            switch (arg) {
                0 => try self.term.eraseEndScreen(),
                1 => try self.term.eraseBeginScreen(),
                2 => self.term.eraseAllScreen(),
                3 => self.term.eraseAllScreenAndScrollback(),
                else => {},
            }
        },
        csi_ops.erase_line => {
            const arg = if (iter.next()) |arg| arg.first else 0;
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

pub fn parseOSC(self: *Ansi, input: []const u8) bool {
    if (input.len < 3) return false;
    if (std.mem.startsWith(u8, input, "0;")) {
        self.platform.setTitle(input[2..]);
        return true;
    }
    return false;
}

fn parseText(self: *Ansi, text: []const u8) usize {
    var iter = Graphemes.iterator(text);
    var cursor: usize = 0;
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            log.debug("fail to parse text: {s}", .{text[cursor..]});
            return text.len - cursor;
        }
        self.term.insert(bytes, @intCast(grapheme.displayWidth(text))) catch unreachable;
        cursor += bytes.len;
    }
    log.debug("text parsed: {s}", .{text});
    return 0;
}

fn simdIndexOfAnyInRange(haystack: []const u8, start: u8, end: u8) ?usize {
    var count: usize = 0;
    if (std.simd.suggestVectorLength(u8)) |block_len| {
        const Block = @Vector(block_len, u8);
        const Mask = @Vector(block_len, bool);
        while (count + block_len <= haystack.len) : (count += block_len) {
            const block: Block = haystack[count..][0..block_len].*;
            var mask: Mask = block >= @as(Block, @splat(start));
            mask &= block < @as(Block, @splat(end));
            if (std.simd.firstTrue(mask)) |index| {
                return count + index;
            }
        }
    }
    if (count < haystack.len) {
        for (haystack[count..], count..) |v, index| {
            if (v >= start and v < end) {
                return index;
            }
        }
    }
    return null;
}

fn simdIndexOfAny(haystack: []const u8, comptime needles: []const u8) ?usize {
    var count: usize = 0;
    if (std.simd.suggestVectorLength(u8)) |block_len| {
        const Block = @Vector(block_len, u8);
        const Mask = @Vector(block_len, bool);
        while (count + block_len <= haystack.len) : (count += block_len) {
            const block: Block = haystack[count..][0..block_len].*;
            var mask: Mask = @splat(false);
            inline for (needles) |needle| {
                mask |= block == @as(Block, @splat(needle));
            }
            if (std.simd.firstTrue(mask)) |index| {
                return count + index;
            }
        }
    }
    if (count < haystack.len) {
        for (haystack[count..], count..) |v, index| {
            inline for (needles) |needle| {
                if (v == needle) {
                    return index;
                }
            }
        }
    }
    return null;
}

fn simdIndexOfControl(haystack: []const u8) ?usize {
    var count: usize = 0;
    if (std.simd.suggestVectorLength(u8)) |block_len| {
        const Block = @Vector(block_len, u8);
        const Mask = @Vector(block_len, bool);
        while (count + block_len <= haystack.len) : (count += block_len) {
            const block: Block = haystack[count..][0..block_len].*;
            var mask: Mask = block <= @as(Block, @splat(std.ascii.control_code.us));
            mask |= block == @as(Block, @splat(std.ascii.control_code.del));
            if (std.simd.firstTrue(mask)) |index| {
                return count + index;
            }
        }
    }
    if (count < haystack.len) {
        for (haystack[count..], count..) |v, index| {
            if (std.ascii.isControl(v)) {
                return index;
            }
        }
    }
    return null;
}

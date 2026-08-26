const std = @import("std");

const AllocQueue = @import("core/queue.zig").AllocQueue;
const unicode = @import("unicode.zig");
const Render = @import("Render.zig");
const ARGB = @import("Render.zig").ARGB;

const log = std.log.scoped(.term);

pub const Term = @This();

const scrollback_capacity = 1024 * 64;

pub const Style = struct {
    pub const Underline = struct {
        const Shape = enum {
            none,
            single,
            double,
            curly,
            dotted,
            dashed,
        };
        color: ARGB = .{ .a = 255, .r = 255, .g = 255, .b = 255 },
        shape: Shape = .none,

        pub fn eq(self: *Underline, other: *Underline) bool {
            return self.shape == other.shape and self.color.eq(other.color);
        }
    };

    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    underline: Underline = .{},
    strikethrough: bool = false,
    background: ARGB = .{ .a = 255, .r = 0, .g = 0, .b = 0 },
    foreground: ARGB = .{ .a = 255, .r = 255, .g = 255, .b = 255 },

    pub fn eq(self: Style, other: Style) bool {
        return !(self.bold and other.bold) and
            self.dim == other.dim and
            self.italic == other.italic and
            self.blink == other.blink and
            self.inverse == other.inverse and
            self.hidden == other.hidden and
            self.strikethrough == other.strikethrough and
            self.underline.eq(other.underline) and
            self.background.eq(other.background) and
            self.foreground.eq(other.foreground);
    }
};

const Cell = struct {
    const Kind = enum {
        normal,
        leading,
        trailing,
    };
    const capacity = 64;

    bytes: [capacity]u8 = [_]u8{0} ** capacity,
    len: usize = 0,
    kind: Kind = .normal,
    style: Style = .{},

    pub fn init(self: *Cell, bytes: []const u8, kind: Kind, style: Style) void {
        const len = @min(capacity, bytes.len);
        @memcpy(self.bytes[0..len], bytes);
        self.len = len;
        self.kind = kind;
        self.style = style;
    }

    pub fn empty() Cell {
        var cell: Cell = undefined;
        cell.init(" ", .normal, .{});
        return cell;
    }

    pub fn content(self: *const Cell) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Row = struct {
    cells: []Cell = undefined,
    len: usize = 0,
    wrapped: bool = false,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Row {
        const row = Row{ .cells = try allocator.alloc(Cell, capacity) };
        @memset(row.cells, Cell.empty());
        return row;
    }

    pub fn deinit(self: *const Row, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
    }

    pub fn insert(self: *Row, index: usize, bytes: []const u8, char_width: u32) void {
        const start = index;
        const end = index + char_width;
        std.debug.assert(end <= self.cells.len);
        self.clearMultiCellChar(start);
        self.clearMultiCellChar(end - 1);
        for (self.cells[start..end], 0..) |*cell, i| {
            if (char_width <= 1) {
                cell.init(bytes, .normal, .{});
            } else {
                if (i == 0) {
                    cell.init(bytes, .leading, .{});
                } else {
                    cell.init(" ", .trailing, .{});
                }
            }
        }

        self.len = @max(end, self.len);
    }

    pub fn scrollLeft(self: *Row, index: usize, amount: usize) !void {
        std.debug.assert(index < self.cells.len);
        if (index >= self.len) return;

        const dest_start = @min(index + amount, self.cells.len);
        const dest_end = self.cells.len;
        const src_start = index;
        const src_end = src_start + (dest_end - dest_start);

        if (self.cells[src_start].kind == .trailing) {
            self.clearMultiCellChar(src_start);
        }
        self.clearMultiCellChar(src_end - 1);

        const src = self.cells[src_start..src_end];
        const dest = self.cells[dest_start..dest_end];

        @memmove(dest, src);
        @memset(self.cells[src_start..dest_start], Cell.empty());

        self.len += amount;
    }

    pub fn delete(self: *Row, index: usize, amount: usize) void {
        std.debug.assert(index < self.cells.len);
        if (index >= self.len) return;
        const real_amount = @min(self.len - index, amount);

        const dest_start = index;
        const dest_end = self.len - real_amount;

        self.clearMultiCellChar(dest_start);
        self.clearMultiCellChar(dest_end - 1);

        const dest = self.cells[dest_start..dest_end];
        const src = self.cells[dest_start + real_amount .. self.len];

        @memmove(dest, src);
        @memset(self.cells[dest_end..], Cell.empty());

        self.len -= real_amount;
    }

    pub fn eraseBegin(self: *Row, index: usize) void {
        std.debug.assert(index < self.cells.len);
        self.clearMultiCellChar(index);
        @memset(self.cells[0 .. index + 1], Cell.empty());
    }

    pub fn eraseEnd(self: *Row, index: usize) void {
        std.debug.assert(index < self.cells.len);
        if (index >= self.len) return;
        self.clearMultiCellChar(index);
        @memset(self.cells[index..], Cell.empty());

        self.len = index;
    }

    pub fn eraseAll(self: *Row) void {
        @memset(self.cells, Cell.empty());

        self.len = 0;
    }

    fn clearMultiCellChar(self: *const Row, index: usize) void {
        std.debug.assert(index < self.cells.len);
        if (self.cells[index].kind == .normal) return;
        var i: i64 = @intCast(index);
        while (i >= 0) : (i -= 1) {
            const kind = self.cells[@intCast(i)].kind;
            self.cells[@intCast(i)] = Cell.empty();
            if (kind == .leading) break;
        }
        i = @intCast(index + 1);
        while (i < self.cells.len) : (i += 1) {
            if (self.cells[@intCast(i)].kind != .trailing) break;
            self.cells[@intCast(i)] = Cell.empty();
        }
    }
};

const Cursor = struct {
    x: usize = 0,
    y: usize = 0,
    wrap_pending: bool = false,
};

allocator: std.mem.Allocator,

width: usize,
height: usize,
style: Style = .{},
cursor: Cursor = .{},
dec_cursor: Cursor = .{},
sco_cursor: Cursor = .{},
rows: AllocQueue(Row),
scrollback: AllocQueue(Row),
need_redraw: bool = false,

pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Term {
    var self = Term{
        .allocator = allocator,
        .rows = try .init(allocator, height),
        .scrollback = try .init(allocator, scrollback_capacity),
        .width = width,
        .height = height,
    };
    while (!self.rows.isFull()) {
        self.rows.putBack(try .init(allocator, width)) catch unreachable;
    }
    return self;
}

pub fn deinit(self: *Term) void {
    var iter = self.rows.iterator();
    while (iter.next()) |row| {
        row.deinit(self.allocator);
    }
    iter = self.scrollback.iterator();
    while (iter.next()) |row| {
        row.deinit(self.allocator);
    }
    self.scrollback.deinit();
    self.rows.deinit();
}

const WindowIterator = struct {
    pub const Window = struct { cells: []const Cell, offset: usize };

    cells: []const Cell = undefined,
    width: usize = 0,
    i: usize = 0,

    pub fn init(cells: []const Cell, width: usize) WindowIterator {
        return .{ .cells = cells, .width = width };
    }

    pub fn next(self: *WindowIterator) ?Window {
        var row_width: usize = 0;
        const start = self.i;
        while (self.i < self.cells.len) {
            var j = self.i + 1;
            while (j < self.cells.len and self.cells[j].kind == .trailing) {
                j += 1;
            }
            const char_width = j - self.i;
            row_width += char_width;
            if (row_width > self.width) {
                break;
            }
            self.i = j;
        }
        if (start != self.i) {
            return .{
                .cells = self.cells[start..self.i],
                .offset = start,
            };
        }
        return null;
    }
};

pub fn resize(self: *Term, width: usize, height: usize) !void {
    var old_rows = self.rows;
    defer {
        var iter = old_rows.iterator();
        while (iter.next()) |row| {
            row.deinit(self.allocator);
        }
        old_rows.deinit();
    }

    self.need_redraw = true;
    self.rows = try AllocQueue(Row).init(self.allocator, height);
    while (!self.rows.isFull()) {
        self.rows.putBack(try .init(self.allocator, width)) catch unreachable;
    }

    var new_cursor: ?Cursor = null;
    var cursor_offset: ?usize = null;
    var accum: std.ArrayList(Cell) = .empty;
    defer accum.deinit(self.allocator);

    var new_row_index: usize = 0;
    for (0..self.height) |old_row_index| {
        const old_row = old_rows.getPtr(old_row_index).?;
        if (old_row_index == self.cursor.y) {
            cursor_offset = accum.items.len + self.cursor.x;
        }
        if (old_row.wrapped) {
            try accum.appendSlice(self.allocator, old_row.cells[0..old_row.len]);
        } else if (old_row.len == 0) {
            new_row_index = @min(height, new_row_index + 1);
        } else {
            try accum.appendSlice(self.allocator, old_row.cells[0..old_row.len]);
            var window_iter = WindowIterator.init(accum.items, width);
            var window_index: usize = 0;
            while (window_iter.next()) |window| : (window_index += 1) {
                if (window_index > 0) {
                    self.rows.getPtr(new_row_index - 1).?.wrapped = true;
                }
                if (new_row_index >= height) {
                    try self.scroll();
                    if (new_cursor) |*nc| {
                        nc.y -|= 1;
                    }
                    new_row_index -= 1;
                }
                var new_row = self.rows.getPtr(new_row_index).?;
                @memcpy(new_row.cells[0..window.cells.len], window.cells);
                new_row.len = window.cells.len;
                new_row_index += 1;

                const window_start = window.offset;
                const window_end = window_start + width;

                if (cursor_offset) |offset| {
                    if (offset >= window_start and offset < window_end) {
                        const x = offset - window_start;
                        new_cursor = .{
                            .x = x,
                            .y = new_row_index - 1,
                            .wrap_pending = self.cursor.wrap_pending and x == width - 1,
                        };
                    }
                }
            }
            accum.clearRetainingCapacity();
        }
    }

    self.width = width;
    self.height = height;
    self.cursor = new_cursor orelse .{
        .x = @min(self.cursor.x, width - 1),
        .y = @min(self.cursor.y, height - 1),
        .wrap_pending = self.cursor.wrap_pending and @min(self.cursor.x, width - 1) == width - 1,
    };
}

fn scroll(self: *Term) !void {
    if (self.rows.takeFront()) |row| {
        if (self.scrollback.isFull()) {
            const deleted = self.scrollback.takeBack().?;
            deleted.deinit(self.allocator);
        }
        self.scrollback.putBack(row) catch unreachable;
        self.rows.putBack(try .init(self.allocator, self.width)) catch unreachable;
    }
}

pub fn lineFeed(self: *Term) !void {
    self.need_redraw = true;
    const y = self.cursor.y + 1;
    if (y >= self.height) {
        try self.scroll();
    }
    self.setCursor(self.cursor.x, y, false);
}

pub fn carriageReturn(self: *Term) void {
    self.need_redraw = true;
    self.setCursor(0, self.cursor.y, false);
}

pub fn insert(self: *Term, bytes: []const u8, char_width: u32) !void {
    self.need_redraw = true;
    if (self.cursor.wrap_pending or self.width - self.cursor.x < char_width) {
        if (self.rows.getPtr(self.cursor.y)) |row| {
            row.wrapped = true;
        }
        const y = self.cursor.y + 1;
        if (y >= self.height) {
            try self.scroll();
        }
        self.setCursor(0, y, false);
    }

    const row = self.rows.getPtr(self.cursor.y).?;
    row.insert(self.cursor.x, bytes, char_width);

    const x = self.cursor.x + char_width;
    const y = self.cursor.y;
    self.setCursor(x, y, x >= self.width);
}

pub fn scrollLeft(self: *Term, amount: usize) !void {
    if (self.rows.len <= self.cursor.y) return;
    self.need_redraw = true;
    const row = self.rows.getPtr(self.cursor.y).?;
    try row.scrollLeft(self.cursor.x, amount);
}

pub fn delete(self: *Term, amount: usize) !void {
    if (self.rows.len <= self.cursor.y) return;
    self.need_redraw = true;
    const row = self.rows.getPtr(self.cursor.y).?;
    row.delete(self.cursor.x, amount);
}

pub const Direction = enum {
    up,
    down,
    left,
    right,
};

pub fn moveCursor(self: *Term, amount: usize, direction: Direction) void {
    self.need_redraw = true;
    switch (direction) {
        .up => self.setCursor(self.cursor.x, self.cursor.y -| amount, false),
        .down => self.setCursor(self.cursor.x, self.cursor.y + amount, false),
        .left => self.setCursor(self.cursor.x -| amount, self.cursor.y, false),
        .right => self.setCursor(self.cursor.x + amount, self.cursor.y, false),
    }
}

pub fn moveCursorBeginningNextLine(self: *Term) void {
    self.need_redraw = true;
    self.setCursor(0, self.cursor.y + 1, false);
}

pub fn moveCursorBeginningPreviousLine(self: *Term) void {
    self.need_redraw = true;
    self.setCursor(0, self.cursor.y -| 1, false);
}

pub fn moveCursorToColumn(self: *Term, col: usize) void {
    self.need_redraw = true;
    self.setCursor(col, self.cursor.y, false);
}

pub fn setCursor(self: *Term, x: usize, y: usize, wrap_pending: bool) void {
    self.need_redraw = true;
    const cx = std.math.clamp(x, 0, self.width - 1);
    const cy = std.math.clamp(y, 0, self.height - 1);
    self.cursor = .{ .x = cx, .y = cy, .wrap_pending = wrap_pending };
}

pub fn scoSave(self: *Term) void {
    self.sco_cursor = self.cursor;
}

pub fn scoRestore(self: *Term) void {
    self.need_redraw = true;
    self.cursor = self.sco_cursor;
}

pub fn decSave(self: *Term) void {
    self.dec_cursor = self.cursor;
}

pub fn decRestore(self: *Term) void {
    self.need_redraw = true;
    self.cursor = self.dec_cursor;
}

pub fn eraseEndScreen(self: *Term) !void {
    if (self.rows.len <= self.cursor.y) return;
    self.need_redraw = true;
    var first_row = self.rows.getPtr(self.cursor.y).?;
    first_row.eraseEnd(self.cursor.x);
    for (self.cursor.y + 1..self.rows.len) |i| {
        const row = self.rows.getPtr(i).?;
        row.wrapped = false;
        row.eraseAll();
    }
}

pub fn eraseBeginScreen(self: *Term) !void {
    self.need_redraw = true;
    var row = self.rows.getPtr(@min(self.cursor.y, self.rows.len - 1)).?;
    row.eraseBegin(self.cursor.x);
    for (0..@min(self.cursor.y, self.rows.len)) |i| {
        row = self.rows.getPtr(i).?;
        row.wrapped = false;
        row.eraseAll();
    }
}

pub fn eraseAllScreen(self: *Term) void {
    self.need_redraw = true;
    var iter = self.rows.iterator();
    while (iter.next()) |row| {
        row.wrapped = false;
        row.eraseAll();
    }
}

pub fn eraseAllScreenAndScrollback(self: *Term) void { // TODO:
    self.need_redraw = true;
    var iter = self.rows.iterator();
    while (iter.next()) |row| {
        row.wrapped = false;
        row.eraseAll();
    }
    iter = self.scrollback.iterator();
    while (self.scrollback.takeBack()) |row| {
        row.deinit(self.allocator);
    }
}

pub fn eraseEndLine(self: *Term) !void {
    if (self.rows.len <= self.cursor.y) return;
    self.need_redraw = true;
    var row = self.rows.getPtr(self.cursor.y).?;
    row.eraseEnd(self.cursor.x);
}

pub fn eraseBeginLine(self: *Term) !void {
    if (self.rows.len <= self.cursor.y) return;
    self.need_redraw = true;
    var row = self.rows.getPtr(self.cursor.y).?;
    row.eraseBegin(self.cursor.x);
}

pub fn eraseAllLine(self: *Term) !void {
    if (self.rows.len <= self.cursor.y) return;
    self.need_redraw = true;
    var row = self.rows.getPtr(self.cursor.y).?;
    row.eraseAll();
}

pub fn draw(
    self: *Term,
    allocator: std.mem.Allocator,
    render: *Render,
    font: Render.ShapeTextInfo.Font,
    cell_width: u32,
    cell_height: u32,
) !void {
    self.need_redraw = false;
    var allocating = std.Io.Writer.Allocating.init(allocator);
    var y_offset: i32 = 0;
    var iter = self.rows.iterator();
    while (iter.next()) |row| {
        allocating.clearRetainingCapacity();
        for (row.cells[0..row.len]) |*cell| {
            if (cell.kind != .trailing) {
                try allocating.writer.writeAll(cell.content());
            }
        }
        const text = allocating.written();
        if (!std.mem.eql(u8, text, "")) {
            const shaped = try render.allocShapeText(allocator, .{ .font = font, .text = text });
            try render.drawShappedText(.{
                .shaped_text = shaped,
                .color = @bitCast(@as(u32, 0xFFFFFFFF)),
                .start = .{ .x = 0, .y = y_offset },
            });
        }
        y_offset += @intCast(cell_height);
    }
    try render.drawRect(.{
        .x = @intCast(self.cursor.x * cell_width),
        .y = @intCast(self.cursor.y * cell_height),
        .width = cell_width,
        .height = cell_height,
    }, @bitCast(@as(u32, 0xFFFFFFFF)));
}

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

    pub const Blink = enum {
        static,
        slow,
        fast,
    };

    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    blink: Blink = .static,
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
    dirty: bool = true,
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
        self.dirty = true;
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
        self.dirty = true;
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
        self.dirty = true;
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
        self.dirty = true;
        self.clearMultiCellChar(index);
        @memset(self.cells[0 .. index + 1], Cell.empty());
    }

    pub fn eraseEnd(self: *Row, index: usize) void {
        std.debug.assert(index < self.cells.len);
        self.dirty = true;
        if (index >= self.len) return;
        self.clearMultiCellChar(index);
        @memset(self.cells[index..], Cell.empty());

        self.len = index;
    }

    pub fn eraseAll(self: *Row) void {
        self.dirty = true;
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
cell_width: usize,
cell_height: usize,

render: *Render,
image: Render.Image,

style: Style = .{},

cursor: Cursor = .{},
dec_cursor: Cursor = .{},
sco_cursor: Cursor = .{},

screen: AllocQueue(Row),
scrollback: AllocQueue(Row),

need_redraw: bool = false,

pub fn init(
    allocator: std.mem.Allocator,
    render: *Render,
    width: usize,
    height: usize,
    cell_width: usize,
    cell_height: usize,
) !Term {
    var self = Term{
        .allocator = allocator,
        .render = render,
        .image = try render.createImage(cell_width * width, cell_height * height),
        .screen = try .init(allocator, height),
        .scrollback = try .init(allocator, scrollback_capacity),
        .width = width,
        .height = height,
        .cell_width = cell_width,
        .cell_height = cell_height,
    };
    try self.render.fill(self.image, @bitCast(@as(u32, 0xFF101010)));
    while (!self.screen.isFull()) {
        self.screen.putBack(try .init(allocator, width)) catch unreachable;
    }
    return self;
}

pub fn deinit(self: *Term) void {
    self.render.destroyImage(self.image) catch unreachable;
    var iter = self.screen.iterator();
    while (iter.next()) |row| {
        row.deinit(self.allocator);
    }
    iter = self.scrollback.iterator();
    while (iter.next()) |row| {
        row.deinit(self.allocator);
    }
    self.scrollback.deinit();
    self.screen.deinit();
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

const RowIterator = struct {
    const Result = struct {
        row: *Row,
        cursor_offset: ?usize = null,
        dec_cursor_offset: ?usize = null,
        sco_cursor_offset: ?usize = null,
    };

    cursor: Cursor,
    dec_cursor: Cursor,
    sco_cursor: Cursor,
    screen_iter: AllocQueue(Row).Iterator,
    scrollback_iter: AllocQueue(Row).Iterator,
    i: usize = 0,

    pub fn init(self: *RowIterator, term: *const Term) void {
        self.* = .{
            .cursor = term.cursor,
            .dec_cursor = term.dec_cursor,
            .sco_cursor = term.sco_cursor,
            .screen_iter = term.screen.iterator(),
            .scrollback_iter = term.scrollback.iterator(),
        };
    }

    pub fn next(self: *RowIterator) ?Result {
        if (self.scrollback_iter.next()) |row| {
            return .{ .row = row };
        }
        if (self.screen_iter.next()) |row| {
            const result = Result{
                .row = row,
                .cursor_offset = if (self.i == self.cursor.y) self.cursor.x else null,
                .dec_cursor_offset = if (self.i == self.dec_cursor.y) self.dec_cursor.x else null,
                .sco_cursor_offset = if (self.i == self.sco_cursor.y) self.sco_cursor.x else null,
            };
            self.i += 1;
            return result;
        }
        return null;
    }
};

const VirtualRow = struct {
    cells: std.ArrayList(Cell) = .empty,
    wrapped: bool = false,
    cursor_offset: ?usize = null,
    dec_cursor_offset: ?usize = null,
    sco_cursor_offset: ?usize = null,

    pub fn toRow(self: *const VirtualRow, allocator: std.mem.Allocator, width: usize) !Row {
        var row = try Row.init(allocator, width);
        @memcpy(row.cells[0..self.cells.items.len], self.cells.items);
        row.wrapped = self.wrapped;
        row.len = self.cells.items.len;
        row.dirty = true;
        return row;
    }

    pub fn clear(self: *VirtualRow) void {
        self.cells.clearRetainingCapacity();
        self.wrapped = false;
        self.cursor_offset = null;
        self.dec_cursor_offset = null;
        self.sco_cursor_offset = null;
    }
};

pub fn resize(self: *Term, width: usize, height: usize) !void {
    self.need_redraw = true;

    self.render.destroyImage(self.image) catch unreachable;
    self.image = try self.render.createImage(self.cell_width * width, self.cell_height * height);
    try self.render.fill(self.image, @bitCast(@as(u32, 0xFF101010)));

    var iter: RowIterator = undefined;
    iter.init(self);

    var virtual_row: VirtualRow = .{};
    defer virtual_row.cells.deinit(self.allocator);
    var rows: std.ArrayList(VirtualRow) = .empty;
    defer rows.deinit(self.allocator);

    while (iter.next()) |result| {
        const old_row = result.row;
        if (result.cursor_offset) |offset| {
            virtual_row.cursor_offset = virtual_row.cells.items.len + offset;
        }
        if (old_row.wrapped) {
            try virtual_row.cells.appendSlice(self.allocator, old_row.cells[0..old_row.len]);
        } else if (old_row.len == 0) {
            try rows.append(self.allocator, .{});
        } else {
            try virtual_row.cells.appendSlice(self.allocator, old_row.cells[0..old_row.len]);
            var window_iter = WindowIterator.init(virtual_row.cells.items, width);
            var window_index: usize = 0;
            while (window_iter.next()) |window| : (window_index += 1) {
                if (window_index > 0) {
                    rows.items[rows.items.len - 1].wrapped = true;
                }

                var new_row = VirtualRow{};
                try new_row.cells.appendSlice(self.allocator, window.cells);

                const window_start = window.offset;
                const window_end = window_start + width;

                if (virtual_row.cursor_offset) |offset| {
                    if (offset >= window_start and offset < window_end) {
                        new_row.cursor_offset = offset - window_start;
                    }
                }

                try rows.append(self.allocator, new_row);
            }
            virtual_row.clear();
        }
    }

    while (rows.getLastOrNull()) |row| {
        if (row.cells.items.len != 0) break;
        var removed = rows.pop().?;
        removed.cells.deinit(self.allocator);
    }

    const screen_start = rows.items.len -| height;
    const scrollback_slice = rows.items[0..screen_start];
    const screen_slice = rows.items[screen_start..];

    var queue_iter = self.scrollback.iterator();
    while (queue_iter.next()) |row| {
        row.deinit(self.allocator);
    }
    self.scrollback.deinit();

    queue_iter = self.screen.iterator();
    while (queue_iter.next()) |row| {
        row.deinit(self.allocator);
    }
    self.screen.deinit();

    self.scrollback = try .init(self.allocator, scrollback_capacity);
    for (scrollback_slice) |*current_virtual_row| {
        if (self.scrollback.isFull()) {
            const removed = self.scrollback.takeFront().?;
            removed.deinit(self.allocator);
        }
        self.scrollback.putBack(try current_virtual_row.toRow(self.allocator, width)) catch unreachable;
        current_virtual_row.cells.deinit(self.allocator);
    }

    self.screen = try .init(self.allocator, height);
    for (screen_slice, 0..) |*current_virtual_row, y| {
        if (current_virtual_row.cursor_offset) |x| {
            self.cursor = .{
                .x = x,
                .y = y,
                .wrap_pending = self.cursor.wrap_pending and x == width - 1,
            };
        }
        self.screen.putBack(try current_virtual_row.toRow(self.allocator, width)) catch unreachable;
        current_virtual_row.cells.deinit(self.allocator);
    }
    while (!self.screen.isFull()) {
        self.screen.putBack(try .init(self.allocator, width)) catch unreachable;
    }

    self.width = width;
    self.height = height;
}

fn scroll(self: *Term) !void {
    if (self.screen.takeFront()) |row| {
        if (self.scrollback.isFull()) {
            const deleted = self.scrollback.takeBack().?;
            deleted.deinit(self.allocator);
        }
        self.scrollback.putBack(row) catch unreachable;
        self.screen.putBack(try .init(self.allocator, self.width)) catch unreachable;
        var iter = self.screen.iterator();
        while (iter.next()) |current| {
            current.dirty = true;
        }
        self.need_redraw = true;
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
        if (self.screen.getPtr(self.cursor.y)) |row| {
            row.wrapped = true;
        }
        const y = self.cursor.y + 1;
        if (y >= self.height) {
            try self.scroll();
        }
        self.setCursor(0, y, false);
    }

    const row = self.screen.getPtr(self.cursor.y).?;
    row.insert(self.cursor.x, bytes, char_width);

    const x = self.cursor.x + char_width;
    const y = self.cursor.y;
    self.setCursor(x, y, x >= self.width);
}

pub fn scrollLeft(self: *Term, amount: usize) !void {
    if (self.screen.len <= self.cursor.y) return;
    self.need_redraw = true;
    const row = self.screen.getPtr(self.cursor.y).?;
    try row.scrollLeft(self.cursor.x, amount);
}

pub fn delete(self: *Term, amount: usize) !void {
    if (self.screen.len <= self.cursor.y) return;
    self.need_redraw = true;
    const row = self.screen.getPtr(self.cursor.y).?;
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
    self.screen.getPtr(self.cursor.y).?.dirty = true;
    const cx = std.math.clamp(x, 0, self.width - 1);
    const cy = std.math.clamp(y, 0, self.height - 1);
    self.screen.getPtr(cy).?.dirty = true;
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
    if (self.screen.len <= self.cursor.y) return;
    self.need_redraw = true;
    var first_row = self.screen.getPtr(self.cursor.y).?;
    first_row.eraseEnd(self.cursor.x);
    for (self.cursor.y + 1..self.screen.len) |i| {
        const row = self.screen.getPtr(i).?;
        row.wrapped = false;
        row.eraseAll();
    }
}

pub fn eraseBeginScreen(self: *Term) !void {
    self.need_redraw = true;
    var row = self.screen.getPtr(@min(self.cursor.y, self.screen.len - 1)).?;
    row.eraseBegin(self.cursor.x);
    for (0..@min(self.cursor.y, self.screen.len)) |i| {
        row = self.screen.getPtr(i).?;
        row.wrapped = false;
        row.eraseAll();
    }
}

pub fn eraseAllScreen(self: *Term) void {
    self.need_redraw = true;
    var iter = self.screen.iterator();
    while (iter.next()) |row| {
        row.wrapped = false;
        row.eraseAll();
    }
}

pub fn eraseAllScreenAndScrollback(self: *Term) void { // TODO:
    self.need_redraw = true;
    var iter = self.screen.iterator();
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
    if (self.screen.len <= self.cursor.y) return;
    self.need_redraw = true;
    var row = self.screen.getPtr(self.cursor.y).?;
    row.eraseEnd(self.cursor.x);
}

pub fn eraseBeginLine(self: *Term) !void {
    if (self.screen.len <= self.cursor.y) return;
    self.need_redraw = true;
    var row = self.screen.getPtr(self.cursor.y).?;
    row.eraseBegin(self.cursor.x);
}

pub fn eraseAllLine(self: *Term) !void {
    if (self.screen.len <= self.cursor.y) return;
    self.need_redraw = true;
    var row = self.screen.getPtr(self.cursor.y).?;
    row.eraseAll();
}

pub fn draw(self: *Term, allocator: std.mem.Allocator, font: Render.DrawTextInfo.Font) !void {
    self.need_redraw = false;
    var allocating = std.Io.Writer.Allocating.init(allocator);
    var y_offset: i32 = 0;
    var iter = self.screen.iterator();
    while (iter.next()) |row| {
        if (row.dirty) {
            allocating.clearRetainingCapacity();
            row.dirty = false;
            try self.render.drawRect(self.image, .{
                .x = 0,
                .y = y_offset,
                .width = @intCast(self.width * self.cell_width),
                .height = @intCast(self.cell_height),
            }, @bitCast(@as(u32, 0xFF101010)));
            for (row.cells[0..row.len]) |*cell| {
                if (cell.kind != .trailing) {
                    try allocating.writer.writeAll(cell.content());
                }
            }
            const text = allocating.written();
            if (!std.mem.eql(u8, text, "")) {
                try self.render.drawText(self.image, .{
                    .font = font,
                    .text = text,
                    .color = @bitCast(@as(u32, 0xFFFFFFFF)),
                    .start = .{ .x = 0, .y = y_offset },
                });
            }
        }
        y_offset += @intCast(self.cell_height);
    }
    try self.render.drawRect(self.image, .{
        .x = @intCast(self.cursor.x * self.cell_width),
        .y = @intCast(self.cursor.y * self.cell_height),
        .width = @intCast(self.cell_width),
        .height = @intCast(self.cell_height),
    }, @bitCast(@as(u32, 0xFFFFFFFF)));
}

const std = @import("std");
const emoji = @import("emoji");
const c = @import("c");

pub const isEmoji = emoji.isEmoji;

pub const GraphemeIter = struct {
    text: []const u8,
    i: u64 = 0,
    state: i32 = 0,
    allocator: ?std.mem.Allocator = null,
    accum: std.ArrayList(u21) = .empty,

    pub fn init(allocator: std.mem.Allocator, text: []const u8) GraphemeIter {
        return .{
            .text = text,
            .allocator = allocator,
        };
    }

    pub fn bufInit(buf: []u21, text: []const u8) GraphemeIter {
        return .{
            .text = text,
            .accum = .initBuffer(buf),
        };
    }

    pub fn deinit(self: *GraphemeIter) void {
        if (self.allocator) |allocator| self.accum.deinit(allocator);
    }

    pub const Result = struct {
        rune: []const u8,
        grapheme: []const u21,
    };

    pub fn next(self: *GraphemeIter) !?Result {
        const start = self.i;
        self.accum.clearRetainingCapacity();
        while (self.nextCodepoint()) |current_codepoint| {
            if (self.allocator) |allocator| {
                try self.accum.append(allocator, @intCast(current_codepoint));
            } else {
                try self.accum.appendBounded(@intCast(current_codepoint));
            }
            if (self.peekCodepoint()) |next_codepoint| {
                if (c.utf8proc_grapheme_break_stateful(current_codepoint, next_codepoint, &self.state)) {
                    return .{
                        .rune = self.text[start..self.i],
                        .grapheme = self.accum.items,
                    };
                }
            } else {
                return .{
                    .rune = self.text[start..],
                    .grapheme = self.accum.items,
                };
            }
        }
        return null;
    }

    fn nextCodepoint(self: *GraphemeIter) ?i32 {
        var codepoint: i32 = undefined;
        const readed = c.utf8proc_iterate(
            self.text.ptr + self.i,
            @intCast(self.text.len - self.i),
            &codepoint,
        );
        if (readed <= 0) return null;
        self.i += @intCast(readed);
        return codepoint;
    }

    fn peekCodepoint(self: *GraphemeIter) ?i32 {
        var codepoint: i32 = undefined;
        const readed = c.utf8proc_iterate(
            self.text.ptr + self.i,
            @intCast(self.text.len - self.i),
            &codepoint,
        );
        if (readed <= 0) return null;
        return codepoint;
    }
};

pub fn charWidth(grapheme: []const u21) u32 {
    if (isEmoji(grapheme)) return 2;
    return @intCast(c.utf8proc_charwidth(grapheme[0]));
}

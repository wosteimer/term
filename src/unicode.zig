const std = @import("std");
const emoji = @import("emoji");
const c = @import("c");

pub const isEmoji = emoji.isEmoji;

pub const GraphemeIter = struct {
    const max_grapheme_len = 64;

    pub const Grapheme = struct { bytes: []const u8, codepoints: []const u21 };

    const Codepoint = struct { codepoint: u21, len: usize };

    text: []const u8,
    state: i32 = 0,
    i: usize = 0,
    buf_accum: [max_grapheme_len]u21 = undefined,
    accum: std.ArrayList(u21) = .empty,

    pub fn init(self: *GraphemeIter, text: []const u8) void {
        self.* = .{ .text = text, .accum = .initBuffer(&self.buf_accum) };
    }

    pub fn next(self: *GraphemeIter) !?Grapheme {
        self.accum.clearRetainingCapacity();
        const start = self.i;
        var end = self.i;
        while (try self.takeCodepoint()) |current_codepoint| {
            self.accum.appendAssumeCapacity(current_codepoint.codepoint);
            end += current_codepoint.len;
            if (try self.peekCodepoint()) |next_codepoint| {
                if (c.utf8proc_grapheme_break_stateful(current_codepoint.codepoint, next_codepoint.codepoint, &self.state)) {
                    return .{ .bytes = self.text[start..end], .codepoints = self.accum.items };
                }
            }
        }
        if (self.accum.items.len == 0) return null;
        if (c.utf8proc_grapheme_break_stateful(self.accum.getLast(), 0, &self.state)) {
            return .{ .bytes = self.text[start..end], .codepoints = self.accum.items };
        }
        return null;
    }

    fn takeCodepoint(self: *GraphemeIter) !?Codepoint {
        if (try self.peekCodepoint()) |entry| {
            self.i += entry.len;
            return entry;
        }
        self.i = self.text.len;
        return null;
    }

    fn peekCodepoint(self: *GraphemeIter) !?Codepoint {
        const buf = self.text[self.i..];
        var codepoint: i32 = undefined;
        const len = c.utf8proc_iterate(buf.ptr, @intCast(buf.len), &codepoint);
        if (len == 0) return null;
        if (len < 0) {
            return error.InvalidBytes;
        }
        return .{ .codepoint = @intCast(codepoint), .len = @intCast(len) };
    }
};

pub fn charWidth(codepoints: []const u21) u32 {
    if (isEmoji(codepoints)) return 2;
    return @intCast(c.utf8proc_charwidth(codepoints[0]));
}

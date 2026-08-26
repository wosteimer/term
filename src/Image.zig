const std = @import("std");

pub const Image = @This();
const Self = @This();

pub const ARGB = packed struct {
    b: u8,
    g: u8,
    r: u8,
    a: u8,

    pub fn eq(self: ARGB, other: ARGB) bool {
        return self.a == other.a and self.r == other.r and self.g == other.g and self.b == other.b;
    }
};

buf: []u32,
witdh: u32,
height: u32,

pub fn fill(self: *Self, color: ARGB) void {
    const vec_len = std.simd.suggestVectorLength(u32) orelse {
        self.fillPixels(color);
        return;
    };
    const color_vec: @Vector(vec_len, u32) = @splat(@bitCast(color));

    const run_len = self.witdh - (self.witdh % vec_len);

    for (0..@intCast(self.height)) |y| {
        var x: usize = 0;
        while (x < run_len) : (x += vec_len) {
            const start = y * self.witdh + x;
            const end = start + vec_len;
            self.buf[start..end][0..vec_len].* = color_vec;
        }

        while (x < self.witdh) : (x += 1) {
            self.buf[y * self.witdh + x] = @bitCast(color);
        }
    }
}

fn fillPixels(self: *Self, color: ARGB) void {
    for (0..@intCast(self.height)) |y| {
        for (0..@intCast(self.witdh)) |x| {
            self.buf[y * self.witdh + x] = @bitCast(color);
        }
    }
}

pub fn fillRect(self: *Self, rect: Rect, color: ARGB) void {}

pub fn composite(self: *Self, position: Point, image: *const Image) void {}

pub const ARGB = packed struct {
    b: u8,
    g: u8,
    r: u8,
    a: u8,

    pub fn eq(self: ARGB, other: ARGB) bool {
        return self.a == other.a and self.r == other.r and self.g == other.g and self.b == other.b;
    }
};

pub const Pallete = struct {
    pub const black = 0;
    pub const red = 1;
    pub const green = 2;
    pub const yellow = 3;
    pub const blue = 4;
    pub const magenta = 5;
    pub const cyan = 6;
    pub const white = 7;
    pub const default = 9;

    pub const init = Pallete{
        .colors_8 = [_]ARGB{
            .{ .a = 255, .r = 0, .g = 0, .b = 0 },
            .{ .a = 255, .r = 128, .g = 0, .b = 0 },
            .{ .a = 255, .r = 0, .g = 128, .b = 0 },
            .{ .a = 255, .r = 128, .g = 128, .b = 0 },
            .{ .a = 255, .r = 0, .g = 0, .b = 128 },
            .{ .a = 255, .r = 128, .g = 0, .b = 128 },
            .{ .a = 255, .r = 0, .g = 128, .b = 128 },
            .{ .a = 255, .r = 192, .g = 192, .b = 192 },
        },

        .colors_16 = [_]ARGB{
            .{ .a = 255, .r = 128, .g = 128, .b = 128 },
            .{ .a = 255, .r = 255, .g = 0, .b = 0 },
            .{ .a = 255, .r = 0, .g = 255, .b = 0 },
            .{ .a = 255, .r = 255, .g = 255, .b = 0 },
            .{ .a = 255, .r = 0, .g = 0, .b = 255 },
            .{ .a = 255, .r = 255, .g = 0, .b = 255 },
            .{ .a = 255, .r = 0, .g = 255, .b = 255 },
            .{ .a = 255, .r = 255, .g = 255, .b = 255 },
        },

        .default_background = .{ .a = 255, .r = 0, .g = 0, .b = 0 },
        .default_foreground = .{ .a = 255, .r = 255, .g = 255, .b = 255 },
    };

    pub const colors_256 = blk: {
        var palette: [256]ARGB = undefined;
        for (0..8) |i| {
            palette[i] = init.colors_8[i];
            palette[i + 8] = init.colors_16[i];
        }
        const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
        var index: usize = 16;
        for (levels) |r| {
            for (levels) |g| {
                for (levels) |b| {
                    palette[index] = .{ .a = 255, .r = r, .g = g, .b = b };
                    index += 1;
                }
            }
        }
        for (0..24) |i| {
            const value = 8 + i * 10;
            palette[232 + i] = .{ .a = 255, .r = value, .g = value, .b = value };
        }
        break :blk palette;
    };

    colors_8: [8]ARGB,
    colors_16: [8]ARGB,

    default_foreground: ARGB,
    default_background: ARGB,
};

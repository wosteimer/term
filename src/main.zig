const std = @import("std");
const Platform = @import("platform").Platform;
const Render = @import("Render");

pub fn main(init: std.process.Init) !void {
    var platform = try Platform.init(init.gpa, init.io);
    defer platform.deinit(init.gpa);
    platform.setTitle("hello world");
    var render = try Render.init(init.gpa, &platform);
    defer render.deinit();

    platform.textInputEnable();
    // var last_frame = std.Io.Timestamp.now(init.io, .real).toMilliseconds();
    // var offset: f32 = 0;
    mainloop: while (true) {
        while (platform.pollEvent()) |ev| {
            switch (ev) {
                .window_close_requested => break :mainloop,
                .text_input_changed => |t| std.debug.print("text: {s}\n", .{t}),
                .text_input_preedit_changed => |t| std.debug.print("preedit: {s}\n", .{t}),
                .key_up => |key_ev| switch (key_ev.key) {
                    .escape => break :mainloop,
                    else => {},
                },
                else => {},
            }
        }
        @memset(platform.getBuffer(), 0xFF000000);
        // const data = platform.getBuffer();
        // const size = platform.getSize();
        // const width: usize, const height: usize = .{ @intCast(size.width), @intCast(size.height) };
        // const now = std.Io.Timestamp.now(init.io, .real).toMilliseconds();
        // const elapsed = now - last_frame;
        // last_frame = now;
        // offset += @as(f32, @floatFromInt(elapsed)) / 1000 * 24;
        // const i_offset: usize = @intFromFloat(@mod(offset, 8));
        // for (0..height) |y| {
        //     for (0..width) |x| {
        //         if (((x + i_offset) + (y + i_offset) / 8 * 8) % 16 < 8) {
        //             data[y * width + x] = 0xFF666666;
        //         } else {
        //             data[y * width + x] = 0xFFEEEEEE;
        //         }
        //     }
        // }

        try render.renderText(.{
            .font = .{ .name = "JetBrains Mono", .size = 16 },
            .text = "hello ==> 😎 你好世界 world",
        });
        platform.present();
    }
}

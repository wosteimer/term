const std = @import("std");

fn hashEmoji(emoji: []const u21) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (emoji) |codepoint| {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, @as(u32, codepoint), .little);
        hasher.update(&buf);
    }
    return hasher.final();
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var input_buf: [1024]u8 = undefined;
    var output_buf: [1024]u8 = undefined;

    const args = try init.minimal.args.toSlice(allocator);
    const output_file_path = args[1];
    const output_file = try std.Io.Dir.cwd().createFile(init.io, output_file_path, .{});
    defer output_file.close(init.io);
    var writer = output_file.writer(init.io, &output_buf);
    var hashes = std.ArrayList(u64).empty;
    for (args[2..]) |arg| {
        const input_file = try std.Io.Dir.openFileAbsolute(init.io, arg, .{ .mode = .read_only });
        defer input_file.close(init.io);
        var input_reader = input_file.reader(init.io, &input_buf);
        const reader = &input_reader.interface;

        while (try reader.takeDelimiter('\n')) |line| {
            if (std.mem.eql(u8, line, "") or std.mem.startsWith(u8, line, "#")) continue;
            if (std.mem.indexOf(u8, line, "..")) |first_end| {
                const first = std.mem.trim(u8, line[0..first_end], &std.ascii.whitespace);
                const second_start = first_end + 2;
                const second_end = std.mem.indexOfScalar(u8, line, ';').?;
                const second = std.mem.trim(u8, line[second_start..second_end], &std.ascii.whitespace);
                for (try std.fmt.parseInt(usize, first, 16)..try std.fmt.parseInt(usize, second, 16) + 1) |codepoint| {
                    try hashes.append(allocator, hashEmoji(&[_]u21{@intCast(codepoint)}));
                }
            } else {
                const end = std.mem.indexOfScalar(u8, line, ';').?;
                var iter = std.mem.splitAny(u8, std.mem.trim(u8, line[0..end], &std.ascii.whitespace), &std.ascii.whitespace);
                var codepoints: [64]u21 = undefined;
                var i: usize = 0;
                while (iter.next()) |hex| {
                    const codepoint = try std.fmt.parseInt(usize, hex, 16);
                    codepoints[i] = @intCast(codepoint);
                    i += 1;
                }
                try hashes.append(allocator, hashEmoji(codepoints[0..i]));
            }
        }
    }
    std.mem.sort(u64, hashes.items, {}, std.sort.asc(u64));
    _ = try writer.interface.write(
        \\ const std = @import("std");
        \\
        \\fn hashEmoji(emoji: []const u21) u64 {
        \\    var hasher = std.hash.Wyhash.init(0);
        \\    for (emoji) |codepoint| {
        \\        var buf: [4]u8 = undefined;
        \\        std.mem.writeInt(u32, &buf, @as(u32, codepoint), .little);
        \\        hasher.update(&buf);
        \\    }
        \\    return hasher.final();
        \\}
        \\ 
        \\pub const hashes = [_]u64{
        \\
        ,
    );
    for (hashes.items) |hash| {
        try writer.interface.print("    0x{x},\n", .{hash});
    }
    _ = try writer.interface.write(
        \\};
        \\
        \\fn compare(hash: u64, current: u64) std.math.Order{
        \\    if(hash == current) return .eq;
        \\    if(hash > current) return .gt;
        \\    return .lt;
        \\}
        \\
        \\pub fn isEmoji(g: []const u21) bool {
        \\    const h = hashEmoji(g);
        \\    return std.sort.binarySearch(u64, &hashes, h, compare) != null;
        \\}
    );
    try writer.interface.flush();
    return std.process.cleanExit(init.io);
}

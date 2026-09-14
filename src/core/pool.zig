const std = @import("std");

pub const Handler = struct {
    index: u32 = 0,
    generation: u32 = 0,
};

pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            value: ?T = null,
            generation: u32 = 0,
            next_free: ?u32 = null,
        };

        entries: []Entry,
        len: u32 = 0,
        capacity: u32,
        free_head: ?u32 = null,

        pub fn init(allocator: std.mem.Allocator, capacity: u32) error{OutOfMemory}!Self {
            const entries = try allocator.alloc(Entry, capacity);
            @memset(entries, .{});
            return .{
                .entries = entries,
                .capacity = capacity,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.entries);
        }

        pub fn create(self: *Self) error{Full}!Handler {
            if (self.free_head) |index| {
                const entry = &self.entries[index];
                self.free_head = entry.next_free;
                return .{
                    .index = index,
                    .generation = entry.generation,
                };
            }
            if (self.len >= self.capacity) return error.Full;
            const index = self.len;
            self.len += 1;

            return .{
                .index = index,
                .generation = 0,
            };
        }

        pub fn destroy(self: *Self, handler: Handler) error{NotAlive}!void {
            const entry = try self.getEntry(handler);
            entry.value = null;
            entry.generation += 1;
            entry.next_free = self.free_head;
            self.free_head = handler.index;
        }

        pub fn getEntry(self: *Self, handler: Handler) error{NotAlive}!*Entry {
            if (!self.isAlive(handler)) return error.NotAlive;
            return &self.entries[handler.index];
        }

        pub fn isAlive(self: *const Self, handler: Handler) bool {
            if (handler.index >= self.len) return false;
            return self.entries[handler.index].generation == handler.generation;
        }
    };
}

test "It is expected that the entry will be reused after being destroyed." {
    var pool = try Pool(u32).init(std.testing.allocator, 10);
    defer pool.deinit(std.testing.allocator);
    const first = try pool.create();
    const second = try pool.create();
    try std.testing.expectEqual(0, first.index);
    try std.testing.expectEqual(0, first.generation);
    try std.testing.expectEqual(1, second.index);
    try std.testing.expectEqual(0, second.generation);

    try pool.destroy(first);

    const new = try pool.create();
    try std.testing.expectEqual(0, new.index);
    try std.testing.expectEqual(1, new.generation);
}

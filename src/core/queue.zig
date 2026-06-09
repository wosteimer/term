const std = @import("std");

pub fn Queue(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        len: usize = 0,
        head: usize = 0,
        tail: usize = 0,

        const Self = @This();
        pub const empty: Self = .{};

        pub fn put(self: *Self, item: T) error{Full}!void {
            if (self.isFull()) return error.Full;
            self.items[self.tail] = item;
            self.len += 1;
            self.tail = (self.tail + 1) % capacity;
        }

        pub fn get(self: *Self) ?T {
            if (isEmpty(self)) return null;
            const result = self.items[self.head];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            return result;
        }

        pub fn isFull(self: *Self) bool {
            return self.len == capacity;
        }

        pub fn isEmpty(self: *Self) bool {
            return self.len == 0;
        }

        pub fn clear(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.len = 0;
        }
    };
}

test "put" {
    const capacity = 8;
    var queue = Queue(usize, capacity).empty;
    for (0..capacity) |i| {
        try queue.put(i);
        try std.testing.expectEqual(i, queue.items[i]);
    }
    try std.testing.expectError(error.Full, queue.put(0));
}

test "get" {
    const capacity = 8;
    var queue = Queue(usize, capacity).empty;
    for (0..capacity) |i| {
        try queue.put(i);
    }
    for (0..capacity) |i| {
        try std.testing.expectEqual(i, queue.get());
    }
    try std.testing.expectEqual(null, queue.get());
}

test "clear" {
    const capacity = 8;
    var queue = Queue(usize, capacity).empty;
    for (0..capacity) |i| {
        try queue.put(i);
    }
    queue.clear();
    try std.testing.expectEqual(0, queue.len);
    try std.testing.expectEqual(0, queue.head);
    try std.testing.expectEqual(0, queue.tail);
}

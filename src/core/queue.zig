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

        pub fn take(self: *Self) ?T {
            if (self.isEmpty()) return null;
            const result = self.items[self.head];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            return result;
        }

        pub fn peek(self: *Self) ?T {
            if (self.isEmpty()) return null;
            return self.items[self.head];
        }

        pub fn get(self: *Self, index: usize) ?T {
            if (index >= self.len) return null;
            return self.items[(self.head + index) % capacity];
        }

        pub fn getPtr(self: *Self, index: usize) ?*T {
            if (index >= self.len) return null;
            return &self.items[(self.head + index) % capacity];
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

        pub const Iterator = struct {
            queue: *const Self,
            i: usize,
            count: usize,

            pub fn next(self: *Iterator) ?*T {
                if (self.count == 0) return null;
                const result = &self.queue.items[self.i];
                self.i = (self.i + 1) % capacity;
                self.count -= 1;
                return result;
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return Iterator{ .queue = self, .i = self.head, .count = self.len };
        }
    };
}

pub fn AllocQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        items: []T,
        capacity: usize = 0,
        len: usize = 0,
        head: usize = 0,
        tail: usize = 0,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            return .{
                .allocator = allocator,
                .capacity = capacity,
                .items = try allocator.alloc(T, capacity),
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
        }

        pub fn putFront(self: *Self, item: T) error{Full}!void {
            if (self.isFull()) return error.Full;
            self.head = @intCast(@mod(@as(i64, @intCast(self.head)) - 1, @as(i64, @intCast(self.capacity))));
            self.items[self.head] = item;
            self.len += 1;
        }

        pub fn putBack(self: *Self, item: T) error{Full}!void {
            if (self.isFull()) return error.Full;
            self.items[self.tail] = item;
            self.len += 1;
            self.tail = (self.tail + 1) % self.capacity;
        }

        pub fn takeFront(self: *Self) ?T {
            if (self.isEmpty()) return null;
            const result = self.items[self.head];
            self.head = (self.head + 1) % self.capacity;
            self.len -= 1;
            return result;
        }

        pub fn takeBack(self: *Self) ?T {
            if (self.isEmpty()) return null;
            self.tail = @intCast(@mod(@as(i64, @intCast(self.tail)) - 1, @as(i64, @intCast(self.capacity))));
            const result = self.items[self.tail];
            self.len -= 1;
            return result;
        }

        pub fn peekFront(self: *Self) ?*T {
            if (self.isEmpty()) return null;
            return &self.items[self.head];
        }

        pub fn peekBack(self: *Self) ?*T {
            if (self.isEmpty()) return null;
            return &self.items[self.tail];
        }

        pub fn get(self: *Self, index: usize) ?T {
            if (index >= self.len) return null;
            return self.items[(self.head + index) % self.capacity];
        }

        pub fn getPtr(self: *Self, index: usize) ?*T {
            if (index >= self.len) return null;
            return &self.items[(self.head + index) % self.capacity];
        }

        pub fn isFull(self: *Self) bool {
            return self.len == self.capacity;
        }

        pub fn isEmpty(self: *Self) bool {
            return self.len == 0;
        }

        pub fn clear(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.len = 0;
        }

        pub const Iterator = struct {
            queue: *const Self,
            i: usize,
            count: usize,

            pub fn next(self: *Iterator) ?*T {
                if (self.count == 0) return null;
                const result = &self.queue.items[self.i];
                self.i = (self.i + 1) % self.queue.items.len;
                self.count -= 1;
                return result;
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return Iterator{ .queue = self, .i = self.head, .count = self.len };
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

test "take" {
    const capacity = 8;
    var queue = Queue(usize, capacity).empty;
    for (0..capacity) |i| {
        try queue.put(i);
    }
    for (0..capacity) |i| {
        try std.testing.expectEqual(i, queue.take());
    }
    try std.testing.expectEqual(null, queue.take());
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

test "iter" {
    const capacity = 8;
    var queue = Queue(usize, capacity).empty;

    var iter = queue.iterator();
    var i: usize = 0;
    while (iter.next()) |c| : (i += 1) {
        try std.testing.expectEqual(i, c.*);
    }
}

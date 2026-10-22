const std = @import("std");

// pub fn Queue(comptime T: type, comptime capacity: usize) type {
//     return struct {
//         items: [capacity]T = undefined,
//         len: usize = 0,
//         head: usize = 0,
//         tail: usize = 0,
//
//         const Self = @This();
//         pub const empty: Self = .{};
//
//         pub fn put(self: *Self, item: T) error{Full}!void {
//             if (self.isFull()) return error.Full;
//             self.items[self.tail] = item;
//             self.len += 1;
//             self.tail = (self.tail + 1) % capacity;
//         }
//
//         pub fn take(self: *Self) ?T {
//             if (self.isEmpty()) return null;
//             const result = self.items[self.head];
//             self.head = (self.head + 1) % capacity;
//             self.len -= 1;
//             return result;
//         }
//
//         pub fn peek(self: *Self) ?T {
//             if (self.isEmpty()) return null;
//             return self.items[self.head];
//         }
//
//         pub fn get(self: *Self, index: usize) ?T {
//             if (index >= self.len) return null;
//             return self.items[(self.head + index) % capacity];
//         }
//
//         pub fn getPtr(self: *Self, index: usize) ?*T {
//             if (index >= self.len) return null;
//             return &self.items[(self.head + index) % capacity];
//         }
//
//         pub fn isFull(self: *Self) bool {
//             return self.len == capacity;
//         }
//
//         pub fn isEmpty(self: *Self) bool {
//             return self.len == 0;
//         }
//
//         pub fn clear(self: *Self) void {
//             self.head = 0;
//             self.tail = 0;
//             self.len = 0;
//         }
//
//         pub const Iterator = struct {
//             queue: *const Self,
//             i: usize,
//             count: usize,
//
//             pub fn next(self: *Iterator) ?*T {
//                 if (self.count == 0) return null;
//                 const result = &self.queue.items[self.i];
//                 self.i = (self.i + 1) % capacity;
//                 self.count -= 1;
//                 return result;
//             }
//         };
//
//         pub fn iterator(self: *const Self) Iterator {
//             return Iterator{ .queue = self, .i = self.head, .count = self.len };
//         }
//     };
// }

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        len: usize = 0,
        head: usize = 0,
        tail: usize = 0,

        pub fn init(buf: []T) Self {
            return .{ .items = buf };
        }

        pub fn putFront(self: *Self, item: T) error{Full}!void {
            if (self.isFull()) return error.Full;
            self.head = @intCast(@mod(@as(i64, @intCast(self.head)) - 1, @as(i64, @intCast(self.items.len))));
            self.items[self.head] = item;
            self.len += 1;
        }

        pub fn putBack(self: *Self, item: T) error{Full}!void {
            if (self.isFull()) return error.Full;
            self.items[self.tail] = item;
            self.len += 1;
            self.tail = (self.tail + 1) % self.items.len;
        }

        pub fn takeFront(self: *Self) ?T {
            if (self.isEmpty()) return null;
            const result = self.items[self.head];
            self.head = (self.head + 1) % self.items.len;
            self.len -= 1;
            return result;
        }

        pub fn takeBack(self: *Self) ?T {
            if (self.isEmpty()) return null;
            self.tail = @intCast(@mod(@as(i64, @intCast(self.tail)) - 1, @as(i64, @intCast(self.items.len))));
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
            return self.items[(self.head + index) % self.items.len];
        }

        pub fn getPtr(self: *Self, index: usize) ?*T {
            if (index >= self.len) return null;
            return &self.items[(self.head + index) % self.items.len];
        }

        pub fn isFull(self: *const Self) bool {
            return self.len == self.items.len;
        }

        pub fn isEmpty(self: *const Self) bool {
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

pub fn ThreadSafeQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        queue: Queue(T),
        mutex: std.Io.Mutex,

        pub fn init(buf: []T) Self {
            return .{
                .queue = .init(buf),
                .mutex = .init,
            };
        }

        pub fn putFront(self: *Self, io: std.Io, item: T) error{ Full, Canceled }!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.queue.peekFront(item);
        }

        pub fn putBack(self: *Self, io: std.Io, item: T) error{ Full, Canceled }!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.queue.putBack(item);
        }

        pub fn takeFront(self: *Self, io: std.Io) std.Io.Cancelable!?T {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.queue.takeFront();
        }

        pub fn takeBack(self: *Self, io: std.Io) std.Io.Cancelable!?T {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.queue.takeBack();
        }

        pub fn peekFront(self: *Self, io: std.Io) std.Io.Cancelable!?*T {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.queue.peekFront();
        }

        pub fn peekBack(self: *Self, io: std.Io) std.Io.Cancelable!?*T {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.queue.peekBack();
        }

        pub fn get(self: *Self, io: std.Io, index: usize) std.Io.Cancelable!?T {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.queue.get(index);
        }

        pub fn getPtr(self: *Self, io: std.Io, index: usize) std.Io.Cancelable!?*T {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.queue.getPtr(index);
        }

        pub fn isFull(self: *const Self, io: std.Io) std.Io.Cancelable!bool {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.queue.isFull();
        }

        pub fn isEmpty(self: *const Self, io: std.Io) std.Io.Cancelable!bool {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.queue.isEmpty();
        }

        pub fn clear(self: *Self, io: std.Io) std.Io.Cancelable!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            self.queue.clear();
        }

        pub const Iterator = struct {
            queue: *const Queue(T),
            mutex: *std.Io.Mutex,
            i: usize,
            count: usize,

            pub fn next(self: *Iterator, io: std.Io) std.Io.Cancelable!?*T {
                try self.mutex.lock(io);
                defer self.mutex.unlock(io);

                if (self.count == 0) return null;
                const result = &self.queue.items[self.i];
                self.i = (self.i + 1) % self.queue.items.len;
                self.count -= 1;
                return result;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return Iterator{
                .queue = &self.queue,
                .mutex = &self.mutex,
                .i = self.queue.head,
                .count = self.queue.len,
            };
        }
    };
}

test "put" {
    const capacity = 8;
    var buf: [capacity]usize = undefined;
    var queue = Queue(usize).init(&buf);
    for (0..capacity) |i| {
        try queue.putBack(i);
        try std.testing.expectEqual(i, queue.items[i]);
    }
    try std.testing.expectError(error.Full, queue.putBack(0));
}

test "take" {
    const capacity = 8;
    var buf: [capacity]usize = undefined;
    var queue = Queue(usize).init(&buf);
    for (0..capacity) |i| {
        try queue.putBack(i);
    }
    for (0..capacity) |i| {
        try std.testing.expectEqual(i, queue.takeFront());
    }
    try std.testing.expectEqual(null, queue.takeFront());
}

test "clear" {
    const capacity = 8;
    var buf: [capacity]usize = undefined;
    var queue = Queue(usize).init(&buf);
    for (0..capacity) |i| {
        try queue.putBack(i);
    }
    queue.clear();
    try std.testing.expectEqual(0, queue.len);
    try std.testing.expectEqual(0, queue.head);
    try std.testing.expectEqual(0, queue.tail);
}

test "iter" {
    const capacity = 8;
    var buf: [capacity]usize = undefined;
    var queue = Queue(usize).init(&buf);
    for (0..capacity) |i| {
        try queue.putBack(i);
    }

    var iter = queue.iterator();
    var i: usize = 0;
    while (iter.next()) |c| : (i += 1) {
        try std.testing.expectEqual(i, c.*);
    }
}

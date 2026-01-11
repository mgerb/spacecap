//// Credits to https://github.com/erik-dunteman/chanz/tree/main
//// This is a placeholder until the new async queue in zig 0.16.0.

const std = @import("std");

pub const ChanError = error{
    Closed,
    OutOfMemory,
    NotImplemented,
    DataCorruption,
};

pub fn Chan(comptime T: type) type {
    return BufferedChan(T, 0);
}

pub fn BufferedChan(comptime T: type, comptime bufSize: u32) type {
    return struct {
        const Self = @This();
        const bufType = [bufSize]?T;
        buf: bufType = [_]?T{null} ** bufSize,
        closed: bool = false,
        mut: std.Thread.Mutex = std.Thread.Mutex{},
        alloc: std.mem.Allocator = undefined,
        recvQ: std.ArrayList(*Receiver) = undefined,
        sendQ: std.ArrayList(*Sender) = undefined,
        len: u32 = 0,

        // represents a thread waiting on recv
        const Receiver = struct {
            mut: std.Thread.Mutex = std.Thread.Mutex{},
            cond: std.Thread.Condition = std.Thread.Condition{},
            data: ?T = null,

            fn putDataAndSignal(self: *@This(), data: T) void {
                self.data = data;
                self.cond.signal();
            }
        };

        // represents a thread waiting on send
        const Sender = struct {
            mut: std.Thread.Mutex = std.Thread.Mutex{},
            cond: std.Thread.Condition = std.Thread.Condition{},
            data: T,
            delivered: bool = false,

            fn getDataAndSignal(self: *@This()) T {
                self.mut.lock();
                defer self.mut.unlock();
                self.delivered = true;
                self.cond.signal();
                return self.data;
            }
        };

        pub fn init(alloc: std.mem.Allocator) !Self {
            return Self{
                .alloc = alloc,
                .recvQ = try std.ArrayList(*Receiver).initCapacity(alloc, 0),
                .sendQ = try std.ArrayList(*Sender).initCapacity(alloc, 0),
            };
        }

        pub fn deinit(self: *Self) void {
            if (!self.closed) {
                self.close(.{});
            }
            self.recvQ.deinit(self.alloc);
            self.sendQ.deinit(self.alloc);
        }

        /// Close the channel. Any sender/receiver currently
        /// waiting will be terminated with ChanError.Closed.
        pub fn close(self: *Self, comptime args: struct {
            /// If true, remove and call "deinit" on all items remaining in the queue.
            drain: bool = false,
        }) void {
            self.mut.lock();
            defer self.mut.unlock();
            self.closed = true;

            for (self.sendQ.items) |sendQ| {
                sendQ.cond.signal();
            }

            for (self.recvQ.items) |recvQ| {
                recvQ.cond.signal();
            }

            if (args.drain) {
                if (@hasDecl(T, "deinit")) {
                    for (self.buf, 0..) |buf, i| {
                        if (buf) |*b| {
                            @constCast(b).deinit();
                        }
                        self.buf[i] = null;
                    }
                }
            }
        }

        pub fn capacity(self: *Self) u32 {
            return self.buf.len;
        }

        pub fn full(self: *Self) bool {
            return self.buf.len == self.len;
        }

        fn debugBuf(self: *Self) void {
            std.log.debug("{d} Buffer debug\n", .{std.time.milliTimestamp()});
            for (self.buf, 0..) |item, i| {
                if (item) |unwrapped| {
                    std.log.debug("[{d}] = {d}\n", .{ i, unwrapped });
                }
            }
        }

        /// Try to send
        /// Chan - will skip if no receiver is receiving
        /// BufferedChan - will skip if at capacity
        pub fn trySend(self: *Self, data: T) ChanError!void {
            self.mut.lock();
            if ((bufSize == 0 and self.recvQ.items.len > 0) or
                (bufSize > 0 and self.len < self.capacity()))
            {
                try self._send(data);
            } else {
                self.mut.unlock();
            }
        }

        /// Chan - send and wait for receiver
        /// BufferedChan - send and wait for receiver if at capacity
        pub fn send(self: *Self, data: T) ChanError!void {
            self.mut.lock();
            return self._send(data);
        }

        /// Private send method so that wrapping functions can manage locking
        fn _send(self: *Self, data: T) ChanError!void {
            if (self.closed) {
                self.mut.unlock();
                return ChanError.Closed;
            }

            // case: receiver already waiting
            // pull receiver (if any) and give it data. Signal receiver that it's done waiting.
            if (self.recvQ.items.len > 0) {
                defer self.mut.unlock();
                // Lock receiver mutex to synchronize data visibility with the waiting thread.
                var receiver: *Receiver = self.recvQ.orderedRemove(0);
                receiver.mut.lock();
                defer receiver.mut.unlock();
                receiver.putDataAndSignal(data);
                return;
            }

            if (self.len < self.capacity() and bufSize > 0) {
                defer self.mut.unlock();

                // insert into first null spot in buffer
                self.buf[self.len] = data;
                self.len += 1;
                return;
            }

            // hold on sender queue. Receivers will signal when they take data.
            var sender = Sender{ .data = data };

            // prime condition
            sender.mut.lock(); // cond.wait below will unlock it and wait until signal, then relock it

            self.sendQ.append(self.alloc, &sender) catch |err| {
                self.mut.unlock();
                sender.mut.unlock();
                return err;
            }; // make visible to other threads
            self.mut.unlock(); // allow all other threads to proceed. This thread is done reading/writing

            // Wait until a receiver consumes the data or the channel closes. Condition
            // waits can spuriously wake, so loop until the receiver marks the send as
            // delivered to avoid leaving a dangling sender pointer in sendQ.
            while (true) {
                // A receiver may have already consumed the data before we start waiting.
                if (sender.delivered) {
                    sender.mut.unlock();
                    break;
                }

                // Check for closed without holding locks in the opposite order of receivers.
                sender.mut.unlock();
                self.mut.lock();
                const closed = self.closed;
                self.mut.unlock();
                sender.mut.lock();

                if (closed) {
                    sender.mut.unlock();
                    return ChanError.Closed;
                }
                if (sender.delivered) {
                    sender.mut.unlock();
                    break;
                }

                sender.cond.wait(&sender.mut);
            }

            // Sender mutex is already unlocked here.
        }

        /// Try to receive
        /// Chan - if nothing is sending, return null
        /// BufferedChan - receive if items have been sent
        pub fn tryRecv(self: *Self) ChanError!?T {
            self.mut.lock();
            if ((bufSize == 0 and self.sendQ.items.len > 0) or
                (bufSize > 0 and self.len > 0))
            {
                const val = self._recv() catch |err| {
                    return err;
                };
                return val;
            } else {
                self.mut.unlock();
                return null;
            }
        }

        pub fn recv(self: *Self) ChanError!T {
            self.mut.lock();
            return self._recv();
        }

        /// Private recv method so that wrapping functions can manage locking
        fn _recv(self: *Self) ChanError!T {
            if (self.closed) {
                self.mut.unlock();
                return ChanError.Closed;
            }

            // case: value in buffer
            const l = self.len;
            if (l > 0 and bufSize > 0) {
                defer self.mut.unlock();
                const val = self.buf[0] orelse return ChanError.DataCorruption;

                // advance items in buffer
                if (l > 1) {
                    for (self.buf[1..l], 0..l - 1) |item, i| {
                        self.buf[i] = item;
                    }
                }
                self.buf[l - 1] = null;

                // top up buffer with a waiting sender, if any
                if (self.sendQ.items.len > 0) {
                    var sender: *Sender = self.sendQ.orderedRemove(0);
                    const valFromSender: T = sender.getDataAndSignal();
                    self.buf[l - 1] = valFromSender;
                }

                self.len -= 1;
                return val;
            }

            // case: sender already waiting
            // pull sender and take its data. Signal sender that it's done waiting.
            if (self.sendQ.items.len > 0) {
                defer self.mut.unlock();
                var sender: *Sender = self.sendQ.orderedRemove(0);
                const data: T = sender.getDataAndSignal();
                return data;
            }

            // hold on receiver queue. Senders will signal when they take it.
            var receiver = Receiver{};

            // prime condition
            receiver.mut.lock();
            defer receiver.mut.unlock();

            self.recvQ.append(self.alloc, &receiver) catch |err| {
                self.mut.unlock();
                return err;
            };
            self.mut.unlock();

            // Wait until a sender provides data. A sender may set data before we start
            // waiting, so always re-check after reacquiring the mutex to avoid missed
            // signals. Condition waits can spuriously wake, so loop until data or closed.
            while (true) {
                if (receiver.data != null) break;

                receiver.mut.unlock();
                self.mut.lock();
                const closed = self.closed;
                self.mut.unlock();
                receiver.mut.lock();

                if (receiver.data != null) break;
                if (closed) {
                    return ChanError.Closed;
                }

                receiver.cond.wait(&receiver.mut);
            }

            self.mut.lock();
            defer self.mut.unlock();
            const closed = self.closed;

            // sender should have put data in .data
            if (closed) {
                return ChanError.Closed;
            } else if (receiver.data) |data| {
                return data;
            } else {
                return ChanError.DataCorruption;
            }
        }
    };
}

test "unbufferedChan" {
    // create channel of u8
    const T = Chan(u8);
    var chan = T.init(std.testing.allocator);
    defer chan.deinit();

    // spawn thread that immediately waits on channel
    const Thread = struct {
        fn run(c: *T) !void {
            const val = try c.recv();
            try std.testing.expectEqual(10, val);
        }
    };
    const t = try std.Thread.spawn(.{}, Thread.run, .{&chan});
    defer t.join();

    // let thread wait a bit before sending value
    std.time.sleep(0.1 * std.time.ns_per_s);

    const val: u8 = 10;
    try chan.send(val);
}

test "bidirectional unbufferedChan" {
    const T = Chan(u8);
    var chan = T.init(std.testing.allocator);
    defer chan.deinit();

    const Thread = struct {
        fn run(c: *T) !void {
            std.time.sleep(0.1 * std.time.ns_per_s);
            const val = try c.recv();
            try std.testing.expectEqual(10, val);
            std.time.sleep(0.1 * std.time.ns_per_s);
            try c.send(val + 1);
            std.time.sleep(0.1 * std.time.ns_per_s);
            try c.send(val + 100);
        }
    };

    const t = try std.Thread.spawn(.{}, Thread.run, .{&chan});
    defer t.join();

    std.time.sleep(0.1 * std.time.ns_per_s);
    var val: u8 = 10;
    try chan.send(val);
    val = try chan.recv();
    try std.testing.expectEqual(11, val);
    val = try chan.recv();
    try std.testing.expectEqual(110, val);
}

test "BufferedChan" {
    const T = BufferedChan(u8, 3);
    var chan = T.init(std.testing.allocator);
    defer chan.deinit();

    const Thread = struct {
        fn run(c: *T) !void {
            std.time.sleep(0.1 * std.time.ns_per_s);
            var val = try c.recv();
            try std.testing.expectEqual(10, val);
            std.time.sleep(0.1 * std.time.ns_per_s);
            val = try c.recv();
            try std.testing.expectEqual(11, val);
            std.time.sleep(0.1 * std.time.ns_per_s);
            val = try c.recv();
            try std.testing.expectEqual(12, val);
            std.time.sleep(0.1 * std.time.ns_per_s);
            val = try c.recv();
            try std.testing.expectEqual(13, val);
        }
    };

    const t = try std.Thread.spawn(.{}, Thread.run, .{&chan});
    defer t.join();

    std.time.sleep(1_000_000_000);
    var val: u8 = 10;
    try chan.send(val);
    val = 11;
    try chan.send(val);
    val = 12;
    try chan.send(val);
    val = 13;
    try chan.send(val);
}

test "len - BufferedChan" {
    const T = BufferedChan(u8, 50);
    var chan = T.init(std.testing.allocator);
    defer chan.deinit();

    const Thread = struct {
        fn run(_chan: *T) !void {
            std.time.sleep(std.time.ns_per_s * 0.5);
            for (0..50) |i| {
                _ = try _chan.recv();
                try std.testing.expectEqual(49 - i, _chan.len);
            }
        }
    };

    const th = try std.Thread.spawn(.{}, Thread.run, .{&chan});

    for (0..50) |i| {
        try chan.send(1);
        try std.testing.expectEqual(chan.len, i + 1);
    }

    th.join();
}

test "chan of chan" {
    const T = BufferedChan(u8, 3);
    const TofT = Chan(T);
    var chanOfChan = TofT.init(std.testing.allocator);
    defer chanOfChan.deinit();

    const Thread = struct {
        fn run(cOC: *TofT) !void {
            std.time.sleep(0.1 * std.time.ns_per_s);
            var c = try cOC.recv();
            const val = try c.recv(); // should have value on buffer
            try std.testing.expectEqual(10, val);
        }
    };

    const t = try std.Thread.spawn(.{}, Thread.run, .{&chanOfChan});
    defer t.join();

    std.time.sleep(0.1 * std.time.ns_per_s);
    const val: u8 = 10;
    var chan = T.init(std.testing.allocator);
    defer chan.deinit();
    try chan.send(val);

    try chanOfChan.send(chan);
}

test "close - Chan" {
    // create channel of u8
    const T = Chan(u8);
    var chan = T.init(std.testing.allocator);
    defer chan.deinit();

    // spawn thread that immediately waits on channel
    const Thread = struct {
        fn run(c: *T) !void {
            while (true) {
                _ = c.recv() catch |err| {
                    try std.testing.expectEqual(ChanError.Closed, err);
                    break;
                };
            }
        }
    };
    const t = try std.Thread.spawn(.{}, Thread.run, .{&chan});
    defer t.join();

    // let thread wait a bit before sending value
    std.time.sleep(0.1 * std.time.ns_per_s);

    const val: u8 = 10;
    try chan.send(val);

    std.time.sleep(0.1 * std.time.ns_per_s);

    chan.close();

    std.time.sleep(1.1 * std.time.ns_per_s);
}

test "trySend - Chan" {
    const T = Chan(u8);
    var chan = T.init(std.testing.allocator);
    defer chan.deinit();

    try chan.trySend(1);

    try std.testing.expectEqual(chan.len, 0);

    const Thread = struct {
        fn run(c: *T) !void {
            try std.testing.expectEqual(try c.recv(), 1);
        }
    };

    const th = try std.Thread.spawn(.{}, Thread.run, .{&chan});

    std.time.sleep(0.1 * std.time.ns_per_s);
    try chan.trySend(1);

    th.join();
}

test "trySend - BufferedChan" {
    const T = BufferedChan(u8, 2);
    var chan = T.init(std.testing.allocator);
    defer chan.deinit();

    try chan.trySend(1);
    try chan.trySend(1);

    // should skip
    try chan.trySend(1);

    try std.testing.expectEqual(chan.len, 2);
}

test "tryRecv - Chan" {
    const T = Chan(u8);
    var chan = T.init(std.testing.allocator);
    defer chan.deinit();

    try std.testing.expectEqual(chan.tryRecv(), null);

    const Thread = struct {
        fn run(c: *T) !void {
            try c.send(1);
        }
    };

    const thread = try std.Thread.spawn(.{}, Thread.run, .{&chan});
    defer thread.join();

    std.time.sleep(0.1 * std.time.ns_per_s);

    try std.testing.expectEqual(chan.tryRecv(), 1);
}

test "tryRecv - BufferedChan" {
    const T = BufferedChan(u8, 2);
    var chan = T.init(std.testing.allocator);
    defer chan.deinit();

    // should not block if nothing in it
    try std.testing.expectEqual(null, chan.tryRecv());

    const Thread = struct {
        fn run(c: *T) !void {
            try c.send(1);
        }
    };

    const thread = try std.Thread.spawn(.{}, Thread.run, .{&chan});
    defer thread.join();

    std.time.sleep(0.1 * std.time.ns_per_s);

    try std.testing.expectEqual(1, chan.tryRecv());
}

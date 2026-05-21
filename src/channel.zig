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
        mut: std.Io.Mutex = .init,
        allocator: std.mem.Allocator = undefined,
        io: std.Io,
        recvQ: std.ArrayList(*Receiver) = undefined,
        sendQ: std.ArrayList(*Sender) = undefined,
        len: u32 = 0,

        // represents a thread waiting on recv
        const Receiver = struct {
            mut: std.Io.Mutex = .init,
            cond: std.Io.Condition = .init,
            data: ?T = null,

            fn put_data_and_signal(self: *@This(), io: std.Io, data: T) void {
                self.data = data;
                self.cond.signal(io);
            }
        };

        // represents a thread waiting on send
        const Sender = struct {
            mut: std.Io.Mutex = .init,
            cond: std.Io.Condition = .init,
            data: T,
            delivered: bool = false,

            fn get_data_and_signal(self: *@This(), io: std.Io) T {
                self.mut.lockUncancelable(io);
                defer self.mut.unlock(io);
                self.delivered = true;
                self.cond.signal(io);
                return self.data;
            }
        };

        pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
            return Self{
                .allocator = allocator,
                .io = io,
                .recvQ = try std.ArrayList(*Receiver).initCapacity(allocator, 0),
                .sendQ = try std.ArrayList(*Sender).initCapacity(allocator, 0),
            };
        }

        pub fn deinit(self: *Self) void {
            if (!self.closed) {
                self.close(.{});
            }
            self.recvQ.deinit(self.allocator);
            self.sendQ.deinit(self.allocator);
        }

        /// Close the channel. Any sender/receiver currently
        /// waiting will be terminated with ChanError.Closed.
        pub fn close(self: *Self, comptime args: struct {
            /// If true, remove and call "deinit" on all items remaining in the queue.
            drain: bool = false,
        }) void {
            self.mut.lockUncancelable(self.io);
            defer self.mut.unlock(self.io);
            if (self.closed) {
                return;
            }
            self.closed = true;

            for (self.sendQ.items) |sendQ| {
                sendQ.cond.signal(self.io);
            }

            for (self.recvQ.items) |recvQ| {
                recvQ.cond.signal(self.io);
            }

            if (args.drain) {
                const type_info = switch (@typeInfo(T)) {
                    .pointer => |p| p.child,
                    else => T,
                };
                if (@hasDecl(type_info, "deinit")) {
                    for (self.buf, 0..) |buf, i| {
                        if (@typeInfo(T) == .pointer) {
                            if (buf) |b| {
                                b.deinit();
                            }
                        } else {
                            if (buf) |*b| {
                                @constCast(b).deinit();
                            }
                        }
                        self.buf[i] = null;
                    }
                } else {
                    @compileError(@typeName(T) ++ " must implement a 'deinit' method when .drain = true");
                }
            }
        }

        pub fn capacity(self: *Self) u32 {
            return self.buf.len;
        }

        pub fn full(self: *Self) bool {
            return self.buf.len == self.len;
        }

        fn debug_buf(self: *Self) void {
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
        /// Returns true if sent successfully.
        pub fn try_send(self: *Self, data: T) ChanError!bool {
            self.mut.lockUncancelable(self.io);
            if ((bufSize == 0 and self.recvQ.items.len > 0) or
                (bufSize > 0 and self.len < self.capacity()))
            {
                try self._send(data);
                return true;
            } else {
                self.mut.unlock(self.io);
                return false;
            }
        }

        /// Chan - send and wait for receiver
        /// BufferedChan - send and wait for receiver if at capacity
        pub fn send(self: *Self, data: T) ChanError!void {
            self.mut.lockUncancelable(self.io);
            return self._send(data);
        }

        /// Private send method so that wrapping functions can manage locking
        fn _send(self: *Self, data: T) ChanError!void {
            if (self.closed) {
                self.mut.unlock(self.io);
                return ChanError.Closed;
            }

            // case: receiver already waiting
            // pull receiver (if any) and give it data. Signal receiver that it's done waiting.
            if (self.recvQ.items.len > 0) {
                defer self.mut.unlock(self.io);
                // Lock receiver mutex to synchronize data visibility with the waiting thread.
                var receiver: *Receiver = self.recvQ.orderedRemove(0);
                receiver.mut.lockUncancelable(self.io);
                defer receiver.mut.unlock(self.io);
                receiver.put_data_and_signal(self.io, data);
                return;
            }

            if (self.len < self.capacity() and bufSize > 0) {
                defer self.mut.unlock(self.io);

                // insert into first null spot in buffer
                self.buf[self.len] = data;
                self.len += 1;
                return;
            }

            // hold on sender queue. Receivers will signal when they take data.
            var sender = Sender{ .data = data };

            // prime condition
            sender.mut.lockUncancelable(self.io); // cond.wait below will unlock it and wait until signal, then relock it

            self.sendQ.append(self.allocator, &sender) catch |err| {
                self.mut.unlock(self.io);
                sender.mut.unlock(self.io);
                return err;
            }; // make visible to other threads
            self.mut.unlock(self.io); // allow all other threads to proceed. This thread is done reading/writing

            // Wait until a receiver consumes the data or the channel closes. Condition
            // waits can spuriously wake, so loop until the receiver marks the send as
            // delivered to avoid leaving a dangling sender pointer in sendQ.
            while (true) {
                // A receiver may have already consumed the data before we start waiting.
                if (sender.delivered) {
                    sender.mut.unlock(self.io);
                    break;
                }

                // Check for closed without holding locks in the opposite order of receivers.
                sender.mut.unlock(self.io);
                self.mut.lockUncancelable(self.io);
                const closed = self.closed;
                self.mut.unlock(self.io);
                sender.mut.lockUncancelable(self.io);

                if (closed) {
                    sender.mut.unlock(self.io);
                    return ChanError.Closed;
                }
                if (sender.delivered) {
                    sender.mut.unlock(self.io);
                    break;
                }

                sender.cond.waitUncancelable(self.io, &sender.mut);
            }

            // Sender mutex is already unlocked here.
        }

        /// Try to receive
        /// Chan - if nothing is sending, return null
        /// BufferedChan - receive if items have been sent
        pub fn try_recv(self: *Self) ChanError!?T {
            self.mut.lockUncancelable(self.io);
            if ((bufSize == 0 and self.sendQ.items.len > 0) or
                (bufSize > 0 and self.len > 0))
            {
                const val = try self._recv();
                return val;
            } else {
                self.mut.unlock(self.io);
                return null;
            }
        }

        pub fn recv(self: *Self) ChanError!T {
            self.mut.lockUncancelable(self.io);
            return self._recv();
        }

        /// Private recv method so that wrapping functions can manage locking
        fn _recv(self: *Self) ChanError!T {
            if (self.closed) {
                self.mut.unlock(self.io);
                return ChanError.Closed;
            }

            // case: value in buffer
            const l = self.len;
            if (l > 0 and bufSize > 0) {
                defer self.mut.unlock(self.io);
                const val = self.buf[0] orelse return ChanError.DataCorruption;

                // advance items in buffer
                if (l > 1) {
                    for (self.buf[1..l], 0..l - 1) |item, i| {
                        self.buf[i] = item;
                    }
                }
                self.buf[l - 1] = null;

                // Top up buffer with a waiting sender, if any. In this case
                // the buffer remains the same logical length.
                if (self.sendQ.items.len > 0) {
                    var sender: *Sender = self.sendQ.orderedRemove(0);
                    const valFromSender: T = sender.get_data_and_signal(self.io);
                    self.buf[l - 1] = valFromSender;
                } else {
                    self.len -= 1;
                }
                return val;
            }

            // case: sender already waiting
            // pull sender and take its data. Signal sender that it's done waiting.
            if (self.sendQ.items.len > 0) {
                defer self.mut.unlock(self.io);
                var sender: *Sender = self.sendQ.orderedRemove(0);
                const data: T = sender.get_data_and_signal(self.io);
                return data;
            }

            // hold on receiver queue. Senders will signal when they take it.
            var receiver = Receiver{};

            // prime condition
            receiver.mut.lockUncancelable(self.io);
            defer receiver.mut.unlock(self.io);

            self.recvQ.append(self.allocator, &receiver) catch |err| {
                self.mut.unlock(self.io);
                return err;
            };
            self.mut.unlock(self.io);

            // Wait until a sender provides data. A sender may set data before we start
            // waiting, so always re-check after reacquiring the mutex to avoid missed
            // signals. Condition waits can spuriously wake, so loop until data or closed.
            while (true) {
                if (receiver.data != null) break;

                receiver.mut.unlock(self.io);
                self.mut.lockUncancelable(self.io);
                const closed = self.closed;
                self.mut.unlock(self.io);
                receiver.mut.lockUncancelable(self.io);

                if (receiver.data != null) break;
                if (closed) {
                    return ChanError.Closed;
                }

                receiver.cond.waitUncancelable(self.io, &receiver.mut);
            }

            self.mut.lockUncancelable(self.io);
            defer self.mut.unlock(self.io);
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

test "Channel - unbufferedChan" {
    // create channel of u8
    const T = Chan(u8);
    var chan = try T.init(std.testing.allocator, std.testing.io);
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
    std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_s / 10), .awake) catch unreachable;

    const val: u8 = 10;
    try chan.send(val);
}

test "Channel - bidirectional unbufferedChan" {
    const T = Chan(u8);
    var chan = try T.init(std.testing.allocator, std.testing.io);
    defer chan.deinit();

    const Thread = struct {
        fn run(c: *T) !void {
            std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_s / 10), .awake) catch unreachable;
            const val = try c.recv();
            try std.testing.expectEqual(10, val);
            std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_s / 10), .awake) catch unreachable;
            try c.send(val + 1);
            std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_s / 10), .awake) catch unreachable;
            try c.send(val + 100);
        }
    };

    const t = try std.Thread.spawn(.{}, Thread.run, .{&chan});
    defer t.join();

    std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_s / 10), .awake) catch unreachable;
    var val: u8 = 10;
    try chan.send(val);
    val = try chan.recv();
    try std.testing.expectEqual(11, val);
    val = try chan.recv();
    try std.testing.expectEqual(110, val);
}

test "Channel - BufferedChan" {
    const T = BufferedChan(u8, 3);
    var chan = try T.init(std.testing.allocator, std.testing.io);
    defer chan.deinit();

    const Thread = struct {
        fn run(c: *T) !void {
            var val = try c.recv();
            try std.testing.expectEqual(10, val);
            val = try c.recv();
            try std.testing.expectEqual(11, val);
            val = try c.recv();
            try std.testing.expectEqual(12, val);
            val = try c.recv();
            try std.testing.expectEqual(13, val);
        }
    };

    const t = try std.Thread.spawn(.{}, Thread.run, .{&chan});
    defer t.join();

    var val: u8 = 10;
    try chan.send(val);
    val = 11;
    try chan.send(val);
    val = 12;
    try chan.send(val);
    val = 13;
    try chan.send(val);
}

test "Channel - BufferedChan recv top-up keeps channel logically full" {
    const T = BufferedChan(u8, 2);
    var chan = try T.init(std.testing.allocator, std.testing.io);
    defer chan.deinit();

    // Fill the buffer.
    try chan.send(1);
    try chan.send(2);

    var started = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);

    const Thread = struct {
        fn run(c: *T, send_started: *std.atomic.Value(bool), send_done: *std.atomic.Value(bool)) !void {
            send_started.store(true, .seq_cst);
            try c.send(3); // Blocks until receiver pops and tops up buffer.
            send_done.store(true, .seq_cst);
        }
    };

    const sender = try std.Thread.spawn(.{}, Thread.run, .{ &chan, &started, &done });
    defer sender.join();

    // Wait for sender thread to attempt send.
    var saw_started = false;
    for (0..500) |_| {
        saw_started = started.load(.seq_cst);
        if (saw_started) break;
        std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch unreachable;
    }
    try std.testing.expect(saw_started);
    try std.testing.expectEqual(false, done.load(.seq_cst));

    // Popping one item should immediately unblock sender and keep buffer full.
    try std.testing.expectEqual(@as(u8, 1), try chan.recv());

    var saw_done = false;
    for (0..500) |_| {
        saw_done = done.load(.seq_cst);
        if (saw_done) break;
        std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch unreachable;
    }
    try std.testing.expect(saw_done);

    try std.testing.expectEqual(false, try chan.try_send(4));
    try std.testing.expectEqual(@as(u8, 2), try chan.recv());
    try std.testing.expectEqual(@as(u8, 3), try chan.recv());
}

test "Channel - len - BufferedChan" {
    const T = BufferedChan(u8, 50);
    var chan = try T.init(std.testing.allocator, std.testing.io);
    defer chan.deinit();

    const Thread = struct {
        fn run(_chan: *T) !void {
            std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch unreachable;
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

test "Channel - chan of chan" {
    const T = BufferedChan(u8, 3);
    const TofT = Chan(T);
    var chanOfChan = try TofT.init(std.testing.allocator, std.testing.io);
    defer chanOfChan.deinit();

    const Thread = struct {
        fn run(cOC: *TofT) !void {
            std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_s / 10), .awake) catch unreachable;
            var c = try cOC.recv();
            const val = try c.recv(); // should have value on buffer
            try std.testing.expectEqual(10, val);
        }
    };

    const t = try std.Thread.spawn(.{}, Thread.run, .{&chanOfChan});
    defer t.join();

    std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_s / 10), .awake) catch unreachable;
    const val: u8 = 10;
    var chan = try T.init(std.testing.allocator, std.testing.io);
    defer chan.deinit();
    try chan.send(val);

    try chanOfChan.send(chan);
}

test "Channel - close - Chan" {
    // create channel of u8
    const T = Chan(u8);
    var chan = try T.init(std.testing.allocator, std.testing.io);
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
    std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_ms * 10), .awake) catch unreachable;

    const val: u8 = 10;
    try chan.send(val);

    std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_ms * 10), .awake) catch unreachable;

    chan.close(.{});

    std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch unreachable;
}

test "Channel - close - Chan is idempotent" {
    const T = Chan(u8);

    {
        var chan = try T.init(std.testing.allocator, std.testing.io);
        defer chan.deinit();

        const ReceiverThread = struct {
            fn run(c: *T) !void {
                _ = c.recv() catch |err| {
                    try std.testing.expectEqual(ChanError.Closed, err);
                    return;
                };
                return error.ExpectedCloseError;
            }
        };

        const receiver = try std.Thread.spawn(.{}, ReceiverThread.run, .{&chan});
        std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_ms * 10), .awake) catch unreachable;
        chan.close(.{});
        receiver.join();

        chan.close(.{});
        _ = chan.recv() catch |err| {
            try std.testing.expectEqual(ChanError.Closed, err);
            return;
        };
        return error.ExpectedClosedReceiveError;
    }

    {
        var chan = try T.init(std.testing.allocator, std.testing.io);
        defer chan.deinit();

        const SenderThread = struct {
            fn run(c: *T) !void {
                c.send(42) catch |err| {
                    try std.testing.expectEqual(ChanError.Closed, err);
                    return;
                };
                return error.ExpectedCloseError;
            }
        };

        const sender = try std.Thread.spawn(.{}, SenderThread.run, .{&chan});
        std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_ms * 10), .awake) catch unreachable;
        chan.close(.{});
        sender.join();

        chan.close(.{});
        chan.send(42) catch |err| {
            try std.testing.expectEqual(ChanError.Closed, err);
            return;
        };
        return error.ExpectedClosedSendError;
    }
}

test "Channel - close - BufferedChan drains queued items" {
    const Item = struct {
        allocator: std.mem.Allocator,
        deinit_count: *usize,

        fn init(allocator: std.mem.Allocator, deinit_count: *usize) !*@This() {
            const item = try allocator.create(@This());
            item.* = .{
                .allocator = allocator,
                .deinit_count = deinit_count,
            };
            return item;
        }

        fn deinit(self: *@This()) void {
            defer self.allocator.destroy(self);
            self.deinit_count.* += 1;
        }
    };

    const T = BufferedChan(*Item, 4);
    var chan = try T.init(std.testing.allocator, std.testing.io);
    defer chan.deinit();

    var deinit_count: usize = 0;

    try chan.send(try Item.init(std.testing.allocator, &deinit_count));
    try chan.send(try Item.init(std.testing.allocator, &deinit_count));
    try chan.send(try Item.init(std.testing.allocator, &deinit_count));

    chan.close(.{ .drain = true });

    try std.testing.expectEqual(@as(usize, 3), deinit_count);
    for (chan.buf) |entry| {
        try std.testing.expect(entry == null);
    }
}

test "Channel - send handles wake races" {
    const T = Chan(u32);
    var chan = try T.init(std.testing.allocator, std.testing.io);
    defer chan.deinit();

    const iterations: u32 = 1000;

    const Thread = struct {
        fn run(c: *T, count: u32) !void {
            for (0..count) |i| {
                if ((i & 1) == 1) std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_ms / 10), .awake) catch unreachable;
                try std.testing.expectEqual(@as(u32, @intCast(i)), try c.recv());
            }
        }
    };

    const receiver = try std.Thread.spawn(.{}, Thread.run, .{ &chan, iterations });
    defer receiver.join();

    // Alternate scheduling so sometimes sender waits first, and sometimes receiver.
    for (0..iterations) |i| {
        if ((i & 1) == 0) std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_ms / 10), .awake) catch unreachable;
        try chan.send(@intCast(i));
    }
}

test "Channel - recv handles wake races" {
    const T = Chan(u32);
    var chan = try T.init(std.testing.allocator, std.testing.io);
    defer chan.deinit();

    const iterations: u32 = 1000;

    const Thread = struct {
        fn run(c: *T, count: u32) !void {
            for (0..count) |i| {
                if ((i & 1) == 0) std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_ms / 10), .awake) catch unreachable;
                try c.send(@intCast(i));
            }
        }
    };

    const sender = try std.Thread.spawn(.{}, Thread.run, .{ &chan, iterations });
    defer sender.join();

    // Alternate scheduling so sometimes receiver waits first, and sometimes sender.
    for (0..iterations) |i| {
        if ((i & 1) == 1) std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_ms / 10), .awake) catch unreachable;
        try std.testing.expectEqual(@as(u32, @intCast(i)), try chan.recv());
    }
}

test "Channel - try_send - Chan" {
    const T = Chan(u8);
    var chan = try T.init(std.testing.allocator, std.testing.io);
    defer chan.deinit();

    try std.testing.expectEqual(false, try chan.try_send(1));

    try std.testing.expectEqual(chan.len, 0);

    const Thread = struct {
        fn run(c: *T) !void {
            try std.testing.expectEqual(try c.recv(), 1);
        }
    };

    const th = try std.Thread.spawn(.{}, Thread.run, .{&chan});

    std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_s / 10), .awake) catch unreachable;
    try std.testing.expectEqual(true, try chan.try_send(1));

    th.join();
}

test "Channel - try_send - BufferedChan" {
    const T = BufferedChan(u8, 2);
    var chan = try T.init(std.testing.allocator, std.testing.io);
    defer chan.deinit();

    try std.testing.expectEqual(true, try chan.try_send(1));
    try std.testing.expectEqual(true, try chan.try_send(1));

    // should skip
    try std.testing.expectEqual(false, try chan.try_send(1));

    try std.testing.expectEqual(chan.len, 2);
}

test "Channel - try_recv - Chan" {
    const T = Chan(u8);
    var chan = try T.init(std.testing.allocator, std.testing.io);
    defer chan.deinit();

    try std.testing.expectEqual(chan.try_recv(), null);

    const Thread = struct {
        fn run(c: *T) !void {
            try c.send(1);
        }
    };

    const thread = try std.Thread.spawn(.{}, Thread.run, .{&chan});
    defer thread.join();

    std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_s / 10), .awake) catch unreachable;

    try std.testing.expectEqual(chan.try_recv(), 1);
}

test "Channel - try_recv - BufferedChan" {
    const T = BufferedChan(u8, 2);
    var chan = try T.init(std.testing.allocator, std.testing.io);
    defer chan.deinit();

    // should not block if nothing in it
    try std.testing.expectEqual(null, chan.try_recv());

    const Thread = struct {
        fn run(c: *T) !void {
            try c.send(1);
        }
    };

    const thread = try std.Thread.spawn(.{}, Thread.run, .{&chan});
    defer thread.join();

    std.Io.sleep(std.testing.io, .fromNanoseconds(std.time.ns_per_s / 10), .awake) catch unreachable;

    try std.testing.expectEqual(1, chan.try_recv());
}

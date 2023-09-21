const std = @import("std");
const libcoro = @import("coro.zig");
const libcoro_options = @import("libcoro_options");

pub const Executor = struct {
    const Self = @This();

    pub const Func = struct {
        const FuncFn = *const fn (userdata: ?*anyopaque) void;
        func: FuncFn,
        userdata: ?*anyopaque = null,
        next: ?*@This() = null,

        pub fn init(func: FuncFn, userdata: ?*anyopaque) @This() {
            return .{ .func = func, .userdata = userdata };
        }

        fn run(self: @This()) void {
            @call(.auto, self.func, .{self.userdata});
        }
    };
    readyq: Queue(Func) = .{},

    pub fn init() Self {
        return .{};
    }

    pub fn runSoon(self: *Self, func: *Func) void {
        self.readyq.push(func);
    }

    fn runAllSoon(self: *Self, funcs: Queue(Func)) void {
        self.readyq.pushAll(funcs);
    }

    pub fn tick(self: *Self) bool {
        // Reset readyq so that adds run on next tick.
        var now = self.readyq;
        self.readyq = .{};

        if (libcoro_options.debug_log_level >= 3) std.debug.print("Executor.tick readyq_len={d}\n", .{now.len()});

        var count: usize = 0;
        while (now.pop()) |func| : (count += 1) func.run();

        if (libcoro_options.debug_log_level >= 3) std.debug.print("Executor.tick done\n", .{});

        return count > 0;
    }
};

pub const ChannelConfig = struct {
    capacity: usize = 1,
};

pub fn Channel(comptime T: type, comptime config: ChannelConfig) type {
    const Storage = ArrayQueue(T, config.capacity);

    return struct {
        const Self = @This();

        q: Storage = .{},
        closed: bool = false,

        space_notif: Condition,
        value_notif: Condition,

        pub fn init(exec: ?*Executor) Self {
            const exec_ = getExec(exec);
            return .{
                .space_notif = Condition.init(exec_),
                .value_notif = Condition.init(exec_),
            };
        }

        pub fn close(self: *Self) void {
            self.closed = true;
            self.value_notif.signal();
        }

        pub fn send(self: *Self, val: T) !void {
            if (self.closed) @panic("Cannot send on closed Channel");
            while (self.q.space() == 0) self.space_notif.wait();
            try self.q.push(val);
            self.value_notif.signal();
        }

        pub fn recv(self: *Self) ?T {
            while (!(self.closed or self.q.len() != 0)) self.value_notif.wait();
            if (self.closed and self.q.len() == 0) return null;
            const out = self.q.pop().?;
            self.space_notif.signal();
            return out;
        }
    };
}

const Condition = struct {
    const Self = @This();

    exec: *Executor,
    waiters: Queue(Executor.Func) = .{},

    fn init(exec: *Executor) Self {
        return .{ .exec = exec };
    }

    fn broadcast(self: *Self) void {
        std.debug.assert(!self.notified);
        self.exec.runAllSoon(self.waiters);
    }

    fn signal(self: *Self) void {
        if (self.waiters.pop()) |waiter| self.exec.runSoon(waiter);
    }

    fn wait(self: *Self) void {
        var res = CoroResume.init();
        var cb = res.func();
        self.waiters.push(&cb);
        libcoro.xsuspend();
    }
};

const CoroResume = struct {
    const Self = @This();

    coro: libcoro.Frame,

    fn init() Self {
        return .{ .coro = libcoro.xframe() };
    }

    fn func(self: *Self) Executor.Func {
        return .{ .func = Self.cb, .userdata = self };
    }

    fn cb(ud: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ud));
        libcoro.xresume(self.coro);
    }
};

fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        head: ?*T = null,
        tail: ?*T = null,

        fn pop(self: *Self) ?*T {
            switch (self.state()) {
                .empty => {
                    return null;
                },
                .one => {
                    const out = self.head.?;
                    self.head = null;
                    self.tail = null;
                    return out;
                },
                .many => {
                    const out = self.head.?;
                    self.head = out.next;
                    return out;
                },
            }
        }

        fn push(self: *Self, val: *T) void {
            val.next = null;
            switch (self.state()) {
                .empty => {
                    self.head = val;
                    self.tail = val;
                },
                .one => {
                    self.head.?.next = val;
                    self.tail = val;
                },
                .many => {
                    self.tail.?.next = val;
                    self.tail = val;
                },
            }
        }

        fn pushAll(self: *Self, vals: Self) void {
            switch (self.state()) {
                .empty => {
                    self.head = vals.head;
                    self.tail = vals.tail;
                },
                .one => {
                    switch (vals.state()) {
                        .empty => {},
                        .one => {
                            self.head.?.next = vals.head;
                            self.tail = vals.head;
                        },
                        .many => {
                            self.head.?.next = vals.head;
                            self.tail = vals.tail;
                        },
                    }
                },
                .many => {
                    switch (vals.state()) {
                        .empty => {},
                        .one => {
                            self.tail.?.next = vals.head;
                            self.tail = vals.head;
                        },
                        .many => {
                            self.tail.?.next = vals.head;
                            self.tail = vals.tail;
                        },
                    }
                },
            }
        }

        fn len(self: Self) usize {
            var current = self.head;
            var size: usize = 0;
            while (current != null) {
                current = current.?.next;
                size += 1;
            }
            return size;
        }

        const State = enum { empty, one, many };
        inline fn state(self: Self) State {
            if (self.head == null) return .empty;
            if (self.head.? == self.tail.?) return .one;
            return .many;
        }
    };
}

fn getExec(exec: ?*Executor) *Executor {
    if (exec != null) return exec.?;
    if (libcoro.getEnv().executor) |x| return x;
    @panic("No explicit Executor passed and no default Executor available");
}

fn ArrayQueue(comptime T: type, comptime size: usize) type {
    return struct {
        const Self = @This();

        vals: [size]T = undefined,
        head: ?usize = null,
        tail: ?usize = null,

        fn init() Self {
            return .{};
        }

        fn len(self: Self) usize {
            switch (self.state()) {
                .empty => return 0,
                .one => return 1,
                .many => {
                    const head = self.head.?;
                    const tail = self.tail.?;
                    if (tail > head) return tail - head + 1;
                    return size - head + tail + 1;
                },
            }
        }

        fn space(self: Self) usize {
            return size - self.len();
        }

        fn push(self: *@This(), val: T) !void {
            if (self.space() < 1) return error.QueueFull;
            switch (self.state()) {
                .empty => {
                    self.head = 0;
                    self.tail = 0;
                    self.vals[0] = val;
                },
                .one, .many => {
                    const tail = self.tail.?;
                    const new_tail = (tail + 1) % size;
                    self.vals[new_tail] = val;
                    self.tail = new_tail;
                },
            }
        }

        fn pop(self: *Self) ?T {
            switch (self.state()) {
                .empty => return null,
                .one => {
                    const out = self.vals[self.head.?];
                    self.head = null;
                    self.tail = null;
                    return out;
                },
                .many => {
                    const out = self.vals[self.head.?];
                    self.head = (self.head.? + 1) % size;
                    return out;
                },
            }
        }

        const State = enum { empty, one, many };
        inline fn state(self: Self) State {
            if (self.head == null) return .empty;
            if (self.head.? == self.tail.?) return .one;
            return .many;
        }
    };
}

const std = @import("std");
const libcoro = @import("coro.zig");

var gcount: usize = 0;

pub const CoroResume = struct {
    const Self = @This();

    coro: libcoro.Frame,

    pub fn init() Self {
        return .{ .coro = libcoro.xframe() };
    }

    pub fn cb(ud: ?*anyopaque, _: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ud));
        gcount += 1;
        if (gcount > 10) @panic("ahhhh");
        libcoro.xresume(self.coro);
    }

    pub fn waiter(self: *Self) Future.Waiter {
        return .{ .func = Self.cb, .userdata = self };
    }
};

pub const Notification = struct {
    const Self = @This();

    fut: Future,

    pub fn init(exec: *Executor) Self {
        return .{ .fut = Future.init(exec) };
    }

    pub fn notified(self: Self) bool {
        return self.fut.done;
    }

    pub fn notify(self: *Self) void {
        self.fut.set(null);
    }

    pub fn reset(self: *Self) void {
        self.fut.done = false;
    }

    pub fn waitForNotification(self: *Self) void {
        var data = CoroResume.init();
        var waiter = data.waiter();
        self.fut.then(&waiter);
        libcoro.xsuspend();
    }
};

pub const Future = struct {
    const Self = @This();
    const Waiter = struct {
        func: *const fn (userdata: ?*anyopaque, payload: ?*anyopaque) void,
        userdata: ?*anyopaque = null,
        next: ?*Waiter = null,

        fn run(self: @This(), payload: ?*anyopaque) void {
            @call(.auto, self.func, .{ self.userdata, payload });
        }
    };
    const WaiterQueue = Queue(Waiter);

    exec: *Executor,
    done: bool = false,
    payload: ?*anyopaque = null,
    waiters: WaiterQueue = .{},
    next: ?*Future = null,
    setter: ?libcoro.CoroInvocationId = null,

    pub fn init(exec: *Executor) Self {
        return .{ .exec = exec };
    }

    pub fn ready(self: Self) bool {
        return self.done;
    }

    pub fn set(self: *Self, val: ?*anyopaque) void {
        if (self.done) @panic("Cannot set a done Future");
        self.done = true;
        self.payload = val;
        self.setter = libcoro.xframe().id;
        std.debug.print("set from {any}\n", .{self.setter});
        self.exec.ready(self);
    }

    pub fn then(self: *Self, waiter: *Waiter) void {
        if (self.done) @panic("TODO: Unimpl");
        self.waiters.push(waiter);
    }

    fn notifyWaiters(self: *Self) void {
        std.debug.print("notifyWaiters from setter {any}\n", .{self.setter.?.id});
        while (self.waiters.pop()) |waiter| waiter.run(self.payload);
        std.debug.print("notifyWaiters done\n", .{});
    }
};

pub const Executor = struct {
    const Self = @This();

    readyq: Queue(Future) = .{},

    pub fn init() Self {
        return .{};
    }

    pub fn ready(self: *Self, fut: *Future) void {
        self.readyq.push(fut);
    }

    pub fn tick(self: *Self) bool {
        if (self.readyq.pop()) |fut| {
            std.debug.print("tick!\n", .{});
            fut.notifyWaiters();
            return true;
        } else {
            return false;
        }
    }
};

fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        head: ?*T = null,
        tail: ?*T = null,

        fn pop(self: *Self) ?*T {
            if (self.head) |head| {
                if (head == self.tail.?) {
                    self.head = null;
                    self.tail = null;
                } else {
                    self.head = head.next;
                }
                return head;
            } else {
                return null;
            }
        }

        fn push(self: *Self, val: *T) void {
            val.next = null;
            if (self.tail) |tail| {
                const head = self.head.?;
                if (tail == head) {
                    head.next = val;
                    self.tail = val;
                } else {
                    tail.next = val;
                    self.tail = val;
                }
            } else {
                self.head = val;
                self.tail = val;
            }
        }
    };
}

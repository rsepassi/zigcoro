const std = @import("std");
const libcoro = @import("coro.zig");
const libexec = @import("executor.zig");

//const log = std.log.scoped(.channel);
const log = struct {
    fn debug(comptime s: anytype, a: anytype) void {
        std.debug.print(s ++ "\n", a);
    }
};

pub const ChannelConfig = struct {};

pub fn Channel(comptime T: type, comptime config: ChannelConfig) type {
    _ = config;

    return struct {
        const Self = @This();

        val: ?T = null,
        closed: bool = false,

        exec: *libexec.Executor,
        space_notif: libexec.Notification,
        value_notif: libexec.Notification,

        pub fn init(exec: *libexec.Executor) Self {
            return .{
                .exec = exec,
                .space_notif = libexec.Notification.init(exec),
                .value_notif = libexec.Notification.init(exec),
            };
        }

        pub fn close(self: *Self) void {
            log.debug("close", .{});
            self.closed = true;
            self.notifyValue();
        }

        pub fn send(self: *Self, val: T) void {
            log.debug("send", .{});
            if (self.closed) @panic("Cannot send on closed Channel");
            while (self.hasValue()) self.waitForSpace();
            self.val = val;
            self.notifyValue();
        }

        pub fn recv(self: *Self) ?T {
            log.debug("recv", .{});
            while (!self.closed and !self.hasValue()) self.waitForValue();
            if (self.closed and !self.hasValue()) return null;
            std.debug.assert(self.hasValue());
            const out = self.val.?;
            self.val = null;
            self.notifySpace();
            return out;
        }

        inline fn hasValue(self: *Self) bool {
            return self.val != null;
        }

        fn waitForSpace(self: *Self) void {
            log.debug("waitForSpace", .{});
            self.space_notif.waitForNotification();
            std.debug.assert(!self.hasValue());
            self.space_notif.reset();
            log.debug("waitForSpace done", .{});
        }

        fn waitForValue(self: *Self) void {
            log.debug("waitForValue", .{});
            self.value_notif.waitForNotification();
            std.debug.assert(self.hasValue());
            self.value_notif.reset();
            log.debug("waitForValue done", .{});
        }

        fn notifySpace(self: *Self) void {
            self.space_notif.notify();
        }

        fn notifyValue(self: *Self) void {
            self.value_notif.notify();
        }
    };
}

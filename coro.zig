const std = @import("std");
const builtin = @import("builtin");

const base = switch (builtin.cpu.arch) {
    .aarch64 => @import("coro_arm64.zig"),
    else => @compileError("Unsupported cpu architecture"),
};

threadlocal var root_coro = base.Coro.root();
threadlocal var current_coro: ?*base.Coro = null;

pub const stack_align = base.stack_align;

pub const Coro = struct {
    func: *const fn (
        from: *Coro,
        self: *Coro,
    ) void,
    base: base.Coro,

    const Self = @This();
    const Func = *const fn (
        from: *Coro,
        self: *Coro,
    ) void;

    pub fn init(func: Func, stack: []align(stack_align) u8) Self {
        return .{ .func = func, .base = base.Coro.init(&jump, stack) };
    }

    pub fn xresume(self: *Self) void {
        const from = current_coro orelse &root_coro;
        defer current_coro = from;
        current_coro = &self.base;
        self.base.resume_from(from);
    }
};

fn jump(from: *base.Coro, target: *base.Coro) callconv(.C) noreturn {
    const fromcoro = @fieldParentPtr(Coro, "base", from);
    const targetcoro = @fieldParentPtr(Coro, "base", target);
    targetcoro.func(fromcoro, targetcoro);

    @panic(std.fmt.allocPrint(std.heap.c_allocator, "Coroutine already completed {*}", .{targetcoro}) catch {
        @panic("Coroutine already completed");
    });
}

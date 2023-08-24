const std = @import("std");

pub const stack_align = 16;

// Swaps from the current coroutine to the target coroutine.
// Mutates the stack pointer in current to suspend it.
// Loads the stack pointer in target to resume it.
// Defined in assembly.
extern fn libcoro_stack_swap(current: *Coro, target: *Coro) void;
comptime {
    asm (@embedFile("coro_arm64.s"));
}

// Low-level coroutine context used by libcoro_stack_swap.
pub const Coro = packed struct {
    stack_pointer: ?[*]u8, // only null for root fiber

    const Self = @This();
    const Func = *const fn (
        from: *Coro,
        self: *Coro,
    ) callconv(.C) noreturn;

    pub fn root() Self {
        return .{ .stack_pointer = null };
    }

    pub fn init(func: Func, stack: []align(stack_align) u8) Self {
        // Zero out register space
        const register_bytes = 0xa0;
        var register_space = stack[stack.len - register_bytes ..];
        @memset(register_space, 0);

        // Set link register to func
        const fnptr_size = @sizeOf(@TypeOf(func));
        var lr_space = stack[stack.len - fnptr_size ..];
        const fn_ptr: [fnptr_size]u8 = @bitCast(@intFromPtr(func));
        @memcpy(lr_space, &fn_ptr);

        // Set the stack pointer to the bottom of the register space
        return .{ .stack_pointer = register_space.ptr };
    }

    pub fn resume_from(self: *Self, from: *Self) void {
        libcoro_stack_swap(from, self);
    }
};

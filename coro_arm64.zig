const std = @import("std");
const Error = @import("errors.zig").Error;

pub const stack_align = 16;
const num_registers = 20;

extern fn libcoro_stack_swap(current: *Coro, target: *Coro) void;
comptime {
    asm (@embedFile("coro_arm64.s"));
}

pub const Coro = packed struct {
    stack_pointer: [*]u8,

    const Self = @This();
    const Func = *const fn (
        from: *Coro,
        self: *Coro,
    ) callconv(.C) noreturn;

    pub fn init(func: Func, stack: []align(stack_align) u8) !Self {
        if (@sizeOf(usize) != 8) @compileError("arm64 usize expected to take 8 bytes");
        if (@sizeOf(*Func) != 8) @compileError("arm64 function pointer expected to take 8 bytes");
        const register_bytes = num_registers * 8;
        if (stack.len < register_bytes) return Error.StackTooSmall;

        // Top of the stack is the end of stack
        const sp = stack.ptr + stack.len;

        // Set link register (last value on the stack) to func
        const lr: *Func = @ptrCast(@alignCast(sp - @sizeOf(*Func)));
        lr.* = func;

        // Set the stack pointer to the bottom of the register space
        return .{ .stack_pointer = sp - register_bytes };
    }

    pub inline fn resumeFrom(self: *Self, from: *Self) void {
        libcoro_stack_swap(from, self);
    }
};

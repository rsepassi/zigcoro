const std = @import("std");
const Error = @import("errors.zig").Error;

const ArchInfo = struct {
    num_registers: usize,
    assembly: []u8,
};
const arch_info: ArchInfo = switch (@import("builtin").os.tag) {
    .windows => .{
        .num_registers = 30,
        .assembly = @embedFile("coro_amd64_windows.s"),
    },
    else => .{
        .num_registers = 6,
        .assembly = @embedFile("coro_amd64.s"),
    },
};

pub const stack_align = 16;
const num_registers = arch_info.num_registers;

extern fn libcoro_stack_swap(current: *Coro, target: *Coro) void;
comptime {
    asm (arch_info.assembly);
}

pub const Coro = packed struct {
    stack_pointer: [*]u8,

    const Self = @This();
    const Func = *const fn (
        from: *Coro,
        self: *Coro,
    ) callconv(.C) noreturn;

    pub fn init(func: Func, stack: []align(stack_align) u8) !Self {
        if (@sizeOf(usize) != 8) @compileError("amd64 usize expected to take 8 bytes");
        if (@sizeOf(*Func) != 8) @compileError("amd64 function pointer expected to take 8 bytes");

        // Top of the stack is the end of stack
        const sp = stack.ptr + stack.len;

        // Define an aligned pointer to func at the top of the stack
        const jump: *Func = @ptrFromInt(std.mem.alignBackward(
            usize,
            @intFromPtr(sp - @sizeOf(*Func)),
            stack_align,
        ));

        const register_bytes = num_registers * 8;
        const rp: [*]u8 = @ptrFromInt(@intFromPtr(jump) - register_bytes);
        if (@intFromPtr(rp) < @intFromPtr(stack.ptr)) return Error.StackTooSmall;

        jump.* = func;

        // Set the stack pointer to the bottom of the register space
        return .{ .stack_pointer = rp };
    }

    pub inline fn resumeFrom(self: *Self, from: *Self) void {
        libcoro_stack_swap(from, self);
    }
};

const std = @import("std");
const Error = @import("errors.zig").Error;

const ArchInfo = struct {
    num_registers: usize,
    jump_idx: usize,
    assembly: []const u8,
};
const arch_info: ArchInfo = switch (@import("builtin").os.tag) {
    .windows => .{
        .num_registers = 32,
        .jump_idx = 30,
        .assembly = @embedFile("coro_amd64_windows.s"),
    },
    else => .{
        .num_registers = 8,
        .jump_idx = 6,
        .assembly = @embedFile("coro_amd64.s"),
    },
};

pub const stack_align = 16;

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
        if (@sizeOf(usize) != 8) @compileError("usize expected to take 8 bytes");
        if (@sizeOf(*Func) != 8) @compileError("function pointer expected to take 8 bytes");
        const register_bytes = arch_info.num_registers * 8;
        if (register_bytes > stack.len) return Error.StackTooSmall;
        const register_space = stack[stack.len - register_bytes ..];
        const jump_ptr: *Func = @ptrCast(@alignCast(&register_space[arch_info.jump_idx * 8]));
        jump_ptr.* = func;
        return .{ .stack_pointer = register_space.ptr };
    }

    pub inline fn resumeFrom(self: *Self, from: *Self) void {
        libcoro_stack_swap(from, self);
    }
};

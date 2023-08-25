const std = @import("std");
const builtin = @import("builtin");

pub const Error = @import("errors.zig").Error;

pub const StackT = []align(base.stack_align) u8;
pub const stack_align = base.stack_align;
pub const default_stack_size = 1024 * 2;

const magic_number: usize = 0x5E574D6D;

threadlocal var root_coro: Coro = undefined;
threadlocal var from_coro: *Coro = undefined;
threadlocal var current_coro: ?*Coro = null;

pub inline fn xsuspend() void {
    xsuspend_safe() catch unreachable;
}

pub inline fn xsuspend_safe() Error!void {
    if (current_coro == null) return Error.SuspendFromMain;
    try check_stack_overflow();
    from_coro.xresume();
}

pub inline fn xresume(c: *Coro) void {
    c.xresume();
}

inline fn check_stack_overflow() !void {
    const current = current_coro.?;
    const stack = current.stack.ptr;
    const sp = current.impl.stack_pointer;
    const magic_number_ptr: *usize = @ptrCast(stack);
    if (magic_number_ptr.* != magic_number or @intFromPtr(sp) < @intFromPtr(stack)) {
        return Error.StackOverflow;
    }
}

pub const Coro = struct {
    // Caller-provided stack
    stack: StackT,
    // Architecture-specific coroutine impl
    impl: base.Coro,
    // Whether the user-provided function has run to completion
    done: bool = false,
    allocator: ?std.mem.Allocator = null,

    const Self = @This();

    pub fn initAlloc(func: anytype, args: anytype, allocator: std.mem.Allocator, stack_size: ?usize) !*Self {
        var stack = try allocator.alignedAlloc(u8, stack_align, stack_size orelse default_stack_size);
        const out = try init(func, args, stack);
        out.allocator = allocator;
        return out;
    }

    pub fn init(
        func: anytype,
        args: anytype,
        stack: StackT,
    ) !*Self {
        // State to store in stack
        const State = struct {
            coro: Coro,
            func: *const @TypeOf(func),
            args: @TypeOf(args),
        };

        // Wrapping function to trigger stack swap
        const swap = (struct {
            fn swap(from: *base.Coro, target: *base.Coro) callconv(.C) noreturn {
                // Look up Coro
                from_coro = @fieldParentPtr(Self, "impl", from);
                const target_coro = @fieldParentPtr(Self, "impl", target);

                // Run the user function.
                const target_state = @fieldParentPtr(State, "coro", target_coro);
                @call(.auto, target_state.func, target_state.args);

                // Mark the coroutine done and resume the calling coroutine.
                target_coro.done = true;
                from_coro.xresume();

                // Never returns
                const err_msg = "Cannot resume an already completed coroutine {*}";
                @panic(std.fmt.allocPrint(
                    std.heap.c_allocator,
                    err_msg,
                    .{target_state},
                ) catch {
                    @panic(err_msg);
                });
            }
        }.swap);

        // Store State at the top of stack
        var state_ptr = @intFromPtr(stack.ptr + stack.len - @sizeOf(State));
        state_ptr = std.mem.alignBackward(usize, state_ptr, @alignOf(State));
        if (state_ptr == 0) return Error.StackTooSmall;
        var state: *State = @ptrFromInt(state_ptr);

        // Store magic number for stack overflow detection
        const magic_number_ptr: *usize = @ptrCast(stack.ptr);
        magic_number_ptr.* = magic_number;

        // Ensure the remaining stack is well-aligned
        const new_end_ptr = std.mem.alignBackward(usize, state_ptr, base.stack_align);
        var reduced_stack = stack[0 .. new_end_ptr - @intFromPtr(stack.ptr)];

        if (@intFromPtr(magic_number_ptr) >= new_end_ptr) return Error.StackTooSmall;

        // Create the underlying coroutine
        const base_coro = try base.Coro.init(&swap, reduced_stack);
        const coro = Self{ .stack = stack, .impl = base_coro };
        state.* = .{
            .coro = coro,
            .func = func,
            .args = args,
        };

        return &state.coro;
    }

    pub fn deinit(self: *Self) void {
        if (self.allocator) |a| {
            a.free(self.stack);
        }
    }

    // Switch to this coroutine.
    // Calling coroutine will be suspended.
    inline fn xresume(self: *Self) void {
        const from = current_coro orelse &root_coro;
        defer current_coro = from;
        current_coro = self;
        self.impl.resume_from(&from.impl);
    }
};

const base = switch (builtin.cpu.arch) {
    .aarch64 => @import("coro_arm64.zig"),
    else => @compileError("Unsupported cpu architecture"),
};

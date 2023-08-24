const std = @import("std");
const builtin = @import("builtin");

pub const StackT = []align(base.stack_align) u8;
pub const stack_align = base.stack_align;

threadlocal var root_coro: Coro = undefined;
threadlocal var from_coro: ?*Coro = null;
threadlocal var current_coro: ?*Coro = null;

pub fn yield() void {
    from_coro.?.xresume();
}

pub fn current() *Coro {
    return current_coro.?;
}

pub const Coro = struct {
    // Caller-provided stack
    stack: StackT,
    // Architecture-specific coroutine impl
    impl: base.Coro,
    // Whether the user-provided function has run to completion
    done: bool = false,
    // Type-erased pointer to user-specified function and args
    state: *anyopaque,

    const Self = @This();

    pub fn init(
        func: anytype,
        args: anytype,
        stack: StackT,
    ) *Self {
        const State = struct {
            coro: Self,
            func: *const @TypeOf(func),
            args: @TypeOf(args),

            fn run(self: @This()) void {
                @call(.auto, self.func, self.args);
            }
        };

        // Store State at the end of the stack
        var coro_ptr = @intFromPtr(stack.ptr + stack.len - @sizeOf(State));
        coro_ptr = std.mem.alignBackward(usize, coro_ptr, @alignOf(State));

        const new_end_ptr = std.mem.alignBackward(usize, coro_ptr, base.stack_align);
        var reduced_stack = stack[0 .. new_end_ptr - @intFromPtr(stack.ptr)];

        const swap = (struct {
            fn swap(from: *base.Coro, target: *base.Coro) callconv(.C) noreturn {
                from_coro = @fieldParentPtr(Self, "impl", from);
                const target_coro = @fieldParentPtr(Self, "impl", target);
                const target_state: *State = @ptrCast(@alignCast(target_coro.state));
                target_state.run();
                target_coro.done = true;
                from_coro.?.xresume();

                @panic(std.fmt.allocPrint(
                    std.heap.c_allocator,
                    "Coroutine already completed {*}",
                    .{target_state},
                ) catch {
                    @panic("Coroutine already completed");
                });
            }
        }.swap);

        const base_coro = base.Coro.init(&swap, reduced_stack);
        var state: *State = @ptrFromInt(coro_ptr);
        const coro = Self{ .stack = stack, .impl = base_coro, .state = state };
        state.* = .{
            .coro = coro,
            .func = func,
            .args = args,
        };

        return &state.coro;
    }

    pub fn xresume(self: *Self) void {
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

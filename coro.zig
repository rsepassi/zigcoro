const std = @import("std");
const builtin = @import("builtin");
const base = switch (builtin.cpu.arch) {
    .aarch64 => @import("coro_arm64.zig"),
    .x86_64 => switch (builtin.os.tag) {
        .windows => @import("coro_amd64_windows.zig"),
        else => @import("coro_amd64.zig"),
    },
    else => @compileError("Unsupported cpu architecture"),
};

// libcoro mutable state:
// * ThreadState.current_coro: set in ThreadState.switchTo
// * Coro
//   * resumer: set in ThreadState.switchTo
//   * status:
//     * Active, Suspended: set in ThreadState.switchTo
//     * Done: set in runcoro
//   * id.invocation: incremented in ThreadState.switchTo

threadlocal var thread_state: ThreadState = .{};
const ThreadState = struct {
    root_coro: Coro = .{
        .stack = undefined,
        .impl = undefined,
        .resumer = undefined,
        .id = CoroInvocationId.root(),
    },
    current_coro: ?*Coro = null,
    next_coro_id: usize = 1,

    fn switchTo(self: *@This(), target: *Coro) void {
        const resumer = self.current();
        if (resumer.statusval != .Done) resumer.statusval = .Suspended;
        target.resumer = resumer;
        target.statusval = .Active;
        target.id.incr();
        self.current_coro = target;
        target.impl.resumeFrom(&resumer.impl);
    }

    fn nextCoroId(self: *@This()) CoroId {
        const out = .{
            .thread = std.Thread.getCurrentId(),
            .coro = self.next_coro_id,
        };
        self.next_coro_id += 1;
        return out;
    }

    fn current(self: *@This()) *Coro {
        return self.current_coro orelse &self.root_coro;
    }
};

// Public API
// ============================================================================
pub const Error = @import("errors.zig").Error;
pub const StackT = []align(base.stack_align) u8;
pub const stack_align = base.stack_align;
pub const default_stack_size = 1024 * 4;

pub const AsyncOptions = struct {
    yieldT: ?type = null,
};

pub const AsyncStatus = enum {
    Suspended,
    Active,
    Done,
};

// Create a coroutine, initially suspended.
pub fn xasync(
    func: anytype,
    args: anytype,
    stack: StackT,
    comptime options: AsyncOptions,
) !CoroFromFn(@TypeOf(func), options) {
    return try CoroFromFn(@TypeOf(func), options).init(func, args, stack);
}

// Create a coroutine with an allocated stack, initially suspended.
// Caller is responsible for calling deinit() to free allocated stack.
pub fn xasyncAlloc(
    func: anytype,
    args: anytype,
    allocator: std.mem.Allocator,
    stack_size: ?usize,
    comptime options: AsyncOptions,
) !CoroFromFn(@TypeOf(func), options) {
    var stack = try allocator.alignedAlloc(u8, stack_align, stack_size orelse default_stack_size);
    const out = try xasync(func, args, stack, options);
    out.coro.allocator = allocator;
    return out;
}

// Resume the passed coroutine, suspending the current coroutine.
// coro: Coro, CoroT
pub fn xresume(coro: anytype) void {
    thread_state.switchTo(getcoro(coro));
}

// Await the result of the passed coroutine, suspending the current coroutine.
// coro: CoroT
pub fn xawait(coro: anytype) @TypeOf(coro).AwaitT {
    while (coro.status() != .Done) {
        thread_state.switchTo(coro.coro);
    }
    const state = coro.getState();
    return state.retval;
}

// Await the next yield of the passed coroutine, suspending the current coroutine.
// coro: CoroT
pub fn xnext(coro: anytype) @TypeOf(coro).YieldT {
    thread_state.switchTo(coro.coro);
    const state = @fieldParentPtr(@TypeOf(coro).State0, "coro", coro.coro);
    const out = state.retval;
    state.retval = null;
    return out;
}

// Suspend the current coroutine, yielding control back to the last resumer.
pub fn xsuspend() void {
    xsuspendSafe() catch unreachable;
}
pub fn xsuspendSafe() Error!void {
    if (thread_state.current_coro) |coro| {
        try check_stack_overflow(coro);
        thread_state.switchTo(coro.resumer);
    } else {
        return Error.SuspendFromMain;
    }
}

// Yield a value from the current coroutine and suspend, yielding control back
// to the last resumer.
pub fn xyield(val: anytype) void {
    const coro = CoroT(OptionalOf(@TypeOf(val)), .{}).wrap(
        thread_state.current_coro.?,
    );
    coro.setStorage(val);
    xsuspend();
}

const CoroId = struct {
    thread: std.Thread.Id,
    coro: usize,
};

const CoroInvocationId = struct {
    id: CoroId,
    invocation: i64 = -1,

    fn init() @This() {
        return .{ .id = thread_state.nextCoroId() };
    }

    fn root() @This() {
        return .{ .id = .{ .thread = 0, .coro = 0 } };
    }

    fn incr(self: *@This()) void {
        self.invocation += 1;
    }
};

pub const Coro = struct {
    stack: StackT,
    impl: base.Coro,
    resumer: *Coro = undefined,
    statusval: AsyncStatus = .Suspended,
    allocator: ?std.mem.Allocator = null,
    id: CoroInvocationId,

    const Self = @This();

    fn init(
        func: anytype,
        args: anytype,
        stack: StackT,
        comptime options: AsyncOptions,
    ) !CoroFromFn(@TypeOf(func), options) {
        return try CoroFromFn(@TypeOf(func), options).init(func, args, stack);
    }

    pub fn deinit(self: *Self) void {
        if (self.allocator) |a| a.free(self.stack);
    }

    pub fn status(self: Self) AsyncStatus {
        return self.statusval;
    }
};

fn CoroT(comptime RetT: type, comptime options: AsyncOptions) type {
    const StorageT = blk: {
        if (options.yieldT) |T| {
            if (RetT != void and T != RetT) @compileError("yield type must match return type, or return type must be void");
            break :blk OptionalOf(T);
        } else {
            break :blk RetT;
        }
    };

    return struct {
        const Self = @This();
        const AwaitT = RetT;
        const YieldT =
            if (@typeInfo(StorageT) != .Optional) @compileError(std.fmt.comptimePrint("coro.next() requires an optional yield type, but this coroutine has yield type {any}", .{StorageT})) else StorageT;

        coro: *Coro,

        // Partial state to store in stack
        // State is split so that the type only depends on
        // StorageT.
        const State0 = struct {
            coro: Coro,
            retval: StorageT = undefined,
        };

        fn wrap(coro: *Coro) Self {
            return .{ .coro = coro };
        }

        fn init(
            func: anytype,
            args: anytype,
            stack: StackT,
        ) !Self {
            // State to store in stack
            const State = struct {
                state0: State0,
                func: *const @TypeOf(func),
                args: @TypeOf(args),
            };

            // Wrapping function to create coroutine
            const runcoro = (struct {
                fn runcoro(resumer: *base.Coro, target: *base.Coro) callconv(.C) noreturn {
                    const resumer_coro = @fieldParentPtr(Coro, "impl", resumer);
                    const target_coro = @fieldParentPtr(Coro, "impl", target);

                    // Run the user function.
                    const target_state = @fieldParentPtr(State, "state0", @fieldParentPtr(State0, "coro", target_coro));
                    const retval = @call(.auto, target_state.func, target_state.args);

                    // Mark the coroutine done and resume the calling coroutine.
                    if (RetT != void) {
                        target_state.state0.retval = retval;
                    }
                    target_coro.statusval = .Done;
                    // std.debug.print("runcoro done: {any}\n", .{target_coro.id});
                    thread_state.switchTo(resumer_coro);

                    // Never returns
                    const err_msg = "Cannot resume an already completed coroutine {any}";
                    @panic(std.fmt.allocPrint(
                        std.heap.c_allocator,
                        err_msg,
                        .{target_coro.id},
                    ) catch {
                        @panic(err_msg);
                    });
                }
            }.runcoro);

            // Store State at the top of stack
            var state_ptr = @intFromPtr(stack.ptr + stack.len - @sizeOf(State));
            state_ptr = std.mem.alignBackward(usize, state_ptr, @alignOf(State));
            if (state_ptr == 0) return Error.StackTooSmall;
            var state: *State = @ptrFromInt(state_ptr);

            // Store magic number for stack overflow detection at
            // the beginning of the stack. If it is ever
            // overwritten, we'll know that the stack was
            // overflowed.
            const magic_number_ptr: *usize = @ptrCast(stack.ptr);
            magic_number_ptr.* = magic_number;

            // Ensure the remaining stack is well-aligned
            const new_end_ptr = std.mem.alignBackward(usize, state_ptr, base.stack_align);
            var reduced_stack = stack[0 .. new_end_ptr - @intFromPtr(stack.ptr)];

            if (@intFromPtr(magic_number_ptr) >= new_end_ptr) return Error.StackTooSmall;

            // Create the underlying coroutine
            const base_coro = try base.Coro.init(&runcoro, reduced_stack);
            const coro = Coro{ .stack = stack, .impl = base_coro, .id = CoroInvocationId.init() };
            state.* = .{
                .state0 = .{
                    .coro = coro,
                },
                .func = func,
                .args = args,
            };

            return .{ .coro = &state.state0.coro };
        }

        pub fn deinit(self: *Self) void {
            self.coro.deinit();
        }

        pub fn status(self: Self) AsyncStatus {
            return self.coro.statusval;
        }

        fn getState(self: Self) *State0 {
            return @fieldParentPtr(State0, "coro", self.coro);
        }

        fn setStorage(self: Self, val: StorageT) void {
            const state = @fieldParentPtr(State0, "coro", self.coro);
            state.retval = val;
        }
    };
}

// ============================================================================

// {*Coro, CoroT} -> Coro
fn getcoro(coro: anytype) *Coro {
    if (@TypeOf(coro) == *Coro) {
        return coro;
    } else {
        return coro.coro;
    }
}

const magic_number: usize = 0x5E574D6D;

fn check_stack_overflow(coro: *Coro) !void {
    const stack = coro.stack.ptr;
    const sp = coro.impl.stack_pointer;
    const magic_number_ptr: *usize = @ptrCast(stack);
    if (magic_number_ptr.* != magic_number or //
        @intFromPtr(sp) < @intFromPtr(stack))
    {
        return Error.StackOverflow;
    }
}

fn CoroFromFn(comptime Fn: type, comptime options: AsyncOptions) type {
    const RetT = @typeInfo(Fn).Fn.return_type.?;
    return CoroT(RetT, options);
}

fn OptionalOf(comptime T: type) type {
    const info = std.builtin.Type{ .Optional = .{ .child = T } };
    return @Type(info);
}

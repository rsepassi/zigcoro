const std = @import("std");
const builtin = @import("builtin");
const base = @import("coro_base.zig");

// libcoro mutable state:
// * ThreadState
//   * current_coro: set in ThreadState.switchTo
//   * next_coro_id: set in ThreadState.nextCoroId
// * Coro
//   * resumer: set in ThreadState.switchTo
//   * status:
//     * Active, Suspended: set in ThreadState.switchTo
//     * Done, Error: set in runcoro
//   * id.invocation: incremented in ThreadState.switchTo

// Public API
// ============================================================================
pub const Error = @import("errors.zig").Error;
pub const StackT = []align(base.stack_align) u8;
pub const stack_align = base.stack_align;
pub const default_stack_size = 1024 * 4;

pub const AsyncOptions = struct {
    YieldT: ?type = null,
};

pub const AsyncStatus = enum {
    Suspended,
    Active,
    Done,
    Error,

    fn complete(self: @This()) bool {
        return self == .Error or self == .Done;
    }
};

// Create a coroutine, initially suspended.
pub fn xcoro(
    func: anytype,
    args: anytype,
    stack: StackT,
    comptime options: AsyncOptions,
) !CoroFromFn(@TypeOf(func), options) {
    return try CoroFromFn(@TypeOf(func), options).init(func, args, stack);
}

// Create a coroutine with an allocated stack, initially suspended.
// Caller is responsible for calling deinit() to free allocated stack.
pub fn xcoroAlloc(
    func: anytype,
    args: anytype,
    allocator: std.mem.Allocator,
    stack_size: ?usize,
    comptime options: AsyncOptions,
) !CoroFromFn(@TypeOf(func), options) {
    var stack = try allocator.alignedAlloc(u8, base.stack_align, stack_size orelse default_stack_size);
    const out = try xcoro(func, args, stack, options);
    out.coro.allocator = allocator;
    return out;
}

// Resume the passed coroutine, suspending the current coroutine.
// coro: CoroT
pub fn xresume(coro: anytype) @TypeOf(coro).ResumeT {
    thread_state.switchIn(getcoro(coro));
    return coro.getError();
}

// Await the result of the passed coroutine, suspending the current coroutine.
// coro: CoroT
pub fn xawait(coro: anytype) @TypeOf(coro).AwaitT {
    while (!coro.status().complete()) {
        thread_state.switchIn(coro.coro);
    }
    return coro.getStorage().popAwait();
}

// Await the next yield of the passed coroutine, suspending the current coroutine.
// coro: CoroT
pub fn xnext(coro: anytype) @TypeOf(coro).NextT {
    thread_state.switchIn(coro.coro);
    return coro.getStorage().popNext();
}

// Suspend the current coroutine, yielding control back to the last resumer.
pub fn xsuspend() void {
    xsuspendSafe() catch unreachable;
}
pub fn xsuspendSafe() Error!void {
    if (thread_state.current_coro) |coro| {
        try check_stack_overflow(coro);
        thread_state.switchOut(coro.resumer);
    } else {
        return Error.SuspendFromMain;
    }
}

// Yield a value from the current coroutine and suspend, yielding control back
// to the last resumer.
pub fn xyield(val: anytype) void {
    const coro = thread_state.current_coro.?;
    coro.yield(@ptrCast(&val));
    xsuspend();
}

pub const Coro = struct {
    stack: StackT,
    impl: base.Coro,
    resumer: *Coro = undefined,
    statusval: AsyncStatus = .Suspended,
    allocator: ?std.mem.Allocator = null,
    id: CoroInvocationId,
    yieldfn: *const fn (*Coro, *const anyopaque) void,

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

    fn yield(self: *Self, ptr: *const anyopaque) void {
        self.yieldfn(self, ptr);
    }
};

// Use CoroT(A, B).wrap(coro) to get a typed coroutine from an untyped one
pub fn CoroT(comptime RetT: type, comptime YieldT: ?type) type {
    return CoroTInner(RetT, YieldT);
}
// ============================================================================

threadlocal var thread_state: ThreadState = .{};
const ThreadState = struct {
    root_coro: Coro = .{
        .stack = undefined,
        .impl = undefined,
        .resumer = undefined,
        .yieldfn = undefined,
        .id = CoroInvocationId.root(),
    },
    current_coro: ?*Coro = null,
    next_coro_id: usize = 1,

    // Called from resume, next, await
    fn switchIn(self: *@This(), target: *Coro) void {
        self.switchTo(target, true);
    }

    // Called from suspend, yield
    fn switchOut(self: *@This(), target: *Coro) void {
        self.switchTo(target, false);
    }

    fn switchTo(self: *@This(), target: *Coro, set_resumer: bool) void {
        const resumer = self.current();
        if (!resumer.status().complete()) resumer.statusval = .Suspended;
        if (set_resumer) target.resumer = resumer;
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

fn CoroStorage(comptime RetT: type, comptime mYieldT: ?type) type {
    const can_error = @typeInfo(RetT) == .ErrorUnion;
    return struct {
        const YieldT = (mYieldT orelse RetT);
        const NextT = if (can_error) anyerror!?YieldT else ?YieldT;
        storage: ?union(enum) {
            ret: RetT,
            yield: YieldT,
        } = null,

        const Self = @This();

        fn setReturn(self: *Self, val: RetT) void {
            self.storage = .{ .ret = val };
        }

        fn popAwait(self: *Self) RetT {
            if (self.storage == null) @panic("xawait called, but coroutine never returned a value");
            switch (self.storage.?) {
                .ret => |val| {
                    self.storage = null;
                    return val;
                },
                else => @panic("xawait called, but coroutine did not return a value. It did yield a value though. Did you mean to call xnext?"),
            }
        }

        fn setYield(self: *Self, val: YieldT) void {
            self.storage = .{ .yield = val };
        }

        fn popNext(self: *Self) NextT {
            if (self.storage == null) return null;
            switch (self.storage.?) {
                .ret => |val| {
                    if (can_error) {
                        if (val) {
                            return null;
                        } else |err| {
                            return err;
                        }
                    } else {
                        return null;
                    }
                },
                .yield => |val| {
                    self.storage = null;
                    return val;
                },
            }
        }

        fn getError(self: Self) ?anyerror {
            if (!can_error) return null;
            if (self.storage == null) return null;
            switch (self.storage.?) {
                .ret => |val| {
                    if (val) {
                        return null;
                    } else |err| {
                        return err;
                    }
                },
                .yield => {
                    return null;
                },
            }
        }
    };
}

fn CoroTInner(comptime RetT: type, comptime maybeYieldT: ?type) type {
    const StorageT = CoroStorage(RetT, maybeYieldT);
    const can_error = @typeInfo(RetT) == .ErrorUnion;

    return struct {
        const Self = @This();

        const AwaitT = RetT;
        const ResumeT = if (can_error) anyerror!void else void;
        const NextT = StorageT.NextT;

        coro: *Coro,

        // Partial state to store in stack
        // State is split so that the type only depends on StorageT.
        const State0 = struct {
            coro: Coro,
            storage: StorageT = .{},
        };

        pub fn wrap(coro: *Coro) Self {
            return .{ .coro = coro };
        }

        fn init(
            func: anytype,
            args: std.meta.ArgsTuple(@TypeOf(func)),
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
                    _ = resumer_coro;
                    const target_coro = @fieldParentPtr(Coro, "impl", target);

                    // Run the user function.
                    const target_state = @fieldParentPtr(State, "state0", @fieldParentPtr(State0, "coro", target_coro));
                    const retval = @call(.auto, target_state.func, target_state.args);

                    // Mark the coroutine done and resume the calling coroutine.
                    target_state.state0.storage.setReturn(retval);

                    if (@typeInfo(@TypeOf(retval)) == .ErrorUnion) {
                        if (std.meta.isError(retval)) {
                            target_coro.statusval = .Error;
                        } else {
                            target_coro.statusval = .Done;
                        }
                    } else {
                        target_coro.statusval = .Done;
                    }
                    thread_state.switchOut(target_coro.resumer);

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

            const yieldfn = (struct {
                fn yieldfn(coro: *Coro, ptr: *const anyopaque) void {
                    const target_state = @fieldParentPtr(State, "state0", @fieldParentPtr(State0, "coro", coro));
                    const val: *const StorageT.YieldT = @ptrCast(@alignCast(ptr));
                    target_state.state0.storage.setYield(val.*);
                }
            }).yieldfn;

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
            const coro = Coro{
                .stack = stack,
                .impl = base_coro,
                .id = CoroInvocationId.init(),
                .yieldfn = yieldfn,
            };
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

        fn getStorage(self: Self) *StorageT {
            const state = @fieldParentPtr(State0, "coro", self.coro);
            return &state.storage;
        }

        fn getError(self: Self) ResumeT {
            if (!can_error) return;
            const err = self.getStorage().getError();
            if (err) |e| return e;
        }
    };
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
    return CoroT(RetT, options.YieldT);
}

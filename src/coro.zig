const std = @import("std");
const builtin = @import("builtin");
const base = @import("coro_base.zig");
const libcoro_options = @import("libcoro_options");

const log = std.log.scoped(.libcoro);
const debug_log_level = libcoro_options.debug_log_level;

// libcoro mutable state:
// * ThreadState
//   * current_coro: set in ThreadState.switchTo
//   * next_coro_id: set in ThreadState.nextCoroId
//   * suspend_block: set in xsuspendBlock, cleared in ThreadState.switchIn
// * Coro
//   * resumer: set in ThreadState.switchTo
//   * status:
//     * Active, Suspended: set in ThreadState.switchTo
//     * Done: set in runcoro
//   * id.invocation: incremented in ThreadState.switchTo

// Public API
// ============================================================================
pub const Error = @import("errors.zig").Error;
pub const StackT = []align(base.stack_alignment) u8;
pub const stack_alignment = base.stack_alignment;
pub const default_stack_size = libcoro_options.default_stack_size;

pub const allocators = struct {
    pub const FixedSizeFreeListAllocator = @import("allocator.zig").FixedSizeFreeListAllocator;
};

pub const Frame = *Coro;

pub const Env = struct {
    stack_allocator: ?std.mem.Allocator = null,
    default_stack_size: ?usize = null,
};
threadlocal var env: Env = .{};
pub fn initEnv(e: Env) void {
    env = e;
}

const StackInfo = struct {
    stack: StackT,
    owned: bool,
};
fn getStack(stack: anytype) !StackInfo {
    const T = @TypeOf(stack);
    const is_optional = @typeInfo(T) == .Optional;
    if (T == @TypeOf(null) or (is_optional and stack == null)) {
        if (env.stack_allocator == null) @panic("No explicit stack passed and no default stack allocator available");
        return .{ .stack = try stackAlloc(env.stack_allocator.?, env.default_stack_size), .owned = true };
    } else if (T == comptime_int or T == usize) {
        const stack_size: usize = @intCast(stack);
        if (env.stack_allocator == null) @panic("No explicit stack passed and no default stack allocator available");
        return .{ .stack = try stackAlloc(env.stack_allocator.?, stack_size), .owned = true };
    } else if (is_optional) {
        return .{ .stack = stack.?, .owned = false };
    } else {
        return .{ .stack = stack, .owned = false };
    }
}

// Await the coroutine(s).
// frame: FrameT: runs the coroutine until done and returns its return value.
pub fn xawait(frame: anytype) xawaitT(@TypeOf(frame)) {
    const f = frame.frame();
    while (f.status != .Done) xsuspend();
    return frame.xreturned();
}

fn xawaitT(comptime T: type) type {
    return if (T == Frame) void else T.Signature.ReturnT();
}

// Create a coroutine and start it
// stack is {null, usize, StackT}. If null or usize, initEnv must have been
// called with a default stack allocator.
pub fn xasync(func: anytype, args: anytype, stack: anytype) !FrameT(func) {
    const stack_info = try getStack(stack);
    const framet = try CoroT.fromFunc(func, .{}).init(args, stack_info.stack, stack_info.owned);
    var frame = framet.frame();
    xresume(frame);
    return FrameT(func).wrap(frame);
}

pub fn FrameT(comptime Func: anytype) type {
    return CoroT.fromFunc(Func, .{});
}

// Allocate a stack suitable for coroutine usage.
// Caller is responsible for freeing memory.
pub fn stackAlloc(allocator: std.mem.Allocator, size: ?usize) !StackT {
    return try allocator.alignedAlloc(u8, stack_alignment, size orelse default_stack_size);
}

// True if within a coroutine, false if at top-level.
pub fn inCoro() bool {
    return thread_state.current_coro != null;
}

// Returns the currently running coroutine
pub fn xframe() Frame {
    return thread_state.current_coro orelse &thread_state.root_coro;
}

// Resume the passed coroutine, suspending the current coroutine.
// When the resumed coroutine suspends, this call will return.
// Note: When the resumed coroutine returns, control will switch to its parent
// (i.e. its original resumer).
// frame: Frame or FrameT
pub fn xresume(frame: anytype) void {
    const f = frame.frame();
    thread_state.switchIn(f);
}

// Suspend the current coroutine, yielding control back to its
// resumer. Returns when the coroutine is resumed.
// Must be called from within a coroutine (i.e. not the top level).
pub fn xsuspend() void {
    xsuspendSafe() catch |e| {
        log.err("{any}\n", .{e});
        @panic("xsuspend");
    };
}
pub fn xsuspendBlock(func: anytype, args: anytype) void {
    const Callback = struct {
        func: *const @TypeOf(func),
        args: ArgsTuple(@TypeOf(func)),
        fn cb(ud: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ud));
            @call(.auto, self.func, self.args);
        }
    };
    var cb = Callback{ .func = func, .args = args };
    thread_state.suspend_block = .{ .func = Callback.cb, .data = @ptrCast(&cb) };
    xsuspend();
}
pub fn xsuspendSafe() Error!void {
    if (thread_state.current_coro == null) return Error.SuspendFromMain;
    const coro = thread_state.current_coro.?;
    try StackOverflow.check(coro);
    thread_state.switchOut(coro.resumer);
}

pub const Coro = struct {
    // Coroutine status
    pub const Status = enum {
        Start,
        Suspended,
        Active,
        Done,
    };

    // Function to run in the coroutine
    func: *const fn () void,
    // Coroutine stack
    stack: StackT,
    // Whether this stack is env-allocated
    owns_stack: bool = false,
    // Architecture-specific implementation
    impl: base.Coro,
    // The coroutine that will be yielded to upon suspend
    resumer: *Coro = undefined,
    // Current status
    status: Status = .Start,
    // Coro id, {thread, coro id, invocation id}
    id: CoroId.InvocationId,
    // Caller-specified coro-local storage
    storage: ?*anyopaque = null,

    pub fn init(func: *const fn () void, stack: StackT, owns_stack: bool, storage: ?*anyopaque) !Frame {
        var s = Stack.init(stack);
        return initFromStack(func, &s, owns_stack, storage);
    }

    pub fn deinit(self: @This()) void {
        if (!self.owns_stack) return;
        env.stack_allocator.?.free(self.stack);
    }

    fn initFromStack(func: *const fn () void, stack: *Stack, owns_stack: bool, storage: ?*anyopaque) !Frame {
        try StackOverflow.setMagicNumber(stack.full);
        var coro = try stack.push(Coro);
        const base_coro = try base.Coro.init(&runcoro, stack.remaining());
        coro.* = @This(){
            .func = func,
            .impl = base_coro,
            .stack = stack.full,
            .owns_stack = owns_stack,
            .storage = storage,
            .id = thread_state.newCoroId(),
        };
        return coro;
    }

    pub fn frame(self: *@This()) Frame {
        return self;
    }

    fn runcoro(from: *base.Coro, this: *base.Coro) callconv(.C) noreturn {
        const from_coro = @fieldParentPtr(Coro, "impl", from);
        const this_coro = @fieldParentPtr(Coro, "impl", this);
        if (debug_log_level >= 3) {
            std.debug.print("coro start {any}\n", .{this_coro.id});
        }
        @call(.auto, this_coro.func, .{});
        this_coro.status = .Done;
        if (debug_log_level >= 3) {
            std.debug.print("coro done {any}\n", .{this_coro.id});
        }
        thread_state.switchOut(from_coro);

        // Never returns
        const err_msg = "Cannot resume an already completed coroutine {any}";
        @panic(std.fmt.allocPrint(
            std.heap.c_allocator,
            err_msg,
            .{this_coro.id},
        ) catch err_msg);
    }

    pub fn getStorage(self: @This(), comptime T: type) *T {
        return @ptrCast(@alignCast(self.storage));
    }

    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("Coro{{.id = {any}, .status = {s}}}", .{
            self.id,
            @tagName(self.status),
        });
    }
};

pub const CoroT = struct {
    pub const Options = struct {
        YieldT: type = void,
        InjectT: type = void,
    };

    // The signature of a coroutine.
    // Considering a coroutine a generalization of a regular function,
    // it has the typical input arguments and outputs (Func) and also
    // the types of its yielded (YieldT) and injected (InjectT) values.
    pub const Signature = struct {
        Func: type,
        YieldT: type = void,
        InjectT: type = void,

        // If the function this signature represents is compile-time known,
        // it can be held here.
        func_ptr: ?type = null,

        pub fn init(comptime Func: anytype, comptime options: CoroT.Options) @This() {
            const FuncT = if (@TypeOf(Func) == type) Func else @TypeOf(Func);
            return .{
                .Func = FuncT,
                .YieldT = options.YieldT,
                .InjectT = options.InjectT,
                .func_ptr = if (@TypeOf(Func) == type) null else struct {
                    const val = Func;
                },
            };
        }

        pub fn ReturnT(comptime self: @This()) type {
            return @typeInfo(self.Func).Fn.return_type.?;
        }
    };

    pub fn fromFunc(comptime Func: anytype, comptime options: Options) type {
        return fromSig(Signature.init(Func, options));
    }

    pub fn fromSig(comptime Sig: Signature) type {
        if (Sig.func_ptr == null) @compileError("Coro function must be comptime known");
        const ArgsT = ArgsTuple(Sig.Func);

        // Stored in the coro stack
        const InnerStorage = struct {
            args: ArgsT,
            // Values that are produced during coroutine execution
            value: union {
                yieldval: Sig.YieldT,
                injectval: Sig.InjectT,
                retval: Sig.ReturnT(),
            } = undefined,
        };

        return struct {
            const Self = @This();
            pub const Signature = Sig;

            _frame: Frame,

            // Create a Coro
            // self and stack pointers must remain stable for the lifetime of
            // the coroutine.
            pub fn init(
                args: ArgsT,
                stack: StackT,
                owns_stack: bool,
            ) !Self {
                var s = Stack.init(stack);
                var inner = try s.push(InnerStorage);
                inner.* = .{
                    .args = args,
                };
                return .{ ._frame = try Coro.initFromStack(wrapfn, &s, owns_stack, inner) };
            }

            pub fn wrap(_frame: Frame) Self {
                return .{ ._frame = _frame };
            }

            pub fn deinit(self: Self) void {
                self._frame.deinit();
            }

            pub fn status(self: @This()) Coro.Status {
                return self._frame.status;
            }

            pub fn frame(self: Self) Frame {
                return self._frame;
            }

            // Coroutine functions.
            //
            // When considering basic coroutine execution, the coroutine state
            // machine is:
            // * Start
            // * Start->xresume->Active
            // * Active->xsuspend->Suspended
            // * Active->(fn returns)->Done
            // * Suspended->xresume->Active
            //
            // When considering interacting with the storage values (yields/injects
            // and returns), the coroutine state machine is:
            // * Created
            // * Created->xnextStart->Active
            // * Active->xyield->Suspended
            // * ActiveFinal->(fn returns)->Done
            // * Suspended->xnext->Active
            // * Suspended->xnextEnd->ActiveFinal
            // * Done->xreturned->Done
            //
            // Note that actions in the Active* states are taken from within the
            // coroutine. All other actions act upon the coroutine from the
            // outside.

            // Initial resume, takes no injected value, returns yielded value
            pub fn xnextStart(self: Self) Sig.YieldT {
                xresume(self._frame);
                const storage = self._frame.getStorage(InnerStorage);
                return storage.value.yieldval;
            }

            // Final resume, takes injected value, returns coroutine's return value
            pub fn xnextEnd(self: Self, val: Sig.InjectT) Sig.ReturnT() {
                const storage = self._frame.getStorage(InnerStorage);
                storage.value = .{ .injectval = val };
                xresume(self._frame);
                return storage.value.retval;
            }

            // Intermediate resume, takes injected value, returns yielded value
            pub fn xnext(self: Self, val: Sig.InjectT) Sig.YieldT {
                const storage = self._frame.getStorage(InnerStorage);
                storage.value = .{ .injectval = val };
                xresume(self._frame);
                return storage.value.yieldval;
            }

            // Yields value, returns injected value
            pub fn xyield(val: Sig.YieldT) Sig.InjectT {
                const storage = thread_state.currentStorage(InnerStorage);
                storage.value = .{ .yieldval = val };
                xsuspend();
                return storage.value.injectval;
            }

            // Returns the value the coroutine returned
            pub fn xreturned(self: Self) Sig.ReturnT() {
                const storage = self._frame.getStorage(InnerStorage);
                return storage.value.retval;
            }

            fn wrapfn() void {
                const storage = thread_state.currentStorage(InnerStorage);
                storage.value = .{ .retval = @call(
                    .always_inline,
                    Sig.func_ptr.?.val,
                    storage.args,
                ) };
            }
        };
    }
};

// Estimates the remaining stack size in the currently running coroutine
pub noinline fn remainingStackSize() usize {
    var dummy: usize = 0;
    dummy += 1;
    const addr = @intFromPtr(&dummy);

    // Check if the stack was already overflowed
    const current = xframe();
    StackOverflow.check(current) catch return 0;

    // Check if the stack is currently overflowed
    const bottom = @intFromPtr(current.stack.ptr);
    if (addr < bottom) return 0;

    // Debug check that we're actually in the stack
    const top = @intFromPtr(current.stack.ptr + current.stack.len);
    std.debug.assert(addr < top); // should never have popped beyond the top

    return addr - bottom;
}

// ============================================================================

// Thread-local coroutine runtime
threadlocal var thread_state: ThreadState = .{};
const ThreadState = struct {
    root_coro: Coro = .{
        .func = undefined,
        .stack = undefined,
        .impl = undefined,
        .id = CoroId.InvocationId.root(),
    },
    current_coro: ?Frame = null,
    next_coro_id: usize = 1,
    suspend_block: ?SuspendBlock = null,

    const SuspendBlock = struct {
        func: *const fn (?*anyopaque) void,
        data: ?*anyopaque,

        fn run(self: @This()) void {
            @call(.auto, self.func, .{self.data});
        }
    };

    // Called from resume
    fn switchIn(self: *@This(), target: Frame) void {
        if (debug_log_level >= 3) {
            const resumer = self.current();
            std.debug.print("coro resume {any} from {any}\n", .{ target.id, resumer.id });
        }
        // Switch to target, setting this coro as the resumer.
        self.switchTo(target, true);

        // Suspend within target brings control back here
        // If a suspend block has been set, pop and run it.
        if (self.suspend_block) |block| {
            self.suspend_block = null;
            block.run();
        }
    }

    // Called from suspend
    fn switchOut(self: *@This(), target: Frame) void {
        if (debug_log_level >= 3) {
            const suspender = self.current();
            std.debug.print("coro suspend {any} to {any}\n", .{ suspender.id, target.id });
        }
        self.switchTo(target, false);
    }

    fn switchTo(self: *@This(), target: Frame, set_resumer: bool) void {
        const suspender = self.current();
        if (suspender.status != .Done) suspender.status = .Suspended;
        if (set_resumer) target.resumer = suspender;
        target.status = .Active;
        target.id.incr();
        self.current_coro = target;
        target.impl.resumeFrom(&suspender.impl);
    }

    fn newCoroId(self: *@This()) CoroId.InvocationId {
        const out = CoroId.InvocationId.init(.{
            .coro = self.next_coro_id,
        });
        self.next_coro_id += 1;
        return out;
    }

    fn current(self: *@This()) Frame {
        return self.current_coro orelse &self.root_coro;
    }

    // Returns the storage of the currently running coroutine
    fn currentStorage(self: *@This(), comptime T: type) *T {
        return self.current_coro.?.getStorage(T);
    }
};

fn ArgsTuple(comptime Fn: type) type {
    const out = std.meta.ArgsTuple(Fn);
    return if (std.meta.fields(out).len == 0) @TypeOf(.{}) else out;
}

const Stack = struct {
    full: StackT,
    sp: [*]u8,

    fn init(stack: StackT) @This() {
        return .{
            .full = stack,
            .sp = stack.ptr + stack.len,
        };
    }

    fn remaining(self: @This()) StackT {
        return self.full[0 .. @intFromPtr(self.sp) - @intFromPtr(self.full.ptr)];
    }

    fn push(self: *@This(), comptime T: type) !*T {
        const ptr_i = std.mem.alignBackward(
            usize,
            @intFromPtr(self.sp - @sizeOf(T)),
            stack_alignment,
        );
        if (ptr_i <= @intFromPtr(self.full.ptr)) {
            return Error.StackTooSmall;
        }
        const ptr: *T = @ptrFromInt(ptr_i);
        self.sp = @ptrFromInt(ptr_i);
        return ptr;
    }
};

const CoroId = struct {
    coro: usize,

    pub const InvocationId = if (builtin.mode == .Debug) DebugInvocationId else DummyInvocationId;

    const DummyInvocationId = struct {
        fn init(id: CoroId) @This() {
            _ = id;
            return .{};
        }
        fn root() @This() {
            return .{};
        }
        fn incr(self: *@This()) void {
            _ = self;
        }
    };

    const DebugInvocationId = struct {
        id: CoroId,
        invocation: i64 = -1,

        fn init(id: CoroId) @This() {
            return .{ .id = id };
        }

        fn root() @This() {
            return .{ .id = .{ .coro = 0 } };
        }

        fn incr(self: *@This()) void {
            self.invocation += 1;
        }

        pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;
            try writer.print("CoroId{{.cid={d}, .i={d}}}", .{
                self.id.coro,
                self.invocation,
            });
        }
    };
};

const StackOverflow = struct {
    const magic_number: usize = 0x5E574D6D;

    fn check(coro: Frame) !void {
        const stack = coro.stack.ptr;
        const sp = coro.impl.stack_pointer;
        const magic_number_ptr: *usize = @ptrCast(stack);
        if (magic_number_ptr.* != magic_number or //
            @intFromPtr(sp) < @intFromPtr(stack))
        {
            return Error.StackOverflow;
        }
    }

    fn setMagicNumber(stack: StackT) !void {
        if (stack.len <= @sizeOf(usize)) return Error.StackTooSmall;
        const magic_number_ptr: *usize = @ptrCast(stack.ptr);
        magic_number_ptr.* = magic_number;
    }
};

test {
    std.testing.refAllDecls(@import("allocator.zig"));
}

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
//     * Done: set in runcoro
//   * id.invocation: incremented in ThreadState.switchTo

// Public API
// ============================================================================
pub const Error = @import("errors.zig").Error;
pub const StackT = []align(base.stack_align) u8;
pub const stack_align = base.stack_align;
pub const default_stack_size = @import("libcoro_options").default_stack_size;

pub const allocators = struct {
    pub const FixedSizeFreeListAllocator = @import("allocator.zig").FixedSizeFreeListAllocator;
};

pub const Frame = *Coro;

// Coroutine status
pub const CoroStatus = enum {
    Start,
    Suspended,
    Active,
    Done,
};

pub const Env = struct {
    stack_allocator: ?std.mem.Allocator = null,
    default_stack_size: ?usize = null,
};
threadlocal var env: Env = .{};
pub fn initEnv(e: Env) void {
    env = e;
}

fn getStack(stack: ?StackT) !StackT {
    if (stack != null) return stack.?;
    if (env.stack_allocator == null) @panic("No explicit stack passed and no default stack allocator available");
    return stackAlloc(env.stack_allocator.?, env.default_stack_size);
}

// Await the coroutine(s).
// frame: FrameT: runs the coroutine until done and returns its return value.
pub fn xawait(frame: anytype) xawaitT(@TypeOf(frame)) {
    if (!@hasDecl(@TypeOf(frame), "FrameTFunc")) @compileError("xawait must be called with a FrameT");
    const f = getFrame(frame);
    while (f.status != .Done) xsuspend();
    return @TypeOf(frame).FrameTFunc.xreturned(f);
}

fn xawaitT(comptime T: type) type {
    return if (T == Frame) void else T.T;
}

// Get Frame from co (either Frame or FrameT)
pub fn getFrame(co: anytype) Frame {
    if (@TypeOf(co) == Frame) return co;
    return co.frame;
}

pub fn xasync(func: anytype, args: anytype, stack: ?StackT) !FrameT(func) {
    const costack = try getStack(stack);
    var frame = try CoroT(func, .{}).init(args, costack);
    xresume(frame);
    return FrameT(func){ .frame = frame, .owns_stack = stack == null };
}

pub fn FrameT(comptime Func: anytype) type {
    return struct {
        const FrameTFunc = CoroT(Func, .{});
        const T = FrameTFunc.Signature.ReturnT;
        frame: Frame,
        owns_stack: bool = false,

        pub fn init(frame: Frame) @This() {
            return .{ .frame = frame };
        }

        pub fn deinit(self: @This()) void {
            if (!self.owns_stack) return;
            env.stack_allocator.?.free(self.frame.stack);
        }

        pub fn status(self: @This()) CoroStatus {
            return self.frame.status;
        }
    };
}

// Allocate a stack suitable for coroutine usage.
// Caller is responsible for freeing memory.
pub fn stackAlloc(allocator: std.mem.Allocator, size: ?usize) !StackT {
    return try allocator.alignedAlloc(u8, stack_align, size orelse default_stack_size);
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
    const f = getFrame(frame);
    thread_state.switchIn(f);
}

// Suspend the current coroutine, yielding control back to its
// resumer. Returns when the coroutine is resumed.
// Must be called from within a coroutine (i.e. not the top level).
pub fn xsuspend() void {
    xsuspendSafe() catch unreachable;
}
pub fn xsuspendBlock(func: *const fn (?*anyopaque) void, data: ?*anyopaque) void {
    thread_state.suspend_block = .{ .func = func, .data = data };
    xsuspendSafe() catch unreachable;
}
pub fn xsuspendSafe() Error!void {
    if (thread_state.current_coro == null) return Error.SuspendFromMain;
    const coro = thread_state.current_coro.?;
    try checkStackOverflow(coro);
    thread_state.switchOut(coro.resumer);
}

pub const Coro = struct {
    // Function to run in the coroutine
    func: *const fn () void,
    // Coroutine stack
    stack: StackT,
    // Architecture-specific implementation
    impl: base.Coro,
    // The coroutine that will be yielded to upon suspend
    resumer: *Coro = undefined,
    // Current status
    status: CoroStatus = .Start,
    // Coro id, {thread, coro id, invocation id}
    id: CoroInvocationId,
    // Caller-specified coro-local storage
    storage: ?*anyopaque = null,

    pub fn init(func: *const fn () void, stack: StackT, storage: ?*anyopaque) !Frame {
        var s = Stack.init(stack);
        return initFromStack(func, &s, storage);
    }

    fn initFromStack(func: *const fn () void, stack: *Stack, storage: ?*anyopaque) !Frame {
        try setStackOverflowMagicNumber(stack.full);
        var coro = try stack.push(Coro);
        const base_coro = try base.Coro.init(&runcoro, stack.remaining());
        coro.* = @This(){
            .func = func,
            .impl = base_coro,
            .stack = stack.full,
            .storage = storage,
            .id = CoroInvocationId.init(),
        };
        return coro;
    }

    pub fn getStorage(self: @This(), comptime T: type) *T {
        return @ptrCast(@alignCast(self.storage));
    }
};

// The signature of a coroutine.
// Considering a coroutine a generalization of a regular function,
// it has the typical input arguments and outputs (Func) and also
// the types of its yielded (YieldT) and injected (InjectT) values.
pub const CoroSignature = struct {
    Func: type,
    ReturnT: type,
    YieldT: type = void,
    InjectT: type = void,

    // If the function this signature represents is compile-time known,
    // it can be held here.
    func_ptr: ?type = null,

    pub fn init(comptime Func: anytype, comptime options: CoroOptions) @This() {
        const FuncT = if (@TypeOf(Func) == type) Func else @TypeOf(Func);
        return .{
            .Func = FuncT,
            .ReturnT = @typeInfo(FuncT).Fn.return_type.?,
            .YieldT = options.YieldT,
            .InjectT = options.InjectT,
            .func_ptr = if (@TypeOf(Func) == type) null else struct {
                const val = Func;
            },
        };
    }
};

pub const CoroOptions = struct {
    YieldT: type = void,
    InjectT: type = void,
};

pub fn CoroT(comptime Func: anytype, comptime options: CoroOptions) type {
    return CoroTSig(CoroSignature.init(Func, options));
}

fn CoroTSig(comptime Sig: CoroSignature) type {
    if (Sig.func_ptr == null) @compileError("Coro function must be comptime known");
    const ArgsT = ArgsTuple(Sig.Func);

    // Stored in the coro stack
    const InnerStorage = struct {
        args: ArgsT,
        // Values that are produced during coroutine execution
        value: union {
            yieldval: Sig.YieldT,
            injectval: Sig.InjectT,
            retval: Sig.ReturnT,
        } = undefined,
    };

    return struct {
        pub const Signature = Sig;

        // Create a Coro
        // self and stack pointers must remain stable for the lifetime of
        // the coroutine.
        pub fn init(
            args: ArgsT,
            stack: StackT,
        ) !Frame {
            var s = Stack.init(stack);
            var inner = try s.push(InnerStorage);
            inner.* = .{
                .args = args,
            };
            return try Coro.initFromStack(wrapfn, &s, inner);
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
        pub fn xnextStart(co: Frame) Sig.YieldT {
            xresume(co);
            const self = co.getStorage(InnerStorage);
            return self.value.yieldval;
        }

        // Final resume, takes injected value, returns coroutine's return value
        pub fn xnextEnd(co: Frame, val: Sig.InjectT) Sig.ReturnT {
            const self = co.getStorage(InnerStorage);
            self.value = .{ .injectval = val };
            xresume(co);
            return self.value.retval;
        }

        // Intermediate resume, takes injected value, returns yielded value
        pub fn xnext(co: Frame, val: Sig.InjectT) Sig.YieldT {
            const self = co.getStorage(InnerStorage);
            self.value = .{ .injectval = val };
            xresume(co);
            return self.value.yieldval;
        }

        // Yields value, returns injected value
        pub fn xyield(val: Sig.YieldT) Sig.InjectT {
            const self = currentStorage(InnerStorage);
            self.value = .{ .yieldval = val };
            xsuspend();
            return self.value.injectval;
        }

        // Returns the value the coroutine returned
        pub fn xreturned(co: Frame) Sig.ReturnT {
            const self = co.getStorage(InnerStorage);
            return self.value.retval;
        }

        fn wrapfn() void {
            const self = currentStorage(InnerStorage);
            self.value = .{ .retval = @call(
                .always_inline,
                Sig.func_ptr.?.val,
                self.args,
            ) };
        }
    };
}

// Returns the storage of the currently running coroutine
fn currentStorage(comptime T: type) *T {
    return thread_state.current_coro.?.getStorage(T);
}

// Estimates the remaining stack size in the currently running coroutine
pub noinline fn remainingStackSize() usize {
    var dummy: usize = 0;
    dummy += 1;
    const addr = @intFromPtr(&dummy);

    // Check if the stack was already overflowed
    const current = xframe();
    checkStackOverflow(current) catch return 0;

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
        .id = CoroInvocationId.root(),
    },
    current_coro: ?Frame = null,
    next_coro_id: usize = 1,
    suspend_block: ?SuspendBlock = null,

    // Called from resume
    fn switchIn(self: *@This(), target: Frame) void {
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

    fn nextCoroId(self: *@This()) CoroId {
        const out = .{
            .thread = std.Thread.getCurrentId(),
            .coro = self.next_coro_id,
        };
        self.next_coro_id += 1;
        return out;
    }

    fn current(self: *@This()) Frame {
        return self.current_coro orelse &self.root_coro;
    }
};

const SuspendBlock = struct {
    func: *const fn (?*anyopaque) void,
    data: ?*anyopaque,

    fn run(self: @This()) void {
        @call(.auto, self.func, .{self.data});
    }
};

fn ArgsTuple(comptime Fn: type) type {
    const out = std.meta.ArgsTuple(Fn);
    return if (std.meta.fields(out).len == 0) @TypeOf(.{}) else out;
}

fn runcoro(from: *base.Coro, target: *base.Coro) callconv(.C) noreturn {
    const from_coro = @fieldParentPtr(Coro, "impl", from);
    const target_coro = @fieldParentPtr(Coro, "impl", target);
    @call(.auto, target_coro.func, .{});
    target_coro.status = .Done;
    thread_state.switchOut(from_coro);

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
            stack_align,
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
    thread: std.Thread.Id,
    coro: usize,
};

const CoroInvocationId = if (builtin.mode == .Debug) DebugCoroInvocationId else DummyCoroInvocationId;

const DummyCoroInvocationId = struct {
    fn init() @This() {
        return .{};
    }
    fn root() @This() {
        return .{};
    }
    fn incr(self: *@This()) void {
        _ = self;
    }
};

const DebugCoroInvocationId = struct {
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

const stack_overflow_magic_number: usize = 0x5E574D6D;

fn checkStackOverflow(coro: Frame) !void {
    const stack = coro.stack.ptr;
    const sp = coro.impl.stack_pointer;
    const magic_number_ptr: *usize = @ptrCast(stack);
    if (magic_number_ptr.* != stack_overflow_magic_number or //
        @intFromPtr(sp) < @intFromPtr(stack))
    {
        return Error.StackOverflow;
    }
}

fn setStackOverflowMagicNumber(stack: StackT) !void {
    if (stack.len <= @sizeOf(usize)) return Error.StackTooSmall;
    const magic_number_ptr: *usize = @ptrCast(stack.ptr);
    magic_number_ptr.* = stack_overflow_magic_number;
}

fn getStackOverflowMagicNumber(stack: StackT) usize {
    const magic_number_ptr: *usize = @ptrCast(stack.ptr);
    return magic_number_ptr.*;
}

test {
    std.testing.refAllDecls(@import("allocator.zig"));
}

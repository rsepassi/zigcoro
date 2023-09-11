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
pub const default_stack_size = blk: {
    const root = @import("root");
    if (@hasDecl(root, "libcoro_options") and
        @hasDecl(root.libcoro_options, "default_stack_size"))
    {
        break :blk root.libcoro_options.default_stack_size;
    }
    break :blk 1024 * 4;
};

// Coroutine status
pub const CoroStatus = enum {
    Start,
    Suspended,
    Active,
    Done,
};

// Allocate a stack suitable for coroutine usage.
// Caller is responsible for freeing memory.
pub fn stackAlloc(allocator: std.mem.Allocator, size: ?usize) !StackT {
    return try allocator.alignedAlloc(u8, stack_align, size orelse default_stack_size);
}

// Returns the currently running coroutine
pub fn xcurrent() ?*Coro {
    return thread_state.current_coro;
}

// Returns the storage of the currently running coroutine
pub fn xcurrentStorage(comptime T: type) *T {
    return thread_state.current_coro.?.getStorage(T);
}

// Resume the passed coroutine, suspending the current coroutine.
// When the resumed coroutine suspends, this call will return.
// Note: When the resumed coroutine returns, control will switch to its parent
// (i.e. its original resumer).
pub fn xresume(coro: *Coro) void {
    thread_state.switchIn(coro);
}

// Suspend the current coroutine, yielding control back to its
// resumer. Returns when the coroutine is resumed.
// Must be called from within a coroutine (i.e. not the top level).
pub fn xsuspend() void {
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
    // Current status, starts in Start
    status: CoroStatus = .Start,
    // Coro id, {thread, coro id, invocation id}
    id: CoroInvocationId,
    // Caller-specified storage
    storage: ?*anyopaque = null,

    pub fn init(func: *const fn () void, stack: StackT, storage: ?*anyopaque) !*@This() {
        try setMagicNumber(stack);
        var s = Stack.init(stack);
        var coro = try s.push(Coro);
        const base_coro = try base.Coro.init(&runcoro, s.remaining());
        coro.* = @This(){
            .func = func,
            .impl = base_coro,
            .stack = stack,
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
    YieldT: type = void,
    InjectT: type = void,

    // If the function this signature represents is compile-time known,
    // it can be held here.
    func_ptr: ?type = null,

    pub fn init(comptime Func: anytype, comptime options: FrameOptions) @This() {
        return .{
            .Func = if (@TypeOf(Func) == type) Func else @TypeOf(Func),
            .YieldT = options.YieldT,
            .InjectT = options.InjectT,
            .func_ptr = if (@TypeOf(Func) == type) null else struct {
                const val = Func;
            },
        };
    }

    pub fn getReturnT(comptime self: @This()) type {
        return @typeInfo(self.Func).Fn.return_type.?;
    }
};

pub const FrameOptions = struct {
    YieldT: type = void,
    InjectT: type = void,
};

pub fn CoroFunc(comptime Func: anytype, comptime options: FrameOptions) type {
    return CoroFuncSig(CoroSignature.init(Func, options));
}

pub fn CoroFuncSig(comptime Sig: CoroSignature) type {
    const is_comptime_func = Sig.func_ptr != null;
    const ArgsT = ArgsTuple(Sig.Func);
    // Stored in the coro stack
    const InnerStorage = struct {
        func: if (is_comptime_func) void else *const Sig.Func,
        args: ArgsT,
        retval: *Sig.getReturnT(),
        // Values that are produced during coroutine execution
        value: union {
            yieldval: Sig.YieldT,
            injectval: Sig.InjectT,
        } = undefined,
    };

    return struct {
        pub const Signature = Sig;
        retval: Sig.getReturnT() = undefined,
        stack: StackT = undefined,

        pub fn init() @This() {
            return .{};
        }

        // Create a Coro
        // self and stack pointers must remain stable for the lifetime of
        // the coroutine.
        pub fn coro(
            self: *@This(),
            args: ArgsT,
            stack: StackT,
        ) !*Coro {
            self.stack = stack;
            var s = Stack.init(stack);
            var inner = try s.push(InnerStorage);
            inner.* = .{
                .func = {},
                .args = args,
                .retval = &self.retval,
            };
            return try Coro.init(wrapfn, s.remaining(), inner);
        }

        // Same as coro but with a runtime-defined function pointer.
        pub fn coroPtr(
            self: *@This(),
            func: *const Sig.Func,
            args: anytype,
            stack: StackT,
        ) !*Coro {
            var s = Stack.init(stack);
            var inner = try s.push(InnerStorage);
            inner.* = .{
                .func = func,
                .args = args,
                .retval = &self.retval,
            };
            return try Coro.init(wrapfn, s.remaining(), inner);
        }

        // Coroutine functions.
        //
        // When considering basic coroutine execution, the coroutine state
        // machine is:
        // * Start
        // * Start->libcoro.xresume->Active
        // * Active->libcoro.xsuspend->Suspended
        // * Active->(fn returns)->Done
        // * Suspended->libcoro.xresume->Active
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
        pub fn xnextStart(co: *Coro) Sig.YieldT {
            xresume(co);
            const self = co.getStorage(InnerStorage);
            return self.value.yieldval;
        }

        // Final resume, takes injected value, returns coroutine's return value
        pub fn xnextEnd(co: *Coro, val: Sig.InjectT) Sig.getReturnT() {
            const self = co.getStorage(InnerStorage);
            self.value = .{ .injectval = val };
            xresume(co);
            return self.retval.*;
        }

        // Intermediate resume, takes injected value, returns yielded value
        pub fn xnext(co: *Coro, val: Sig.InjectT) Sig.YieldT {
            const self = co.getStorage(InnerStorage);
            self.value = .{ .injectval = val };
            xresume(co);
            return self.value.yieldval;
        }

        // Yields value, returns injected value
        pub fn xyield(val: Sig.YieldT) Sig.InjectT {
            const self = xcurrentStorage(InnerStorage);
            self.value = .{ .yieldval = val };
            xsuspend();
            return self.value.injectval;
        }

        // Returns the value the coroutine returned
        pub fn xreturned(co: *Coro) Sig.getReturnT() {
            const self = co.getStorage(InnerStorage);
            return self.retval.*;
        }

        fn wrapfn() void {
            const self = xcurrentStorage(InnerStorage);
            self.retval.* = @call(
                if (is_comptime_func) .always_inline else .auto,
                if (is_comptime_func) Sig.func_ptr.?.val else self.func,
                self.args,
            );
        }
    };
}

// Estimates the remaining stack size in the currently running coroutine
pub noinline fn remainingStackSize() usize {
    var dummy: usize = 0;
    dummy += 1;
    const addr = @intFromPtr(&dummy);

    // Check if the stack was already overflowed
    const current = xcurrent().?;
    if (getMagicNumber(current.stack) != magic_number) return 0;

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
    current_coro: ?*Coro = null,
    next_coro_id: usize = 1,

    // Called from resume
    fn switchIn(self: *@This(), target: *Coro) void {
        self.switchTo(target, true);
    }

    // Called from suspend
    fn switchOut(self: *@This(), target: *Coro) void {
        self.switchTo(target, false);
    }

    fn switchTo(self: *@This(), target: *Coro, set_resumer: bool) void {
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

    fn current(self: *@This()) *Coro {
        return self.current_coro orelse &self.root_coro;
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

const magic_number: usize = 0x5E574D6D;

fn checkStackOverflow(coro: *Coro) !void {
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

fn getMagicNumber(stack: StackT) usize {
    const magic_number_ptr: *usize = @ptrCast(stack.ptr);
    return magic_number_ptr.*;
}

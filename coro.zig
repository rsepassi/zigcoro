const std = @import("std");
const builtin = @import("builtin");
const base = @import("coro_base.zig");

// libcoro mutable state:
// * ThreadState
//   * current_coro: set in ThreadState.switchTo
//   * next_coro_id: set in ThreadState.nextCoroId
// * Coro
//   * parent: set in ThreadState.switchTo
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

// Coroutine status
pub const CoroStatus = enum {
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
pub fn xcurrent() *Coro {
    return thread_state.current_coro.?;
}

// Returns the storage of the currently running coroutine
pub fn xcurrentStorage(comptime T: type) *T {
    return thread_state.current_coro.?.getStorage(T);
}

// Resume the passed coroutine, suspending the current coroutine.
// When the resumed coroutine yields, this call will return.
pub fn xresume(coro: *Coro) void {
    thread_state.switchIn(coro);
}

// Suspend the current coroutine, yielding control back to the parent.
// Returns when the coroutine is resumed.
pub fn xsuspend() void {
    xsuspendSafe() catch unreachable;
}
pub fn xsuspendSafe() Error!void {
    if (thread_state.current_coro == null) return Error.SuspendFromMain;
    const coro = thread_state.current_coro.?;
    try checkStackOverflow(coro);
    thread_state.switchOut(coro.parent);
}

pub const Coro = struct {
    // Function to run in the coroutine
    func: *const fn () void,
    // Coroutine stack
    stack: StackT,
    // Architecture-specific implementation
    impl: base.Coro,
    // The coroutine that will be yielded to upon suspend
    parent: *Coro = undefined,
    // Current status, starts suspended
    status: CoroStatus = .Suspended,
    // Coro id, {thread, coro id, invocation id}
    id: CoroInvocationId,
    // Caller-specified storage
    storage: ?*const anyopaque = null,

    pub fn init(func: *const fn () void, stack: StackT, storage: ?*const anyopaque) !@This() {
        try setMagicNumber(stack);
        const base_coro = try base.Coro.init(&runcoro, stack);
        return .{
            .func = func,
            .impl = base_coro,
            .stack = stack,
            .storage = storage,
            .id = CoroInvocationId.init(),
        };
    }

    pub fn getStorage(self: @This(), comptime T: type) *T {
        return @ptrCast(@constCast(@alignCast(self.storage)));
    }
};

pub const CoroSignature = struct {
    Func: type,
    YieldT: type = void,
    InjectT: type = void,
    func_ptr: ?type = null,

    pub fn getReturnT(comptime self: @This()) type {
        return @typeInfo(self.Func).Fn.return_type.?;
    }

    pub fn yieldsVals(comptime self: @This()) bool {
        return self.YieldT != null;
    }

    pub fn injectsVals(comptime self: @This()) bool {
        return self.InjectT != null;
    }
};

pub const FrameOptions = struct {
    YieldT: type = void,
    InjectT: type = void,
};

pub fn CoroFunc(comptime Func: anytype, comptime options: FrameOptions) type {
    return CoroFuncSig(.{
        .Func = if (@TypeOf(Func) == type) Func else @TypeOf(Func),
        .YieldT = options.YieldT,
        .InjectT = options.InjectT,
        .func_ptr = if (@TypeOf(Func) == type) null else struct {
            const val = Func;
        },
    });
}

const xresumeTopLevel = xresume;

pub fn CoroFuncSig(comptime Sig: CoroSignature) type {
    const is_comptime_func = Sig.func_ptr != null;
    return struct {
        pub const Signature = Sig;
        func: if (is_comptime_func) void else *const Sig.Func,
        args: std.meta.ArgsTuple(Sig.Func),
        // Values that are produced during coroutine execution
        values: union {
            retval: Sig.getReturnT(),
            yieldval: Sig.YieldT,
            injectval: Sig.InjectT,
        } = undefined,

        // Initialize frame with args
        // Function pointer be comptime known
        pub fn init(args: anytype) @This() {
            if (!is_comptime_func) {
                @compileError("init requires function pointer to be comptime known. Use initPtr for runtime-only-known function pointers");
            }
            return .{ .func = {}, .args = args };
        }

        pub fn initPtr(func: *const Sig.Func, args: anytype) @This() {
            return .{ .func = func, .args = args };
        }

        // Create a Coro
        // CoroFunc and stack pointers must remain stable for the lifetime of
        // the coroutine.
        pub fn coro(self: *@This(), stack: StackT) !Coro {
            return try Coro.init(wrapfn, stack, self);
        }

        fn wrapfn() void {
            const self: *@This() = xcurrentStorage(@This());
            self.values = .{ .retval = @call(
                .auto,
                if (is_comptime_func) Sig.func_ptr.?.val else self.func,
                self.args,
            ) };
        }

        // Initial resume, takes no injected value, returns yielded value
        pub fn xresumeStart(co: *Coro) Sig.YieldT {
            xresumeTopLevel(co);
            const self = co.getStorage(@This());
            return self.values.yieldval;
        }

        // Final resume, returns return value
        pub fn xresumeEnd(co: *Coro, val: Sig.InjectT) Sig.getReturnT() {
            const self = co.getStorage(@This());
            self.values = .{ .injectval = val };
            xresumeTopLevel(co);
            return self.values.retval;
        }

        // Intermediate resume, takes injected value, returns yielded value
        pub fn xresume(co: *Coro, val: Sig.InjectT) Sig.YieldT {
            const self = co.getStorage(@This());
            self.values = .{ .injectval = val };
            xresumeTopLevel(co);
            return self.values.yieldval;
        }

        // Yields value, returns injected value
        pub fn xyield(val: Sig.YieldT) Sig.InjectT {
            const self = xcurrentStorage(@This());
            self.values = .{ .yieldval = val };
            xsuspend();
            return self.values.injectval;
        }
    };
}

// StackCoro creates a Coro with a CoroFunc stored at the top of the provided
// stack.
pub const StackCoro = struct {
    pub fn init(
        func: anytype,
        args: anytype,
        stack: StackT,
        comptime options: FrameOptions,
    ) !Coro {
        const FrameT = CoroFunc(@TypeOf(func), options);
        const ptr = try stackPush(stack, FrameT.initPtr(func, args));
        var reduced_stack = stack[0 .. @intFromPtr(ptr) - @intFromPtr(stack.ptr)];
        var f: *FrameT = @ptrCast(@alignCast(ptr));
        return f.coro(reduced_stack);
    }

    pub fn frame(
        func: anytype,
        comptime options: FrameOptions,
        coro: Coro,
    ) *CoroFunc(@TypeOf(func), options) {
        return @ptrCast(@alignCast(coro.stack.ptr + coro.stack.len));
    }
};

// Estimates the remaining stack size in the currently running coroutine
pub noinline fn remainingStackSize() usize {
    var dummy: usize = 0;
    dummy += 1;
    const addr = @intFromPtr(&dummy);

    // Check if the stack was already overflowed
    const current = xcurrent();
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

    fn switchTo(self: *@This(), target: *Coro, set_parent: bool) void {
        const suspender = self.current();
        if (suspender.status != .Done) suspender.status = .Suspended;
        if (set_parent) target.parent = suspender;
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

fn runcoro(from: *base.Coro, target: *base.Coro) callconv(.C) noreturn {
    _ = from;
    const target_coro = @fieldParentPtr(Coro, "impl", target);
    @call(.auto, target_coro.func, .{});
    target_coro.status = .Done;
    thread_state.switchOut(target_coro.parent);

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

fn stackPush(stack: StackT, val: anytype) ![*]u8 {
    const T = @TypeOf(val);
    const ptr_i = std.mem.alignBackward(
        usize,
        @intFromPtr(stack.ptr + stack.len - @sizeOf(T)),
        stack_align,
    );
    if (ptr_i <= @intFromPtr(stack.ptr)) {
        return Error.StackTooSmall;
    }
    const ptr: *T = @ptrFromInt(ptr_i);
    ptr.* = val;
    return @ptrFromInt(ptr_i);
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

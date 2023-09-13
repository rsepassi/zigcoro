const std = @import("std");
const xev = @import("xev");
const libcoro = @import("coro.zig");

pub const xasync = libcoro.xasync;
pub const xawait = libcoro.xawait;

const Frame = libcoro.Frame;

const Env = struct {
    loop: ?*xev.Loop = null,
};
pub const EnvArg = struct {
    loop: ?*xev.Loop = null,
    stack_allocator: ?std.mem.Allocator = null,
    default_stack_size: ?usize = null,
};
threadlocal var env: Env = .{};
pub fn initEnv(e: EnvArg) void {
    env = .{ .loop = e.loop };
    libcoro.initEnv(.{
        .stack_allocator = e.stack_allocator,
        .default_stack_size = e.default_stack_size,
    });
}

fn getLoop(loop: ?*xev.Loop) *xev.Loop {
    if (loop != null) return loop.?;
    if (env.loop == null) @panic("No explicit loop passed and no default loop available.");
    return env.loop.?;
}

// Run a coroutine to completion.
// Must be called from "root", outside of any created coroutine.
pub fn run(
    loop: ?*xev.Loop,
    func: anytype,
    args: anytype,
    stack: ?libcoro.StackT,
) !RunT(func, .{}) {
    const frame = try xasync(func, args, stack);
    defer frame.deinit();
    try runCoro(loop, frame);
    return xawait(frame);
}

// Run a coroutine to completion.
// Must be called from "root", outside of any created coroutine.
fn runCoro(loop: ?*xev.Loop, frame: anytype) !void {
    const f = frame.frame();
    if (f.status == .Start) libcoro.xresume(f);
    while (f.status != .Done) try getLoop(loop).run(.once);
}

const SleepResult = xev.Timer.RunError!void;
pub fn sleep(loop: ?*xev.Loop, ms: u64) !void {
    const Data = XCallback(SleepResult);

    var data = Data.init();
    const w = try xev.Timer.init();
    defer w.deinit();
    var c: xev.Completion = .{};
    w.run(getLoop(loop), &c, ms, Data, &data, &Data.callback);

    try waitForCompletion(loop, &c);

    return data.result;
}

fn waitForCompletion(loop: ?*xev.Loop, c: *xev.Completion) !void {
    if (libcoro.inCoro()) {
        // In a coroutine; wait for it to be resumed
        libcoro.xsuspend();
    } else {
        // Not in a coroutine, blocking call
        while (c.state() != .dead) try getLoop(loop).run(.once);
    }
}

pub const TCP = struct {
    const Self = @This();

    loop: ?*xev.Loop,
    tcp: xev.TCP,

    pub usingnamespace Stream(Self, xev.TCP, .{
        .close = true,
        .read = .recv,
        .write = .send,
    });

    pub fn init(loop: ?*xev.Loop, tcp: xev.TCP) Self {
        return .{ .loop = loop, .tcp = tcp };
    }

    fn stream(self: Self) xev.TCP {
        return self.tcp;
    }

    pub fn accept(self: Self) !Self {
        const AcceptResult = xev.TCP.AcceptError!xev.TCP;
        const Data = XCallback(AcceptResult);

        var data = Data.init();
        var c: xev.Completion = .{};
        self.tcp.accept(getLoop(self.loop), &c, Data, &data, &Data.callback);

        try waitForCompletion(self.loop, &c);

        if (data.result) |result| {
            return .{ .loop = self.loop, .tcp = result };
        } else |err| return err;
    }

    const ConnectResult = xev.TCP.ConnectError!void;
    pub fn connect(self: Self, addr: std.net.Address) !void {
        const ResultT = ConnectResult;
        const Data = struct {
            result: ResultT = undefined,
            frame: ?Frame = null,

            fn callback(
                userdata: ?*@This(),
                l: *xev.Loop,
                c: *xev.Completion,
                s: xev.TCP,
                result: ResultT,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = s;
                const data = userdata.?;
                data.result = result;
                if (data.frame != null) libcoro.xresume(data.frame.?);
                return .disarm;
            }
        };

        var data: Data = .{ .frame = libcoro.xframe() };

        var c: xev.Completion = .{};
        self.tcp.connect(getLoop(self.loop), &c, addr, Data, &data, &Data.callback);

        try waitForCompletion(self.loop, &c);

        return data.result;
    }

    const ShutdownResult = xev.TCP.ShutdownError!void;
    pub fn shutdown(self: Self) ShutdownResult {
        const ResultT = ShutdownResult;
        const Data = struct {
            result: ResultT = undefined,
            frame: ?Frame = null,

            fn callback(
                userdata: ?*@This(),
                l: *xev.Loop,
                c: *xev.Completion,
                s: xev.TCP,
                result: ResultT,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = s;
                const data = userdata.?;
                data.result = result;
                if (data.frame != null) libcoro.xresume(data.frame.?);
                return .disarm;
            }
        };

        var data: Data = .{ .frame = libcoro.xframe() };

        var c: xev.Completion = .{};
        self.tcp.shutdown(getLoop(self.loop), &c, Data, &data, &Data.callback);

        try waitForCompletion(self.loop, &c);

        return data.result;
    }
};

fn Stream(comptime T: type, comptime StreamT: type, comptime options: xev.stream.Options) type {
    return struct {
        pub usingnamespace if (options.close) Closeable(T, StreamT) else struct {};
        pub usingnamespace if (options.read != .none) Readable(T, StreamT) else struct {};
        pub usingnamespace if (options.write != .none) Writeable(T, StreamT) else struct {};
    };
}

fn Closeable(comptime T: type, comptime StreamT: type) type {
    return struct {
        const Self = T;
        const CloseResult = xev.CloseError!void;
        pub fn close(self: Self) !void {
            const ResultT = CloseResult;
            const Data = struct {
                result: ResultT = undefined,
                frame: ?Frame = null,

                fn callback(
                    userdata: ?*@This(),
                    l: *xev.Loop,
                    c: *xev.Completion,
                    s: StreamT,
                    result: ResultT,
                ) xev.CallbackAction {
                    _ = l;
                    _ = c;
                    _ = s;
                    const data = userdata.?;
                    data.result = result;
                    if (data.frame != null) libcoro.xresume(data.frame.?);
                    return .disarm;
                }
            };

            var data: Data = .{ .frame = libcoro.xframe() };

            var c: xev.Completion = .{};
            self.stream().close(getLoop(self.loop), &c, Data, &data, &Data.callback);

            try waitForCompletion(self.loop, &c);

            return data.result;
        }
    };
}

fn Readable(comptime T: type, comptime StreamT: type) type {
    return struct {
        const Self = T;
        const ReadResult = xev.ReadError!usize;
        pub fn read(self: Self, buf: xev.ReadBuffer) !usize {
            const ResultT = ReadResult;
            const Data = struct {
                result: ResultT = undefined,
                frame: ?Frame = null,

                fn callback(
                    userdata: ?*@This(),
                    l: *xev.Loop,
                    c: *xev.Completion,
                    s: StreamT,
                    b: xev.ReadBuffer,
                    result: ResultT,
                ) xev.CallbackAction {
                    _ = l;
                    _ = c;
                    _ = s;
                    _ = b;
                    const data = userdata.?;
                    data.result = result;
                    if (data.frame != null) libcoro.xresume(data.frame.?);
                    return .disarm;
                }
            };

            var data: Data = .{ .frame = libcoro.xframe() };

            var c: xev.Completion = .{};
            self.stream().read(getLoop(self.loop), &c, buf, Data, &data, &Data.callback);

            try waitForCompletion(self.loop, &c);

            return data.result;
        }
    };
}

fn Writeable(comptime T: type, comptime StreamT: type) type {
    return struct {
        const Self = T;
        const WriteResult = xev.WriteError!usize;
        pub fn write(self: Self, buf: xev.WriteBuffer) !usize {
            const ResultT = WriteResult;
            const Data = struct {
                result: ResultT = undefined,
                frame: ?Frame = null,

                fn callback(
                    userdata: ?*@This(),
                    l: *xev.Loop,
                    c: *xev.Completion,
                    s: StreamT,
                    b: xev.WriteBuffer,
                    result: ResultT,
                ) xev.CallbackAction {
                    _ = l;
                    _ = c;
                    _ = s;
                    _ = b;
                    const data = userdata.?;
                    data.result = result;
                    if (data.frame != null) libcoro.xresume(data.frame.?);
                    return .disarm;
                }
            };

            var data: Data = .{ .frame = libcoro.xframe() };

            var c: xev.Completion = .{};
            self.stream().write(getLoop(self.loop), &c, buf, Data, &data, &Data.callback);

            try waitForCompletion(self.loop, &c);
            return data.result;
        }
    };
}

pub const File = struct {
    const Self = @This();

    loop: ?*xev.Loop,
    file: xev.File,

    pub usingnamespace Stream(Self, xev.File, .{
        .close = true,
        .read = .read,
        .write = .write,
        .threadpool = true,
    });

    pub fn init(loop: ?*xev.Loop, file: xev.File) Self {
        return .{ .loop = loop, .file = file };
    }

    fn stream(self: Self) xev.File {
        return self.file;
    }

    const PReadResult = xev.ReadError!usize;
    pub fn pread(self: Self, buf: xev.ReadBuffer, offset: u64) PReadResult {
        const ResultT = PReadResult;
        const Data = struct {
            result: ResultT = undefined,
            frame: ?Frame = null,

            fn callback(
                userdata: ?*@This(),
                l: *xev.Loop,
                c: *xev.Completion,
                s: xev.File,
                b: xev.ReadBuffer,
                result: ResultT,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = s;
                _ = b;
                const data = userdata.?;
                data.result = result;
                if (data.frame != null) libcoro.xresume(data.frame.?);
                return .disarm;
            }
        };

        var data: Data = .{ .frame = libcoro.xframe() };

        var c: xev.Completion = .{};
        self.file.pread(getLoop(self.loop), &c, buf, offset, Data, &data, &Data.callback);

        try waitForCompletion(self.loop, &c);

        return data.result;
    }

    const PWriteResult = xev.WriteError!usize;
    pub fn pwrite(self: Self, buf: xev.WriteBuffer, offset: u64) PWriteResult {
        const ResultT = PWriteResult;
        const Data = struct {
            result: ResultT = undefined,
            frame: ?Frame = null,

            fn callback(
                userdata: ?*@This(),
                l: *xev.Loop,
                c: *xev.Completion,
                s: xev.File,
                b: xev.WriteBuffer,
                result: ResultT,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = s;
                _ = b;
                const data = userdata.?;
                data.result = result;
                if (data.frame != null) libcoro.xresume(data.frame.?);
                return .disarm;
            }
        };

        var data: Data = .{ .frame = libcoro.xframe() };

        var c: xev.Completion = .{};
        self.file.pwrite(getLoop(self.loop), &c, buf, offset, Data, &data, &Data.callback);

        try waitForCompletion(self.loop, &c);

        return data.result;
    }
};

pub const Process = struct {
    const Self = @This();

    loop: ?*xev.Loop,
    p: xev.Process,

    pub fn init(loop: ?*xev.Loop, p: xev.Process) Self {
        return .{ .loop = loop, .p = p };
    }

    const WaitResult = xev.Process.WaitError!u32;
    pub fn wait(self: Self) !u32 {
        const Data = XCallback(WaitResult);
        var c: xev.Completion = .{};
        var data = Data.init();
        self.p.wait(getLoop(self.loop), &c, Data, &data, &Data.callback);

        try waitForCompletion(self.loop, &c);

        return data.result;
    }
};

pub const AsyncNotification = struct {
    const Self = @This();

    loop: ?*xev.Loop,
    notif: xev.Async,

    pub fn init(loop: ?*xev.Loop, notif: xev.Async) Self {
        return .{ .loop = loop, .notif = notif };
    }

    const WaitResult = xev.Async.WaitError!void;
    pub fn wait(self: Self) !void {
        const Data = XCallback(WaitResult);

        var c: xev.Completion = .{};
        var data = Data.init();
        self.notif.wait(getLoop(self.loop), &c, Data, &data, &Data.callback);

        try waitForCompletion(self.loop, &c);

        return data.result;
    }
};

pub const UDP = struct {
    const Self = @This();

    loop: ?*xev.Loop,
    udp: xev.UDP,

    pub usingnamespace Stream(Self, xev.UDP, .{
        .close = true,
        .read = .none,
        .write = .none,
    });

    pub fn init(loop: ?*xev.Loop, udp: xev.UDP) Self {
        return .{ .loop = loop, .udp = udp };
    }

    pub fn stream(self: Self) xev.UDP {
        return self.udp;
    }

    const ReadResult = xev.ReadError!usize;
    pub fn read(self: Self, buf: xev.ReadBuffer) !usize {
        const ResultT = ReadResult;
        const Data = struct {
            result: ResultT = undefined,
            frame: ?Frame = null,

            fn callback(
                userdata: ?*@This(),
                l: *xev.Loop,
                c: *xev.Completion,
                s: *xev.UDP.State,
                addr: std.net.Address,
                udp: xev.UDP,
                b: xev.ReadBuffer,
                result: ResultT,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = s;
                _ = addr;
                _ = udp;
                _ = b;
                const data = userdata.?;
                data.result = result;
                if (data.frame != null) libcoro.xresume(data.frame.?);
                return .disarm;
            }
        };

        var s: xev.UDP.State = undefined;
        var c: xev.Completion = .{};
        var data: Data = .{ .frame = libcoro.xframe() };
        self.udp.read(getLoop(self.loop), &c, &s, buf, Data, &data, &Data.callback);

        try waitForCompletion(self.loop, &c);

        return data.result;
    }

    const WriteResult = xev.WriteError!usize;
    pub fn write(self: Self, addr: std.net.Address, buf: xev.WriteBuffer) !usize {
        const ResultT = WriteResult;
        const Data = struct {
            result: ResultT = undefined,
            frame: ?Frame = null,

            fn callback(
                userdata: ?*@This(),
                l: *xev.Loop,
                c: *xev.Completion,
                s: *xev.UDP.State,
                udp: xev.UDP,
                b: xev.WriteBuffer,
                result: ResultT,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = s;
                _ = udp;
                _ = b;
                const data = userdata.?;
                data.result = result;
                if (data.frame != null) libcoro.xresume(data.frame.?);
                return .disarm;
            }
        };

        var s: xev.UDP.State = undefined;
        var c: xev.Completion = .{};
        var data: Data = .{ .frame = libcoro.xframe() };
        self.udp.write(getLoop(self.loop), &c, &s, addr, buf, Data, &data, &Data.callback);

        try waitForCompletion(self.loop, &c);

        return data.result;
    }
};

fn RunT(comptime Func: anytype, comptime opts: libcoro.CoroT.Options) type {
    const T = libcoro.CoroT.Signature.init(Func, opts).ReturnT();
    return switch (@typeInfo(T)) {
        .ErrorUnion => |E| E.payload,
        else => T,
    };
}

fn XCallback(comptime ResultT: type) type {
    return struct {
        frame: ?Frame = null,
        result: ResultT = undefined,

        fn init() @This() {
            return .{ .frame = libcoro.xframe() };
        }

        fn callback(
            userdata: ?*@This(),
            _: *xev.Loop,
            _: *xev.Completion,
            result: ResultT,
        ) xev.CallbackAction {
            const data = userdata.?;
            data.result = result;
            if (data.frame != null) libcoro.xresume(data.frame.?);
            return .disarm;
        }
    };
}

const std = @import("std");
const xev = @import("xev");
const libcoro = @import("coro.zig");

// Run a coroutine to completion.
// Must be called from "root", outside of any created coroutine.
// TODO: when xreturned returns an error, program crashes. I
// suspect something gone wrong in error set inference. The
// intention is to join the errors from the "try"s with the
// error set of xreturned.
pub fn run(
    loop: *xev.Loop,
    func: anytype,
    args: anytype,
    stack: libcoro.StackT,
) !RunT(func, .{}) {
    const CoroFn = libcoro.CoroFunc(func, .{});
    var frame = CoroFn.init();
    var co = try frame.coro(args, stack);
    try runCoro(loop, co);
    return CoroFn.xreturned(co);
}

// Run a coroutine to completion.
// Must be called from "root", outside of any created coroutine.
pub fn runCoro(loop: *xev.Loop, co: *libcoro.Coro) !void {
    std.debug.assert(co.status == .Start);
    libcoro.xresume(co);
    while (co.status != .Done) {
        try loop.tick(1);
    }
}

// Run the coroutines concurrently and return when all are done.
// coros: tuple or slice of *libcoro.Coro
pub fn xawait(coros: anytype) void {
    const is_tuple = @typeInfo(@TypeOf(coros)) == .Struct;

    var num_suspends: usize = 0;

    // Start each coro. This coro will be the parent as it is the initial
    // resumer.
    if (is_tuple) {
        inline for (coros) |co| {
            std.debug.assert(co.status == .Start or co.status == .Done);
            if (co.status != .Done) {
                num_suspends += 1;
                libcoro.xresume(co);
            }
        }
    } else {
        for (coros) |co| {
            std.debug.assert(co.status == .Start or co.status == .Done);
            if (co.status != .Done) {
                num_suspends += 1;
                libcoro.xresume(co);
            }
        }
    }

    // As each coro completes, it will return control here.
    for (0..num_suspends) |_| {
        libcoro.xsuspend();
    }

    if (is_tuple) {
        inline for (coros) |co| {
            std.debug.assert(co.status == .Done);
        }
    } else {
        for (coros) |co| {
            std.debug.assert(co.status == .Done);
        }
    }
}

const SleepResult = xev.Timer.RunError!void;
pub fn sleep(loop: *xev.Loop, ms: u64) SleepResult {
    const Data = XCallback(SleepResult);

    var data = Data.init();
    const w = try xev.Timer.init();
    defer w.deinit();
    var c: xev.Completion = .{};
    w.run(loop, &c, ms, Data, &data, &Data.callback);

    libcoro.xsuspend();

    return data.result;
}

pub const TCP = struct {
    const Self = @This();

    loop: *xev.Loop,
    tcp: xev.TCP,

    pub usingnamespace Stream(Self, xev.TCP, .{
        .close = true,
        .read = .recv,
        .write = .send,
    });

    pub fn init(loop: *xev.Loop, tcp: xev.TCP) Self {
        return .{ .loop = loop, .tcp = tcp };
    }

    fn stream(self: Self) xev.TCP {
        return self.tcp;
    }

    pub fn accept(self: Self) xev.TCP.AcceptError!Self {
        const AcceptResult = xev.TCP.AcceptError!xev.TCP;
        const Data = XCallback(AcceptResult);

        var data = Data.init();
        var c: xev.Completion = .{};
        self.tcp.accept(self.loop, &c, Data, &data, &Data.callback);

        libcoro.xsuspend();

        if (data.result) |result| {
            return .{ .loop = self.loop, .tcp = result };
        } else |err| return err;
    }

    const ConnectResult = xev.TCP.ConnectError!void;
    pub fn connect(self: Self, addr: std.net.Address) ConnectResult {
        const ResultT = ConnectResult;
        const Data = struct {
            result: ResultT = undefined,
            coro: *libcoro.Coro = undefined,

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
                libcoro.xresume(data.coro);
                return .disarm;
            }
        };

        var data: Data = .{ .coro = libcoro.xcurrent() };

        var c: xev.Completion = .{};
        self.tcp.connect(self.loop, &c, addr, Data, &data, &Data.callback);

        libcoro.xsuspend();

        return data.result;
    }

    const ShutdownResult = xev.TCP.ShutdownError!void;
    pub fn shutdown(self: Self) ShutdownResult {
        const ResultT = ShutdownResult;
        const Data = struct {
            result: ResultT = undefined,
            coro: *libcoro.Coro = undefined,

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
                libcoro.xresume(data.coro);
                return .disarm;
            }
        };

        var data: Data = .{ .coro = libcoro.xcurrent() };

        var c: xev.Completion = .{};
        self.tcp.shutdown(self.loop, &c, Data, &data, &Data.callback);

        libcoro.xsuspend();

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
        pub fn close(self: Self) CloseResult {
            const ResultT = CloseResult;
            const Data = struct {
                result: ResultT = undefined,
                coro: *libcoro.Coro = undefined,

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
                    libcoro.xresume(data.coro);
                    return .disarm;
                }
            };

            var data: Data = .{ .coro = libcoro.xcurrent() };

            var c: xev.Completion = .{};
            self.stream().close(self.loop, &c, Data, &data, &Data.callback);

            libcoro.xsuspend();

            return data.result;
        }
    };
}

fn Readable(comptime T: type, comptime StreamT: type) type {
    return struct {
        const Self = T;
        const ReadResult = xev.ReadError!usize;
        pub fn read(self: Self, buf: xev.ReadBuffer) ReadResult {
            const ResultT = ReadResult;
            const Data = struct {
                result: ResultT = undefined,
                coro: *libcoro.Coro = undefined,

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
                    libcoro.xresume(data.coro);
                    return .disarm;
                }
            };

            var data: Data = .{ .coro = libcoro.xcurrent() };

            var c: xev.Completion = .{};
            self.stream().read(self.loop, &c, buf, Data, &data, &Data.callback);

            libcoro.xsuspend();

            return data.result;
        }
    };
}

fn Writeable(comptime T: type, comptime StreamT: type) type {
    return struct {
        const Self = T;
        const WriteResult = xev.WriteError!usize;
        pub fn write(self: Self, buf: xev.WriteBuffer) WriteResult {
            const ResultT = WriteResult;
            const Data = struct {
                result: ResultT = undefined,
                coro: *libcoro.Coro = undefined,

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
                    libcoro.xresume(data.coro);
                    return .disarm;
                }
            };

            var data: Data = .{ .coro = libcoro.xcurrent() };

            var c: xev.Completion = .{};
            self.stream().write(self.loop, &c, buf, Data, &data, &Data.callback);

            libcoro.xsuspend();

            return data.result;
        }
    };
}

pub const File = struct {
    const Self = @This();

    loop: *xev.Loop,
    file: xev.File,

    pub usingnamespace Stream(Self, xev.File, .{
        .close = true,
        .read = .read,
        .write = .write,
        .threadpool = true,
    });

    pub fn init(loop: *xev.Loop, file: xev.File) Self {
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
            coro: *libcoro.Coro = undefined,

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
                libcoro.xresume(data.coro);
                return .disarm;
            }
        };

        var data: Data = .{ .coro = libcoro.xcurrent() };

        var c: xev.Completion = .{};
        self.file.pread(self.loop, &c, buf, offset, Data, &data, &Data.callback);

        libcoro.xsuspend();

        return data.result;
    }

    const PWriteResult = xev.WriteError!usize;
    pub fn pwrite(self: Self, buf: xev.WriteBuffer, offset: u64) PWriteResult {
        const ResultT = PWriteResult;
        const Data = struct {
            result: ResultT = undefined,
            coro: *libcoro.Coro = undefined,

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
                libcoro.xresume(data.coro);
                return .disarm;
            }
        };

        var data: Data = .{ .coro = libcoro.xcurrent() };

        var c: xev.Completion = .{};
        self.file.pwrite(self.loop, &c, buf, offset, Data, &data, &Data.callback);

        libcoro.xsuspend();

        return data.result;
    }
};

pub const Process = struct {
    const Self = @This();

    loop: *xev.Loop,
    p: xev.Process,

    pub fn init(loop: *xev.Loop, p: xev.Process) Self {
        return .{ .loop = loop, .p = p };
    }

    const WaitResult = xev.Process.WaitError!u32;
    pub fn wait(self: Self) WaitResult {
        const Data = XCallback(WaitResult);
        var c: xev.Completion = .{};
        var data = Data.init();
        self.p.wait(self.loop, &c, Data, &data, &Data.callback);

        libcoro.xsuspend();

        return data.result;
    }
};

pub const Async = struct {
    const Self = @This();

    loop: *xev.Loop,
    xasync: xev.Async,

    pub fn init(loop: *xev.Loop, xasync: xev.Async) Self {
        return .{ .loop = loop, .xasync = xasync };
    }

    const WaitResult = xev.Async.WaitError!void;
    pub fn wait(self: Self) WaitResult {
        const Data = XCallback(WaitResult);

        var c: xev.Completion = .{};
        var data = Data.init();
        self.xasync.wait(self.loop, &c, Data, &data, &Data.callback);

        libcoro.xsuspend();

        return data.result;
    }
};

pub const UDP = struct {
    const Self = @This();

    loop: *xev.Loop,
    udp: xev.UDP,

    pub usingnamespace Stream(Self, xev.UDP, .{
        .close = true,
        .read = .none,
        .write = .none,
    });

    pub fn init(loop: *xev.Loop, udp: xev.UDP) Self {
        return .{ .loop = loop, .udp = udp };
    }

    pub fn stream(self: Self) xev.UDP {
        return self.udp;
    }

    const ReadResult = xev.ReadError!usize;
    pub fn read(self: Self, buf: xev.ReadBuffer) ReadResult {
        const ResultT = ReadResult;
        const Data = struct {
            result: ResultT = undefined,
            coro: *libcoro.Coro = undefined,

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
                libcoro.xresume(data.coro);
                return .disarm;
            }
        };

        var s: xev.UDP.State = undefined;
        var c: xev.Completion = .{};
        var data: Data = .{ .coro = libcoro.xcurrent() };
        self.udp.read(self.loop, &c, &s, buf, Data, &data, &Data.callback);

        libcoro.xsuspend();

        return data.result;
    }

    const WriteResult = xev.WriteError!usize;
    pub fn write(self: Self, addr: std.net.Address, buf: xev.WriteBuffer) WriteResult {
        const ResultT = WriteResult;
        const Data = struct {
            result: ResultT = undefined,
            coro: *libcoro.Coro = undefined,

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
                libcoro.xresume(data.coro);
                return .disarm;
            }
        };

        var s: xev.UDP.State = undefined;
        var c: xev.Completion = .{};
        var data: Data = .{ .coro = libcoro.xcurrent() };
        self.udp.write(self.loop, &c, &s, addr, buf, Data, &data, &Data.callback);

        libcoro.xsuspend();

        return data.result;
    }
};

fn RunT(comptime Func: anytype, comptime opts: libcoro.FrameOptions) type {
    const T = libcoro.CoroSignature.init(Func, opts).getReturnT();
    return switch (@typeInfo(T)) {
        .ErrorUnion => |E| E.payload,
        else => T,
    };
}

fn XCallback(comptime ResultT: type) type {
    return struct {
        coro: *libcoro.Coro,
        result: ResultT = undefined,

        fn init() @This() {
            return .{ .coro = libcoro.xcurrent() };
        }

        fn callback(
            userdata: ?*@This(),
            _: *xev.Loop,
            _: *xev.Completion,
            result: ResultT,
        ) xev.CallbackAction {
            const data = userdata.?;
            data.result = result;
            libcoro.xresume(data.coro);
            return .disarm;
        }
    };
}

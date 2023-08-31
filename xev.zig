const std = @import("std");
const xev = @import("xev");
const libcoro = @import("coro.zig");

// Todos
// * Revisit global env
// * Groups of coroutines: waitAll, asCompleted
// * Timeouts, cancellations

pub const Env = struct {
    loop: *xev.Loop,
};
pub threadlocal var env: Env = undefined;

fn XCallback(comptime ResultT: type) type {
    return struct {
        coro: *libcoro.Coro,
        result: ResultT = undefined,

        fn init() @This() {
            return .{ .coro = libcoro.xcurrent() };
        }

        fn callback(
            userdata: ?*@This(),
            l: *xev.Loop,
            c: *xev.Completion,
            result: ResultT,
        ) xev.CallbackAction {
            _ = l;
            _ = c;
            const data = userdata.?;
            data.result = result;
            libcoro.xresume(data.coro);
            return .disarm;
        }
    };
}

pub const Async = struct {
    const Self = @This();

    xasync: xev.Async,

    pub fn init(xasync: xev.Async) Self {
        return .{ .xasync = xasync };
    }

    const WaitResult = xev.Async.WaitError!void;
    pub fn wait(self: Self) WaitResult {
        const Data = XCallback(WaitResult);

        var c: xev.Completion = .{};
        var data = Data.init();
        self.xasync.wait(env.loop, &c, Data, &data, &Data.callback);

        libcoro.xsuspend();

        return data.result;
    }
};

pub const UDP = struct {
    const Self = @This();

    udp: xev.UDP,

    pub usingnamespace Stream(Self, xev.UDP, .{
        .close = true,
        .read = .none,
        .write = .none,
    });

    pub fn init(udp: xev.UDP) Self {
        return .{ .udp = udp };
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
        self.udp.read(env.loop, &c, &s, buf, Data, &data, &Data.callback);

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
        self.udp.write(env.loop, &c, &s, addr, buf, Data, &data, &Data.callback);

        libcoro.xsuspend();

        return data.result;
    }
};

pub const Process = struct {
    const Self = @This();

    p: xev.Process,

    pub fn init(p: xev.Process) Self {
        return .{ .p = p };
    }

    const WaitResult = xev.Process.WaitError!u32;
    pub fn wait(self: Self) WaitResult {
        const Data = XCallback(WaitResult);
        var c: xev.Completion = .{};
        var data = Data.init();
        self.p.wait(env.loop, &c, Data, &data, &Data.callback);

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
            self.stream().close(env.loop, &c, Data, &data, &Data.callback);

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
            self.stream().read(env.loop, &c, buf, Data, &data, &Data.callback);

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
            self.stream().write(env.loop, &c, buf, Data, &data, &Data.callback);

            libcoro.xsuspend();

            return data.result;
        }
    };
}

pub const File = struct {
    const Self = @This();

    file: xev.File,

    pub usingnamespace Stream(Self, xev.File, .{
        .close = true,
        .read = .read,
        .write = .write,
        .threadpool = true,
    });

    pub fn init(file: xev.File) Self {
        return .{ .file = file };
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
        self.file.pread(env.loop, &c, buf, offset, Data, &data, &Data.callback);

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
        self.file.pwrite(env.loop, &c, buf, offset, Data, &data, &Data.callback);

        libcoro.xsuspend();

        return data.result;
    }
};

pub const TCP = struct {
    const Self = @This();

    tcp: xev.TCP,

    pub usingnamespace Stream(Self, xev.TCP, .{
        .close = true,
        .read = .recv,
        .write = .send,
    });

    pub fn init(tcp: xev.TCP) Self {
        return .{ .tcp = tcp };
    }

    fn stream(self: Self) xev.TCP {
        return self.tcp;
    }

    pub fn accept(self: Self) xev.TCP.AcceptError!Self {
        const AcceptResult = xev.TCP.AcceptError!xev.TCP;
        const Data = XCallback(AcceptResult);

        var data = Data.init();
        var c: xev.Completion = .{};
        self.tcp.accept(env.loop, &c, Data, &data, &Data.callback);

        libcoro.xsuspend();

        if (data.result) |result| {
            return .{ .tcp = result };
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
        self.tcp.connect(env.loop, &c, addr, Data, &data, &Data.callback);

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
        self.tcp.shutdown(env.loop, &c, Data, &data, &Data.callback);

        libcoro.xsuspend();

        return data.result;
    }
};

const SleepResult = xev.Timer.RunError!void;
pub fn sleep(ms: u64) SleepResult {
    const Data = XCallback(SleepResult);

    var data = Data.init();
    const w = try xev.Timer.init();
    defer w.deinit();
    var c: xev.Completion = .{};
    w.run(env.loop, &c, ms, Data, &data, &Data.callback);

    libcoro.xsuspend();

    return data.result;
}

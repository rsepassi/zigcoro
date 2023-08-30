const std = @import("std");
const xev = @import("xev");
const libcoro = @import("libcoro");

// Todos
// * CoroPool to reuse stack memory
// * Groups of coroutines: waitAll, asCompleted
// * Timeouts, cancellations

const Env = struct {
    loop: *xev.Loop,
    allocator: std.mem.Allocator,
};
var env: Env = undefined;

fn Stream(comptime T: type, comptime StreamT: type, comptime options: xev.stream.Options) type {
    return struct {
        pub usingnamespace if (options.close) Closeable(T, StreamT, options) else struct {};
        pub usingnamespace if (options.read != .none) Readable(T, StreamT, options) else struct {};
        pub usingnamespace if (options.write != .none) Writeable(T, StreamT, options) else struct {};
    };
}

fn Closeable(comptime T: type, comptime StreamT: type, comptime options: xev.stream.Options) type {
    _ = options;
    return struct {
        const Self = T;
        const CloseResult = xev.CloseError!void;
        fn close(self: Self) CloseResult {
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

fn Readable(comptime T: type, comptime StreamT: type, comptime options: xev.stream.Options) type {
    _ = options;
    return struct {
        const Self = T;
        const ReadResult = xev.ReadError!usize;
        fn read(self: Self, buf: xev.ReadBuffer) ReadResult {
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

fn Writeable(comptime T: type, comptime StreamT: type, comptime options: xev.stream.Options) type {
    _ = options;
    return struct {
        const Self = T;
        const WriteResult = xev.WriteError!usize;
        fn write(self: Self, buf: xev.WriteBuffer) WriteResult {
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

const TCP = struct {
    const Self = @This();

    tcp: xev.TCP,

    usingnamespace Stream(Self, xev.TCP, .{
        .close = true,
        .read = .recv,
        .write = .send,
    });

    fn init(tcp: xev.TCP) Self {
        return .{ .tcp = tcp };
    }

    fn stream(self: Self) xev.TCP {
        return self.tcp;
    }

    fn ResultData(comptime ResultT: type) type {
        return struct {
            result: ResultT = undefined,
            coro: *libcoro.Coro = undefined,

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

    fn accept(self: Self) xev.TCP.AcceptError!Self {
        const AcceptResult = xev.TCP.AcceptError!xev.TCP;
        const ResultT = AcceptResult;
        const Data = struct {
            result: ResultT = undefined,
            coro: *libcoro.Coro = undefined,

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

        var data: Data = .{ .coro = libcoro.xcurrent() };

        var c: xev.Completion = .{};
        self.tcp.accept(env.loop, &c, Data, &data, &Data.callback);

        libcoro.xsuspend();

        if (data.result) |result| {
            return .{ .tcp = result };
        } else |err| return err;
    }

    const ConnectResult = xev.TCP.ConnectError!void;
    fn connect(self: Self, addr: std.net.Address) ConnectResult {
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
    fn shutdown(self: Self) ShutdownResult {
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

fn sleep(ms: u64) xev.Timer.RunError!void {
    const Data = struct {
        result: xev.Timer.RunError!void = {},
        coro: *libcoro.Coro = undefined,

        fn callback(
            userdata: ?*@This(),
            loop: *xev.Loop,
            c: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = c;
            _ = loop;
            const self = userdata.?;
            self.result = result;
            libcoro.xresume(self.coro);
            return .disarm;
        }
    };

    var data: Data = .{ .coro = libcoro.xcurrent() };

    const w = try xev.Timer.init();
    defer w.deinit();
    var c: xev.Completion = .{};
    w.run(env.loop, &c, ms, Data, &data, &Data.callback);

    libcoro.xsuspend();

    return data.result;
}

pub fn main() !void {
    std.debug.print("main start\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    env = .{
        .loop = &loop,
        .allocator = allocator,
    };

    // 2 parallel timer loops, one fast, one slow
    const main_coro = try libcoro.xcoroAlloc(tickLoop, .{ 500, "slow" }, env.allocator, null, .{});
    defer main_coro.deinit();
    try libcoro.xresume(main_coro);

    const main_coro2 = try libcoro.xcoroAlloc(tickLoop, .{ 250, "fast" }, env.allocator, null, .{});
    defer main_coro2.deinit();
    try libcoro.xresume(main_coro2);

    var info: ServerInfo = .{};
    const main_coro3 = try libcoro.xcoroAlloc(tcpServer, .{&info}, env.allocator, 1024 * 32, .{});
    defer main_coro3.deinit();
    try libcoro.xresume(main_coro3);

    const main_coro4 = try libcoro.xcoroAlloc(tcpClient, .{&info}, env.allocator, 1024 * 32, .{});
    defer main_coro4.deinit();
    try libcoro.xresume(main_coro4);

    std.debug.print("main loop run\n", .{});
    try loop.run(.until_done);
    std.debug.print("main end\n", .{});
}

fn tickLoop(tick: usize, name: []const u8) !void {
    std.debug.print("tickLoop {s} start\n", .{name});

    for (0..6) |i| {
        try sleep(tick);
        std.debug.print("{s} tick {d}\n", .{ name, i });
    }

    std.debug.print("tickLoop {s} end\n", .{name});
}

const ServerInfo = struct {
    addr: std.net.Address = undefined,
};

fn tcpServer(info: *ServerInfo) !void {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try xev.TCP.init(address);

    try server.bind(address);
    try server.listen(1);

    var sock_len = address.getOsSockLen();
    try std.os.getsockname(server.fd, &address.any, &sock_len);
    info.addr = address;
    std.debug.print("tcp listen {any}\n", .{address});

    const cserver = TCP.init(server);
    const conn = try cserver.accept();
    defer conn.close() catch unreachable;
    try cserver.close();

    var recv_buf: [128]u8 = undefined;
    const recv_len = try conn.read(.{ .slice = &recv_buf });
    std.debug.print("tcp bytes received {d}\n", .{recv_len});
    const send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    std.debug.assert(std.mem.eql(u8, &send_buf, recv_buf[0..recv_len]));
}

fn tcpClient(info: *ServerInfo) !void {
    const address = info.addr;
    std.debug.print("tcp connect {any}\n", .{address});
    const client = try xev.TCP.init(address);
    const cclient = TCP.init(client);
    defer cclient.close() catch unreachable;
    _ = try cclient.connect(address);
    var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    const send_len = try cclient.write(.{ .slice = &send_buf });
    std.debug.print("tcp bytes send {d}\n", .{send_len});
}

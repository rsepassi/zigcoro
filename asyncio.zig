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

const Async = struct {
    const Self = @This();

    xasync: xev.Async,

    fn init(xasync: xev.Async) Self {
        return .{ .xasync = xasync };
    }

    const WaitResult = xev.Async.WaitError!void;
    fn wait(self: Self) WaitResult {
        const Data = XCallback(WaitResult);

        var c: xev.Completion = .{};
        var data = Data.init();
        self.xasync.wait(env.loop, &c, Data, &data, &Data.callback);

        libcoro.xsuspend();

        return data.result;
    }
};

const UDP = struct {
    const Self = @This();

    udp: xev.UDP,

    usingnamespace Stream(Self, xev.UDP, .{
        .close = true,
        .read = .none,
        .write = .none,
    });

    fn init(udp: xev.UDP) Self {
        return .{ .udp = udp };
    }

    fn stream(self: Self) xev.UDP {
        return self.udp;
    }

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
    fn write(self: Self, addr: std.net.Address, buf: xev.WriteBuffer) WriteResult {
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

const Process = struct {
    const Self = @This();

    p: xev.Process,

    fn init(p: xev.Process) Self {
        return .{ .p = p };
    }

    const WaitResult = xev.Process.WaitError!u32;
    fn wait(self: Self) WaitResult {
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

fn Readable(comptime T: type, comptime StreamT: type) type {
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

fn Writeable(comptime T: type, comptime StreamT: type) type {
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

const File = struct {
    const Self = @This();

    file: xev.File,

    usingnamespace Stream(Self, xev.File, .{
        .close = true,
        .read = .read,
        .write = .write,
        .threadpool = true,
    });

    fn init(file: xev.File) Self {
        return .{ .file = file };
    }

    fn stream(self: Self) xev.File {
        return self.file;
    }

    const PReadResult = xev.ReadError!usize;
    fn pread(self: Self, buf: xev.ReadBuffer, offset: u64) PReadResult {
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
    fn pwrite(self: Self, buf: xev.WriteBuffer, offset: u64) PWriteResult {
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

    fn accept(self: Self) xev.TCP.AcceptError!Self {
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

const SleepResult = xev.Timer.RunError!void;
fn sleep(ms: u64) SleepResult {
    const Data = XCallback(SleepResult);

    var data = Data.init();
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

    var tpool = xev.ThreadPool.init(.{});
    defer tpool.deinit();
    defer tpool.shutdown();
    var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
    defer loop.deinit();

    env = .{
        .loop = &loop,
        .allocator = allocator,
    };

    const stack_size = 2 * 1024 * 1024; // 2MiB stacks

    // 2 parallel timer loops, one fast, one slow
    const main_coro = try libcoro.xcoroAlloc(tickLoop, .{ 500, "slow" }, env.allocator, null, .{});
    defer main_coro.deinit();
    try libcoro.xresume(main_coro);

    const main_coro2 = try libcoro.xcoroAlloc(tickLoop, .{ 250, "fast" }, env.allocator, null, .{});
    defer main_coro2.deinit();
    try libcoro.xresume(main_coro2);

    var info: ServerInfo = .{};
    const main_coro3 = try libcoro.xcoroAlloc(tcpServer, .{&info}, env.allocator, stack_size, .{});
    defer main_coro3.deinit();
    try libcoro.xresume(main_coro3);

    const main_coro4 = try libcoro.xcoroAlloc(tcpClient, .{&info}, env.allocator, stack_size, .{});
    defer main_coro4.deinit();
    try libcoro.xresume(main_coro4);

    const main_coro5 = try libcoro.xcoroAlloc(fileRW, .{}, env.allocator, stack_size, .{});
    defer main_coro5.deinit();
    try libcoro.xresume(main_coro5);

    const main_coro6 = try libcoro.xcoroAlloc(processTest, .{}, env.allocator, stack_size, .{});
    defer main_coro6.deinit();
    try libcoro.xresume(main_coro6);

    var udp_info: ServerInfo = .{};
    const main_coro7 = try libcoro.xcoroAlloc(udpServer, .{&udp_info}, env.allocator, stack_size, .{});
    defer main_coro7.deinit();
    try libcoro.xresume(main_coro7);

    const main_coro8 = try libcoro.xcoroAlloc(udpClient, .{&udp_info}, env.allocator, stack_size, .{});
    defer main_coro8.deinit();
    try libcoro.xresume(main_coro8);

    var nstate = NotifierState{ .x = try xev.Async.init() };
    defer nstate.x.deinit();
    const main_coro9 = try libcoro.xcoroAlloc(asyncTest, .{&nstate}, env.allocator, stack_size, .{});
    defer main_coro9.deinit();
    try libcoro.xresume(main_coro9);

    const main_coro10 = try libcoro.xcoroAlloc(asyncNotifier, .{&nstate}, env.allocator, stack_size, .{});
    defer main_coro10.deinit();
    try libcoro.xresume(main_coro10);

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
    const xserver = try xev.TCP.init(address);

    try xserver.bind(address);
    try xserver.listen(1);

    var sock_len = address.getOsSockLen();
    try std.os.getsockname(xserver.fd, &address.any, &sock_len);
    info.addr = address;
    std.debug.print("tcp listen {any}\n", .{address});

    const server = TCP.init(xserver);
    const conn = try server.accept();
    defer conn.close() catch unreachable;
    try server.close();

    var recv_buf: [128]u8 = undefined;
    const recv_len = try conn.read(.{ .slice = &recv_buf });
    std.debug.print("tcp bytes received {d}\n", .{recv_len});
    const send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    std.debug.assert(std.mem.eql(u8, &send_buf, recv_buf[0..recv_len]));
}

fn tcpClient(info: *ServerInfo) !void {
    const address = info.addr;
    std.debug.print("tcp connect {any}\n", .{address});
    const xclient = try xev.TCP.init(address);
    const client = TCP.init(xclient);
    defer client.close() catch unreachable;
    _ = try client.connect(address);
    var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    const send_len = try client.write(.{ .slice = &send_buf });
    std.debug.print("tcp bytes send {d}\n", .{send_len});
}

fn fileRW() !void {
    const path = "test_watcher_file";
    const f = try std.fs.cwd().createFile(path, .{
        .read = true,
        .truncate = true,
    });
    defer f.close();
    defer std.fs.cwd().deleteFile(path) catch {};
    const xfile = try xev.File.init(f);
    const file = File.init(xfile);
    var write_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    const write_len = try file.write(.{ .slice = &write_buf });
    std.debug.print("fileRW wrote {d} bytes\n", .{write_len});
    std.debug.assert(write_len == write_buf.len);
    try f.sync();
    const f2 = try std.fs.cwd().openFile(path, .{});
    defer f2.close();
    const xfile2 = try xev.File.init(f2);
    const file2 = File.init(xfile2);
    var read_buf: [128]u8 = undefined;
    const read_len = try file2.read(.{ .slice = &read_buf });
    std.debug.print("fileRW read {d} bytes\n", .{read_len});
    std.debug.assert(write_len == read_len);
    std.debug.assert(std.mem.eql(u8, &write_buf, read_buf[0..read_len]));
}

fn processTest() !void {
    const alloc = std.heap.c_allocator;
    var child = std.ChildProcess.init(&.{ "sh", "-c", "exit 0" }, alloc);
    std.debug.print("childprocess start\n", .{});
    try child.spawn();

    var xp = try xev.Process.init(child.id);
    defer xp.deinit();

    const p = Process.init(xp);
    const rc = try p.wait();
    std.debug.assert(rc == 0);
    std.debug.print("childprocess done\n", .{});
}

fn udpServer(info: *ServerInfo) !void {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const xserver = try xev.UDP.init(address);

    try xserver.bind(address);

    var sock_len = address.getOsSockLen();
    try std.os.getsockname(xserver.fd, &address.any, &sock_len);
    info.addr = address;
    std.debug.print("udp listen {any}\n", .{address});

    const server = UDP.init(xserver);

    var recv_buf: [128]u8 = undefined;
    const recv_len = try server.read(.{ .slice = &recv_buf });
    std.debug.print("udp recv {d} bytes\n", .{recv_len});
    var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    std.debug.assert(recv_len == send_buf.len);
    std.debug.assert(std.mem.eql(u8, &send_buf, recv_buf[0..recv_len]));
    try server.close();
}

fn udpClient(info: *ServerInfo) !void {
    const xclient = try xev.UDP.init(info.addr);
    const client = UDP.init(xclient);
    var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    const send_len = try client.write(info.addr, .{ .slice = &send_buf });
    std.debug.print("udp send {d} bytes\n", .{send_len});
    std.debug.assert(send_len == 7);
    try client.close();
}

const NotifierState = struct {
    x: xev.Async,
    notified: bool = false,
};

fn asyncTest(state: *NotifierState) !void {
    const notif = Async.init(state.x);
    try notif.wait();
    state.notified = true;
}

fn asyncNotifier(state: *NotifierState) !void {
    try state.x.notify();
    try sleep(100);
    std.debug.assert(state.notified);
    std.debug.print("async notified\n", .{});
}

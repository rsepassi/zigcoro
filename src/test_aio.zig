const std = @import("std");
const libcoro = @import("libcoro");
const xev = @import("xev");
const aio = libcoro.asyncio;

threadlocal var env: struct { allocator: std.mem.Allocator, loop: *xev.Loop } = undefined;

const AioTest = struct {
    allocator: std.mem.Allocator,
    tp: *xev.ThreadPool,
    loop: *xev.Loop,

    fn init() !@This() {
        const allocator = std.testing.allocator;

        // Allocate on heap for pointer stability
        var tp = try allocator.create(xev.ThreadPool);
        var loop = try allocator.create(xev.Loop);
        tp.* = xev.ThreadPool.init(.{});
        loop.* = try xev.Loop.init(.{ .thread_pool = tp });

        // Thread-local env
        env = .{
            .allocator = allocator,
            .loop = loop,
        };

        return .{
            .allocator = allocator,
            .tp = tp,
            .loop = loop,
        };
    }

    fn deinit(self: @This()) void {
        self.loop.deinit();
        self.tp.shutdown();
        self.tp.deinit();
        self.allocator.destroy(self.tp);
        self.allocator.destroy(self.loop);
    }

    fn run(self: @This(), func: anytype) !void {
        const stack = try libcoro.stackAlloc(self.allocator, 1024 * 32);
        defer self.allocator.free(stack);
        try aio.run(self.loop, func, .{}, stack);
    }
};

fn sleep(ms: u64) !i64 {
    try aio.sleep(env.loop, ms);
    try std.testing.expect(libcoro.remainingStackSize() > 1024 * 2);
    return std.time.milliTimestamp();
}
const SleepFn = libcoro.CoroFunc(sleep, .{});

test "aio sleep run" {
    const t = try AioTest.init();
    defer t.deinit();

    const stack = try libcoro.stackAlloc(
        t.allocator,
        null,
    );
    defer t.allocator.free(stack);
    const before = std.time.milliTimestamp();
    const after = try aio.run(t.loop, sleep, .{500}, stack);

    try std.testing.expect(after > (before + 497));
    try std.testing.expect(after < (before + 503));
}

fn sleepTask() !void {
    const stack = try libcoro.stackAlloc(
        env.allocator,
        null,
    );
    defer env.allocator.free(stack);
    var frame = SleepFn.init();
    var coro = try frame.coro(.{250}, stack);

    const stack2 = try libcoro.stackAlloc(
        env.allocator,
        null,
    );
    defer env.allocator.free(stack2);
    var frame2 = SleepFn.init();
    var coro2 = try frame2.coro(.{500}, stack2);

    aio.xawait(.{ coro, coro2 });

    const after = try SleepFn.xreturned(coro);
    const after2 = try SleepFn.xreturned(coro2);
    try std.testing.expect(after2 > (after + 247));
    try std.testing.expect(after2 < (after + 253));
}

test "aio concurrent sleep" {
    const t = try AioTest.init();
    defer t.deinit();

    const stack = try libcoro.stackAlloc(
        t.allocator,
        1024 * 8,
    );
    defer t.allocator.free(stack);
    const before = std.time.milliTimestamp();
    try aio.run(t.loop, sleepTask, .{}, stack);
    const after = std.time.milliTimestamp();

    try std.testing.expect(after > (before + 497));
    try std.testing.expect(after < (before + 503));
}

const TickState = struct {
    slow: usize = 0,
    fast: usize = 0,
};

fn tickLoop(tick: usize, state: *TickState) !void {
    const amfast = tick == 50;
    for (0..10) |i| {
        try aio.sleep(env.loop, tick);
        if (amfast) {
            state.fast += 1;
        } else {
            state.slow += 1;
        }
        if (!amfast and i >= 6) {
            try std.testing.expectEqual(state.fast, 10);
        }
    }
}
const TickLoopFn = libcoro.CoroFunc(tickLoop, .{});

fn aioTimersMain() !void {
    const stack_size: usize = 1024 * 16;

    var tick_state = TickState{};

    // 2 parallel timer loops, one fast, one slow
    var fn1 = TickLoopFn.init();
    const stack1 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack1);
    var co1 = try fn1.coro(.{ 50, &tick_state }, stack1);

    var fn2 = TickLoopFn.init();
    const stack2 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack2);
    var co2 = try fn2.coro(.{ 100, &tick_state }, stack2);

    aio.xawait(.{ co1, co2 });

    try std.testing.expectEqual(co1.status, .Done);
    try std.testing.expectEqual(co2.status, .Done);
    try std.testing.expect(!std.meta.isError(TickLoopFn.xreturned(co1)));
    try std.testing.expect(!std.meta.isError(TickLoopFn.xreturned(co2)));
}

test "aio timers" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(aioTimersMain);
}

fn tcpMain() !void {
    const stack_size = 1024 * 32;

    var info: ServerInfo = .{};

    var fn1 = libcoro.CoroFunc(tcpServer, .{}).init();
    const stack1 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack1);
    var server_co = try fn1.coro(.{&info}, stack1);

    var fn2 = libcoro.CoroFunc(tcpClient, .{}).init();
    const stack2 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack2);
    var client_co = try fn2.coro(.{&info}, stack2);

    aio.xawait(.{ server_co, client_co });
}

test "aio tcp" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(tcpMain);
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
    const file = aio.File.init(env.loop, xfile);
    var write_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    const write_len = try file.write(.{ .slice = &write_buf });
    try std.testing.expectEqual(write_len, write_buf.len);
    try f.sync();
    const f2 = try std.fs.cwd().openFile(path, .{});
    defer f2.close();
    const xfile2 = try xev.File.init(f2);
    const file2 = aio.File.init(env.loop, xfile2);
    var read_buf: [128]u8 = undefined;
    const read_len = try file2.read(.{ .slice = &read_buf });
    try std.testing.expectEqual(write_len, read_len);
    try std.testing.expect(std.mem.eql(u8, &write_buf, read_buf[0..read_len]));
}

test "aio file" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(fileRW);
}

fn udpMain() !void {
    const stack_size = 1024 * 32;
    var info: ServerInfo = .{};

    var fn1 = libcoro.CoroFunc(udpServer, .{}).init();
    const stack1 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack1);
    var server_co = try fn1.coro(.{&info}, stack1);

    var fn2 = libcoro.CoroFunc(udpClient, .{}).init();
    const stack2 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack2);
    var client_co = try fn2.coro(.{&info}, stack2);

    aio.xawait(.{ server_co, client_co });
}

test "aio udp" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(udpMain);
}

fn processTest() !void {
    const alloc = std.heap.c_allocator;
    var child = std.ChildProcess.init(&.{ "sh", "-c", "exit 0" }, alloc);
    try child.spawn();

    var xp = try xev.Process.init(child.id);
    defer xp.deinit();

    const p = aio.Process.init(env.loop, xp);
    const rc = try p.wait();
    try std.testing.expectEqual(rc, 0);
}

test "aio process" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(processTest);
}

fn asyncMain() !void {
    const stack_size = 1024 * 32;
    var nstate = NotifierState{ .x = try xev.Async.init() };

    var fn1 = libcoro.CoroFunc(asyncTest, .{}).init();
    const stack = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack);
    var co = try fn1.coro(.{&nstate}, stack);

    var fn2 = libcoro.CoroFunc(asyncNotifier, .{}).init();
    const stack2 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack2);
    var nco = try fn2.coro(.{&nstate}, stack2);

    aio.xawait(.{ co, nco });
}

test "aio async" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(asyncMain);
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

    const server = aio.TCP.init(env.loop, xserver);
    const conn = try server.accept();
    defer conn.close() catch unreachable;
    try server.close();

    var recv_buf: [128]u8 = undefined;
    const recv_len = try conn.read(.{ .slice = &recv_buf });
    const send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    try std.testing.expect(std.mem.eql(u8, &send_buf, recv_buf[0..recv_len]));
}

fn tcpClient(info: *ServerInfo) !void {
    const address = info.addr;
    const xclient = try xev.TCP.init(address);
    const client = aio.TCP.init(env.loop, xclient);
    defer client.close() catch unreachable;
    _ = try client.connect(address);
    var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    const send_len = try client.write(.{ .slice = &send_buf });
    try std.testing.expectEqual(send_len, 7);
}

fn udpServer(info: *ServerInfo) !void {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const xserver = try xev.UDP.init(address);

    try xserver.bind(address);

    var sock_len = address.getOsSockLen();
    try std.os.getsockname(xserver.fd, &address.any, &sock_len);
    info.addr = address;

    const server = aio.UDP.init(env.loop, xserver);

    var recv_buf: [128]u8 = undefined;
    const recv_len = try server.read(.{ .slice = &recv_buf });
    var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    try std.testing.expectEqual(recv_len, send_buf.len);
    try std.testing.expect(std.mem.eql(u8, &send_buf, recv_buf[0..recv_len]));
    try server.close();
}

fn udpClient(info: *ServerInfo) !void {
    const xclient = try xev.UDP.init(info.addr);
    const client = aio.UDP.init(env.loop, xclient);
    var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    const send_len = try client.write(info.addr, .{ .slice = &send_buf });
    try std.testing.expectEqual(send_len, 7);
    try client.close();
}

const NotifierState = struct {
    x: xev.Async,
    notified: bool = false,
};

fn asyncTest(state: *NotifierState) !void {
    const notif = aio.Async.init(env.loop, state.x);
    try notif.wait();
    state.notified = true;
}

fn asyncNotifier(state: *NotifierState) !void {
    try state.x.notify();
    try aio.sleep(env.loop, 100);
    try std.testing.expect(state.notified);
}

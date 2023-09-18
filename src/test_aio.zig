const std = @import("std");
const libcoro = @import("libcoro");
const xev = @import("xev");
const aio = libcoro.asyncio;

threadlocal var env: struct { allocator: std.mem.Allocator, loop: *xev.Loop } = undefined;

const AioTest = struct {
    allocator: std.mem.Allocator,
    tp: *xev.ThreadPool,
    loop: *xev.Loop,
    fla: *libcoro.allocators.FixedSizeFreeListAllocator,
    stacks: []u8,

    fn init() !@This() {
        const allocator = std.testing.allocator;

        // Allocate on heap for pointer stability
        var tp = try allocator.create(xev.ThreadPool);
        var loop = try allocator.create(xev.Loop);
        var fla = try allocator.create(libcoro.allocators.FixedSizeFreeListAllocator);
        tp.* = xev.ThreadPool.init(.{});
        loop.* = try xev.Loop.init(.{ .thread_pool = tp });
        const stack_size = 1024 * 64;
        const num_stacks = 5;
        const stacks = try allocator.alignedAlloc(u8, libcoro.stack_alignment, num_stacks * stack_size);
        fla.* = try libcoro.allocators.FixedSizeFreeListAllocator.init(libcoro.stack_alignment, stacks, stack_size, allocator);

        // Thread-local env
        env = .{
            .allocator = allocator,
            .loop = loop,
        };

        aio.initEnv(.{
            .loop = loop,
            .stack_allocator = fla.allocator(),
            .default_stack_size = stack_size,
        });

        return .{
            .allocator = allocator,
            .tp = tp,
            .loop = loop,
            .fla = fla,
            .stacks = stacks,
        };
    }

    fn deinit(self: @This()) void {
        self.loop.deinit();
        self.tp.shutdown();
        self.tp.deinit();
        self.fla.deinit();
        self.allocator.destroy(self.tp);
        self.allocator.destroy(self.loop);
        self.allocator.destroy(self.fla);
        self.allocator.free(self.stacks);
    }

    fn run(self: @This(), func: anytype) !void {
        const stack = try libcoro.stackAlloc(self.allocator, 1024 * 32);
        defer self.allocator.free(stack);
        try aio.run(self.loop, func, .{}, stack);
    }
};

test "aio sleep top-level" {
    const t = try AioTest.init();
    defer t.deinit();
    try aio.sleep(t.loop, 10);
}

fn sleep(ms: u64) !i64 {
    try aio.sleep(env.loop, ms);
    try std.testing.expect(libcoro.remainingStackSize() > 1024 * 2);
    return std.time.milliTimestamp();
}

test "aio sleep run" {
    const t = try AioTest.init();
    defer t.deinit();

    const stack = try libcoro.stackAlloc(
        t.allocator,
        null,
    );
    defer t.allocator.free(stack);
    const before = std.time.milliTimestamp();
    const after = try aio.run(t.loop, sleep, .{10}, stack);

    try std.testing.expect(after > (before + 7));
    try std.testing.expect(after < (before + 13));
}

fn sleepTask() !void {
    const stack = try libcoro.stackAlloc(
        env.allocator,
        null,
    );
    defer env.allocator.free(stack);
    var sleep1 = try aio.xasync(sleep, .{10}, stack);

    const stack2 = try libcoro.stackAlloc(
        env.allocator,
        null,
    );
    defer env.allocator.free(stack2);
    var sleep2 = try aio.xasync(sleep, .{20}, stack2);

    const after = try aio.xawait(sleep1);
    const after2 = try aio.xawait(sleep2);

    try std.testing.expect(after2 > (after + 7));
    try std.testing.expect(after2 < (after + 13));
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

    try std.testing.expect(after > (before + 17));
    try std.testing.expect(after < (before + 23));
}

const TickState = struct {
    slow: usize = 0,
    fast: usize = 0,
};

fn tickLoop(tick: usize, state: *TickState) !void {
    const amfast = tick == 10;
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

fn aioTimersMain() !void {
    const stack_size: usize = 1024 * 16;

    var tick_state = TickState{};

    // 2 parallel timer loops, one fast, one slow
    const stack1 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack1);
    const co1 = try aio.xasync(tickLoop, .{ 10, &tick_state }, stack1);
    const stack2 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack2);
    const co2 = try aio.xasync(tickLoop, .{ 20, &tick_state }, stack2);

    try aio.xawait(co1);
    try aio.xawait(co2);
}

test "aio timers" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(aioTimersMain);
}

fn tcpMain() !void {
    const stack_size = 1024 * 32;

    var info: ServerInfo = .{};

    const sstack = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(sstack);
    var server = try aio.xasync(tcpServer, .{&info}, sstack);

    const cstack = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(cstack);
    var client = try aio.xasync(tcpClient, .{&info}, cstack);

    try aio.xawait(server);
    try aio.xawait(client);
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

    const stack1 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack1);
    var server_co = try aio.xasync(udpServer, .{&info}, stack1);

    const stack2 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack2);
    var client_co = try aio.xasync(udpClient, .{&info}, stack2);

    try aio.xawait(server_co);
    try aio.xawait(client_co);
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

    const stack = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack);
    var co = try aio.xasync(asyncTest, .{&nstate}, stack);

    const stack2 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack2);
    var nco = try aio.xasync(asyncNotifier, .{&nstate}, stack2);

    try aio.xawait(co);
    try aio.xawait(nco);
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
    const notif = aio.AsyncNotification.init(env.loop, state.x);
    try notif.wait();
    state.notified = true;
}

fn asyncNotifier(state: *NotifierState) !void {
    try state.x.notify();
    try aio.sleep(env.loop, 10);
    try std.testing.expect(state.notified);
}

test "aio sleep env" {
    const t = try AioTest.init();
    defer t.deinit();

    const before = std.time.milliTimestamp();
    const after = try aio.run(null, sleep, .{10}, null);

    try std.testing.expect(after > (before + 7));
    try std.testing.expect(after < (before + 13));
}

fn sleepTaskEnv() !void {
    var sleep1 = try aio.xasync(sleep, .{10}, null);
    defer sleep1.deinit();
    var sleep2 = try aio.xasync(sleep, .{20}, null);
    defer sleep2.deinit();

    const after = try aio.xawait(sleep1);
    const after2 = try aio.xawait(sleep2);

    try std.testing.expect(after2 > (after + 7));
    try std.testing.expect(after2 < (after + 13));
}

test "aio concurrent sleep env" {
    const t = try AioTest.init();
    defer t.deinit();

    const before = std.time.milliTimestamp();
    try aio.run(null, sleepTaskEnv, .{}, null);
    const after = std.time.milliTimestamp();

    try std.testing.expect(after > (before + 17));
    try std.testing.expect(after < (before + 23));
}

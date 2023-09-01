const std = @import("std");
const libcoro = @import("libcoro");
const xev = @import("xev");
const aio = libcoro.xev.aio;

var env: struct { loop: *xev.Loop } = undefined;

const AioTest = struct {
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    tp: *xev.ThreadPool,

    fn init() !@This() {
        const allocator = std.testing.allocator;

        // Allocate on heap for pointer stability
        var loop = try allocator.create(xev.Loop);
        var tp = try allocator.create(xev.ThreadPool);
        tp.* = xev.ThreadPool.init(.{});
        loop.* = try xev.Loop.init(.{ .thread_pool = tp });

        // Thread-local env
        env = .{
            .loop = loop,
        };

        return .{
            .allocator = allocator,
            .loop = loop,
            .tp = tp,
        };
    }

    fn deinit(self: @This()) void {
        self.loop.deinit();
        self.tp.shutdown();
        self.tp.deinit();
        self.allocator.destroy(self.tp);
        self.allocator.destroy(self.loop);
    }
};

test "aio timers" {
    const t = try AioTest.init();
    defer t.deinit();

    const stack_size = 1024 * 32;

    // 2 parallel timer loops, one fast, one slow
    var tick_state = TickState{};
    const t1 = try libcoro.xcoroAlloc(tickLoop, .{ 100, &tick_state }, t.allocator, stack_size, .{});
    defer t1.deinit();
    try libcoro.xresume(t1);

    const t2 = try libcoro.xcoroAlloc(tickLoop, .{ 200, &tick_state }, t.allocator, stack_size, .{});
    defer t2.deinit();
    try libcoro.xresume(t2);

    try t.loop.run(.until_done);
}

test "aio tcp" {
    const t = try AioTest.init();
    defer t.deinit();

    const stack_size = 1024 * 32;

    var info: ServerInfo = .{};
    const sco = try libcoro.xcoroAlloc(tcpServer, .{&info}, t.allocator, stack_size, .{});
    defer sco.deinit();
    try libcoro.xresume(sco);

    const cco = try libcoro.xcoroAlloc(tcpClient, .{&info}, t.allocator, stack_size, .{});
    defer cco.deinit();
    try libcoro.xresume(cco);

    try t.loop.run(.until_done);
}

test "aio file" {
    const t = try AioTest.init();
    defer t.deinit();
    const stack_size = 1024 * 32;
    const co = try libcoro.xcoroAlloc(fileRW, .{}, t.allocator, stack_size, .{});
    defer co.deinit();
    try libcoro.xresume(co);
    try t.loop.run(.until_done);
}

test "aio udp" {
    const t = try AioTest.init();
    defer t.deinit();

    const stack_size = 1024 * 32;
    var udp_info: ServerInfo = .{};

    const sco = try libcoro.xcoroAlloc(udpServer, .{&udp_info}, t.allocator, stack_size, .{});
    defer sco.deinit();
    try libcoro.xresume(sco);

    const cco = try libcoro.xcoroAlloc(udpClient, .{&udp_info}, t.allocator, stack_size, .{});
    defer cco.deinit();
    try libcoro.xresume(cco);

    try t.loop.run(.until_done);
}

test "aio sleep" {
    const t = try AioTest.init();
    defer t.deinit();

    const stack_size = 1024 * 32;

    const co = try libcoro.xcoroAlloc(sleepTest, .{}, t.allocator, stack_size, .{});
    defer co.deinit();
    try libcoro.xresume(co);

    try t.loop.run(.until_done);
}

test "aio process" {
    const t = try AioTest.init();
    defer t.deinit();

    const stack_size = 1024 * 32;

    const co = try libcoro.xcoroAlloc(processTest, .{}, t.allocator, stack_size, .{});
    defer co.deinit();
    try libcoro.xresume(co);

    try t.loop.run(.until_done);
}

test "aio async" {
    const t = try AioTest.init();
    defer t.deinit();

    const stack_size = 1024 * 32;
    var nstate = NotifierState{ .x = try xev.Async.init() };

    const co = try libcoro.xcoroAlloc(asyncTest, .{&nstate}, t.allocator, stack_size, .{});
    defer co.deinit();
    try libcoro.xresume(co);

    const nco = try libcoro.xcoroAlloc(asyncNotifier, .{&nstate}, t.allocator, stack_size, .{});
    defer nco.deinit();
    try libcoro.xresume(nco);

    try t.loop.run(.until_done);
}

const TickState = struct {
    slow: usize = 0,
    fast: usize = 0,
};
fn tickLoop(tick: usize, state: *TickState) !void {
    const amfast = tick == 100;
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

fn sleepTest() !void {
    const before = std.time.milliTimestamp();
    try aio.sleep(env.loop, 1000);
    const after = std.time.milliTimestamp();
    try std.testing.expect(@fabs(@as(f64, @floatFromInt(after - before - 1000))) < 5);
}

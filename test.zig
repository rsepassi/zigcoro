const std = @import("std");
const libcoro = @import("libcoro");
const xev = @import("xev");
const aio = libcoro.xev.aio;

fn explicit_coro(x: *i32) void {
    x.* += 1;
    libcoro.xsuspend();
    x.* += 3;
}

test "explicit" {
    const allocator = std.heap.c_allocator;
    var x: i32 = 0;

    // Use xcoro or xcoroAlloc to create a coroutine
    var coro = try libcoro.xcoroAlloc(
        explicit_coro,
        .{&x},
        allocator,
        null,
        .{},
    );
    defer coro.deinit();

    // Coroutines start off paused.
    try std.testing.expectEqual(x, 0);

    // xresume suspends the current coroutine and resumes the passed coroutine.
    libcoro.xresume(coro);

    // When the coroutine suspends, it yields control back to the caller.
    try std.testing.expectEqual(coro.status(), .Suspended);
    try std.testing.expectEqual(x, 1);

    // xresume can be called until the coroutine is Done
    libcoro.xresume(coro);
    try std.testing.expectEqual(x, 4);
    try std.testing.expectEqual(coro.status(), .Done);
}

var idx: usize = 0;
var steps = [_]usize{0} ** 8;

fn set_idx(val: usize) void {
    steps[idx] = val;
    idx += 1;
}

fn test_fn(x: *usize) void {
    set_idx(2);
    x.* += 2;
    libcoro.xsuspend();
    set_idx(4);
    x.* += 7;
    libcoro.xsuspend();
    set_idx(6);
    x.* += 1;
}

test {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stack_size: usize = 1024 * 2;
    const stack = try allocator.alignedAlloc(u8, libcoro.stack_align, stack_size);
    defer allocator.free(stack);

    set_idx(0);
    var x: usize = 88;
    var test_coro = try libcoro.xcoro(test_fn, .{&x}, stack, .{});

    set_idx(1);
    try std.testing.expectEqual(test_coro.status(), .Suspended);
    libcoro.xresume(test_coro);
    try std.testing.expectEqual(x, 90);
    set_idx(3);
    try std.testing.expectEqual(test_coro.status(), .Suspended);
    libcoro.xresume(test_coro);
    try std.testing.expectEqual(test_coro.status(), .Suspended);
    try std.testing.expectEqual(x, 97);
    x += 3;
    set_idx(5);
    libcoro.xresume(test_coro);
    try std.testing.expectEqual(x, 101);
    set_idx(7);

    try std.testing.expectEqual(test_coro.status(), .Done);

    for (0..steps.len) |i| {
        try std.testing.expectEqual(i, steps[i]);
    }
}

// Panic on stack overflow
// Set this to 512
const stack_overflow_stack_size: ?usize = null;

fn stack_overflow() void {
    var x = [_]i128{0} ** 2;
    for (&x) |*el| {
        el.* += std.time.nanoTimestamp();
    }
    const res = libcoro.xsuspendSafe();
    res catch |e| {
        std.debug.assert(e == libcoro.Error.StackOverflow);
        @panic("Yup, it stack overflowed!");
    };
    var sum: i128 = 0;
    for (x) |el| {
        sum += el;
    }
}

test "stack overflow" {
    const allocator = std.heap.c_allocator;
    var coro = try libcoro.xcoroAlloc(stack_overflow, .{}, allocator, stack_overflow_stack_size, .{});
    defer coro.deinit();
    libcoro.xresume(coro);
    libcoro.xresume(coro);
}

fn generator(end: usize) void {
    for (0..end) |i| {
        libcoro.xyield(i);
    }
}

test "generator" {
    const allocator = std.heap.c_allocator;
    const end: usize = 10;
    var gen = try libcoro.xcoroAlloc(
        generator,
        .{end},
        allocator,
        null,
        .{ .YieldT = usize },
    );
    defer gen.deinit();
    var i: usize = 0;
    while (libcoro.xnext(gen)) |val| : (i += 1) {
        try std.testing.expectEqual(i, val);
    }
    try std.testing.expectEqual(i, 10);
}

fn inner() usize {
    libcoro.xsuspend();
    return 10;
}

fn nested() !usize {
    const allocator = std.heap.c_allocator;
    var coro = try libcoro.xcoroAlloc(inner, .{}, allocator, null, .{});
    defer coro.deinit();
    const x = libcoro.xawait(coro);
    return x + 7;
}

test "nested" {
    const allocator = std.heap.c_allocator;
    var coro = try libcoro.xcoroAlloc(nested, .{}, allocator, null, .{});
    defer coro.deinit();
    const val = try libcoro.xawait(coro);
    try std.testing.expectEqual(val, 17);
}

fn yieldAndReturn() usize {
    const x: i32 = 7;
    libcoro.xyield(x);
    return 10;
}

test "yield and return" {
    const allocator = std.heap.c_allocator;
    var coro = try libcoro.xcoroAlloc(yieldAndReturn, .{}, allocator, null, .{ .YieldT = i32 });
    defer coro.deinit();

    var i: usize = 0;
    while (libcoro.xnext(coro)) |val| : (i += 1) {
        if (@TypeOf(val) != i32) @compileError("bad type");
        try std.testing.expectEqual(val, 7);
    }
    try std.testing.expectEqual(i, 1);

    const val = libcoro.xawait(coro);
    if (@TypeOf(val) != usize) @compileError("bad type");
    try std.testing.expectEqual(val, 10);
}

fn anerror() !usize {
    if (true) return error.SomeError;
    return 10;
}

test "await error" {
    const allocator = std.heap.c_allocator;
    var coro = try libcoro.xcoroAlloc(anerror, .{}, allocator, null, .{});
    defer coro.deinit();
    const val = libcoro.xawait(coro);
    try std.testing.expectEqual(val, error.SomeError);
    try std.testing.expectEqual(coro.status(), .Error);
}

fn yielderror() !void {
    for (0..2) |_| {
        const x: usize = 7;
        libcoro.xyield(x);
    }
    if (true) return error.SomeError;
}

test "yield error" {
    const allocator = std.heap.c_allocator;
    var coro = try libcoro.xcoroAlloc(yielderror, .{}, allocator, null, .{ .YieldT = usize });
    defer coro.deinit();
    _ = try libcoro.xnext(coro);
    _ = try libcoro.xnext(coro);
    const err = libcoro.xnext(coro);
    try std.testing.expectEqual(err, error.SomeError);
    try std.testing.expectEqual(coro.status(), .Error);
}

fn resumeerror() !void {
    libcoro.xsuspend();
    if (true) return error.SomeError;
}

test "resume error" {
    const allocator = std.heap.c_allocator;
    var coro = try libcoro.xcoroAlloc(resumeerror, .{}, allocator, null, .{ .YieldT = usize });
    defer coro.deinit();
    _ = try libcoro.xresume(coro);
    const err = libcoro.xresume(coro);
    try std.testing.expectEqual(err, error.SomeError);
    try std.testing.expectEqual(coro.status(), .Error);
}

const AioTest = struct {
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    tp: *xev.ThreadPool,

    fn init() !@This() {
        const allocator = std.testing.allocator;
        var loop = try allocator.create(xev.Loop);
        var tp = try allocator.create(xev.ThreadPool);
        tp.* = xev.ThreadPool.init(.{});
        loop.* = try xev.Loop.init(.{ .thread_pool = tp });

        // Global env
        aio.env = .{
            .loop = loop,
            .allocator = allocator,
        };

        return .{
            .allocator = std.testing.allocator,
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
    const stack_size = 1024 * 16;
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
        try aio.sleep(tick);
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

    const server = aio.TCP.init(xserver);
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
    const client = aio.TCP.init(xclient);
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
    const file = aio.File.init(xfile);
    var write_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    const write_len = try file.write(.{ .slice = &write_buf });
    try std.testing.expectEqual(write_len, write_buf.len);
    try f.sync();
    const f2 = try std.fs.cwd().openFile(path, .{});
    defer f2.close();
    const xfile2 = try xev.File.init(f2);
    const file2 = aio.File.init(xfile2);
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

    const p = aio.Process.init(xp);
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

    const server = aio.UDP.init(xserver);

    var recv_buf: [128]u8 = undefined;
    const recv_len = try server.read(.{ .slice = &recv_buf });
    var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    try std.testing.expectEqual(recv_len, send_buf.len);
    try std.testing.expect(std.mem.eql(u8, &send_buf, recv_buf[0..recv_len]));
    try server.close();
}

fn udpClient(info: *ServerInfo) !void {
    const xclient = try xev.UDP.init(info.addr);
    const client = aio.UDP.init(xclient);
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
    const notif = aio.Async.init(state.x);
    try notif.wait();
    state.notified = true;
}

fn asyncNotifier(state: *NotifierState) !void {
    try state.x.notify();
    try aio.sleep(100);
    try std.testing.expect(state.notified);
}

fn sleepTest() !void {
    const before = std.time.milliTimestamp();
    try aio.sleep(1000);
    const after = std.time.milliTimestamp();
    try std.testing.expect(@fabs(@as(f64, @floatFromInt(after - before - 1000))) < 5);
}

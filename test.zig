const std = @import("std");
const libcoro = @import("libcoro");

fn simple_coro(x: *i32) void {
    x.* += 1;

    // Use xsuspend to switch back to the calling coroutine (which may be the main
    // thread)
    libcoro.xsuspend();

    x.* += 3;
}

test "simple" {
    const allocator = std.heap.c_allocator;

    // Create a coroutine.
    // Each coroutine has a dedicated stack. You can specify an allocator and
    // stack size (xasyncAlloc) or provide a stack directly (xasync).
    var x: i32 = 0;
    var coro = try libcoro.xasyncAlloc(simple_coro, .{&x}, allocator, null, .{});
    defer coro.deinit();

    // Coroutines start off paused.
    try std.testing.expectEqual(x, 0);

    // xresume switches to the coroutine.
    libcoro.xresume(coro);

    // A coroutine can xsuspend, yielding control back to its caller.
    try std.testing.expectEqual(x, 1);

    libcoro.xresume(coro);
    try std.testing.expectEqual(x, 4);

    // Finished coroutines are marked done
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
    var test_coro = try libcoro.xasync(test_fn, .{&x}, stack, .{});

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
    var coro = try libcoro.xasyncAlloc(stack_overflow, .{}, allocator, stack_overflow_stack_size, .{});
    defer coro.deinit();
    libcoro.xresume(coro);
    libcoro.xresume(coro);
}

fn generator() void {
    for (0..10) |i| {
        libcoro.xyield(i);
    }
}

test "generator" {
    const allocator = std.heap.c_allocator;
    var coro = try libcoro.xasyncAlloc(generator, .{}, allocator, null, .{ .YieldT = usize });
    defer coro.deinit();
    var i: usize = 0;
    while (libcoro.xnext(coro)) |val| : (i += 1) {
        try std.testing.expectEqual(i, val);
    }
    try std.testing.expectEqual(i, 10);
}

fn inner() usize {
    libcoro.xsuspend();
    return 10;
}

fn nested() usize {
    const allocator = std.heap.c_allocator;
    var coro = libcoro.xasyncAlloc(inner, .{}, allocator, null, .{}) catch unreachable;
    defer coro.deinit();
    const x = libcoro.xawait(coro);
    return x + 7;
}

test "nested" {
    const allocator = std.heap.c_allocator;
    var coro = try libcoro.xasyncAlloc(nested, .{}, allocator, null, .{});
    defer coro.deinit();
    const val = libcoro.xawait(coro);
    try std.testing.expectEqual(val, 17);
}

fn yieldAndReturn() usize {
    const x: i32 = 7;
    libcoro.xyield(x);
    return 10;
}

test "yield and return" {
    const allocator = std.heap.c_allocator;
    var coro = try libcoro.xasyncAlloc(yieldAndReturn, .{}, allocator, null, .{ .YieldT = i32 });
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
    var coro = try libcoro.xasyncAlloc(anerror, .{}, allocator, null, .{});
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
    var coro = try libcoro.xasyncAlloc(yielderror, .{}, allocator, null, .{ .YieldT = usize });
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
    var coro = try libcoro.xasyncAlloc(resumeerror, .{}, allocator, null, .{ .YieldT = usize });
    defer coro.deinit();
    _ = try libcoro.xresume(coro);
    const err = libcoro.xresume(coro);
    try std.testing.expectEqual(err, error.SomeError);
    try std.testing.expectEqual(coro.status(), .Error);
}

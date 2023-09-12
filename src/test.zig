const std = @import("std");
const libcoro = @import("libcoro");

var idx: usize = 0;
var steps = [_]usize{0} ** 8;

fn set_idx(val: usize) void {
    steps[idx] = val;
    idx += 1;
}

fn test_fn() void {
    std.debug.assert(libcoro.remainingStackSize() > 2048);
    set_idx(2);
    libcoro.xsuspend();
    set_idx(4);
    libcoro.xsuspend();
    set_idx(6);
}

test "basic suspend and resume" {
    const allocator = std.testing.allocator;

    const stack_size: usize = 1024 * 4;
    const stack = try libcoro.stackAlloc(allocator, stack_size);
    defer allocator.free(stack);

    set_idx(0);
    var test_coro = try libcoro.Coro.init(test_fn, stack, null);

    set_idx(1);
    try std.testing.expectEqual(test_coro.status, .Start);
    libcoro.xresume(test_coro);
    set_idx(3);
    try std.testing.expectEqual(test_coro.status, .Suspended);
    libcoro.xresume(test_coro);
    try std.testing.expectEqual(test_coro.status, .Suspended);
    set_idx(5);
    libcoro.xresume(test_coro);
    set_idx(7);

    try std.testing.expectEqual(test_coro.status, .Done);

    for (0..steps.len) |i| {
        try std.testing.expectEqual(i, steps[i]);
    }
}

const Storage = struct {
    x: *usize,
};
fn coroInner(x: *usize) void {
    x.* += 1;
    libcoro.xsuspend();
    x.* += 3;
}
fn coroWrap() void {
    const storage = libcoro.xframe().getStorage(Storage);
    const x = storage.x;
    coroInner(x);
}

test "with values" {
    var x: usize = 0;
    var storage = Storage{ .x = &x };

    const allocator = std.testing.allocator;
    const stack = try libcoro.stackAlloc(allocator, null);
    defer allocator.free(stack);
    var coro = try libcoro.Coro.init(coroWrap, stack, @ptrCast(&storage));

    try std.testing.expectEqual(storage.x.*, 0);
    libcoro.xresume(coro);
    try std.testing.expectEqual(storage.x.*, 1);
    libcoro.xresume(coro);
    try std.testing.expectEqual(storage.x.*, 4);
}

fn coroFnImpl(x: *usize) usize {
    x.* += 1;
    libcoro.xsuspend();
    x.* += 3;
    libcoro.xsuspend();
    return x.* + 10;
}

test "with CoroT" {
    const allocator = std.testing.allocator;
    const stack = try libcoro.stackAlloc(allocator, null);
    defer allocator.free(stack);

    var x: usize = 0;

    const CoroFn = libcoro.CoroT(coroFnImpl, .{});
    var coro = try CoroFn.init(.{&x}, stack);

    try std.testing.expectEqual(x, 0);
    libcoro.xresume(coro);
    try std.testing.expectEqual(x, 1);
    libcoro.xresume(coro);
    try std.testing.expectEqual(x, 4);
    libcoro.xresume(coro);
    try std.testing.expectEqual(x, 4);
    try std.testing.expectEqual(coro.status, .Done);
    try std.testing.expectEqual(CoroFn.xreturned(coro), 14);
    comptime try std.testing.expectEqual(CoroFn.Signature.ReturnT, usize);
}

test "with FrameT and xasync xawait" {
    const allocator = std.testing.allocator;
    const stack = try libcoro.stackAlloc(allocator, null);
    defer allocator.free(stack);

    var x: usize = 0;

    var frame = try libcoro.xasync(coroFnImpl, .{&x}, stack);

    try std.testing.expectEqual(x, 1);
    libcoro.xresume(frame);
    try std.testing.expectEqual(x, 4);
    libcoro.xresume(frame);
    try std.testing.expectEqual(x, 4);
    try std.testing.expectEqual(frame.status(), .Done);

    const out = libcoro.xawait(frame);
    try std.testing.expectEqual(out, 14);
}

fn coroError(x: *usize) !usize {
    x.* += 1;
    libcoro.xsuspend();
    if (true) return error.SomethingBad;
    return x.* + 10;
}

test "coro frame error" {
    const allocator = std.testing.allocator;
    const stack = try libcoro.stackAlloc(allocator, null);
    defer allocator.free(stack);

    var x: usize = 0;
    const Fn = libcoro.CoroT(coroError, .{});
    var coro = try Fn.init(.{&x}, stack);

    try std.testing.expectEqual(x, 0);
    libcoro.xresume(coro);
    try std.testing.expectEqual(x, 1);
    libcoro.xresume(coro);
    try std.testing.expectEqual(x, 1);
    try std.testing.expectEqual(coro.status, .Done);
    try std.testing.expectEqual(Fn.xreturned(coro), error.SomethingBad);
}

fn iterFn(start: usize) bool {
    var val = start;
    var incr: usize = 0;
    while (val < 10) : (val += incr) {
        incr = Iter.xyield(val);
    }
    return val == 28;
}
const Iter = libcoro.CoroT(iterFn, .{ .YieldT = usize, .InjectT = usize });

test "iterator" {
    const allocator = std.testing.allocator;
    const stack = try libcoro.stackAlloc(allocator, null);
    defer allocator.free(stack);

    var x: usize = 1;
    var coro = try Iter.init(.{x}, stack);
    var yielded: usize = undefined;
    yielded = Iter.xnextStart(coro); // first resume takes no value
    try std.testing.expectEqual(yielded, 1);
    yielded = Iter.xnext(coro, 3);
    try std.testing.expectEqual(yielded, 4);
    yielded = Iter.xnext(coro, 2);
    try std.testing.expectEqual(yielded, 6);
    const retval = Iter.xnextEnd(coro, 22);
    try std.testing.expect(retval);

    try std.testing.expectEqual(coro.status, .Done);
}

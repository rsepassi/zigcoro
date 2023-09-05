const std = @import("std");
const libcoro = @import("libcoro");

var idx: usize = 0;
var steps = [_]usize{0} ** 8;

fn set_idx(val: usize) void {
    steps[idx] = val;
    idx += 1;
}

fn test_fn() void {
    std.debug.assert(libcoro.remainingStackSize() > 1024);
    set_idx(2);
    libcoro.xsuspend();
    set_idx(4);
    libcoro.xsuspend();
    set_idx(6);
}

test "basic suspend and resume" {
    const allocator = std.testing.allocator;

    const stack_size: usize = 1024 * 2;
    const stack = try libcoro.stackAlloc(allocator, stack_size);
    defer allocator.free(stack);

    set_idx(0);
    var test_coro = try libcoro.Coro.init(test_fn, stack, null);

    set_idx(1);
    try std.testing.expectEqual(test_coro.status, .Suspended);
    libcoro.xresume(&test_coro);
    set_idx(3);
    try std.testing.expectEqual(test_coro.status, .Suspended);
    libcoro.xresume(&test_coro);
    try std.testing.expectEqual(test_coro.status, .Suspended);
    set_idx(5);
    libcoro.xresume(&test_coro);
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
    const storage = libcoro.xcurrentStorage(Storage);
    const x = storage.x;
    coroInner(x);
}

test "with values" {
    var x: usize = 0;
    const storage = Storage{ .x = &x };

    const allocator = std.testing.allocator;
    const stack = try libcoro.stackAlloc(allocator, null);
    defer allocator.free(stack);
    var coro = try libcoro.Coro.init(coroWrap, stack, @ptrCast(&storage));

    try std.testing.expectEqual(storage.x.*, 0);
    libcoro.xresume(&coro);
    try std.testing.expectEqual(storage.x.*, 1);
    libcoro.xresume(&coro);
    try std.testing.expectEqual(storage.x.*, 4);
}

fn coroFn(x: *usize) usize {
    x.* += 1;
    libcoro.xsuspend();
    x.* += 3;
    libcoro.xsuspend();
    return x.* + 10;
}

test "with coro frame" {
    const allocator = std.testing.allocator;
    const stack = try libcoro.stackAlloc(allocator, null);
    defer allocator.free(stack);

    var x: usize = 0;
    var storage = libcoro.CoroFrame(@TypeOf(coroFn)).init(coroFn, .{&x});
    var coro = try storage.coro(stack);

    try std.testing.expectEqual(x, 0);
    libcoro.xresume(&coro);
    try std.testing.expectEqual(x, 1);
    libcoro.xresume(&coro);
    try std.testing.expectEqual(x, 4);
    libcoro.xresume(&coro);
    try std.testing.expectEqual(x, 4);
    try std.testing.expectEqual(coro.status, .Done);
    try std.testing.expectEqual(storage.retval, 14);
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
    var storage = libcoro.CoroFrame(@TypeOf(coroError)).init(coroError, .{&x});
    var coro = try storage.coro(stack);

    try std.testing.expectEqual(x, 0);
    libcoro.xresume(&coro);
    try std.testing.expectEqual(x, 1);
    libcoro.xresume(&coro);
    try std.testing.expectEqual(x, 1);
    try std.testing.expectEqual(coro.status, .Done);
    try std.testing.expectEqual(storage.retval, error.SomethingBad);
}

test "stack coro" {
    const allocator = std.testing.allocator;
    const stack = try libcoro.stackAlloc(allocator, null);
    defer allocator.free(stack);

    var x: usize = 0;
    var coro = try libcoro.StackCoro.init(coroError, .{&x}, stack);

    try std.testing.expectEqual(x, 0);
    libcoro.xresume(&coro);
    try std.testing.expectEqual(x, 1);
    libcoro.xresume(&coro);
    try std.testing.expectEqual(x, 1);
    try std.testing.expectEqual(coro.status, .Done);

    const retval = libcoro.StackCoro.storage(coroError, coro).retval;
    try std.testing.expectEqual(retval, error.SomethingBad);
}

// TODO:
// next/yield (resume/suspend with values)
// args/return (first resume with value, last yield with value)

// fn explicit_coro(x: *i32) void {
//     x.* += 1;
//     libcoro.xsuspend();
//     x.* += 3;
// }
//
// test "explicit" {
//     const allocator = std.heap.c_allocator;
//     var x: i32 = 0;
//
//     // Use xcoro or xcoroAlloc to create a coroutine
//     var coro = try libcoro.xcoroAlloc(
//         explicit_coro,
//         .{&x},
//         allocator,
//         null,
//         .{},
//     );
//     defer coro.deinit();
//
//     // Coroutines start off paused.
//     try std.testing.expectEqual(x, 0);
//
//     // xresume suspends the current coroutine and resumes the passed coroutine.
//     libcoro.xresume(coro);
//
//     // When the coroutine suspends, it yields control back to the caller.
//     try std.testing.expectEqual(coro.status(), .Suspended);
//     try std.testing.expectEqual(x, 1);
//
//     // xresume can be called until the coroutine is Done
//     libcoro.xresume(coro);
//     try std.testing.expectEqual(x, 4);
//     try std.testing.expectEqual(coro.status(), .Done);
// }
//
// var idx: usize = 0;
// var steps = [_]usize{0} ** 8;
//
// fn set_idx(val: usize) void {
//     steps[idx] = val;
//     idx += 1;
// }
//
// fn test_fn(x: *usize) void {
//     set_idx(2);
//     x.* += 2;
//     libcoro.xsuspend();
//     set_idx(4);
//     x.* += 7;
//     libcoro.xsuspend();
//     set_idx(6);
//     x.* += 1;
// }
//
// test {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     defer _ = gpa.deinit();
//     const allocator = gpa.allocator();
//
//     const stack_size: usize = 1024 * 2;
//     const stack = try allocator.alignedAlloc(u8, libcoro.stack_align, stack_size);
//     defer allocator.free(stack);
//
//     set_idx(0);
//     var x: usize = 88;
//     var test_coro = try libcoro.xcoro(test_fn, .{&x}, stack, .{});
//
//     set_idx(1);
//     try std.testing.expectEqual(test_coro.status(), .Suspended);
//     libcoro.xresume(test_coro);
//     try std.testing.expectEqual(x, 90);
//     set_idx(3);
//     try std.testing.expectEqual(test_coro.status(), .Suspended);
//     libcoro.xresume(test_coro);
//     try std.testing.expectEqual(test_coro.status(), .Suspended);
//     try std.testing.expectEqual(x, 97);
//     x += 3;
//     set_idx(5);
//     libcoro.xresume(test_coro);
//     try std.testing.expectEqual(x, 101);
//     set_idx(7);
//
//     try std.testing.expectEqual(test_coro.status(), .Done);
//
//     for (0..steps.len) |i| {
//         try std.testing.expectEqual(i, steps[i]);
//     }
// }
//
// // Panic on stack overflow
// // Set this to 512
// const stack_overflow_stack_size: ?usize = null;
//
// fn stack_overflow() void {
//     var x = [_]i128{0} ** 2;
//     for (&x) |*el| {
//         el.* += std.time.nanoTimestamp();
//     }
//     const res = libcoro.xsuspendSafe();
//     res catch |e| {
//         std.debug.assert(e == libcoro.Error.StackOverflow);
//         @panic("Yup, it stack overflowed!");
//     };
//     var sum: i128 = 0;
//     for (x) |el| {
//         sum += el;
//     }
// }
//
// test "stack overflow" {
//     const allocator = std.heap.c_allocator;
//     var coro = try libcoro.xcoroAlloc(stack_overflow, .{}, allocator, stack_overflow_stack_size, .{});
//     defer coro.deinit();
//     libcoro.xresume(coro);
//     libcoro.xresume(coro);
// }
//
// fn generator(end: usize) void {
//     for (0..end) |i| {
//         libcoro.xyield(i);
//     }
// }
//
// test "generator" {
//     const allocator = std.heap.c_allocator;
//     const end: usize = 10;
//     var gen = try libcoro.xcoroAlloc(
//         generator,
//         .{end},
//         allocator,
//         null,
//         .{ .YieldT = usize },
//     );
//     defer gen.deinit();
//     var i: usize = 0;
//     while (libcoro.xnext(gen)) |val| : (i += 1) {
//         try std.testing.expectEqual(i, val);
//     }
//     try std.testing.expectEqual(i, 10);
// }
//
// fn inner() usize {
//     return 10;
// }
//
// fn nested() !usize {
//     const allocator = std.heap.c_allocator;
//     var coro = try libcoro.xcoroAlloc(inner, .{}, allocator, null, .{});
//     defer coro.deinit();
//     const x = libcoro.xawait(coro);
//     return x + 7;
// }
//
// test "nested" {
//     const allocator = std.heap.c_allocator;
//     var coro = try libcoro.xcoroAlloc(nested, .{}, allocator, null, .{});
//     defer coro.deinit();
//     const val = try libcoro.xawait(coro);
//     try std.testing.expectEqual(val, 17);
// }
//
// fn yieldAndReturn() usize {
//     const x: i32 = 7;
//     libcoro.xyield(x);
//     return 10;
// }
//
// test "yield and return" {
//     const allocator = std.heap.c_allocator;
//     var coro = try libcoro.xcoroAlloc(yieldAndReturn, .{}, allocator, null, .{ .YieldT = i32 });
//     defer coro.deinit();
//
//     var i: usize = 0;
//     while (libcoro.xnext(coro)) |val| : (i += 1) {
//         if (@TypeOf(val) != i32) @compileError("bad type");
//         try std.testing.expectEqual(val, 7);
//     }
//     try std.testing.expectEqual(i, 1);
//
//     const val = libcoro.xawait(coro);
//     if (@TypeOf(val) != usize) @compileError("bad type");
//     try std.testing.expectEqual(val, 10);
// }
//
// fn anerror() !usize {
//     if (true) return error.SomeError;
//     return 10;
// }
//
// test "await error" {
//     const allocator = std.heap.c_allocator;
//     var coro = try libcoro.xcoroAlloc(anerror, .{}, allocator, null, .{});
//     defer coro.deinit();
//     const val = libcoro.xawait(coro);
//     try std.testing.expectEqual(val, error.SomeError);
//     try std.testing.expectEqual(coro.status(), .Error);
// }
//
// fn yielderror() !void {
//     for (0..2) |_| {
//         const x: usize = 7;
//         libcoro.xyield(x);
//     }
//     if (true) return error.SomeError;
// }
//
// test "yield error" {
//     const allocator = std.heap.c_allocator;
//     var coro = try libcoro.xcoroAlloc(yielderror, .{}, allocator, null, .{ .YieldT = usize });
//     defer coro.deinit();
//     _ = try libcoro.xnext(coro);
//     _ = try libcoro.xnext(coro);
//     const err = libcoro.xnext(coro);
//     try std.testing.expectEqual(err, error.SomeError);
//     try std.testing.expectEqual(coro.status(), .Error);
// }
//
// fn resumeerror() !void {
//     libcoro.xsuspend();
//     if (true) return error.SomeError;
// }
//
// test "resume error" {
//     const allocator = std.heap.c_allocator;
//     var coro = try libcoro.xcoroAlloc(resumeerror, .{}, allocator, null, .{ .YieldT = usize });
//     defer coro.deinit();
//     _ = try libcoro.xresume(coro);
//     const err = libcoro.xresume(coro);
//     try std.testing.expectEqual(err, error.SomeError);
//     try std.testing.expectEqual(coro.status(), .Error);
// }

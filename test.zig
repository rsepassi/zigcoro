const std = @import("std");
const libcoro = @import("libcoro");

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

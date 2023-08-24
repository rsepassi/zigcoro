const std = @import("std");
const libcoro = @import("libcoro");

var idx: usize = 0;
var steps = [_]usize{0} ** 8;

fn set_idx(val: usize) void {
    steps[idx] = val;
    idx += 1;
}

fn test_fn(x: *usize) void {
    set_idx(2);
    x.* += 2;
    libcoro.yield();
    set_idx(4);
    x.* += 7;
    libcoro.yield();
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
    var test_coro = libcoro.Coro.init(test_fn, .{&x}, stack);

    set_idx(1);
    try std.testing.expect(!test_coro.done);
    test_coro.xresume();
    try std.testing.expectEqual(x, 90);
    set_idx(3);
    try std.testing.expect(!test_coro.done);
    test_coro.xresume();
    try std.testing.expect(!test_coro.done);
    try std.testing.expectEqual(x, 97);
    x += 3;
    set_idx(5);
    test_coro.xresume();
    try std.testing.expectEqual(x, 101);
    set_idx(7);

    try std.testing.expect(test_coro.done);

    for (0..steps.len) |i| {
        try std.testing.expectEqual(i, steps[i]);
    }
}

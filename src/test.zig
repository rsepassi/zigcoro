const std = @import("std");
const libcoro = @import("libcoro");

fn coroFnImpl(x: *usize) usize {
    x.* += 1;
    libcoro.xsuspend();
    x.* += 3;
    libcoro.xsuspend();
    return x.* + 10;
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

test "xawait error" {
    const allocator = std.testing.allocator;
    const stack = try libcoro.stackAlloc(allocator, null);
    defer allocator.free(stack);

    var x: usize = 0;
    const frame = try libcoro.xasync(coroError, .{&x}, stack);
    try std.testing.expectEqual(x, 1);
    libcoro.xresume(frame);
    try std.testing.expectEqual(x, 1);
    try std.testing.expectEqual(frame.status(), .Done);
    const out = libcoro.xawait(frame);
    try std.testing.expectError(error.SomethingBad, out);
}

fn withSuspendBlock() void {
    const Data = struct {
        frame: libcoro.Frame,
        fn block_fn(data: *@This()) void {
            std.debug.assert(data.frame.status == .Suspended);
            std.debug.assert(data.frame != libcoro.xframe());
            libcoro.xresume(data.frame);
        }
    };
    var data = Data{ .frame = libcoro.xframe() };
    libcoro.xsuspendBlock(Data.block_fn, .{&data});
}

test "suspend block" {
    const allocator = std.testing.allocator;
    const stack = try libcoro.stackAlloc(allocator, null);
    defer allocator.free(stack);

    const frame = try libcoro.xasync(withSuspendBlock, .{}, stack);
    try std.testing.expectEqual(frame.status(), .Done);
}

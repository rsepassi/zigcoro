const std = @import("std");
const libcoro = @import("libcoro");

var num_bounces: usize = 0;

fn test_fn() void {
    for (0..num_bounces) |_| {
        libcoro.xsuspend();
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stack_size: usize = 1024 * 2;
    const stack = try allocator.alignedAlloc(u8, libcoro.stack_align, stack_size);
    defer allocator.free(stack);

    // warmup
    num_bounces = 100_000;
    {
        var test_coro = libcoro.Coro.init(test_fn, .{}, stack);
        for (0..num_bounces) |_| {
            libcoro.xresume(test_coro);
        }
        libcoro.xresume(test_coro);
    }

    num_bounces = 20_000_000;
    {
        var test_coro = libcoro.Coro.init(test_fn, .{}, stack);

        const start = std.time.nanoTimestamp();
        for (0..num_bounces) |_| {
            libcoro.xresume(test_coro);
        }
        const end = std.time.nanoTimestamp();
        const duration = end - start;
        const ns_per_bounce = @divFloor(duration, num_bounces * 2);
        std.debug.print("ns/ctxswitch: {d}\n", .{ns_per_bounce});

        libcoro.xresume(test_coro);
    }
}

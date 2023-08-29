const std = @import("std");
const libcoro = @import("libcoro");

var num_bounces: usize = 0;

fn testFn() void {
    for (0..num_bounces) |_| {
        libcoro.xsuspend();
    }
}

fn suspendRepeat() void {
    while (true) libcoro.xsuspend();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // context switch benchmark
    {
        const stack_size: usize = 1024 * 2;
        const stack = try allocator.alignedAlloc(u8, libcoro.stack_align, stack_size);
        defer allocator.free(stack);

        // warmup
        num_bounces = 100_000;
        {
            var test_coro = try libcoro.xasync(testFn, .{}, stack, .{});
            for (0..num_bounces) |_| {
                libcoro.xresume(test_coro);
            }
            libcoro.xresume(test_coro);
        }

        num_bounces = 20_000_000;
        {
            var test_coro = try libcoro.xasync(testFn, .{}, stack, .{});

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

    // number of coroutines benchmark
    if (false) {
        const num_coros = 100_000_000;
        var coros = try allocator.alloc(*libcoro.Coro, num_coros);
        defer allocator.free(coros);

        var buf = try allocator.alloc(u8, num_coros * 1024 * 4);
        var fba = std.heap.FixedBufferAllocator.init(buf);
        const alloc2 = fba.allocator();

        for (0..num_coros) |i| {
            const coro = try libcoro.xasyncAlloc(suspendRepeat, .{}, alloc2, null, .{});
            coros[i] = coro.coro;
        }

        for (0..20) |i| {
            const start = std.time.nanoTimestamp();
            for (coros) |coro| {
                libcoro.xresume(coro);
            }
            const end = std.time.nanoTimestamp();
            const duration = end - start;
            const ns_per_bounce = @divFloor(duration, num_coros * 2);
            std.debug.print("ns/ctxswitch: {d}\n", .{ns_per_bounce});
            if (i > 5 and ns_per_bounce > 100) {
                @panic("swap memory being used");
            }
        }
        std.debug.print("efficiently ran {d} coroutines\n", .{num_coros});
    }
}

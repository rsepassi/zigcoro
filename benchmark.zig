const std = @import("std");
const libcoro = @import("libcoro");

var num_bounces: usize = 0;
fn testFn() void {
    libcoro.xsuspend();
    for (0..num_bounces) |_| {
        libcoro.xsuspend();
    }
}

fn suspendRepeat() void {
    libcoro.xsuspend();
    while (true) libcoro.xsuspend();
}

fn contextSwitchBm() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // context switch benchmark
    {
        const stack_size: usize = 1024 * 4;
        const stack = try allocator.alignedAlloc(u8, libcoro.stack_alignment, stack_size);
        defer allocator.free(stack);

        // warmup
        num_bounces = 100_000;
        {
            const test_coro = try libcoro.xasync(testFn, .{}, stack);
            for (0..num_bounces) |_| {
                libcoro.xresume(test_coro);
            }
            libcoro.xresume(test_coro);
        }

        num_bounces = 20_000_000;
        {
            const test_coro = try libcoro.xasync(testFn, .{}, stack);

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
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  benchmark --context_switch
        \\  benchmark --ncoros 100000
        \\
    , .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const Benchmark = enum {
        context_switch,
        ncoros,
    };
    var benchmark = Benchmark.context_switch;
    var ncoros: usize = 100_000;

    fargs: for (try std.process.argsAlloc(allocator), 0..) |arg, i| {
        if (i == 0) continue;
        if (std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "--help"))
        {
            printUsage();
            return;
        }

        inline for (@typeInfo(Benchmark).Enum.fields) |f| {
            if (std.mem.eql(u8, arg[2..], f.name)) {
                benchmark = @enumFromInt(f.value);
                continue :fargs;
            }
        }

        if (!std.mem.eql(u8, arg[0..1], "-")) {
            ncoros = try std.fmt.parseInt(usize, arg, 10);
            continue;
        }

        printUsage();
        return;
    }
    std.debug.print("Running benchmark {s}\n", .{@tagName(benchmark)});

    try switch (benchmark) {
        .context_switch => contextSwitchBm(),
        .ncoros => ncorosBm(ncoros),
    };
}

fn ncorosBm(num_coros: usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const rounds: usize = 1000;
    std.debug.print("Running {d} coroutines for {d} rounds\n", .{ num_coros, rounds });

    // number of coroutines benchmark
    var coros = try allocator.alloc(libcoro.Frame, num_coros);
    defer allocator.free(coros);

    const buf = try allocator.alloc(u8, num_coros * 1024 * 4);
    var fba = std.heap.FixedBufferAllocator.init(buf);
    const alloc2 = fba.allocator();

    for (0..num_coros) |i| {
        const stack = try libcoro.stackAlloc(alloc2, null);
        const coro = try libcoro.xasync(suspendRepeat, .{}, stack);
        coros[i] = coro.frame();
    }

    const batching: usize = if (num_coros >= 10_000_000) 1 else 10;

    var start = std.time.nanoTimestamp();
    for (0..rounds) |i| {
        for (coros) |coro| {
            libcoro.xresume(coro);
        }
        if ((i + 1) % batching == 0) {
            const end = std.time.nanoTimestamp();
            const duration = end - start;
            const ns_per_bounce = @divFloor(duration, batching * num_coros * 2);
            if (i > (3 * batching)) { // warmup
                std.debug.print("ns/ctxswitch: {d}\n", .{ns_per_bounce});
            }
            start = std.time.nanoTimestamp();
        }
    }
    std.debug.print("Ran {d} coroutines for {d} rounds\n", .{ num_coros, rounds });
}

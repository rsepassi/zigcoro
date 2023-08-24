const std = @import("std");
const libcoro = @import("libcoro");
const Coro = libcoro.Coro;

const num_bounces = 2;

fn test_coro(
    from: *Coro,
    self: *Coro,
) void {
    _ = self;

    var i: usize = 0;
    while (i < num_bounces) : (i += 1) {
        from.xresume();
    }
}

test {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stack_size: usize = 1024 * 2;
    const stack = try allocator.alignedAlloc(u8, libcoro.stack_align, stack_size);
    defer allocator.free(stack);

    var test_fiber = Coro.init(&test_coro, stack);

    var i: usize = 0;
    while (i < num_bounces) : (i += 1) {
        test_fiber.xresume();
    }
}

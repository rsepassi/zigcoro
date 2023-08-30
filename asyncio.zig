const std = @import("std");
const xev = @import("xev");
const libcoro = @import("libcoro");

const Env = struct {
    loop: *xev.Loop,
};
var env: Env = undefined;

fn sleepFor(ms: u64) void {
    std.debug.print("sleepFor\n", .{});
    const w = try xev.Timer.init();
    defer w.deinit();
    var c: xev.Completion = .{};
    w.run(env.loop, &c, ms, libcoro.Coro, libcoro.xcurrent(), &resumeCoroCallback);
    libcoro.xsuspend();
    std.debug.print("sleepFor done\n", .{});
}

fn resumeCoroCallback(
    userdata: ?*libcoro.Coro,
    loop: *xev.Loop,
    c: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    std.debug.print("resumeCoroCallback\n", .{});
    _ = loop;
    _ = result catch unreachable;
    _ = c;

    const coro: *libcoro.Coro = @ptrCast(@alignCast(userdata.?));
    libcoro.xresume(coro);

    std.debug.print("resumeCoroCallback done\n", .{});
    return .disarm;
}

pub fn main() !void {
    std.debug.print("mainmain\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    env = .{
        .loop = &loop,
    };

    // Run the main function, which will enqueue some completions to the loop
    // and suspend, returning control back here, triggering the loop to run until
    // completion.
    const main_coro = try libcoro.xcoroAlloc(coroMain, .{}, allocator, null, .{});
    defer main_coro.deinit();
    try libcoro.xresume(main_coro);

    std.debug.print("mainmain loop run\n", .{});
    try loop.run(.until_done);
    std.debug.print("mainmain done\n", .{});
}

fn coroMain() !void {
    std.debug.print("coroMain\n", .{});

    sleepFor(1000);

    std.debug.print("coroMain done\n", .{});
}

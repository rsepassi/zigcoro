const std = @import("std");
const xev = @import("xev");
const libcoro = @import("libcoro");

// Notes
// * CoroPool? To reuse stacks?

const Env = struct {
    loop: *xev.Loop,
    allocator: std.mem.Allocator,
};
var env: Env = undefined;

fn sleep(ms: u64) xev.Timer.RunError!void {
    std.debug.print("sleep\n", .{});

    var data: struct {
        result: xev.Timer.RunError!void = {},
        coro: *libcoro.Coro = undefined,

        fn callback(
            userdata: ?*@This(),
            loop: *xev.Loop,
            c_inner: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = c_inner;
            _ = loop;
            const data: *@This() = @ptrCast(@alignCast(userdata.?));
            data.result = result;
            libcoro.xresume(data.coro);
            return .disarm;
        }
    } = .{ .coro = libcoro.xcurrent() };

    const w = try xev.Timer.init();
    defer w.deinit();
    var c: xev.Completion = .{};
    w.run(env.loop, &c, ms, @TypeOf(data), &data, &@TypeOf(data).callback);

    std.debug.print("sleep suspend {d}\n", .{std.time.timestamp()});
    libcoro.xsuspend();
    std.debug.print("sleep done    {d}\n", .{std.time.timestamp()});
    return data.result;
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
        .allocator = allocator,
    };

    const main_coro = try libcoro.xcoroAlloc(coroMain, .{1000}, env.allocator, null, .{});
    defer main_coro.deinit();
    try libcoro.xresume(main_coro);

    const main_coro2 = try libcoro.xcoroAlloc(coroMain, .{500}, env.allocator, null, .{});
    defer main_coro2.deinit();
    try libcoro.xresume(main_coro2);

    std.debug.print("mainmain loop run\n", .{});
    try loop.run(.until_done);
    std.debug.print("mainmain done\n", .{});
}

fn coroMain(tick: usize) !void {
    std.debug.print("coroMain\n", .{});

    for (0..10) |i| {
        try sleep(tick);
        std.debug.print("coroMain tick {d}\n", .{i});
    }

    std.debug.print("coroMain done\n", .{});
}

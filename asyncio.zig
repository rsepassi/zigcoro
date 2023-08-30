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

fn sleepFor(ms: u64) xev.Timer.RunError!void {
    std.debug.print("sleepFor\n", .{});

    var data: struct {
        err: ?xev.Timer.RunError = null,
        coro: *libcoro.Coro = undefined,

        fn callback(
            userdata: ?*@This(),
            loop: *xev.Loop,
            c_inner: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            std.debug.print("in callback\n", .{});
            _ = c_inner;
            _ = loop;
            const data: *@This() = @ptrCast(@alignCast(userdata.?));
            if (result) |_| {} else |err| {
                data.err = err;
            }
            libcoro.xresume(data.coro);
            return .disarm;
        }
    } = .{ .coro = libcoro.xcurrent() };

    const w = try xev.Timer.init();
    defer w.deinit();
    var c: xev.Completion = .{};
    w.run(env.loop, &c, ms, @TypeOf(data), &data, &@TypeOf(data).callback);

    std.debug.print("sleepFor suspend {d}\n", .{std.time.timestamp()});
    libcoro.xsuspend();
    std.debug.print("sleepFor done    {d}\n", .{std.time.timestamp()});
    if (data.err) |err| return err;
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

    const main_coro = try libcoro.xcoroAlloc(coroMain, .{}, env.allocator, null, .{});
    defer main_coro.deinit();
    try libcoro.xresume(main_coro);

    std.debug.print("mainmain loop run\n", .{});
    try loop.run(.until_done);
    std.debug.print("mainmain done\n", .{});
}

fn coroMain() !void {
    std.debug.print("coroMain\n", .{});

    try sleepFor(1000);

    std.debug.print("coroMain done\n", .{});
}

const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const coro = b.addModule("libcoro", .{
        .source_file = .{ .path = "coro.zig" },
    });

    const coro_test = b.addTest(.{
        .name = "corotest",
        .root_source_file = .{ .path = "test.zig" },
        .target = target,
        .optimize = optimize,
    });
    coro_test.addModule("libcoro", coro);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(coro_test).step);
}

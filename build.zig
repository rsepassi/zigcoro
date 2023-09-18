const std = @import("std");

pub fn build(b: *std.Build) !void {
    // Options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const default_stack_size = b.option(usize, "libcoro_default_stack_size", "Default stack size for coroutines") orelse 1024 * 4;
    const debug_log_level = b.option(usize, "libcoro_debug_log_level", "Debug log level for coroutines") orelse 0;

    // Deps
    const xev = b.dependency("libxev", .{}).module("xev");

    // Module
    const coro_options = b.addOptions();
    coro_options.addOption(usize, "default_stack_size", default_stack_size);
    coro_options.addOption(usize, "debug_log_level", debug_log_level);
    const coro = b.addModule("libcoro", .{
        .source_file = .{ .path = "src/main.zig" },
        .dependencies = &[_]std.Build.ModuleDependency{
            .{ .name = "xev", .module = xev },
            .{ .name = "libcoro_options", .module = coro_options.createModule() },
        },
    });

    {
        const coro_test = b.addTest(.{
            .name = "corotest",
            .root_source_file = .{ .path = "src/test.zig" },
            .target = target,
            .optimize = optimize,
        });
        coro_test.addModule("libcoro", coro);
        coro_test.addModule("xev", xev);
        coro_test.linkLibC();

        const internal_test = b.addTest(.{
            .name = "corotest-internal",
            .root_source_file = .{ .path = "src/coro.zig" },
            .target = target,
            .optimize = optimize,
        });
        coro_test.addModule("xev", xev);
        coro_test.linkLibC();

        // Test step
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&b.addRunArtifact(coro_test).step);
        test_step.dependOn(&b.addRunArtifact(internal_test).step);
    }

    {
        const aio_test = b.addTest(.{
            .name = "aiotest",
            .root_source_file = .{ .path = "src/test_aio.zig" },
            .target = target,
            .optimize = optimize,
        });
        aio_test.addModule("libcoro", coro);
        aio_test.addModule("xev", xev);
        aio_test.linkLibC();

        // Test step
        const test_step = b.step("test-aio", "Run async io tests");
        test_step.dependOn(&b.addRunArtifact(aio_test).step);
    }

    {
        // Benchmark
        const bench = b.addExecutable(.{
            .name = "benchmark",
            .root_source_file = .{ .path = "benchmark.zig" },
            .optimize = .ReleaseFast,
        });
        bench.addModule("libcoro", coro);
        bench.linkLibC();
        const bench_run = b.addRunArtifact(bench);
        if (b.args) |args| {
            bench_run.addArgs(args);
        }
        const bench_step = b.step("benchmark", "Run benchmark");
        bench_step.dependOn(&bench_run.step);
        bench_step.dependOn(&b.addInstallArtifact(bench, .{}).step);
    }
}

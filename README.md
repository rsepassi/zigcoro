# zigcoro

*Async Zig as a library using stackful coroutines.*

WIP as of 2023/08/24.

While waiting for Zig's async to land, I thought it'd be interesting to build
out an async runtime as a library. This is the result of that effort.

Currently supports arm64 (aka aarch64). Tested on M1 Mac.

## Example

```zig
fn simple_coro(x: *i32) void {
    x.* += 1;

    // Use yield to switch back to the calling coroutine (which may be the main
    // thread)
    libcoro.xsuspend();

    x.* += 3;
}

test "simple" {
    const allocator = std.heap.c_allocator;

    // Create a coroutine.
    // Each coroutine has a dedicated stack. You can specify an allocator and
    // stack size (Coro.initAlloc) or provide a stack directly (Coro.init).
    var x: i32 = 0;
    var coro = try libcoro.Coro.initAlloc(simple_coro, .{&x}, allocator, null);
    defer coro.deinit();

    // Coroutines start off paused.
    try std.testing.expectEqual(x, 0);

    // xresume switches to the coroutine.
    libcoro.xresume(coro);

    // A coroutine can xsuspend, yielding control back to its caller.
    try std.testing.expectEqual(x, 1);

    libcoro.xresume(coro);
    try std.testing.expectEqual(x, 4);

    // Finished coroutines are marked done
    try std.testing.expect(coro.done);
}
```

## Todos

* yield/await
* Detect incomplete coroutines
* Cancellation
* Single-threaded scheduler/runtime
* Multi-threaded scheduler/runtime
* Coro-friendly (i.e. non-blocking) concurrency primitives and IO
* Coro names/ids
* Debugging/tracing tools
* Make it so that it's trivial to switch to Zig's async when it's ready
* Stacks
  * Stackless coroutines (with limitations)
  * Auto-growing stacks
  * Copy-stack mode
* Link to other inspiring implementations
* Architecture support
  * x86 support
  * risc-v
  * 32-bit
  * WASM

## Notes

This is a "stackful" coroutine implementation; that is, each coroutine is given an
explicitly allocated separate stack (which itself could be stack or heap allocated).
An ergonomic "stackless" implementation would require language support and that's
what we expect to see with Zig's async functionality.

## Performance

Run on an M1 Mac Mini.

```
> zig env | grep target
 "target": "aarch64-macos.13.5...13.5-none"
> zig build benchmark
ns/ctxswitch: 19
```

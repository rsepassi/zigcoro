# zigcoro

*Async Zig as a library using stackful coroutines.*

WIP as of 2023/08/28.

While waiting for Zig's async to land, I thought it'd be interesting to build
out an async runtime as a library. This is the result of that effort.

Currently supports arm64 (aka aarch64). Tested on M1 Mac.

## Example

```zig
fn simple_coro(x: *i32) void {
    x.* += 1;

    // Use xsuspend to switch back to the calling coroutine (which may be the main
    // thread)
    libcoro.xsuspend();

    x.* += 3;
}

test "simple" {
    const allocator = std.heap.c_allocator;

    // Create a coroutine.
    // Each coroutine has a dedicated stack. You can specify an allocator and
    // stack size (xasyncAlloc) or provide a stack directly (xasync).
    var x: i32 = 0;
    var coro = try libcoro.xasyncAlloc(simple_coro, .{&x}, allocator, null);
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

Minimal:
* Inject values in with resume (to be returned in suspend/yield)
* User function error handling
* Benchmark number of coroutines and memory

Featureful:
* Task library
  * Schedulers (single and multi threaded)
  * Futures
  * Cancellation
* Coro-friendly (i.e. non-blocking) concurrency primitives and IO (wrapping libuv)
* Debugging
    * Coro names
    * Tracing tools
    * Detect incomplete coroutines
    * ASAN, TSAN, Valgrind support
* Recursive data structure and coroutine based iterator library
* Coroutine-based parsing library
* Make it so that it's trivial to switch to Zig's async when it's ready
* Architecture support
  * x86 support
  * risc-v
  * 32-bit
  * WASM
  * Comptime?

## Notes

This is a "stackful asymmetric" coroutine library:
* Stackful: each coroutine has an explicitly allocated stack and
  suspends/yields preserve the entire call stack of the current coroutine. An
  ergonomic "stackless" implementation would require language support and
  that's what we expect to see with Zig's async functionality.
* Asymmetric: coroutines are nested such that there is always a
  "caller"/"callee" relationship. The caller coroutine is the parent such that
  all yields/suspends will jump back to it.

## Performance

The benchmark measures the cost of a context switch from one coroutine to
another by bouncing back and forth between 2 coroutines millions of times.

From a run on an M1 Mac Mini:

```
> zig env | grep target
 "target": "aarch64-macos.13.5...13.5-none"
> zig build benchmark
ns/ctxswitch: 17
```

## Inspirations

* [Revisiting Coroutines by de Moura & Ierusalimschy][coropaper]
* https://github.com/edubart/minicoro
* https://github.com/kprotty/zefi

[coropaper]: https://dl.acm.org/doi/pdf/10.1145/1462166.1462167

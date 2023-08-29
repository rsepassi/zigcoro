# zigcoro

Async Zig as a library using stackful asymmetric coroutines.

* Stackful: each coroutine has an explicitly allocated stack and
  suspends/yields preserve the entire call stack of the coroutine. An
  ergonomic "stackless" implementation would require language support and
  that's what we expect to see with Zig's async functionality.
* Asymmetric: coroutines are nested such that there is a "caller"/"callee"
  relationship, starting with a root coroutine per thread. The caller coroutine
  is the parent such that upon completion of the callee (the child coroutine),
  control will transfer to the caller. Intermediate yields/suspends transfer
  control to the last resuming coroutine.

---

[![test][ci-badge]][ci]

*[Tested][ci] weekly and on push on {Windows, Linux, Mac} `x86_64` with Zig v0.11. Also
supports {Linux, Mac} `aarch64`.*

## Current status

*As of 2023/08/29*

Alpha. Basic API implemented.

## API

```
Create:
  xcoro: create coroutine with a caller-provided stack
  xcoroAlloc: create coroutine with an Allocator
Resume:
  xresume: resume coroutine until next suspend
  xnext: resume coroutine until next yield
  xawait: resume coroutine until complete
Suspend:
  xsuspend: suspend the running coroutine
  xyield: suspend the running coroutine and yield a value
Destory: coro.deinit()
Status: coro.status()
Type-wrap: CoroT(ReturnType, YieldType).wrap(coro)
```

## Examples

Explicit resume/suspend (`xresume`, `xsuspend`):

```zig
fn explicit_coro(x: *i32) void {
    x.* += 1;
    libcoro.xsuspend();
    x.* += 3;
}

test "explicit" {
    const allocator = std.heap.c_allocator;
    var x: i32 = 0;

    // Use xcoro or xcoroAlloc to create a coroutine
    var coro = try libcoro.xcoroAlloc(
        explicit_coro,
        .{&x},
        allocator,
        null,
        .{},
    );
    defer coro.deinit();

    // Coroutines start off paused.
    try std.testing.expectEqual(x, 0);

    // xresume suspends the current coroutine and resumes the passed coroutine.
    libcoro.xresume(coro);

    // When the coroutine suspends, it yields control back to the caller.
    try std.testing.expectEqual(coro.status(), .Suspended);
    try std.testing.expectEqual(x, 1);

    // xresume can be called until the coroutine is Done
    libcoro.xresume(coro);
    try std.testing.expectEqual(x, 4);
    try std.testing.expectEqual(coro.status(), .Done);
}
```

Generator (`xnext`, `xyield`):

```zig
fn generator(end: usize) void {
    for (0..end) |i| {
        libcoro.xyield(i);
    }
}

test "generator" {
    const allocator = std.heap.c_allocator;
    const end: usize = 10;
    var gen = try libcoro.xcoroAlloc(
        generator,
        .{end},
        allocator,
        null,
        .{ .YieldT = usize },
    );
    defer gen.deinit();
    var i: usize = 0;
    while (libcoro.xnext(gen)) |val| : (i += 1) {
        try std.testing.expectEqual(i, val);
    }
    try std.testing.expectEqual(i, 10);
}
```

Await (`xawait`):

```zig
fn inner() usize {
    libcoro.xsuspend();
    return 10;
}

fn nested() !usize {
    const allocator = std.heap.c_allocator;
    var coro = try libcoro.xcoroAlloc(inner, .{}, allocator, null, .{});
    defer coro.deinit();
    const x = libcoro.xawait(coro);
    return x + 7;
}

test "nested" {
    const allocator = std.heap.c_allocator;
    var coro = try libcoro.xcoroAlloc(nested, .{}, allocator, null, .{});
    defer coro.deinit();
    const val = try libcoro.xawait(coro);
    try std.testing.expectEqual(val, 17);
}
```

## Performance

The benchmark measures the cost of a context switch from one coroutine to
another by bouncing back and forth between 2 coroutines millions of times.

From a run on an AMD Ryzen Threadripper PRO 5995WX:

```
> zig env | grep target
 "target": "x86_64-linux.5.19...5.19-gnu.2.19"
> zig build benchmark
ns/ctxswitch: 7
```

From a run on an M1 Mac Mini:

```
> zig env | grep target
 "target": "aarch64-macos.13.5...13.5-none"
> zig build benchmark
ns/ctxswitch: 17
```

Each coroutine uses, at minimum, 1 page of memory, typically 4KB on `x86_64`
Linux. As long as the coroutine stacks can all be resident in memory,
performance is ~preserved. Verified that a Linux box with ~400GB of memory
can spawn and swap between 100M simple coroutines without issue.

## Future work

* Libraries
  * Concurrency primitives and IO (with libuv or libxev)
  * Task library: schedulers, futures, cancellation
  * Recursive data structure iterators
  * Parsers
* Debugging
    * Coro names
    * Tracing tools
    * Detect incomplete coroutines
    * ASAN, TSAN, Valgrind support
* Make it so that it's as easy as possible to switch to Zig's async when it's
  ready
* C API
* Broader architecture support
  * risc-v
  * 32-bit
  * WASM
  * comptime?

## Inspirations

* ["Revisiting Coroutines"][coropaper] by de Moura & Ierusalimschy
* https://github.com/edubart/minicoro
* https://github.com/kurocha/coroutine
* https://github.com/kprotty/zefi

[coropaper]: https://dl.acm.org/doi/pdf/10.1145/1462166.1462167
[ci]: https://github.com/rsepassi/zigcoro/actions/workflows/zig.yml?query=branch%3Amain
[ci-badge]: https://github.com/rsepassi/zigcoro/actions/workflows/zig.yml/badge.svg?query=branch%3Amain

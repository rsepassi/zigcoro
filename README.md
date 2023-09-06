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

Async IO is provided by [`libxev`][libxev].

---

[![test][ci-badge]][ci]

*[Tested][ci] weekly and on push on {Windows, Linux, Mac} `x86_64` with Zig v0.11. Also
supports {Linux, Mac} `aarch64`.*

## Current status

*Updated 2023/09/05*

Alpha.

Next steps are to further explore cooperative multitasking.

## Coroutine API

```
stackAlloc(allocator, size)->[]u8
remainingStackSize()->usize
xcurrent()->*Coro
xcurrentStorage(T)->*T
xresume(*coro)
xsuspend()
Coro
  init(*func, *stack, ?*storage)
  getStorage(T)
CoroFunc(Fn)
  init(.{args})
  initPtr(&fn, .{args})
  coro(*stack)->Coro
  xresumeStart()->YieldT
  xresume(inject)->YieldT
  xresumeEnd(inject)->ReturnT
  xyield(yield)->InjectT
StackCoro
  init(*func, .{args}, *stack)
  frame(*func, coro)->CoroFunc(Fn)
```

## Async IO API

`libcoro.xev.aio` provides coroutine-friendly wrappers to all the [high-level
async APIs][libxev-watchers] in [`libxev`][libxev].

See
[`aio_test.zig`](https://github.com/rsepassi/zigcoro/blob/main/aio_test.zig)
for usage examples.

```
sleep
TCP
  accept
  connect
  read
  write
  close
  shutdown
UDP
  read
  write
  close
Process
  wait
File
  read
  pread
  write
  pwrite
  close
Async
  wait
```

Stackful asymmetric coroutines provide a clean way of wrapping up async IO
functionality, providing a programming model akin to threads (where the lightweight
versions are variously called Coroutines, Green Threads, or Fibers). Calls to
IO functionality are blocking from the perspective of the coroutine, but many
coroutines can be running on the same thread.

Under the hood, what's required is async IO functionality, such that a coroutine
can submit work to be done, suspend, and then be resumed when the work is complete.
Libraries like [libuv][libuv] and [libxev][libxev] provide cross-platform async IO,
and this is a new Zig project, so why not depend on another new Zig project like
libxev?

## Depend

`build.zig.zon`
```zig
.zigcoro = .{
  .url = "https://api.github.com/repos/rsepassi/zigcoro/tarball/s0mEg1tHasH",
},
```

`build.zig`
```zig
const libcoro = b.dependency("zigcoro", .{}).module("libcoro");
my_lib.addModule("libcoro", libcoro);
```

## Coroutine Examples

*TODO: Fill back in*

* resume, suspend
* storage
* args, return
* yield, inject

## Performance

I've done some simple benchmarking on the cost of context switching and on
pushing the number of coroutines. Further investigations on performance would
be most welcome, as well as more realistic benchmarks.

## Context switching

This benchmark measures the cost of a context switch from one coroutine to
another by bouncing back and forth between 2 coroutines millions of times.

From a run on an AMD Ryzen Threadripper PRO 5995WX:

```
> zig env | grep target
 "target": "x86_64-linux.5.19...5.19-gnu.2.19"

> zig build benchmark -- --context_switch
ns/ctxswitch: 7
```

From a run on an M1 Mac Mini:

```
> zig env | grep target
 "target": "aarch64-macos.13.5...13.5-none"

> zig build benchmark -- --context_switch
ns/ctxswitch: 17
```

## Coroutine count

This benchmark spawns a number of coroutines and iterates through them bouncing
control back and forth, periodically logging the cost of context switching. As
you increase the number of coroutines, you'll notice a cliff in performance or OOM.
This will be highly dependent on the amount of free memory on the system.

Note also that zigcoro's default stack size is 4096B, which is the typical size of
a single page on many systems.

From a run on an AMD Ryzen Threadripper PRO 5995WX:

```
> zig env | grep target
 "target": "x86_64-linux.5.19...5.19-gnu.2.19"

> cat /proc/meminfo | head -n3
MemTotal:       527970488 kB
MemFree:        462149848 kB
MemAvailable:   515031792 kB

> zig build benchmark -- --ncoros 1_000_000
Running benchmark ncoros
Running 1000000 coroutines for 1000 rounds
ns/ctxswitch: 57
...

> zig build benchmark -- --ncoros 100_000_000
Running benchmark ncoros
Running 100000000 coroutines for 1000 rounds
ns/ctxswitch: 57
...

> zig build benchmark -- --ncoros 200_000_000
Running benchmark ncoros
Running 200000000 coroutines for 1000 rounds
error: OutOfMemory
```

From a run on an M1 Mac Mini:
```
> zig env | grep target
 "target": "aarch64-macos.13.5...13.5-none"

> system_profiler SPHardwareDataType | grep Memory
  Memory: 8 GB

> zig build benchmark -- --ncoros 800_000
Running benchmark ncoros
Running 800000 coroutines for 1000 rounds
ns/ctxswitch: 26
...

> zig build benchmark -- --ncoros 900_000
Running benchmark ncoros
Running 900000 coroutines for 1000 rounds
ns/ctxswitch: 233
...
```

## Future work

Contributions welcome.

* Libraries
  * (WIP) Task library: schedulers, futures, cancellation
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
[libxev]: https://github.com/mitchellh/libxev
[libxev-watchers]: https://github.com/mitchellh/libxev/tree/main/src/watcher
[libuv]: https://libuv.org

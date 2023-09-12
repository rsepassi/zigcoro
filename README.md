# zigcoro

Async Zig as a library using stackful asymmetric coroutines.

Supports async IO via [`libxev`][libxev].

---

[![test][ci-badge]][ci]

*[Tested][ci] weekly and on push on {Windows, Linux, Mac} `x86_64` with Zig v0.11. Also
supports {Linux, Mac} `aarch64`.*

## Depend

`build.zig.zon`
```zig
.zigcoro = .{
  .url = "https://api.github.com/repos/rsepassi/zigcoro/tarball/v0.4.0",
  .hash = "1220963d94c1c44a71f5d14158e244c47ca84b585790240828b2288b2269b4dc0cde",
},
```

`build.zig`
```zig
const libcoro = b.dependency("zigcoro", .{}).module("libcoro");
my_lib.addModule("libcoro", libcoro);
```

## Current status

*Updated 2023/09/08*

Alpha, WIP.

[TODOs](#TODO) list active work.

## Coroutine API

```
// High-level API
xasync(func, args, *stack)->FrameT
xawait(FrameT)->T
xframe()->Frame
xresume(frame)
xsuspend()
xsuspendBlock(func, ptr)

// Optional thread-local environment
initEnv

// Low-level API
Coro (Frame=*Coro)
  init(func, *stack, ?*storage)->Frame
  getStorage(T)->*T
CoroT(func, opts)
  init(args, *stack)->Frame
  xnextStart(frame)->YieldT
  xnext(frame, inject)->YieldT
  xnextEnd(frame, inject)->ReturnT
  xyield(yield)->InjectT
  xreturned(frame)->ReturnT

// Stack utilities
stackAlloc(allocator, size)->[]u8
remainingStackSize()->usize
```

## Async IO API

[`libcoro.asyncio`][aio] provides coroutine-based async IO functionality
building upon the event loop from [`libxev`][libxev],
providing coroutine-friendly wrappers to all the [high-level
async APIs][libxev-watchers].

See [`test_aio.zig`][test-aio] for usage examples.

```
// Top-level coroutine execution
run

// Optional thread-local environment
initEnv

// IO
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
AsyncNotification
  wait
```

## Switching to Zig's async/await

zigcoro has been designed to make it trivial to switch to Zig's async/await
when it's ready. Below you'll find the zigcoro version along with the Zig
async/await version for each of the core APIs.

```zig
// async
var frame = try xasync(func, args, stack);
var frame = async func(args);

// await
const res = xawait(frame);
const res = await frame;

// @frame
var frame = xframe();
var frame = @frame();

// suspend
xsuspend();
suspend {}

// suspend block
xsuspendBlock(func, ptr);
suspend { func(ptr); }

// resume
xresume(frame);
resume frame;

// nosuspend
run(loop, func, args, stack)
nosuspend run(loop, func, args, null)

// xev IO
// No changes needed to the calls
try sleep(loop, 10);
```

The above assumes the Zig async API that was available in [Zig
0.10.1][zig-async].

## Performance

I've done some simple benchmarking on the cost of context
switching and on pushing the number of coroutines. Further
investigations on performance would be most welcome, as well
as more realistic benchmarks.

## Context switching

This benchmark measures the cost of a context switch from
one coroutine to another by bouncing back and forth between
2 coroutines millions of times.

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

This benchmark spawns a number of coroutines and iterates
through them bouncing control back and forth, periodically
logging the cost of context switching. As you increase the
number of coroutines, you'll notice a cliff in performance
or OOM. This will be highly dependent on the amount of free
memory on the system.

Note also that zigcoro's default stack size is 4096B, which
is the typical size of a single page on many systems.

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

## Stackful asymmetric coroutines

* Stackful: each coroutine has an explicitly allocated stack and
  suspends/yields preserve the entire call stack of the coroutine. An
  ergonomic "stackless" implementation would require language support and
  that's what we expect to see with Zig's async functionality.
* Asymmetric: coroutines are nested such that there is a "caller"/"callee"
  relationship, starting with a root coroutine per thread. The caller coroutine
  is the parent such that upon completion of the callee (the child coroutine),
  control will transfer to the caller. Intermediate yields/suspends transfer
  control to the last resuming coroutine.

The wonderful 2009 paper ["Revisiting Coroutines"][coropaper] describes the
power of stackful asymmetric coroutines in particular and their various
applications, including nonblocking IO.

## Future work

Contributions welcome.

* Simple coro stack allocator, reusing stacks
* More aggressive stack reclamation
* Global/thread-local defaults (event loop, stack allocator)
* Build option for default stack size
* Libraries
  * TLS, HTTP, WebSocket
  * Actors
  * Recursive data structure iterators
  * Parsers
* Multi-threading support
* Alternative async IO loops (e.g. [libuv][libuv])
* Debugging
    * Coro names
    * Tracing tools
    * Verbose logging
    * Dependency graphs
    * Detect incomplete coroutines
    * ASAN, TSAN, Valgrind support
* C API
* Broader architecture support
  * risc-v
  * 32-bit
  * WASM (Asyncify?)
  * comptime?

### TODO

* Concurrent execution helpers (e.g. xawaitAsReady)
* Add support for cancellation and timeouts
* Async iterators/streams
* Channels (possibly replacing yield/inject)
* HTTP client and server
* Documentation, code comments, examples
* Write up

## Inspirations

* ["Revisiting Coroutines"][coropaper] by de Moura & Ierusalimschy
* [Lua coroutines][lua-coro]
* ["Structured Concurrency"][struccon] by Eric Niebler
* https://github.com/edubart/minicoro
* https://github.com/kurocha/coroutine
* https://github.com/kprotty/zefi

[coropaper]: https://dl.acm.org/doi/pdf/10.1145/1462166.1462167
[ci]: https://github.com/rsepassi/zigcoro/actions/workflows/zig.yml?query=branch%3Amain
[ci-badge]: https://github.com/rsepassi/zigcoro/actions/workflows/zig.yml/badge.svg?query=branch%3Amain
[libxev]: https://github.com/mitchellh/libxev
[libxev-watchers]: https://github.com/mitchellh/libxev/tree/main/src/watcher
[libuv]: https://libuv.org
[struccon]: https://ericniebler.com/2020/11/08/structured-concurrency
[aio]: https://github.com/rsepassi/zigcoro/blob/main/src/aio_xev.zig
[test-aio]: https://github.com/rsepassi/zigcoro/blob/main/src/test_aio.zig
[lua-coro]: https://www.lua.org/pil/9.1.html
[zig-async]: https://ziglang.org/documentation/0.10.1/#Async-Functions

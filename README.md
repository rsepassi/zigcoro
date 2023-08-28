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

*WIP as of 2023/08/28*

While waiting for Zig's async to land, I thought it'd be interesting to build
out an async runtime as a library. This is the result of that effort.

Currently supports arm64 (aka aarch64). Tested on M1 Mac.

## API

```
Create:
  xasync: create coroutine with a caller-provided stack
  xasyncAlloc: create coroutine with an Allocator
Resume:
  xresume: resume coroutine until next suspend
  next: resume coroutine until next yield
  xawait: resume coroutine until complete
Suspend:
  xsuspend: suspend the running coroutine
  yield: suspend the running coroutine and yield a value
Destory: coro.deinit()
Status: coro.status()
```

## Todos

Minimal:
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

* ["Revisiting Coroutines"][coropaper] by de Moura & Ierusalimschy
* https://github.com/edubart/minicoro
* https://github.com/kprotty/zefi

[coropaper]: https://dl.acm.org/doi/pdf/10.1145/1462166.1462167

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

---

While waiting for Zig's async to land, I thought it'd be interesting to build
out an async runtime as a library. This is the result of that effort.

## API

```
Create:
  xasync: create coroutine with a caller-provided stack
  xasyncAlloc: create coroutine with an Allocator
Resume:
  xresume: resume coroutine until next suspend
  xnext: resume coroutine until next yield
  xawait: resume coroutine until complete
Suspend:
  xsuspend: suspend the running coroutine
  xyield: suspend the running coroutine and yield a value
Destory: coro.deinit()
Status: coro.status()
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

## Current status

*WIP as of 2023/08/28*

Not ready for use.

MVP todos:
* Addressing wonky bits (below)
* Coroutines propagate errors on resume/next/await
* Benchmark pushing number of coroutines and tracking memory

Wonky bits:
* Currently a coroutine has a parent as well as a last resumer. Upon
  yield/suspend, control is transferred to the last resumer. Upon return,
  control is transferred to the parent. So, if `xawait(coro)` is called from a
  coroutine other than the parent, `xawait` may never return. Similarly, if
  calling `xresume`/`xnext` from a coroutine other than the parent, and the resumed
  coroutine returns, control will be transferred to the parent, not the last
  resumer, which may result in unexpected behavior.
  * May want to enforce:
    * that xresume is paired with xsuspend
    * that xnext is paired with xyield
    * that xawait is only called from the parent
* The storage type for a coroutine is a little ill-defined when the coroutine
  is both a generator and an awaitable. T, ?T, ??T.
  * May want to handle yield/next a bit differently. Possibly push it to a
    separate channel-like abstraction.

## Future work

* Coro-friendly non-blocking concurrency primitives and IO (wrapping libuv)
* Task library
  * Schedulers (single and multi threaded)
  * Futures
  * Cancellation
* Debugging
    * Coro names
    * Tracing tools
    * Detect incomplete coroutines
    * ASAN, TSAN, Valgrind support
* Recursive data structure and coroutine based iterator library
* Coroutine-based parsing library
* Make it so that it's trivial to switch to Zig's async when it's ready
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

# Zig async as a library

WIP as of 2023/08/24.

While waiting for Zig's async to land, I thought it'd be interesting to build
out an async runtime as a library. This is the result of that effort.

Currently supports arm64 (aka aarch64). Tested on M1 Mac.

## Todos

* anytype func and args
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
ns/ctxswitch: 20
```

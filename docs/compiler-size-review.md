# Compiler size review

This review covers `luauc-develop` at `8bb1192` with its initial uncommitted
changes, and the optional compiler in `agent-os-develop`. Measurements use
the saved pre-review compiler and the revised compiler with the same inputs.
Sizes are raw linked wasm bytes. They are not compressed transfer sizes.

## Results

| Package | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| `calc.luau`, embed profile | 1,497,727 | 947,243 | 36.8% |
| Office, 13 modules, AgentOS profile | 4,315,732 | 3,099,000 | 28.2% |
| 32 consecutive calls, embed profile | 1,866,617 | 307,291 | 83.5% |
| Identity function, embed profile | 257,741 | 257,467 | 0.1% |

The office package contains `calc`, `chart`, `color`, `docx`, `media`, `opc`,
`path`, `pptx`, `xform`, `xlsx`, `xml`, `zip`, and the entry module. The
AgentOS compiler test executes it and verifies the generated office files.

The built AgentOS interpreter is 1,030,307 bytes, including its program stamp.
The office artifact is still larger. The `calc` measurement uses the smaller
embed runtime, so its size is not an equivalent AgentOS comparison.
This change improves the compiler but does not meet the size target for office.

## Compilation model

The frontend compiles source into temporary Luau Protos and CodeGen IR. The
snapshot is the compiler input, not a program that the guest interprets.
The backend emits wasm functions and immutable runtime metadata. Calls,
errors, GC, values, and coroutine operations use the strict runtime.

The generated function uses a wasm dispatcher for basic blocks and resume
points. A yield can destroy its wasm activation. The continuation planner
therefore admits a resume suffix only when the suffix can reconstruct its
values from the Luau frame. This invariant is also sufficient for entering
that suffix after an ordinary successful call.

Every included module and its compiled Proto graph still retain their
capabilities. The review does not remove functions based on observed calls,
evaluate initializers, embed executable bytecode, or add an interpreter.

## Main code-size defect

`compiler/backend/emit/dispatch.zig:emitCallContinuation` emitted the remainder
of a block separately for each call and interrupt. The normal block emitted
the same remainder again. A sequence of calls could therefore produce
quadratic code growth.

The ordinary path now branches to the already admitted call suffix. An
interrupt enters its existing interrupt continuation before executing the
interrupt. That continuation executes the interrupt once and continues into
the suffix. A suffix does not branch to itself at its entry. Splitting also
requires the same range end, so partial specialized ranges keep their existing
lowering. Existing continuation indices provide constant-time lookups.

The regression test compiles 8, 16, and 32 calls. Before the change, these
produce 372,069, 677,717, and 1,866,617 bytes. After the change, they produce
270,488, 282,753, and 307,291 bytes. The test checks incremental growth and
executes positive, zero, and negative inputs. It repeats the test with
yield/full-GC boundaries.

The tradeoff is an additional wasm dispatcher transfer on successful calls
and interrupts. This is ordinary generated control flow. No runtime IR or
bytecode dispatch is introduced. The review does not claim a runtime speedup.

## Uncommitted optimizations

The value-local work remains. It removes internal cluster results, reuses
same-block local lifetimes, and delays eligible register loads until use.
Its register-write checks now use a prefix index instead of rescanning every
producer-to-consumer interval. Runtime-assisted numeric loads are barriers.

The expanded linker outlining changes are removed. With the value-local work
still enabled, reverting those changes reduces `calc` from 1,497,727 to
1,497,294 bytes and office from 4,315,732 to 4,307,860 bytes. The added memory
offset parameters and status-return handling did not justify their code and
complexity on these packages. The committed relocation tightening and
existing arm sharing remain.

## Correctness defect

`compiler/backend/emit/closures.zig:emitUniformCaptureRun` restarted capture
indices at zero for each run. Runs can split at a capture-kind boundary or
at the eight-capture limit. Later runs then overwrite earlier captures and
can put the GC marker before the closure's actual last capture.

The shared helper now receives the first capture index. The new regression
uses more than eight captures. It fails with the pre-review compiler and
passes with the fix. The original office package also failed during module
initialization with the same GC-marker error; it now executes successfully.

## Linker and remaining size

`compiler/link/linker.zig:emit` preserves the runtime pack's functions and
table entries. It shortens relocated immediates, appends generated functions,
and retains only profile-declared exports. Removing exports does not remove
the associated function bodies from the pack.

The AgentOS runtime pack is 503,370 bytes. The final office artifact has a
2,680,702-byte code section and a 411,602-byte data section. The remaining
problem is predominantly generated code, not custom-section names or padded
relocations. Removing all runtime-pack bytes would still not put office
below the interpreter.

Further work should measure emitted bytes per operation and per Proto.
Prioritize repeated call/status/stack-reload sequences and safe shared
lowerings. Whole-program removal of library functions needs an explicit
proof of reachability through tables, closures, and dynamic calls. A runtime
pack reachability pass must also preserve table-referenced library functions
and remap every affected function index.

## AgentOS integration

The guest command sends a closed source package to the optional host compiler.
The host checks the request, compiles it, stamps the artifact, and returns the
bytes. The interpreter remains available independently.

The JavaScript wrapper leaked allocations when a later allocation failed,
and could leak a created context if ABI description failed. Cleanup now
covers partial construction and partial request allocation. Tests inject
failure at all six allocation positions across load and compile.

The native wrapper left staged pack/profile files behind when engine startup
failed. It now removes that staging directory. Its focused tests cover
startup failure, malformed requests, and native compilation.

The native wrapper still waits two seconds to infer startup success. That is
attachment latency, not compile latency. A future explicit readiness message
would require a coordinated port-protocol change. The wasm wrapper also runs
compilation synchronously; its async method does not move CPU work off the
JavaScript event loop.

AgentOS remains pinned to its existing luauc archive. Validation uses
`--override_module=luauc=/mnt/workspace/opytai/luauc/luauc-develop`. A release
must update the archive commit and integrity together after committing luauc.

## Validation

All 25 targeted luauc tests pass. They cover backend conformance, JavaScript execution,
Wasmtime parity, yield/GC barriers, native/wasm compiler parity, ABI handling,
strict-AOT forbidden symbols, and the new size regression. The AgentOS
compiler end-to-end test uses the local luauc override. Three focused native
adapter tests pass independently of the rest of the server application.

Stale upvalue import expectations were updated so closure and buffer tests
run to completion. A synthetic upvalue-read counter was removed; the test now
counts the actual helper reads.

The separate linker corpus test still assumes generated function counts and
relocation byte offsets remain unchanged after linking. Those assumptions
conflict with the existing outlining and immediate-tightening passes. It
fails its generated-function-count assertion and is not reported as passing.
Its relocation oracle needs to account for transformed output.

Compilation timings varied with host and concurrent builds. The raw-size
comparisons and behavioral tests are the acceptance evidence for this change.

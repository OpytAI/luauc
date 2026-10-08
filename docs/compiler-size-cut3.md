# Third compiler size cut

This review starts from the uncommitted second cut. It targets the compiler
model and runtime linkage, not an office-specific source transformation.
All sizes below are raw wasm bytes from the same seven-case source matrix.

## Results

| Program | Before | After | Saved |
| --- | ---: | ---: | ---: |
| Identity, embed | 257,467 | 220,176 | 37,291 |
| Math, embed | 262,959 | 233,083 | 29,876 |
| Table iteration, embed | 265,861 | 239,110 | 26,751 |
| String operations, embed | 263,212 | 231,436 | 31,776 |
| Coroutine yield, embed | 259,607 | 229,051 | 30,556 |
| calc plus identity entry, embed | 832,438 | 769,720 | 62,718 |
| Office, 13 modules, AgentOS | 2,620,268 | 2,391,262 | 229,006 |

The calc entry in this matrix differs from the preceding reports. Compare
only the two columns in this table for that case.

Office is 8.7% smaller than the second cut, 22.8% smaller than `c098252`,
and 44.6% smaller than the initial 4,315,732-byte artifact. It still exceeds
the 1,030,307-byte interpreter. This is not a one-megabyte reduction from the
second cut, and the interpreter-size target remains unmet.

The measured office stages are 2,600,467 after runtime reachability pruning,
2,428,852 without frontend block cloning, and 2,391,262 with shared constant
array checks. One final office integration run compiles in 1,268 ms. Timing
is not a controlled speed comparison.

## Design findings and changes

### A symbol universe is not a reachability root set

The runtime pack exports every generated-code helper so that any source
package can resolve its imports. The linker previously stripped those export
names but retained all their function bodies. This confuses symbols available
to the linker with symbols required by the finished program.

The linker now computes the direct-call closure from three root sets:

- Runtime functions imported by the generated object.
- Functions retained by the provider's public export contract.
- Every function in every runtime element segment.

The worklist visits each reachable function once. A dense live array provides
constant-time membership tests. The linker then assigns dense function IDs
and rewrites direct calls, export indices, and element function indices.
Imported function IDs, type IDs, table slots, memory addresses, and all data
segments remain stable. Unreachable recursive cycles can be removed.

All table targets remain roots even when no static source call names them.
This retains dynamic library lookup, metatables, callbacks, and indirect calls.
No source-level guesses about which library methods an application needs are
used. Allocation-failure tests cover construction and cleanup of the graph.

This reduces the runtime contribution to each linked program. It does not
shrink the downloadable universal pack itself. That pack must still provide
helpers for other source packages. Data compaction needs separate relocation
proofs because native pointers are embedded in the pack's data.

### Native-JIT block cloning is the wrong default for size-oriented AOT

The frontend previously ran `createLinearBlocks` after constant propagation.
This pass clones successor chains for individual predecessors and propagates
path-specific constants through the copies. It can help a native JIT, but the
AOT backend must encode both the clones and the original paths in wasm.

The frontend now keeps CFG analysis and constant propagation but omits this
cloning pass. This is one production pipeline, not a second compiler mode.
The frontend identity changes to
`254652880aa0967cfcb192da1a8bb062ae82d6adc767e0d5aea044b675c4efd0`.
The snapshot wire format and backend's accepted IR operations do not change.

Historical graph fixtures retain tests for linearized blocks and their
malformed variants. Each fixture records its source and snapshot hashes.
The harness also compiles each source through the current frontend and lowers
that result. It verifies the archived bytes, then binds only their frontend
identity field to the current backend for the structural tests. This is a
test-only operation; production identity validation is unchanged.

Most fixtures come from the `c098252` frontend. The generic, mixed, and global
table fixtures use the cached historical frontend identity recorded on each
fixture. These fixtures retain exact instruction/operand assertions instead
of deleting coverage when the current frontend stops producing those shapes.

### Function prologues repeat a shared validation algorithm

Every function with constants walked the active closure, checked its kind,
loaded its Proto, checked execdata/function identity and constant count, and
loaded `Proto.k`. Only the expected function ID and count differ.

Large packages now emit one wasm helper for that probe. Each function supplies
its two expected scalar values. The original predicates and failure behavior
remain intact. No mutable result is cached across activations or GC boundaries.
Small packages retain the inline form to avoid unnecessary helper overhead.

### String interning used a quadratic search

`StringKeyPool.intern` scanned every earlier string. It serves constants,
string keys, and module source names, so its cost grows with the product of
lookup count and distinct-string count.

The pool now uses a hash index whose keys are offsets and lengths into the
existing byte arena. It keeps insertion order and does not allocate a second
copy of each string. Hash collisions still compare the actual bytes. The
index remains valid when the byte arena moves. Tests cover binary strings,
empty strings, growth, deduplication, and every allocation failure point.
The compiler build digest now includes the model sources as well.

## What is not the main cause

The many fields in the Zig lowering context and parameters to `lowerFunction`
are compiler-side state. They are not all passed to generated wasm functions.
Refactoring them can improve maintainability, but it does not directly remove
hundreds of kilobytes from the guest. The shared prologue above targets code
that is actually emitted in each guest function.

The raw runtime already builds its C++ code with `-Oz`. Switching one more
build flag is not a plausible megabyte-scale solution. Similarly, removing
unused standard-library registrations without a proof would reduce dynamic
capabilities. This cut deliberately retains all indirect table roots.

Disabling additional dynamic string-key inline probes produced no change to
the measured matrix. That experiment is not retained.

## Remaining larger work

The backend still maps much of the native-oriented IR into a per-function
dispatcher. Ordinary CFG edges and resumable continuation entries share that
representation. A region-based lowering could use structured wasm for
single-entry regions and reserve dispatch for genuine resume/multi-entry
boundaries. It must preserve yield/full-GC reconstruction, source locations,
and Wasmi fuel-region behavior. Removing dispatcher wrappers without those
proofs is not a safe optimization.

The linker outliner recognizes a narrow set of integer/status return and
dispatch arms. Broader sharing requires typed live-in/live-out analysis, not
passing every scratch local to a helper. A profitable template must cost less
after argument materialization, helper code, and type metadata are included.

The next large opportunities are these control-flow and liveness changes,
not narrower library inclusion or an interpreter disguised as a helper.
Their savings have not been measured and are not included in this report.

## AgentOS integration boundary

AgentOS still pins an older luauc archive and hardcodes that frontend contract
in both its JS package builder and native request encoder. A local module
override alone therefore returns `CompilerContractMismatch` with this new
frontend. Do not bypass that check in production.

The full existing AgentOS compiler/office test passes when its test client
uses the new contract with the new compiler. The validation run substitutes
only the JS contract module in memory through a temporary Node loader; it
does not alter the test assertions or the compiler's validation. Shipping
requires a coordinated luauc archive and JS/native contract update. AgentOS
source pins are intentionally not changed to an uncommitted compiler.

## Validation

All 32 targeted checks pass: the conformance families, frontend identity,
compiler APIs, lowering and linker units, allocation-failure tests, JS size
regressions, Wasmtime parity/barriers, forbidden linkage, parser fuzz tests,
compiler build identity, and regenerated metadata/IR coverage maps.

The small-program regression executes identity, dynamically selected math,
table iteration, and yield/full-GC cases. It also checks deterministic output
and linked size limits. The existing separate linker corpus oracle remains
stale from before these cuts: its fixed function-count/relocation expectations
do not model tightening, outlining, or pruning. Its historical map is not
relabeled as a newly validated result.

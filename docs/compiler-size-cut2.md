# Second compiler size cut

This cut follows `c098252`. Measurements use the same source packages and
runtime profiles as `compiler-size-review.md`. Sizes are raw linked wasm.

## Results

| Package | c098252 | This cut | Reduction |
| --- | ---: | ---: | ---: |
| Office, 13 modules, AgentOS profile | 3,099,000 | 2,620,268 | 15.4% |
| calc, embed profile | 947,243 | 831,663 | 12.2% |
| Identity, embed profile | 257,467 | 257,467 | 0% |

Office is 39.3% smaller than the initial 4,315,732-byte artifact. It still
exceeds the 1,030,307-byte AgentOS interpreter. The goal is not yet met.
The office code section falls from 2,680,702 to 2,202,200 bytes. Its data
section remains nearly constant: 411,602 versus 411,408 bytes. Generated
code, not an unused source blob or runtime pack alone, remains the main cost.

## Retained changes

Large packages already use shared helpers above the eight-sibling inline
threshold. Apply that policy to returns, builtin iterator traversal, and
generic iterator calls. Use the existing runtime operations instead of
repeating their fast paths at every site. Small packages retain their inline
paths. Both forms emit wasm and use the same strict AOT runtime.

Do not synthesize ipairs or inline string sub/find/match implementations in
large packages. Emit their ordinary compiled call protocol instead. This
keeps builtin semantics, error handling, and overridden environments intact.

Do not fuse a generic loop body when its continuation also needs the body.
On successful generic iterator calls, enter the existing resume finish arm
instead of emitting result publication twice. Yielded and ordinary returns
therefore share the same finish logic.

Enter interrupt continuations through ordinary instruction lowering. An
entry sentinel prevents a self-branch. This lets the existing fused
interrupt/line/call preface apply inside the continuation as well.

Simplify the safe-environment guard. A missing environment returns an
internal error. An unsafe environment follows the existing compiled failure
edge, or returns unsupported when no edge exists. A safe environment falls
through. The guard makes no runtime call and needs no base reload.

The changes trade some inline execution for smaller generated code. They do
not claim a runtime speedup. Office compilation still takes about 1.5 seconds
in earlier local Node runs and 1.75 seconds in the final run. These are
observations, not controlled timing results.

## Measurements during development

These are cumulative office sizes, not independent savings that can be added.

| Change | Bytes |
| --- | ---: |
| Shared return and generic call helpers | 2,967,221 |
| Shared builtin iteration and ordinary ipairs | 2,824,860 |
| Simplified safe-environment guard | 2,788,796 |
| Avoid duplicate fused loop bodies | 2,785,459 |
| Fused prefaces inside interrupt continuations | 2,696,841 |
| Ordinary string method calls | 2,632,673 |
| Reuse the guard boolean as status | 2,630,769 |
| Share generic iterator finish arms | 2,620,268 |

## Rejected and deferred work

Expanding shared builtin fastcall lowering and changing direct-loop follower
discovery produced no reduction for office or calc. Neither change remains.

The frontend's `createLinearBlocks` pass clones successor chains to expose
path-specific constant propagation. Disabling it reduced an intermediate
office artifact from 2,788,796 to 2,623,566 bytes. Office execution passed,
but six conformance targets depended on the resulting graph shapes. The
pass remains enabled. A future size-oriented frontend must migrate its
contract identity and preserve the existing linearized-IR and malformed-IR
coverage rather than deleting assertions. The savings cannot be assumed to
add unchanged to the final backend cut.

A diagnostic Binaryen `-Oz` run reduced the 2,788,796-byte intermediate
artifact to 2,425,942 bytes. No postoptimizer or new production dependency
was added. This indicates remaining opportunities in generated control flow;
it is not a measured result for the final compiler.

Next priorities are frontend clone control, dispatcher/continuation edge
simplification, and repeated generated instruction sequences. Keep all
included Proto graphs and dynamic behavior unless a sound reachability proof
supports elimination. Runtime metadata compaction is secondary to code size.

## Regression coverage

`//hosts/js:shared_lowering_test` compiles and executes large packages with
8, 16, and 32 calls, with and without yield/full-GC boundaries. It checks
linear growth and a 220-byte per-added-call limit. The preceding compiler
fails that limit; this compiler passes it.

The test also covers captured mutable upvalues after return and GC, ipairs,
pairs with a hole, a yielding callable-table iterator with a false key,
string operations, and an overridden unsafe environment. The existing
frontend graph coverage remains unchanged. The buffer package's expected
import list now reflects the return helper closing upvalues itself.

The AgentOS compiler integration test executes the full office package and
checks the produced document, spreadsheet, and presentation files. No
bytecode interpretation, runtime IR evaluation, or reduced capability mode
is introduced.

Final validation passes all 26 targeted compiler tests: conformance families,
lowering driver, linker, compiler APIs, JS embedding and size regressions,
Wasmtime parity and barriers, forbidden linkage, and compiler build identity.
AgentOS `//memcontainers/sdk-js/core:compiler_test` also passes with
`--override_module=luauc=/mnt/workspace/opytai/luauc/luauc-develop`.
Formatting and `git diff --check` pass. The separate linker corpus test's
pre-existing count/relocation oracle issue remains outside this cut.

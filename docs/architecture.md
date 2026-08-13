# Architecture

`luauc` has one compilation path:

```text
SourcePackageV1 + RuntimeProfileV1 + normalized runtime pack
  -> pinned Luau parser and source compiler
  -> temporary Proto graph and pinned CodeGen IR
  -> pointer-free FrontendSnapshotV1
  -> validated Zig IR lowering
  -> standard linking-v2 WebAssembly object
  -> profile-derived bounded linker
  -> reparsed and validated strict-AOT module
```

Temporary bytecode exists only inside the compiler to construct the upstream Proto graph. It is
never executed by the compiler and never copied into an output. The compiler does not evaluate
module initializers, closures, loops, errors, or tables.

The output carries generated WebAssembly bodies, immutable Proto-equivalent metadata, constants,
module records, source locations, the selected runtime pack, and a `luauc.link.v1` identity section.
It contains no parser, compiler, bytecode executor, runtime compiler, opcode-dispatch fallback, or
sidecar dependency. Unknown IR, object, profile, feature, import, or relocation shapes fail closed.

## Ownership

- Pinned Luau owns language compilation and runtime semantics.
- The C++ frontend adapter owns only pin-specific extraction into a pointer-free snapshot.
- Zig owns validation, lowering, object construction, linking, and final structural policy.
- The strict runtime owns generated-frame entry/resume plus pinned Luau values, calls, errors,
  coroutines, and GC.
- Runtime providers own host imports, libraries, protected-call transport, exports, and invocation.
- Hosts instantiate compiler and artifact modules and implement only profile-declared effects.

There is no consumer-specific host name or policy in the compiler or generated-code ABI. Generated
objects reference neutral `luauc_runtime_v1_*` symbols; the supplied profile and pack satisfy them.

## Determinism and identity

One compiler context owns immutable copies of the exact profile and pack bytes. A source request
binds their SHA-256 digests. `CompileResultV1` returns profile, pack, package-manifest, generated-object,
and final-artifact identities. Identical compiler, context, request, and options produce identical
artifact bytes. Context handles are bounded and generational, so destroyed handles cannot alias a
later context.

The reference conformance gate instantiates the same zero-import compiler in JavaScript and Wasmtime,
compiles the same multi-module request, compares artifact SHA-256, executes the artifact over three
runtime inputs, and compares results with a separately linked pinned Luau interpreter.

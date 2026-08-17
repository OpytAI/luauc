# Reference embedding

`embed-v1` is a small external-runtime contract, not a hidden compiler policy. Its final artifact
imports exactly two functions from the profile-selected namespace:

```text
protected_call() -> i32
set_throw(i32)
```

The host invokes the exported protected dispatcher as a nested Wasm call. A runtime raise publishes
its status and traps; the host catches that trap at the innermost protected boundary and returns the
status. Unexpected traps remain failures.

The artifact initializer must run once before allocation or context creation. Both reference hosts
derive that export through the profile's `initialize` role and call it immediately after
instantiation.

## Invocation ABI

The reference provider exports allocation, context, and invocation functions:

```text
luauc_embed_v1_alloc(size) -> pointer
luauc_embed_v1_dealloc(pointer)
luauc_embed_v1_context_create() -> handle
luauc_embed_v1_context_destroy(handle)
luauc_embed_v1_invoke(handle, request_ptr, request_size, result_ptr) -> status
```

The 32-byte request contains version/size, an `i64` number, text pointer/size, and output
pointer/capacity. The 32-byte result contains status, flags, returned `i64`, and output byte count.
Pointers name the artifact's own memory and are valid only for that instance.

Each context owns a real Luau state and a compiled package root. Invocation creates a real Luau
thread, passes runtime arguments, and returns the actual Luau number and string results. A
`"gc-boundary"` yield still forces a full collect and resume so `embed_main.luau` can prove
GC-while-suspended; zero yields is success. Any other yield string is a product error. No host
computes expected program behavior.

## JavaScript

[host.mjs](../hosts/js/host.mjs) uses only standard browser APIs and exports asynchronous
`compilePackage` plus synchronous `instantiateArtifact` and `invoke`. Node-specific file and process
transport is confined to the command-line wrappers.
`//:luauc` and `//:embed-js` are thin command-line wrappers around those public functions.

## Wasmtime

`//:embed-wasmtime` independently implements the compiler ABI, SourcePackageV1 encoder, protected
host functions, and invocation ABI in Rust. It provides:

```text
luauc-embed-wasmtime compile-run <compiler> <profile> <pack> \
  <lib> <main> <proto_identity> <userdata_hooks> <number> <text>...
luauc-embed-wasmtime run <artifact> <number> <text>...
```

The product package is four modules: `lib`, `main`, `proto_identity`, and `userdata_hooks`.

`embed.vec2` is the published userdata contract. `.Unit` normalizes `(x, y)` by Euclidean
length (zero length becomes `(0, 0)`). `:Mark(bag)` writes the receiver into `bag[1]` and
returns the seed's first payload component. Frontend hooks, the pinned interpreter, and the
embed pack implement that contract identically. Observe it as `seed:Mark + unit:Mark` so a
zero Unit cannot hide behind `seed:Mark` alone.

The parity gate reuses one compiled Wasmtime `Module` but creates fresh compiler instances for repeat
compilation. It compares the artifact digest and every runtime result with JavaScript, then compares
the same result transcript with a separately linked pinned Luau interpreter. The interpreter exists
only as differential evidence and is not reachable from `luauc.wasm`, a runtime pack, or an output.

# Compiler WebAssembly ABI v1

`luauc.wasm` is a core WebAssembly module with no imports. It exports only:

```text
memory
luauc_v1_describe(result_ptr) -> status
luauc_v1_alloc(size) -> pointer
luauc_v1_dealloc(pointer, size)
luauc_v1_context_create(profile_ptr, profile_size, pack_ptr, pack_size, result_ptr) -> status
luauc_v1_context_destroy(context) -> status
luauc_v1_compile(context, request_ptr, request_size, result_ptr) -> status
luauc_v1_result_free(result_ptr)
```

All integers and structures use little-endian wasm32 layout. Input and result ranges must be live,
bounded, and non-overlapping where required. A successful context copies and owns the profile and
pack; the caller may immediately free its input buffers.

## Status values

| Value | Meaning |
| ---: | --- |
| 0 | success |
| 1 | invalid scalar/range argument |
| 2 | invalid request, profile, or pack |
| 3 | frontend/source failure |
| 4 | unsupported or invalid backend graph |
| 5 | link or final-module failure |
| 6 | resource ceiling exceeded |
| 7 | invalid or stale context handle |

## Description (32 bytes)

Eight `u32` fields: ABI version, description size, context-result size, compile-result size, maximum
live contexts, maximum profile bytes, maximum pack bytes, and zero reserved. The current ceilings are
8 contexts, 256 KiB profiles, and 32 MiB packs.

## Context result (72 bytes)

| Offset | Field |
| ---: | --- |
| 0 | `u32 handle` |
| 4 | `u32 status` |
| 8 | `u8 runtime_profile_sha256[32]` |
| 40 | `u8 runtime_pack_sha256[32]` |

## Compile result (208 bytes)

| Offset | Field |
| ---: | --- |
| 0 | artifact pointer and size (`u32`, `u32`) |
| 8 | diagnostic pointer and size (`u32`, `u32`) |
| 16 | status and zero reserved (`u32`, `u32`) |
| 24 | request ID (16 bytes) |
| 40 | runtime-profile SHA-256 |
| 72 | runtime-pack SHA-256 |
| 104 | package-manifest SHA-256 |
| 136 | generated-object SHA-256 |
| 168 | final-artifact SHA-256 |
| 200 | generated function count (`u32`) |
| 204 | generated data bytes (`u32`) |

`luauc_v1_result_free` releases artifact and diagnostic allocations and zeros the result. Call it
exactly once for every initialized compile-result buffer, including failed compilations. Caller-owned
buffers are released separately with `luauc_v1_dealloc(pointer, original_size)`.

Malformed operations do not poison the instance: after every rejected request/profile/pack/source in
the conformance corpus, a valid compile through the same compiler instance must reproduce the prior
artifact bytes.

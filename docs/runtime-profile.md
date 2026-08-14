# RuntimeProfileV1 and normalized packs

A runtime profile is explicit compiler input. It names and types the host imports, retained exports,
generated-code helper symbols, semantic export roles, feature limits, memory/table ceilings, and
identity digests for one normalized runtime pack. The compiler contains no default pack bytes.

## Canonical profile

`RuntimeProfileV1` begins with the 320-byte `LUACRP1\0` header. It carries feature and memory/table
limits, canonical record offsets/counts/sizes, the profile ID, and SHA-256 identities for the Luau
pin, generated runtime ABI, object contract, pack build, and license inventory. It is followed by:

- sorted function host-import records `(module, name, type index, kind)`;
- sorted retained-export records `(name, kind, optional role)`;
- sorted generated runtime-symbol records `(name, type index, function kind)`;
- role-sorted binding records `(name, role, kind)`;
- one canonical UTF-8 string table.

Profiles are limited to 256 KiB. Unknown kinds/roles, duplicate or unsorted entries, noncanonical
offsets, malformed strings, nonzero reserved bytes, and inconsistent resource limits are rejected.

Required roles bind the program pointer, generated data arena/capacity, memory, protected dispatcher,
allocator/deallocator, context create/destroy, invocation function, and initializer. Linker policy is
derived from these bindings; it does not hardcode the provider's public names or import module.

## Pack

The pack is a valid core Wasm module ending in exactly one `luauc.runtime.v1` custom section whose
payload is byte-identical to the supplied profile. The compiler validates its complete structure,
imports, exports, types, memory/table limits, generated runtime symbols, arena, and declared features
before creating a context.

The pack builder takes the strict runtime plus provider-owned adapters and policy, produces the raw
Wasm module, derives its type/symbol/resource facts, emits the canonical profile, and appends that
profile as the pack manifest. Consumers never patch the manifest after linking.

`@luauc//profiles:defs.bzl` exports `luauc_runtime_profile`. Its input policy has version, profile ID,
semantic role bindings, and optional additional retained exports. Every required role is present
exactly once, its export kind and retention are fixed by the schema, and unknown fields fail closed.
Host imports, function types, memory/table limits, generated-runtime symbols, pack identity, and
license inventory are derived from the linked raw pack and declared inputs rather than duplicated in
consumer build rules.

`embed-v1` and `embed-alt-v1` are independently constructed packs with distinct host namespaces. The
same `luauc.wasm` compiles the same source through both without selecting another backend.

## Protected calls

The runtime-facing ABI is neutral:

```c
int luauc_runtime_v1_protected_call(void (*callback)(void *), void *context);
_Noreturn void luauc_runtime_v1_raise(int status);
```

`embed-v1` realizes this through two declared host functions, `protected_call` and `set_throw`, plus
the manifest-bound protected dispatcher export. Other profiles may use another mechanism only if it
preserves nested errors, protected calls, coroutine yield/resume, and recovery.

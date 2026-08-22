# luauc

`luauc` is a strict Luau-to-WebAssembly compiler. It accepts a closed Luau source package plus an
explicit runtime profile and pack, then emits one deterministic WebAssembly module containing
generated code for every reachable Luau function and the real pinned Luau runtime it needs.

The compiler is itself a zero-import WebAssembly capability. It has no built-in operating-system,
filesystem, syscall, package, or host namespace. Runtime libraries, imports, exports, protected
calls, entry conventions, and resource ceilings come from validated profile/pack inputs.

## Build

Requirements are Bazel 9.2.0 (pinned by `.bazelversion`) and a supported Node.js runtime. Bazel
downloads the pinned Luau 0.725 source archive and all toolchains. Set the Bazel output root and
Zig compiler cache in ignored `user.bazelrc`. Do not put those caches under `/tmp`.

```bash
bazel build //compiler:compiler_wasm \
  //profiles/embed:embed_v1_pack_files \
  //:luauc //:embed-js //:embed-wasmtime
```

The portable compiler is `bazel-bin/compiler/luauc.wasm`. The reference profile and pack are
`bazel-bin/profiles/embed/embed_v1.profile` and `embed_v1.pack.wasm`.

## Compile a package

Module names are logical package IDs, not filesystem paths. This compiles the included natural
four-module package (`lib`, `main`, `proto_identity`, `userdata_hooks`):

```bash
bazel run //:luauc -- compile \
  --compiler bazel-bin/compiler/luauc.wasm \
  --profile bazel-bin/profiles/embed/embed_v1.profile \
  --pack bazel-bin/profiles/embed/embed_v1.pack.wasm \
  --output /tmp/program.wasm \
  --entry main \
  --inline-plan proto_identity:2:0:0 \
  lib=conformance/sources/embed_lib.luau \
  main=conformance/sources/embed_main.luau \
  proto_identity=conformance/sources/proto_identity.luau \
  userdata_hooks=conformance/sources/userdata_hooks.luau
```

Run that exact artifact in either reference host:

```bash
bazel run //:embed-js -- /tmp/program.wasm 7 beta
bazel run //:embed-wasmtime -- run /tmp/program.wasm 7 beta
```

Both print the pinned-interpreter transcript:

```text
result=7|beta|641|beta:8:2/1/11:missing
```

The example exercises static modules, closures and calls, protected errors, tables, strings,
`ipairs`, nested coroutine yield/resume, an outer compiled suspension, full GC while suspended,
proto identity, and the published userdata hook. The same compiled bytes run over multiple inputs
and are differentially checked against pinned Luau.

## Bazel dependency

Consumers can load `luauc_package` from `@luauc//bazel:defs.bzl` and supply either the reference
profile or their own validated profile and normalized pack:

```starlark
load("@luauc//bazel:defs.bzl", "luauc_package")

luauc_package(
    name = "program",
    modules = {
        "lib": "lib.luau",
        "main": "main.luau",
    },
    entry = "main",
)
```

The default profile is `embed-v1`; `runtime_profile` and `runtime_pack` are explicit rule arguments
when a consumer owns a different embedding contract.

Consumers build a provider-owned pack with the public strict-runtime components and derive its
manifest through `luauc_runtime_profile`:

```starlark
load("@luauc//profiles:defs.bzl", "luauc_runtime_profile")

luauc_runtime_profile(
    name = "product_runtime",
    raw_pack = ":product_runtime_raw",
    policy = "runtime_profile.json",
)
```

The JSON policy binds the fixed semantic roles to exports actually present in the linked raw pack.
The builder derives imports, types, limits, generated-runtime symbols, identities, and the normalized
pack manifest from those bytes; it does not select a provider namespace or entrypoint.

## Pinned Luau components

`luauc` is the sole pin and patch authority for its Luau distribution. Downstream interpreter and
analysis products consume stable component archives instead of addressing the private `@luau`
repository or compiling its source set themselves:

- `@luauc//luau:interpreter_wasm32_wasi`
- `@luauc//luau:analysis_wasm32_wasi`

Each C++ translation unit is an independent Bazel action; luauc assembles the resulting Wasm objects
into one deterministic archive per component. The analysis component owns its interpreter-component
link dependency, so downstream analyzers consume `analysis_wasm32_wasi` without reconstructing Luau's
internal archive order. Both compiled components expose Luau's public C API with C linkage. Source and
header facades remain available for consumers targeting another toolchain:

- `@luauc//luau:interpreter_sources`
- `@luauc//luau:interpreter_headers`
- `@luauc//luau:interpreter_header_files`
- `@luauc//luau:analysis_sources`
- `@luauc//luau:analysis_headers`
- `@luauc//luau:analysis_header_files`

The facades carry pin-sensitive source classification. Public neutral patch headers carry the
interpreter exception boundary, while the analysis header set carries the no-exception/threading
shim. Consumers still own executable entrypoints, protected-call providers, effects, packaging, and
installation.

The source facades preserve the same disjoint ownership, preventing a consumer from compiling the
interpreter twice under different component policies.

Rules that compile the interpreter use `@luauc//runtime:runtime_patch_incs` for include paths and
`@luauc//runtime:runtime_patch_headers` for declared header inputs. Keeping these targets separate
prevents Zig from treating the C++ error-channel template as a C `@cImport` root.

## Contracts

- [Architecture](docs/architecture.md)
- [Compiler ABI](docs/compiler-abi.md)
- [Source package](docs/source-package.md)
- [Runtime profiles and packs](docs/runtime-profile.md)
- [JavaScript and Wasmtime embedding](docs/embedding.md)

Project-owned code is Apache-2.0. The pinned Luau distribution retains its upstream license; see
[NOTICE](NOTICE).

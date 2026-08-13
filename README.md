# luauc

`luauc` is a strict Luau-to-WebAssembly compiler. It accepts a closed Luau source package plus an
explicit runtime profile and pack, then emits one deterministic WebAssembly module containing
generated code for every reachable Luau function and the real pinned Luau runtime it needs.

The compiler is itself a zero-import WebAssembly capability. It has no built-in operating-system,
filesystem, syscall, package, or host namespace. Runtime libraries, imports, exports, protected
calls, entry conventions, and resource ceilings come from validated profile/pack inputs.

## Build

Requirements are Bazel 9.2.0 (pinned by `.bazelversion`) and a supported Node.js runtime. Bazel
downloads the pinned Luau 0.725 source archive and all toolchains.

```bash
bazel build //compiler:compiler_wasm \
  //profiles/embed:embed_v1_pack_files \
  //:luauc //:embed-js //:embed-wasmtime
```

The portable compiler is `bazel-bin/compiler/luauc.wasm`. The reference profile and pack are
`bazel-bin/profiles/embed/embed_v1.profile` and `embed_v1.pack.wasm`.

## Compile a package

Module names are logical package IDs, not filesystem paths. This compiles the included natural
two-module package:

```bash
bazel run //:luauc -- compile \
  --compiler bazel-bin/compiler/luauc.wasm \
  --profile bazel-bin/profiles/embed/embed_v1.profile \
  --pack bazel-bin/profiles/embed/embed_v1.pack.wasm \
  --output /tmp/program.wasm \
  --entry main \
  lib=conformance/sources/embed_lib.luau \
  main=conformance/sources/embed_main.luau
```

Run that exact artifact in either reference host:

```bash
bazel run //:embed-js -- /tmp/program.wasm 7 beta
bazel run //:embed-wasmtime -- run /tmp/program.wasm 7 beta
```

Both print:

```text
result=7|beta|76|beta:8
```

The example exercises static modules, closures and calls, protected errors, tables, strings,
`ipairs`, nested coroutine yield/resume, an outer compiled suspension, and full GC while suspended.
The same compiled bytes run over multiple inputs and are differentially checked against pinned Luau.

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

## Contracts

- [Architecture](docs/architecture.md)
- [Compiler ABI](docs/compiler-abi.md)
- [Source package](docs/source-package.md)
- [Runtime profiles and packs](docs/runtime-profile.md)
- [JavaScript and Wasmtime embedding](docs/embedding.md)

Project-owned code is Apache-2.0. The pinned Luau distribution retains its upstream license; see
[NOTICE](NOTICE).

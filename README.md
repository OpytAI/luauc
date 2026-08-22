<div align="center">
  <h1>luauc</h1>

  <p><strong>A compiler from Luau to WebAssembly.</strong></p>

  <p>
    Pass in a closed package of modules and get back one <code>.wasm</code>
    with a Luau runtime already linked in.
  </p>

  <p>
    <img alt="Luau 0.725" src="https://img.shields.io/badge/Luau-0.725-00a2ff">
    <img alt="WebAssembly" src="https://img.shields.io/badge/target-WebAssembly-654ff0">
    <img alt="Hosts: Node and Wasmtime" src="https://img.shields.io/badge/hosts-Node%20%7C%20Wasmtime-43a047">
    <img alt="Built with Bazel" src="https://img.shields.io/badge/build-Bazel-43a047">
  </p>

  <p>
    <a href="#why-luauc">Why luauc</a> ·
    <a href="#first-program">First program</a> ·
    <a href="#capabilities">Capabilities</a> ·
    <a href="#build">Build</a> ·
    <a href="#docs">Docs</a>
  </p>
</div>

---

## Why luauc

People usually run Luau by shipping source or bytecode and letting a host
virtual machine interpret it. That works until the VM on the machine is not
the one you tested.

luauc compiles the program ahead of time. You hand it every module up front —
if something `require`s `mathlib`, `mathlib` has to be in the package — and a
copy of the Luau VM already built as WebAssembly. The compiler lowers your
functions and links that VM into the same module. Node, a browser, or
Wasmtime can load the file and call in.

The `.wasm` is not a new language. It is ordinary Luau, compiled, sitting next
to a pinned runtime.

## First program

Two files. The host calls the function `main` returns, and passes a number and
a string.

`examples/first/mathlib.luau`:

```luau
return function(n)
    return n * 7 + 10
end
```

`examples/first/main.luau`:

```luau
local calc = require("mathlib")

return function(n, text)
    local result = calc(n)
    return result, text .. ":" .. tostring(result)
end
```

With `n = 5` that is `5 * 7 + 10`, so `45`, plus a string built from `text`.

```bash
bazel build //examples/first:program //:embed-js
bazel run //:embed-js -- "$PWD/bazel-bin/examples/first/program.wasm" 5 hi
```

```text
result=5|hi|45|hi:45
```

The same file runs under `//:embed-wasmtime`. Almost all of the bytes are the
VM. The Luau here is a few dozen characters; luauc is how you ship it, not how
you make it small.

## Capabilities

- Compiles a closed package: every `require` is resolved before you run.
- Emits one module, with the runtime linked in.
- Repeats the same bytes when the compiler, package, and runtime inputs match.
- Reference hosts in Node (`//:embed-js`) and Wasmtime (`//:embed-wasmtime`).
- A Bazel rule, `luauc_package`, if you want the compile on the graph.

## Build

Bazel 9.2.0 (see `.bazelversion`) and a Node.js runtime. Bazel fetches Luau
0.725 and the toolchains. Put the Bazel output root and Zig cache in ignored
`user.bazelrc` — not under `/tmp`.

```bash
bazel build //examples/first:program \
  //:luauc //:embed-js //:embed-wasmtime
```

`bazel-bin/compiler/luauc.wasm` is the compiler. The reference runtime is
`embed_v1`: `bazel-bin/profiles/embed/embed_v1.profile` and
`embed_v1.pack.wasm`.

`examples/first` is the tutorial. `examples/embed` is the conformance package
(closures, errors, coroutines, GC, userdata).

### CLI

Module names are logical IDs, not paths:

```bash
bazel run //:luauc -- compile \
  --compiler bazel-bin/compiler/luauc.wasm \
  --profile bazel-bin/profiles/embed/embed_v1.profile \
  --pack bazel-bin/profiles/embed/embed_v1.pack.wasm \
  --output /tmp/first.wasm \
  --entry main \
  mathlib=examples/first/mathlib.luau \
  main=examples/first/main.luau

bazel run //:embed-js -- /tmp/first.wasm 5 hi
```

### From another Bazel repo

```starlark
load("@luauc//bazel:defs.bzl", "luauc_package")

luauc_package(
    name = "program",
    modules = {
        "mathlib": "mathlib.luau",
        "main": "main.luau",
    },
    entry = "main",
)
```

That uses `embed-v1`. Pass `runtime_profile` and `runtime_pack` if you own a
different embedding. `luauc_runtime_profile` in `@luauc//profiles:defs.bzl`
builds a pack from a policy file.

Interpreter and analysis archives, if you need Luau without compiling it
yourself, are `@luauc//luau:interpreter_wasm32_wasi` and
`@luauc//luau:analysis_wasm32_wasi`. The docs below cover the rest.

## Docs

| Document | What it covers |
| --- | --- |
| [`docs/architecture.md`](docs/architecture.md) | Compilation path and ownership |
| [`docs/compiler-abi.md`](docs/compiler-abi.md) | Compiler ABI |
| [`docs/source-package.md`](docs/source-package.md) | Closed source package |
| [`docs/runtime-profile.md`](docs/runtime-profile.md) | Profiles and packs |
| [`docs/embedding.md`](docs/embedding.md) | JavaScript and Wasmtime hosts |

Apache-2.0 for project code. Luau keeps its own license; see [NOTICE](NOTICE).

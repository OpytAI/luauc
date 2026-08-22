<div align="center">
  <h1>luauc</h1>

  <p><strong>Compile Luau to one WebAssembly file, runtime included.</strong></p>

  <p>
    You write ordinary Luau. luauc emits a single <code>.wasm</code> that already<br>
    contains a pinned Luau VM. A host loads that file. There is no interpreter to install.
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

Luau is usually shipped as source or bytecode. A host process then runs an
interpreter or a JIT. The VM on the machine has to match what you tested.

luauc is a strict ahead-of-time compiler:

- You give it a **closed** package of Luau modules. Every `require` must be
  listed. Nothing is loaded from the network or the filesystem at run time.
- You also give it a **runtime pack** (a pinned Luau VM, already compiled to
  WebAssembly) and a **runtime profile** (which of that VM’s symbols the host
  must keep).
- It emits **one** `.wasm` file that contains your compiled program *and* that
  pinned runtime.

A host (Node, a browser, Wasmtime, an embedder) instantiates that module and
calls into it. There is no separate Luau interpreter to install.

In one sentence: **luauc turns a closed Luau package into a single,
deterministic WebAssembly artifact with a real Luau runtime fused inside.**

1. **Write Luau, not WebAssembly.** Modules and `require` are ordinary Luau.
2. **The package must be closed.** The compiler sees the whole graph.
3. **The VM is an input, not a surprise.** Profile plus pack pin the runtime
   you ship.
4. **One `.wasm` out.** Your code and the runtime share one linear memory.

## First program

Two files. That is the whole program. The embed host passes a number and a
string into the entry function.

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

A module’s top-level return value is what `require` yields. `main` returns the
function the host will call. Given `n = 5` it computes `5 * 7 + 10` and returns
`45` plus a string.

Build the artifact, then run it:

```bash
bazel build //examples/first:program //:embed-js
bazel run //:embed-js -- "$PWD/bazel-bin/examples/first/program.wasm" 5 hi
```

```text
result=5|hi|45|hi:45
```

The same bytes run under `//:embed-wasmtime`. Almost all of the file is the
pinned VM. The Luau source is a few dozen characters. luauc does not make Luau
small by itself — it makes Luau *shippable* as one pinned WebAssembly module.

| Term | Meaning |
|------|---------|
| **Module** | A Luau source file identified by a logical name (`mathlib`, `main`), not a path. |
| **Package** | A finite map from module names to source. Closed: every `require` resolves inside it. |
| **Entry** | The module whose top-level value is the host-callable function. |
| **Runtime pack** | A prebuilt WebAssembly blob holding the Luau VM and a small embed API. |
| **Runtime profile** | Which pack exports to keep, and which slots your program replaces. |
| **Artifact** | The single `.wasm` you get: pack plus compiled Luau, linked together. |

## Capabilities

- **Closed packages** — every reachable function is compiled; `require` is
  resolved at compile time.
- **Fused runtime** — the output is one module, not “bytecode plus a VM to find
  later.”
- **Deterministic artifacts** — identical compiler, profile, pack, and package
  produce identical bytes.
- **Reference hosts** — Node (`//:embed-js`) and Wasmtime (`//:embed-wasmtime`)
  compile and invoke with the same ABI.
- **Bazel rule** — `luauc_package` turns a module map into that `.wasm`.

## Build

Requirements are Bazel 9.2.0 (pinned by `.bazelversion`) and a supported
Node.js runtime. Bazel downloads the pinned Luau 0.725 source archive and all
toolchains. Set the Bazel output root and Zig compiler cache in ignored
`user.bazelrc`. Do not put those caches under `/tmp`.

```bash
bazel build //examples/first:program \
  //:luauc //:embed-js //:embed-wasmtime
```

The portable compiler is `bazel-bin/compiler/luauc.wasm`. The reference profile
and pack are `bazel-bin/profiles/embed/embed_v1.profile` and
`embed_v1.pack.wasm`.

The four-module embed package under `examples/embed` is the conformance gate
(closures, errors, coroutines, GC while suspended, userdata). Use
`examples/first` to learn the pipeline.

### Compile from the CLI

Module names are logical IDs, not filesystem paths:

```bash
bazel run //:luauc -- compile \
  --compiler bazel-bin/compiler/luauc.wasm \
  --profile bazel-bin/profiles/embed/embed_v1.profile \
  --pack bazel-bin/profiles/embed/embed_v1.pack.wasm \
  --output /tmp/first.wasm \
  --entry main \
  mathlib=examples/first/mathlib.luau \
  main=examples/first/main.luau
```

```bash
bazel run //:embed-js -- /tmp/first.wasm 5 hi
```

### Bazel dependency

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

The default profile is `embed-v1`. Pass `runtime_profile` and `runtime_pack`
when you own a different embedding contract. Build a provider-owned pack with
`luauc_runtime_profile` from `@luauc//profiles:defs.bzl`.

Downstream interpreter and analysis products consume stable component archives
instead of compiling Luau themselves: `@luauc//luau:interpreter_wasm32_wasi`
and `@luauc//luau:analysis_wasm32_wasi`. Source and header facades live next to
those targets. Details are in the docs below.

## Docs

| Document | What it covers |
| --- | --- |
| [`docs/architecture.md`](docs/architecture.md) | Compilation path and ownership |
| [`docs/compiler-abi.md`](docs/compiler-abi.md) | Compiler ABI |
| [`docs/source-package.md`](docs/source-package.md) | Closed source package |
| [`docs/runtime-profile.md`](docs/runtime-profile.md) | Profiles and packs |
| [`docs/embedding.md`](docs/embedding.md) | JavaScript and Wasmtime hosts |

Project-owned code is Apache-2.0. The pinned Luau distribution retains its
upstream license; see [NOTICE](NOTICE).

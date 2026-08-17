load("@rules_zig//zig:defs.bzl", "zig_library")


def backend_emit_library(name, deps = []):
    """Defines one independently-addressable semantic lowering family."""
    zig_library(
        name = name,
        main = name + ".zig",
        import_name = "luauc_backend_emit_" + name,
        visibility = ["//compiler/backend:__subpackages__"],
        deps = deps + [
            "//compiler/ir:frontend_snapshot_v1",
            "//compiler/model:model",
            "//compiler/model:runtime_abi",
            "//compiler/wasm:object",
        ],
    )

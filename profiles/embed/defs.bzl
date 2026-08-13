load("@rules_zig//zig:defs.bzl", "zig_binary", "zig_configure_binary")

def raw_pack(name, host_module, exports):
    zig_binary(
        name = name + "_raw",
        main = "provider_root.zig",
        csrcs = [
            "program_placeholder.c",
            "provider_bridge.c",
            "provider_entry.c",
            "wasi_stubs.c",
        ],
        copts = [
            "-DLUAUC_EMBED_HOST_MODULE=\"%s\"" % host_module,
            "-fno-exceptions",
            "-fno-rtti",
        ],
        extra_srcs = [
            "//runtime:runtime_incs",
            "@luau//:interp_all_hdrs",
        ],
        linkopts = [
            "-lc",
            "-lc++",
            "-fno-entry",
            "--initial-memory=67108864",
            "--max-memory=268435456",
        ] + ["--export=" + symbol for symbol in exports],
        deps = [
            "//runtime:runtime_abi",
            "//runtime:runtime_archive_raw",
            "//runtime:runtime_incs",
            "@luau//:interp_incs",
        ],
        tags = ["manual"],
    )
    zig_configure_binary(
        name = name,
        actual = ":" + name + "_raw",
        mode = "release_small",
        target = "//platforms:wasm32_wasi",
        threaded = "single",
    )

"""Pin-owned compilation of Luau C++ components into deterministic archives."""

load("//bazel:cc.bzl", "cc_object_archive", "zig_cxx_object")

def luauc_cpp_archive(
        name,
        srcs,
        copts,
        extra_srcs,
        deps,
        visibility = None,
        tags = None):
    """Compiles each C++ translation unit independently and bundles the resulting archives."""
    if not srcs:
        fail("luauc_cpp_archive requires at least one translation unit")

    objects = []
    unit_tags = (tags or []) + ["manual"]
    for index, source in enumerate(sorted(srcs)):
        unit = "%s_unit_%d" % (name, index)
        zig_cxx_object(
            name = unit,
            src = source,
            target = "wasm32-wasi",
            copts = [
                "-Oz",
                "-DNDEBUG",
                "-std=c++17",
            ] + copts,
            extra_srcs = extra_srcs,
            deps = deps,
            tags = unit_tags,
            visibility = ["//visibility:private"],
        )
        objects.append(":" + unit)

    cc_object_archive(
        name = name,
        objects = objects,
        deps = deps,
        tags = tags or [],
        visibility = visibility,
    )

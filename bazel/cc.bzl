"""Small C/C++ providers consumed by rules_zig without a separate C++ toolchain."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

def _cc_headers_impl(ctx):
    includes = [
        paths.normalize(paths.join(ctx.label.workspace_root, ctx.label.package, directory))
        for directory in ctx.attr.includes
    ]
    return [
        DefaultInfo(files = depset(ctx.files.hdrs)),
        CcInfo(compilation_context = cc_common.create_compilation_context(
            headers = depset(ctx.files.hdrs),
            includes = depset(includes),
        )),
    ]

cc_headers = rule(
    implementation = _cc_headers_impl,
    attrs = {
        "hdrs": attr.label_list(allow_files = True),
        "includes": attr.string_list(),
    },
)

def _cc_object_impl(ctx):
    obj = ctx.file.obj
    return [
        DefaultInfo(files = depset([obj])),
        CcInfo(linking_context = cc_common.create_linking_context(
            linker_inputs = depset([cc_common.create_linker_input(
                owner = ctx.label,
                user_link_flags = [obj.path],
                additional_inputs = depset([obj]),
            )]),
        )),
    ]

cc_object = rule(
    implementation = _cc_object_impl,
    attrs = {"obj": attr.label(allow_single_file = True)},
)

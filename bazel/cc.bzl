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

def _zig_executable(ctx):
    zigtoolchaininfo = ctx.toolchains["@rules_zig//zig:toolchain_type"].zigtoolchaininfo
    zig = zigtoolchaininfo.zig_exe.file
    if zig == None:
        fail("a hermetic Zig toolchain is required")
    return zig, zigtoolchaininfo

def _zig_cxx_object_impl(ctx):
    zig, zigtoolchaininfo = _zig_executable(ctx)
    source = ctx.file.src
    output = ctx.actions.declare_file(ctx.label.name + ".o")

    cc_info = cc_common.merge_cc_infos(cc_infos = [dep[CcInfo] for dep in ctx.attr.deps])
    compilation = cc_info.compilation_context
    args = ctx.actions.args()
    args.add("-target")
    args.add(ctx.attr.target)
    args.add_all(ctx.attr.copts)
    args.add_all(compilation.defines, format_each = "-D%s")
    args.add_all(compilation.includes, format_each = "-I%s")
    args.add_all(compilation.quote_includes, format_each = "-I%s")
    args.add_all(compilation.system_includes, before_each = "-isystem")
    args.add("-c")
    args.add(source)
    args.add("-o")
    args.add(output)

    tool_inputs = [zigtoolchaininfo.validation]
    if zigtoolchaininfo.zig_lib.file != None:
        tool_inputs.append(zigtoolchaininfo.zig_lib.file)
    ctx.actions.run(
        executable = zig,
        arguments = ["c++", args],
        env = {
            "ZIG_GLOBAL_CACHE_DIR": zigtoolchaininfo.zig_cache,
            "ZIG_LOCAL_CACHE_DIR": zigtoolchaininfo.zig_cache,
        },
        inputs = depset(
            direct = [source] + ctx.files.extra_srcs + tool_inputs,
            transitive = [compilation.headers],
        ),
        outputs = [output],
        tools = [zig],
        mnemonic = "ZigCxxCompile",
        progress_message = "Compiling C++ translation unit %{label}",
    )
    return [DefaultInfo(files = depset([output]))]

zig_cxx_object = rule(
    implementation = _zig_cxx_object_impl,
    attrs = {
        "src": attr.label(allow_single_file = [".cc", ".cpp", ".cxx"]),
        "copts": attr.string_list(),
        "extra_srcs": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [CcInfo]),
        "target": attr.string(mandatory = True),
    },
    toolchains = ["@rules_zig//zig:toolchain_type"],
)

def _cc_object_archive_impl(ctx):
    objects = ctx.files.objects
    if not objects:
        fail("cc_object_archive requires at least one object")

    zig, _ = _zig_executable(ctx)

    output = ctx.actions.declare_file("lib%s.a" % ctx.label.name)
    args = ctx.actions.args()
    args.add("rcs")
    args.add(output)
    args.add_all(objects)
    ctx.actions.run(
        executable = zig,
        arguments = ["ar", args],
        inputs = objects,
        outputs = [output],
        tools = [zig],
        mnemonic = "ZigArchiveBundle",
        progress_message = "Bundling C++ component %{label}",
    )

    own = CcInfo(linking_context = cc_common.create_linking_context(
        linker_inputs = depset([cc_common.create_linker_input(
            owner = ctx.label,
            user_link_flags = [output.path],
            additional_inputs = depset([output]),
        )]),
    ))
    return [
        DefaultInfo(files = depset([output])),
        cc_common.merge_cc_infos(cc_infos = [own] + [dep[CcInfo] for dep in ctx.attr.deps]),
    ]

cc_object_archive = rule(
    implementation = _cc_object_archive_impl,
    attrs = {
        "objects": attr.label_list(allow_files = [".o"]),
        "deps": attr.label_list(providers = [CcInfo]),
    },
    toolchains = ["@rules_zig//zig:toolchain_type"],
)

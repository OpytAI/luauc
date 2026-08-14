"""Public construction rule for consumer-owned luauc runtime profiles and packs."""

_PACK_BUILDER = Label("//profiles:pack_builder")
_RUNTIME_ABI = Label("//runtime:abi_v1.zig")
_OBJECT_CONTRACT = Label("//compiler/wasm:object.zig")
_DEFAULT_LICENSES = [
    Label("//:LICENSE"),
    Label("//:NOTICE"),
    Label("//third_party/luau:LICENSE.txt"),
    Label("//third_party/luau:lua_LICENSE.txt"),
]

def luauc_runtime_profile(
        name,
        raw_pack,
        policy,
        licenses = [],
        visibility = None,
        tags = None):
    """Derives a canonical RuntimeProfileV1 and normalized pack from a linked raw pack.

    The raw pack and policy are consumer-owned. The policy binds semantic roles to
    actual raw-pack exports; no provider namespace or entrypoint is selected here.
    """
    profile = name + ".profile"
    pack = name + ".pack.wasm"
    license_inputs = _DEFAULT_LICENSES + licenses
    native.genrule(
        name = name + "_pack_files",
        srcs = [
            raw_pack,
            policy,
            _RUNTIME_ABI,
            _OBJECT_CONTRACT,
        ] + license_inputs,
        outs = [profile, pack],
        cmd = "BAZEL_BINDIR=. $(execpath %s) $(location %s) $(location %s) $(location %s) $(location %s) $(location %s) $(location %s) %s" % (
            _PACK_BUILDER,
            raw_pack,
            profile,
            pack,
            policy,
            _RUNTIME_ABI,
            _OBJECT_CONTRACT,
            " ".join(["$(location %s)" % item for item in license_inputs]),
        ),
        tools = [_PACK_BUILDER],
        tags = tags or [],
    )
    native.filegroup(
        name = name + "_profile",
        srcs = [profile],
        visibility = visibility,
    )
    native.filegroup(
        name = name + "_pack",
        srcs = [pack],
        visibility = visibility,
    )

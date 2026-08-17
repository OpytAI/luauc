"""Public rules for compiling closed Luau packages with an explicit runtime profile."""

load("@aspect_rules_js//js:defs.bzl", "js_run_binary")

_CLI = Label("//hosts/js:luauc")
_COMPILER = Label("//compiler:compiler_wasm")
_EMBED_PROFILE = Label("//profiles/embed:embed_v1_profile")
_EMBED_PACK = Label("//profiles/embed:embed_v1_pack")

def _module_name(name):
    if not name or name.startswith("/") or name.endswith("/") or ".." in name:
        fail("invalid canonical Luau module name: %r" % name)
    for character in name.elems():
        if character not in "abcdefghijklmnopqrstuvwxyz0123456789_-/.":
            fail("invalid canonical Luau module name: %r" % name)
    return name

def luauc_package(
        name,
        modules,
        entry,
        inline_plans = None,
        compiler = _COMPILER,
        runtime_profile = _EMBED_PROFILE,
        runtime_pack = _EMBED_PACK,
        out = None,
        visibility = None,
        tags = None):
    """Compiles a canonical module-name-to-source-label map into one strict-AOT Wasm module."""
    if not modules:
        fail("luauc_package requires at least one module")
    names = sorted([_module_name(module_name) for module_name in modules.keys()])
    if entry not in modules:
        fail("entry module %r is absent" % entry)
    output = out or name + ".wasm"
    sources = [modules[module_name] for module_name in names]
    module_arguments = [
        "%s=$(location %s)" % (module_name, modules[module_name])
        for module_name in names
    ]
    inline_plan_arguments = []
    for plan in inline_plans or []:
        inline_plan_arguments.extend(["--inline-plan", plan])
    js_run_binary(
        name = name,
        tool = _CLI,
        srcs = [compiler, runtime_profile, runtime_pack] + sources,
        outs = [output],
        args = [
            "compile",
            "--compiler",
            "$(execpath %s)" % compiler,
            "--profile",
            "$(execpath %s)" % runtime_profile,
            "--pack",
            "$(execpath %s)" % runtime_pack,
            "--output",
            "$(execpath %s)" % output,
            "--entry",
            entry,
        ] + inline_plan_arguments + module_arguments,
        copy_srcs_to_bin = False,
        env = {"LUAUC_BAZEL_EXECROOT_PATHS": "1"},
        mnemonic = "LuaucCompile",
        progress_message = "Compiling strict-AOT Luau package %{label}",
        visibility = visibility,
        tags = tags or [],
    )

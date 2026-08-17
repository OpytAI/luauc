load("@aspect_rules_js//js:defs.bzl", "js_test")

WASM_LD = "@@emsdk++emscripten_deps+emscripten_bin_linux//:bin/wasm-ld"

def _source_env(name, label):
    return {name: "$(rlocationpath %s)" % label}

COMMON_DATA = [
    "harness.mjs",
    "//compiler/backend:backend_wasm",
    "//frontend:frontend_wasm",
    WASM_LD,
]

COMMON_ENV = {
    "LUAUC_BACKEND_WASM": "$(rlocationpath //compiler/backend:backend_wasm)",
    "LUAUC_FRONTEND_WASM": "$(rlocationpath //frontend:frontend_wasm)",
    "LUAUC_WASM_LD": "$(rlocationpath %s)" % WASM_LD,
}

SOURCE_ENV = {
    "LUAUC_BUFFER_SCALAR_MATRIX_SOURCE": "//conformance/sources:buffer_scalar_matrix",
    "LUAUC_CAPTURED_CALL_SOURCE": "//conformance/sources:captured_call",
    "LUAUC_COMPILED_CALL_SOURCE": "//conformance/sources:compiled_call",
    "LUAUC_DYNAMIC_ARRAY_TABLE_SOURCE": "//conformance/sources:dynamic_array_table",
    "LUAUC_DYNAMIC_HASH_TABLE_SOURCE": "//conformance/sources:dynamic_hash_table",
    "LUAUC_DYNAMIC_STRING_SOURCE": "//conformance/sources:dynamic_string",
    "LUAUC_EMBED_LIB_SOURCE": "//conformance/sources:embed_lib",
    "LUAUC_FAST_BUILTINS_SOURCE": "//conformance/sources:fast_builtins",
    "LUAUC_FORWARDED_CAPTURE_SOURCE": "//conformance/sources:forwarded_capture",
    "LUAUC_GENERIC_ITERATION_SOURCE": "//conformance/sources:generic_iteration",
    "LUAUC_GENERIC_TABLE_SOURCE": "//conformance/sources:generic_table",
    "LUAUC_GLOBAL_STATE_SOURCE": "//conformance/sources:global_state",
    "LUAUC_MIXED_TABLE_SOURCE": "//conformance/sources:mixed_table",
    "LUAUC_MULTI_RESULT_CALL_SOURCE": "//conformance/sources:multi_result_call",
    "LUAUC_PROTO_IDENTITY_SOURCE": "//conformance/sources:proto_identity",
    "LUAUC_RECURSIVE_CALL_SOURCE": "//conformance/sources:recursive_call",
    "LUAUC_REFERENCE_CAPTURE_SOURCE": "//conformance/sources:reference_capture",
    "LUAUC_SILENT_SOURCE": "//conformance/sources:silent_return",
    "LUAUC_SLOW_ADD_SOURCE": "//conformance/sources:slow_add",
    "LUAUC_TABLE_CLONE_APPEND_SOURCE": "//conformance/sources:table_clone_append",
    "LUAUC_TABLE_NAMECALL_SOURCE": "//conformance/sources:table_namecall",
    "LUAUC_USERDATA_HOOKS_SOURCE": "//conformance/sources:userdata_hooks",
    "LUAUC_YIELD_CALL_SOURCE": "//conformance/sources:yield_call",
    "LUAUC_NUMERIC_LOOP_SOURCE": "//conformance/sources:numeric_loop",
    "LUAUC_NATURAL_INTEGER_SOURCE": "//conformance/sources:natural_integer",
    "LUAUC_NATURAL_BIT32_SOURCE": "//conformance/sources:natural_bit32",
    "LUAUC_NATURAL_BUFFER_SOURCE": "//conformance/sources:natural_buffer",
}

def family_js_test(name, entry_point, source_env_keys, extra_data = []):
    data = list(COMMON_DATA) + [entry_point] + list(extra_data)
    env = dict(COMMON_ENV)
    for key in source_env_keys:
        label = SOURCE_ENV[key]
        data.append(label)
        env[key] = "$(rlocationpath %s)" % label
    js_test(
        name = name,
        data = data,
        entry_point = entry_point,
        env = env,
        no_copy_to_bin = [WASM_LD],
        visibility = ["//visibility:public"],
    )

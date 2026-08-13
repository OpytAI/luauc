#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lua_State lua_State;
typedef struct LuaucRuntimeProtoV1 LuaucRuntimeProtoV1;
typedef struct LuaucRuntimeModuleV1 LuaucRuntimeModuleV1;
typedef struct LuaucRuntimeProgramV1 LuaucRuntimeProgramV1;
typedef struct LuaucRuntimeVmConstantV1 LuaucRuntimeVmConstantV1;
typedef struct LuaucRuntimeVmConstantItemV1 LuaucRuntimeVmConstantItemV1;

typedef uint32_t (*LuaucRuntimeFunctionV1)(lua_State *state, const LuaucRuntimeProtoV1 *proto);

enum LuaucRuntimeStatusV1 {
    LUAUC_RUNTIME_V1_OK = 0,
    LUAUC_RUNTIME_V1_UNSUPPORTED_TYPE = 1,
    LUAUC_RUNTIME_V1_INTERNAL_ERROR = 2,
    LUAUC_RUNTIME_V1_YIELDED = 3,
};

enum LuaucRuntimeProtoFlagsV1 {
    LUAUC_AOT_PROTO_V1_ROOT = 1u << 0,
};

enum LuaucRuntimeIdsV1 {
    LUAUC_RUNTIME_V1_NO_ID = UINT32_MAX,
};

enum LuaucRuntimeCountV1 {
    LUAUC_RUNTIME_V1_MULTRET = -1,
};

// Value operands accepted by arithmetic/comparison and generic table fallback helpers. Untagged
// values are VM register indices; the high bit selects an immutable Proto constant and the
// remaining bits carry its constant ID. Proto constant counts are independently bounded to INT_MAX
// by runtime metadata validation, so the two namespaces cannot overlap.
#define LUAUC_AOT_OPERAND_V1_CONSTANT_FLAG UINT32_C(0x80000000)
#define LUAUC_AOT_OPERAND_V1_INDEX_MASK UINT32_C(0x7fffffff)

// These values are identical to FrontendSnapshotV1's VM constant kinds. The strict package
// carries only pointer-free scalar payloads and linear-memory addresses; the runtime constructs
// the real pinned-Luau TValue graph before publishing a closure.
enum LuaucRuntimeVmConstantKindV1 {
    LUAUC_AOT_VM_CONSTANT_V1_NIL = 0,
    LUAUC_AOT_VM_CONSTANT_V1_BOOLEAN = 1,
    LUAUC_AOT_VM_CONSTANT_V1_NUMBER = 2,
    LUAUC_AOT_VM_CONSTANT_V1_VECTOR = 3,
    LUAUC_AOT_VM_CONSTANT_V1_STRING = 4,
    LUAUC_AOT_VM_CONSTANT_V1_INTEGER = 5,
    LUAUC_AOT_VM_CONSTANT_V1_IMPORT = 6,
    LUAUC_AOT_VM_CONSTANT_V1_TABLE = 7,
    LUAUC_AOT_VM_CONSTANT_V1_CLOSURE = 8,
    LUAUC_AOT_VM_CONSTANT_V1_CLASS_SHAPE = 9,
};

struct LuaucRuntimeVmConstantV1 {
    uint8_t kind;
    uint8_t reserved[3];
    uint32_t payload0;
    uint32_t payload1;
    uint32_t payload2;
};

struct LuaucRuntimeVmConstantItemV1 {
    uint32_t key;
    uint32_t value;
};

// Stable AOT helper operations. These values are independent of Luau's internal TMS enum; the
// compiler frontend pin maps upstream TMS values onto this versioned runtime ABI.
enum LuaucRuntimeArithOpV1 {
    LUAUC_AOT_ARITH_V1_ADD = 0,
    LUAUC_AOT_ARITH_V1_SUB = 1,
    LUAUC_AOT_ARITH_V1_MUL = 2,
    LUAUC_AOT_ARITH_V1_DIV = 3,
    LUAUC_AOT_ARITH_V1_IDIV = 4,
    LUAUC_AOT_ARITH_V1_MOD = 5,
    LUAUC_AOT_ARITH_V1_POW = 6,
    LUAUC_AOT_ARITH_V1_UNM = 7,
};

enum LuaucRuntimeCompareOpV1 {
    LUAUC_AOT_COMPARE_V1_EQUAL = 0,
    LUAUC_AOT_COMPARE_V1_LESS = 1,
    LUAUC_AOT_COMPARE_V1_LESS_EQUAL = 2,
};

// Stable capture kinds corresponding to the pinned Luau 0.725 LCT_* bytecode operands.
enum LuaucRuntimeCaptureKindV1 {
    LUAUC_AOT_CAPTURE_V1_VAL = 0,
    LUAUC_AOT_CAPTURE_V1_REF = 1,
    LUAUC_AOT_CAPTURE_V1_UPVAL = 2,
};

// Immutable metadata attached to Proto::execdata by the AOT image initializer. The generated
// function pointer uses the Wasm table index representation selected by the canonical toolchain;
// generated code itself receives this record as linear-memory data and never dereferences Proto.
struct LuaucRuntimeProtoV1 {
    uint32_t abi_version;
    uint32_t struct_size;
    uint8_t layout_sha256[32];
    LuaucRuntimeFunctionV1 entry;
    uint32_t function_id;
    uint32_t parent_id;
    uint32_t flags;
    uint8_t num_params;
    uint8_t nups;
    uint8_t is_vararg;
    uint8_t max_stack_size;
    const LuaucRuntimeVmConstantV1 *constants;
    uint32_t constant_count;
    const LuaucRuntimeVmConstantItemV1 *constant_items;
    uint32_t constant_item_count;
};

// Immutable closed-package module metadata. Module IDs are dense table indices; each root Proto has
// no parent and owns one independently initialized Luau chunk.
struct LuaucRuntimeModuleV1 {
    uint32_t abi_version;
    uint32_t struct_size;
    uint8_t layout_sha256[32];
    uint32_t module_id;
    uint32_t root_proto_id;
    const char *source_name;
    uint32_t source_name_size;
};

// One immutable descriptor covers the closed package's canonical Proto forest. Proto IDs are dense
// global array indices; each module root has no parent and all other parents precede their
// children, so scanning equal parent_id values preserves every snapshot's declared child order.
struct LuaucRuntimeProgramV1 {
    uint32_t abi_version;
    uint32_t struct_size;
    uint8_t layout_sha256[32];
    const LuaucRuntimeProtoV1 *protos;
    uint32_t proto_count;
    uint32_t root_proto_id;
    uint32_t flags;
    const LuaucRuntimeModuleV1 *modules;
    uint32_t module_count;
    uint32_t entry_module_id;
};

enum {
    LUAUC_AOT_ABI_V1 = 1,
    LUAUC_AOT_VM_CONSTANT_V1_SIZE = 16,
    LUAUC_AOT_VM_CONSTANT_ITEM_V1_SIZE = 8,
    LUAUC_AOT_PROTO_V1_SIZE = 76,
    LUAUC_AOT_MODULE_V1_SIZE = 56,
    LUAUC_AOT_PROGRAM_V1_LEGACY_SIZE = 56,
    LUAUC_AOT_PROGRAM_V1_SIZE = 68,
};

extern const uint8_t luauc_runtime_v1_layout_sha256[32];

// Generated-code/runtime surface. Keep it versioned, unmangled, and narrow.
void luauc_runtime_v1_enter(lua_State *state);
void luauc_runtime_v1_finish_yielded_op(lua_State *state);
void luauc_runtime_v1_set_location(lua_State *state, uint32_t line);
uint32_t luauc_runtime_v1_builtin_type_error(lua_State *state, const char *builtin_name,
                                           size_t builtin_name_length, uint32_t argument_index,
                                           uint32_t expected_tag, uint32_t source_register);
double luauc_runtime_v1_builtin_number(lua_State *state, uint32_t source_register);
void luauc_runtime_v1_buffer_bounds_error(lua_State *state);
uint32_t luauc_runtime_v1_exchange_continuation(lua_State *state, uint32_t next);
void luauc_runtime_v1_new_table(lua_State *state, uint32_t destination_register, uint32_t array_count,
                              uint32_t node_count);
void luauc_runtime_v1_new_table_deferred(lua_State *state, uint32_t destination_register,
                                       uint32_t array_count, uint32_t node_count);
void luauc_runtime_v1_check_gc(lua_State *state);
void luauc_runtime_v1_dup_table(lua_State *state, uint32_t destination_register,
                              uint32_t constant_id);
void luauc_runtime_v1_load_constant(lua_State *state, uint32_t destination_register,
                                  uint32_t constant_id);
void luauc_runtime_v1_table_insert_append(lua_State *state, uint32_t table_register,
                                        uint32_t source_register);
void luauc_runtime_v1_set_list(lua_State *state, uint32_t table_register, uint32_t source_start,
                             uint32_t count, uint32_t start_index, uint32_t known_size);
void luauc_runtime_v1_array_set(lua_State *state, uint32_t table_register, uint32_t source_register,
                              uint32_t index);
void luauc_runtime_v1_array_get(lua_State *state, uint32_t destination_register,
                              uint32_t table_register, uint32_t index);
void luauc_runtime_v1_table_set_string(lua_State *state, uint32_t table_register,
                                     uint32_t source_register, const char *key_pointer,
                                     size_t key_length);
void luauc_runtime_v1_table_get_string(lua_State *state, uint32_t destination_register,
                                     uint32_t table_register, const char *key_pointer,
                                     size_t key_length);
void luauc_runtime_v1_namecall_plain(lua_State *state, uint32_t destination_register,
                                   uint32_t source_register, const char *key_pointer,
                                   size_t key_length);
void luauc_runtime_v1_table_set(lua_State *state, uint32_t table_register, uint32_t key_operand,
                              uint32_t source_register);
void luauc_runtime_v1_table_get(lua_State *state, uint32_t destination_register,
                              uint32_t table_register, uint32_t key_operand);
uint32_t luauc_runtime_v1_table_array_set(lua_State *state, uint32_t table_register,
                                        uint32_t one_based_index, uint32_t source_register);
uint32_t luauc_runtime_v1_table_array_get(lua_State *state, uint32_t destination_register,
                                        uint32_t table_register, uint32_t one_based_index);
void luauc_runtime_v1_get_global(lua_State *state, uint32_t destination_register,
                               const char *key_pointer, size_t key_length);
void luauc_runtime_v1_set_global(lua_State *state, uint32_t source_register, const char *key_pointer,
                               size_t key_length);
uint32_t luauc_runtime_v1_check_safe_env(lua_State *state);
int32_t luauc_runtime_v1_fastcall(lua_State *state, uint32_t builtin_id,
                                uint32_t destination_register, uint32_t source_register,
                                uint32_t argument_two, uint32_t argument_three,
                                int32_t result_count, int32_t parameter_count);
uint32_t luauc_runtime_v1_type_name(lua_State *state, uint32_t destination_register,
                                  uint32_t source_register, uint32_t custom_name);
double luauc_runtime_v1_libm(uint32_t builtin_id, double first, double second);
void luauc_runtime_v1_table_len(lua_State *state, uint32_t destination_register,
                              uint32_t table_register);
void luauc_runtime_v1_concat(lua_State *state, uint32_t destination_register, uint32_t source_start,
                           uint32_t count);
void luauc_runtime_v1_do_len(lua_State *state, uint32_t destination_register,
                           uint32_t source_register);
void luauc_runtime_v1_forg_prep(lua_State *state, uint32_t base_register);
void luauc_runtime_v1_forgprep_xnext_fallback(lua_State *state, uint32_t base_register);
uint32_t luauc_runtime_v1_forg_loop(lua_State *state, uint32_t base_register, uint32_t aux);
uint32_t luauc_runtime_v1_forg_loop_call(lua_State *state, uint32_t base_register, uint32_t aux);
uint32_t luauc_runtime_v1_forg_loop_finish(lua_State *state, uint32_t base_register, uint32_t aux);
void *luauc_runtime_v1_new_userdata(lua_State *state, uint32_t byte_size, uint32_t user_tag);
uint32_t luauc_runtime_v1_check_userdata_tag(lua_State *state, const void *userdata_object,
                                           uint32_t expected_tag);
void luauc_runtime_v1_barrier_object(lua_State *state, void *owner, uint32_t source_register);
void luauc_runtime_v1_barrier_table_back(lua_State *state, void *table);
void luauc_runtime_v1_return(lua_State *state, uint32_t source_register, int32_t result_count);
uint32_t luauc_runtime_v1_interrupt(lua_State *state, uint32_t line);
void luauc_runtime_v1_do_arith(lua_State *state, uint32_t destination_register, uint32_t lhs_register,
                             uint32_t rhs_register, uint32_t operation);
uint32_t luauc_runtime_v1_compare_any(lua_State *state, uint32_t lhs_register, uint32_t rhs_register,
                                    uint32_t operation);
void luauc_runtime_v1_dupclosure(lua_State *state, uint32_t destination_register,
                               uint32_t child_proto_id);
void luauc_runtime_v1_newclosure_capture(lua_State *state, uint32_t destination_register,
                                       uint32_t child_proto_id, uint32_t capture_index,
                                       uint32_t capture_kind, uint32_t source_index,
                                       uint32_t check_gc);
void luauc_runtime_v1_get_upvalue(lua_State *state, uint32_t destination_register,
                                uint32_t upvalue_index);
void luauc_runtime_v1_set_upvalue(lua_State *state, uint32_t upvalue_index, uint32_t source_register);
void luauc_runtime_v1_close_upvalues(lua_State *state, uint32_t first_register);
uint32_t luauc_runtime_v1_call(lua_State *state, uint32_t function_register, int32_t parameter_count,
                             int32_t result_count);
void luauc_runtime_v1_prep_varargs(lua_State *state, uint32_t fixed_parameter_count);
void luauc_runtime_v1_get_varargs_fixed(lua_State *state, uint32_t destination_register,
                                      uint32_t result_count);
void luauc_runtime_v1_get_varargs_multret(lua_State *state, uint32_t destination_register);
uint32_t luauc_runtime_v1_require_static(lua_State *state, uint32_t destination_register,
                                       uint32_t target_module_id);
uint32_t luauc_runtime_v1_push_root(lua_State *state, const LuaucRuntimeProtoV1 *metadata,
                                  const char *source, size_t source_size);
uint32_t luauc_runtime_v1_push_program(lua_State *state, const LuaucRuntimeProgramV1 *program,
                                     const char *source, size_t source_size);

#ifdef __cplusplus
}

#if defined(__wasm32__)
static_assert(sizeof(LuaucRuntimeVmConstantV1) == LUAUC_AOT_VM_CONSTANT_V1_SIZE,
              "LuaucRuntimeVmConstantV1 wasm32 layout drift");
static_assert(sizeof(LuaucRuntimeVmConstantItemV1) == LUAUC_AOT_VM_CONSTANT_ITEM_V1_SIZE,
              "LuaucRuntimeVmConstantItemV1 wasm32 layout drift");
static_assert(sizeof(LuaucRuntimeProtoV1) == LUAUC_AOT_PROTO_V1_SIZE,
              "LuaucRuntimeProtoV1 wasm32 layout drift");
static_assert(offsetof(LuaucRuntimeProtoV1, entry) == 40, "LuaucRuntimeProtoV1 entry offset drift");
static_assert(offsetof(LuaucRuntimeProtoV1, num_params) == 56,
              "LuaucRuntimeProtoV1 parameter offset drift");
static_assert(offsetof(LuaucRuntimeProtoV1, constants) == 60,
              "LuaucRuntimeProtoV1 constants offset drift");
static_assert(offsetof(LuaucRuntimeProtoV1, constant_items) == 68,
              "LuaucRuntimeProtoV1 constant items offset drift");
static_assert(sizeof(LuaucRuntimeModuleV1) == LUAUC_AOT_MODULE_V1_SIZE,
              "LuaucRuntimeModuleV1 wasm32 layout drift");
static_assert(offsetof(LuaucRuntimeModuleV1, source_name) == 48,
              "LuaucRuntimeModuleV1 source-name offset drift");
static_assert(sizeof(LuaucRuntimeProgramV1) == LUAUC_AOT_PROGRAM_V1_SIZE,
              "LuaucRuntimeProgramV1 wasm32 layout drift");
static_assert(offsetof(LuaucRuntimeProgramV1, protos) == 40,
              "LuaucRuntimeProgramV1 Proto pointer offset drift");
static_assert(offsetof(LuaucRuntimeProgramV1, modules) == 56,
              "LuaucRuntimeProgramV1 module pointer offset drift");
#endif
#endif

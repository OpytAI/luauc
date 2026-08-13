const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const static_package_v1 = @import("static_package_v1.zig");
const wasm = @import("luauc_wasm_object");

pub const generated_symbol = "luauc_runtime_v1_generated_ir_function";
pub const return_symbol = "luauc_runtime_v1_return";
pub const interrupt_symbol = "luauc_runtime_v1_interrupt";
pub const do_arith_symbol = "luauc_runtime_v1_do_arith";
pub const compare_any_symbol = "luauc_runtime_v1_compare_any";
pub const dupclosure_symbol = "luauc_runtime_v1_dupclosure";
pub const newclosure_capture_symbol = "luauc_runtime_v1_newclosure_capture";
pub const get_upvalue_symbol = "luauc_runtime_v1_get_upvalue";
pub const set_upvalue_symbol = "luauc_runtime_v1_set_upvalue";
pub const close_upvalues_symbol = "luauc_runtime_v1_close_upvalues";
pub const call_symbol = "luauc_runtime_v1_call";
pub const exchange_continuation_symbol = "luauc_runtime_v1_exchange_continuation";
pub const set_location_symbol = "luauc_runtime_v1_set_location";
pub const new_table_symbol = "luauc_runtime_v1_new_table";
pub const new_table_deferred_symbol = "luauc_runtime_v1_new_table_deferred";
pub const check_gc_symbol = "luauc_runtime_v1_check_gc";
pub const load_constant_symbol = "luauc_runtime_v1_load_constant";
pub const dup_table_symbol = "luauc_runtime_v1_dup_table";
pub const table_insert_append_symbol = "luauc_runtime_v1_table_insert_append";
pub const namecall_plain_symbol = "luauc_runtime_v1_namecall_plain";
pub const set_list_symbol = "luauc_runtime_v1_set_list";
pub const array_set_symbol = "luauc_runtime_v1_array_set";
pub const array_get_symbol = "luauc_runtime_v1_array_get";
pub const table_len_symbol = "luauc_runtime_v1_table_len";
pub const concat_symbol = "luauc_runtime_v1_concat";
pub const do_len_symbol = "luauc_runtime_v1_do_len";
pub const forg_prep_symbol = "luauc_runtime_v1_forg_prep";
pub const forg_loop_symbol = "luauc_runtime_v1_forg_loop";
pub const forg_loop_call_symbol = "luauc_runtime_v1_forg_loop_call";
pub const forg_loop_finish_symbol = "luauc_runtime_v1_forg_loop_finish";
pub const forgprep_xnext_fallback_symbol = "luauc_runtime_v1_forgprep_xnext_fallback";
pub const new_userdata_symbol = "luauc_runtime_v1_new_userdata";
pub const check_userdata_tag_symbol = "luauc_runtime_v1_check_userdata_tag";
pub const barrier_object_symbol = "luauc_runtime_v1_barrier_object";
pub const barrier_table_back_symbol = "luauc_runtime_v1_barrier_table_back";
pub const table_set_string_symbol = "luauc_runtime_v1_table_set_string";
pub const table_get_string_symbol = "luauc_runtime_v1_table_get_string";
pub const table_set_symbol = "luauc_runtime_v1_table_set";
pub const table_get_symbol = "luauc_runtime_v1_table_get";
pub const table_array_set_symbol = "luauc_runtime_v1_table_array_set";
pub const table_array_get_symbol = "luauc_runtime_v1_table_array_get";
pub const get_global_symbol = "luauc_runtime_v1_get_global";
pub const set_global_symbol = "luauc_runtime_v1_set_global";
pub const fastcall_symbol = "luauc_runtime_v1_fastcall";
pub const type_name_symbol = "luauc_runtime_v1_type_name";
pub const libm_symbol = "luauc_runtime_v1_libm";
pub const builtin_type_error_symbol = "luauc_runtime_v1_builtin_type_error";
pub const builtin_number_symbol = "luauc_runtime_v1_builtin_number";
pub const buffer_bounds_error_symbol = "luauc_runtime_v1_buffer_bounds_error";
pub const check_safe_env_symbol = "luauc_runtime_v1_check_safe_env";
pub const prep_varargs_symbol = "luauc_runtime_v1_prep_varargs";
pub const get_varargs_fixed_symbol = "luauc_runtime_v1_get_varargs_fixed";
pub const get_varargs_multret_symbol = "luauc_runtime_v1_get_varargs_multret";
pub const require_static_symbol = "luauc_runtime_v1_require_static";
pub const generated_protos_symbol = "luauc_runtime_v1_protos";
pub const generated_modules_symbol = "luauc_runtime_v1_modules";
pub const generated_program_symbol = "luauc_runtime_v1_program";
pub const generated_string_keys_symbol = "luauc_runtime_v1_string_keys";

const aot_abi_version: u32 = 1;
const aot_proto_size: u32 = 76;
const aot_constant_size: u32 = 16;
const aot_constant_item_size: u32 = 8;
const aot_module_size: u32 = 56;
const aot_program_size: u32 = 68;
const aot_proto_root_flag: u32 = 1;
const aot_layout_sha256 = snapshot_v1.production_identity.layout.?;

const status_ok: i32 = 0;
const status_unsupported_type: i32 = 1;
const status_internal_error: i32 = 2;

const ir_cmd_table_len: snapshot_v1.IrCommand = @enumFromInt(98);
const ir_cmd_get_arr_addr: snapshot_v1.IrCommand = @enumFromInt(9);
const ir_cmd_get_slot_node_addr: snapshot_v1.IrCommand = @enumFromInt(10);
const ir_cmd_get_hash_node_addr: snapshot_v1.IrCommand = @enumFromInt(11);
const ir_cmd_new_table: snapshot_v1.IrCommand = @enumFromInt(100);
const ir_cmd_new_userdata: snapshot_v1.IrCommand = @enumFromInt(105);
const ir_cmd_dup_table: snapshot_v1.IrCommand = @enumFromInt(101);
const ir_cmd_table_setnum: snapshot_v1.IrCommand = @enumFromInt(102);
const ir_cmd_try_call_fastgettm: snapshot_v1.IrCommand = @enumFromInt(104);
const ir_cmd_do_len: snapshot_v1.IrCommand = @enumFromInt(124);
const ir_cmd_concat: snapshot_v1.IrCommand = @enumFromInt(128);
const ir_cmd_get_table: snapshot_v1.IrCommand = @enumFromInt(125);
const ir_cmd_set_table: snapshot_v1.IrCommand = @enumFromInt(126);
const ir_cmd_try_num_to_index: snapshot_v1.IrCommand = @enumFromInt(103);
const ir_cmd_check_readonly: snapshot_v1.IrCommand = @enumFromInt(133);
const ir_cmd_check_no_metatable: snapshot_v1.IrCommand = @enumFromInt(134);
const ir_cmd_check_array_size: snapshot_v1.IrCommand = @enumFromInt(136);
const ir_cmd_check_slot_match: snapshot_v1.IrCommand = @enumFromInt(137);
const ir_cmd_check_node_no_next: snapshot_v1.IrCommand = @enumFromInt(138);
const ir_cmd_barrier_table_forward: snapshot_v1.IrCommand = @enumFromInt(149);
const ir_cmd_setlist: snapshot_v1.IrCommand = @enumFromInt(153);
const ir_cmd_fallback_gettableks: snapshot_v1.IrCommand = @enumFromInt(162);
const ir_cmd_fallback_settableks: snapshot_v1.IrCommand = @enumFromInt(163);
const ir_cmd_fallback_getglobal: snapshot_v1.IrCommand = @enumFromInt(160);
const ir_cmd_fallback_setglobal: snapshot_v1.IrCommand = @enumFromInt(161);
const ir_cmd_fallback_namecall: snapshot_v1.IrCommand = @enumFromInt(164);
const ir_cmd_forgloop: snapshot_v1.IrCommand = @enumFromInt(156);
const ir_cmd_forgloop_fallback: snapshot_v1.IrCommand = @enumFromInt(157);
const ir_cmd_forgprep_xnext_fallback: snapshot_v1.IrCommand = @enumFromInt(158);
const ir_cmd_fallback_forgprep: snapshot_v1.IrCommand = @enumFromInt(169);
const ir_cmd_string_len: snapshot_v1.IrCommand = @enumFromInt(99);
const ir_cmd_adjust_stack_to_reg: snapshot_v1.IrCommand = @enumFromInt(118);
const ir_cmd_adjust_stack_to_top: snapshot_v1.IrCommand = @enumFromInt(119);
const ir_cmd_fastcall: snapshot_v1.IrCommand = @enumFromInt(120);
const ir_cmd_invoke_fastcall: snapshot_v1.IrCommand = @enumFromInt(121);
const ir_cmd_check_fastcall_res: snapshot_v1.IrCommand = @enumFromInt(122);
const ir_cmd_invoke_libm: snapshot_v1.IrCommand = @enumFromInt(197);
const ir_cmd_get_type: snapshot_v1.IrCommand = @enumFromInt(198);
const ir_cmd_get_typeof: snapshot_v1.IrCommand = @enumFromInt(199);
const ir_cmd_check_buffer_len: snapshot_v1.IrCommand = @enumFromInt(140);
const ir_cmd_check_userdata_tag: snapshot_v1.IrCommand = @enumFromInt(141);
const ir_cmd_barrier_object: snapshot_v1.IrCommand = @enumFromInt(147);
const ir_cmd_barrier_table_back: snapshot_v1.IrCommand = @enumFromInt(148);
const ir_cmd_buffer_readi8: snapshot_v1.IrCommand = @enumFromInt(201);
const ir_cmd_buffer_readu8: snapshot_v1.IrCommand = @enumFromInt(202);
const ir_cmd_buffer_writei8: snapshot_v1.IrCommand = @enumFromInt(203);
const ir_cmd_buffer_readi16: snapshot_v1.IrCommand = @enumFromInt(204);
const ir_cmd_buffer_readu16: snapshot_v1.IrCommand = @enumFromInt(205);
const ir_cmd_buffer_writei16: snapshot_v1.IrCommand = @enumFromInt(206);
const ir_cmd_buffer_readi32: snapshot_v1.IrCommand = @enumFromInt(207);
const ir_cmd_buffer_writei32: snapshot_v1.IrCommand = @enumFromInt(208);
const ir_cmd_buffer_readf32: snapshot_v1.IrCommand = @enumFromInt(209);
const ir_cmd_buffer_writef32: snapshot_v1.IrCommand = @enumFromInt(210);
const ir_cmd_buffer_readf64: snapshot_v1.IrCommand = @enumFromInt(211);
const ir_cmd_buffer_writef64: snapshot_v1.IrCommand = @enumFromInt(212);
const ir_cmd_buffer_readi64: snapshot_v1.IrCommand = @enumFromInt(213);
const ir_cmd_buffer_writei64: snapshot_v1.IrCommand = @enumFromInt(214);
const ir_cmd_jump_slot_match: snapshot_v1.IrCommand = @enumFromInt(97);

const lua_state_top_offset: u32 = 8;
const lua_state_base_offset: u32 = 12;
const lua_state_ci_offset: u32 = 20;
const callinfo_top_offset: u32 = 8;
const tvalue_size: u32 = 16;
const tvalue_extra_offset: u32 = 8;
const tvalue_tag_offset: u32 = 12;
const tstring_len_offset: u32 = 16;
const buffer_len_offset: u32 = 4;
const buffer_data_offset: u32 = 8;
const userdata_data_offset: u32 = 16;
const lua_tag_nil: i32 = 0;
const lua_tag_boolean: i32 = 1;
const lua_tag_lightuserdata: u8 = 2;
const lua_tag_number: u8 = 3;
const lua_tag_integer: u8 = 4;
const lua_tag_vector: i64 = 5;
const lua_tag_string: u8 = 6;
const lua_tag_table: u8 = 7;
const lua_tag_userdata: u8 = 9;
const lua_tag_buffer: u8 = 11;
const lu_tag_iterator: i32 = 128;
const lua_utag_limit: u32 = 128;
const vector_lane_count: u32 = 3;
const tvalue_lane_count: u32 = 4;
const round_number_bias: f64 = @bitCast(@as(u64, 0x3fdf_ffff_ffff_ffff));
const upstream_tm_add: i32 = 8;
const upstream_tm_pow: i32 = 14;
const upstream_tm_unm: i32 = 15;
const max_lowered_locals: u32 = 262_144;
const lbf_math_pow: u32 = 21;
const lbf_operand_none: u32 = std.math.maxInt(u32);
const lbf_buffer_readi8: u32 = 65;
const lbf_buffer_writef64: u32 = 77;
const lbf_integer_create: u32 = 94;
const lbf_buffer_readinteger: u32 = 131;
const lbf_buffer_writeinteger: u32 = 132;
const lop_getimport: u8 = 12;
const lop_call: u8 = 21;
const lop_fastcall3: u8 = 60;
const lop_fastcall: u8 = 68;
const lop_fastcall1: u8 = 73;
const lop_fastcall2: u8 = 74;
const lop_fastcall2k: u8 = 75;

const StringKeyPool = struct {
    const Entry = struct { offset: u32, length: u32 };

    bytes: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(Entry) = .empty,

    fn deinit(self: *StringKeyPool, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    fn intern(self: *StringKeyPool, allocator: std.mem.Allocator, key: []const u8) Error!Entry {
        for (self.entries.items) |entry| {
            const start: usize = @intCast(entry.offset);
            const end = std.math.add(usize, start, entry.length) catch return Error.ResourceLimit;
            if (std.mem.eql(u8, self.bytes.items[start..end], key))
                return entry;
        }
        if (key.len > std.math.maxInt(u32) or self.bytes.items.len > std.math.maxInt(u32) - key.len)
            return Error.ResourceLimit;
        const entry = Entry{ .offset = @intCast(self.bytes.items.len), .length = @intCast(key.len) };
        try self.bytes.appendSlice(allocator, key);
        try self.entries.append(allocator, entry);
        return entry;
    }
};

fn aotArithmeticOperation(upstream_operation: i32) ?i32 {
    if (upstream_operation < upstream_tm_add or upstream_operation > upstream_tm_unm)
        return null;
    return upstream_operation - upstream_tm_add;
}

fn rotateRight32(value: u32, comptime shift: u5) u32 {
    const inverse: u5 = @intCast(@as(u6, 32) - @as(u6, shift));
    return (value >> shift) | (value << inverse);
}

fn upstreamStringHash(key: []const u8) ?u32 {
    if (key.len > std.math.maxInt(u32))
        return null;
    var a: u32 = 0;
    var b: u32 = 0;
    var hash: u32 = @intCast(key.len);
    var cursor: usize = 0;
    var remaining = key.len;
    while (remaining >= 32) {
        a +%= std.mem.readInt(u32, key[cursor..][0..4], .little);
        b +%= std.mem.readInt(u32, key[cursor + 4 ..][0..4], .little);
        hash +%= std.mem.readInt(u32, key[cursor + 8 ..][0..4], .little);
        a ^= hash;
        a -%= rotateRight32(hash, 14);
        b ^= a;
        b -%= rotateRight32(a, 11);
        hash ^= b;
        hash -%= rotateRight32(b, 25);
        cursor += 12;
        remaining -= 12;
    }
    var index = remaining;
    while (index > 0) {
        index -= 1;
        hash ^= (hash << 5) +% (hash >> 2) +% key[cursor + index];
    }
    return hash;
}

pub const Error = snapshot_v1.Error || static_package_v1.Error || wasm.Error || std.mem.Allocator.Error || error{
    FunctionOutOfBounds,
    UnsupportedVariadicFunction,
    UnsupportedCommand,
    UnsupportedOperand,
    UnsupportedCondition,
    UnsupportedControlFlow,
    InvalidOperandCount,
    InvalidOperandType,
    InvalidInstructionResult,
    InvalidBlockTermination,
    InvalidReturnCount,
    ResourceLimit,
};

const ValueShape = enum {
    none,
    i32,
    pointer,
    i64,
    f32,
    f64,
    tvalue,
};

const ValueSlot = struct {
    shape: ValueShape = .none,
    first: u32 = snapshot_v1.no_id,
    second: u32 = snapshot_v1.no_id,
};

const CaptureKind = enum(u32) {
    value = 0,
    reference = 1,
    upvalue = 2,
};

const Capture = struct {
    kind: CaptureKind,
    source: u32,
};

const NewClosurePattern = struct {
    start: u32,
    finish: u32,
    destination: u32,
    child_proto_id: u32,
    capture_count: u32,
    capture_ir_start: u32,
    marker_start: u32,
};

const SetUpvaluePattern = struct {
    upvalue_index: u32,
    source_register: u32,
};

const StaticRequirePattern = struct {
    end: u32,
    interrupt_id: u32,
    destination: u32,
    module_id: u32,
};

const ContinuationAction = union(enum) {
    call_suffix: struct {
        block_id: u32,
        suffix_start: u32,
        block_finish: u32,
    },
    generic_iteration: GenericIterationPattern,
    interrupt_block_retry: struct {
        block_id: u32,
    },
    interrupt_suffix: struct {
        block_id: u32,
        interrupt_id: u32,
        suffix_start: u32,
        block_finish: u32,
    },
    static_require_interrupt: struct {
        block_id: u32,
        require: StaticRequirePattern,
        suffix_start: u32,
        block_finish: u32,
    },
};

const CallContinuation = struct {
    instruction_id: u32,
    continuation_id: u32,
    dispatch_id: u32,
    action: ContinuationAction,
};

const TableAllocationPattern = struct {
    start: u32,
    finish: u32,
    assist: bool,
    deferred_to_later_gc: bool,
    destination: u32,
    array_count: u32,
    node_count: u32,
};

const DupTablePattern = struct {
    start: u32,
    finish: u32,
    destination: u32,
    constant_id: u32,
};

const ConstantLoadPattern = struct {
    start: u32,
    finish: u32,
    destination: u32,
    constant_id: u32,
};

const ConstantTruthyFallbackPattern = struct {
    start: u32,
    finish: u32,
    destination: u32,
    constant_id: u32,
    true_value: snapshot_v1.IrOperand,
};

const ArrayOperationKind = enum { set, get, len };

const SemanticArrayOperation = struct {
    pattern: ArrayOperationPattern,
    kind: ArrayOperationKind,
};

const LiteralFieldSetPattern = struct {
    start: u32,
    finish: u32,
    pc: u32,
    table: u32,
    value: u32,
    materialized_tag: ?i32 = null,
    key: []const u8,
};

const TableInsertAppendPattern = struct {
    start: u32,
    finish: u32,
    table: u32,
    source: u32,
    constant_number: ?f64 = null,
};

const PlainTableNamecallPattern = struct {
    start: u32,
    destination: u32,
    source: u32,
    key: []const u8,
    pc: u32,
    first_fast: u32,
    second_fast: u32,
    fallback: u32,
    rejoin: u32,
};

const ArrayOperationPattern = struct {
    start: u32,
    destination: u32 = 0,
    table: u32,
    source: u32 = 0,
    index: u32 = 0,
    rejoin: u32,
};

const InlineArrayGetPattern = struct {
    start: u32,
    finish: u32,
    destination: u32,
    table: u32,
    index: u32,
};

const ConcatPattern = struct {
    start: u32,
    finish: u32,
    destination: u32,
    source: u32,
    count: u32,
};

const DynamicLengthPattern = struct {
    start: u32,
    destination: u32,
    source: u32,
    fallback: u32,
    rejoin: u32,
    marker: snapshot_v1.IrInstruction,
};

const PowPattern = struct {
    start: u32,
    destination: u32,
    lhs: u32,
    rhs: u32,
    fast_target: u32,
    rejoin: u32,
    marker: snapshot_v1.IrInstruction,
    arithmetic_id: u32,
};

const LinearizedPowPattern = struct {
    finish: u32,
    marker: snapshot_v1.IrInstruction,
    arithmetic_id: u32,
};

const ConstantArithmeticPattern = struct {
    start: u32,
    fast_target: u32,
    rejoin: u32,
    marker: snapshot_v1.IrInstruction,
    arithmetic_id: u32,
};

const ConstantPowPattern = ConstantArithmeticPattern;

const StringEqualityPattern = struct {
    start: u32,
    lhs: u32,
    rhs: u32,
    true_target: u32,
    false_target: u32,
    pointer_block: u32,
};

const GenericIterationPattern = struct {
    marker: snapshot_v1.IrInstruction,
    base: u32,
    aux: u32,
    variable_count: u32,
    repeat_target: u32,
    exit_target: u32,
    fallback_target: ?u32 = null,
};

const XnextPreparationPattern = struct {
    pc: u32,
    base: u32,
    target: u32,
};

const XnextFastPreparationPattern = struct {
    start: u32,
    pc: u32,
    base: u32,
    target: u32,
    fallback: u32,
    publish: ?u32 = null,
};

const UserdataAllocationPattern = struct {
    start: u32,
    allocation: u32,
    finish: u32,
    destination: u32,
    byte_size: u32,
    user_tag: u32,
};

const StringTableOperation = enum { set, get };

const GenericTableOperation = enum { set, get };

const GenericTablePattern = struct {
    operation: GenericTableOperation,
    start: u32,
    table: u32,
    key: u32,
    register_key: ?u32,
    immediate_number_key: ?f64,
    value: u32,
    marker: snapshot_v1.IrInstruction,
    fallback: u32,
    fast_target: u32,
    rejoin: u32,
};

const GenericTableFallback = struct {
    marker: snapshot_v1.IrInstruction,
    rejoin: u32,
};

const InlineGenericTablePattern = struct {
    pattern: GenericTablePattern,
    finish: u32,
    address: u32,
};

const InlineConstantTableGetPattern = struct {
    pattern: GenericTablePattern,
    finish: u32,
};

const SemanticTableReloadPattern = struct {
    start: u32,
    finish: u32,
    destination: u32,
    table: u32,
    key: union(enum) {
        dynamic: struct { register: u32, marker: snapshot_v1.IrInstruction },
        string: struct { value: []const u8, pc: u32 },
    },
};

const GlobalOperation = enum { get, set };

const GlobalPattern = struct {
    operation: GlobalOperation,
    start: u32,
    value: u32,
    key: []const u8,
    pc: u32,
    fast_target: u32,
    rejoin: u32,
};

const FastcallPattern = struct {
    start: u32,
    finish: u32,
    builtin_id: u32,
    destination: u32,
    source: u32,
    argument_two: u32,
    argument_three: u32,
    parameter_count: i32,
    result_count: i32,
    fallback: u32,
    fast_target: u32,
};

const TypeNamePattern = struct {
    destination: u32,
    source: u32,
    custom: u32,
    finish: u32,
};

const StringLengthPattern = struct {
    source: u32,
    destination: u32,
};

const BuiltinFallback = struct {
    id: u32,
    name: []const u8,
    pc: u32,
    argument_registers: [3]u32,
    argument_count: u8,
};

const IntegerCreatePattern = struct {
    check: u32,
    finish: u32,
    destination: u32,
};

fn isBufferBuiltinId(id: u32) bool {
    return (id >= lbf_buffer_readi8 and id <= lbf_buffer_writef64) or
        id == lbf_buffer_readinteger or id == lbf_buffer_writeinteger;
}

const StringTablePattern = struct {
    operation: StringTableOperation,
    start: u32,
    pc: u32,
    table: u32,
    value: u32,
    key: []const u8,
    fallback: u32,
    fast_target: u32,
    rejoin: u32,
};

const DupClosurePattern = union(enum) {
    closed: struct {
        destination: u32,
        child_proto_id: u32,
    },
    captured: struct {
        destination: u32,
        child_proto_id: u32,
        capture_count: u32,
        marker_start: u32,
    },
};

fn markerCapture(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    proto: snapshot_v1.Proto,
    marker_id: u32,
    allow_reference: bool,
) Error!Capture {
    const marker = try snapshot.irInstruction(function, marker_id);
    if (marker.command != .capture)
        return Error.UnsupportedControlFlow;
    if (marker.operand_count != 2)
        return Error.InvalidOperandCount;
    const source = try snapshot.irOperand(marker, 0);
    const kind_operand = try snapshot.irOperand(marker, 1);
    if (kind_operand.kind != .constant)
        return Error.InvalidOperandType;
    const marker_kind = (try snapshot.irConstant(function, kind_operand.value)).uintValue() orelse
        return Error.InvalidOperandType;
    if (source.kind == .vm_reg) {
        if (source.value >= proto.max_stack_size or marker_kind > 1 or (!allow_reference and marker_kind != 0))
            return Error.InvalidOperandType;
        return .{ .kind = if (marker_kind == 0) .value else .reference, .source = source.value };
    }
    if (source.kind == .vm_upvalue and source.value < proto.nups and marker_kind == 0)
        return .{ .kind = .upvalue, .source = source.value };
    return Error.InvalidOperandType;
}

fn requireSingleBytecodeBlockRangeFor(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    start: u32,
    finish: u32,
) Error!void {
    var owner: ?u32 = null;
    var block_id: u32 = 0;
    while (block_id < function.block_count) : (block_id += 1) {
        const block = try snapshot.irBlock(function, block_id);
        if (block.isEmpty() or block.finish < start or block.start > finish)
            continue;
        if (owner != null or block.kind != .bytecode or block.start > start or block.finish < finish)
            return Error.UnsupportedControlFlow;
        owner = block_id;
    }
    if (owner == null)
        return Error.UnsupportedControlFlow;
}

fn dupClosurePattern(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    proto: snapshot_v1.Proto,
    instruction_id: u32,
) Error!DupClosurePattern {
    if (instruction_id >= function.instruction_count)
        return Error.UnsupportedControlFlow;
    const instruction_value = try snapshot.irInstruction(function, instruction_id);
    if (instruction_value.command != .fallback_dupclosure)
        return Error.UnsupportedControlFlow;
    if (instruction_value.operand_count != 3)
        return Error.InvalidOperandCount;

    const pc_operand = try snapshot.irOperand(instruction_value, 0);
    const destination_operand = try snapshot.irOperand(instruction_value, 1);
    const constant_operand = try snapshot.irOperand(instruction_value, 2);
    if (pc_operand.kind != .constant or destination_operand.kind != .vm_reg or
        destination_operand.value >= proto.max_stack_size or constant_operand.kind != .vm_const)
        return Error.InvalidOperandType;
    const pc = try snapshot.irConstant(function, pc_operand.value);
    if (pc.uintValue() == null)
        return Error.InvalidOperandType;
    const child_proto_id = (try snapshot.vmConstant(proto, constant_operand.value)).closureProtoId() orelse
        return Error.InvalidOperandType;
    const child = try snapshot.proto(child_proto_id);
    if (child.parent_id != proto.id)
        return Error.UnsupportedControlFlow;

    if (child.nups == 0)
        return .{ .closed = .{
            .destination = destination_operand.value,
            .child_proto_id = child_proto_id,
        } };
    const capture_count: u32 = child.nups;
    const marker_start = std.math.add(u32, instruction_id, 1) catch return Error.ResourceLimit;
    const finish = std.math.add(u32, instruction_id, capture_count) catch return Error.ResourceLimit;
    if (finish >= function.instruction_count)
        return Error.UnsupportedControlFlow;
    try requireSingleBytecodeBlockRangeFor(snapshot, function, instruction_id, finish);
    var capture_index: u32 = 0;
    while (capture_index < capture_count) : (capture_index += 1)
        _ = try markerCapture(snapshot, function, proto, marker_start + capture_index, false);
    return .{ .captured = .{
        .destination = destination_operand.value,
        .child_proto_id = child_proto_id,
        .capture_count = capture_count,
        .marker_start = marker_start,
    } };
}

const Context = struct {
    allocator: std.mem.Allocator,
    snapshot: snapshot_v1.Snapshot,
    proto: snapshot_v1.Proto,
    function: snapshot_v1.IrFunction,
    slots: []const ValueSlot,
    builtin_number_sources: []u32,
    body: *wasm.Body,
    return_: wasm.FunctionRef,
    interrupt: wasm.FunctionRef,
    do_arith: ?wasm.FunctionRef,
    compare_any: ?wasm.FunctionRef,
    dupclosure: ?wasm.FunctionRef,
    newclosure_capture: ?wasm.FunctionRef,
    get_upvalue: ?wasm.FunctionRef,
    set_upvalue: ?wasm.FunctionRef,
    close_upvalues: ?wasm.FunctionRef,
    call: ?wasm.FunctionRef,
    exchange_continuation: ?wasm.FunctionRef,
    set_location: ?wasm.FunctionRef,
    new_table: ?wasm.FunctionRef,
    new_table_deferred: ?wasm.FunctionRef,
    check_gc: ?wasm.FunctionRef,
    load_constant: ?wasm.FunctionRef,
    dup_table: ?wasm.FunctionRef,
    table_insert_append: ?wasm.FunctionRef,
    namecall_plain: ?wasm.FunctionRef,
    set_list: ?wasm.FunctionRef,
    array_set: ?wasm.FunctionRef,
    array_get: ?wasm.FunctionRef,
    table_len: ?wasm.FunctionRef,
    concat: ?wasm.FunctionRef,
    do_len: ?wasm.FunctionRef,
    forg_prep: ?wasm.FunctionRef,
    forg_loop: ?wasm.FunctionRef,
    forg_loop_call: ?wasm.FunctionRef,
    forg_loop_finish: ?wasm.FunctionRef,
    forgprep_xnext_fallback: ?wasm.FunctionRef,
    new_userdata: ?wasm.FunctionRef,
    check_userdata_tag: ?wasm.FunctionRef,
    barrier_object: ?wasm.FunctionRef,
    barrier_table_back: ?wasm.FunctionRef,
    table_set_string: ?wasm.FunctionRef,
    table_get_string: ?wasm.FunctionRef,
    table_set: ?wasm.FunctionRef,
    table_get: ?wasm.FunctionRef,
    table_array_set: ?wasm.FunctionRef,
    table_array_get: ?wasm.FunctionRef,
    get_global: ?wasm.FunctionRef,
    set_global: ?wasm.FunctionRef,
    check_safe_env: ?wasm.FunctionRef,
    fastcall: ?wasm.FunctionRef,
    type_name: ?wasm.FunctionRef,
    libm: ?wasm.FunctionRef,
    builtin_type_error: ?wasm.FunctionRef,
    builtin_number: ?wasm.FunctionRef,
    buffer_bounds_error: ?wasm.FunctionRef,
    prep_varargs: ?wasm.FunctionRef,
    get_varargs_fixed: ?wasm.FunctionRef,
    get_varargs_multret: ?wasm.FunctionRef,
    require_static: ?wasm.FunctionRef,
    static_package: ?static_package_v1.Package,
    function_id_base: u32,
    base_local: u32,
    dispatch_local: u32,
    status_local: u32,
    continuation_local: u32,
    table_index_local: u32,
    call_continuations: []const CallContinuation,
    string_keys: *StringKeyPool,

    fn instruction(self: Context, id: u32) Error!snapshot_v1.IrInstruction {
        return self.snapshot.irInstruction(self.function, id);
    }

    fn operand(self: Context, instruction_value: snapshot_v1.IrInstruction, id: u32) Error!snapshot_v1.IrOperand {
        return self.snapshot.irOperand(instruction_value, id);
    }

    fn constant(self: Context, id: u32) Error!snapshot_v1.IrConstant {
        return self.snapshot.irConstant(self.function, id);
    }

    fn requireOperandCount(_: Context, instruction_value: snapshot_v1.IrInstruction, expected: u32) Error!void {
        if (instruction_value.operand_count != expected)
            return Error.InvalidOperandCount;
    }

    fn vmRegisterOffset(self: Context, operand_value: snapshot_v1.IrOperand, field_offset: u32) Error!u32 {
        return (try self.vmRegisterIndex(operand_value)) * tvalue_size + field_offset;
    }

    fn vmRegisterIndex(self: Context, operand_value: snapshot_v1.IrOperand) Error!u32 {
        if (operand_value.kind != .vm_reg or operand_value.value >= self.proto.max_stack_size)
            return Error.InvalidOperandType;
        return operand_value.value;
    }

    fn valueOperandEncoding(self: Context, operand_value: snapshot_v1.IrOperand) Error!u32 {
        if (operand_value.kind == .vm_reg)
            return self.vmRegisterIndex(operand_value);
        if (operand_value.kind != .vm_const or operand_value.value >= self.proto.vm_constant_count or
            operand_value.value >= 0x80000000)
            return Error.InvalidOperandType;
        const value = try self.snapshot.vmConstant(self.proto, operand_value.value);
        switch (value.kind) {
            .nil, .boolean, .number, .integer, .vector, .string => {},
            .table, .closure, .class_shape, .import => return Error.InvalidOperandType,
        }
        return 0x80000000 | operand_value.value;
    }

    fn emitReloadBase(self: Context) Error!void {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Load(self.allocator, 2, lua_state_base_offset);
        try self.body.localSet(self.allocator, self.base_local);
    }

    fn requireSingleBytecodeBlockRange(self: Context, start: u32, finish: u32) Error!void {
        return requireSingleBytecodeBlockRangeFor(self.snapshot, self.function, start, finish);
    }

    fn requireSingleCompilableBlockRange(self: Context, start: u32, finish: u32) Error!void {
        var owner: ?u32 = null;
        var block_id: u32 = 0;
        while (block_id < self.function.block_count) : (block_id += 1) {
            const block = try self.snapshot.irBlock(self.function, block_id);
            if (block.isEmpty() or block.finish < start or block.start > finish)
                continue;
            if (owner != null or !block.kind.isCompilable() or block.start > start or block.finish < finish)
                return Error.UnsupportedControlFlow;
            owner = block_id;
        }
        if (owner == null)
            return Error.UnsupportedControlFlow;
    }

    fn requireSingleCallBlockRange(self: Context, start: u32, finish: u32) Error!void {
        var owner: ?u32 = null;
        var block_id: u32 = 0;
        while (block_id < self.function.block_count) : (block_id += 1) {
            const block = try self.snapshot.irBlock(self.function, block_id);
            if (block.isEmpty() or block.finish < start or block.start > finish)
                continue;
            const supported = block.kind.isCompilable() or
                (block.kind == .fallback and
                    ((try self.isFastcallFallbackBlock(block)) or (try self.supportsOrdinaryCallFallback(block))));
            if (owner != null or !supported or block.start > start or block.finish < finish)
                return Error.UnsupportedControlFlow;
            owner = block_id;
        }
        if (owner == null)
            return Error.UnsupportedControlFlow;
    }

    fn loadedTValueRegister(self: Context, instruction_id: u32) Error!?u32 {
        if (instruction_id >= self.function.instruction_count)
            return Error.InvalidInstructionResult;
        const load = try self.instruction(instruction_id);
        if (load.command != .load_tvalue)
            return null;
        if (load.operand_count != 1 and load.operand_count != 3)
            return Error.InvalidOperandCount;
        const source = try self.vmRegisterIndex(try self.operand(load, 0));
        if (load.operand_count == 3) {
            if (try self.tvalueByteOffset(load, 1) != 0)
                return Error.InvalidOperandType;
            const tag = try self.operand(load, 2);
            if (tag.kind != .constant or (try self.constant(tag.value)).tagValue() == null)
                return Error.InvalidOperandType;
        }
        return source;
    }

    fn initializedClosureValueCapture(self: Context, address_id: u32, store_id: u32, newclosure_id: u32) Error!?Capture {
        const store = try self.instruction(store_id);
        if (store.command == .store_tvalue) {
            try self.requireOperandCount(store, 2);
            const destination = try self.operand(store, 0);
            const source = try self.operand(store, 1);
            if (destination.kind != .instruction or destination.value != address_id or source.kind != .instruction)
                return Error.InvalidOperandType;
            if (try self.concatPatternContaining(source.value)) |concat| {
                if (source.value != concat.start + 2)
                    return Error.InvalidOperandType;
                return .{ .kind = .value, .source = concat.destination };
            }
            if (try self.loadedTValueRegister(source.value)) |source_register|
                return .{ .kind = .value, .source = source_register };
            return null;
        }
        if (store.command != .store_split_tvalue)
            return null;
        try self.requireOperandCount(store, 3);
        const destination = try self.operand(store, 0);
        const tag = try self.operand(store, 1);
        const source = try self.operand(store, 2);
        if (destination.kind != .instruction or destination.value != address_id or
            tag.kind != .constant or (try self.constant(tag.value)).tagValue() != 8 or
            source.kind != .instruction or source.value >= newclosure_id)
            return Error.InvalidOperandType;
        const source_instruction = try self.instruction(source.value);
        if (source_instruction.command != .newclosure)
            return Error.UnsupportedControlFlow;
        const source_pattern = try self.newClosurePattern(source.value);
        if (source_pattern.finish >= newclosure_id - 2)
            return Error.UnsupportedControlFlow;
        return .{ .kind = .value, .source = source_pattern.destination };
    }

    fn newClosurePattern(self: Context, newclosure_id: u32) Error!NewClosurePattern {
        if (newclosure_id < 2)
            return Error.UnsupportedControlFlow;
        const marker = try self.instruction(newclosure_id - 2);
        const load_env = try self.instruction(newclosure_id - 1);
        const newclosure = try self.instruction(newclosure_id);
        const store_pointer = try self.instruction(newclosure_id + 1);
        const store_tag = try self.instruction(newclosure_id + 2);
        if (marker.command != .set_savedpc or load_env.command != .load_env or
            newclosure.command != .newclosure or store_pointer.command != .store_pointer or
            store_tag.command != .store_tag)
            return Error.UnsupportedControlFlow;
        _ = try self.savedPc(marker);
        try self.requireOperandCount(load_env, 0);
        try self.requireOperandCount(newclosure, 3);
        try self.requireOperandCount(store_pointer, 2);
        try self.requireOperandCount(store_tag, 2);

        const nups_operand = try self.operand(newclosure, 0);
        const env_operand = try self.operand(newclosure, 1);
        const child_index_operand = try self.operand(newclosure, 2);
        if (nups_operand.kind != .constant or env_operand.kind != .instruction or
            env_operand.value != newclosure_id - 1 or child_index_operand.kind != .constant)
            return Error.InvalidOperandType;
        const capture_count = (try self.constant(nups_operand.value)).uintValue() orelse return Error.InvalidOperandType;
        if (capture_count == 0)
            return Error.UnsupportedControlFlow;
        const child_index = (try self.constant(child_index_operand.value)).uintValue() orelse
            return Error.InvalidOperandType;
        const child_proto_id = try self.snapshot.protoChild(self.proto, child_index);
        const child = try self.snapshot.proto(child_proto_id);
        if (child.parent_id != self.proto.id or child.nups != capture_count)
            return Error.UnsupportedControlFlow;

        const pointer_destination = try self.operand(store_pointer, 0);
        const pointer_source = try self.operand(store_pointer, 1);
        const tag_destination = try self.operand(store_tag, 0);
        const tag_source = try self.operand(store_tag, 1);
        if (pointer_source.kind != .instruction or pointer_source.value != newclosure_id or
            tag_destination.kind != .vm_reg or tag_destination.value != pointer_destination.value or
            tag_source.kind != .constant or (try self.constant(tag_source.value)).tagValue() != 8)
            return Error.InvalidOperandType;
        const destination = try self.vmRegisterIndex(pointer_destination);

        var cursor = std.math.add(u32, newclosure_id, 3) catch return Error.ResourceLimit;
        const leading_marker = try self.instruction(cursor);
        if (leading_marker.command == .nop) {
            try self.requireOperandCount(leading_marker, 0);
            cursor = std.math.add(u32, cursor, 1) catch return Error.ResourceLimit;
        }
        const capture_ir_start = cursor;
        var capture_index: u32 = 0;
        while (capture_index < capture_count) : (capture_index += 1) {
            var first = try self.instruction(cursor);
            while (first.command == .nop) {
                try self.requireOperandCount(first, 0);
                cursor = std.math.add(u32, cursor, 1) catch return Error.ResourceLimit;
                first = try self.instruction(cursor);
            }
            if (first.command == .load_tvalue) {
                if (first.operand_count != 1 and first.operand_count != 3)
                    return Error.InvalidOperandCount;
                _ = try self.vmRegisterIndex(try self.operand(first, 0));
                if (first.operand_count == 3) {
                    if (try self.tvalueByteOffset(first, 1) != 0)
                        return Error.InvalidOperandType;
                    const load_tag = try self.operand(first, 2);
                    if (load_tag.kind != .constant or (try self.constant(load_tag.value)).tagValue() == null)
                        return Error.InvalidOperandType;
                }
                const address_id = cursor + 1;
                const store_id = cursor + 2;
                const address = try self.instruction(address_id);
                const store = try self.instruction(store_id);
                if (address.command != .get_closure_upval_addr or store.command != .store_tvalue)
                    return Error.UnsupportedControlFlow;
                try self.requireOperandCount(address, 2);
                try self.requireOperandCount(store, 2);
                try self.requireClosureCaptureAddress(address, newclosure_id, capture_index);
                try self.requireTValueStore(store, address_id, cursor);
                cursor = store_id + 1;
            } else if (first.command == .findupval) {
                try self.requireOperandCount(first, 1);
                _ = try self.vmRegisterIndex(try self.operand(first, 0));
                const address_id = cursor + 1;
                const pointer_id = cursor + 2;
                const tag_id = cursor + 3;
                const address = try self.instruction(address_id);
                const pointer_store = try self.instruction(pointer_id);
                const tag_store = try self.instruction(tag_id);
                if (address.command != .get_closure_upval_addr or pointer_store.command != .store_pointer or
                    tag_store.command != .store_tag)
                    return Error.UnsupportedControlFlow;
                try self.requireOperandCount(address, 2);
                try self.requireOperandCount(pointer_store, 2);
                try self.requireOperandCount(tag_store, 2);
                try self.requireClosureCaptureAddress(address, newclosure_id, capture_index);
                try self.requireInstructionStore(pointer_store, address_id, cursor);
                const capture_tag_destination = try self.operand(tag_store, 0);
                const capture_tag_source = try self.operand(tag_store, 1);
                if (capture_tag_destination.kind != .instruction or capture_tag_destination.value != address_id or
                    capture_tag_source.kind != .constant or (try self.constant(capture_tag_source.value)).tagValue() != 16)
                    return Error.InvalidOperandType;
                cursor = tag_id + 1;
            } else if (first.command == .get_closure_upval_addr) {
                try self.requireOperandCount(first, 2);
                const source_closure = try self.operand(first, 0);
                const source_slot = try self.operand(first, 1);
                if (source_closure.kind == .instruction and source_closure.value == newclosure_id) {
                    try self.requireClosureCaptureAddress(first, newclosure_id, capture_index);
                    const store_id = cursor + 1;
                    if (try self.initializedClosureValueCapture(cursor, store_id, newclosure_id) == null)
                        return Error.UnsupportedControlFlow;
                    cursor = store_id + 1;
                    continue;
                }
                if (source_closure.kind != .undef or source_closure.value != 0 or
                    source_slot.kind != .vm_upvalue or source_slot.value >= self.proto.nups)
                    return Error.InvalidOperandType;
                const address_id = cursor + 1;
                const load_id = cursor + 2;
                const store_id = cursor + 3;
                const address = try self.instruction(address_id);
                const load = try self.instruction(load_id);
                const store = try self.instruction(store_id);
                if (address.command != .get_closure_upval_addr or load.command != .load_tvalue or
                    store.command != .store_tvalue)
                    return Error.UnsupportedControlFlow;
                try self.requireOperandCount(address, 2);
                try self.requireOperandCount(load, 1);
                try self.requireOperandCount(store, 2);
                try self.requireClosureCaptureAddress(address, newclosure_id, capture_index);
                const load_source = try self.operand(load, 0);
                if (load_source.kind != .instruction or load_source.value != cursor)
                    return Error.InvalidOperandType;
                try self.requireTValueStore(store, address_id, load_id);
                cursor = store_id + 1;
            } else return Error.UnsupportedControlFlow;
        }

        const terminator = try self.instruction(cursor);
        if (terminator.command != .check_gc and terminator.command != .nop)
            return Error.UnsupportedControlFlow;
        try self.requireOperandCount(terminator, 0);
        const marker_start = cursor + 1;
        capture_index = 0;
        while (capture_index < capture_count) : (capture_index += 1) {
            const initialized = try self.initializedCapture(capture_index, capture_ir_start);
            const captured = try markerCapture(self.snapshot, self.function, self.proto, marker_start + capture_index, true);
            if (captured.kind != initialized.kind or captured.source != initialized.source)
                return Error.InvalidOperandType;
        }
        const finish = marker_start + capture_count - 1;
        if (finish >= self.function.instruction_count)
            return Error.UnsupportedControlFlow;
        try self.requireSingleCompilableBlockRange(newclosure_id - 2, finish);
        return .{ .start = newclosure_id - 2, .finish = finish, .destination = destination, .child_proto_id = child_proto_id, .capture_count = capture_count, .capture_ir_start = capture_ir_start, .marker_start = marker_start };
    }

    fn requireClosureCaptureAddress(self: Context, instruction_value: snapshot_v1.IrInstruction, newclosure_id: u32, capture_index: u32) Error!void {
        const closure = try self.operand(instruction_value, 0);
        const slot = try self.operand(instruction_value, 1);
        if (closure.kind != .instruction or closure.value != newclosure_id or
            slot.kind != .vm_upvalue or slot.value != capture_index)
            return Error.InvalidOperandType;
    }

    fn requireInstructionStore(self: Context, instruction_value: snapshot_v1.IrInstruction, destination_id: u32, source_id: u32) Error!void {
        const destination = try self.operand(instruction_value, 0);
        const source = try self.operand(instruction_value, 1);
        if (destination.kind != .instruction or destination.value != destination_id or
            source.kind != .instruction or source.value != source_id)
            return Error.InvalidOperandType;
    }

    fn requireTValueStore(self: Context, instruction_value: snapshot_v1.IrInstruction, destination_id: u32, source_id: u32) Error!void {
        return self.requireInstructionStore(instruction_value, destination_id, source_id);
    }

    fn initializedCapture(self: Context, wanted: u32, capture_ir_start: u32) Error!Capture {
        var cursor = capture_ir_start;
        var index: u32 = 0;
        while (index <= wanted) : (index += 1) {
            var first = try self.instruction(cursor);
            while (first.command == .nop) {
                try self.requireOperandCount(first, 0);
                cursor = std.math.add(u32, cursor, 1) catch return Error.ResourceLimit;
                first = try self.instruction(cursor);
            }
            if (first.command == .get_closure_upval_addr) {
                try self.requireOperandCount(first, 2);
                const closure = try self.operand(first, 0);
                if (closure.kind == .instruction) {
                    const capture = (try self.initializedClosureValueCapture(cursor, cursor + 1, closure.value)) orelse
                        return Error.UnsupportedControlFlow;
                    if (index == wanted)
                        return capture;
                    cursor += 2;
                    continue;
                }
            }
            const capture: Capture = if (first.command == .load_tvalue)
                .{ .kind = .value, .source = (try self.operand(first, 0)).value }
            else if (first.command == .findupval)
                .{ .kind = .reference, .source = (try self.operand(first, 0)).value }
            else if (first.command == .get_closure_upval_addr)
                .{ .kind = .upvalue, .source = (try self.operand(first, 1)).value }
            else
                return Error.UnsupportedControlFlow;
            if (index == wanted)
                return capture;
            cursor += if (capture.kind == .value) 3 else 4;
        }
        unreachable;
    }

    fn newClosurePatternContaining(self: Context, instruction_id: u32) Error!?NewClosurePattern {
        var candidate: u32 = 0;
        while (candidate < self.function.instruction_count) : (candidate += 1) {
            if ((try self.instruction(candidate)).command != .newclosure)
                continue;
            const pattern = self.newClosurePattern(candidate) catch |err| switch (err) {
                Error.UnsupportedControlFlow,
                Error.InvalidOperandCount,
                Error.InvalidOperandType,
                Error.InvalidInstructionResult,
                Error.InvalidBlockTermination,
                => continue,
                else => return err,
            };
            if (instruction_id >= pattern.start and instruction_id <= pattern.finish)
                return pattern;
        }
        return null;
    }

    fn isDupClosureCapture(self: Context, instruction_id: u32) Error!bool {
        var candidate: u32 = 0;
        while (candidate < instruction_id) : (candidate += 1) {
            if ((try self.instruction(candidate)).command != .fallback_dupclosure)
                continue;
            const pattern = dupClosurePattern(self.snapshot, self.function, self.proto, candidate) catch |err| switch (err) {
                Error.UnsupportedControlFlow,
                Error.InvalidOperandCount,
                Error.InvalidOperandType,
                Error.InvalidInstructionResult,
                Error.InvalidBlockTermination,
                => continue,
                else => return err,
            };
            switch (pattern) {
                .closed => {},
                .captured => |captured| {
                    const finish = std.math.add(u32, captured.marker_start, captured.capture_count) catch
                        return Error.ResourceLimit;
                    if (instruction_id >= captured.marker_start and instruction_id < finish)
                        return true;
                },
            }
        }
        return false;
    }

    fn setUpvaluePattern(self: Context, instruction_id: u32) Error!SetUpvaluePattern {
        if (instruction_id == 0)
            return Error.UnsupportedControlFlow;
        try self.requireSingleCompilableBlockRange(instruction_id - 1, instruction_id);
        const load = try self.instruction(instruction_id - 1);
        const set = try self.instruction(instruction_id);
        if (load.command != .load_tvalue or set.command != .set_upvalue)
            return Error.UnsupportedControlFlow;
        if (load.operand_count != 1 and load.operand_count != 3)
            return Error.InvalidOperandCount;
        try self.requireOperandCount(set, 3);
        const source_register = try self.vmRegisterIndex(try self.operand(load, 0));
        if (load.operand_count == 3) {
            if (try self.tvalueByteOffset(load, 1) != 0)
                return Error.InvalidOperandType;
            const load_tag = try self.operand(load, 2);
            if (load_tag.kind != .constant or (try self.constant(load_tag.value)).tagValue() == null)
                return Error.InvalidOperandType;
        }
        const upvalue = try self.operand(set, 0);
        const value = try self.operand(set, 1);
        const tag = try self.operand(set, 2);
        if (upvalue.kind != .vm_upvalue or upvalue.value >= self.proto.nups or
            value.kind != .instruction or value.value != instruction_id - 1)
            return Error.InvalidOperandType;
        if (tag.kind == .constant) {
            if ((try self.constant(tag.value)).tagValue() == null)
                return Error.InvalidOperandType;
        } else if (tag.kind != .undef or tag.value != 0)
            return Error.InvalidOperandType;
        return .{ .upvalue_index = upvalue.value, .source_register = source_register };
    }

    fn emitCopyTValueRegisters(self: Context, destination: u32, source: u32) Error!void {
        try self.emitCopyTValueRegisterToAddress(destination, 0, source);
    }

    fn emitStoreTValueOperand(self: Context, destination: u32, source: snapshot_v1.IrOperand) Error!void {
        if (destination >= self.proto.max_stack_size)
            return Error.InvalidOperandType;
        const destination_offset = destination * tvalue_size;
        try self.body.localGet(self.allocator, self.base_local);
        try self.emitTValuePart(source, false);
        try self.body.i64Store(self.allocator, 3, destination_offset);
        try self.body.localGet(self.allocator, self.base_local);
        try self.emitTValuePart(source, true);
        try self.body.i64Store(self.allocator, 3, destination_offset + 8);
    }

    fn emitCopyTValueRegisterToAddress(
        self: Context,
        destination: u32,
        destination_byte_offset: u32,
        source: u32,
    ) Error!void {
        const destination_offset = destination * tvalue_size;
        const source_offset = source * tvalue_size;
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i64Load(self.allocator, 3, source_offset);
        try self.body.i64Store(self.allocator, 3, destination_offset + destination_byte_offset);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i64Load(self.allocator, 3, source_offset + 8);
        try self.body.i64Store(self.allocator, 3, destination_offset + destination_byte_offset + 8);
    }

    fn emitStoreSplitTValue(
        self: Context,
        instruction_value: snapshot_v1.IrInstruction,
    ) Error!void {
        if (instruction_value.operand_count != 3 and instruction_value.operand_count != 4)
            return Error.InvalidOperandCount;
        const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
        const tag = try self.operand(instruction_value, 1);
        const source = try self.operand(instruction_value, 2);
        if (tag.kind != .constant)
            return Error.InvalidOperandType;
        const tag_value = (try self.constant(tag.value)).tagValue() orelse return Error.InvalidOperandType;

        if (source.kind == .instruction and source.value < self.function.instruction_count and
            (try self.instruction(source.value)).command == .newclosure)
        {
            if (instruction_value.operand_count != 3 or tag_value != 8)
                return Error.UnsupportedControlFlow;
            const pattern = try self.newClosurePattern(source.value);
            try self.emitCopyTValueRegisters(destination, pattern.destination);
            return;
        }

        const address_offset = if (instruction_value.operand_count == 4)
            try self.tvalueByteOffset(instruction_value, 3)
        else
            0;

        // A numeric-string builtin argument enters the optimized numeric arm through an
        // AOT-owned coercion.  Numeric consumers use the converted instruction result,
        // while TValue materialization must preserve the untouched source value just as
        // the bytecode fallback would.
        if (tag_value == lua_tag_number and source.kind == .instruction and
            source.value < self.builtin_number_sources.len)
        {
            const source_register = self.builtin_number_sources[source.value];
            if (source_register != std.math.maxInt(u32)) {
                try self.emitCopyTValueRegisterToAddress(destination, address_offset, source_register);
                return;
            }
        }

        const destination_operand = try self.operand(instruction_value, 0);
        const value_offset = try self.vmRegisterOffset(destination_operand, address_offset);
        const tag_offset = try self.vmRegisterOffset(destination_operand, address_offset + tvalue_tag_offset);

        try self.body.localGet(self.allocator, self.base_local);
        try self.emitI32Value(tag);
        try self.body.i32Store(self.allocator, 2, tag_offset);

        try self.body.localGet(self.allocator, self.base_local);
        switch (tag_value) {
            lua_tag_boolean => {
                try self.emitI32Value(source);
                try self.body.i32Store(self.allocator, 2, value_offset);
            },
            lua_tag_number => {
                try self.emitF64Value(source);
                try self.body.f64Store(self.allocator, 3, value_offset);
            },
            lua_tag_integer => {
                try self.emitI64Value(source);
                try self.body.i64Store(self.allocator, 3, value_offset);
            },
            lua_tag_string, 7, 8, 9, 10, 11, 12 => {
                try self.emitPointerValue(source);
                try self.body.i32Store(self.allocator, 2, value_offset);
            },
            else => return Error.UnsupportedOperand,
        }
    }

    fn emitI32Value(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        switch (operand_value.kind) {
            .constant => {
                const value = try self.constant(operand_value.value);
                const integer: i32 = switch (value.kind) {
                    .int => value.intValue().?,
                    .uint => @bitCast(value.uintValue().?),
                    .tag => value.tagValue().?,
                    else => return Error.InvalidOperandType,
                };
                try self.body.i32Const(self.allocator, integer);
            },
            .instruction => {
                if (operand_value.value >= self.slots.len)
                    return Error.InvalidInstructionResult;
                const slot = self.slots[operand_value.value];
                if (slot.shape != .i32)
                    return Error.InvalidInstructionResult;
                try self.body.localGet(self.allocator, slot.first);
            },
            else => return Error.UnsupportedOperand,
        }
    }

    fn emitPointerValue(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        switch (operand_value.kind) {
            .constant => {
                const value = try self.constant(operand_value.value);
                const integer = value.intValue() orelse return Error.InvalidOperandType;
                if (integer != 0)
                    return Error.InvalidOperandType;
                try self.body.i32Const(self.allocator, 0);
            },
            .instruction => {
                if (operand_value.value >= self.slots.len)
                    return Error.InvalidInstructionResult;
                const slot = self.slots[operand_value.value];
                if (slot.shape != .pointer)
                    return Error.InvalidInstructionResult;
                try self.body.localGet(self.allocator, slot.first);
            },
            else => return Error.UnsupportedOperand,
        }
    }

    fn vmConstantTag(self: Context, operand_value: snapshot_v1.IrOperand) Error!i32 {
        if (operand_value.kind != .vm_const)
            return Error.InvalidOperandType;
        const value = try self.snapshot.vmConstant(self.proto, operand_value.value);
        return switch (value.kind) {
            .nil => lua_tag_nil,
            .boolean => lua_tag_boolean,
            .number => lua_tag_number,
            .integer => lua_tag_integer,
            .vector => @intCast(lua_tag_vector),
            .string => lua_tag_string,
            .table => 7,
            .closure => 8,
            .class_shape => 12,
            // Imports are resolved while loading bytecode and have no statically known tag.
            .import => return Error.UnsupportedOperand,
        };
    }

    const VmConstantParts = struct {
        low: u64,
        high: u64,
    };

    fn vmConstantParts(self: Context, operand_value: snapshot_v1.IrOperand) Error!VmConstantParts {
        if (operand_value.kind != .vm_const)
            return Error.InvalidOperandType;
        const value = try self.snapshot.vmConstant(self.proto, operand_value.value);
        const tag: u64 = @intCast(try self.vmConstantTag(operand_value));
        const low: u64 = switch (value.kind) {
            .nil => 0,
            .boolean => value.payload0,
            .number, .integer => value.bits0,
            .vector => @as(u64, value.payload0) | (@as(u64, value.payload1) << 32),
            // The snapshot deliberately contains stable IDs instead of runtime GC pointers.
            .string, .import, .table, .closure, .class_shape => return Error.UnsupportedOperand,
        };
        const extra: u64 = switch (value.kind) {
            .vector => value.payload2,
            else => 0,
        };
        return .{ .low = low, .high = extra | (tag << 32) };
    }

    fn emitTValueAddress(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        switch (operand_value.kind) {
            .vm_reg => {
                _ = try self.vmRegisterIndex(operand_value);
                try self.body.localGet(self.allocator, self.base_local);
            },
            .instruction => try self.emitPointerValue(operand_value),
            else => return Error.UnsupportedOperand,
        }
    }

    fn tvalueByteOffset(self: Context, instruction_value: snapshot_v1.IrInstruction, operand_index: u32) Error!u32 {
        const offset_operand = try self.operand(instruction_value, operand_index);
        if (offset_operand.kind != .constant)
            return Error.InvalidOperandType;
        const offset = (try self.constant(offset_operand.value)).intValue() orelse return Error.InvalidOperandType;
        if (offset < 0 or @mod(offset, 4) != 0 or offset > 4092)
            return Error.InvalidOperandType;
        return @intCast(offset);
    }

    fn emitI64Value(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        switch (operand_value.kind) {
            .constant => {
                const value = try self.constant(operand_value.value);
                try self.body.i64Const(self.allocator, value.int64Value() orelse return Error.InvalidOperandType);
            },
            .instruction => {
                if (operand_value.value >= self.slots.len)
                    return Error.InvalidInstructionResult;
                const slot = self.slots[operand_value.value];
                if (slot.shape != .i64)
                    return Error.InvalidInstructionResult;
                try self.body.localGet(self.allocator, slot.first);
            },
            else => return Error.UnsupportedOperand,
        }
    }

    fn emitF32Value(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        switch (operand_value.kind) {
            .constant => {
                const value = try self.constant(operand_value.value);
                try self.body.f32Const(self.allocator, @floatCast(value.doubleValue() orelse return Error.InvalidOperandType));
            },
            .instruction => {
                if (operand_value.value >= self.slots.len)
                    return Error.InvalidInstructionResult;
                const slot = self.slots[operand_value.value];
                if (slot.shape != .f32)
                    return Error.InvalidInstructionResult;
                try self.body.localGet(self.allocator, slot.first);
            },
            else => return Error.UnsupportedOperand,
        }
    }

    fn emitF64Value(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        switch (operand_value.kind) {
            .constant => {
                const value = try self.constant(operand_value.value);
                try self.body.f64Const(self.allocator, value.doubleValue() orelse return Error.InvalidOperandType);
            },
            .instruction => {
                if (operand_value.value >= self.slots.len)
                    return Error.InvalidInstructionResult;
                const slot = self.slots[operand_value.value];
                if (slot.shape != .f64)
                    return Error.InvalidInstructionResult;
                try self.body.localGet(self.allocator, slot.first);
            },
            else => return Error.UnsupportedOperand,
        }
    }

    fn emitTagValue(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        if (operand_value.kind == .vm_reg) {
            try self.body.localGet(self.allocator, self.base_local);
            try self.body.i32Load(self.allocator, 2, try self.vmRegisterOffset(operand_value, tvalue_tag_offset));
        } else {
            try self.emitI32Value(operand_value);
        }
    }

    fn tvalueSlot(self: Context, operand_value: snapshot_v1.IrOperand) Error!ValueSlot {
        if (operand_value.kind != .instruction or operand_value.value >= self.slots.len)
            return Error.InvalidOperandType;
        const slot = self.slots[operand_value.value];
        if (slot.shape != .tvalue)
            return Error.InvalidInstructionResult;
        return slot;
    }

    fn emitTValuePart(self: Context, operand_value: snapshot_v1.IrOperand, high: bool) Error!void {
        switch (operand_value.kind) {
            .vm_reg => {
                try self.body.localGet(self.allocator, self.base_local);
                const offset = try self.vmRegisterOffset(operand_value, if (high) 8 else 0);
                try self.body.i64Load(self.allocator, 3, offset);
            },
            .instruction => {
                const slot = try self.tvalueSlot(operand_value);
                try self.body.localGet(self.allocator, if (high) slot.second else slot.first);
            },
            else => return Error.UnsupportedOperand,
        }
    }

    fn emitTValueTag(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        if (operand_value.kind == .vm_reg) {
            try self.emitTagValue(operand_value);
            return;
        }

        try self.emitTValuePart(operand_value, true);
        try self.body.i64Const(self.allocator, 32);
        try self.body.opcode(self.allocator, 0x88); // i64.shr_u
        try self.body.opcode(self.allocator, 0xa7); // i32.wrap_i64
    }

    fn emitTValuePayloadI32(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        if (operand_value.kind == .vm_reg) {
            try self.body.localGet(self.allocator, self.base_local);
            try self.body.i32Load(self.allocator, 2, try self.vmRegisterOffset(operand_value, 0));
            return;
        }

        try self.emitTValuePart(operand_value, false);
        try self.body.opcode(self.allocator, 0xa7); // i32.wrap_i64
    }

    fn emitTValueTruthy(self: Context, operand_value: snapshot_v1.IrOperand) Error!void {
        try self.emitTValueTag(operand_value);
        try self.body.i32Const(self.allocator, lua_tag_nil);
        try self.body.i32Ne(self.allocator);

        try self.emitTValueTag(operand_value);
        try self.body.i32Const(self.allocator, lua_tag_boolean);
        try self.body.i32Ne(self.allocator);
        try self.emitTValuePayloadI32(operand_value);
        try self.body.i32Eqz(self.allocator);
        try self.body.i32Eqz(self.allocator);
        try self.body.opcode(self.allocator, 0x72); // i32.or
        try self.body.opcode(self.allocator, 0x71); // i32.and
    }

    fn requireCompiledTarget(self: Context, operand_value: snapshot_v1.IrOperand) Error!u32 {
        if (operand_value.kind != .block)
            return Error.InvalidOperandType;
        const target = try self.snapshot.irBlock(self.function, operand_value.value);
        if (!target.kind.isCompilable() or target.isEmpty())
            return Error.UnsupportedControlFlow;
        return operand_value.value;
    }

    fn requireDispatchTarget(self: Context, operand_value: snapshot_v1.IrOperand) Error!u32 {
        if (operand_value.kind != .block)
            return Error.InvalidOperandType;
        const target = try self.snapshot.irBlock(self.function, operand_value.value);
        if (target.isEmpty() or
            (!target.kind.isCompilable() and
                (target.kind != .fallback or !try self.supportsFallback(target))))
            return Error.UnsupportedControlFlow;
        return operand_value.value;
    }

    fn emitStatusReturn(self: Context, status: i32) Error!void {
        try self.body.i32Const(self.allocator, status);
        try self.body.return_(self.allocator);
    }

    fn emitInstructionResultSet(self: Context, instruction_id: u32) Error!void {
        if (instruction_id >= self.slots.len or self.slots[instruction_id].shape == .none)
            return Error.InvalidInstructionResult;
        try self.body.localSet(self.allocator, self.slots[instruction_id].first);
    }

    fn emitLoadTag(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const source = try self.operand(instruction_value, 0);
        if (source.kind == .vm_const) {
            try self.body.i32Const(self.allocator, try self.vmConstantTag(source));
        } else {
            try self.emitTValueAddress(source);
            const offset = if (source.kind == .vm_reg)
                try self.vmRegisterOffset(source, tvalue_tag_offset)
            else
                tvalue_tag_offset;
            try self.body.i32Load(self.allocator, 2, offset);
        }
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitLoadI32(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const source = try self.operand(instruction_value, 0);
        if (instruction_value.command == .load_pointer) {
            if (source.kind == .vm_const) {
                try self.body.i32Const(self.allocator, @bitCast(@as(u32, @truncate((try self.vmConstantParts(source)).low))));
            } else {
                try self.emitTValueAddress(source);
                const offset = if (source.kind == .vm_reg) try self.vmRegisterOffset(source, 0) else 0;
                try self.body.i32Load(self.allocator, 2, offset);
            }
        } else {
            if (source.kind != .vm_reg)
                return Error.UnsupportedOperand;
            try self.body.localGet(self.allocator, self.base_local);
            try self.body.i32Load(self.allocator, 2, try self.vmRegisterOffset(source, 0));
        }
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitLoadI64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const source = try self.operand(instruction_value, 0);
        if (source.kind == .vm_const) {
            try self.body.i64Const(self.allocator, @bitCast((try self.vmConstantParts(source)).low));
        } else {
            try self.emitTValueAddress(source);
            const offset = if (source.kind == .vm_reg) try self.vmRegisterOffset(source, 0) else 0;
            try self.body.i64Load(self.allocator, 3, offset);
        }
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitLoadFloat(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const source = try self.operand(instruction_value, 0);
        const offset_operand = try self.operand(instruction_value, 1);
        if (offset_operand.kind != .constant)
            return Error.InvalidOperandType;
        const offset = (try self.constant(offset_operand.value)).intValue() orelse return Error.InvalidOperandType;
        if (offset < 0 or offset > 8 or @mod(offset, 4) != 0)
            return Error.InvalidOperandType;
        if (source.kind == .vm_const) {
            const parts = try self.vmConstantParts(source);
            const bits: u32 = switch (offset) {
                0 => @truncate(parts.low),
                4 => @truncate(parts.low >> 32),
                8 => @truncate(parts.high),
                else => unreachable,
            };
            try self.body.f32Const(self.allocator, @bitCast(bits));
        } else {
            try self.emitTValueAddress(source);
            const address_offset = if (source.kind == .vm_reg)
                try self.vmRegisterOffset(source, @intCast(offset))
            else
                @as(u32, @intCast(offset));
            try self.body.f32Load(self.allocator, 2, address_offset);
        }
        try self.emitInstructionResultSet(instruction_id);
    }

    fn storesVmRegister(self: Context, instruction_value: snapshot_v1.IrInstruction, register: u32) Error!bool {
        switch (instruction_value.command) {
            .store_tag,
            .store_extra,
            .store_pointer,
            .store_double,
            .store_int,
            .store_int64,
            .store_vector,
            .store_tvalue,
            .store_split_tvalue,
            => {},
            else => return false,
        }
        if (instruction_value.operand_count == 0)
            return false;
        const destination = try self.operand(instruction_value, 0);
        return destination.kind == .vm_reg and destination.value == register;
    }

    fn classifyBuiltinNumberLoads(self: Context) Error!void {
        @memset(self.builtin_number_sources, std.math.maxInt(u32));
        if (self.builtin_number == null)
            return;
        var block_id: u32 = 0;
        while (block_id < self.function.block_count) : (block_id += 1) {
            const block = try self.snapshot.irBlock(self.function, block_id);
            if (!block.kind.isCompilable() or block.isEmpty())
                continue;

            var guarded_registers = [_]bool{false} ** 256;
            var instruction_id = block.start;
            while (instruction_id <= block.finish) : (instruction_id += 1) {
                const instruction_value = try self.instruction(instruction_id);
                if (instruction_value.command == .load_double and instruction_value.operand_count == 1) {
                    const source = try self.operand(instruction_value, 0);
                    if (source.kind == .vm_reg and source.value < guarded_registers.len and
                        guarded_registers[source.value])
                        self.builtin_number_sources[instruction_id] = source.value;
                }

                if (instruction_value.command == .check_tag and instruction_value.operand_count == 3) {
                    const checked = try self.operand(instruction_value, 0);
                    const expected = try self.operand(instruction_value, 1);
                    const failure = try self.operand(instruction_value, 2);
                    if (checked.kind == .instruction and expected.kind == .constant and
                        failure.kind == .vm_exit and
                        (try self.constant(expected.value)).tagValue() == lua_tag_number and
                        (try self.builtinFallback(failure.value)) != null)
                    {
                        const load_tag = try self.instruction(checked.value);
                        if (load_tag.command == .load_tag and load_tag.operand_count == 1) {
                            const source = try self.operand(load_tag, 0);
                            if (source.kind == .vm_reg and source.value < guarded_registers.len)
                                guarded_registers[source.value] = true;
                        }
                    }
                }

                if (instruction_value.command != .load_double and instruction_value.operand_count != 0) {
                    const destination = try self.operand(instruction_value, 0);
                    if (destination.kind == .vm_reg and destination.value < guarded_registers.len and
                        try self.storesVmRegister(instruction_value, destination.value))
                        guarded_registers[destination.value] = false;
                }
            }
        }
    }

    fn emitLoadDouble(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const source = try self.operand(instruction_value, 0);
        if (source.kind == .vm_const) {
            try self.body.f64Const(self.allocator, @bitCast((try self.vmConstantParts(source)).low));
        } else if (self.builtin_number_sources[instruction_id] != std.math.maxInt(u32)) {
            try self.body.localGet(self.allocator, 0);
            try self.body.i32Const(self.allocator, @intCast(source.value));
            try self.body.call(self.allocator, self.builtin_number orelse return Error.UnsupportedCommand);
        } else {
            try self.emitTValueAddress(source);
            const offset = if (source.kind == .vm_reg) try self.vmRegisterOffset(source, 0) else 0;
            try self.body.f64Load(self.allocator, 3, offset);
        }
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitLoadTValue(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        if (try self.newClosurePatternContaining(instruction_id) != null)
            return;
        if (instruction_id + 1 < self.function.instruction_count and
            (try self.instruction(instruction_id + 1)).command == .set_upvalue)
            _ = try self.setUpvaluePattern(instruction_id + 1);
        if (instruction_value.operand_count != 1 and instruction_value.operand_count != 2 and
            instruction_value.operand_count != 3)
            return Error.InvalidOperandCount;
        if (instruction_id >= self.slots.len or self.slots[instruction_id].shape != .tvalue)
            return Error.InvalidInstructionResult;
        const source = try self.operand(instruction_value, 0);
        const address_offset = if (instruction_value.operand_count >= 2)
            try self.tvalueByteOffset(instruction_value, 1)
        else
            0;
        if (instruction_value.operand_count == 3) {
            const tag = try self.operand(instruction_value, 2);
            if (tag.kind != .constant or (try self.constant(tag.value)).tagValue() == null)
                return Error.InvalidOperandType;
        }
        if (source.kind != .instruction and address_offset != 0)
            return Error.InvalidOperandType;
        if (source.kind == .vm_const) {
            const parts = try self.vmConstantParts(source);
            try self.body.i64Const(self.allocator, @bitCast(parts.low));
            try self.body.localSet(self.allocator, self.slots[instruction_id].first);
            try self.body.i64Const(self.allocator, @bitCast(parts.high));
            try self.body.localSet(self.allocator, self.slots[instruction_id].second);
            return;
        }
        try self.emitTValueAddress(source);
        const value_offset = if (source.kind == .vm_reg)
            try self.vmRegisterOffset(source, address_offset)
        else
            address_offset;
        try self.body.i64Load(self.allocator, 3, value_offset);
        try self.body.localSet(self.allocator, self.slots[instruction_id].first);
        try self.emitTValueAddress(source);
        try self.body.i64Load(self.allocator, 3, value_offset + 8);
        try self.body.localSet(self.allocator, self.slots[instruction_id].second);
    }

    fn emitStoreTag(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        if (try self.newClosurePatternContaining(instruction_id) != null)
            return;
        try self.requireOperandCount(instruction_value, 2);
        const destination = try self.operand(instruction_value, 0);
        const source = try self.operand(instruction_value, 1);
        if (source.kind != .constant or (try self.constant(source.value)).kind != .tag)
            return Error.InvalidOperandType;
        try self.emitTValueAddress(destination);
        try self.emitI32Value(source);
        const offset = if (destination.kind == .vm_reg)
            try self.vmRegisterOffset(destination, tvalue_tag_offset)
        else
            tvalue_tag_offset;
        try self.body.i32Store(self.allocator, 2, offset);
    }

    fn emitStoreDouble(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const destination = try self.operand(instruction_value, 0);
        try self.emitTValueAddress(destination);
        try self.emitF64Value(try self.operand(instruction_value, 1));
        const offset = if (destination.kind == .vm_reg) try self.vmRegisterOffset(destination, 0) else 0;
        try self.body.f64Store(self.allocator, 3, offset);
    }

    fn emitStoreI32(self: Context, instruction_value: snapshot_v1.IrInstruction, field_offset: u32) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const destination = try self.operand(instruction_value, 0);
        const source = try self.operand(instruction_value, 1);
        if (instruction_value.command == .store_int) {
            try self.body.localGet(self.allocator, self.base_local);
            try self.emitI32Value(source);
            try self.body.i32Store(self.allocator, 2, try self.vmRegisterOffset(destination, field_offset));
            return;
        }
        try self.emitTValueAddress(destination);
        switch (instruction_value.command) {
            .store_pointer => try self.emitPointerValue(source),
            .store_extra => {
                if (source.kind != .constant or (try self.constant(source.value)).kind != .int)
                    return Error.InvalidOperandType;
                try self.emitI32Value(source);
            },
            else => return Error.UnsupportedCommand,
        }
        const offset = if (destination.kind == .vm_reg)
            try self.vmRegisterOffset(destination, field_offset)
        else
            field_offset;
        try self.body.i32Store(self.allocator, 2, offset);
    }

    fn emitStoreI64(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const destination = try self.operand(instruction_value, 0);
        try self.body.localGet(self.allocator, self.base_local);
        try self.emitI64Value(try self.operand(instruction_value, 1));
        try self.body.i64Store(self.allocator, 3, try self.vmRegisterOffset(destination, 0));
    }

    fn emitStoreVector(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        if (instruction_value.operand_count != 4 and instruction_value.operand_count != 5)
            return Error.InvalidOperandCount;
        const destination = try self.operand(instruction_value, 0);
        _ = try self.vmRegisterIndex(destination);
        var lane: u32 = 0;
        while (lane < vector_lane_count) : (lane += 1) {
            try self.body.localGet(self.allocator, self.base_local);
            try self.emitF32Value(try self.operand(instruction_value, lane + 1));
            try self.body.f32Store(self.allocator, 2, try self.vmRegisterOffset(destination, lane * 4));
        }
        if (instruction_value.operand_count == 5) {
            try self.body.localGet(self.allocator, self.base_local);
            try self.emitTagValue(try self.operand(instruction_value, 4));
            try self.body.i32Store(self.allocator, 2, try self.vmRegisterOffset(destination, tvalue_tag_offset));
        }
    }

    fn emitStoreTValue(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        if (try self.newClosurePatternContaining(instruction_id) != null)
            return;
        if (instruction_value.operand_count != 2 and instruction_value.operand_count != 3)
            return Error.InvalidOperandCount;
        const destination = try self.operand(instruction_value, 0);
        const source = try self.operand(instruction_value, 1);
        if (source.kind == .instruction) {
            const source_instruction = try self.instruction(source.value);
            if (source_instruction.command == .get_upvalue) {
                if (source.value + 1 != instruction_id) {
                    const first_store = try self.instruction(source.value + 1);
                    if (first_store.command != .store_tvalue or first_store.operand_count != 2)
                        return Error.UnsupportedControlFlow;
                    const first_source = try self.operand(first_store, 1);
                    if (first_source.kind != .instruction or first_source.value != source.value)
                        return Error.UnsupportedControlFlow;
                    var gap = source.value + 2;
                    while (gap < instruction_id) : (gap += 1) {
                        const marker = try self.instruction(gap);
                        if (marker.command != .nop or marker.operand_count != 0)
                            return Error.UnsupportedControlFlow;
                    }
                }
                if (instruction_value.operand_count != 2)
                    return Error.UnsupportedControlFlow;
                try self.requireOperandCount(source_instruction, 1);
                const upvalue = try self.operand(source_instruction, 0);
                if (upvalue.kind != .vm_upvalue or upvalue.value >= self.proto.nups)
                    return Error.InvalidOperandType;

                try self.body.localGet(self.allocator, 0);
                try self.body.i32Const(self.allocator, @intCast(try self.vmRegisterIndex(destination)));
                try self.body.i32Const(self.allocator, @intCast(upvalue.value));
                try self.body.call(self.allocator, self.get_upvalue orelse return Error.UnsupportedCommand);
                return;
            }
        }
        if (source.kind != .instruction or source.value >= self.slots.len or self.slots[source.value].shape != .tvalue)
            return Error.InvalidOperandType;
        const address_offset = if (instruction_value.operand_count == 3)
            try self.tvalueByteOffset(instruction_value, 2)
        else
            0;
        if (destination.kind != .instruction and address_offset != 0)
            return Error.InvalidOperandType;
        try self.emitTValueAddress(destination);
        const destination_offset = if (destination.kind == .vm_reg)
            try self.vmRegisterOffset(destination, address_offset)
        else
            address_offset;
        try self.body.localGet(self.allocator, self.slots[source.value].first);
        try self.body.i64Store(self.allocator, 3, destination_offset);
        try self.emitTValueAddress(destination);
        try self.body.localGet(self.allocator, self.slots[source.value].second);
        try self.body.i64Store(self.allocator, 3, destination_offset + 8);
    }

    fn emitGetUpvalue(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const upvalue = try self.operand(instruction_value, 0);
        if (upvalue.kind != .vm_upvalue or upvalue.value >= self.proto.nups or
            instruction_id + 1 >= self.function.instruction_count)
            return Error.InvalidOperandType;
        const store = try self.instruction(instruction_id + 1);
        if (store.command != .store_tvalue or store.operand_count != 2)
            return Error.UnsupportedControlFlow;
        const store_source = try self.operand(store, 1);
        if (store_source.kind != .instruction or store_source.value != instruction_id)
            return Error.UnsupportedControlFlow;
    }

    fn emitNewClosure(self: Context, instruction_id: u32) Error!void {
        const pattern = try self.newClosurePattern(instruction_id);
        const child_id = std.math.add(u32, self.function_id_base, pattern.child_proto_id) catch return Error.ResourceLimit;
        const terminator = try self.instruction(pattern.marker_start - 1);
        var capture_index: u32 = 0;
        while (capture_index < pattern.capture_count) : (capture_index += 1) {
            const capture = try self.initializedCapture(capture_index, pattern.capture_ir_start);
            try self.emitCaptureCall(pattern.destination, child_id, capture_index, capture, terminator.command == .check_gc and capture_index + 1 == pattern.capture_count);
        }
        try self.emitReloadBase();
    }

    fn emitCaptureCall(self: Context, destination: u32, child_id: u32, capture_index: u32, capture: Capture, check_gc: bool) Error!void {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(destination));
        try self.body.i32Const(self.allocator, @intCast(child_id));
        try self.body.i32Const(self.allocator, @intCast(capture_index));
        try self.body.i32Const(self.allocator, @intCast(@intFromEnum(capture.kind)));
        try self.body.i32Const(self.allocator, @intCast(capture.source));
        try self.body.i32Const(self.allocator, @intFromBool(check_gc));
        try self.body.call(self.allocator, self.newclosure_capture orelse return Error.UnsupportedCommand);
    }

    fn emitSetUpvalue(self: Context, instruction_id: u32) Error!void {
        const pattern = try self.setUpvaluePattern(instruction_id);
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.upvalue_index));
        try self.body.i32Const(self.allocator, @intCast(pattern.source_register));
        try self.body.call(self.allocator, self.set_upvalue orelse return Error.UnsupportedCommand);
    }

    fn emitCloseUpvalues(self: Context, instruction_id: u32) Error!void {
        const instruction_value = try self.instruction(instruction_id);
        try self.requireOperandCount(instruction_value, 1);
        const source = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(source));
        try self.body.call(self.allocator, self.close_upvalues orelse return Error.UnsupportedCommand);
    }

    fn emitAddNumber(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.body.f64Add(self.allocator);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitUnaryI32(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        try self.emitI32Value(try self.operand(instruction_value, 0));
        try self.body.opcode(self.allocator, opcode);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitUnaryI64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        try self.emitI64Value(try self.operand(instruction_value, 0));
        try self.body.opcode(self.allocator, opcode);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitUnaryF32(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        try self.emitF32Value(try self.operand(instruction_value, 0));
        try self.body.opcode(self.allocator, opcode);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitUnaryF64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.body.opcode(self.allocator, opcode);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitBinaryI32(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        try self.emitI32Value(try self.operand(instruction_value, 0));
        try self.emitI32Value(try self.operand(instruction_value, 1));
        try self.body.opcode(self.allocator, opcode);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitBinaryI64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        try self.emitI64Value(try self.operand(instruction_value, 0));
        try self.emitI64Value(try self.operand(instruction_value, 1));
        try self.body.opcode(self.allocator, opcode);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitInvalidI64DivisionGuard(self: Context, lhs: snapshot_v1.IrOperand, rhs: snapshot_v1.IrOperand) Error!void {
        try self.emitI64Value(rhs);
        try self.body.opcode(self.allocator, 0x50); // i64.eqz

        try self.emitI64Value(lhs);
        try self.body.i64Const(self.allocator, std.math.minInt(i64));
        try self.body.opcode(self.allocator, 0x51); // i64.eq
        try self.emitI64Value(rhs);
        try self.body.i64Const(self.allocator, -1);
        try self.body.opcode(self.allocator, 0x51); // i64.eq
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.opcode(self.allocator, 0x72); // i32.or

        try self.body.ifVoid(self.allocator);
        // Well-formed upstream IR puts CHECK_DIV_INT64 before signed division. Keep malformed
        // snapshots on the explicit status boundary instead of exposing Wasm's integer trap.
        try self.emitStatusReturn(status_internal_error);
        try self.body.end(self.allocator);
    }

    fn emitZeroI64DivisorGuard(self: Context, rhs: snapshot_v1.IrOperand) Error!void {
        try self.emitI64Value(rhs);
        try self.body.opcode(self.allocator, 0x50); // i64.eqz
        try self.body.ifVoid(self.allocator);
        // UDIV/UREM and REM/MOD are guarded separately by upstream. Reject malformed streams
        // explicitly so the raw Wasm div/rem instructions below can never trap.
        try self.emitStatusReturn(status_internal_error);
        try self.body.end(self.allocator);
    }

    fn emitSignedDivisionI64(
        self: Context,
        instruction_id: u32,
        instruction_value: snapshot_v1.IrInstruction,
        floor_result: bool,
    ) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        try self.emitInvalidI64DivisionGuard(lhs, rhs);

        try self.emitI64Value(lhs);
        try self.emitI64Value(rhs);
        try self.body.opcode(self.allocator, 0x7f); // i64.div_s
        try self.emitInstructionResultSet(instruction_id);

        if (floor_result) {
            // Native x64 adjusts a truncating quotient when a non-zero remainder and the divisor
            // have opposite signs. This is the mathematical floor for every guarded input.
            try self.emitI64Value(lhs);
            try self.emitI64Value(rhs);
            try self.body.opcode(self.allocator, 0x81); // i64.rem_s
            try self.body.i64Const(self.allocator, 0);
            try self.body.opcode(self.allocator, 0x52); // i64.ne

            try self.emitI64Value(lhs);
            try self.emitI64Value(rhs);
            try self.body.opcode(self.allocator, 0x81); // i64.rem_s
            try self.emitI64Value(rhs);
            try self.body.opcode(self.allocator, 0x85); // i64.xor
            try self.body.i64Const(self.allocator, 0);
            try self.body.opcode(self.allocator, 0x53); // i64.lt_s
            try self.body.opcode(self.allocator, 0x71); // i32.and
            try self.body.ifVoid(self.allocator);
            try self.body.localGet(self.allocator, self.slots[instruction_id].first);
            try self.body.i64Const(self.allocator, 1);
            try self.body.opcode(self.allocator, 0x7d); // i64.sub
            try self.emitInstructionResultSet(instruction_id);
            try self.body.end(self.allocator);
        }
    }

    fn emitUnsignedDivisionI64(
        self: Context,
        instruction_id: u32,
        instruction_value: snapshot_v1.IrInstruction,
        remainder: bool,
    ) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        try self.emitZeroI64DivisorGuard(rhs);
        try self.emitI64Value(lhs);
        try self.emitI64Value(rhs);
        try self.body.opcode(self.allocator, if (remainder) 0x82 else 0x80); // i64.rem_u / i64.div_u
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitSignedRemainderI64(
        self: Context,
        instruction_id: u32,
        instruction_value: snapshot_v1.IrInstruction,
        floor_result: bool,
    ) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        try self.emitZeroI64DivisorGuard(rhs);

        // Wasm rem_s traps for INT64_MIN % -1, while both pinned native lowerers define the
        // remainder (and modulus) as zero for that otherwise overflowing quotient.
        try self.emitI64Value(lhs);
        try self.body.i64Const(self.allocator, std.math.minInt(i64));
        try self.body.opcode(self.allocator, 0x51); // i64.eq
        try self.emitI64Value(rhs);
        try self.body.i64Const(self.allocator, -1);
        try self.body.opcode(self.allocator, 0x51); // i64.eq
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.ifVoid(self.allocator);
        try self.body.i64Const(self.allocator, 0);
        try self.emitInstructionResultSet(instruction_id);
        try self.body.else_(self.allocator);
        try self.emitI64Value(lhs);
        try self.emitI64Value(rhs);
        try self.body.opcode(self.allocator, 0x81); // i64.rem_s
        try self.emitInstructionResultSet(instruction_id);

        if (floor_result) {
            // Lua modulus has the divisor's sign: adjust C's truncating remainder only when it is
            // non-zero and its sign differs from the divisor.
            try self.body.localGet(self.allocator, self.slots[instruction_id].first);
            try self.body.i64Const(self.allocator, 0);
            try self.body.opcode(self.allocator, 0x52); // i64.ne
            try self.body.localGet(self.allocator, self.slots[instruction_id].first);
            try self.emitI64Value(rhs);
            try self.body.opcode(self.allocator, 0x85); // i64.xor
            try self.body.i64Const(self.allocator, 0);
            try self.body.opcode(self.allocator, 0x53); // i64.lt_s
            try self.body.opcode(self.allocator, 0x71); // i32.and
            try self.body.ifVoid(self.allocator);
            try self.body.localGet(self.allocator, self.slots[instruction_id].first);
            try self.emitI64Value(rhs);
            try self.body.opcode(self.allocator, 0x7c); // i64.add
            try self.emitInstructionResultSet(instruction_id);
            try self.body.end(self.allocator);
        }
        try self.body.end(self.allocator);
    }

    fn emitNotI32(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        try self.emitI32Value(try self.operand(instruction_value, 0));
        try self.body.i32Const(self.allocator, -1);
        try self.body.opcode(self.allocator, 0x73); // i32.xor
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitNotI64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        try self.emitI64Value(try self.operand(instruction_value, 0));
        try self.body.i64Const(self.allocator, -1);
        try self.body.opcode(self.allocator, 0x85); // i64.xor
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitSignedI64Shift(
        self: Context,
        instruction_id: u32,
        instruction_value: snapshot_v1.IrInstruction,
        positive_opcode: u8,
        negative_opcode: u8,
        saturate_sign: bool,
    ) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const value = try self.operand(instruction_value, 0);
        const amount = try self.operand(instruction_value, 1);

        try self.emitI64Value(amount);
        try self.body.i64Const(self.allocator, -64);
        try self.body.opcode(self.allocator, 0x57); // i64.le_s
        try self.body.ifVoid(self.allocator);
        try self.body.i64Const(self.allocator, 0);
        try self.emitInstructionResultSet(instruction_id);
        try self.body.else_(self.allocator);

        try self.emitI64Value(amount);
        try self.body.i64Const(self.allocator, 64);
        try self.body.opcode(self.allocator, 0x59); // i64.ge_s
        try self.body.ifVoid(self.allocator);
        if (saturate_sign) {
            try self.emitI64Value(value);
            try self.body.i64Const(self.allocator, 63);
            try self.body.opcode(self.allocator, 0x87); // i64.shr_s
        } else {
            try self.body.i64Const(self.allocator, 0);
        }
        try self.emitInstructionResultSet(instruction_id);
        try self.body.else_(self.allocator);

        try self.emitI64Value(amount);
        try self.body.i64Const(self.allocator, 0);
        try self.body.opcode(self.allocator, 0x53); // i64.lt_s
        try self.body.ifVoid(self.allocator);
        try self.emitI64Value(value);
        try self.body.i64Const(self.allocator, 0);
        try self.emitI64Value(amount);
        try self.body.opcode(self.allocator, 0x7d); // i64.sub
        try self.body.opcode(self.allocator, negative_opcode);
        try self.emitInstructionResultSet(instruction_id);
        try self.body.else_(self.allocator);
        try self.emitI64Value(value);
        try self.emitI64Value(amount);
        try self.body.opcode(self.allocator, positive_opcode);
        try self.emitInstructionResultSet(instruction_id);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
    }

    fn emitByteSwapI32(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const value = try self.operand(instruction_value, 0);
        try self.emitI32Value(value);
        try self.body.i32Const(self.allocator, 0x00ff_00ff);
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.i32Const(self.allocator, 8);
        try self.body.opcode(self.allocator, 0x74); // i32.shl
        try self.emitI32Value(value);
        try self.body.i32Const(self.allocator, 8);
        try self.body.opcode(self.allocator, 0x76); // i32.shr_u
        try self.body.i32Const(self.allocator, 0x00ff_00ff);
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.opcode(self.allocator, 0x72); // i32.or
        try self.body.i32Const(self.allocator, 16);
        try self.body.opcode(self.allocator, 0x77); // i32.rotl
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitAdjacentByteSwapI64(self: Context, value: snapshot_v1.IrOperand) Error!void {
        try self.emitI64Value(value);
        try self.body.i64Const(self.allocator, 0x00ff_00ff_00ff_00ff);
        try self.body.opcode(self.allocator, 0x83); // i64.and
        try self.body.i64Const(self.allocator, 8);
        try self.body.opcode(self.allocator, 0x86); // i64.shl
        try self.emitI64Value(value);
        try self.body.i64Const(self.allocator, 8);
        try self.body.opcode(self.allocator, 0x88); // i64.shr_u
        try self.body.i64Const(self.allocator, 0x00ff_00ff_00ff_00ff);
        try self.body.opcode(self.allocator, 0x83); // i64.and
        try self.body.opcode(self.allocator, 0x84); // i64.or
    }

    fn emitByteSwapI64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const value = try self.operand(instruction_value, 0);
        try self.emitAdjacentByteSwapI64(value);
        try self.body.i64Const(self.allocator, 0x0000_ffff_0000_ffff);
        try self.body.opcode(self.allocator, 0x83); // i64.and
        try self.body.i64Const(self.allocator, 16);
        try self.body.opcode(self.allocator, 0x86); // i64.shl
        try self.emitAdjacentByteSwapI64(value);
        try self.body.i64Const(self.allocator, 16);
        try self.body.opcode(self.allocator, 0x88); // i64.shr_u
        try self.body.i64Const(self.allocator, 0x0000_ffff_0000_ffff);
        try self.body.opcode(self.allocator, 0x83); // i64.and
        try self.body.opcode(self.allocator, 0x84); // i64.or
        try self.body.i64Const(self.allocator, 32);
        try self.body.opcode(self.allocator, 0x89); // i64.rotl
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitBinaryF32(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        try self.emitF32Value(try self.operand(instruction_value, 0));
        try self.emitF32Value(try self.operand(instruction_value, 1));
        try self.body.opcode(self.allocator, opcode);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitBinaryF64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.body.opcode(self.allocator, opcode);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitMulAddNumber(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.body.opcode(self.allocator, 0xa2); // f64.mul
        try self.emitF64Value(try self.operand(instruction_value, 2));
        try self.body.opcode(self.allocator, 0xa0); // f64.add
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitFloorDivisionNumber(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.body.opcode(self.allocator, 0xa3); // f64.div
        try self.body.opcode(self.allocator, 0x9c); // f64.floor
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitModNumber(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        try self.emitF64Value(lhs);
        try self.emitF64Value(lhs);
        try self.emitF64Value(rhs);
        try self.body.opcode(self.allocator, 0xa3); // f64.div
        try self.body.opcode(self.allocator, 0x9c); // f64.floor
        try self.emitF64Value(rhs);
        try self.body.opcode(self.allocator, 0xa2); // f64.mul
        try self.body.opcode(self.allocator, 0xa1); // f64.sub
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitMinMaxNumber(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, comparison_opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        try self.emitF64Value(lhs);
        try self.emitF64Value(rhs);
        try self.emitF64Value(lhs);
        try self.emitF64Value(rhs);
        try self.body.opcode(self.allocator, comparison_opcode);
        try self.body.select(self.allocator);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitRoundNumber(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const value = try self.operand(instruction_value, 0);
        try self.emitF64Value(value);
        try self.body.f64Const(self.allocator, round_number_bias);
        try self.emitF64Value(value);
        try self.body.opcode(self.allocator, 0xa6); // f64.copysign
        try self.body.opcode(self.allocator, 0xa0); // f64.add
        try self.body.opcode(self.allocator, 0x9d); // f64.trunc
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitSignNumber(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const value = try self.operand(instruction_value, 0);
        try self.body.f64Const(self.allocator, 1.0);
        try self.body.f64Const(self.allocator, -1.0);
        try self.body.f64Const(self.allocator, 0.0);
        try self.emitF64Value(value);
        try self.body.f64Const(self.allocator, 0.0);
        try self.body.opcode(self.allocator, 0x63); // f64.lt
        try self.body.select(self.allocator);
        try self.emitF64Value(value);
        try self.body.f64Const(self.allocator, 0.0);
        try self.body.opcode(self.allocator, 0x64); // f64.gt
        try self.body.select(self.allocator);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitMinMaxFloat(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, comparison_opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        try self.emitF32Value(lhs);
        try self.emitF32Value(rhs);
        try self.emitF32Value(lhs);
        try self.emitF32Value(rhs);
        try self.body.opcode(self.allocator, comparison_opcode);
        try self.body.select(self.allocator);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitSignFloat(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const value = try self.operand(instruction_value, 0);
        try self.body.f32Const(self.allocator, 1.0);
        try self.body.f32Const(self.allocator, -1.0);
        try self.body.f32Const(self.allocator, 0.0);
        try self.emitF32Value(value);
        try self.body.f32Const(self.allocator, 0.0);
        try self.body.opcode(self.allocator, 0x5d); // f32.lt
        try self.body.select(self.allocator);
        try self.emitF32Value(value);
        try self.body.f32Const(self.allocator, 0.0);
        try self.body.opcode(self.allocator, 0x5e); // f32.gt
        try self.body.select(self.allocator);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn vectorSlot(self: Context, operand_value: snapshot_v1.IrOperand) Error!ValueSlot {
        if (operand_value.kind != .instruction or operand_value.value >= self.slots.len)
            return Error.InvalidOperandType;
        const slot = self.slots[operand_value.value];
        if (slot.shape != .tvalue)
            return Error.InvalidInstructionResult;
        return slot;
    }

    fn emitVectorLaneBits(self: Context, operand_value: snapshot_v1.IrOperand, lane: u32) Error!void {
        const slot = try self.vectorSlot(operand_value);
        switch (lane) {
            0 => try self.body.localGet(self.allocator, slot.first),
            1 => {
                try self.body.localGet(self.allocator, slot.first);
                try self.body.i64Const(self.allocator, 32);
                try self.body.opcode(self.allocator, 0x88); // i64.shr_u
            },
            2 => try self.body.localGet(self.allocator, slot.second),
            3 => {
                try self.body.localGet(self.allocator, slot.second);
                try self.body.i64Const(self.allocator, 32);
                try self.body.opcode(self.allocator, 0x88); // i64.shr_u
            },
            else => return Error.InvalidOperandType,
        }
        try self.body.opcode(self.allocator, 0xa7); // i32.wrap_i64
    }

    fn emitVectorLane(self: Context, operand_value: snapshot_v1.IrOperand, lane: u32) Error!void {
        try self.emitVectorLaneBits(operand_value, lane);
        try self.body.opcode(self.allocator, 0xbe); // f32.reinterpret_i32
    }

    fn emitVectorPackPrefix(self: Context, instruction_id: u32, lane: u32) Error!void {
        if (instruction_id >= self.slots.len or self.slots[instruction_id].shape != .tvalue)
            return Error.InvalidInstructionResult;
        if (lane == 1)
            try self.body.localGet(self.allocator, self.slots[instruction_id].first)
        else if (lane == 3)
            try self.body.localGet(self.allocator, self.slots[instruction_id].second);
    }

    fn emitVectorLaneBitsSet(self: Context, instruction_id: u32, lane: u32) Error!void {
        const slot = self.slots[instruction_id];
        try self.body.opcode(self.allocator, 0xad); // i64.extend_i32_u
        switch (lane) {
            0 => try self.body.localSet(self.allocator, slot.first),
            1 => {
                try self.body.i64Const(self.allocator, 32);
                try self.body.opcode(self.allocator, 0x86); // i64.shl
                try self.body.opcode(self.allocator, 0x84); // i64.or
                try self.body.localSet(self.allocator, slot.first);
            },
            2 => try self.body.localSet(self.allocator, slot.second),
            3 => {
                try self.body.i64Const(self.allocator, 32);
                try self.body.opcode(self.allocator, 0x86); // i64.shl
                try self.body.opcode(self.allocator, 0x84); // i64.or
                try self.body.localSet(self.allocator, slot.second);
            },
            else => return Error.InvalidOperandType,
        }
    }

    fn emitVectorLaneSet(self: Context, instruction_id: u32, lane: u32) Error!void {
        try self.body.opcode(self.allocator, 0xbc); // i32.reinterpret_f32
        try self.emitVectorLaneBitsSet(instruction_id, lane);
    }

    fn emitVectorUnary(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const value = try self.operand(instruction_value, 0);
        var lane: u32 = 0;
        while (lane < vector_lane_count) : (lane += 1) {
            try self.emitVectorPackPrefix(instruction_id, lane);
            try self.emitVectorLane(value, lane);
            try self.body.opcode(self.allocator, opcode);
            try self.emitVectorLaneSet(instruction_id, lane);
        }
    }

    fn emitVectorBinary(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        var lane: u32 = 0;
        while (lane < vector_lane_count) : (lane += 1) {
            try self.emitVectorPackPrefix(instruction_id, lane);
            try self.emitVectorLane(lhs, lane);
            try self.emitVectorLane(rhs, lane);
            try self.body.opcode(self.allocator, opcode);
            try self.emitVectorLaneSet(instruction_id, lane);
        }
    }

    fn emitFloorDivisionVector(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        var lane: u32 = 0;
        while (lane < vector_lane_count) : (lane += 1) {
            try self.emitVectorPackPrefix(instruction_id, lane);
            try self.emitVectorLane(lhs, lane);
            try self.emitVectorLane(rhs, lane);
            try self.body.opcode(self.allocator, 0x95); // f32.div
            try self.body.opcode(self.allocator, 0x8e); // f32.floor
            try self.emitVectorLaneSet(instruction_id, lane);
        }
    }

    fn emitMulAddVector(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        const addend = try self.operand(instruction_value, 2);
        var lane: u32 = 0;
        while (lane < vector_lane_count) : (lane += 1) {
            try self.emitVectorPackPrefix(instruction_id, lane);
            try self.emitVectorLane(lhs, lane);
            try self.emitVectorLane(rhs, lane);
            try self.body.opcode(self.allocator, 0x94); // f32.mul
            try self.emitVectorLane(addend, lane);
            try self.body.opcode(self.allocator, 0x92); // f32.add
            try self.emitVectorLaneSet(instruction_id, lane);
        }
    }

    fn emitMinMaxVector(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, comparison_opcode: u8) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        var lane: u32 = 0;
        while (lane < vector_lane_count) : (lane += 1) {
            try self.emitVectorPackPrefix(instruction_id, lane);
            try self.emitVectorLaneBits(lhs, lane);
            try self.emitVectorLaneBits(rhs, lane);
            try self.emitVectorLane(lhs, lane);
            try self.emitVectorLane(rhs, lane);
            try self.body.opcode(self.allocator, comparison_opcode);
            try self.body.select(self.allocator);
            try self.emitVectorLaneBitsSet(instruction_id, lane);
        }
    }

    fn emitDotVector(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        var lane: u32 = 0;
        while (lane < vector_lane_count) : (lane += 1) {
            try self.emitVectorLane(lhs, lane);
            try self.emitVectorLane(rhs, lane);
            try self.body.opcode(self.allocator, 0x94); // f32.mul
            if (lane != 0)
                try self.body.opcode(self.allocator, 0x92); // f32.add
        }
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitExtractVector(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const lane_operand = try self.operand(instruction_value, 1);
        if (lane_operand.kind != .constant)
            return Error.InvalidOperandType;
        const lane = (try self.constant(lane_operand.value)).intValue() orelse return Error.InvalidOperandType;
        if (lane < 0 or lane >= @as(i32, @intCast(vector_lane_count)))
            return Error.InvalidOperandType;
        try self.emitVectorLane(try self.operand(instruction_value, 0), @intCast(lane));
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitFloatToVector(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const value = try self.operand(instruction_value, 0);
        var lane: u32 = 0;
        while (lane < vector_lane_count) : (lane += 1) {
            try self.emitVectorPackPrefix(instruction_id, lane);
            try self.emitF32Value(value);
            try self.emitVectorLaneSet(instruction_id, lane);
        }
    }

    fn emitTagVector(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        if (instruction_id >= self.slots.len or self.slots[instruction_id].shape != .tvalue)
            return Error.InvalidInstructionResult;
        const source = try self.vectorSlot(try self.operand(instruction_value, 0));
        const destination = self.slots[instruction_id];
        try self.body.localGet(self.allocator, source.first);
        try self.body.localSet(self.allocator, destination.first);
        try self.body.localGet(self.allocator, source.second);
        try self.body.i64Const(self.allocator, 0xffff_ffff);
        try self.body.opcode(self.allocator, 0x83); // i64.and
        try self.body.i64Const(self.allocator, lua_tag_vector << 32);
        try self.body.opcode(self.allocator, 0x84); // i64.or
        try self.body.localSet(self.allocator, destination.second);
    }

    fn conditionOperand(self: Context, instruction_value: snapshot_v1.IrInstruction, index: u32) Error!snapshot_v1.IrCondition {
        const operand_value = try self.operand(instruction_value, index);
        if (operand_value.kind != .condition)
            return Error.InvalidOperandType;
        return @enumFromInt(@as(u8, @intCast(operand_value.value)));
    }

    fn emitIntegerCondition(self: Context, condition: snapshot_v1.IrCondition) Error!void {
        const opcode: u8 = switch (condition) {
            .equal => 0x46,
            .not_equal => 0x47,
            .less => 0x48,
            .not_less => 0x4e,
            .less_equal => 0x4c,
            .not_less_equal => 0x4a,
            .greater => 0x4a,
            .not_greater => 0x4c,
            .greater_equal => 0x4e,
            .not_greater_equal => 0x48,
            .unsigned_less => 0x49,
            .unsigned_less_equal => 0x4d,
            .unsigned_greater => 0x4b,
            .unsigned_greater_equal => 0x4f,
        };
        try self.body.opcode(self.allocator, opcode);
    }

    fn emitInt64Condition(self: Context, condition: snapshot_v1.IrCondition) Error!void {
        const opcode: u8 = switch (condition) {
            .equal => 0x51,
            .not_equal => 0x52,
            .less => 0x53,
            .not_less => 0x59,
            .less_equal => 0x57,
            .not_less_equal => 0x55,
            .greater => 0x55,
            .not_greater => 0x57,
            .greater_equal => 0x59,
            .not_greater_equal => 0x53,
            .unsigned_less => 0x54,
            .unsigned_less_equal => 0x58,
            .unsigned_greater => 0x56,
            .unsigned_greater_equal => 0x5a,
        };
        try self.body.opcode(self.allocator, opcode);
    }

    fn emitFloatCondition(self: Context, condition: snapshot_v1.IrCondition) Error!void {
        switch (condition) {
            .equal => try self.body.opcode(self.allocator, 0x5b),
            .not_equal => try self.body.opcode(self.allocator, 0x5c),
            .less => try self.body.opcode(self.allocator, 0x5d),
            .not_less => {
                try self.body.opcode(self.allocator, 0x5d);
                try self.body.i32Eqz(self.allocator);
            },
            .less_equal => try self.body.opcode(self.allocator, 0x5f),
            .not_less_equal => {
                try self.body.opcode(self.allocator, 0x5f);
                try self.body.i32Eqz(self.allocator);
            },
            .greater => try self.body.opcode(self.allocator, 0x5e),
            .not_greater => {
                try self.body.opcode(self.allocator, 0x5e);
                try self.body.i32Eqz(self.allocator);
            },
            .greater_equal => try self.body.opcode(self.allocator, 0x60),
            .not_greater_equal => {
                try self.body.opcode(self.allocator, 0x60);
                try self.body.i32Eqz(self.allocator);
            },
            .unsigned_less, .unsigned_less_equal, .unsigned_greater, .unsigned_greater_equal => return Error.UnsupportedCondition,
        }
    }

    fn emitComparisonI32(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        try self.emitI32Value(try self.operand(instruction_value, 0));
        try self.emitI32Value(try self.operand(instruction_value, 1));
        try self.emitIntegerCondition(try self.conditionOperand(instruction_value, 2));
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitComparisonI64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        try self.emitI64Value(try self.operand(instruction_value, 0));
        try self.emitI64Value(try self.operand(instruction_value, 1));
        try self.emitInt64Condition(try self.conditionOperand(instruction_value, 2));
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitComparisonTag(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        const condition = try self.conditionOperand(instruction_value, 2);
        if (condition != .equal and condition != .not_equal)
            return Error.UnsupportedCondition;
        try self.emitTagValue(try self.operand(instruction_value, 0));
        try self.emitTagValue(try self.operand(instruction_value, 1));
        try self.emitIntegerCondition(condition);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitSplitTValueComparison(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 5);
        const expected_tag_operand = try self.operand(instruction_value, 1);
        if (expected_tag_operand.kind != .constant)
            return Error.InvalidOperandType;
        const expected_tag = (try self.constant(expected_tag_operand.value)).tagValue() orelse return Error.InvalidOperandType;
        const condition = try self.conditionOperand(instruction_value, 4);
        if (condition != .equal and condition != .not_equal)
            return Error.UnsupportedCondition;

        try self.emitTagValue(try self.operand(instruction_value, 0));
        try self.emitTagValue(expected_tag_operand);
        try self.emitIntegerCondition(condition);

        const lhs = try self.operand(instruction_value, 2);
        const rhs = try self.operand(instruction_value, 3);
        switch (expected_tag) {
            lua_tag_boolean, lua_tag_string => {
                try self.emitI32Value(lhs);
                try self.emitI32Value(rhs);
                try self.emitIntegerCondition(condition);
            },
            lua_tag_number => {
                try self.emitF64Value(lhs);
                try self.emitF64Value(rhs);
                if (condition == .equal)
                    try self.body.f64Eq(self.allocator)
                else
                    try self.body.f64Ne(self.allocator);
            },
            lua_tag_integer => {
                try self.emitI64Value(lhs);
                try self.emitI64Value(rhs);
                try self.emitInt64Condition(condition);
            },
            else => return Error.UnsupportedOperand,
        }

        try self.body.opcode(self.allocator, if (condition == .equal) 0x71 else 0x72); // i32.and / i32.or
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitSelectNumber(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.emitF64Value(try self.operand(instruction_value, 2));
        try self.emitF64Value(try self.operand(instruction_value, 3));
        try self.body.f64Eq(self.allocator);
        try self.body.select(self.allocator);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitSelectInt64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 5);
        try self.emitI64Value(try self.operand(instruction_value, 1));
        try self.emitI64Value(try self.operand(instruction_value, 0));
        try self.emitI64Value(try self.operand(instruction_value, 2));
        try self.emitI64Value(try self.operand(instruction_value, 3));
        try self.emitInt64Condition(try self.conditionOperand(instruction_value, 4));
        try self.body.select(self.allocator);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitSelectVector(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        const false_value = try self.operand(instruction_value, 0);
        const true_value = try self.operand(instruction_value, 1);
        const lhs = try self.operand(instruction_value, 2);
        const rhs = try self.operand(instruction_value, 3);
        var lane: u32 = 0;
        while (lane < tvalue_lane_count) : (lane += 1) {
            try self.emitVectorPackPrefix(instruction_id, lane);
            try self.emitVectorLaneBits(true_value, lane);
            try self.emitVectorLaneBits(false_value, lane);
            if (lane < vector_lane_count) {
                try self.emitVectorLane(lhs, lane);
                try self.emitVectorLane(rhs, lane);
            } else {
                // Upstream vecOp normalizes the non-semantic W lane to zero even when the source
                // TValue carries a tag in its high word. Preserve the selected raw lane above, but
                // compare the normalized vector operands here.
                try self.body.f32Const(self.allocator, 0.0);
                try self.body.f32Const(self.allocator, 0.0);
            }
            try self.body.opcode(self.allocator, 0x5b); // f32.eq
            try self.body.select(self.allocator);
            try self.emitVectorLaneBitsSet(instruction_id, lane);
        }
    }

    fn emitSelectIfTruthy(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        if (instruction_id >= self.slots.len or self.slots[instruction_id].shape != .tvalue)
            return Error.InvalidInstructionResult;
        const condition = try self.operand(instruction_value, 0);
        const true_value = try self.operand(instruction_value, 1);
        const false_value = try self.operand(instruction_value, 2);
        const destination = self.slots[instruction_id];

        try self.emitTValuePart(true_value, false);
        try self.emitTValuePart(false_value, false);
        try self.emitTValueTruthy(condition);
        try self.body.select(self.allocator);
        try self.body.localSet(self.allocator, destination.first);

        try self.emitTValuePart(true_value, true);
        try self.emitTValuePart(false_value, true);
        try self.emitTValueTruthy(condition);
        try self.body.select(self.allocator);
        try self.body.localSet(self.allocator, destination.second);
    }

    fn emitCopyI32(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        try self.emitI32Value(try self.operand(instruction_value, 0));
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitNotAny(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const tag = try self.operand(instruction_value, 0);
        const value = try self.operand(instruction_value, 1);
        try self.emitI32Value(tag);
        try self.body.i32Const(self.allocator, lua_tag_nil);
        try self.body.i32Eq(self.allocator);
        try self.emitI32Value(tag);
        try self.body.i32Const(self.allocator, lua_tag_boolean);
        try self.body.i32Eq(self.allocator);
        try self.emitI32Value(value);
        try self.body.i32Eqz(self.allocator);
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.opcode(self.allocator, 0x72); // i32.or
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitCheckDivInt64(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        const failure = try self.operand(instruction_value, 2);

        // Reject b == 0 and INT64_MIN / -1, exactly the two cases guarded by the pinned native
        // lowerers before their signed division instructions.
        try self.emitI64Value(rhs);
        try self.body.opcode(self.allocator, 0x50); // i64.eqz
        try self.emitI64Value(lhs);
        try self.body.i64Const(self.allocator, std.math.minInt(i64));
        try self.body.opcode(self.allocator, 0x51); // i64.eq
        try self.emitI64Value(rhs);
        try self.body.i64Const(self.allocator, -1);
        try self.body.opcode(self.allocator, 0x51); // i64.eq
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.opcode(self.allocator, 0x72); // i32.or
        try self.body.ifVoid(self.allocator);
        switch (failure.kind) {
            .block => {
                const target_block = try self.snapshot.irBlock(self.function, failure.value);
                if (target_block.kind == .fallback and !try self.supportsFallback(target_block)) {
                    try self.emitStatusReturn(status_unsupported_type);
                } else {
                    const target = if (target_block.kind == .fallback)
                        failure.value
                    else
                        try self.requireCompiledTarget(failure);
                    try self.body.i32Const(self.allocator, @intCast(target));
                    try self.body.localSet(self.allocator, self.dispatch_local);
                    try self.body.branch(self.allocator, 2);
                }
            },
            // Strict AOT has no bytecode VM exit to resume yet. Match the existing CHECK_TAG
            // boundary until the WP5 error helper can preserve the precise Luau error identity.
            .vm_exit => try self.emitStatusReturn(status_unsupported_type),
            .undef => try self.emitStatusReturn(status_internal_error),
            else => return Error.InvalidOperandType,
        }
        try self.body.end(self.allocator);
    }

    fn emitBuiltinTypeError(
        self: Context,
        instruction_value: snapshot_v1.IrInstruction,
        pc: u32,
    ) Error!bool {
        const fallback = (try self.builtinFallback(pc)) orelse return false;
        const checked = try self.operand(instruction_value, 0);
        const expected = try self.operand(instruction_value, 1);
        if (checked.kind != .instruction or expected.kind != .constant)
            return false;
        const load = try self.instruction(checked.value);
        if (load.command != .load_tag or load.operand_count != 1)
            return false;
        const source_register = try self.vmRegisterIndex(try self.operand(load, 0));
        var argument: ?u32 = null;
        var index: u32 = 0;
        while (index < fallback.argument_count) : (index += 1) {
            if (fallback.argument_registers[index] == source_register) {
                if (argument != null)
                    return false;
                argument = index + 1;
            }
        }
        const expected_tag = (try self.constant(expected.value)).tagValue() orelse return false;
        const name = try self.string_keys.intern(self.allocator, fallback.name);
        try self.emitPcLocation(fallback.pc);
        try self.body.localGet(self.allocator, 0);
        try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(name.offset));
        try self.body.i32Const(self.allocator, @intCast(name.length));
        try self.body.i32Const(self.allocator, @intCast(argument orelse return false));
        try self.body.i32Const(self.allocator, @intCast(expected_tag));
        try self.body.i32Const(self.allocator, @intCast(source_register));
        try self.body.call(self.allocator, self.builtin_type_error orelse return Error.UnsupportedCommand);
        try self.body.i32Const(self.allocator, 1);
        try self.body.i32Ne(self.allocator);
        try self.emitInternalErrorIf();
        return true;
    }

    fn emitCheckTag(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        try self.emitI32Value(try self.operand(instruction_value, 0));
        try self.emitI32Value(try self.operand(instruction_value, 1));
        const failure = try self.operand(instruction_value, 2);
        try self.body.i32Ne(self.allocator);
        try self.body.ifVoid(self.allocator);
        switch (failure.kind) {
            .block => {
                const target_block = try self.snapshot.irBlock(self.function, failure.value);
                if (target_block.kind == .fallback and !try self.supportsFallback(target_block)) {
                    // Preserve the existing numeric tier for fallback shapes that have not been
                    // normalized yet. A guard hit fails through the explicit status boundary; the
                    // unsupported fallback instructions are never emitted or accidentally entered.
                    try self.emitStatusReturn(status_unsupported_type);
                } else {
                    const target = if (target_block.kind == .fallback)
                        failure.value
                    else
                        try self.requireCompiledTarget(failure);
                    try self.body.i32Const(self.allocator, @intCast(target));
                    try self.body.localSet(self.allocator, self.dispatch_local);
                    // CHECK_TAG's conditional is nested inside the selected-block conditional.
                    try self.body.branch(self.allocator, 2);
                }
            },
            .vm_exit => if (!try self.emitBuiltinTypeError(instruction_value, failure.value))
                try self.emitStatusReturn(status_unsupported_type),
            .undef => try self.emitStatusReturn(status_internal_error),
            else => return Error.InvalidOperandType,
        }
        try self.body.end(self.allocator);
    }

    fn emitInvalidSignedConversion(self: Context, source: snapshot_v1.IrOperand, lower: f64, upper: f64) Error!void {
        try self.emitF64Value(source);
        try self.emitF64Value(source);
        try self.body.f64Ne(self.allocator); // NaN
        try self.emitF64Value(source);
        try self.body.f64Const(self.allocator, lower);
        try self.body.f64Lt(self.allocator);
        try self.body.opcode(self.allocator, 0x72); // i32.or
        try self.emitF64Value(source);
        try self.body.f64Const(self.allocator, upper);
        try self.body.f64Ge(self.allocator);
        try self.body.opcode(self.allocator, 0x72); // i32.or
    }

    fn emitNumToInt(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const source = try self.operand(instruction_value, 0);
        try self.emitInvalidSignedConversion(source, -2147483648.0, 2147483648.0);
        try self.body.ifVoid(self.allocator);
        // Match the pinned x86 cvttsd2si invalid result instead of exposing a trapping Wasm cast.
        try self.body.i32Const(self.allocator, std.math.minInt(i32));
        try self.emitInstructionResultSet(instruction_id);
        try self.body.else_(self.allocator);
        try self.emitF64Value(source);
        try self.body.opcode(self.allocator, 0xaa); // i32.trunc_f64_s
        try self.emitInstructionResultSet(instruction_id);
        try self.body.end(self.allocator);
    }

    fn emitNumToInt64(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const source = try self.operand(instruction_value, 0);
        try self.emitInvalidSignedConversion(source, -9223372036854775808.0, 9223372036854775808.0);
        try self.body.ifVoid(self.allocator);
        try self.body.i64Const(self.allocator, std.math.minInt(i64));
        try self.emitInstructionResultSet(instruction_id);
        try self.body.else_(self.allocator);
        try self.emitF64Value(source);
        try self.body.opcode(self.allocator, 0xb0); // i64.trunc_f64_s
        try self.emitInstructionResultSet(instruction_id);
        try self.body.end(self.allocator);
    }

    fn emitNumToUint(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const source = try self.operand(instruction_value, 0);
        // Pinned NUM_TO_UINT is `(unsigned)(long long)n`: perform the signed i64 conversion first,
        // then keep the low 32 bits, including the pinned invalid-conversion result.
        try self.emitInvalidSignedConversion(source, -9223372036854775808.0, 9223372036854775808.0);
        try self.body.ifVoid(self.allocator);
        try self.body.i32Const(self.allocator, 0); // low bits of INT64_MIN
        try self.emitInstructionResultSet(instruction_id);
        try self.body.else_(self.allocator);
        try self.emitF64Value(source);
        try self.body.opcode(self.allocator, 0xb0); // i64.trunc_f64_s
        try self.body.opcode(self.allocator, 0xa7); // i32.wrap_i64
        try self.emitInstructionResultSet(instruction_id);
        try self.body.end(self.allocator);
    }

    fn emitBufferLengthCheck(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        _ = instruction_id;
        try self.requireOperandCount(instruction_value, 6);
        const pointer = try self.operand(instruction_value, 0);
        const index = try self.operand(instruction_value, 1);
        const original = try self.operand(instruction_value, 4);
        const failure = try self.operand(instruction_value, 5);
        const min_offset = try self.intConstant(try self.operand(instruction_value, 2));
        const max_offset = try self.intConstant(try self.operand(instruction_value, 3));
        if (min_offset >= max_offset or min_offset < -4095 or max_offset > 4095 or
            try self.loadedPointerRegister(pointer) == null or
            (index.kind != .instruction and index.kind != .constant) or
            (original.kind != .undef and original.kind != .instruction))
            return Error.UnsupportedControlFlow;
        if (failure.kind == .vm_exit) {
            const fallback = (try self.builtinFallback(failure.value)) orelse
                return Error.UnsupportedControlFlow;
            if (!isBufferBuiltinId(fallback.id))
                return Error.UnsupportedControlFlow;
        }

        // The native guard's original-number roundtrip is an optimization exit, not a language
        // rejection: the pinned C fallback truncates fractional numeric offsets. Generated code
        // therefore uses NUM_TO_INT's pinned result and applies only the actual buffer bound.
        if (min_offset >= 0) {
            try self.emitI32Value(index);
            try self.body.opcode(self.allocator, 0xad); // i64.extend_i32_u
            try self.body.i64Const(self.allocator, max_offset);
        } else {
            try self.emitI32Value(index);
            try self.body.i32Const(self.allocator, min_offset);
            try self.body.opcode(self.allocator, 0x6a); // i32.add
            try self.body.opcode(self.allocator, 0xad); // i64.extend_i32_u
            try self.body.i64Const(self.allocator, max_offset - min_offset);
        }
        try self.body.opcode(self.allocator, 0x7c); // i64.add
        try self.emitPointerValue(pointer);
        try self.body.i32Load(self.allocator, 2, buffer_len_offset);
        try self.body.opcode(self.allocator, 0xad); // i64.extend_i32_u
        try self.body.opcode(self.allocator, 0x56); // i64.gt_u
        if (failure.kind != .vm_exit) {
            try self.emitGuardFailure(failure);
            return;
        }

        try self.body.ifVoid(self.allocator);
        try self.emitPcLocation(failure.value);
        try self.body.localGet(self.allocator, 0);
        try self.body.call(self.allocator, self.buffer_bounds_error orelse return Error.UnsupportedCommand);
        try self.emitStatusReturn(status_internal_error);
        try self.body.end(self.allocator);
    }

    fn emitBufferAddress(self: Context, pointer: snapshot_v1.IrOperand, index: snapshot_v1.IrOperand) Error!void {
        try self.emitPointerValue(pointer);
        try self.emitI32Value(index);
        try self.body.opcode(self.allocator, 0x6a); // i32.add
        try self.body.i32Const(self.allocator, @intCast(buffer_data_offset));
        try self.body.opcode(self.allocator, 0x6a); // i32.add
    }

    fn emitUnalignedMemoryOp(self: Context, opcode: u8) Error!void {
        try self.body.opcode(self.allocator, opcode);
        try self.body.opcode(self.allocator, 0); // alignment exponent
        try self.body.opcode(self.allocator, 0); // offset
    }

    fn emitBufferRead(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        if (!try self.bufferOperationOwnedByRange(instruction_id, instruction_value))
            return Error.UnsupportedControlFlow;
        try self.requireOperandCount(instruction_value, 3);
        try self.emitBufferAddress(try self.operand(instruction_value, 0), try self.operand(instruction_value, 1));
        switch (instruction_value.command) {
            ir_cmd_buffer_readi8 => try self.emitUnalignedMemoryOp(0x2c), // i32.load8_s
            ir_cmd_buffer_readu8 => try self.emitUnalignedMemoryOp(0x2d), // i32.load8_u
            ir_cmd_buffer_readi16 => try self.emitUnalignedMemoryOp(0x2e), // i32.load16_s
            ir_cmd_buffer_readu16 => try self.emitUnalignedMemoryOp(0x2f), // i32.load16_u
            ir_cmd_buffer_readi32 => try self.body.i32Load(self.allocator, 0, 0),
            ir_cmd_buffer_readf32 => try self.body.f32Load(self.allocator, 0, 0),
            ir_cmd_buffer_readf64 => try self.body.f64Load(self.allocator, 0, 0),
            ir_cmd_buffer_readi64 => try self.body.i64Load(self.allocator, 0, 0),
            else => return Error.UnsupportedCommand,
        }
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitBufferWrite(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        if (!try self.bufferOperationOwnedByRange(instruction_id, instruction_value))
            return Error.UnsupportedControlFlow;
        try self.requireOperandCount(instruction_value, 4);
        try self.emitBufferAddress(try self.operand(instruction_value, 0), try self.operand(instruction_value, 1));
        const value = try self.operand(instruction_value, 2);
        switch (instruction_value.command) {
            ir_cmd_buffer_writei8 => {
                try self.emitI32Value(value);
                try self.emitUnalignedMemoryOp(0x3a); // i32.store8
            },
            ir_cmd_buffer_writei16 => {
                try self.emitI32Value(value);
                try self.emitUnalignedMemoryOp(0x3b); // i32.store16
            },
            ir_cmd_buffer_writei32 => {
                try self.emitI32Value(value);
                try self.body.i32Store(self.allocator, 0, 0);
            },
            ir_cmd_buffer_writef32 => {
                try self.emitF32Value(value);
                try self.body.f32Store(self.allocator, 0, 0);
            },
            ir_cmd_buffer_writef64 => {
                try self.emitF64Value(value);
                try self.body.f64Store(self.allocator, 0, 0);
            },
            ir_cmd_buffer_writei64 => {
                try self.emitI64Value(value);
                try self.body.i64Store(self.allocator, 0, 0);
            },
            else => return Error.UnsupportedCommand,
        }
    }

    fn emitUserdataWrite(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        const pointer = try self.operand(instruction_value, 0);
        const offset = try self.uintConstant(try self.operand(instruction_value, 1));
        try self.emitPointerValue(pointer);
        const data_offset = std.math.add(u32, userdata_data_offset, offset) catch return Error.ResourceLimit;
        try self.body.i32Const(self.allocator, @intCast(data_offset));
        try self.body.opcode(self.allocator, 0x6a); // i32.add
        const value = try self.operand(instruction_value, 2);
        switch (instruction_value.command) {
            ir_cmd_buffer_writei8 => {
                try self.emitI32Value(value);
                try self.emitUnalignedMemoryOp(0x3a); // i32.store8
            },
            ir_cmd_buffer_writei16 => {
                try self.emitI32Value(value);
                try self.emitUnalignedMemoryOp(0x3b); // i32.store16
            },
            ir_cmd_buffer_writei32 => {
                try self.emitI32Value(value);
                try self.body.i32Store(self.allocator, 0, 0);
            },
            ir_cmd_buffer_writef32 => {
                try self.emitF32Value(value);
                try self.body.f32Store(self.allocator, 0, 0);
            },
            ir_cmd_buffer_writef64 => {
                try self.emitF64Value(value);
                try self.body.f64Store(self.allocator, 0, 0);
            },
            ir_cmd_buffer_writei64 => {
                try self.emitI64Value(value);
                try self.body.i64Store(self.allocator, 0, 0);
            },
            else => return Error.UnsupportedCommand,
        }
    }

    fn loadedPointerRegister(self: Context, pointer: snapshot_v1.IrOperand) Error!?u32 {
        if (pointer.kind != .instruction or pointer.value >= self.function.instruction_count)
            return null;
        const load = try self.instruction(pointer.value);
        if (load.command != .load_pointer or load.operand_count != 1)
            return null;
        const source = try self.operand(load, 0);
        if (source.kind != .vm_reg or source.value >= self.proto.max_stack_size)
            return null;
        return source.value;
    }

    fn rootedTablePointerRegister(self: Context, pointer: snapshot_v1.IrOperand) Error!?u32 {
        if (try self.loadedPointerRegister(pointer)) |register|
            return register;
        if (pointer.kind != .instruction or pointer.value >= self.function.instruction_count)
            return null;
        if (try self.tableAllocationPatternAt(pointer.value)) |pattern|
            return pattern.destination;
        if (pointer.value != 0)
            if (try self.dupTablePatternAt(pointer.value - 1)) |pattern|
                if (pattern.start + 1 == pointer.value) return pattern.destination;
        return null;
    }

    fn emitRegisterTagMismatch(self: Context, register: u32, expected: i32) Error!void {
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Load(self.allocator, 2, register * tvalue_size + tvalue_tag_offset);
        try self.body.i32Const(self.allocator, expected);
        try self.body.i32Ne(self.allocator);
    }

    fn emitCheckUserdataTag(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        const pointer = try self.operand(instruction_value, 0);
        const expected = try self.uintConstant(try self.operand(instruction_value, 1));
        if (expected >= lua_utag_limit)
            return Error.InvalidOperandType;
        const failure = try self.operand(instruction_value, 2);
        if (try self.loadedPointerRegister(pointer)) |register| {
            try self.emitRegisterTagMismatch(register, lua_tag_userdata);
            try self.emitGuardFailure(failure);
        } else if (pointer.kind != .instruction or
            try self.userdataAllocationPatternContaining(pointer.value) == null)
            return Error.UnsupportedControlFlow;

        try self.body.localGet(self.allocator, 0);
        try self.emitPointerValue(pointer);
        try self.body.i32Const(self.allocator, @intCast(expected));
        try self.body.call(self.allocator, self.check_userdata_tag orelse return Error.UnsupportedCommand);
        try self.body.i32Eqz(self.allocator);
        try self.emitGuardFailure(failure);
    }

    fn emitInternalErrorIf(self: Context) Error!void {
        try self.body.ifVoid(self.allocator);
        try self.emitStatusReturn(status_internal_error);
        try self.body.end(self.allocator);
    }

    fn emitBarrierObject(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        const owner = try self.operand(instruction_value, 0);
        const source = try self.operand(instruction_value, 1);
        const static_tag = try self.operand(instruction_value, 2);
        if (source.kind != .vm_reg or source.value >= self.proto.max_stack_size or
            (static_tag.kind != .undef and static_tag.kind != .constant))
            return Error.InvalidOperandType;
        if (static_tag.kind == .constant and (try self.constant(static_tag.value)).tagValue() == null)
            return Error.InvalidOperandType;

        if (try self.loadedPointerRegister(owner)) |register| {
            try self.body.localGet(self.allocator, self.base_local);
            try self.body.i32Load(self.allocator, 2, register * tvalue_size + tvalue_tag_offset);
            try self.body.i32Const(self.allocator, lua_tag_string);
            try self.body.opcode(self.allocator, 0x48); // i32.lt_s
            try self.body.localGet(self.allocator, self.base_local);
            try self.body.i32Load(self.allocator, 2, register * tvalue_size + tvalue_tag_offset);
            try self.body.i32Const(self.allocator, 13);
            try self.body.opcode(self.allocator, 0x4a); // i32.gt_s
            try self.body.opcode(self.allocator, 0x72); // i32.or
            try self.emitInternalErrorIf();
        } else if (owner.kind != .instruction or
            try self.userdataAllocationPatternContaining(owner.value) == null)
            return Error.UnsupportedControlFlow;

        try self.body.localGet(self.allocator, 0);
        try self.emitPointerValue(owner);
        try self.body.i32Const(self.allocator, @intCast(source.value));
        try self.body.call(self.allocator, self.barrier_object orelse return Error.UnsupportedCommand);
    }

    fn emitBarrierTableBack(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const table = try self.operand(instruction_value, 0);
        const register = (try self.loadedPointerRegister(table)) orelse return Error.UnsupportedControlFlow;
        try self.emitRegisterTagMismatch(register, lua_tag_table);
        try self.emitInternalErrorIf();
        try self.body.localGet(self.allocator, 0);
        try self.emitPointerValue(table);
        try self.body.call(self.allocator, self.barrier_table_back orelse return Error.UnsupportedCommand);
    }

    fn emitBufferAdjustStack(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        _ = instruction_id;
        try self.requireOperandCount(instruction_value, 2);
        const count = try self.intConstant(try self.operand(instruction_value, 1));
        if (count < 0)
            return Error.InvalidOperandType;
        try self.emitAdjustStackConstant(
            try self.vmRegisterIndex(try self.operand(instruction_value, 0)),
            @intCast(count),
        );
    }

    fn emitGuardFailure(self: Context, failure: snapshot_v1.IrOperand) Error!void {
        try self.body.ifVoid(self.allocator);
        switch (failure.kind) {
            .block => {
                const target_block = try self.snapshot.irBlock(self.function, failure.value);
                if (target_block.kind == .fallback and !try self.supportsFallback(target_block)) {
                    try self.emitStatusReturn(status_unsupported_type);
                } else {
                    const target = if (target_block.kind == .fallback)
                        failure.value
                    else
                        try self.requireCompiledTarget(failure);
                    try self.body.i32Const(self.allocator, @intCast(target));
                    try self.body.localSet(self.allocator, self.dispatch_local);
                    // The guard conditional is nested inside the selected-block conditional.
                    try self.body.branch(self.allocator, 2);
                }
            },
            .vm_exit => try self.emitStatusReturn(status_unsupported_type),
            .undef => try self.emitStatusReturn(status_internal_error),
            else => return Error.InvalidOperandType,
        }
        try self.body.end(self.allocator);
    }

    fn emitCheckTruthy(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        const tag = try self.operand(instruction_value, 0);
        const value = try self.operand(instruction_value, 1);

        // Fail for nil, or for a boolean whose payload is zero. Every other tag is truthy.
        try self.emitI32Value(tag);
        try self.body.i32Const(self.allocator, lua_tag_nil);
        try self.body.i32Eq(self.allocator);
        try self.emitI32Value(tag);
        try self.body.i32Const(self.allocator, lua_tag_boolean);
        try self.body.i32Eq(self.allocator);
        try self.emitI32Value(value);
        try self.body.i32Eqz(self.allocator);
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.opcode(self.allocator, 0x72); // i32.or
        try self.emitGuardFailure(try self.operand(instruction_value, 2));
    }

    fn emitCheckCompareNumber(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.emitNumericCondition(try self.conditionOperand(instruction_value, 2));
        try self.body.i32Eqz(self.allocator);
        try self.emitGuardFailure(try self.operand(instruction_value, 3));
    }

    fn emitCheckCompareInteger(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        try self.emitI32Value(try self.operand(instruction_value, 0));
        try self.emitI32Value(try self.operand(instruction_value, 1));
        try self.emitIntegerCondition(try self.conditionOperand(instruction_value, 2));
        try self.body.i32Eqz(self.allocator);
        try self.emitGuardFailure(try self.operand(instruction_value, 3));
    }

    fn emitCheckCompareInt64(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        try self.emitI64Value(try self.operand(instruction_value, 0));
        try self.emitI64Value(try self.operand(instruction_value, 1));
        try self.emitInt64Condition(try self.conditionOperand(instruction_value, 2));
        try self.body.i32Eqz(self.allocator);
        try self.emitGuardFailure(try self.operand(instruction_value, 3));
    }

    fn savedPc(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!u32 {
        try self.requireOperandCount(instruction_value, 1);
        const operand_value = try self.operand(instruction_value, 0);
        if (operand_value.kind != .constant)
            return Error.InvalidOperandType;
        return (try self.constant(operand_value.value)).uintValue() orelse Error.InvalidOperandType;
    }

    fn uintConstant(self: Context, operand_value: snapshot_v1.IrOperand) Error!u32 {
        if (operand_value.kind != .constant)
            return Error.InvalidOperandType;
        return (try self.constant(operand_value.value)).uintValue() orelse Error.InvalidOperandType;
    }

    fn intConstant(self: Context, operand_value: snapshot_v1.IrOperand) Error!i32 {
        if (operand_value.kind != .constant)
            return Error.InvalidOperandType;
        return (try self.constant(operand_value.value)).intValue() orelse Error.InvalidOperandType;
    }

    fn nonnegativeConstant(self: Context, operand_value: snapshot_v1.IrOperand) Error!u32 {
        if (operand_value.kind != .constant)
            return Error.InvalidOperandType;
        const value = try self.constant(operand_value.value);
        if (value.uintValue()) |result|
            return result;
        const signed = value.intValue() orelse return Error.InvalidOperandType;
        if (signed < 0)
            return Error.InvalidOperandType;
        return @intCast(signed);
    }

    fn genericIterationAux(self: Context, operand_value: snapshot_v1.IrOperand) Error!u32 {
        const encoded: u32 = @bitCast(try self.intConstant(operand_value));
        if (encoded & 0x7fff_ff00 != 0)
            return Error.InvalidOperandType;
        const count = encoded & 0xff;
        if (count == 0 or (encoded & 0x8000_0000 != 0 and count != 2))
            return Error.InvalidOperandType;
        return encoded;
    }

    fn sameOperand(lhs: snapshot_v1.IrOperand, rhs: snapshot_v1.IrOperand) bool {
        return lhs.kind == rhs.kind and lhs.value == rhs.value;
    }

    fn operandIntConstant(self: Context, operand_value: snapshot_v1.IrOperand) Error!?i32 {
        if (operand_value.kind != .constant)
            return null;
        return (try self.constant(operand_value.value)).intValue();
    }

    fn compilableBlockContaining(self: Context, instruction_id: u32) Error!?snapshot_v1.IrBlock {
        var block_id: u32 = 0;
        while (block_id < self.function.block_count) : (block_id += 1) {
            const block = try self.snapshot.irBlock(self.function, block_id);
            if (block.kind.isCompilable() and !block.isEmpty() and
                instruction_id >= block.start and instruction_id <= block.finish)
                return block;
        }
        return null;
    }

    fn bufferAccessWidth(command: snapshot_v1.IrCommand) ?u32 {
        return switch (command) {
            ir_cmd_buffer_readi8, ir_cmd_buffer_readu8, ir_cmd_buffer_writei8 => 1,
            ir_cmd_buffer_readi16, ir_cmd_buffer_readu16, ir_cmd_buffer_writei16 => 2,
            ir_cmd_buffer_readi32,
            ir_cmd_buffer_readf32,
            ir_cmd_buffer_writei32,
            ir_cmd_buffer_writef32,
            => 4,
            ir_cmd_buffer_readf64,
            ir_cmd_buffer_readi64,
            ir_cmd_buffer_writef64,
            ir_cmd_buffer_writei64,
            => 8,
            else => null,
        };
    }

    fn bufferIndexOffset(
        self: Context,
        base: snapshot_v1.IrOperand,
        index: snapshot_v1.IrOperand,
    ) Error!?i32 {
        if (sameOperand(base, index))
            return 0;
        if (try self.operandIntConstant(base)) |base_value| {
            if (try self.operandIntConstant(index)) |index_value|
                return std.math.sub(i32, index_value, base_value) catch null;
        }
        if (index.kind != .instruction or index.value >= self.function.instruction_count)
            return null;
        const arithmetic = try self.instruction(index.value);
        if (arithmetic.operand_count != 2 or
            (arithmetic.command != .add_int and arithmetic.command != .sub_int))
            return null;
        const lhs = try self.operand(arithmetic, 0);
        const rhs = try self.operand(arithmetic, 1);
        if (sameOperand(lhs, base)) {
            const displacement = (try self.operandIntConstant(rhs)) orelse return null;
            return if (arithmetic.command == .add_int)
                displacement
            else
                std.math.sub(i32, 0, displacement) catch null;
        }
        if (arithmetic.command == .add_int and sameOperand(rhs, base))
            return (try self.operandIntConstant(lhs)) orelse null;
        return null;
    }

    fn bufferOperationOwnedByRange(
        self: Context,
        instruction_id: u32,
        instruction_value: snapshot_v1.IrInstruction,
    ) Error!bool {
        const width = bufferAccessWidth(instruction_value.command) orelse return false;
        if (instruction_value.operand_count < 3)
            return false;
        const pointer = try self.operand(instruction_value, 0);
        const index = try self.operand(instruction_value, 1);
        const tag = try self.operand(instruction_value, instruction_value.operand_count - 1);
        if (tag.kind != .constant or (try self.constant(tag.value)).tagValue() != lua_tag_buffer or
            try self.loadedPointerRegister(pointer) == null)
            return false;

        const block = (try self.compilableBlockContaining(instruction_id)) orelse return false;
        var cursor = instruction_id;
        while (cursor > block.start) {
            cursor -= 1;
            const candidate = try self.instruction(cursor);
            if (candidate.command != ir_cmd_check_buffer_len or candidate.operand_count != 6)
                continue;
            if (!sameOperand(pointer, try self.operand(candidate, 0)))
                continue;
            const offset = (try self.bufferIndexOffset(try self.operand(candidate, 1), index)) orelse
                continue;
            const min_offset = (try self.operandIntConstant(try self.operand(candidate, 2))) orelse
                continue;
            const max_offset = (try self.operandIntConstant(try self.operand(candidate, 3))) orelse
                continue;
            const end_offset = std.math.add(i64, @as(i64, offset), @as(i64, width)) catch continue;
            if (offset >= min_offset and end_offset <= max_offset)
                return true;
        }
        return false;
    }

    fn integerCreatePatternAt(self: Context, check_id: u32) Error!?IntegerCreatePattern {
        if (check_id < 5 or check_id + 2 >= self.function.instruction_count)
            return null;
        const load_tag = try self.instruction(check_id - 5);
        const type_check = try self.instruction(check_id - 4);
        const load_number = try self.instruction(check_id - 3);
        const convert = try self.instruction(check_id - 2);
        const roundtrip = try self.instruction(check_id - 1);
        const check = try self.instruction(check_id);
        const store = try self.instruction(check_id + 1);
        const store_tag = try self.instruction(check_id + 2);
        if (load_tag.command != .load_tag or load_tag.operand_count != 1 or
            type_check.command != .check_tag or type_check.operand_count != 3 or
            load_number.command != .load_double or load_number.operand_count != 1 or
            convert.command != .num_to_int64 or convert.operand_count != 1 or
            roundtrip.command != .int64_to_num or roundtrip.operand_count != 1 or
            check.command != .check_cmp_num or check.operand_count != 4 or
            store.command != .store_int64 or store.operand_count != 2 or
            store_tag.command != .store_tag or store_tag.operand_count != 2)
            return null;

        const source = try self.operand(load_tag, 0);
        const checked = try self.operand(type_check, 0);
        const expected = try self.operand(type_check, 1);
        const type_exit = try self.operand(type_check, 2);
        const loaded = try self.operand(load_number, 0);
        const converted = try self.operand(convert, 0);
        const rounded = try self.operand(roundtrip, 0);
        const lhs = try self.operand(check, 0);
        const rhs = try self.operand(check, 1);
        const condition = try self.operand(check, 2);
        const range_exit = try self.operand(check, 3);
        const destination = try self.operand(store, 0);
        const stored = try self.operand(store, 1);
        const tag_destination = try self.operand(store_tag, 0);
        const tag = try self.operand(store_tag, 1);
        if (source.kind != .vm_reg or !sameOperand(source, loaded) or
            checked.kind != .instruction or checked.value != check_id - 5 or
            expected.kind != .constant or (try self.constant(expected.value)).tagValue() != lua_tag_number or
            type_exit.kind != .vm_exit or range_exit.kind != .vm_exit or type_exit.value != range_exit.value or
            converted.kind != .instruction or converted.value != check_id - 3 or
            rounded.kind != .instruction or rounded.value != check_id - 2 or
            lhs.kind != .instruction or lhs.value != check_id - 1 or
            rhs.kind != .instruction or rhs.value != check_id - 3 or
            condition.kind != .condition or condition.value != @intFromEnum(snapshot_v1.IrCondition.equal) or
            destination.kind != .vm_reg or !sameOperand(destination, tag_destination) or
            stored.kind != .instruction or stored.value != check_id - 2 or
            tag.kind != .constant or (try self.constant(tag.value)).tagValue() != lua_tag_integer)
            return null;
        const fallback = (try self.builtinFallback(type_exit.value)) orelse return null;
        if (fallback.id != lbf_integer_create)
            return null;
        return .{
            .check = check_id,
            .finish = check_id + 2,
            .destination = destination.value,
        };
    }

    fn emitIntegerCreate(self: Context, pattern: IntegerCreatePattern) Error!void {
        const check = try self.instruction(pattern.check);
        try self.emitF64Value(try self.operand(check, 0));
        try self.emitF64Value(try self.operand(check, 1));
        try self.body.f64Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.emitStoreI64(try self.instruction(pattern.check + 1));
        try self.emitStoreTag(pattern.check + 2, try self.instruction(pattern.check + 2));
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Const(self.allocator, lua_tag_nil);
        try self.body.i32Store(
            self.allocator,
            2,
            pattern.destination * tvalue_size + tvalue_tag_offset,
        );
        try self.body.end(self.allocator);
    }

    fn tableAllocationPatternAt(self: Context, start: u32) Error!?TableAllocationPattern {
        if (self.function.instruction_count < 3 or start > self.function.instruction_count - 3)
            return null;
        const allocation = try self.instruction(start);
        const store_pointer = try self.instruction(start + 1);
        const store_tag = try self.instruction(start + 2);
        if (allocation.command != ir_cmd_new_table or allocation.operand_count != 2 or
            store_pointer.command != .store_pointer or store_pointer.operand_count != 2 or
            store_tag.command != .store_tag or store_tag.operand_count != 2)
            return null;
        var finish = start + 2;
        var assist = false;
        if (start + 3 < self.function.instruction_count) {
            const possible_check = try self.instruction(start + 3);
            if (possible_check.command == .check_gc and possible_check.operand_count == 0) {
                finish = start + 3;
                assist = true;
            } else if (possible_check.command == .nop and possible_check.operand_count == 0) {
                // Const-prop turns a redundant CHECK_GC into this exact adjacent marker.
                finish = start + 3;
            }
        }
        self.requireSingleCompilableBlockRange(start, finish) catch return null;
        const destination = try self.operand(store_pointer, 0);
        const pointer = try self.operand(store_pointer, 1);
        const tag_destination = try self.operand(store_tag, 0);
        const tag = try self.operand(store_tag, 1);
        if (destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
            pointer.kind != .instruction or pointer.value != start or
            tag_destination.kind != .vm_reg or tag_destination.value != destination.value or
            tag.kind != .constant or (try self.constant(tag.value)).tagValue() != lua_tag_table)
            return null;
        const node_count = try self.uintConstant(try self.operand(allocation, 1));
        const deferred_to_later_gc = finish == start + 2;
        if (deferred_to_later_gc and !try self.hasLaterCheckGcInBlock(start, finish)) return null;
        return .{
            .start = start,
            .finish = finish,
            .assist = assist,
            .deferred_to_later_gc = deferred_to_later_gc,
            .destination = destination.value,
            .array_count = try self.uintConstant(try self.operand(allocation, 0)),
            .node_count = node_count,
        };
    }

    fn isDeferredTableInitializationCommand(command: snapshot_v1.IrCommand) bool {
        return switch (command) {
            .nop,
            .substitute,
            .mark_used,
            .mark_dead,
            .load_tag,
            .load_pointer,
            .load_int,
            .load_int64,
            .load_float,
            .load_double,
            .load_tvalue,
            .store_tag,
            .store_pointer,
            .store_extra,
            .store_int,
            .store_int64,
            .store_double,
            .store_vector,
            .store_tvalue,
            .store_split_tvalue,
            ir_cmd_new_table,
            => true,
            else => false,
        };
    }

    fn hasLaterCheckGcInBlock(self: Context, start: u32, finish: u32) Error!bool {
        var block_id: u32 = 0;
        while (block_id < self.function.block_count) : (block_id += 1) {
            const block = try self.snapshot.irBlock(self.function, block_id);
            if (!block.kind.isCompilable() or block.isEmpty() or start < block.start or finish > block.finish)
                continue;
            var cursor = finish + 1;
            while (cursor <= block.finish) : (cursor += 1) {
                const candidate = try self.instruction(cursor);
                if (candidate.command == .check_gc and candidate.operand_count == 0)
                    return true;
                if (!isDeferredTableInitializationCommand(candidate.command))
                    return false;
            }
            return false;
        }
        return false;
    }

    fn checkGcClosesDeferredTableAllocation(self: Context, instruction_id: u32) Error!bool {
        var block_id: u32 = 0;
        while (block_id < self.function.block_count) : (block_id += 1) {
            const block = try self.snapshot.irBlock(self.function, block_id);
            if (!block.kind.isCompilable() or block.isEmpty() or instruction_id < block.start or instruction_id > block.finish)
                continue;
            var cursor = block.start;
            var owns_deferred = false;
            while (cursor < instruction_id) : (cursor += 1) {
                const candidate = try self.instruction(cursor);
                if (candidate.command == .check_gc)
                    owns_deferred = false;
                if (try self.tableAllocationPatternAt(cursor)) |pattern| {
                    if (pattern.deferred_to_later_gc)
                        owns_deferred = true;
                    cursor = pattern.finish;
                }
            }
            return owns_deferred;
        }
        return false;
    }

    fn userdataWriteWidth(command: snapshot_v1.IrCommand) ?u32 {
        return if (command == ir_cmd_buffer_writei8)
            1
        else if (command == ir_cmd_buffer_writei16)
            2
        else if (command == ir_cmd_buffer_writei32 or command == ir_cmd_buffer_writef32)
            4
        else if (command == ir_cmd_buffer_writef64 or command == ir_cmd_buffer_writei64)
            8
        else
            null;
    }

    fn userdataAllocationPatternAt(self: Context, start: u32) Error!?UserdataAllocationPattern {
        if (start + 3 >= self.function.instruction_count)
            return null;
        const check_gc = try self.instruction(start);
        const allocation = try self.instruction(start + 1);
        if (check_gc.command != .check_gc or check_gc.operand_count != 0 or
            allocation.command != ir_cmd_new_userdata or allocation.operand_count != 2)
            return null;

        const byte_size = self.uintConstant(try self.operand(allocation, 0)) catch return null;
        const user_tag = self.uintConstant(try self.operand(allocation, 1)) catch return null;
        if (user_tag >= lua_utag_limit)
            return null;
        var cursor = start + 2;
        while (cursor < self.function.instruction_count) : (cursor += 1) {
            const candidate = try self.instruction(cursor);
            if (userdataWriteWidth(candidate.command)) |width| {
                if (candidate.operand_count != 4)
                    return null;
                const pointer = try self.operand(candidate, 0);
                const offset = self.uintConstant(try self.operand(candidate, 1)) catch return null;
                const tag = try self.operand(candidate, 3);
                if (pointer.kind != .instruction or pointer.value != start + 1 or
                    tag.kind != .constant or (try self.constant(tag.value)).tagValue() != lua_tag_userdata or
                    offset > byte_size or width > byte_size - offset)
                    return null;
                continue;
            }
            if (candidate.command != .store_pointer or candidate.operand_count != 2 or
                cursor + 1 >= self.function.instruction_count)
                return null;
            const store_tag = try self.instruction(cursor + 1);
            if (store_tag.command != .store_tag or store_tag.operand_count != 2)
                return null;
            const destination = try self.operand(candidate, 0);
            const pointer = try self.operand(candidate, 1);
            const tag_destination = try self.operand(store_tag, 0);
            const tag = try self.operand(store_tag, 1);
            if (destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
                pointer.kind != .instruction or pointer.value != start + 1 or
                tag_destination.kind != .vm_reg or tag_destination.value != destination.value or
                tag.kind != .constant or (try self.constant(tag.value)).tagValue() != lua_tag_userdata)
                return null;
            self.requireSingleCompilableBlockRange(start, cursor + 1) catch return null;
            return .{
                .start = start,
                .allocation = start + 1,
                .finish = cursor + 1,
                .destination = destination.value,
                .byte_size = byte_size,
                .user_tag = user_tag,
            };
        }
        return null;
    }

    fn userdataAllocationPatternContaining(self: Context, instruction_id: u32) Error!?UserdataAllocationPattern {
        var cursor = instruction_id + 1;
        while (cursor != 0) {
            cursor -= 1;
            const candidate = try self.instruction(cursor);
            if (candidate.command != .check_gc)
                continue;
            if (try self.userdataAllocationPatternAt(cursor)) |pattern|
                if (instruction_id <= pattern.finish) return pattern;
        }
        return null;
    }

    fn materializedConstantTag(kind: snapshot_v1.VmConstantKind) ?u8 {
        return switch (kind) {
            .nil => @intCast(lua_tag_nil),
            .boolean => @intCast(lua_tag_boolean),
            .number => lua_tag_number,
            .vector => @intCast(lua_tag_vector),
            .string => lua_tag_string,
            .integer => lua_tag_integer,
            .table => lua_tag_table,
            .import, .closure, .class_shape => null,
        };
    }

    fn constantLoadPatternAt(self: Context, start: u32) Error!?ConstantLoadPattern {
        if (start + 1 >= self.function.instruction_count)
            return null;
        const load = try self.instruction(start);
        const store = try self.instruction(start + 1);
        if (load.command != .load_tvalue or load.operand_count != 3 or
            store.command != .store_tvalue or store.operand_count != 2)
            return null;
        self.requireSingleCallBlockRange(start, start + 1) catch return null;

        const constant_operand = try self.operand(load, 0);
        const offset = try self.operand(load, 1);
        const tag = try self.operand(load, 2);
        const destination = try self.operand(store, 0);
        const stored = try self.operand(store, 1);
        if (constant_operand.kind != .vm_const or constant_operand.value >= self.proto.vm_constant_count or
            !try self.intOperandEquals(offset, 0) or tag.kind != .constant or
            destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
            stored.kind != .instruction or stored.value != start)
            return null;
        const expected_tag = materializedConstantTag((try self.snapshot.vmConstant(self.proto, constant_operand.value)).kind) orelse
            return null;
        if ((try self.constant(tag.value)).tagValue() != expected_tag)
            return null;
        return .{
            .start = start,
            .finish = start + 1,
            .destination = destination.value,
            .constant_id = constant_operand.value,
        };
    }

    fn constantLoadPatternContaining(self: Context, instruction_id: u32) Error!?ConstantLoadPattern {
        if (try self.constantLoadPatternAt(instruction_id)) |pattern|
            return pattern;
        if (instruction_id != 0)
            if (try self.constantLoadPatternAt(instruction_id - 1)) |pattern|
                if (pattern.finish == instruction_id) return pattern;
        return null;
    }

    fn emitConstantLoad(self: Context, pattern: ConstantLoadPattern) Error!void {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.destination));
        try self.body.i32Const(self.allocator, @intCast(pattern.constant_id));
        try self.body.call(self.allocator, self.load_constant orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
    }

    fn constantTruthyFallbackPatternAt(self: Context, start: u32) Error!?ConstantTruthyFallbackPattern {
        const commands = [_]snapshot_v1.IrCommand{ .load_tvalue, .select_if_truthy, .store_tvalue };
        if (!try self.commandRangeMatches(start, &commands))
            return null;
        const finish = start + @as(u32, @intCast(commands.len - 1));
        self.requireSingleCompilableBlockRange(start, finish) catch return null;

        const load = try self.instruction(start);
        const select = try self.instruction(start + 1);
        const store = try self.instruction(finish);
        if (load.operand_count != 1 or select.operand_count != 3 or store.operand_count != 2 or
            load.use_count != 1)
            return null;
        const constant_operand = try self.operand(load, 0);
        const condition = try self.operand(select, 0);
        const true_value = try self.operand(select, 1);
        const false_value = try self.operand(select, 2);
        const destination = try self.operand(store, 0);
        const stored = try self.operand(store, 1);
        if (constant_operand.kind != .vm_const or constant_operand.value >= self.proto.vm_constant_count or
            materializedConstantTag((try self.snapshot.vmConstant(self.proto, constant_operand.value)).kind) == null or
            (true_value.kind != .vm_reg and true_value.kind != .instruction) or
            condition.kind != true_value.kind or condition.value != true_value.value or
            false_value.kind != .instruction or false_value.value != start or
            destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
            stored.kind != .instruction or stored.value != start + 1)
            return null;
        return .{
            .start = start,
            .finish = finish,
            .destination = destination.value,
            .constant_id = constant_operand.value,
            .true_value = true_value,
        };
    }

    fn constantTruthyFallbackPatternContaining(self: Context, instruction_id: u32) Error!?ConstantTruthyFallbackPattern {
        var distance: u32 = 0;
        while (distance < 3 and distance <= instruction_id) : (distance += 1) {
            if (try self.constantTruthyFallbackPatternAt(instruction_id - distance)) |pattern|
                if (instruction_id <= pattern.finish) return pattern;
        }
        return null;
    }

    fn emitConstantTruthyFallback(self: Context, pattern: ConstantTruthyFallbackPattern) Error!void {
        try self.emitTValueTruthy(pattern.true_value);
        try self.body.ifVoid(self.allocator);
        try self.emitStoreTValueOperand(pattern.destination, pattern.true_value);
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.destination));
        try self.body.i32Const(self.allocator, @intCast(pattern.constant_id));
        try self.body.call(self.allocator, self.load_constant orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
        try self.body.end(self.allocator);

        const result_id = pattern.start + 1;
        if (result_id >= self.slots.len or self.slots[result_id].shape != .tvalue)
            return Error.InvalidInstructionResult;
        const published = snapshot_v1.IrOperand{ .kind = .vm_reg, .value = pattern.destination };
        try self.emitTValuePart(published, false);
        try self.body.localSet(self.allocator, self.slots[result_id].first);
        try self.emitTValuePart(published, true);
        try self.body.localSet(self.allocator, self.slots[result_id].second);
    }

    fn dupTablePatternAt(self: Context, start: u32) Error!?DupTablePattern {
        const prefix = [_]snapshot_v1.IrCommand{
            .load_pointer, ir_cmd_dup_table, .store_pointer, .store_tag,
        };
        const prefix_len: u32 = @intCast(prefix.len);
        if (!try self.commandRangeMatches(start, &prefix) or start + prefix_len >= self.function.instruction_count)
            return null;
        const finish = start + prefix_len;
        self.requireSingleCompilableBlockRange(start, finish) catch return null;

        const load = try self.instruction(start);
        const duplicate = try self.instruction(start + 1);
        const store_pointer = try self.instruction(start + 2);
        const store_tag = try self.instruction(start + 3);
        const check_gc = try self.instruction(finish);
        // The pinned DSE pass can replace CHECK_GC with NOP in the linearized duplicate. The
        // combined helper still publishes the clone before performing the collector assist, so
        // accepting that exact optimized suffix is conservative rather than a weaker GC path.
        if ((check_gc.command != .check_gc and check_gc.command != .nop) or
            load.operand_count != 1 or duplicate.operand_count != 1 or
            store_pointer.operand_count != 2 or store_tag.operand_count != 2 or check_gc.operand_count != 0)
            return null;

        const constant_operand = try self.operand(load, 0);
        if (constant_operand.kind != .vm_const or constant_operand.value >= self.proto.vm_constant_count or
            (try self.snapshot.vmConstant(self.proto, constant_operand.value)).kind != .table)
            return null;
        const duplicate_source = try self.operand(duplicate, 0);
        const destination = try self.operand(store_pointer, 0);
        const stored_pointer = try self.operand(store_pointer, 1);
        const tag_destination = try self.operand(store_tag, 0);
        const tag = try self.operand(store_tag, 1);
        if (duplicate_source.kind != .instruction or duplicate_source.value != start or
            stored_pointer.kind != .instruction or stored_pointer.value != start + 1 or
            tag_destination.kind != .vm_reg or tag_destination.value != destination.value or
            tag.kind != .constant or (try self.constant(tag.value)).tagValue() != lua_tag_table)
            return null;
        return .{
            .start = start,
            .finish = finish,
            .destination = try self.vmRegisterIndex(destination),
            .constant_id = constant_operand.value,
        };
    }

    fn dupTablePatternContaining(self: Context, instruction_id: u32) Error!?DupTablePattern {
        var distance: u32 = 0;
        while (distance < 5 and distance <= instruction_id) : (distance += 1) {
            if (try self.dupTablePatternAt(instruction_id - distance)) |pattern|
                if (instruction_id <= pattern.finish) return pattern;
        }
        return null;
    }

    fn emitDupTable(self: Context, pattern: DupTablePattern) Error!void {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.destination));
        try self.body.i32Const(self.allocator, @intCast(pattern.constant_id));
        try self.body.call(self.allocator, self.dup_table orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
    }

    fn tableRegisterForPointer(self: Context, pointer_id: u32) Error!?u32 {
        const pointer = try self.instruction(pointer_id);
        if (pointer.command == .load_pointer and pointer.operand_count == 1) {
            const source = try self.operand(pointer, 0);
            if (source.kind != .vm_reg)
                return null;
            return try self.vmRegisterIndex(source);
        }
        if (pointer.command == ir_cmd_dup_table and pointer_id != 0) {
            const clone = (try self.dupTablePatternAt(pointer_id - 1)) orelse return null;
            if (clone.start + 1 != pointer_id)
                return null;
            return clone.destination;
        }
        return null;
    }

    fn dupTableRegisterForPointer(self: Context, pointer_id: u32) Error!?u32 {
        const pointer = try self.instruction(pointer_id);
        if (pointer.command == ir_cmd_dup_table and pointer_id != 0) {
            const clone = (try self.dupTablePatternAt(pointer_id - 1)) orelse return null;
            return clone.destination;
        }
        if (pointer.command != .load_pointer or pointer.operand_count != 1)
            return null;
        const source = try self.operand(pointer, 0);
        if (source.kind != .vm_reg or source.value >= self.proto.max_stack_size)
            return null;

        var cursor = pointer_id;
        while (cursor != 0) {
            cursor -= 1;
            const candidate = try self.instruction(cursor);
            if (candidate.command != .store_pointer or candidate.operand_count != 2)
                continue;
            const destination = try self.operand(candidate, 0);
            if (destination.kind != .vm_reg or destination.value != source.value)
                continue;
            if (cursor != 0)
                if (try self.tableAllocationPatternAt(cursor - 1)) |pattern|
                    if (pattern.start + 1 == cursor and pattern.destination == source.value)
                        return pattern.destination;
            if (cursor < 2)
                return null;
            const clone = (try self.dupTablePatternAt(cursor - 2)) orelse return null;
            if (clone.start + 2 != cursor or clone.destination != source.value)
                return null;
            return clone.destination;
        }
        return null;
    }

    fn literalFieldSetPatternAt(self: Context, start: u32) Error!?LiteralFieldSetPattern {
        if (start + 4 >= self.function.instruction_count)
            return null;
        const slot = try self.instruction(start);
        const match = try self.instruction(start + 1);
        const readonly = try self.instruction(start + 2);
        if (slot.command != ir_cmd_get_slot_node_addr or slot.operand_count != 3 or
            match.command != ir_cmd_check_slot_match or match.operand_count != 3 or
            ((readonly.command != ir_cmd_check_readonly or readonly.operand_count != 2) and
                (readonly.command != .nop or readonly.operand_count != 0)))
            return null;

        const pointer = try self.operand(slot, 0);
        const pc = try self.operand(slot, 1);
        const key_operand = try self.operand(slot, 2);
        const matched_slot = try self.operand(match, 0);
        const matched_key = try self.operand(match, 1);
        const fallback = try self.operand(match, 2);
        if (pointer.kind != .instruction or pointer.value >= start or pc.kind != .constant or
            key_operand.kind != .vm_const or matched_slot.kind != .instruction or matched_slot.value != start or
            matched_key.kind != .vm_const or matched_key.value != key_operand.value or fallback.kind != .block)
            return null;
        const readonly_elided = readonly.command == .nop;
        if (!readonly_elided) {
            const readonly_pointer = try self.operand(readonly, 0);
            const readonly_fallback = try self.operand(readonly, 1);
            if (readonly_pointer.kind != .instruction or readonly_pointer.value != pointer.value or
                readonly_fallback.kind != .block or readonly_fallback.value != fallback.value)
                return null;
        }
        const table = (try self.tableRegisterForPointer(pointer.value)) orelse return null;
        const key = (try self.stringKey(key_operand)) orelse return null;
        const pc_value = (try self.constant(pc.value)).uintValue() orelse return null;

        var store_id = start + 3;
        if ((try self.instruction(store_id)).command == .nop) {
            if ((try self.instruction(store_id)).operand_count != 0)
                return null;
            store_id += 1;
        }
        if (store_id >= self.function.instruction_count)
            return null;
        const store = try self.instruction(store_id);
        if (store.command == .store_tvalue) {
            if (store_id + 1 >= self.function.instruction_count or store.operand_count != 3)
                return null;
            const barrier = try self.instruction(store_id + 1);
            if (barrier.command != ir_cmd_barrier_table_forward or barrier.operand_count != 3)
                return null;
            const destination = try self.operand(store, 0);
            const stored = try self.operand(store, 1);
            const offset = try self.operand(store, 2);
            const barrier_pointer = try self.operand(barrier, 0);
            const value = try self.operand(barrier, 1);
            const barrier_tag = try self.operand(barrier, 2);
            if (destination.kind != .instruction or destination.value != start or
                stored.kind != .instruction or !try self.intOperandEquals(offset, 0) or
                barrier_pointer.kind != .instruction or barrier_pointer.value != pointer.value or
                value.kind != .vm_reg or value.value >= self.proto.max_stack_size or
                barrier_tag.kind != .constant or (try self.constant(barrier_tag.value)).tagValue() != lua_tag_string or
                stored.value + 1 >= start)
                return null;
            const publication = try self.instruction(stored.value + 1);
            if (publication.command != .store_tvalue or publication.operand_count != 2 or
                (try self.operand(publication, 0)).kind != .vm_reg or
                (try self.operand(publication, 0)).value != value.value or
                (try self.operand(publication, 1)).kind != .instruction or
                (try self.operand(publication, 1)).value != stored.value or
                try self.constantLoadPatternAt(stored.value) == null)
                return null;
            self.requireSingleCompilableBlockRange(start, store_id + 1) catch return null;
            if ((try self.stringFallbackRejoin(fallback.value, .set, pc_value, value.value, table, key_operand.value)) == null)
                return null;
            return .{ .start = start, .finish = store_id + 1, .pc = pc_value, .table = table, .value = value.value, .key = key };
        }
        if (store.command != .store_split_tvalue or store.operand_count != 4 or
            store_id + 1 >= self.function.instruction_count or start < 2)
            return null;
        const suffix = try self.instruction(store_id + 1);
        const destination = try self.operand(store, 0);
        const tag = try self.operand(store, 1);
        const value = try self.operand(store, 2);
        const offset = try self.operand(store, 3);
        if (destination.kind != .instruction or destination.value != start or
            tag.kind != .constant or !try self.intOperandEquals(offset, 0))
            return null;
        const tag_value = (try self.constant(tag.value)).tagValue() orelse return null;
        if (tag_value == lua_tag_table) {
            if (readonly_elided or suffix.command != ir_cmd_barrier_table_forward or suffix.operand_count != 3 or
                value.kind != .instruction)
                return null;
            const value_register = (try self.rootedTablePointerRegister(value)) orelse return null;
            if ((try self.operand(suffix, 0)).kind != .instruction or
                (try self.operand(suffix, 0)).value != pointer.value or
                (try self.operand(suffix, 1)).kind != .vm_reg or
                (try self.operand(suffix, 1)).value != value_register or
                (try self.operand(suffix, 2)).kind != .constant or
                (try self.constant((try self.operand(suffix, 2)).value)).tagValue() != tag_value)
                return null;
            self.requireSingleCompilableBlockRange(start, store_id + 1) catch return null;
            if ((try self.stringFallbackRejoin(fallback.value, .set, pc_value, value_register, table, key_operand.value)) == null)
                return null;
            return .{ .start = start, .finish = store_id + 1, .pc = pc_value, .table = table, .value = value_register, .key = key };
        }
        if (tag_value == lua_tag_number and value.kind == .instruction) {
            if (readonly_elided or suffix.command != .nop or suffix.operand_count != 0)
                return null;
            const owner = (try self.compilableOwnerBlock(start)) orelse return null;
            const source = (try self.publishedNumberPayloadRegister(owner, value, store_id)) orelse return null;
            if ((try self.stringFallbackRejoin(fallback.value, .set, pc_value, source, table, key_operand.value)) == null)
                return null;
            return .{
                .start = start,
                .finish = store_id + 1,
                .pc = pc_value,
                .table = table,
                .value = source,
                .materialized_tag = lua_tag_number,
                .key = key,
            };
        }
        if (suffix.command != .nop or suffix.operand_count != 0 or value.kind != .constant)
            return null;
        if (tag_value != lua_tag_number and tag_value != lua_tag_boolean)
            return null;
        if (readonly_elided and tag_value != lua_tag_boolean)
            return null;

        const value_command: snapshot_v1.IrCommand = if (tag_value == lua_tag_number) .store_double else .store_int;
        var value_store_id: ?u32 = null;
        if (start >= 5 and (try self.instruction(start - 5)).command == value_command and
            (try self.instruction(start - 4)).command == .store_tag)
            value_store_id = start - 5;
        if (value_store_id == null and (try self.instruction(start - 2)).command == value_command and
            (try self.instruction(start - 1)).command == .store_tag)
            value_store_id = start - 2;
        const publication_id = value_store_id orelse return null;
        const value_store = try self.instruction(publication_id);
        const tag_store = try self.instruction(publication_id + 1);
        if (value_store.operand_count != 2 or tag_store.operand_count != 2)
            return null;
        if (publication_id + 5 == start) {
            const guard0 = try self.instruction(publication_id + 2);
            const guard1 = try self.instruction(publication_id + 3);
            const guard2 = try self.instruction(publication_id + 4);
            const optimized = guard0.command == .nop and guard0.operand_count == 0 and
                guard1.command == .nop and guard1.operand_count == 0 and
                guard2.command == .nop and guard2.operand_count == 0;
            if (!optimized) {
                if (guard0.command != .load_tag or guard0.operand_count != 1 or
                    guard1.command != .check_tag or guard1.operand_count != 3 or
                    guard2.command != .load_pointer or guard2.operand_count != 1)
                    return null;
                const guarded_table = try self.operand(guard0, 0);
                const checked_tag = try self.operand(guard1, 0);
                const required_tag = try self.operand(guard1, 1);
                const exit = try self.operand(guard1, 2);
                const loaded_table = try self.operand(guard2, 0);
                if (guarded_table.kind != .vm_reg or guarded_table.value != table or
                    checked_tag.kind != .instruction or checked_tag.value != publication_id + 2 or
                    required_tag.kind != .constant or (try self.constant(required_tag.value)).tagValue() != lua_tag_table or
                    exit.kind != .vm_exit or loaded_table.kind != .vm_reg or loaded_table.value != table or
                    pointer.value != publication_id + 4)
                    return null;
            }
        }
        const value_destination = try self.operand(value_store, 0);
        const tag_destination = try self.operand(tag_store, 0);
        const stored_value = try self.operand(value_store, 1);
        const stored_tag = try self.operand(tag_store, 1);
        if (value_destination.kind != .vm_reg or value_destination.value >= self.proto.max_stack_size or
            tag_destination.kind != .vm_reg or tag_destination.value != value_destination.value or
            stored_value.kind != .constant or stored_value.value != value.value or
            stored_tag.kind != .constant or stored_tag.value != tag.value)
            return null;
        self.requireSingleCompilableBlockRange(publication_id, store_id + 1) catch return null;
        if ((try self.stringFallbackRejoin(fallback.value, .set, pc_value, value_destination.value, table, key_operand.value)) == null)
            return null;
        return .{ .start = start, .finish = store_id + 1, .pc = pc_value, .table = table, .value = value_destination.value, .key = key };
    }

    fn literalFieldSetPatternContaining(self: Context, instruction_id: u32) Error!?LiteralFieldSetPattern {
        var distance: u32 = 0;
        while (distance < 7 and distance <= instruction_id) : (distance += 1) {
            const start = instruction_id - distance;
            if ((try self.instruction(start)).command == ir_cmd_get_slot_node_addr)
                if (try self.literalFieldSetPatternAt(start)) |pattern|
                    if (instruction_id <= pattern.finish) return pattern;
        }
        return null;
    }

    fn emitLiteralFieldSet(self: Context, pattern: LiteralFieldSetPattern) Error!void {
        const key = try self.string_keys.intern(self.allocator, pattern.key);
        try self.emitPcLocation(pattern.pc);
        if (pattern.materialized_tag) |tag| {
            try self.body.localGet(self.allocator, self.base_local);
            try self.body.i32Const(self.allocator, tag);
            try self.body.i32Store(self.allocator, 2, pattern.value * tvalue_size + tvalue_tag_offset);
        }
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.table));
        try self.body.i32Const(self.allocator, @intCast(pattern.value));
        try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(key.offset));
        try self.body.i32Const(self.allocator, @intCast(key.length));
        try self.body.call(self.allocator, self.table_set_string orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
    }

    fn tableInsertAppendPatternAt(self: Context, cluster_start: u32) Error!?TableInsertAppendPattern {
        const dynamic_commands = [_]snapshot_v1.IrCommand{
            ir_cmd_table_len, .add_int, ir_cmd_table_setnum, .load_tvalue, .store_tvalue, ir_cmd_barrier_table_forward,
        };
        const number_commands = [_]snapshot_v1.IrCommand{
            ir_cmd_table_len, .add_int, ir_cmd_table_setnum, .store_double, .store_tag,
        };
        const dynamic = try self.commandRangeMatches(cluster_start, &dynamic_commands);
        const number = !dynamic and try self.commandRangeMatches(cluster_start, &number_commands);
        if (!dynamic and !number)
            return null;
        const command_count = if (dynamic) dynamic_commands.len else number_commands.len;
        const finish = cluster_start + @as(u32, @intCast(command_count - 1));
        var start = cluster_start;
        if (cluster_start != 0 and (try self.instruction(cluster_start - 1)).command == ir_cmd_check_readonly)
            start = cluster_start - 1;
        self.requireSingleCompilableBlockRange(start, finish) catch return null;

        const length = try self.instruction(cluster_start);
        const increment = try self.instruction(cluster_start + 1);
        const destination = try self.instruction(cluster_start + 2);
        if (length.operand_count != 1 or increment.operand_count != 2 or destination.operand_count != 2)
            return null;

        const length_pointer = try self.operand(length, 0);
        if (length_pointer.kind != .instruction or length_pointer.value >= cluster_start)
            return null;
        const table_register = (try self.tableRegisterForPointer(length_pointer.value)) orelse return null;
        const increment_lhs = try self.operand(increment, 0);
        const setnum_pointer = try self.operand(destination, 0);
        const setnum_key = try self.operand(destination, 1);
        if (increment_lhs.kind != .instruction or increment_lhs.value != cluster_start or
            !try self.intOperandEquals(try self.operand(increment, 1), 1) or
            setnum_pointer.kind != .instruction or setnum_pointer.value != length_pointer.value or
            setnum_key.kind != .instruction or setnum_key.value != cluster_start + 1)
            return null;
        var source: u32 = undefined;
        var constant_number: ?f64 = null;
        if (dynamic) {
            const load = try self.instruction(cluster_start + 3);
            const store = try self.instruction(cluster_start + 4);
            const barrier = try self.instruction(finish);
            if (load.operand_count != 1 or store.operand_count != 2 or barrier.operand_count != 3)
                return null;
            const source_operand = try self.operand(load, 0);
            const store_destination = try self.operand(store, 0);
            const store_source = try self.operand(store, 1);
            const barrier_pointer = try self.operand(barrier, 0);
            const barrier_source = try self.operand(barrier, 1);
            const barrier_tag = try self.operand(barrier, 2);
            if (source_operand.kind != .vm_reg or
                store_destination.kind != .instruction or store_destination.value != cluster_start + 2 or
                store_source.kind != .instruction or store_source.value != cluster_start + 3 or
                barrier_pointer.kind != .instruction or barrier_pointer.value != length_pointer.value or
                barrier_source.kind != .vm_reg or barrier_source.value != source_operand.value or barrier_tag.kind != .undef)
                return null;
            source = try self.vmRegisterIndex(source_operand);
        } else {
            const store = try self.instruction(cluster_start + 3);
            const store_tag = try self.instruction(cluster_start + 4);
            if (store.operand_count != 2 or store_tag.operand_count != 2)
                return null;
            const store_destination = try self.operand(store, 0);
            const stored = try self.operand(store, 1);
            const tag_destination = try self.operand(store_tag, 0);
            const tag = try self.operand(store_tag, 1);
            if (store_destination.kind != .instruction or store_destination.value != cluster_start + 2 or
                !sameOperand(store_destination, tag_destination) or stored.kind != .constant or tag.kind != .constant or
                (try self.constant(tag.value)).tagValue() != lua_tag_number)
                return null;
            constant_number = (try self.constant(stored.value)).doubleValue() orelse return null;
        }
        if (start != cluster_start) {
            const readonly = try self.instruction(start);
            if (readonly.operand_count != 2 or
                (try self.operand(readonly, 0)).kind != .instruction or
                (try self.operand(readonly, 0)).value != length_pointer.value or
                (try self.operand(readonly, 1)).kind != .vm_exit)
                return null;
            if (number) {
                const exit = try self.operand(readonly, 1);
                if (exit.value < 2)
                    return null;
                const fast_pc = exit.value - 2;
                const fast_word = try self.snapshot.bytecodeWord(self.proto, fast_pc);
                if (@as(u8, @truncate(fast_word)) != lop_fastcall2k or
                    ((fast_word >> 8) & 0xff) != 52 or ((fast_word >> 16) & 0xff) != table_register)
                    return null;
                const call_pc = std.math.add(u32, fast_pc, ((fast_word >> 24) & 0xff) + 1) catch return null;
                if (call_pc >= self.proto.code_count)
                    return null;
                const call_word = try self.snapshot.bytecodeWord(self.proto, call_pc);
                if (@as(u8, @truncate(call_word)) != lop_call or ((call_word >> 16) & 0xff) != 3)
                    return null;
                source = ((call_word >> 8) & 0xff) + 2;
                if (source >= self.proto.max_stack_size)
                    return null;
            }
        } else if (number) {
            return null;
        }
        return .{
            .start = start,
            .finish = finish,
            .table = table_register,
            .source = source,
            .constant_number = constant_number,
        };
    }

    fn tableInsertAppendPatternContaining(self: Context, instruction_id: u32) Error!?TableInsertAppendPattern {
        if ((try self.instruction(instruction_id)).command == ir_cmd_check_readonly and
            instruction_id + 1 < self.function.instruction_count)
            if (try self.tableInsertAppendPatternAt(instruction_id + 1)) |pattern|
                if (pattern.start == instruction_id) return pattern;
        var distance: u32 = 0;
        while (distance < 7 and distance <= instruction_id) : (distance += 1) {
            const candidate = instruction_id - distance;
            if ((try self.instruction(candidate)).command == ir_cmd_table_len)
                if (try self.tableInsertAppendPatternAt(candidate)) |pattern|
                    if (instruction_id <= pattern.finish) return pattern;
        }
        return null;
    }

    fn emitTableInsertAppend(self: Context, pattern: TableInsertAppendPattern) Error!void {
        if (pattern.constant_number) |value| {
            try self.body.localGet(self.allocator, self.base_local);
            try self.body.f64Const(self.allocator, value);
            try self.body.f64Store(self.allocator, 3, pattern.source * tvalue_size);
            try self.body.localGet(self.allocator, self.base_local);
            try self.body.i32Const(self.allocator, lua_tag_number);
            try self.body.i32Store(self.allocator, 2, pattern.source * tvalue_size + tvalue_tag_offset);
        }
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.table));
        try self.body.i32Const(self.allocator, @intCast(pattern.source));
        try self.body.call(self.allocator, self.table_insert_append orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
    }

    fn blockReferenceCount(self: Context, target: u32) Error!u32 {
        var count: u32 = 0;
        var instruction_id: u32 = 0;
        while (instruction_id < self.function.instruction_count) : (instruction_id += 1) {
            const instruction_value = try self.instruction(instruction_id);
            var operand_id: u32 = 0;
            while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                const operand_value = try self.operand(instruction_value, operand_id);
                if (operand_value.kind == .block and operand_value.value == target)
                    count = std.math.add(u32, count, 1) catch return Error.ResourceLimit;
            }
        }
        return count;
    }

    fn plainTableNamecallPattern(self: Context, block: snapshot_v1.IrBlock) Error!?PlainTableNamecallPattern {
        const head_commands = [_]snapshot_v1.IrCommand{
            .load_tag, .check_tag, .load_pointer, ir_cmd_get_hash_node_addr, ir_cmd_jump_slot_match,
        };
        if (!block.kind.isCompilable() or block.isEmpty() or block.finish < block.start + head_commands.len - 1)
            return null;
        const start = block.finish - @as(u32, @intCast(head_commands.len - 1));
        if (!try self.commandRangeMatches(start, &head_commands))
            return null;

        const load_tag = try self.instruction(start);
        const check_tag = try self.instruction(start + 1);
        const load_pointer = try self.instruction(start + 2);
        const hash_node = try self.instruction(start + 3);
        const slot_branch = try self.instruction(start + 4);
        if (load_tag.operand_count != 1 or check_tag.operand_count != 3 or load_pointer.operand_count != 1 or
            hash_node.operand_count != 2 or slot_branch.operand_count != 4)
            return null;
        const source = try self.operand(load_tag, 0);
        const checked = try self.operand(check_tag, 0);
        const required_tag = try self.operand(check_tag, 1);
        const exit = try self.operand(check_tag, 2);
        const loaded_source = try self.operand(load_pointer, 0);
        const hash_table = try self.operand(hash_node, 0);
        const hash_value = try self.operand(hash_node, 1);
        const branched_node = try self.operand(slot_branch, 0);
        const key_operand = try self.operand(slot_branch, 1);
        const first_fast = try self.operand(slot_branch, 2);
        const second_fast = try self.operand(slot_branch, 3);
        if (source.kind != .vm_reg or source.value >= self.proto.max_stack_size or
            checked.kind != .instruction or checked.value != start or required_tag.kind != .constant or
            (try self.constant(required_tag.value)).tagValue() != lua_tag_table or
            (exit.kind != .vm_exit and exit.kind != .block) or
            loaded_source.kind != .vm_reg or loaded_source.value != source.value or
            hash_table.kind != .instruction or hash_table.value != start + 2 or hash_value.kind != .constant or
            branched_node.kind != .instruction or branched_node.value != start + 3 or key_operand.kind != .vm_const or
            first_fast.kind != .block or second_fast.kind != .block or first_fast.value == second_fast.value)
            return null;
        const key = (try self.stringKey(key_operand)) orelse return null;
        const expected_hash = upstreamStringHash(key) orelse return null;
        if ((try self.constant(hash_value.value)).uintValue() != expected_hash)
            return null;

        const first_block = try self.snapshot.irBlock(self.function, first_fast.value);
        const first_commands = [_]snapshot_v1.IrCommand{ .store_pointer, .store_tag, .load_tvalue, .store_tvalue, .jump };
        if (first_block.kind != .internal or first_block.isEmpty() or
            first_block.finish != first_block.start + first_commands.len - 1 or
            !try self.commandRangeMatches(first_block.start, &first_commands))
            return null;
        const first_store_pointer = try self.instruction(first_block.start);
        const first_store_tag = try self.instruction(first_block.start + 1);
        const first_load = try self.instruction(first_block.start + 2);
        const first_store = try self.instruction(first_block.start + 3);
        const first_jump = try self.instruction(first_block.start + 4);
        if (first_store_pointer.operand_count != 2 or first_store_tag.operand_count != 2 or
            first_load.operand_count != 2 or first_store.operand_count != 2 or first_jump.operand_count != 1)
            return null;
        const receiver_destination = try self.operand(first_store_pointer, 0);
        const destination = try self.operand(first_store, 0);
        const first_rejoin = try self.operand(first_jump, 0);
        if (receiver_destination.kind != .vm_reg or destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
            destination.value == std.math.maxInt(u32) or receiver_destination.value != destination.value + 1 or
            receiver_destination.value >= self.proto.max_stack_size or
            (try self.operand(first_store_pointer, 1)).kind != .instruction or
            (try self.operand(first_store_pointer, 1)).value != start + 2 or
            (try self.operand(first_store_tag, 0)).kind != .vm_reg or
            (try self.operand(first_store_tag, 0)).value != receiver_destination.value or
            (try self.operand(first_store_tag, 1)).kind != .constant or
            (try self.constant((try self.operand(first_store_tag, 1)).value)).tagValue() != lua_tag_table or
            (try self.operand(first_load, 0)).kind != .instruction or
            (try self.operand(first_load, 0)).value != start + 3 or !try self.intOperandEquals(try self.operand(first_load, 1), 0) or
            (try self.operand(first_store, 1)).kind != .instruction or
            (try self.operand(first_store, 1)).value != first_block.start + 2 or first_rejoin.kind != .block)
            return null;

        const second_block = try self.snapshot.irBlock(self.function, second_fast.value);
        const second_commands = [_]snapshot_v1.IrCommand{
            ir_cmd_check_node_no_next, ir_cmd_try_call_fastgettm, .load_tag,     .check_tag,     .load_pointer,
            ir_cmd_get_slot_node_addr, ir_cmd_check_slot_match,   .load_pointer, .store_pointer, .store_tag,
            .load_tvalue,              .store_tvalue,             .jump,
        };
        if (second_block.kind != .internal or second_block.isEmpty() or
            second_block.finish != second_block.start + second_commands.len - 1 or
            !try self.commandRangeMatches(second_block.start, &second_commands))
            return null;
        const second_id = second_block.start;
        const no_next = try self.instruction(second_id);
        const fastgettm = try self.instruction(second_id + 1);
        const index_tag = try self.instruction(second_id + 2);
        const index_check = try self.instruction(second_id + 3);
        const index_pointer = try self.instruction(second_id + 4);
        const index_slot = try self.instruction(second_id + 5);
        const index_match = try self.instruction(second_id + 6);
        const reloaded_table = try self.instruction(second_id + 7);
        const second_store_pointer = try self.instruction(second_id + 8);
        const second_store_tag = try self.instruction(second_id + 9);
        const second_load = try self.instruction(second_id + 10);
        const second_store = try self.instruction(second_id + 11);
        const second_jump = try self.instruction(second_id + 12);
        if (no_next.operand_count != 2 or fastgettm.operand_count != 3 or index_tag.operand_count != 1 or
            index_check.operand_count != 3 or index_pointer.operand_count != 1 or index_slot.operand_count != 3 or
            index_match.operand_count != 3 or reloaded_table.operand_count != 1 or second_store_pointer.operand_count != 2 or
            second_store_tag.operand_count != 2 or second_load.operand_count != 2 or second_store.operand_count != 2 or
            second_jump.operand_count != 1)
            return null;
        const fallback = try self.operand(no_next, 1);
        if ((try self.operand(no_next, 0)).kind != .instruction or (try self.operand(no_next, 0)).value != start + 3 or
            fallback.kind != .block or (try self.operand(fastgettm, 0)).kind != .instruction or
            (try self.operand(fastgettm, 0)).value != start + 2 or !try self.intOperandEquals(try self.operand(fastgettm, 1), 0) or
            (try self.operand(fastgettm, 2)).kind != .block or (try self.operand(fastgettm, 2)).value != fallback.value or
            (try self.operand(index_tag, 0)).kind != .instruction or (try self.operand(index_tag, 0)).value != second_id + 1 or
            (try self.operand(index_check, 0)).kind != .instruction or (try self.operand(index_check, 0)).value != second_id + 2 or
            (try self.operand(index_check, 1)).kind != .constant or
            (try self.constant((try self.operand(index_check, 1)).value)).tagValue() != lua_tag_table or
            (try self.operand(index_check, 2)).kind != .block or (try self.operand(index_check, 2)).value != fallback.value or
            (try self.operand(index_pointer, 0)).kind != .instruction or (try self.operand(index_pointer, 0)).value != second_id + 1 or
            (try self.operand(index_slot, 0)).kind != .instruction or (try self.operand(index_slot, 0)).value != second_id + 4 or
            (try self.operand(index_slot, 1)).kind != .constant or
            (try self.operand(index_slot, 2)).kind != .vm_const or (try self.operand(index_slot, 2)).value != key_operand.value or
            (try self.operand(index_match, 0)).kind != .instruction or (try self.operand(index_match, 0)).value != second_id + 5 or
            (try self.operand(index_match, 1)).kind != .vm_const or (try self.operand(index_match, 1)).value != key_operand.value or
            (try self.operand(index_match, 2)).kind != .block or (try self.operand(index_match, 2)).value != fallback.value or
            (try self.operand(reloaded_table, 0)).kind != .vm_reg or (try self.operand(reloaded_table, 0)).value != source.value or
            (try self.operand(second_store_pointer, 0)).kind != .vm_reg or
            (try self.operand(second_store_pointer, 0)).value != receiver_destination.value or
            (try self.operand(second_store_pointer, 1)).kind != .instruction or
            (try self.operand(second_store_pointer, 1)).value != second_id + 7 or
            (try self.operand(second_store_tag, 0)).kind != .vm_reg or
            (try self.operand(second_store_tag, 0)).value != receiver_destination.value or
            (try self.operand(second_store_tag, 1)).kind != .constant or
            (try self.constant((try self.operand(second_store_tag, 1)).value)).tagValue() != lua_tag_table or
            (try self.operand(second_load, 0)).kind != .instruction or (try self.operand(second_load, 0)).value != second_id + 5 or
            !try self.intOperandEquals(try self.operand(second_load, 1), 0) or
            (try self.operand(second_store, 0)).kind != .vm_reg or (try self.operand(second_store, 0)).value != destination.value or
            (try self.operand(second_store, 1)).kind != .instruction or (try self.operand(second_store, 1)).value != second_id + 10 or
            (try self.operand(second_jump, 0)).kind != .block or (try self.operand(second_jump, 0)).value != first_rejoin.value)
            return null;

        const fallback_block = try self.snapshot.irBlock(self.function, fallback.value);
        if (fallback_block.kind != .fallback or fallback_block.isEmpty() or fallback_block.finish != fallback_block.start + 1)
            return null;
        const semantic = try self.instruction(fallback_block.start);
        const fallback_jump = try self.instruction(fallback_block.finish);
        if (semantic.command != ir_cmd_fallback_namecall or semantic.operand_count != 4 or
            fallback_jump.command != .jump or fallback_jump.operand_count != 1)
            return null;
        const pc = try self.operand(semantic, 0);
        if (pc.kind != .constant or
            (try self.operand(semantic, 1)).kind != .vm_reg or (try self.operand(semantic, 1)).value != destination.value or
            (try self.operand(semantic, 2)).kind != .vm_reg or (try self.operand(semantic, 2)).value != source.value or
            (try self.operand(semantic, 3)).kind != .vm_const or (try self.operand(semantic, 3)).value != key_operand.value or
            (try self.operand(fallback_jump, 0)).kind != .block or
            (try self.operand(fallback_jump, 0)).value != first_rejoin.value)
            return null;
        const pc_value = (try self.constant(pc.value)).uintValue() orelse return null;
        if ((exit.kind == .vm_exit and exit.value != pc_value) or
            (exit.kind == .block and exit.value != fallback.value) or
            (try self.constant((try self.operand(index_slot, 1)).value)).uintValue() != pc_value)
            return null;
        const expected_fallback_references: u32 = if (exit.kind == .block) 5 else 4;
        if (first_fast.value == fallback.value or second_fast.value == fallback.value or
            first_rejoin.value == first_fast.value or first_rejoin.value == second_fast.value or
            first_rejoin.value == fallback.value or (try self.blockReferenceCount(first_fast.value)) != 1 or
            (try self.blockReferenceCount(second_fast.value)) != 1 or
            (try self.blockReferenceCount(fallback.value)) != expected_fallback_references)
            return null;
        _ = self.requireCompiledTarget(first_rejoin) catch return null;
        return .{
            .start = start,
            .destination = destination.value,
            .source = source.value,
            .key = key,
            .pc = pc_value,
            .first_fast = first_fast.value,
            .second_fast = second_fast.value,
            .fallback = fallback.value,
            .rejoin = first_rejoin.value,
        };
    }

    fn isBypassedPlainTableNamecallBlock(self: Context, block_id: u32) Error!bool {
        if (self.function.entry_block == block_id)
            return false;
        var source_block_id: u32 = 0;
        while (source_block_id < self.function.block_count) : (source_block_id += 1) {
            const source_block = try self.snapshot.irBlock(self.function, source_block_id);
            if (try self.plainTableNamecallPattern(source_block)) |pattern|
                if (block_id == pattern.first_fast or block_id == pattern.second_fast or block_id == pattern.fallback)
                    return true;
        }
        return false;
    }

    fn emitPlainTableNamecallBlock(
        self: Context,
        block_id: u32,
        block: snapshot_v1.IrBlock,
        pattern: PlainTableNamecallPattern,
    ) Error!void {
        try self.body.localGet(self.allocator, self.dispatch_local);
        try self.body.i32Const(self.allocator, @intCast(block_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        if (pattern.start > block.start) {
            if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
                return Error.InvalidBlockTermination;
        }
        try self.emitPlainTableNamecallOperation(pattern);
        try self.body.branch(self.allocator, 1);
        try self.body.end(self.allocator);
    }

    fn emitPlainTableNamecallOperation(self: Context, pattern: PlainTableNamecallPattern) Error!void {
        const key = try self.string_keys.intern(self.allocator, pattern.key);
        try self.emitPcLocation(pattern.pc);
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.destination));
        try self.body.i32Const(self.allocator, @intCast(pattern.source));
        try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(key.offset));
        try self.body.i32Const(self.allocator, @intCast(key.length));
        try self.body.call(self.allocator, self.namecall_plain orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
        try self.body.i32Const(self.allocator, @intCast(pattern.rejoin));
        try self.body.localSet(self.allocator, self.dispatch_local);
    }

    fn tableAllocationPatternContaining(self: Context, instruction_id: u32) Error!?TableAllocationPattern {
        var back: u32 = 0;
        while (back <= 3 and back <= instruction_id) : (back += 1) {
            if (try self.tableAllocationPatternAt(instruction_id - back)) |pattern| {
                if (instruction_id <= pattern.finish)
                    return pattern;
            }
        }
        return null;
    }

    fn emitTableAllocation(self: Context, pattern: TableAllocationPattern) Error!void {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.destination));
        try self.body.i32Const(self.allocator, @intCast(pattern.array_count));
        try self.body.i32Const(self.allocator, @intCast(pattern.node_count));
        const helper = if (pattern.assist)
            self.new_table
        else
            self.new_table_deferred;
        try self.body.call(self.allocator, helper orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
    }

    fn emitUserdataAllocationInstruction(
        self: Context,
        instruction_id: u32,
        instruction_value: snapshot_v1.IrInstruction,
        pattern: UserdataAllocationPattern,
    ) Error!void {
        if (instruction_id == pattern.start)
            return;
        if (instruction_id == pattern.allocation) {
            try self.body.localGet(self.allocator, 0);
            try self.body.i32Const(self.allocator, @intCast(pattern.byte_size));
            try self.body.i32Const(self.allocator, @intCast(pattern.user_tag));
            try self.body.call(self.allocator, self.new_userdata orelse return Error.UnsupportedCommand);
            try self.emitInstructionResultSet(instruction_id);
            try self.emitReloadBase();
            return;
        }
        if (userdataWriteWidth(instruction_value.command) != null) {
            try self.emitUserdataWrite(instruction_value);
            return;
        }
        if (instruction_value.command == .store_pointer) {
            try self.emitStoreI32(instruction_value, 0);
            return;
        }
        if (instruction_value.command == .store_tag) {
            try self.emitStoreTag(instruction_id, instruction_value);
            return;
        }
        return Error.UnsupportedControlFlow;
    }

    fn emitSetList(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        if (instruction_value.operand_count != 6)
            return Error.InvalidOperandCount;
        _ = try self.uintConstant(try self.operand(instruction_value, 0));
        const table = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
        const source = try self.vmRegisterIndex(try self.operand(instruction_value, 2));
        const count = try self.intConstant(try self.operand(instruction_value, 3));
        const start_index = try self.uintConstant(try self.operand(instruction_value, 4));
        const known_size_operand = try self.operand(instruction_value, 5);
        if (count <= 0 or start_index == 0 or
            (known_size_operand.kind != .constant and known_size_operand.kind != .undef))
            return Error.UnsupportedControlFlow;
        const known_size = if (known_size_operand.kind == .constant)
            try self.uintConstant(known_size_operand)
        else
            std.math.maxInt(u32);
        const count_u32: u32 = @intCast(count);
        if (count_u32 > @as(u32, self.proto.max_stack_size) - source or
            (known_size_operand.kind == .constant and count_u32 > known_size -| (start_index - 1)))
            return Error.UnsupportedControlFlow;
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(table));
        try self.body.i32Const(self.allocator, @intCast(source));
        try self.body.i32Const(self.allocator, count);
        try self.body.i32Const(self.allocator, @intCast(start_index));
        try self.body.i32Const(self.allocator, @bitCast(known_size));
        try self.body.call(self.allocator, self.set_list orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
    }

    fn commandRangeMatches(self: Context, start: u32, commands: []const snapshot_v1.IrCommand) Error!bool {
        if (start > self.function.instruction_count -| @as(u32, @intCast(commands.len)))
            return false;
        for (commands, 0..) |command, offset| {
            if ((try self.instruction(start + @as(u32, @intCast(offset)))).command != command)
                return false;
        }
        return true;
    }

    fn concatPatternAt(self: Context, start: u32) Error!?ConcatPattern {
        const commands = [_]snapshot_v1.IrCommand{ .set_savedpc, ir_cmd_concat, .load_tvalue, .store_tvalue, .check_gc };
        if (!try self.commandRangeMatches(start, &commands))
            return null;
        const finish = start + @as(u32, @intCast(commands.len - 1));
        try self.requireSingleCompilableBlockRange(start, finish);

        const marker = try self.instruction(start);
        const concat = try self.instruction(start + 1);
        const load = try self.instruction(start + 2);
        const store = try self.instruction(start + 3);
        const check_gc = try self.instruction(finish);
        if (marker.operand_count != 1 or concat.operand_count != 2 or load.operand_count != 1 or
            store.operand_count != 2 or check_gc.operand_count != 0)
            return null;
        _ = try self.savedPc(marker);

        const source = try self.vmRegisterIndex(try self.operand(concat, 0));
        const count_operand = try self.operand(concat, 1);
        const count = if (count_operand.kind == .constant)
            (try self.constant(count_operand.value)).uintValue() orelse return null
        else
            return null;
        if (count < 2 or count > @as(u32, self.proto.max_stack_size) - source)
            return null;
        const loaded_source = try self.vmRegisterIndex(try self.operand(load, 0));
        const destination = try self.vmRegisterIndex(try self.operand(store, 0));
        const stored = try self.operand(store, 1);
        if (loaded_source != source or stored.kind != .instruction or stored.value != start + 2)
            return null;
        return .{ .start = start, .finish = finish, .destination = destination, .source = source, .count = count };
    }

    fn concatPatternContaining(self: Context, instruction_id: u32) Error!?ConcatPattern {
        var distance: u32 = 0;
        while (distance < 5 and distance <= instruction_id) : (distance += 1) {
            if (try self.concatPatternAt(instruction_id - distance)) |pattern| {
                if (instruction_id <= pattern.finish)
                    return pattern;
            }
        }
        return null;
    }

    fn emitConcat(self: Context, pattern: ConcatPattern) Error!void {
        try self.emitSavedPcLocation(try self.instruction(pattern.start));
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.destination));
        try self.body.i32Const(self.allocator, @intCast(pattern.source));
        try self.body.i32Const(self.allocator, @intCast(pattern.count));
        try self.body.call(self.allocator, self.concat orelse return Error.UnsupportedCommand);
        // Concatenation publishes the result and runs its ordinary GC boundary in the runtime helper.
        try self.emitReloadBase();
    }

    fn uintOperandEquals(self: Context, operand_value: snapshot_v1.IrOperand, expected: u32) Error!bool {
        return operand_value.kind == .constant and (try self.constant(operand_value.value)).uintValue() == expected;
    }

    fn intOperandEquals(self: Context, operand_value: snapshot_v1.IrOperand, expected: i32) Error!bool {
        return operand_value.kind == .constant and (try self.constant(operand_value.value)).intValue() == expected;
    }

    fn stringKey(self: Context, operand_value: snapshot_v1.IrOperand) Error!?[]const u8 {
        if (operand_value.kind != .vm_const)
            return null;
        const constant_value = try self.snapshot.vmConstant(self.proto, operand_value.value);
        if (constant_value.kind != .string)
            return null;
        const key = try self.snapshot.string(constant_value.payload0);
        return key;
    }

    fn stringFallbackRejoin(
        self: Context,
        fallback_id: u32,
        operation: StringTableOperation,
        pc: u32,
        value: u32,
        table: u32,
        key_id: u32,
    ) Error!?u32 {
        if (fallback_id >= self.function.block_count)
            return null;
        const block = try self.snapshot.irBlock(self.function, fallback_id);
        if (block.kind != .fallback or block.isEmpty() or block.finish != block.start + 1)
            return null;
        const semantic = try self.instruction(block.start);
        const jump = try self.instruction(block.finish);
        const expected_command = if (operation == .set) ir_cmd_fallback_settableks else ir_cmd_fallback_gettableks;
        if (semantic.command != expected_command or semantic.operand_count != 4 or jump.command != .jump or jump.operand_count != 1)
            return null;
        const semantic_pc = try self.operand(semantic, 0);
        const semantic_value = try self.operand(semantic, 1);
        const semantic_table = try self.operand(semantic, 2);
        const semantic_key = try self.operand(semantic, 3);
        const target = try self.operand(jump, 0);
        if (!try self.uintOperandEquals(semantic_pc, pc) or
            semantic_value.kind != .vm_reg or semantic_value.value != value or
            semantic_table.kind != .vm_reg or semantic_table.value != table or
            semantic_key.kind != .vm_const or semantic_key.value != key_id or target.kind != .block)
            return null;
        return self.requireDispatchTarget(target) catch return null;
    }

    fn fastcallValueOperand(self: Context, operand_value: snapshot_v1.IrOperand) Error!?u32 {
        if (operand_value.kind == .undef)
            return lbf_operand_none;
        return self.valueOperandEncoding(operand_value) catch return null;
    }

    fn fastcallPatternAt(self: Context, start: u32, block: snapshot_v1.IrBlock) Error!?FastcallPattern {
        if (!block.kind.isCompilable() or block.isEmpty() or start < block.start or start > block.finish)
            return null;
        var saved_id = start;
        const first = try self.instruction(start);
        if (first.command == .check_safe_env) {
            if (first.operand_count != 1 or (try self.operand(first, 0)).kind != .vm_exit)
                return null;
            saved_id = std.math.add(u32, start, 1) catch return Error.ResourceLimit;
        }
        if (saved_id + 3 > block.finish)
            return null;
        const saved_pc = try self.instruction(saved_id);
        const invoke_id = saved_id + 1;
        const invoke = try self.instruction(invoke_id);
        const check = try self.instruction(invoke_id + 1);
        if (saved_pc.command != .set_savedpc or invoke.command != ir_cmd_invoke_fastcall or
            check.command != ir_cmd_check_fastcall_res or invoke.operand_count != 7 or check.operand_count != 2)
            return null;

        const pc = try self.savedPc(saved_pc);
        if (pc == 0)
            return null;
        var fast_pc = pc - 1;
        var word = try self.snapshot.bytecodeWord(self.proto, fast_pc);
        var opcode: u8 = @truncate(word);
        if (opcode != lop_fastcall and opcode != lop_fastcall1) {
            if (pc < 2)
                return null;
            fast_pc = pc - 2;
            word = try self.snapshot.bytecodeWord(self.proto, fast_pc);
            opcode = @truncate(word);
            if (opcode != lop_fastcall2 and opcode != lop_fastcall2k and opcode != lop_fastcall3)
                return null;
        }
        const builtin_operand = try self.operand(invoke, 0);
        if (builtin_operand.kind != .constant)
            return null;
        const builtin_id = (try self.constant(builtin_operand.value)).uintValue() orelse return null;
        if (builtin_id >= 256 or ((word >> 8) & 0xff) != builtin_id)
            return null;

        const destination = try self.vmRegisterIndex(try self.operand(invoke, 1));
        const source = try self.vmRegisterIndex(try self.operand(invoke, 2));
        if (opcode == lop_fastcall1 and ((word >> 16) & 0xff) != source)
            return null;
        const argument_two_operand = try self.operand(invoke, 3);
        const argument_three_operand = try self.operand(invoke, 4);
        const argument_two = (try self.fastcallValueOperand(argument_two_operand)) orelse return null;
        const argument_three = (try self.fastcallValueOperand(argument_three_operand)) orelse return null;
        const parameter_count = try self.intConstant(try self.operand(invoke, 5));
        const result_count = try self.intConstant(try self.operand(invoke, 6));
        if (parameter_count < -1 or result_count < -1)
            return null;
        if (opcode == lop_fastcall) {
            if (parameter_count != -1 or source != destination + 1 or
                argument_two_operand.kind != .vm_reg or argument_two_operand.value != destination + 2 or
                argument_three != lbf_operand_none)
                return null;
        } else if (opcode == lop_fastcall1) {
            const fixed_one = parameter_count == 1 and argument_two == lbf_operand_none and argument_three == lbf_operand_none;
            const open = parameter_count == -1 and source == destination + 1 and
                argument_two_operand.kind == .vm_reg and argument_two_operand.value == destination + 2 and
                argument_three == lbf_operand_none;
            if (!fixed_one and !open)
                return null;
        }
        if (opcode == lop_fastcall2 and (parameter_count != 2 or argument_two_operand.kind != .vm_reg or argument_three != lbf_operand_none))
            return null;
        if (opcode == lop_fastcall2k and (parameter_count != 2 or argument_two_operand.kind != .vm_const or argument_three != lbf_operand_none))
            return null;
        if (opcode == lop_fastcall3 and (parameter_count != 3 or argument_two_operand.kind != .vm_reg or
            argument_three_operand.kind != .vm_reg))
            return null;
        if (opcode != lop_fastcall and opcode != lop_fastcall1) {
            const aux = try self.snapshot.bytecodeWord(self.proto, fast_pc + 1);
            if (opcode == lop_fastcall2 and (aux & 0xff) != argument_two_operand.value)
                return null;
            if (opcode == lop_fastcall2k and aux != argument_two_operand.value)
                return null;
            if (opcode == lop_fastcall3 and
                ((aux & 0xff) != argument_two_operand.value or ((aux >> 8) & 0xff) != argument_three_operand.value))
                return null;
        }

        const checked_result = try self.operand(check, 0);
        const fallback_operand = try self.operand(check, 1);
        if (checked_result.kind != .instruction or checked_result.value != invoke_id or
            fallback_operand.kind != .block or fallback_operand.value >= self.function.block_count)
            return null;
        const fallback = try self.snapshot.irBlock(self.function, fallback_operand.value);
        if (fallback.kind != .fallback or fallback.isEmpty() or fallback.finish <= fallback.start)
            return null;
        const fallback_call = try self.instruction(fallback.finish - 1);
        const fallback_jump = try self.instruction(fallback.finish);
        const call_pc = std.math.add(u32, fast_pc, ((word >> 24) & 0xff) + 1) catch return Error.ResourceLimit;
        if (call_pc >= self.proto.code_count)
            return null;
        const call_word = try self.snapshot.bytecodeWord(self.proto, call_pc);
        if (@as(u8, @truncate(call_word)) != lop_call)
            return null;
        const call_destination = (call_word >> 8) & 0xff;
        const call_parameter_count = @as(i32, @intCast((call_word >> 16) & 0xff)) - 1;
        const call_result_count = @as(i32, @intCast((call_word >> 24) & 0xff)) - 1;
        if (fallback_call.command != .call or fallback_call.operand_count != 3 or
            fallback_jump.command != .jump or fallback_jump.operand_count != 1 or
            destination != call_destination or
            try self.vmRegisterIndex(try self.operand(fallback_call, 0)) != call_destination or
            try self.intConstant(try self.operand(fallback_call, 1)) != call_parameter_count or
            try self.intConstant(try self.operand(fallback_call, 2)) != call_result_count or
            result_count != call_result_count)
            return null;

        var finish = invoke_id + 2;
        if (result_count == -1) {
            const adjust = try self.instruction(finish);
            if (adjust.command != ir_cmd_adjust_stack_to_reg or adjust.operand_count != 2 or
                try self.vmRegisterIndex(try self.operand(adjust, 0)) != destination or
                (try self.operand(adjust, 1)).kind != .instruction or
                (try self.operand(adjust, 1)).value != invoke_id)
                return null;
            finish += 1;
        } else if ((try self.instruction(finish)).command == ir_cmd_adjust_stack_to_top) {
            if ((try self.instruction(finish)).operand_count != 0)
                return null;
            finish += 1;
        }
        if (finish > block.finish)
            return null;
        const terminal = try self.instruction(finish);
        const fast_target = if (terminal.command == .jump and terminal.operand_count == 1)
            try self.operand(terminal, 0)
        else if (block.kind == .linearized) blk: {
            const canonical_rejoin = try self.operand(fallback_jump, 0);
            if (canonical_rejoin.kind != .block or
                canonical_rejoin.value >= self.function.block_count or
                !(try self.snapshot.irBlock(self.function, canonical_rejoin.value)).kind.isCompilable())
                return null;
            break :blk canonical_rejoin;
        } else return null;
        if (fast_target.kind != .block or fast_target.value >= self.function.block_count)
            return null;
        return .{
            .start = start,
            .finish = finish,
            .builtin_id = builtin_id,
            .destination = destination,
            .source = source,
            .argument_two = argument_two,
            .argument_three = argument_three,
            .parameter_count = parameter_count,
            .result_count = result_count,
            .fallback = fallback_operand.value,
            .fast_target = fast_target.value,
        };
    }

    fn stringLengthPattern(self: Context, instruction_id: u32) Error!?StringLengthPattern {
        if (instruction_id + 3 >= self.function.instruction_count)
            return null;
        const string_len = try self.instruction(instruction_id);
        const converted = try self.instruction(instruction_id + 1);
        const store = try self.instruction(instruction_id + 2);
        const store_tag = try self.instruction(instruction_id + 3);
        if (string_len.command != ir_cmd_string_len or converted.command != .int_to_num or store.command != .store_double or
            store_tag.command != .store_tag)
            return null;
        try self.requireOperandCount(string_len, 1);
        try self.requireOperandCount(converted, 1);
        try self.requireOperandCount(store, 2);
        try self.requireOperandCount(store_tag, 2);
        const length_pointer = try self.operand(string_len, 0);
        if (length_pointer.kind != .instruction or length_pointer.value >= self.function.instruction_count)
            return null;
        const load_pointer = try self.instruction(length_pointer.value);
        if (load_pointer.command != .load_pointer)
            return null;
        try self.requireOperandCount(load_pointer, 1);
        const source = try self.vmRegisterIndex(try self.operand(load_pointer, 0));
        if (!try self.hasPreservedStringGuard(source, length_pointer.value) or
            !try self.preservesRegisterToConsumer(source, length_pointer.value, instruction_id))
            return null;
        const converted_length = try self.operand(converted, 0);
        const destination = try self.vmRegisterIndex(try self.operand(store, 0));
        const stored = try self.operand(store, 1);
        const tag_destination = try self.vmRegisterIndex(try self.operand(store_tag, 0));
        const result_tag = try self.operand(store_tag, 1);
        if (converted_length.kind != .instruction or
            converted_length.value != instruction_id or stored.kind != .instruction or
            stored.value != instruction_id + 1 or tag_destination != destination or result_tag.kind != .constant or
            (try self.constant(result_tag.value)).tagValue() != lua_tag_number)
            return null;
        if (instruction_id + 4 < self.function.instruction_count and
            (try self.instruction(instruction_id + 4)).command == .mark_dead)
        {
            const mark_dead = try self.instruction(instruction_id + 4);
            if (mark_dead.operand_count != 2 or
                try self.vmRegisterIndex(try self.operand(mark_dead, 0)) != destination + 1 or
                try self.intConstant(try self.operand(mark_dead, 1)) != -1)
                return null;
        }
        return .{ .source = source, .destination = destination };
    }

    fn hasPreservedStringGuard(self: Context, source: u32, pointer_id: u32) Error!bool {
        var owner_id: ?u32 = null;
        var block_id: u32 = 0;
        while (block_id < self.function.block_count) : (block_id += 1) {
            const block = try self.snapshot.irBlock(self.function, block_id);
            if (!block.isEmpty() and pointer_id >= block.start and pointer_id <= block.finish) {
                if (owner_id != null)
                    return false;
                owner_id = block_id;
            }
        }
        const owner = try self.snapshot.irBlock(self.function, owner_id orelse return false);
        if (try self.rangeHasPreservedStringGuard(source, owner.start, pointer_id))
            return true;
        if (owner.kind != .linearized or owner.use_count != 1)
            return false;

        var predecessor_id: ?u32 = null;
        block_id = 0;
        while (block_id < self.function.block_count) : (block_id += 1) {
            const candidate = try self.snapshot.irBlock(self.function, block_id);
            if (!candidate.kind.isCompilable() or candidate.isEmpty())
                continue;
            var instruction_id = candidate.start;
            while (instruction_id <= candidate.finish) : (instruction_id += 1) {
                const instruction_value = try self.instruction(instruction_id);
                var operand_id: u32 = 0;
                while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                    const operand_value = try self.operand(instruction_value, operand_id);
                    if (operand_value.kind == .block and operand_value.value == owner_id.?) {
                        if (predecessor_id != null and predecessor_id.? != block_id)
                            return false;
                        predecessor_id = block_id;
                    }
                }
            }
        }
        const predecessor = try self.snapshot.irBlock(self.function, predecessor_id orelse return false);
        if (!try self.rangeHasPreservedStringGuard(source, predecessor.start, predecessor.finish))
            return false;
        var instruction_id = owner.start;
        while (instruction_id < pointer_id) : (instruction_id += 1)
            if (try self.instructionWritesRegister(instruction_id, source))
                return false;
        return true;
    }

    fn preservesRegisterToConsumer(self: Context, source: u32, producer_id: u32, consumer_id: u32) Error!bool {
        if (producer_id >= consumer_id)
            return false;
        var producer_block: ?u32 = null;
        var consumer_block: ?u32 = null;
        var block_id: u32 = 0;
        while (block_id < self.function.block_count) : (block_id += 1) {
            const block = try self.snapshot.irBlock(self.function, block_id);
            if (block.isEmpty())
                continue;
            if (producer_id >= block.start and producer_id <= block.finish) {
                if (producer_block != null)
                    return false;
                producer_block = block_id;
            }
            if (consumer_id >= block.start and consumer_id <= block.finish) {
                if (consumer_block != null)
                    return false;
                consumer_block = block_id;
            }
        }
        const producer_owner_id = producer_block orelse return false;
        const consumer_owner_id = consumer_block orelse return false;
        if (producer_owner_id == consumer_owner_id) {
            var instruction_id = producer_id + 1;
            while (instruction_id < consumer_id) : (instruction_id += 1)
                if (try self.instructionWritesRegister(instruction_id, source))
                    return false;
            return true;
        }

        const producer_owner = try self.snapshot.irBlock(self.function, producer_owner_id);
        const consumer_owner = try self.snapshot.irBlock(self.function, consumer_owner_id);
        if (!producer_owner.kind.isCompilable() or consumer_owner.kind != .linearized or consumer_owner.use_count != 1)
            return false;

        // A linearized block with use_count == 1 has one incoming edge. Prove that edge directly
        // from the producer block instead of inventorying the whole function again.
        var owns_edge = false;
        var instruction_id = producer_owner.start;
        while (instruction_id <= producer_owner.finish and !owns_edge) : (instruction_id += 1) {
            const instruction_value = try self.instruction(instruction_id);
            var operand_id: u32 = 0;
            while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                const operand_value = try self.operand(instruction_value, operand_id);
                if (operand_value.kind == .block and operand_value.value == consumer_owner_id) {
                    owns_edge = true;
                    break;
                }
            }
        }
        if (!owns_edge)
            return false;

        instruction_id = producer_id + 1;
        while (instruction_id <= producer_owner.finish) : (instruction_id += 1)
            if (try self.instructionWritesRegister(instruction_id, source))
                return false;
        instruction_id = consumer_owner.start;
        while (instruction_id < consumer_id) : (instruction_id += 1)
            if (try self.instructionWritesRegister(instruction_id, source))
                return false;
        return true;
    }

    fn rangeHasPreservedStringGuard(self: Context, source: u32, start: u32, finish: u32) Error!bool {
        if (start >= finish)
            return false;
        var cursor = finish;
        while (cursor > start) : (cursor -= 1) {
            const check_id = cursor - 1;
            const check = try self.instruction(check_id);
            if (check.command != .check_tag or check.operand_count != 3)
                continue;
            const checked = try self.operand(check, 0);
            const expected = try self.operand(check, 1);
            const failure = try self.operand(check, 2);
            if (checked.kind != .instruction or checked.value + 1 != check_id or
                expected.kind != .constant or (try self.constant(expected.value)).tagValue() != lua_tag_string or
                failure.kind != .vm_exit)
                continue;
            const load = try self.instruction(checked.value);
            if (load.command != .load_tag or load.operand_count != 1 or
                (self.vmRegisterIndex(try self.operand(load, 0)) catch continue) != source)
                continue;
            var between = check_id + 1;
            var overwritten = false;
            while (between < finish) : (between += 1)
                if (try self.instructionWritesRegister(between, source)) {
                    overwritten = true;
                    break;
                };
            if (!overwritten)
                return true;
        }
        return false;
    }

    fn instructionWritesRegister(self: Context, instruction_id: u32, register: u32) Error!bool {
        const instruction_value = try self.instruction(instruction_id);
        switch (instruction_value.command) {
            .store_pointer,
            .store_int,
            .store_int64,
            .store_double,
            .store_tvalue,
            .store_split_tvalue,
            .store_vector,
            .store_tag,
            .store_extra,
            .get_cached_import,
            => if (instruction_value.operand_count != 0 and
                (try self.operand(instruction_value, 0)).kind == .vm_reg and
                (try self.operand(instruction_value, 0)).value == register)
                return true,
            .call => {
                if (instruction_value.operand_count != 3)
                    return true;
                const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
                const result_count = try self.intConstant(try self.operand(instruction_value, 2));
                if (result_count == -1)
                    return register >= destination;
                if (result_count > 0)
                    return register >= destination and register < destination + @as(u32, @intCast(result_count));
            },
            ir_cmd_fastcall, ir_cmd_invoke_fastcall => {
                if (instruction_value.operand_count < 2)
                    return true;
                const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
                const count_operand: u32 = if (instruction_value.command == ir_cmd_fastcall) 3 else 6;
                if (instruction_value.operand_count <= count_operand)
                    return true;
                const result_count = try self.intConstant(try self.operand(instruction_value, count_operand));
                if (result_count == -1)
                    return register >= destination;
                if (result_count > 0)
                    return register >= destination and register < destination + @as(u32, @intCast(result_count));
            },
            .fallback_getvarargs => {
                if (instruction_value.operand_count < 2)
                    return true;
                const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
                return register >= destination;
            },
            else => {},
        }
        return false;
    }

    fn hasPublishedTValue(
        self: Context,
        block: snapshot_v1.IrBlock,
        source: snapshot_v1.IrOperand,
        register: u32,
        consumer_id: u32,
    ) Error!bool {
        if (source.kind != .instruction or source.value >= consumer_id or register >= self.proto.max_stack_size or
            block.isEmpty() or consumer_id < block.start or consumer_id > block.finish)
            return false;

        var publication: ?u32 = null;
        var instruction_id = block.start;
        while (instruction_id < consumer_id) : (instruction_id += 1) {
            const instruction_value = try self.instruction(instruction_id);
            if (instruction_value.command != .store_tvalue or instruction_value.operand_count != 2)
                continue;
            const destination = try self.operand(instruction_value, 0);
            const stored = try self.operand(instruction_value, 1);
            if (destination.kind == .vm_reg and destination.value == register and
                stored.kind == source.kind and stored.value == source.value)
                publication = instruction_id;
        }
        return if (publication) |producer|
            try self.preservesRegisterToConsumer(register, producer, consumer_id)
        else
            false;
    }

    fn compilableOwnerBlock(self: Context, instruction_id: u32) Error!?snapshot_v1.IrBlock {
        var owner: ?snapshot_v1.IrBlock = null;
        var block_id: u32 = 0;
        while (block_id < self.function.block_count) : (block_id += 1) {
            const block = try self.snapshot.irBlock(self.function, block_id);
            if (!block.kind.isCompilable() or block.isEmpty() or
                instruction_id < block.start or instruction_id > block.finish)
                continue;
            if (owner != null)
                return null;
            owner = block;
        }
        return owner;
    }

    fn publishedNumberPayloadRegister(
        self: Context,
        block: snapshot_v1.IrBlock,
        source: snapshot_v1.IrOperand,
        consumer_id: u32,
    ) Error!?u32 {
        if (source.kind != .instruction or source.value >= consumer_id or block.isEmpty() or
            consumer_id < block.start or consumer_id > block.finish)
            return null;

        var publication: ?struct { instruction_id: u32, register: u32 } = null;
        var instruction_id = block.start;
        while (instruction_id < consumer_id) : (instruction_id += 1) {
            const store = try self.instruction(instruction_id);
            if (store.command != .store_double or store.operand_count != 2)
                continue;
            const destination = try self.operand(store, 0);
            const stored = try self.operand(store, 1);
            if (destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
                stored.kind != source.kind or stored.value != source.value)
                continue;
            var publication_id = instruction_id;
            if (instruction_id + 1 < consumer_id) {
                const possible_tag = try self.instruction(instruction_id + 1);
                if (possible_tag.command == .store_tag and possible_tag.operand_count == 2 and
                    (try self.operand(possible_tag, 0)).kind == .vm_reg and
                    (try self.operand(possible_tag, 0)).value == destination.value and
                    (try self.operand(possible_tag, 1)).kind == .constant and
                    (try self.constant((try self.operand(possible_tag, 1)).value)).tagValue() == lua_tag_number)
                    publication_id = instruction_id + 1;
            }
            publication = .{ .instruction_id = publication_id, .register = destination.value };
        }
        const published = publication orelse return null;
        instruction_id = published.instruction_id + 1;
        while (instruction_id < consumer_id) : (instruction_id += 1)
            if (try self.instructionWritesRegister(instruction_id, published.register))
                return null;
        return published.register;
    }

    fn typeNamePattern(self: Context, instruction_id: u32, custom: bool) Error!?TypeNamePattern {
        if (instruction_id + 2 >= self.function.instruction_count)
            return null;
        const get = try self.instruction(instruction_id);
        const store_pointer = try self.instruction(instruction_id + 1);
        const store_tag = try self.instruction(instruction_id + 2);
        if (get.command != (if (custom) ir_cmd_get_typeof else ir_cmd_get_type) or
            store_pointer.command != .store_pointer or store_tag.command != .store_tag)
            return null;
        try self.requireOperandCount(get, 1);
        try self.requireOperandCount(store_pointer, 2);
        try self.requireOperandCount(store_tag, 2);
        const input = try self.operand(get, 0);
        const source = if (custom) try self.vmRegisterIndex(input) else blk: {
            if (input.kind != .instruction or input.value + 1 != instruction_id)
                return null;
            const load_tag = try self.instruction(input.value);
            if (load_tag.command != .load_tag or load_tag.operand_count != 1)
                return null;
            break :blk try self.vmRegisterIndex(try self.operand(load_tag, 0));
        };
        const destination = try self.vmRegisterIndex(try self.operand(store_pointer, 0));
        const stored_pointer = try self.operand(store_pointer, 1);
        const tag_destination = try self.vmRegisterIndex(try self.operand(store_tag, 0));
        const tag = try self.operand(store_tag, 1);
        if (stored_pointer.kind != .instruction or stored_pointer.value != instruction_id or
            tag_destination != destination or tag.kind != .constant or
            (try self.constant(tag.value)).tagValue() != lua_tag_string)
            return null;
        var finish = instruction_id + 2;
        if (instruction_id + 3 < self.function.instruction_count and
            (try self.instruction(instruction_id + 3)).command == .mark_dead)
        {
            const mark_dead = try self.instruction(instruction_id + 3);
            if (mark_dead.operand_count != 2 or
                try self.vmRegisterIndex(try self.operand(mark_dead, 0)) != destination + 1 or
                try self.intConstant(try self.operand(mark_dead, 1)) != -1)
                return null;
            finish += 1;
        }
        return .{ .destination = destination, .source = source, .custom = @intFromBool(custom), .finish = finish };
    }

    fn stringSetPattern(self: Context, block: snapshot_v1.IrBlock) Error!?StringTablePattern {
        if (!block.kind.isCompilable() or block.isEmpty())
            return null;

        const general = [_]snapshot_v1.IrCommand{
            .load_tag,                    .check_tag,            .load_pointer, ir_cmd_get_slot_node_addr,
            ir_cmd_check_slot_match,      ir_cmd_check_readonly, .load_tvalue,  .store_tvalue,
            ir_cmd_barrier_table_forward, .jump,
        };
        const preloaded = [_]snapshot_v1.IrCommand{
            .load_tvalue,  .store_tvalue,             .load_tag,                    .check_tag,
            .load_pointer, ir_cmd_get_slot_node_addr, ir_cmd_check_slot_match,      ir_cmd_check_readonly,
            .nop,          .store_tvalue,             ir_cmd_barrier_table_forward, .jump,
        };
        const published = [_]snapshot_v1.IrCommand{
            .load_tag,                    .check_tag,            .load_pointer, ir_cmd_get_slot_node_addr,
            ir_cmd_check_slot_match,      ir_cmd_check_readonly, .nop,          .store_tvalue,
            ir_cmd_barrier_table_forward, .jump,
        };
        const cloned = [_]snapshot_v1.IrCommand{
            ir_cmd_get_slot_node_addr, ir_cmd_check_slot_match,      ir_cmd_check_readonly, .load_tvalue,
            .store_tvalue,             ir_cmd_barrier_table_forward, .jump,
        };
        const trusted = [_]snapshot_v1.IrCommand{
            ir_cmd_get_slot_node_addr, ir_cmd_check_slot_match,      .nop,  .load_tvalue,
            .store_tvalue,             ir_cmd_barrier_table_forward, .jump,
        };
        const is_general = block.finish >= block.start + general.len - 1 and
            try self.commandRangeMatches(block.finish - @as(u32, @intCast(general.len - 1)), &general);
        const is_preloaded = !is_general and block.finish >= block.start + preloaded.len - 1 and
            try self.commandRangeMatches(block.finish - @as(u32, @intCast(preloaded.len - 1)), &preloaded);
        const is_published = !is_general and !is_preloaded and block.finish >= block.start + published.len - 1 and
            try self.commandRangeMatches(block.finish - @as(u32, @intCast(published.len - 1)), &published);
        const is_cloned = !is_general and !is_preloaded and !is_published and block.finish >= block.start + cloned.len - 1 and
            try self.commandRangeMatches(block.finish - @as(u32, @intCast(cloned.len - 1)), &cloned);
        const is_trusted = !is_general and !is_preloaded and !is_published and !is_cloned and block.finish >= block.start + trusted.len - 1 and
            try self.commandRangeMatches(block.finish - @as(u32, @intCast(trusted.len - 1)), &trusted);
        if (!is_general and !is_preloaded and !is_published and !is_cloned and !is_trusted)
            return null;
        const command_count = if (is_general) general.len else if (is_preloaded) preloaded.len else if (is_published) published.len else if (is_cloned) cloned.len else trusted.len;
        const start = block.finish - @as(u32, @intCast(command_count - 1));
        const semantic_start = start + (if (is_preloaded) @as(u32, 2) else 0);
        const slot_id = start + (if (is_general or is_published) @as(u32, 3) else if (is_preloaded) @as(u32, 5) else @as(u32, 0));
        const match_id = slot_id + 1;
        const load_id = start + (if (is_general) @as(u32, 6) else if (is_preloaded) @as(u32, 0) else @as(u32, 3));
        const store_id = if (is_preloaded) start + 9 else if (is_published) start + 7 else load_id + 1;
        const barrier_id = store_id + 1;
        const slot = try self.instruction(slot_id);
        const match = try self.instruction(match_id);
        const load = try self.instruction(load_id);
        const store = try self.instruction(store_id);
        const barrier = try self.instruction(barrier_id);
        const jump = try self.instruction(block.finish);
        if (slot.operand_count != 3 or match.operand_count != 3 or
            (!is_published and load.operand_count != 1 and load.operand_count != 3) or
            store.operand_count != 3 or barrier.operand_count != 3 or jump.operand_count != 1)
            return null;

        const pointer_operand = try self.operand(slot, 0);
        const pc_operand = try self.operand(slot, 1);
        const key_operand = try self.operand(slot, 2);
        const matched_slot = try self.operand(match, 0);
        const matched_key = try self.operand(match, 1);
        const fallback = try self.operand(match, 2);
        const store_slot = try self.operand(store, 0);
        const store_value = try self.operand(store, 1);
        const store_offset = try self.operand(store, 2);
        const barrier_pointer = try self.operand(barrier, 0);
        const barrier_source = try self.operand(barrier, 1);
        const barrier_tag = try self.operand(barrier, 2);
        const source = if (is_published)
            barrier_source
        else if (is_preloaded)
            try self.operand(try self.instruction(start + 1), 0)
        else
            try self.operand(load, 0);
        const fast_target = try self.operand(jump, 0);
        if (pointer_operand.kind != .instruction or pc_operand.kind != .constant or key_operand.kind != .vm_const or
            matched_slot.kind != .instruction or matched_slot.value != slot_id or
            matched_key.kind != .vm_const or matched_key.value != key_operand.value or fallback.kind != .block or
            source.kind != .vm_reg or source.value >= self.proto.max_stack_size or
            store_slot.kind != .instruction or store_slot.value != slot_id or
            store_value.kind != .instruction or (!is_published and store_value.value != load_id) or
            !try self.intOperandEquals(store_offset, 0) or
            barrier_pointer.kind != .instruction or barrier_pointer.value != pointer_operand.value or
            barrier_source.kind != .vm_reg or barrier_source.value != source.value or
            fast_target.kind != .block)
            return null;
        if (is_published) {
            if ((barrier_tag.kind != .undef and
                (barrier_tag.kind != .constant or (try self.constant(barrier_tag.value)).tagValue() == null)) or
                !try self.hasPublishedTValue(block, store_value, source.value, store_id))
                return null;
        } else if (load.operand_count == 1) {
            if (barrier_tag.kind != .undef)
                return null;
        } else {
            const load_offset = try self.operand(load, 1);
            const load_tag = try self.operand(load, 2);
            if (!try self.intOperandEquals(load_offset, 0) or load_tag.kind != .constant or
                (try self.constant(load_tag.value)).tagValue() == null or barrier_tag.kind != .constant or
                (try self.constant(barrier_tag.value)).tagValue() != (try self.constant(load_tag.value)).tagValue())
                return null;
        }
        if (is_preloaded) {
            const publication = try self.instruction(start + 1);
            if (publication.operand_count != 2 or
                (try self.operand(publication, 1)).kind != .instruction or
                (try self.operand(publication, 1)).value != load_id or
                try self.constantLoadPatternAt(load_id) == null)
                return null;
        }
        const pc = (try self.constant(pc_operand.value)).uintValue() orelse return null;
        const key = (try self.stringKey(key_operand)) orelse return null;

        var table: u32 = undefined;
        if (is_general or is_preloaded or is_published) {
            const load_tag = try self.instruction(semantic_start);
            const check_tag = try self.instruction(semantic_start + 1);
            const load_pointer = try self.instruction(semantic_start + 2);
            const table_operand = try self.operand(load_tag, 0);
            if (load_tag.operand_count != 1 or check_tag.operand_count != 3 or load_pointer.operand_count != 1 or
                table_operand.kind != .vm_reg or table_operand.value >= self.proto.max_stack_size or
                (try self.operand(check_tag, 0)).kind != .instruction or (try self.operand(check_tag, 0)).value != semantic_start or
                (try self.operand(check_tag, 1)).kind != .constant or
                (try self.constant((try self.operand(check_tag, 1)).value)).tagValue() != lua_tag_table or
                (((try self.operand(check_tag, 2)).kind != .vm_exit or (try self.operand(check_tag, 2)).value != pc) and
                    ((try self.operand(check_tag, 2)).kind != .block or (try self.operand(check_tag, 2)).value != fallback.value)) or
                (try self.operand(load_pointer, 0)).kind != .vm_reg or (try self.operand(load_pointer, 0)).value != table_operand.value or
                pointer_operand.value != semantic_start + 2)
                return null;
            table = table_operand.value;
            const readonly = try self.instruction(semantic_start + 5);
            if (readonly.operand_count != 2 or
                (try self.operand(readonly, 0)).kind != .instruction or (try self.operand(readonly, 0)).value != semantic_start + 2 or
                (try self.operand(readonly, 1)).kind != .block or (try self.operand(readonly, 1)).value != fallback.value)
                return null;
        } else if (is_cloned) {
            const readonly = try self.instruction(start + 2);
            if (readonly.operand_count != 2 or
                (try self.operand(readonly, 0)).kind != .instruction or
                (try self.operand(readonly, 0)).value != pointer_operand.value or
                (try self.operand(readonly, 1)).kind != .block or
                (try self.operand(readonly, 1)).value != fallback.value)
                return null;
            table = (try self.dupTableRegisterForPointer(pointer_operand.value)) orelse return null;
        } else {
            const allocation = (try self.tableAllocationPatternContaining(pointer_operand.value)) orelse return null;
            if (allocation.start != pointer_operand.value or allocation.node_count != 4)
                return null;
            table = allocation.destination;
        }
        const rejoin = (try self.stringFallbackRejoin(fallback.value, .set, pc, source.value, table, key_operand.value)) orelse return null;
        return .{ .operation = .set, .start = semantic_start, .pc = pc, .table = table, .value = source.value, .key = key, .fallback = fallback.value, .fast_target = fast_target.value, .rejoin = rejoin };
    }

    fn stringGetPattern(self: Context, block: snapshot_v1.IrBlock) Error!?StringTablePattern {
        const commands = [_]snapshot_v1.IrCommand{
            .load_tag,               .check_tag,   .load_pointer, ir_cmd_get_slot_node_addr,
            ir_cmd_check_slot_match, .load_tvalue, .store_tvalue, .jump,
        };
        if (!block.kind.isCompilable() or block.isEmpty() or block.finish < block.start + commands.len - 1)
            return null;
        const start = block.finish - @as(u32, @intCast(commands.len - 1));
        if (!try self.commandRangeMatches(start, &commands))
            return null;
        const load_tag = try self.instruction(start);
        const check_tag = try self.instruction(start + 1);
        const load_pointer = try self.instruction(start + 2);
        const slot = try self.instruction(start + 3);
        const match = try self.instruction(start + 4);
        const load = try self.instruction(start + 5);
        const store = try self.instruction(start + 6);
        const jump = try self.instruction(start + 7);
        if (load_tag.operand_count != 1 or check_tag.operand_count != 3 or load_pointer.operand_count != 1 or
            slot.operand_count != 3 or match.operand_count != 3 or load.operand_count != 2 or
            store.operand_count != 2 or jump.operand_count != 1)
            return null;
        const table = try self.operand(load_tag, 0);
        const checked = try self.operand(check_tag, 0);
        const tag = try self.operand(check_tag, 1);
        const check_fallback = try self.operand(check_tag, 2);
        const pointer_table = try self.operand(load_pointer, 0);
        const slot_pointer = try self.operand(slot, 0);
        const pc_operand = try self.operand(slot, 1);
        const key_operand = try self.operand(slot, 2);
        const matched_slot = try self.operand(match, 0);
        const matched_key = try self.operand(match, 1);
        const fallback = try self.operand(match, 2);
        const loaded_slot = try self.operand(load, 0);
        const load_offset = try self.operand(load, 1);
        const destination = try self.operand(store, 0);
        const stored = try self.operand(store, 1);
        const fast_target = try self.operand(jump, 0);
        if (table.kind != .vm_reg or table.value >= self.proto.max_stack_size or
            checked.kind != .instruction or checked.value != start or tag.kind != .constant or
            (try self.constant(tag.value)).tagValue() != lua_tag_table or
            ((check_fallback.kind != .block or check_fallback.value != fallback.value) and
                (check_fallback.kind != .vm_exit or check_fallback.value != ((try self.constant(pc_operand.value)).uintValue() orelse return null))) or
            pointer_table.kind != .vm_reg or pointer_table.value != table.value or
            slot_pointer.kind != .instruction or slot_pointer.value != start + 2 or pc_operand.kind != .constant or
            key_operand.kind != .vm_const or matched_slot.kind != .instruction or matched_slot.value != start + 3 or
            matched_key.kind != .vm_const or matched_key.value != key_operand.value or fallback.kind != .block or
            loaded_slot.kind != .instruction or loaded_slot.value != start + 3 or !try self.intOperandEquals(load_offset, 0) or
            destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
            stored.kind != .instruction or stored.value != start + 5 or fast_target.kind != .block)
            return null;
        const pc = (try self.constant(pc_operand.value)).uintValue() orelse return null;
        const key = (try self.stringKey(key_operand)) orelse return null;
        const rejoin = (try self.stringFallbackRejoin(fallback.value, .get, pc, destination.value, table.value, key_operand.value)) orelse return null;
        return .{ .operation = .get, .start = start, .pc = pc, .table = table.value, .value = destination.value, .key = key, .fallback = fallback.value, .fast_target = fast_target.value, .rejoin = rejoin };
    }

    fn inlineStringGetPatternAt(self: Context, start: u32, block: snapshot_v1.IrBlock) Error!?StringTablePattern {
        const commands = [_]snapshot_v1.IrCommand{
            .load_tag,               .check_tag,   .load_pointer, ir_cmd_get_slot_node_addr,
            ir_cmd_check_slot_match, .load_tvalue, .store_tvalue,
        };
        if (!block.kind.isCompilable() or block.isEmpty() or start < block.start or start > block.finish or
            block.finish - start < commands.len - 1 or !try self.commandRangeMatches(start, &commands))
            return null;

        const load_tag = try self.instruction(start);
        const check_tag = try self.instruction(start + 1);
        const load_pointer = try self.instruction(start + 2);
        const slot = try self.instruction(start + 3);
        const match = try self.instruction(start + 4);
        const load = try self.instruction(start + 5);
        const store = try self.instruction(start + 6);
        if (load_tag.operand_count != 1 or check_tag.operand_count != 3 or load_pointer.operand_count != 1 or
            slot.operand_count != 3 or match.operand_count != 3 or load.operand_count != 2 or store.operand_count != 2)
            return null;

        const table = try self.operand(load_tag, 0);
        const checked = try self.operand(check_tag, 0);
        const tag = try self.operand(check_tag, 1);
        const check_fallback = try self.operand(check_tag, 2);
        const pointer_table = try self.operand(load_pointer, 0);
        const slot_pointer = try self.operand(slot, 0);
        const pc_operand = try self.operand(slot, 1);
        const key_operand = try self.operand(slot, 2);
        const matched_slot = try self.operand(match, 0);
        const matched_key = try self.operand(match, 1);
        const fallback = try self.operand(match, 2);
        const loaded_slot = try self.operand(load, 0);
        const load_offset = try self.operand(load, 1);
        const destination = try self.operand(store, 0);
        const stored = try self.operand(store, 1);
        if (table.kind != .vm_reg or table.value >= self.proto.max_stack_size or
            checked.kind != .instruction or checked.value != start or tag.kind != .constant or
            (try self.constant(tag.value)).tagValue() != lua_tag_table or
            pointer_table.kind != .vm_reg or pointer_table.value != table.value or
            slot_pointer.kind != .instruction or slot_pointer.value != start + 2 or pc_operand.kind != .constant or
            key_operand.kind != .vm_const or matched_slot.kind != .instruction or matched_slot.value != start + 3 or
            matched_key.kind != .vm_const or matched_key.value != key_operand.value or fallback.kind != .block or
            loaded_slot.kind != .instruction or loaded_slot.value != start + 3 or !try self.intOperandEquals(load_offset, 0) or
            destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
            stored.kind != .instruction or stored.value != start + 5)
            return null;

        const pc = (try self.constant(pc_operand.value)).uintValue() orelse return null;
        if ((check_fallback.kind != .block or check_fallback.value != fallback.value) and
            (check_fallback.kind != .vm_exit or check_fallback.value != pc))
            return null;
        const key = (try self.stringKey(key_operand)) orelse return null;
        const rejoin = (try self.stringFallbackRejoin(fallback.value, .get, pc, destination.value, table.value, key_operand.value)) orelse return null;
        return .{ .operation = .get, .start = start, .pc = pc, .table = table.value, .value = destination.value, .key = key, .fallback = fallback.value, .fast_target = rejoin, .rejoin = rejoin };
    }

    fn stringTablePattern(self: Context, block: snapshot_v1.IrBlock) Error!?StringTablePattern {
        if (try self.stringSetPattern(block)) |pattern|
            return pattern;
        return self.stringGetPattern(block);
    }

    fn globalFallback(
        self: Context,
        fallback_id: u32,
        operation: GlobalOperation,
        pc: u32,
        value: u32,
        key_id: u32,
    ) Error!?u32 {
        if (fallback_id >= self.function.block_count)
            return null;
        const block = try self.snapshot.irBlock(self.function, fallback_id);
        if (block.kind != .fallback or block.isEmpty() or block.finish != block.start + 1)
            return null;
        const semantic = try self.instruction(block.start);
        const jump = try self.instruction(block.finish);
        const expected_command = if (operation == .get) ir_cmd_fallback_getglobal else ir_cmd_fallback_setglobal;
        if (semantic.command != expected_command or semantic.operand_count != 3 or
            jump.command != .jump or jump.operand_count != 1)
            return null;
        const semantic_pc = try self.operand(semantic, 0);
        const semantic_value = try self.operand(semantic, 1);
        const semantic_key = try self.operand(semantic, 2);
        if (!try self.uintOperandEquals(semantic_pc, pc) or semantic_value.kind != .vm_reg or semantic_value.value != value or
            semantic_key.kind != .vm_const or semantic_key.value != key_id)
            return null;
        return self.requireCompiledTarget(try self.operand(jump, 0)) catch return null;
    }

    fn globalPatternFor(self: Context, block: snapshot_v1.IrBlock, operation: GlobalOperation) Error!?GlobalPattern {
        if (!block.kind.isCompilable() or block.isEmpty())
            return null;
        const get_commands = [_]snapshot_v1.IrCommand{
            .load_env, ir_cmd_get_slot_node_addr, ir_cmd_check_slot_match, .load_tvalue, .store_tvalue, .jump,
        };
        const set_commands = [_]snapshot_v1.IrCommand{
            .load_env,    ir_cmd_get_slot_node_addr, ir_cmd_check_slot_match,      ir_cmd_check_readonly,
            .load_tvalue, .store_tvalue,             ir_cmd_barrier_table_forward, .jump,
        };
        const command_count = if (operation == .get) get_commands.len else set_commands.len;
        if (block.finish < block.start + command_count - 1)
            return null;
        const start = block.finish - @as(u32, @intCast(command_count - 1));
        if (operation == .get) {
            if (!try self.commandRangeMatches(start, &get_commands))
                return null;
        } else if (!try self.commandRangeMatches(start, &set_commands))
            return null;

        const env = try self.instruction(start);
        const slot = try self.instruction(start + 1);
        const match = try self.instruction(start + 2);
        const load_id = start + (if (operation == .get) @as(u32, 3) else 4);
        const store_id = load_id + 1;
        const load = try self.instruction(load_id);
        const store = try self.instruction(store_id);
        const jump = try self.instruction(block.finish);
        if (env.operand_count != 0 or slot.operand_count != 3 or match.operand_count != 3 or
            load.operand_count != (if (operation == .get) @as(u32, 2) else 1) or
            store.operand_count != (if (operation == .get) @as(u32, 2) else 3) or jump.operand_count != 1)
            return null;
        const slot_env = try self.operand(slot, 0);
        const pc_operand = try self.operand(slot, 1);
        const key_operand = try self.operand(slot, 2);
        const matched_slot = try self.operand(match, 0);
        const matched_key = try self.operand(match, 1);
        const fallback = try self.operand(match, 2);
        const fast_target = try self.operand(jump, 0);
        if (slot_env.kind != .instruction or slot_env.value != start or pc_operand.kind != .constant or
            key_operand.kind != .vm_const or matched_slot.kind != .instruction or matched_slot.value != start + 1 or
            matched_key.kind != .vm_const or matched_key.value != key_operand.value or fallback.kind != .block or
            fast_target.kind != .block)
            return null;
        const pc = (try self.constant(pc_operand.value)).uintValue() orelse return null;
        const key = (try self.stringKey(key_operand)) orelse return null;

        var value: u32 = undefined;
        if (operation == .get) {
            const loaded_slot = try self.operand(load, 0);
            const load_offset = try self.operand(load, 1);
            const destination = try self.operand(store, 0);
            const stored = try self.operand(store, 1);
            if (loaded_slot.kind != .instruction or loaded_slot.value != start + 1 or
                !try self.intOperandEquals(load_offset, 0) or destination.kind != .vm_reg or
                destination.value >= self.proto.max_stack_size or stored.kind != .instruction or stored.value != load_id)
                return null;
            value = destination.value;
        } else {
            const readonly = try self.instruction(start + 3);
            const source = try self.operand(load, 0);
            const store_slot = try self.operand(store, 0);
            const store_value = try self.operand(store, 1);
            const store_offset = try self.operand(store, 2);
            const barrier = try self.instruction(start + 6);
            if (readonly.operand_count != 2 or barrier.operand_count != 3 or source.kind != .vm_reg or
                source.value >= self.proto.max_stack_size or
                (try self.operand(readonly, 0)).kind != .instruction or (try self.operand(readonly, 0)).value != start or
                (try self.operand(readonly, 1)).kind != .block or (try self.operand(readonly, 1)).value != fallback.value or
                store_slot.kind != .instruction or store_slot.value != start + 1 or
                store_value.kind != .instruction or store_value.value != load_id or !try self.intOperandEquals(store_offset, 0) or
                (try self.operand(barrier, 0)).kind != .instruction or (try self.operand(barrier, 0)).value != start or
                (try self.operand(barrier, 1)).kind != .vm_reg or (try self.operand(barrier, 1)).value != source.value or
                (try self.operand(barrier, 2)).kind != .undef)
                return null;
            value = source.value;
        }
        const rejoin = (try self.globalFallback(fallback.value, operation, pc, value, key_operand.value)) orelse return null;
        return .{
            .operation = operation,
            .start = start,
            .value = value,
            .key = key,
            .pc = pc,
            .fast_target = try self.requireCompiledTarget(fast_target),
            .rejoin = rejoin,
        };
    }

    fn globalPattern(self: Context, block: snapshot_v1.IrBlock) Error!?GlobalPattern {
        if (try self.globalPatternFor(block, .set)) |pattern|
            return pattern;
        return self.globalPatternFor(block, .get);
    }

    fn globalHeadPatternAt(self: Context, start: u32, block: snapshot_v1.IrBlock) Error!?GlobalPattern {
        if (!block.kind.isCompilable() or start < block.start or start + 2 > block.finish)
            return null;
        const env = try self.instruction(start);
        const slot = try self.instruction(start + 1);
        const match = try self.instruction(start + 2);
        if (env.command != .load_env or slot.command != ir_cmd_get_slot_node_addr or
            match.command != ir_cmd_check_slot_match or env.operand_count != 0 or
            slot.operand_count != 3 or match.operand_count != 3)
            return null;
        const slot_env = try self.operand(slot, 0);
        const pc_operand = try self.operand(slot, 1);
        const key_operand = try self.operand(slot, 2);
        const matched_slot = try self.operand(match, 0);
        const matched_key = try self.operand(match, 1);
        const fallback = try self.operand(match, 2);
        if (slot_env.kind != .instruction or slot_env.value != start or pc_operand.kind != .constant or
            key_operand.kind != .vm_const or matched_slot.kind != .instruction or matched_slot.value != start + 1 or
            matched_key.kind != .vm_const or matched_key.value != key_operand.value or fallback.kind != .block)
            return null;
        const pc = (try self.constant(pc_operand.value)).uintValue() orelse return null;
        const key = (try self.stringKey(key_operand)) orelse return null;
        const fallback_block = try self.snapshot.irBlock(self.function, fallback.value);
        if (fallback_block.kind != .fallback or fallback_block.isEmpty() or fallback_block.finish != fallback_block.start + 1)
            return null;
        const semantic = try self.instruction(fallback_block.start);
        const jump = try self.instruction(fallback_block.finish);
        if ((semantic.command != ir_cmd_fallback_getglobal and semantic.command != ir_cmd_fallback_setglobal) or
            semantic.operand_count != 3 or jump.command != .jump or jump.operand_count != 1)
            return null;
        const semantic_pc = try self.operand(semantic, 0);
        const value = try self.operand(semantic, 1);
        const semantic_key = try self.operand(semantic, 2);
        const rejoin = try self.operand(jump, 0);
        if (!try self.uintOperandEquals(semantic_pc, pc) or value.kind != .vm_reg or
            value.value >= self.proto.max_stack_size or semantic_key.kind != .vm_const or
            semantic_key.value != key_operand.value or rejoin.kind != .block)
            return null;
        return .{
            .operation = if (semantic.command == ir_cmd_fallback_getglobal) .get else .set,
            .start = start,
            .value = value.value,
            .key = key,
            .pc = pc,
            .fast_target = fallback.value,
            .rejoin = try self.requireCompiledTarget(rejoin),
        };
    }

    fn genericTableFallback(
        self: Context,
        fallback_id: u32,
        operation: GenericTableOperation,
        value: u32,
        table: u32,
        key: snapshot_v1.IrOperand,
    ) Error!?GenericTableFallback {
        if (fallback_id >= self.function.block_count)
            return null;
        const block = try self.snapshot.irBlock(self.function, fallback_id);
        if (block.kind != .fallback or block.isEmpty() or block.finish != block.start + 2)
            return null;
        const marker = try self.instruction(block.start);
        const semantic = try self.instruction(block.start + 1);
        const jump = try self.instruction(block.finish);
        const expected_command = if (operation == .set) ir_cmd_set_table else ir_cmd_get_table;
        if (marker.command != .set_savedpc or marker.operand_count != 1 or
            semantic.command != expected_command or semantic.operand_count != 3 or
            jump.command != .jump or jump.operand_count != 1 or try self.savedPc(marker) == 0)
            return null;
        const semantic_value = try self.operand(semantic, 0);
        const semantic_table = try self.operand(semantic, 1);
        const semantic_key = try self.operand(semantic, 2);
        if (semantic_value.kind != .vm_reg or semantic_value.value != value or
            semantic_table.kind != .vm_reg or semantic_table.value != table or
            semantic_key.kind != key.kind or semantic_key.value != key.value)
            return null;
        return .{
            .marker = marker,
            .rejoin = self.requireCompiledTarget(try self.operand(jump, 0)) catch return null,
        };
    }

    fn inlineGenericTableSetPatternAt(self: Context, start: u32) Error!?InlineGenericTablePattern {
        const commands = [_]snapshot_v1.IrCommand{
            .load_tag,               .check_tag,                .nop,                         .nop,
            .load_pointer,           .nop,                      ir_cmd_try_num_to_index,      .sub_int,
            ir_cmd_check_array_size, ir_cmd_check_no_metatable, ir_cmd_check_readonly,        ir_cmd_get_arr_addr,
            .nop,                    .store_split_tvalue,       ir_cmd_barrier_table_forward,
        };
        if (!try self.commandRangeMatches(start, &commands))
            return null;
        const finish = start + @as(u32, @intCast(commands.len - 1));
        self.requireSingleCompilableBlockRange(start, finish) catch return null;

        {
            // Linearization reuses the earlier numeric key proof and the just-published literal value.
            // Anchor the fused operation in the semantic fallback registers first, then prove every
            // surviving fast-path pointer, index, guard, store, and barrier references those registers.
            const semantic_check = try self.instruction(start + 1);
            if (semantic_check.operand_count != 3)
                return null;
            const semantic_fallback = try self.operand(semantic_check, 2);
            if (semantic_fallback.kind != .block or semantic_fallback.value >= self.function.block_count)
                return null;
            const fallback_block = try self.snapshot.irBlock(self.function, semantic_fallback.value);
            if (fallback_block.kind != .fallback or fallback_block.isEmpty() or fallback_block.finish != fallback_block.start + 2)
                return null;
            const semantic = try self.instruction(fallback_block.start + 1);
            const marker = try self.instruction(fallback_block.start);
            const fallback_jump = try self.instruction(fallback_block.finish);
            if (marker.command != .set_savedpc or marker.operand_count != 1 or try self.savedPc(marker) == 0 or
                semantic.command != ir_cmd_set_table or semantic.operand_count != 3 or
                fallback_jump.command != .jump or fallback_jump.operand_count != 1)
                return null;
            const rejoin = try self.operand(fallback_jump, 0);
            if (rejoin.kind != .block or rejoin.value >= self.function.block_count)
                return null;
            const rejoin_block = try self.snapshot.irBlock(self.function, rejoin.value);
            if (!rejoin_block.kind.isCompilable() or rejoin_block.isEmpty())
                return null;
            const value = self.vmRegisterIndex(try self.operand(semantic, 0)) catch return null;
            const table = self.vmRegisterIndex(try self.operand(semantic, 1)) catch return null;
            const key = self.vmRegisterIndex(try self.operand(semantic, 2)) catch return null;

            const table_load = try self.instruction(start);
            const pointer = try self.instruction(start + 4);
            const index = try self.instruction(start + 6);
            const zero_index = try self.instruction(start + 7);
            const size_check = try self.instruction(start + 8);
            const metatable = try self.instruction(start + 9);
            const readonly = try self.instruction(start + 10);
            const address = try self.instruction(start + 11);
            const store = try self.instruction(start + 13);
            const barrier = try self.instruction(finish);
            const indexed_value = try self.operand(index, 0);
            if (table_load.operand_count != 1 or (try self.operand(table_load, 0)).kind != .vm_reg or
                (try self.operand(table_load, 0)).value != table or pointer.operand_count != 1 or
                (try self.operand(pointer, 0)).kind != .vm_reg or (try self.operand(pointer, 0)).value != table or
                index.operand_count != 2 or indexed_value.kind != .instruction or indexed_value.value >= start)
                return null;
            const key_load = try self.instruction(indexed_value.value);
            if (key_load.command != .load_double or key_load.operand_count != 1 or
                (try self.operand(key_load, 0)).kind != .vm_reg or (try self.operand(key_load, 0)).value != key or
                (try self.operand(index, 1)).kind != .block or
                (try self.operand(index, 1)).value != semantic_fallback.value or
                zero_index.operand_count != 2 or (try self.operand(zero_index, 0)).kind != .instruction or
                (try self.operand(zero_index, 0)).value != start + 6 or
                !try self.intOperandEquals(try self.operand(zero_index, 1), 1))
                return null;
            inline for (.{ size_check, metatable, readonly }) |guard| {
                const failure_index: u32 = if (guard.command == ir_cmd_check_array_size) 2 else 1;
                if ((try self.operand(guard, 0)).kind != .instruction or
                    (try self.operand(guard, 0)).value != start + 4 or
                    (try self.operand(guard, failure_index)).kind != .block or
                    (try self.operand(guard, failure_index)).value != semantic_fallback.value)
                    return null;
            }
            if ((try self.operand(size_check, 1)).kind != .instruction or
                (try self.operand(size_check, 1)).value != start + 7)
                return null;
            if ((try self.operand(address, 0)).kind != .instruction or (try self.operand(address, 0)).value != start + 4 or
                (try self.operand(address, 1)).kind != .instruction or (try self.operand(address, 1)).value != start + 7)
                return null;
            if ((store.operand_count != 3 and store.operand_count != 4) or
                (try self.operand(store, 0)).kind != .instruction or
                (try self.operand(store, 0)).value != start + 11 or
                (try self.operand(store, 1)).kind != .constant or
                (try self.constant((try self.operand(store, 1)).value)).tagValue() != lua_tag_table or
                (store.operand_count == 4 and !try self.intOperandEquals(try self.operand(store, 3), 0)))
                return null;
            if (barrier.operand_count != 3 or (try self.operand(barrier, 0)).kind != .instruction or
                (try self.operand(barrier, 0)).value != start + 4 or (try self.operand(barrier, 1)).kind != .vm_reg or
                (try self.operand(barrier, 1)).value != value or (try self.operand(barrier, 2)).kind != .constant or
                (try self.constant((try self.operand(barrier, 2)).value)).tagValue() != lua_tag_table)
                return null;
            const stored_value = try self.operand(store, 2);
            if (stored_value.kind != .instruction or stored_value.value + 2 >= self.function.instruction_count)
                return null;
            const producer = try self.instruction(stored_value.value);
            const publication = try self.instruction(stored_value.value + 1);
            const publication_tag = try self.instruction(stored_value.value + 2);
            if (producer.command != ir_cmd_dup_table or publication.command != .store_pointer or publication.operand_count != 2 or
                publication_tag.command != .store_tag or publication_tag.operand_count != 2 or
                (try self.operand(publication, 0)).kind != .vm_reg or (try self.operand(publication, 0)).value != value or
                (try self.operand(publication, 1)).kind != .instruction or
                (try self.operand(publication, 1)).value != stored_value.value or
                (try self.operand(publication_tag, 0)).kind != .vm_reg or
                (try self.operand(publication_tag, 0)).value != value or
                (try self.operand(publication_tag, 1)).kind != .constant or
                (try self.constant((try self.operand(publication_tag, 1)).value)).tagValue() != lua_tag_table)
                return null;
            return .{
                .pattern = .{
                    .operation = .set,
                    .start = start,
                    .table = table,
                    .key = try self.valueOperandEncoding(try self.operand(semantic, 2)),
                    .register_key = key,
                    .immediate_number_key = null,
                    .value = value,
                    .marker = marker,
                    .fallback = semantic_fallback.value,
                    .fast_target = 0,
                    .rejoin = rejoin.value,
                },
                .finish = finish,
                .address = start + 11,
            };
        }
    }

    fn inlineGenericTableSetPatternContaining(self: Context, instruction_id: u32) Error!?InlineGenericTablePattern {
        var distance: u32 = 0;
        while (distance < 15 and distance <= instruction_id) : (distance += 1) {
            const start = instruction_id - distance;
            if ((try self.instruction(start)).command == .load_tag)
                if (try self.inlineGenericTableSetPatternAt(start)) |pattern|
                    if (instruction_id <= pattern.finish) return pattern;
        }
        return null;
    }

    fn semanticTableReloadPatternAt(self: Context, start: u32) Error!?SemanticTableReloadPattern {
        if (start + 1 >= self.function.instruction_count)
            return null;
        const load = try self.instruction(start);
        const store = try self.instruction(start + 1);
        if (load.command != .load_tvalue or (load.operand_count != 1 and load.operand_count != 2) or
            store.command != .store_tvalue or store.operand_count != 2)
            return null;
        const address = try self.operand(load, 0);
        if (address.kind != .instruction)
            return null;
        if (load.operand_count == 2 and !try self.intOperandEquals(try self.operand(load, 1), 0))
            return null;
        const destination = self.vmRegisterIndex(try self.operand(store, 0)) catch return null;
        const stored = try self.operand(store, 1);
        if (stored.kind != .instruction or stored.value != start)
            return null;

        if (address.value >= 11)
            if (try self.inlineGenericTableSetPatternAt(address.value - 11)) |owner|
                if (owner.address == address.value)
                    return .{
                        .start = start,
                        .finish = start + 1,
                        .destination = destination,
                        .table = owner.pattern.table,
                        .key = .{ .dynamic = .{ .register = owner.pattern.key, .marker = owner.pattern.marker } },
                    };
        if (try self.literalFieldSetPatternAt(address.value)) |owner|
            return .{
                .start = start,
                .finish = start + 1,
                .destination = destination,
                .table = owner.table,
                .key = .{ .string = .{ .value = owner.key, .pc = owner.pc } },
            };
        return null;
    }

    fn semanticTableReloadPatternContaining(self: Context, instruction_id: u32) Error!?SemanticTableReloadPattern {
        if (try self.semanticTableReloadPatternAt(instruction_id)) |pattern|
            return pattern;
        if (instruction_id != 0)
            if (try self.semanticTableReloadPatternAt(instruction_id - 1)) |pattern|
                if (pattern.finish == instruction_id) return pattern;
        return null;
    }

    fn emitSemanticTableReload(self: Context, pattern: SemanticTableReloadPattern) Error!void {
        switch (pattern.key) {
            .dynamic => |key| {
                try self.emitSavedPcLocation(key.marker);
                try self.body.localGet(self.allocator, 0);
                try self.body.i32Const(self.allocator, @intCast(pattern.destination));
                try self.body.i32Const(self.allocator, @intCast(pattern.table));
                try self.body.i32Const(self.allocator, @intCast(key.register));
                try self.body.call(self.allocator, self.table_get orelse return Error.UnsupportedCommand);
            },
            .string => |key| {
                const interned = try self.string_keys.intern(self.allocator, key.value);
                try self.emitPcLocation(key.pc);
                try self.body.localGet(self.allocator, 0);
                try self.body.i32Const(self.allocator, @intCast(pattern.destination));
                try self.body.i32Const(self.allocator, @intCast(pattern.table));
                try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(interned.offset));
                try self.body.i32Const(self.allocator, @intCast(interned.length));
                try self.body.call(self.allocator, self.table_get_string orelse return Error.UnsupportedCommand);
            },
        }
        try self.emitReloadBase();
    }

    fn genericTableSetPattern(self: Context, block: snapshot_v1.IrBlock) Error!?GenericTablePattern {
        if (!block.kind.isCompilable() or block.isEmpty())
            return null;
        const general = [_]snapshot_v1.IrCommand{
            .load_tag,               .check_tag,                .load_tag,                    .check_tag,
            .load_pointer,           .load_double,              ir_cmd_try_num_to_index,      .sub_int,
            ir_cmd_check_array_size, ir_cmd_check_no_metatable, ir_cmd_check_readonly,        ir_cmd_get_arr_addr,
            .load_tvalue,            .store_tvalue,             ir_cmd_barrier_table_forward, .jump,
        };
        const general_reused_value = [_]snapshot_v1.IrCommand{
            .load_tag,               .check_tag,                .load_tag,                    .check_tag,
            .load_pointer,           .load_double,              ir_cmd_try_num_to_index,      .sub_int,
            ir_cmd_check_array_size, ir_cmd_check_no_metatable, ir_cmd_check_readonly,        ir_cmd_get_arr_addr,
            .nop,                    .store_tvalue,             ir_cmd_barrier_table_forward, .jump,
        };
        const trusted = [_]snapshot_v1.IrCommand{
            .load_tag,                    .check_tag,          .nop,                    .load_double,
            ir_cmd_try_num_to_index,      .sub_int,            ir_cmd_check_array_size, .nop,
            .nop,                         ir_cmd_get_arr_addr, .load_tvalue,            .store_tvalue,
            ir_cmd_barrier_table_forward, .jump,
        };
        const trusted_reused_value = [_]snapshot_v1.IrCommand{
            .load_tag,                    .check_tag,          .nop,                    .load_double,
            ir_cmd_try_num_to_index,      .sub_int,            ir_cmd_check_array_size, .nop,
            .nop,                         ir_cmd_get_arr_addr, .nop,                    .store_tvalue,
            ir_cmd_barrier_table_forward, .jump,
        };
        const is_general_loaded = block.finish >= block.start + general.len - 1 and
            try self.commandRangeMatches(block.finish - @as(u32, @intCast(general.len - 1)), &general);
        const is_general_reused = !is_general_loaded and block.finish >= block.start + general_reused_value.len - 1 and
            try self.commandRangeMatches(block.finish - @as(u32, @intCast(general_reused_value.len - 1)), &general_reused_value);
        const is_trusted_loaded = !is_general_loaded and !is_general_reused and block.finish >= block.start + trusted.len - 1 and
            try self.commandRangeMatches(block.finish - @as(u32, @intCast(trusted.len - 1)), &trusted);
        const is_trusted_reused = !is_general_loaded and !is_general_reused and !is_trusted_loaded and
            block.finish >= block.start + trusted_reused_value.len - 1 and
            try self.commandRangeMatches(block.finish - @as(u32, @intCast(trusted_reused_value.len - 1)), &trusted_reused_value);
        const is_general = is_general_loaded or is_general_reused;
        const is_trusted = is_trusted_loaded or is_trusted_reused;
        const has_value_load = is_general_loaded or is_trusted_loaded;
        if (!is_general and !is_trusted)
            return null;
        const command_count = if (is_general) general.len else trusted.len;
        const start = block.finish - @as(u32, @intCast(command_count - 1));
        if (is_trusted and start < 6)
            return null;
        const key_load_id = start + (if (is_general) @as(u32, 2) else 0);
        const key_check_id = key_load_id + 1;
        const pointer_id = if (is_general) start + 4 else start - 6;
        const number_load_id = start + (if (is_general) @as(u32, 5) else 3);
        const index_id = number_load_id + 1;
        const zero_index_id = index_id + 1;
        const size_check_id = zero_index_id + 1;
        const address_id = start + (if (is_general) @as(u32, 11) else 9);
        const value_load_id = address_id + 1;
        const store_id = value_load_id + 1;
        const barrier_id = store_id + 1;

        const key_load = try self.instruction(key_load_id);
        const key_check = try self.instruction(key_check_id);
        const number_load = try self.instruction(number_load_id);
        const index = try self.instruction(index_id);
        const zero_index = try self.instruction(zero_index_id);
        const size_check = try self.instruction(size_check_id);
        const address = try self.instruction(address_id);
        const value_load = try self.instruction(value_load_id);
        const store = try self.instruction(store_id);
        const barrier = try self.instruction(barrier_id);
        const jump = try self.instruction(block.finish);
        if (key_load.operand_count != 1 or key_check.operand_count != 3 or number_load.operand_count != 1 or
            index.operand_count != 2 or zero_index.operand_count != 2 or size_check.operand_count != 3 or
            address.operand_count != 2 or value_load.operand_count != (if (has_value_load) @as(u32, 1) else 0) or
            store.operand_count != 2 or
            barrier.operand_count != 3 or jump.operand_count != 1)
            return null;
        const key = try self.vmRegisterIndex(try self.operand(key_load, 0));
        const checked_key = try self.operand(key_check, 0);
        const number_tag = try self.operand(key_check, 1);
        const fallback_target = try self.operand(key_check, 2);
        if (checked_key.kind != .instruction or checked_key.value != key_load_id or number_tag.kind != .constant or
            (try self.constant(number_tag.value)).tagValue() != lua_tag_number or fallback_target.kind != .block)
            return null;
        const loaded_key = try self.operand(number_load, 0);
        const indexed = try self.operand(index, 0);
        const index_fallback = try self.operand(index, 1);
        const zero_source = try self.operand(zero_index, 0);
        const size_pointer = try self.operand(size_check, 0);
        const size_index = try self.operand(size_check, 1);
        const size_fallback = try self.operand(size_check, 2);
        const address_pointer = try self.operand(address, 0);
        const address_index = try self.operand(address, 1);
        const store_address = try self.operand(store, 0);
        const store_value = try self.operand(store, 1);
        const barrier_pointer = try self.operand(barrier, 0);
        const barrier_source = try self.operand(barrier, 1);
        const barrier_tag = try self.operand(barrier, 2);
        const fast_target = try self.operand(jump, 0);
        if (loaded_key.kind != .vm_reg or loaded_key.value != key or indexed.kind != .instruction or indexed.value != number_load_id or
            index_fallback.kind != .block or index_fallback.value != fallback_target.value or
            zero_source.kind != .instruction or zero_source.value != index_id or
            !try self.intOperandEquals(try self.operand(zero_index, 1), 1) or
            size_pointer.kind != .instruction or size_pointer.value != pointer_id or
            size_index.kind != .instruction or size_index.value != zero_index_id or
            size_fallback.kind != .block or size_fallback.value != fallback_target.value or
            address_pointer.kind != .instruction or address_pointer.value != pointer_id or
            address_index.kind != .instruction or address_index.value != zero_index_id or
            store_address.kind != .instruction or store_address.value != address_id or store_value.kind != .instruction or
            barrier_pointer.kind != .instruction or barrier_pointer.value != pointer_id or
            barrier_source.kind != .vm_reg or barrier_tag.kind != .undef or
            fast_target.kind != .block)
            return null;

        const source = try self.vmRegisterIndex(barrier_source);
        if (has_value_load) {
            const loaded_source = try self.operand(value_load, 0);
            if (loaded_source.kind != .vm_reg or loaded_source.value != source or store_value.value != value_load_id)
                return null;
        } else {
            // Upstream can reuse a TValue SSA producer that it has just published to the source VM
            // register, leaving a NOP where the ordinary cluster reloads that register.  The fused
            // lowering consumes the VM register through the semantic helper, so admit this only when
            // the immediately preceding STORE_TVALUE proves both identities and the reused value is
            // a real TValue producer owned by the already executed prefix.
            if (start == block.start or store_value.value >= start)
                return null;
            const publication = try self.instruction(start - 1);
            if (publication.command != .store_tvalue or publication.operand_count != 2)
                return null;
            const published_register = try self.operand(publication, 0);
            const published_value = try self.operand(publication, 1);
            if (published_register.kind != .vm_reg or published_register.value != source or
                published_value.kind != .instruction or published_value.value != store_value.value)
                return null;
        }

        var table: u32 = undefined;
        if (is_general) {
            const table_load = try self.instruction(start);
            const table_check = try self.instruction(start + 1);
            const pointer = try self.instruction(pointer_id);
            if (table_load.operand_count != 1 or table_check.operand_count != 3 or pointer.operand_count != 1)
                return null;
            table = try self.vmRegisterIndex(try self.operand(table_load, 0));
            const checked_table = try self.operand(table_check, 0);
            const table_tag = try self.operand(table_check, 1);
            const table_failure = try self.operand(table_check, 2);
            const pointer_table = try self.operand(pointer, 0);
            const canonical_table_failure = table_failure.kind == .vm_exit or
                (table_failure.kind == .block and table_failure.value == fallback_target.value);
            if (checked_table.kind != .instruction or checked_table.value != start or table_tag.kind != .constant or
                (try self.constant(table_tag.value)).tagValue() != lua_tag_table or !canonical_table_failure or
                pointer_table.kind != .vm_reg or pointer_table.value != table)
                return null;
            const metatable = try self.instruction(start + 9);
            const readonly = try self.instruction(start + 10);
            if (metatable.operand_count != 2 or readonly.operand_count != 2 or
                (try self.operand(metatable, 0)).kind != .instruction or (try self.operand(metatable, 0)).value != pointer_id or
                (try self.operand(metatable, 1)).kind != .block or (try self.operand(metatable, 1)).value != fallback_target.value or
                (try self.operand(readonly, 0)).kind != .instruction or (try self.operand(readonly, 0)).value != pointer_id or
                (try self.operand(readonly, 1)).kind != .block or (try self.operand(readonly, 1)).value != fallback_target.value)
                return null;
        } else {
            const allocation = (try self.tableAllocationPatternContaining(pointer_id)) orelse return null;
            if (allocation.start != pointer_id or allocation.destination >= self.proto.max_stack_size)
                return null;
            table = allocation.destination;
            const pointer_nop = try self.instruction(start + 2);
            const metatable_nop = try self.instruction(start + 7);
            const readonly_nop = try self.instruction(start + 8);
            if (pointer_nop.operand_count != 0 or metatable_nop.operand_count != 0 or readonly_nop.operand_count != 0)
                return null;
        }
        const semantic_key = try self.operand(try self.instruction((try self.snapshot.irBlock(self.function, fallback_target.value)).start + 1), 2);
        const fallback = (try self.genericTableFallback(fallback_target.value, .set, source, table, semantic_key)) orelse return null;
        return .{
            .operation = .set,
            .start = start,
            .table = table,
            .key = try self.valueOperandEncoding(semantic_key),
            .register_key = key,
            .immediate_number_key = null,
            .value = source,
            .marker = fallback.marker,
            .fallback = fallback_target.value,
            .fast_target = try self.requireCompiledTarget(fast_target),
            .rejoin = fallback.rejoin,
        };
    }

    fn genericTableGetPattern(self: Context, block: snapshot_v1.IrBlock) Error!?GenericTablePattern {
        const commands = [_]snapshot_v1.IrCommand{
            .load_tag,               .check_tag, .load_tag,               .check_tag,                .load_pointer,       .load_double,
            ir_cmd_try_num_to_index, .sub_int,   ir_cmd_check_array_size, ir_cmd_check_no_metatable, ir_cmd_get_arr_addr, .load_tvalue,
            .store_tvalue,           .jump,
        };
        if (!block.kind.isCompilable() or block.isEmpty() or block.finish < block.start + commands.len - 1)
            return null;
        const start = block.finish - @as(u32, @intCast(commands.len - 1));
        if (!try self.commandRangeMatches(start, &commands))
            return null;
        const table = try self.vmRegisterIndex(try self.operand(try self.instruction(start), 0));
        const table_check = try self.instruction(start + 1);
        const key = try self.vmRegisterIndex(try self.operand(try self.instruction(start + 2), 0));
        const key_check = try self.instruction(start + 3);
        const pointer = try self.instruction(start + 4);
        const number_load = try self.instruction(start + 5);
        const index = try self.instruction(start + 6);
        const zero_index = try self.instruction(start + 7);
        const size_check = try self.instruction(start + 8);
        const metatable = try self.instruction(start + 9);
        const address = try self.instruction(start + 10);
        const load = try self.instruction(start + 11);
        const store = try self.instruction(start + 12);
        const jump = try self.instruction(block.finish);
        if (table_check.operand_count != 3 or key_check.operand_count != 3 or pointer.operand_count != 1 or
            number_load.operand_count != 1 or index.operand_count != 2 or zero_index.operand_count != 2 or
            size_check.operand_count != 3 or metatable.operand_count != 2 or address.operand_count != 2 or
            load.operand_count != 1 or store.operand_count != 2 or jump.operand_count != 1)
            return null;
        const table_fallback = try self.operand(table_check, 2);
        const key_fallback = try self.operand(key_check, 2);
        if ((try self.operand(table_check, 0)).kind != .instruction or (try self.operand(table_check, 0)).value != start or
            (try self.operand(table_check, 1)).kind != .constant or
            (try self.constant((try self.operand(table_check, 1)).value)).tagValue() != lua_tag_table or
            table_fallback.kind != .block or
            (try self.operand(key_check, 0)).kind != .instruction or (try self.operand(key_check, 0)).value != start + 2 or
            (try self.operand(key_check, 1)).kind != .constant or
            (try self.constant((try self.operand(key_check, 1)).value)).tagValue() != lua_tag_number or
            key_fallback.kind != .block or key_fallback.value != table_fallback.value or
            (try self.operand(pointer, 0)).kind != .vm_reg or (try self.operand(pointer, 0)).value != table or
            (try self.operand(number_load, 0)).kind != .vm_reg or (try self.operand(number_load, 0)).value != key or
            (try self.operand(index, 0)).kind != .instruction or (try self.operand(index, 0)).value != start + 5 or
            (try self.operand(index, 1)).kind != .block or (try self.operand(index, 1)).value != table_fallback.value or
            (try self.operand(zero_index, 0)).kind != .instruction or (try self.operand(zero_index, 0)).value != start + 6 or
            !try self.intOperandEquals(try self.operand(zero_index, 1), 1) or
            (try self.operand(size_check, 0)).kind != .instruction or (try self.operand(size_check, 0)).value != start + 4 or
            (try self.operand(size_check, 1)).kind != .instruction or (try self.operand(size_check, 1)).value != start + 7 or
            (try self.operand(size_check, 2)).kind != .block or (try self.operand(size_check, 2)).value != table_fallback.value or
            (try self.operand(metatable, 0)).kind != .instruction or (try self.operand(metatable, 0)).value != start + 4 or
            (try self.operand(metatable, 1)).kind != .block or (try self.operand(metatable, 1)).value != table_fallback.value or
            (try self.operand(address, 0)).kind != .instruction or (try self.operand(address, 0)).value != start + 4 or
            (try self.operand(address, 1)).kind != .instruction or (try self.operand(address, 1)).value != start + 7 or
            (try self.operand(load, 0)).kind != .instruction or (try self.operand(load, 0)).value != start + 10)
            return null;
        const destination = try self.vmRegisterIndex(try self.operand(store, 0));
        const stored = try self.operand(store, 1);
        const fast_target = try self.operand(jump, 0);
        if (stored.kind != .instruction or stored.value != start + 11 or fast_target.kind != .block)
            return null;
        const semantic_key = try self.operand(try self.instruction((try self.snapshot.irBlock(self.function, table_fallback.value)).start + 1), 2);
        const fallback = (try self.genericTableFallback(table_fallback.value, .get, destination, table, semantic_key)) orelse return null;
        return .{
            .operation = .get,
            .start = start,
            .table = table,
            .key = try self.valueOperandEncoding(semantic_key),
            .register_key = key,
            .immediate_number_key = null,
            .value = destination,
            .marker = fallback.marker,
            .fallback = table_fallback.value,
            .fast_target = try self.requireCompiledTarget(fast_target),
            .rejoin = fallback.rejoin,
        };
    }

    fn constantGenericTableGetPattern(self: Context, block: snapshot_v1.IrBlock) Error!?GenericTablePattern {
        const command_count: u32 = 9;
        if (block.isEmpty() or block.finish < block.start + command_count - 1)
            return null;
        const candidate_start = block.finish - (command_count - 1);
        const tag_check = try self.instruction(candidate_start + 1);
        if (tag_check.operand_count != 3)
            return null;
        const fallback_operand = try self.operand(tag_check, 2);
        if (fallback_operand.kind != .block or fallback_operand.value >= self.function.block_count)
            return null;
        const fallback_block = try self.snapshot.irBlock(self.function, fallback_operand.value);
        if (fallback_block.kind != .fallback or fallback_block.isEmpty() or fallback_block.finish != fallback_block.start + 2)
            return null;
        const semantic = try self.instruction(fallback_block.start + 1);
        if (semantic.command != ir_cmd_get_table or semantic.operand_count != 3)
            return null;
        const semantic_key = try self.operand(semantic, 2);
        if (semantic_key.kind != .constant)
            return null;
        const direct = (try self.arrayGetPattern(block)) orelse return null;
        const key_constant = try self.constant(semantic_key.value);
        const number: f64 = switch (key_constant.kind) {
            .int => @floatFromInt(key_constant.intValue() orelse return null),
            .uint => @floatFromInt(key_constant.uintValue() orelse return null),
            .int64 => @floatFromInt(key_constant.int64Value() orelse return null),
            .double => key_constant.doubleValue() orelse return null,
            .tag, .import => return null,
        };
        if (!std.math.isFinite(number) or number < 1 or number > std.math.maxInt(u32) or @trunc(number) != number)
            return null;
        const one_based_index: u32 = @intFromFloat(number);
        if (one_based_index != direct.index)
            return null;
        const fallback = (try self.genericTableFallback(
            fallback_operand.value,
            .get,
            direct.destination,
            direct.table,
            semantic_key,
        )) orelse return null;
        return .{
            .operation = .get,
            .start = direct.start,
            .table = direct.table,
            // Materialize the immutable IR immediate in the result register before calling the
            // existing TValue-key semantic helper. Destination/key overlap is valid for
            // luaV_gettable, which consumes the key before publishing its result.
            .key = direct.destination,
            .register_key = null,
            .immediate_number_key = number,
            .value = direct.destination,
            .marker = fallback.marker,
            .fallback = fallback_operand.value,
            .fast_target = direct.rejoin,
            .rejoin = fallback.rejoin,
        };
    }

    fn inlineConstantTableGetPatternAt(self: Context, start: u32) Error!?InlineConstantTableGetPattern {
        const commands = [_]snapshot_v1.IrCommand{
            .load_tag,
            .check_tag,
            .load_pointer,
            ir_cmd_check_array_size,
            ir_cmd_check_no_metatable,
            ir_cmd_get_arr_addr,
            .load_tvalue,
            .store_tvalue,
        };
        if (!try self.commandRangeMatches(start, &commands))
            return null;
        const finish = start + @as(u32, @intCast(commands.len - 1));
        self.requireSingleCompilableBlockRange(start, finish) catch return null;

        const table_load = try self.instruction(start);
        const tag_check = try self.instruction(start + 1);
        const pointer = try self.instruction(start + 2);
        const size_check = try self.instruction(start + 3);
        const metatable_check = try self.instruction(start + 4);
        const address = try self.instruction(start + 5);
        const load = try self.instruction(start + 6);
        const store = try self.instruction(finish);
        if (table_load.operand_count != 1 or tag_check.operand_count != 3 or pointer.operand_count != 1 or
            size_check.operand_count != 3 or metatable_check.operand_count != 2 or address.operand_count != 2 or
            load.operand_count != 2 or store.operand_count != 2)
            return null;

        const table = self.vmRegisterIndex(try self.operand(table_load, 0)) catch return null;
        const checked = try self.operand(tag_check, 0);
        const table_tag = try self.operand(tag_check, 1);
        const fallback_operand = try self.operand(tag_check, 2);
        if (checked.kind != .instruction or checked.value != start or table_tag.kind != .constant or
            (try self.constant(table_tag.value)).tagValue() != lua_tag_table or
            fallback_operand.kind != .block or fallback_operand.value >= self.function.block_count)
            return null;
        if ((try self.operand(pointer, 0)).kind != .vm_reg or (try self.operand(pointer, 0)).value != table)
            return null;

        const zero_based = self.intConstant(try self.operand(size_check, 1)) catch return null;
        if (zero_based < 0)
            return null;
        const index: u32 = std.math.add(u32, @intCast(zero_based), 1) catch return null;
        if ((try self.operand(size_check, 0)).kind != .instruction or
            (try self.operand(size_check, 0)).value != start + 2 or
            (try self.operand(size_check, 2)).kind != .block or
            (try self.operand(size_check, 2)).value != fallback_operand.value or
            (try self.operand(metatable_check, 0)).kind != .instruction or
            (try self.operand(metatable_check, 0)).value != start + 2 or
            (try self.operand(metatable_check, 1)).kind != .block or
            (try self.operand(metatable_check, 1)).value != fallback_operand.value)
            return null;

        const address_offset = self.nonnegativeConstant(try self.operand(address, 1)) catch return null;
        const load_offset = self.nonnegativeConstant(try self.operand(load, 1)) catch return null;
        const expected_offset = std.math.mul(u32, @intCast(zero_based), tvalue_size) catch return null;
        if ((try self.operand(address, 0)).kind != .instruction or
            (try self.operand(address, 0)).value != start + 2 or address_offset != 0 or
            (try self.operand(load, 0)).kind != .instruction or
            (try self.operand(load, 0)).value != start + 5 or load_offset != expected_offset)
            return null;
        const destination = self.vmRegisterIndex(try self.operand(store, 0)) catch return null;
        if ((try self.operand(store, 1)).kind != .instruction or (try self.operand(store, 1)).value != start + 6)
            return null;

        const fallback_block = try self.snapshot.irBlock(self.function, fallback_operand.value);
        if (fallback_block.kind != .fallback or fallback_block.isEmpty() or fallback_block.finish != fallback_block.start + 2)
            return null;
        const semantic = try self.instruction(fallback_block.start + 1);
        if (semantic.command != ir_cmd_get_table or semantic.operand_count != 3)
            return null;
        const semantic_key = try self.operand(semantic, 2);
        if (semantic_key.kind != .constant)
            return null;
        const key_constant = try self.constant(semantic_key.value);
        const number: f64 = switch (key_constant.kind) {
            .int => @floatFromInt(key_constant.intValue() orelse return null),
            .uint => @floatFromInt(key_constant.uintValue() orelse return null),
            .int64 => @floatFromInt(key_constant.int64Value() orelse return null),
            .double => key_constant.doubleValue() orelse return null,
            .tag, .import => return null,
        };
        if (!std.math.isFinite(number) or number != @as(f64, @floatFromInt(index)))
            return null;
        const fallback = (try self.genericTableFallback(
            fallback_operand.value,
            .get,
            destination,
            table,
            semantic_key,
        )) orelse return null;
        return .{
            .pattern = .{
                .operation = .get,
                .start = start,
                .table = table,
                .key = destination,
                .register_key = null,
                .immediate_number_key = number,
                .value = destination,
                .marker = fallback.marker,
                .fallback = fallback_operand.value,
                .fast_target = 0,
                .rejoin = fallback.rejoin,
            },
            .finish = finish,
        };
    }

    fn inlineConstantTableGetPatternContaining(self: Context, instruction_id: u32) Error!?InlineConstantTableGetPattern {
        var distance: u32 = 0;
        while (distance < 8 and distance <= instruction_id) : (distance += 1) {
            const start = instruction_id - distance;
            if ((try self.instruction(start)).command == .load_tag)
                if (try self.inlineConstantTableGetPatternAt(start)) |pattern|
                    if (instruction_id <= pattern.finish) return pattern;
        }
        return null;
    }

    fn genericTablePattern(self: Context, block: snapshot_v1.IrBlock) Error!?GenericTablePattern {
        if (try self.genericTableSetPattern(block)) |pattern|
            return pattern;
        if (try self.genericTableGetPattern(block)) |pattern|
            return pattern;
        return self.constantGenericTableGetPattern(block);
    }

    fn arraySetPattern(self: Context, block: snapshot_v1.IrBlock) Error!?ArrayOperationPattern {
        const commands = [_]snapshot_v1.IrCommand{
            .load_tag,             .check_tag,          .load_pointer, ir_cmd_check_array_size, ir_cmd_check_no_metatable,
            ir_cmd_check_readonly, ir_cmd_get_arr_addr, .load_tvalue,  .store_tvalue,           ir_cmd_barrier_table_forward,
            .jump,
        };
        if (block.isEmpty() or block.finish - block.start != commands.len - 1 or
            !try self.commandRangeMatches(block.start, &commands))
            return null;
        const table_operand = try self.operand(try self.instruction(block.start), 0);
        const tag_check = try self.instruction(block.start + 1);
        const table_pointer = try self.instruction(block.start + 2);
        const size_check = try self.instruction(block.start + 3);
        const metatable_check = try self.instruction(block.start + 4);
        const readonly_check = try self.instruction(block.start + 5);
        const array_address = try self.instruction(block.start + 6);
        const store = try self.instruction(block.start + 8);
        const barrier = try self.instruction(block.start + 9);
        const source_operand = try self.operand(try self.instruction(block.start + 7), 0);
        const jump = try self.instruction(block.finish);
        const target = try self.operand(jump, 0);
        if (table_operand.kind != .vm_reg or source_operand.kind != .vm_reg or target.kind != .block)
            return null;
        const index = try self.intConstant(try self.operand(size_check, 1));
        if (index < 0)
            return null;
        const pointer_source = try self.operand(table_pointer, 0);
        const checked_tag = try self.operand(tag_check, 0);
        const tag_value = try self.operand(tag_check, 1);
        const tag_failure = try self.operand(tag_check, 2);
        const size_pointer = try self.operand(size_check, 0);
        const fallback = try self.operand(size_check, 2);
        const meta_pointer = try self.operand(metatable_check, 0);
        const meta_fallback = try self.operand(metatable_check, 1);
        const readonly_pointer = try self.operand(readonly_check, 0);
        const readonly_fallback = try self.operand(readonly_check, 1);
        const address_pointer = try self.operand(array_address, 0);
        const address_offset = try self.nonnegativeConstant(try self.operand(array_address, 1));
        const store_address = try self.operand(store, 0);
        const store_value = try self.operand(store, 1);
        const store_offset = try self.nonnegativeConstant(try self.operand(store, 2));
        const barrier_pointer = try self.operand(barrier, 0);
        const barrier_source = try self.operand(barrier, 1);
        const barrier_tag = try self.operand(barrier, 2);
        if (checked_tag.kind != .instruction or checked_tag.value != block.start or
            pointer_source.kind != .vm_reg or pointer_source.value != table_operand.value or
            tag_value.kind != .constant or (try self.constant(tag_value.value)).tagValue() != lua_tag_table or
            tag_failure.kind != .vm_exit or
            size_pointer.kind != .instruction or size_pointer.value != block.start + 2 or fallback.kind != .block or
            meta_pointer.kind != .instruction or meta_pointer.value != block.start + 2 or
            meta_fallback.kind != .block or meta_fallback.value != fallback.value or
            readonly_pointer.kind != .instruction or readonly_pointer.value != block.start + 2 or
            readonly_fallback.kind != .block or readonly_fallback.value != fallback.value or
            address_pointer.kind != .instruction or address_pointer.value != block.start + 2 or address_offset != 0 or
            store_address.kind != .instruction or store_address.value != block.start + 6 or
            store_value.kind != .instruction or store_value.value != block.start + 7 or
            store_offset != @as(u32, @intCast(index)) * tvalue_size or
            barrier_pointer.kind != .instruction or barrier_pointer.value != block.start + 2 or
            barrier_source.kind != .vm_reg or barrier_source.value != source_operand.value or barrier_tag.kind != .undef)
            return null;
        return .{
            .start = block.start,
            .table = try self.vmRegisterIndex(table_operand),
            .source = try self.vmRegisterIndex(source_operand),
            .index = std.math.add(u32, @intCast(index), 1) catch return null,
            .rejoin = try self.requireDispatchTarget(target),
        };
    }

    fn arrayGetPattern(self: Context, block: snapshot_v1.IrBlock) Error!?ArrayOperationPattern {
        const commands = [_]snapshot_v1.IrCommand{
            .load_tag,           .check_tag,   .load_pointer, ir_cmd_check_array_size, ir_cmd_check_no_metatable,
            ir_cmd_get_arr_addr, .load_tvalue, .store_tvalue, .jump,
        };
        if (block.isEmpty() or block.finish < block.start + commands.len - 1)
            return null;
        const start = block.finish - @as(u32, @intCast(commands.len - 1));
        if (!try self.commandRangeMatches(start, &commands))
            return null;
        const table_operand = try self.operand(try self.instruction(start), 0);
        const tag_check = try self.instruction(start + 1);
        const table_pointer = try self.instruction(start + 2);
        const size_check = try self.instruction(start + 3);
        const metatable_check = try self.instruction(start + 4);
        const array_address = try self.instruction(start + 5);
        const load_value = try self.instruction(start + 6);
        const store = try self.instruction(start + 7);
        const destination = try self.operand(store, 0);
        const target = try self.operand(try self.instruction(block.finish), 0);
        if (table_operand.kind != .vm_reg or destination.kind != .vm_reg or target.kind != .block)
            return null;
        const index = try self.intConstant(try self.operand(size_check, 1));
        if (index < 0)
            return null;
        const pointer_source = try self.operand(table_pointer, 0);
        const checked_tag = try self.operand(tag_check, 0);
        const tag_value = try self.operand(tag_check, 1);
        const tag_fallback = try self.operand(tag_check, 2);
        const size_pointer = try self.operand(size_check, 0);
        const fallback = try self.operand(size_check, 2);
        const meta_pointer = try self.operand(metatable_check, 0);
        const meta_fallback = try self.operand(metatable_check, 1);
        const address_pointer = try self.operand(array_address, 0);
        const address_offset = try self.nonnegativeConstant(try self.operand(array_address, 1));
        const load_address = try self.operand(load_value, 0);
        const load_offset = try self.nonnegativeConstant(try self.operand(load_value, 1));
        const stored_value = try self.operand(store, 1);
        if (checked_tag.kind != .instruction or checked_tag.value != start or
            pointer_source.kind != .vm_reg or pointer_source.value != table_operand.value or
            tag_value.kind != .constant or (try self.constant(tag_value.value)).tagValue() != lua_tag_table or
            tag_fallback.kind != .block or size_pointer.kind != .instruction or size_pointer.value != start + 2 or
            fallback.kind != .block or fallback.value != tag_fallback.value or
            meta_pointer.kind != .instruction or meta_pointer.value != start + 2 or
            meta_fallback.kind != .block or meta_fallback.value != fallback.value or
            address_pointer.kind != .instruction or address_pointer.value != start + 2 or address_offset != 0 or
            load_address.kind != .instruction or load_address.value != start + 5 or
            load_offset != @as(u32, @intCast(index)) * tvalue_size or
            stored_value.kind != .instruction or stored_value.value != start + 6)
            return null;
        return .{
            .start = start,
            .destination = try self.vmRegisterIndex(destination),
            .table = try self.vmRegisterIndex(table_operand),
            .index = std.math.add(u32, @intCast(index), 1) catch return null,
            .rejoin = try self.requireDispatchTarget(target),
        };
    }

    fn trustedArrayGetPattern(self: Context, block: snapshot_v1.IrBlock) Error!?ArrayOperationPattern {
        if (block.isEmpty() or block.finish < block.start + 2)
            return null;
        const start = block.finish - 2;
        const load = try self.instruction(start);
        const store = try self.instruction(start + 1);
        const jump = try self.instruction(start + 2);
        if (load.command != .load_tvalue or load.operand_count != 2 or
            store.command != .store_tvalue or store.operand_count != 2 or jump.command != .jump)
            return null;
        const address_operand = try self.operand(load, 0);
        const destination = try self.operand(store, 0);
        const stored = try self.operand(store, 1);
        const target = try self.operand(jump, 0);
        if (address_operand.kind != .instruction or destination.kind != .vm_reg or
            stored.kind != .instruction or stored.value != start or target.kind != .block)
            return null;
        const address = try self.instruction(address_operand.value);
        if (address.command != ir_cmd_get_arr_addr or address.operand_count != 2)
            return null;
        const table_pointer_operand = try self.operand(address, 0);
        if (table_pointer_operand.kind != .instruction)
            return null;
        const table_pointer = try self.instruction(table_pointer_operand.value);
        if (table_pointer.command != .load_pointer or table_pointer.operand_count != 1)
            return null;
        const table = try self.operand(table_pointer, 0);
        if (table.kind != .vm_reg)
            return null;
        const load_offset = self.nonnegativeConstant(try self.operand(load, 1)) catch return null;
        const address_offset = self.nonnegativeConstant(try self.operand(address, 1)) catch return null;
        if (load_offset % tvalue_size != 0 or address_offset % tvalue_size != 0)
            return null;
        const zero_based = std.math.add(u32, address_offset / tvalue_size, load_offset / tvalue_size) catch return null;
        return .{
            .start = start,
            .destination = try self.vmRegisterIndex(destination),
            .table = try self.vmRegisterIndex(table),
            .index = std.math.add(u32, zero_based, 1) catch return null,
            .rejoin = try self.requireDispatchTarget(target),
        };
    }

    fn trustedArrayAddress(self: Context, instruction_id: u32) Error!bool {
        const address = try self.instruction(instruction_id);
        if (address.command != ir_cmd_get_arr_addr or address.operand_count != 2)
            return false;
        const table_pointer_operand = try self.operand(address, 0);
        _ = try self.nonnegativeConstant(try self.operand(address, 1));
        if (table_pointer_operand.kind != .instruction)
            return false;
        const table_pointer = try self.instruction(table_pointer_operand.value);
        if (table_pointer.command != .load_pointer or table_pointer.operand_count != 1)
            return false;
        const table = try self.operand(table_pointer, 0);
        if (table.kind != .vm_reg)
            return false;
        return true;
    }

    fn inlineArrayGetPatternAt(self: Context, start: u32) Error!?InlineArrayGetPattern {
        const commands = [_]snapshot_v1.IrCommand{ ir_cmd_get_arr_addr, .load_tvalue, .store_tvalue };
        if (!try self.commandRangeMatches(start, &commands))
            return null;
        const finish = start + 2;
        self.requireSingleCompilableBlockRange(start, finish) catch return null;
        const address = try self.instruction(start);
        const load = try self.instruction(start + 1);
        const store = try self.instruction(finish);
        if (address.operand_count != 2 or load.operand_count != 2 or store.operand_count != 2)
            return null;
        const pointer_operand = try self.operand(address, 0);
        if (pointer_operand.kind != .instruction)
            return null;
        const pointer = try self.instruction(pointer_operand.value);
        if (pointer.command != .load_pointer or pointer.operand_count != 1)
            return null;
        const table = self.vmRegisterIndex(try self.operand(pointer, 0)) catch return null;
        if ((try self.operand(load, 0)).kind != .instruction or (try self.operand(load, 0)).value != start or
            (try self.operand(store, 1)).kind != .instruction or (try self.operand(store, 1)).value != start + 1)
            return null;
        const address_offset = self.nonnegativeConstant(try self.operand(address, 1)) catch return null;
        const load_offset = self.nonnegativeConstant(try self.operand(load, 1)) catch return null;
        if (address_offset % tvalue_size != 0 or load_offset % tvalue_size != 0)
            return null;
        const zero_based = std.math.add(u32, address_offset / tvalue_size, load_offset / tvalue_size) catch return null;
        return .{
            .start = start,
            .finish = finish,
            .destination = self.vmRegisterIndex(try self.operand(store, 0)) catch return null,
            .table = table,
            .index = std.math.add(u32, zero_based, 1) catch return null,
        };
    }

    fn inlineArrayGetPatternContaining(self: Context, instruction_id: u32) Error!?InlineArrayGetPattern {
        var distance: u32 = 0;
        while (distance < 3 and distance <= instruction_id) : (distance += 1) {
            const start = instruction_id - distance;
            if (try self.inlineArrayGetPatternAt(start)) |pattern|
                if (instruction_id <= pattern.finish) return pattern;
        }
        return null;
    }

    fn emitInlineArrayGet(self: Context, pattern: InlineArrayGetPattern) Error!void {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.destination));
        try self.body.i32Const(self.allocator, @intCast(pattern.table));
        try self.body.i32Const(self.allocator, @intCast(pattern.index));
        try self.body.call(self.allocator, self.array_get orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
    }

    fn tableLenPattern(self: Context, block: snapshot_v1.IrBlock) Error!?ArrayOperationPattern {
        const commands = [_]snapshot_v1.IrCommand{
            .load_tag,   .check_tag,    .load_pointer, ir_cmd_check_no_metatable, ir_cmd_table_len,
            .int_to_num, .store_double, .store_tag,    .jump,
        };
        if (block.isEmpty() or block.finish < block.start + commands.len - 1)
            return null;
        const start = block.finish - @as(u32, @intCast(commands.len - 1));
        if (!try self.commandRangeMatches(start, &commands))
            return null;
        const table_operand = try self.operand(try self.instruction(start), 0);
        const tag_check = try self.instruction(start + 1);
        const table_pointer = try self.instruction(start + 2);
        const metatable_check = try self.instruction(start + 3);
        const length = try self.instruction(start + 4);
        const convert = try self.instruction(start + 5);
        const store = try self.instruction(start + 6);
        const store_tag = try self.instruction(start + 7);
        const destination = try self.operand(store, 0);
        const target = try self.operand(try self.instruction(block.finish), 0);
        if (table_operand.kind != .vm_reg or destination.kind != .vm_reg or target.kind != .block)
            return null;
        const pointer_source = try self.operand(table_pointer, 0);
        const checked_tag = try self.operand(tag_check, 0);
        const tag_value = try self.operand(tag_check, 1);
        const tag_fallback = try self.operand(tag_check, 2);
        const meta_pointer = try self.operand(metatable_check, 0);
        const meta_fallback = try self.operand(metatable_check, 1);
        const length_pointer = try self.operand(length, 0);
        const converted_length = try self.operand(convert, 0);
        const stored_length = try self.operand(store, 1);
        const tag_destination = try self.operand(store_tag, 0);
        const result_tag = try self.operand(store_tag, 1);
        if (checked_tag.kind != .instruction or checked_tag.value != start or
            pointer_source.kind != .vm_reg or pointer_source.value != table_operand.value or
            tag_value.kind != .constant or (try self.constant(tag_value.value)).tagValue() != lua_tag_table or
            tag_fallback.kind != .block or meta_pointer.kind != .instruction or meta_pointer.value != start + 2 or
            meta_fallback.kind != .block or meta_fallback.value != tag_fallback.value or
            length_pointer.kind != .instruction or length_pointer.value != start + 2 or
            converted_length.kind != .instruction or converted_length.value != start + 4 or
            stored_length.kind != .instruction or stored_length.value != start + 5 or
            tag_destination.kind != .vm_reg or tag_destination.value != destination.value or
            result_tag.kind != .constant or (try self.constant(result_tag.value)).tagValue() != lua_tag_number)
            return null;
        return .{
            .start = start,
            .destination = try self.vmRegisterIndex(destination),
            .table = try self.vmRegisterIndex(table_operand),
            .rejoin = try self.requireDispatchTarget(target),
        };
    }

    fn dynamicLengthPattern(self: Context, block: snapshot_v1.IrBlock) Error!?DynamicLengthPattern {
        const commands = [_]snapshot_v1.IrCommand{
            .load_tag,   .check_tag,    .load_pointer, ir_cmd_check_no_metatable, ir_cmd_table_len,
            .int_to_num, .store_double, .store_tag,    .jump,
        };
        if (block.isEmpty() or block.finish < block.start + commands.len - 1)
            return null;
        const start = block.finish - @as(u32, @intCast(commands.len - 1));
        if (!try self.commandRangeMatches(start, &commands))
            return null;

        const source = try self.vmRegisterIndex(try self.operand(try self.instruction(start), 0));
        const tag_check = try self.instruction(start + 1);
        const pointer = try self.instruction(start + 2);
        const metatable = try self.instruction(start + 3);
        const length = try self.instruction(start + 4);
        const convert = try self.instruction(start + 5);
        const store = try self.instruction(start + 6);
        const store_tag = try self.instruction(start + 7);
        const fast_jump = try self.instruction(start + 8);
        if ((try self.instruction(start)).operand_count != 1 or tag_check.operand_count != 3 or
            pointer.operand_count != 1 or metatable.operand_count != 2 or
            length.operand_count != 1 or convert.operand_count != 1 or store.operand_count != 2 or
            store_tag.operand_count != 2 or fast_jump.operand_count != 1)
            return null;
        const tag_input = try self.operand(tag_check, 0);
        const table_tag = try self.operand(tag_check, 1);
        const fallback_target = try self.operand(tag_check, 2);
        const pointer_input = try self.operand(pointer, 0);
        const metatable_pointer = try self.operand(metatable, 0);
        const metatable_fallback = try self.operand(metatable, 1);
        const length_pointer = try self.operand(length, 0);
        const converted = try self.operand(convert, 0);
        const destination = try self.vmRegisterIndex(try self.operand(store, 0));
        const stored = try self.operand(store, 1);
        const tag_destination = try self.operand(store_tag, 0);
        const result_tag = try self.operand(store_tag, 1);
        const fast_rejoin = try self.operand(fast_jump, 0);
        if (tag_input.kind != .instruction or tag_input.value != start or table_tag.kind != .constant or
            (try self.constant(table_tag.value)).tagValue() != lua_tag_table or fallback_target.kind != .block or
            pointer_input.kind != .vm_reg or pointer_input.value != source or
            metatable_pointer.kind != .instruction or metatable_pointer.value != start + 2 or
            metatable_fallback.kind != .block or metatable_fallback.value != fallback_target.value or
            length_pointer.kind != .instruction or length_pointer.value != start + 2 or
            converted.kind != .instruction or converted.value != start + 4 or
            stored.kind != .instruction or stored.value != start + 5 or
            tag_destination.kind != .vm_reg or tag_destination.value != destination or result_tag.kind != .constant or
            (try self.constant(result_tag.value)).tagValue() != lua_tag_number or fast_rejoin.kind != .block)
            return null;

        const fallback = try self.snapshot.irBlock(self.function, fallback_target.value);
        if (fallback.kind != .fallback or fallback.isEmpty() or fallback.finish - fallback.start != 2)
            return null;
        const marker = try self.instruction(fallback.start);
        const do_len = try self.instruction(fallback.start + 1);
        const fallback_jump = try self.instruction(fallback.start + 2);
        if (marker.command != .set_savedpc or do_len.command != ir_cmd_do_len or fallback_jump.command != .jump or
            marker.operand_count != 1 or do_len.operand_count != 2 or fallback_jump.operand_count != 1)
            return null;
        _ = try self.savedPc(marker);
        const fallback_destination = try self.vmRegisterIndex(try self.operand(do_len, 0));
        const fallback_source = try self.vmRegisterIndex(try self.operand(do_len, 1));
        const fallback_rejoin = try self.operand(fallback_jump, 0);
        if (fallback_destination != destination or fallback_source != source or fallback_rejoin.kind != .block or
            fallback_rejoin.value != fast_rejoin.value)
            return null;
        return .{
            .start = start,
            .destination = destination,
            .source = source,
            .fallback = fallback_target.value,
            .rejoin = try self.requireCompiledTarget(fast_rejoin),
            .marker = marker,
        };
    }

    fn powPattern(self: Context, block: snapshot_v1.IrBlock) Error!?PowPattern {
        const tagged_commands = [_]snapshot_v1.IrCommand{
            .load_tag,    .check_tag,         .load_tag,     .check_tag, .load_double,
            .load_double, ir_cmd_invoke_libm, .store_double, .store_tag, .jump,
        };
        const established_tag_commands = [_]snapshot_v1.IrCommand{
            .load_tag,    .check_tag,         .load_tag,     .check_tag, .load_double,
            .load_double, ir_cmd_invoke_libm, .store_double, .jump,
        };
        if (!block.kind.isCompilable() or block.isEmpty())
            return null;
        const has_store_tag = block.finish >= block.start + tagged_commands.len - 1 and
            try self.commandRangeMatches(block.finish - @as(u32, @intCast(tagged_commands.len - 1)), &tagged_commands);
        const uses_established_tag = !has_store_tag and block.finish >= block.start + established_tag_commands.len - 1 and
            try self.commandRangeMatches(
                block.finish - @as(u32, @intCast(established_tag_commands.len - 1)),
                &established_tag_commands,
            );
        if (!has_store_tag and !uses_established_tag)
            return null;
        const command_count = if (has_store_tag) tagged_commands.len else established_tag_commands.len;
        const start = block.finish - @as(u32, @intCast(command_count - 1));

        const lhs = try self.vmRegisterIndex(try self.operand(try self.instruction(start), 0));
        const lhs_check = try self.instruction(start + 1);
        const rhs = try self.vmRegisterIndex(try self.operand(try self.instruction(start + 2), 0));
        const rhs_check = try self.instruction(start + 3);
        const lhs_load = try self.instruction(start + 4);
        const rhs_load = try self.instruction(start + 5);
        const invoke = try self.instruction(start + 6);
        const store = try self.instruction(start + 7);
        const store_tag = if (has_store_tag) try self.instruction(start + 8) else null;
        const jump = try self.instruction(start + (if (has_store_tag) @as(u32, 9) else 8));
        if (lhs_check.operand_count != 3 or rhs_check.operand_count != 3 or lhs_load.operand_count != 1 or
            rhs_load.operand_count != 1 or invoke.operand_count != 3 or store.operand_count != 2 or
            (has_store_tag and store_tag.?.operand_count != 2) or jump.operand_count != 1)
            return null;
        const fallback = try self.operand(lhs_check, 2);
        const rhs_fallback = try self.operand(rhs_check, 2);
        const fast_rejoin = try self.operand(jump, 0);
        if ((try self.operand(lhs_check, 0)).kind != .instruction or (try self.operand(lhs_check, 0)).value != start or
            (try self.operand(lhs_check, 1)).kind != .constant or
            (try self.constant((try self.operand(lhs_check, 1)).value)).tagValue() != lua_tag_number or
            fallback.kind != .block or
            (try self.operand(rhs_check, 0)).kind != .instruction or (try self.operand(rhs_check, 0)).value != start + 2 or
            (try self.operand(rhs_check, 1)).kind != .constant or
            (try self.constant((try self.operand(rhs_check, 1)).value)).tagValue() != lua_tag_number or
            rhs_fallback.kind != .block or rhs_fallback.value != fallback.value or
            (try self.operand(lhs_load, 0)).kind != .vm_reg or (try self.operand(lhs_load, 0)).value != lhs or
            (try self.operand(rhs_load, 0)).kind != .vm_reg or (try self.operand(rhs_load, 0)).value != rhs or
            (try self.operand(invoke, 0)).kind != .constant or
            (try self.constant((try self.operand(invoke, 0)).value)).uintValue() != lbf_math_pow or
            (try self.operand(invoke, 1)).kind != .instruction or (try self.operand(invoke, 1)).value != start + 4 or
            (try self.operand(invoke, 2)).kind != .instruction or (try self.operand(invoke, 2)).value != start + 5 or
            (try self.operand(store, 0)).kind != .vm_reg or (try self.operand(store, 1)).kind != .instruction or
            (try self.operand(store, 1)).value != start + 6 or
            fast_rejoin.kind != .block)
            return null;
        const destination = try self.vmRegisterIndex(try self.operand(store, 0));
        if (has_store_tag) {
            if ((try self.operand(store_tag.?, 0)).kind != .vm_reg or
                (try self.operand(store_tag.?, 0)).value != destination or
                (try self.operand(store_tag.?, 1)).kind != .constant or
                (try self.constant((try self.operand(store_tag.?, 1)).value)).tagValue() != lua_tag_number)
                return null;
        } else if (destination != lhs) {
            // The pin omits STORE_TAG only when the successful lhs number guard already proves the
            // overwritten destination register carries the number tag on the direct path.
            return null;
        }

        const fallback_block = try self.snapshot.irBlock(self.function, fallback.value);
        if (!try self.supportsArithmeticFallback(fallback_block))
            return null;
        const marker = try self.instruction(fallback_block.start);
        const arithmetic_id = fallback_block.start + 1;
        const arithmetic = try self.instruction(arithmetic_id);
        const fallback_rejoin = try self.operand(try self.instruction(fallback_block.finish), 0);
        if ((try self.operand(arithmetic, 0)).kind != .vm_reg or (try self.operand(arithmetic, 0)).value != destination or
            (try self.operand(arithmetic, 1)).kind != .vm_reg or (try self.operand(arithmetic, 1)).value != lhs or
            (try self.operand(arithmetic, 2)).kind != .vm_reg or (try self.operand(arithmetic, 2)).value != rhs or
            (try self.operand(arithmetic, 3)).kind != .constant or
            (try self.constant((try self.operand(arithmetic, 3)).value)).intValue() != upstream_tm_pow or
            fallback_rejoin.kind != .block)
            return null;
        return .{
            .start = start,
            .destination = destination,
            .lhs = lhs,
            .rhs = rhs,
            .fast_target = try self.requireCompiledTarget(fast_rejoin),
            .rejoin = try self.requireCompiledTarget(fallback_rejoin),
            .marker = marker,
            .arithmetic_id = arithmetic_id,
        };
    }

    fn powValueRegister(self: Context, operand_value: snapshot_v1.IrOperand, before: u32) Error!?u32 {
        if (operand_value.kind != .instruction or operand_value.value >= before)
            return null;
        const producer = try self.instruction(operand_value.value);
        if (producer.command == .load_double and producer.operand_count == 1)
            return self.vmRegisterIndex(try self.operand(producer, 0)) catch return null;
        if (producer.command != ir_cmd_invoke_libm or producer.operand_count != 3 or
            operand_value.value + 1 >= before)
            return null;
        const bfid = try self.operand(producer, 0);
        const publication = try self.instruction(operand_value.value + 1);
        if (bfid.kind != .constant or (try self.constant(bfid.value)).uintValue() != lbf_math_pow or
            publication.command != .store_double or publication.operand_count != 2 or
            (try self.operand(publication, 1)).kind != .instruction or
            (try self.operand(publication, 1)).value != operand_value.value)
            return null;
        return self.vmRegisterIndex(try self.operand(publication, 0)) catch return null;
    }

    fn numericCommandMetamethod(command: snapshot_v1.IrCommand) ?i32 {
        return switch (command) {
            .add_num => 8,
            .sub_num => 9,
            .mul_num => 10,
            .div_num => 11,
            .idiv_num => 12,
            .mod_num => 13,
            else => null,
        };
    }

    fn constantArithmeticPattern(self: Context, block: snapshot_v1.IrBlock) Error!?ConstantArithmeticPattern {
        if (!block.kind.isCompilable() or block.isEmpty() or block.finish < block.start + 5)
            return null;
        const possible_tag = try self.instruction(block.finish - 1);
        const has_store_tag = possible_tag.command == .store_tag;
        if (has_store_tag and block.finish < block.start + 6)
            return null;
        const start = block.finish - (if (has_store_tag) @as(u32, 6) else 5);
        const load_tag = try self.instruction(start);
        const check_tag = try self.instruction(start + 1);
        const load = try self.instruction(start + 2);
        const arithmetic_id = start + 3;
        const arithmetic = try self.instruction(arithmetic_id);
        const store = try self.instruction(start + 4);
        const store_tag = if (has_store_tag) try self.instruction(start + 5) else null;
        const jump = try self.instruction(block.finish);
        const upstream_operation = numericCommandMetamethod(arithmetic.command) orelse return null;
        if (load_tag.command != .load_tag or check_tag.command != .check_tag or load.command != .load_double or
            store.command != .store_double or jump.command != .jump or load_tag.operand_count != 1 or
            check_tag.operand_count != 3 or load.operand_count != 1 or arithmetic.operand_count != 2 or
            store.operand_count != 2 or (has_store_tag and store_tag.?.operand_count != 2) or jump.operand_count != 1)
            return null;
        const source = try self.operand(load_tag, 0);
        const checked = try self.operand(check_tag, 0);
        const checked_tag = try self.operand(check_tag, 1);
        const fallback = try self.operand(check_tag, 2);
        const loaded_source = try self.operand(load, 0);
        const lhs_direct = try self.operand(arithmetic, 0);
        const rhs_direct = try self.operand(arithmetic, 1);
        const destination = try self.operand(store, 0);
        const stored = try self.operand(store, 1);
        const fast_target = try self.operand(jump, 0);
        if (source.kind != .vm_reg or source.value >= self.proto.max_stack_size or
            checked.kind != .instruction or checked.value != start or checked_tag.kind != .constant or
            (try self.constant(checked_tag.value)).tagValue() != lua_tag_number or fallback.kind != .block or
            loaded_source.kind != .vm_reg or loaded_source.value != source.value or destination.kind != .vm_reg or
            destination.value >= self.proto.max_stack_size or stored.kind != .instruction or stored.value != arithmetic_id or
            fast_target.kind != .block)
            return null;
        const register_is_lhs = lhs_direct.kind == .instruction and lhs_direct.value == start + 2 and rhs_direct.kind == .constant;
        const register_is_rhs = rhs_direct.kind == .instruction and rhs_direct.value == start + 2 and lhs_direct.kind == .constant;
        if (register_is_lhs == register_is_rhs)
            return null;
        if (has_store_tag) {
            if ((try self.operand(store_tag.?, 0)).kind != .vm_reg or
                (try self.operand(store_tag.?, 0)).value != destination.value or
                (try self.operand(store_tag.?, 1)).kind != .constant or
                (try self.constant((try self.operand(store_tag.?, 1)).value)).tagValue() != lua_tag_number)
                return null;
        } else if (destination.value != source.value) {
            return null;
        }

        const direct_constant = try self.constant((if (register_is_lhs) rhs_direct else lhs_direct).value);
        if (direct_constant.doubleValue() == null)
            return null;
        const fallback_block = try self.snapshot.irBlock(self.function, fallback.value);
        if (!try self.supportsArithmeticFallback(fallback_block))
            return null;
        const marker = try self.instruction(fallback_block.start);
        const fallback_arithmetic_id = fallback_block.start + 1;
        const fallback_arithmetic = try self.instruction(fallback_arithmetic_id);
        const fallback_destination = try self.operand(fallback_arithmetic, 0);
        const fallback_lhs = try self.operand(fallback_arithmetic, 1);
        const fallback_rhs = try self.operand(fallback_arithmetic, 2);
        const fallback_operation = try self.operand(fallback_arithmetic, 3);
        const fallback_rejoin = try self.operand(try self.instruction(fallback_block.finish), 0);
        const constant_operand = if (register_is_lhs) fallback_rhs else fallback_lhs;
        const register_operand = if (register_is_lhs) fallback_lhs else fallback_rhs;
        if (fallback_destination.kind != .vm_reg or fallback_destination.value != destination.value or
            register_operand.kind != .vm_reg or register_operand.value != source.value or
            constant_operand.kind != .vm_const or constant_operand.value >= self.proto.vm_constant_count or
            fallback_operation.kind != .constant or
            (try self.constant(fallback_operation.value)).intValue() != upstream_operation or
            fallback_rejoin.kind != .block)
            return null;
        const vm_constant = try self.snapshot.vmConstant(self.proto, constant_operand.value);
        if (vm_constant.kind != .number or vm_constant.bits0 != direct_constant.bits)
            return null;
        // Preserve the established numeric fast path when both arms already rejoin the same
        // canonical block. This fused helper exists only to replace optimizer-owned divergent
        // linearized copies, whose duplicated middle-of-block commands cannot be emitted safely.
        if (fast_target.value == fallback_rejoin.value)
            return null;
        return .{
            .start = start,
            .fast_target = try self.requireCompiledTarget(fast_target),
            .rejoin = try self.requireCompiledTarget(fallback_rejoin),
            .marker = marker,
            .arithmetic_id = fallback_arithmetic_id,
        };
    }

    fn integerPowExponent(self: Context, instruction_id: u32, load_id: u32, limit: u32) Error!?u32 {
        if (instruction_id == load_id)
            return 1;
        if (instruction_id <= load_id or instruction_id >= limit)
            return null;
        const instruction_value = try self.instruction(instruction_id);
        if (instruction_value.command != .mul_num or instruction_value.operand_count != 2)
            return null;
        const lhs = try self.operand(instruction_value, 0);
        const rhs = try self.operand(instruction_value, 1);
        if (lhs.kind != .instruction or rhs.kind != .instruction)
            return null;
        const lhs_exponent = (try self.integerPowExponent(lhs.value, load_id, instruction_id)) orelse return null;
        const rhs_exponent = (try self.integerPowExponent(rhs.value, load_id, instruction_id)) orelse return null;
        return std.math.add(u32, lhs_exponent, rhs_exponent) catch null;
    }

    fn constantPowPattern(self: Context, block: snapshot_v1.IrBlock) Error!?ConstantPowPattern {
        if (!block.kind.isCompilable() or block.isEmpty() or block.finish < block.start + 6)
            return null;
        const possible_tag = try self.instruction(block.finish - 1);
        const has_store_tag = possible_tag.command == .store_tag;
        const store_id = block.finish - (if (has_store_tag) @as(u32, 2) else 1);
        if (store_id < block.start + 4)
            return null;
        const store = try self.instruction(store_id);
        const jump = try self.instruction(block.finish);
        if (store.command != .store_double or store.operand_count != 2 or jump.command != .jump or jump.operand_count != 1)
            return null;
        const destination = try self.operand(store, 0);
        const result = try self.operand(store, 1);
        const fast_target = try self.operand(jump, 0);
        if (destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
            result.kind != .instruction or result.value + 1 != store_id or fast_target.kind != .block)
            return null;
        if (has_store_tag) {
            if ((try self.operand(possible_tag, 0)).kind != .vm_reg or
                (try self.operand(possible_tag, 0)).value != destination.value or
                (try self.operand(possible_tag, 1)).kind != .constant or
                (try self.constant((try self.operand(possible_tag, 1)).value)).tagValue() != lua_tag_number)
                return null;
        }

        const direct_result = try self.instruction(result.value);
        if (direct_result.command == ir_cmd_invoke_libm and direct_result.operand_count == 3) {
            const bfid = try self.operand(direct_result, 0);
            const direct_lhs = try self.operand(direct_result, 1);
            const direct_rhs = try self.operand(direct_result, 2);
            if (bfid.kind == .constant and (try self.constant(bfid.value)).uintValue() == lbf_math_pow and
                direct_lhs.kind == .constant and direct_rhs.kind == .instruction)
            constant_left: {
                const direct_constant = try self.constant(direct_lhs.value);
                if (direct_constant.doubleValue() == null)
                    break :constant_left;
                const load = try self.instruction(direct_rhs.value);
                if (load.command != .load_double or load.operand_count != 1)
                    break :constant_left;
                const loaded = try self.operand(load, 0);
                if (loaded.kind != .vm_reg)
                    break :constant_left;
                var guard_start = block.start;
                var guarded = false;
                var fallback_id: u32 = 0;
                while (guard_start + 1 < direct_rhs.value) : (guard_start += 1) {
                    const load_tag = try self.instruction(guard_start);
                    const check = try self.instruction(guard_start + 1);
                    if (load_tag.command != .load_tag or check.command != .check_tag or
                        load_tag.operand_count != 1 or check.operand_count != 3)
                        continue;
                    const source = try self.operand(load_tag, 0);
                    const checked = try self.operand(check, 0);
                    const tag = try self.operand(check, 1);
                    const fallback = try self.operand(check, 2);
                    if (source.kind == .vm_reg and source.value == loaded.value and checked.kind == .instruction and
                        checked.value == guard_start and tag.kind == .constant and
                        (try self.constant(tag.value)).tagValue() == lua_tag_number and fallback.kind == .block)
                    {
                        guarded = true;
                        fallback_id = fallback.value;
                        break;
                    }
                }
                if (!guarded)
                    break :constant_left;
                const fallback_block = try self.snapshot.irBlock(self.function, fallback_id);
                if (!try self.supportsArithmeticFallback(fallback_block))
                    break :constant_left;
                const marker = try self.instruction(fallback_block.start);
                const arithmetic_id = fallback_block.start + 1;
                const arithmetic = try self.instruction(arithmetic_id);
                const fallback_destination = try self.operand(arithmetic, 0);
                const fallback_lhs = try self.operand(arithmetic, 1);
                const fallback_rhs = try self.operand(arithmetic, 2);
                const operation = try self.operand(arithmetic, 3);
                const fallback_rejoin = try self.operand(try self.instruction(fallback_block.finish), 0);
                if (fallback_destination.kind != .vm_reg or fallback_destination.value != destination.value or
                    fallback_lhs.kind != .vm_reg or fallback_rhs.kind != .vm_reg or fallback_rhs.value != loaded.value or
                    operation.kind != .constant or (try self.constant(operation.value)).intValue() != upstream_tm_pow or
                    fallback_rejoin.kind != .block)
                    break :constant_left;
                var materialized = false;
                var materialize_id = block.start;
                while (materialize_id + 1 < guard_start) : (materialize_id += 1) {
                    const materialize = try self.instruction(materialize_id);
                    const materialize_tag = try self.instruction(materialize_id + 1);
                    if (materialize.command != .store_double or materialize.operand_count != 2 or
                        materialize_tag.command != .store_tag or materialize_tag.operand_count != 2)
                        continue;
                    const materialize_destination = try self.operand(materialize, 0);
                    const materialize_value = try self.operand(materialize, 1);
                    if (materialize_destination.kind == .vm_reg and materialize_destination.value == fallback_lhs.value and
                        materialize_value.kind == .constant and (try self.constant(materialize_value.value)).bits == direct_constant.bits and
                        (try self.operand(materialize_tag, 0)).kind == .vm_reg and
                        (try self.operand(materialize_tag, 0)).value == fallback_lhs.value and
                        (try self.operand(materialize_tag, 1)).kind == .constant and
                        (try self.constant((try self.operand(materialize_tag, 1)).value)).tagValue() == lua_tag_number)
                    {
                        materialized = true;
                        break;
                    }
                }
                if (!materialized)
                    break :constant_left;
                return .{
                    .start = guard_start,
                    .fast_target = try self.requireCompiledTarget(fast_target),
                    .rejoin = try self.requireCompiledTarget(fallback_rejoin),
                    .marker = marker,
                    .arithmetic_id = arithmetic_id,
                };
            }
        }

        // The pin strength-reduces a variable raised to a positive integer constant into an exact
        // multiplication DAG rooted in one guarded LOAD_DOUBLE.
        var start = block.start;
        while (start + 3 < store_id) : (start += 1) {
            const load_tag = try self.instruction(start);
            const check = try self.instruction(start + 1);
            const load = try self.instruction(start + 2);
            if (load_tag.command != .load_tag or check.command != .check_tag or load.command != .load_double or
                load_tag.operand_count != 1 or check.operand_count != 3 or load.operand_count != 1)
                continue;
            const source = try self.operand(load_tag, 0);
            const checked = try self.operand(check, 0);
            const tag = try self.operand(check, 1);
            const fallback = try self.operand(check, 2);
            const loaded = try self.operand(load, 0);
            if (source.kind != .vm_reg or source.value >= self.proto.max_stack_size or
                checked.kind != .instruction or checked.value != start or tag.kind != .constant or
                (try self.constant(tag.value)).tagValue() != lua_tag_number or fallback.kind != .block or
                loaded.kind != .vm_reg or loaded.value != source.value)
                continue;
            const exponent = (try self.integerPowExponent(result.value, start + 2, store_id)) orelse continue;
            const fallback_block = try self.snapshot.irBlock(self.function, fallback.value);
            if (!try self.supportsArithmeticFallback(fallback_block))
                continue;
            const marker = try self.instruction(fallback_block.start);
            const arithmetic_id = fallback_block.start + 1;
            const arithmetic = try self.instruction(arithmetic_id);
            const fallback_destination = try self.operand(arithmetic, 0);
            const fallback_lhs = try self.operand(arithmetic, 1);
            const fallback_rhs = try self.operand(arithmetic, 2);
            const operation = try self.operand(arithmetic, 3);
            const fallback_rejoin = try self.operand(try self.instruction(fallback_block.finish), 0);
            if (fallback_destination.kind != .vm_reg or fallback_destination.value != destination.value or
                fallback_lhs.kind != .vm_reg or fallback_lhs.value != source.value or fallback_rhs.kind != .vm_const or
                fallback_rhs.value >= self.proto.vm_constant_count or operation.kind != .constant or
                (try self.constant(operation.value)).intValue() != upstream_tm_pow or fallback_rejoin.kind != .block)
                continue;
            const exponent_constant = try self.snapshot.vmConstant(self.proto, fallback_rhs.value);
            if (exponent_constant.kind != .number or exponent_constant.bits0 != @as(u64, @bitCast(@as(f64, @floatFromInt(exponent)))))
                continue;
            return .{
                .start = start,
                .fast_target = try self.requireCompiledTarget(fast_target),
                .rejoin = try self.requireCompiledTarget(fallback_rejoin),
                .marker = marker,
                .arithmetic_id = arithmetic_id,
            };
        }
        return null;
    }

    fn linearizedPowPattern(self: Context, instruction_id: u32, block: snapshot_v1.IrBlock) Error!?LinearizedPowPattern {
        if (block.kind != .linearized or instruction_id >= block.finish)
            return null;
        const invoke = try self.instruction(instruction_id);
        const store = try self.instruction(instruction_id + 1);
        if (invoke.command != ir_cmd_invoke_libm or invoke.operand_count != 3 or
            store.command != .store_double or store.operand_count != 2)
            return null;
        const bfid = try self.operand(invoke, 0);
        const destination = try self.vmRegisterIndex(try self.operand(store, 0));
        if (bfid.kind != .constant or (try self.constant(bfid.value)).uintValue() != lbf_math_pow or
            (try self.operand(store, 1)).kind != .instruction or
            (try self.operand(store, 1)).value != instruction_id)
            return null;
        const lhs = (try self.powValueRegister(try self.operand(invoke, 1), instruction_id)) orelse return null;
        const rhs = (try self.powValueRegister(try self.operand(invoke, 2), instruction_id)) orelse return null;

        var finish = instruction_id + 1;
        if (finish < block.finish) {
            const possible_tag = try self.instruction(finish + 1);
            if (possible_tag.command == .store_tag and possible_tag.operand_count == 2 and
                (try self.operand(possible_tag, 0)).kind == .vm_reg and
                (try self.operand(possible_tag, 0)).value == destination and
                (try self.operand(possible_tag, 1)).kind == .constant and
                (try self.constant((try self.operand(possible_tag, 1)).value)).tagValue() == lua_tag_number)
                finish += 1;
        }
        if (finish == instruction_id + 1 and destination != lhs)
            return null;

        // Linearization preserves source order but may reuse the same VM tuple for several pow
        // sites. Select the Nth canonical site for the Nth matching linearized occurrence instead
        // of requiring tuple uniqueness.
        var ordinal: u32 = 0;
        var cursor = block.start;
        while (cursor < instruction_id) : (cursor += 1) {
            const prior = try self.instruction(cursor);
            if (prior.command != ir_cmd_invoke_libm or prior.operand_count != 3 or cursor + 1 > block.finish)
                continue;
            const prior_bfid = try self.operand(prior, 0);
            if (prior_bfid.kind != .constant or (try self.constant(prior_bfid.value)).uintValue() != lbf_math_pow)
                continue;
            const prior_store = try self.instruction(cursor + 1);
            if (prior_store.command != .store_double or prior_store.operand_count != 2)
                continue;
            const prior_destination = self.vmRegisterIndex(try self.operand(prior_store, 0)) catch continue;
            const prior_lhs = (try self.powValueRegister(try self.operand(prior, 1), cursor)) orelse continue;
            const prior_rhs = (try self.powValueRegister(try self.operand(prior, 2), cursor)) orelse continue;
            if (prior_destination == destination and prior_lhs == lhs and prior_rhs == rhs)
                ordinal += 1;
        }

        var selected: ?PowPattern = null;
        var previous_start: ?u32 = null;
        var index: u32 = 0;
        while (index <= ordinal) : (index += 1) {
            var next: ?PowPattern = null;
            var block_id: u32 = 0;
            while (block_id < self.function.block_count) : (block_id += 1) {
                const candidate = try self.snapshot.irBlock(self.function, block_id);
                const pattern = (try self.powPattern(candidate)) orelse continue;
                if (pattern.destination != destination or pattern.lhs != lhs or pattern.rhs != rhs or
                    (previous_start != null and pattern.start <= previous_start.?) or
                    (next != null and pattern.start >= next.?.start))
                    continue;
                next = pattern;
            }
            selected = next orelse return null;
            previous_start = selected.?.start;
        }
        return .{
            .finish = finish,
            .marker = selected.?.marker,
            .arithmetic_id = selected.?.arithmetic_id,
        };
    }

    fn emitPowBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock, pattern: PowPattern) Error!void {
        try self.body.localGet(self.allocator, self.dispatch_local);
        try self.body.i32Const(self.allocator, @intCast(block_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        if (pattern.start > block.start) {
            if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
                return Error.InvalidBlockTermination;
        }
        try self.emitSavedPcLocation(pattern.marker);
        try self.emitDoArith(pattern.arithmetic_id, try self.instruction(pattern.arithmetic_id));
        try self.body.i32Const(self.allocator, @intCast(pattern.rejoin));
        try self.body.localSet(self.allocator, self.dispatch_local);
        try self.body.branch(self.allocator, 1);
        try self.body.end(self.allocator);
    }

    fn emitConstantArithmeticBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock, pattern: ConstantArithmeticPattern) Error!void {
        try self.body.localGet(self.allocator, self.dispatch_local);
        try self.body.i32Const(self.allocator, @intCast(block_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        if (pattern.start > block.start) {
            if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
                return Error.InvalidBlockTermination;
        }
        try self.emitSavedPcLocation(pattern.marker);
        try self.emitDoArith(pattern.arithmetic_id, try self.instruction(pattern.arithmetic_id));
        try self.body.i32Const(self.allocator, @intCast(pattern.rejoin));
        try self.body.localSet(self.allocator, self.dispatch_local);
        try self.body.branch(self.allocator, 1);
        try self.body.end(self.allocator);
    }

    fn emitDynamicLengthBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock, pattern: DynamicLengthPattern) Error!void {
        try self.body.localGet(self.allocator, self.dispatch_local);
        try self.body.i32Const(self.allocator, @intCast(block_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        if (pattern.start > block.start) {
            if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
                return Error.InvalidBlockTermination;
        }
        try self.emitDynamicLength(pattern);
        try self.body.branch(self.allocator, 1);
        try self.body.end(self.allocator);
    }

    fn emitDynamicLength(self: Context, pattern: DynamicLengthPattern) Error!void {
        try self.emitSavedPcLocation(pattern.marker);
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.destination));
        try self.body.i32Const(self.allocator, @intCast(pattern.source));
        try self.body.call(self.allocator, self.do_len orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
        try self.body.i32Const(self.allocator, @intCast(pattern.rejoin));
        try self.body.localSet(self.allocator, self.dispatch_local);
    }

    fn genericIterationFallbackPattern(self: Context, block: snapshot_v1.IrBlock) Error!?GenericIterationPattern {
        if (block.kind != .fallback or block.isEmpty() or block.finish != block.start + 1)
            return null;
        const marker = try self.instruction(block.start);
        const loop = try self.instruction(block.finish);
        if (marker.command != .set_savedpc or marker.operand_count != 1 or
            loop.command != ir_cmd_forgloop_fallback or loop.operand_count != 4)
            return null;
        if (try self.savedPc(marker) == 0)
            return null;

        const base = try self.vmRegisterIndex(try self.operand(loop, 0));
        const aux = self.genericIterationAux(try self.operand(loop, 1)) catch return null;
        const variable_count = aux & 0xff;
        const live_count = @max(std.math.add(u32, variable_count, 3) catch return null, 5);
        if (live_count > self.proto.max_stack_size or
            base > @as(u32, self.proto.max_stack_size) - live_count)
            return null;
        const repeat = try self.operand(loop, 2);
        const exit = try self.operand(loop, 3);
        return .{
            .marker = marker,
            .base = base,
            .aux = aux,
            .variable_count = variable_count,
            .repeat_target = self.requireCompiledTarget(repeat) catch return null,
            .exit_target = self.requireCompiledTarget(exit) catch return null,
        };
    }

    fn genericIterationPattern(self: Context, block: snapshot_v1.IrBlock) Error!?GenericIterationPattern {
        if (!block.kind.isCompilable() or block.isEmpty() or block.finish != block.start + 3)
            return null;
        const commands = [_]snapshot_v1.IrCommand{ .interrupt, .load_tag, .check_tag, ir_cmd_forgloop };
        if (!try self.commandRangeMatches(block.start, &commands))
            return null;
        const marker = try self.instruction(block.start);
        const load_tag = try self.instruction(block.start + 1);
        const check_tag = try self.instruction(block.start + 2);
        const loop = try self.instruction(block.finish);
        if (marker.operand_count != 1 or load_tag.operand_count != 1 or check_tag.operand_count != 3 or
            loop.operand_count != 4)
            return null;
        _ = self.uintConstant(try self.operand(marker, 0)) catch return null;

        const base = try self.vmRegisterIndex(try self.operand(load_tag, 0));
        const checked = try self.operand(check_tag, 0);
        const expected_tag = try self.operand(check_tag, 1);
        const fallback_target = try self.operand(check_tag, 2);
        if (checked.kind != .instruction or checked.value != block.start + 1 or expected_tag.kind != .constant or
            (try self.constant(expected_tag.value)).tagValue() != @as(u8, @intCast(lua_tag_nil)) or
            fallback_target.kind != .block or fallback_target.value >= self.function.block_count)
            return null;

        const fallback_block = try self.snapshot.irBlock(self.function, fallback_target.value);
        const fallback = (try self.genericIterationFallbackPattern(fallback_block)) orelse return null;
        const loop_base = try self.vmRegisterIndex(try self.operand(loop, 0));
        const aux = self.genericIterationAux(try self.operand(loop, 1)) catch return null;
        const variable_count = aux & 0xff;
        const repeat = try self.operand(loop, 2);
        const exit = try self.operand(loop, 3);
        if (loop_base != base or aux != fallback.aux or base != fallback.base or
            repeat.kind != .block or repeat.value != fallback.repeat_target or
            exit.kind != .block or exit.value != fallback.exit_target)
            return null;
        return .{
            .marker = marker,
            .base = base,
            .aux = aux,
            .variable_count = variable_count,
            .repeat_target = fallback.repeat_target,
            .exit_target = fallback.exit_target,
            .fallback_target = fallback_target.value,
        };
    }

    fn xnextPreparationPattern(self: Context, block: snapshot_v1.IrBlock) Error!?XnextPreparationPattern {
        if (block.kind != .fallback or block.isEmpty() or block.start != block.finish)
            return null;
        const instruction_value = try self.instruction(block.start);
        if (instruction_value.command != ir_cmd_forgprep_xnext_fallback or instruction_value.operand_count != 3)
            return null;
        const pc = self.uintConstant(try self.operand(instruction_value, 0)) catch return null;
        const base = self.vmRegisterIndex(try self.operand(instruction_value, 1)) catch return null;
        if (self.proto.max_stack_size < 3 or base > @as(u32, self.proto.max_stack_size) - 3)
            return null;
        const target = self.requireCompiledTarget(try self.operand(instruction_value, 2)) catch return null;
        return .{ .pc = pc, .base = base, .target = target };
    }

    fn xnextCanonicalPublish(self: Context, start: u32, base: u32, target: u32) Error!bool {
        const commands = [_]snapshot_v1.IrCommand{
            .store_tag,
            .store_pointer,
            .store_extra,
            .store_tag,
            .jump,
        };
        if (!try self.commandRangeMatches(start, &commands))
            return false;
        const iterator_tag = try self.instruction(start);
        const control_pointer = try self.instruction(start + 1);
        const control_extra = try self.instruction(start + 2);
        const control_tag = try self.instruction(start + 3);
        const jump = try self.instruction(start + 4);
        if (iterator_tag.operand_count != 2 or control_pointer.operand_count != 2 or
            control_extra.operand_count != 2 or control_tag.operand_count != 2 or jump.operand_count != 1)
            return false;
        const iterator_destination = try self.operand(iterator_tag, 0);
        const iterator_value = try self.operand(iterator_tag, 1);
        const pointer_destination = try self.operand(control_pointer, 0);
        const pointer_value = try self.operand(control_pointer, 1);
        const extra_destination = try self.operand(control_extra, 0);
        const extra_value = try self.operand(control_extra, 1);
        const tag_destination = try self.operand(control_tag, 0);
        const tag_value = try self.operand(control_tag, 1);
        const jump_target = try self.operand(jump, 0);
        if (iterator_destination.kind != .vm_reg or iterator_destination.value != base or
            iterator_value.kind != .constant or
            (try self.constant(iterator_value.value)).tagValue() != @as(u8, @intCast(lua_tag_nil)) or
            pointer_destination.kind != .vm_reg or pointer_destination.value != base + 2 or
            (self.intConstant(pointer_value) catch return false) != 0 or
            extra_destination.kind != .vm_reg or extra_destination.value != base + 2 or
            (self.intConstant(extra_value) catch return false) != lu_tag_iterator or
            tag_destination.kind != .vm_reg or tag_destination.value != base + 2 or
            tag_value.kind != .constant or
            (try self.constant(tag_value.value)).tagValue() != lua_tag_lightuserdata or
            jump_target.kind != .block or jump_target.value != target)
            return false;
        return true;
    }

    fn xnextFastPreparationPattern(self: Context, block: snapshot_v1.IrBlock) Error!?XnextFastPreparationPattern {
        if (!block.kind.isCompilable() or block.isEmpty())
            return null;

        // FORGPREP_NEXT ends in one block. LOAD_TAG/CHECK_TAG for a statically nil control may be
        // optimized to two NOPs, but the safe-environment marker and the complete publication graph
        // retain exact ownership of the fallback.
        if (block.finish >= block.start + 9) next: {
            const start = block.finish - 9;
            const marker = try self.instruction(start);
            const state_load = try self.instruction(start + 1);
            const state_check = try self.instruction(start + 2);
            const control_load = try self.instruction(start + 3);
            const control_check = try self.instruction(start + 4);
            if ((marker.command != .nop and marker.command != .check_safe_env) or
                state_load.command != .load_tag or state_check.command != .check_tag)
                break :next;
            if ((marker.command == .nop and (marker.operand_count != 0 or (block.flags & 1) == 0)) or
                (marker.command == .check_safe_env and
                    (marker.operand_count != 1 or (try self.operand(marker, 0)).kind != .vm_exit)) or
                state_load.operand_count != 1 or state_check.operand_count != 3)
                break :next;
            const state_register = self.vmRegisterIndex(try self.operand(state_load, 0)) catch break :next;
            if (state_register == 0)
                break :next;
            const base = state_register - 1;
            if (base + 2 >= self.proto.max_stack_size)
                break :next;
            const state_value = try self.operand(state_check, 0);
            const state_tag = try self.operand(state_check, 1);
            const fallback = try self.operand(state_check, 2);
            if (state_value.kind != .instruction or state_value.value != start + 1 or
                state_tag.kind != .constant or
                (try self.constant(state_tag.value)).tagValue() != lua_tag_table or
                fallback.kind != .block or fallback.value >= self.function.block_count)
                break :next;
            if (control_load.command == .nop and control_check.command == .nop) {
                if (control_load.operand_count != 0 or control_check.operand_count != 0)
                    break :next;
            } else {
                if (control_load.command != .load_tag or control_check.command != .check_tag or
                    control_load.operand_count != 1 or control_check.operand_count != 3 or
                    self.vmRegisterIndex(try self.operand(control_load, 0)) catch break :next != base + 2)
                    break :next;
                const checked_control = try self.operand(control_check, 0);
                const control_tag = try self.operand(control_check, 1);
                const control_fallback = try self.operand(control_check, 2);
                if (checked_control.kind != .instruction or checked_control.value != start + 3 or
                    control_tag.kind != .constant or
                    (try self.constant(control_tag.value)).tagValue() != @as(u8, @intCast(lua_tag_nil)) or
                    control_fallback.kind != .block or control_fallback.value != fallback.value)
                    break :next;
            }
            const fallback_block = try self.snapshot.irBlock(self.function, fallback.value);
            const fallback_pattern = (try self.xnextPreparationPattern(fallback_block)) orelse break :next;
            if (fallback_pattern.base != base or
                !try self.xnextCanonicalPublish(start + 5, base, fallback_pattern.target))
                break :next;
            return .{
                .start = start,
                .pc = fallback_pattern.pc,
                .base = base,
                .target = fallback_pattern.target,
                .fallback = fallback.value,
            };
        }

        // FORGPREP_INEXT performs the safe/table/number guards in the source block and branches to
        // a separate canonical publication block only when the control is exactly numeric zero.
        if (block.finish < block.start + 6)
            return null;
        const start = block.finish - 6;
        const marker = try self.instruction(start);
        const state_load = try self.instruction(start + 1);
        const state_check = try self.instruction(start + 2);
        const control_load = try self.instruction(start + 3);
        const control_check = try self.instruction(start + 4);
        const number_load = try self.instruction(start + 5);
        const branch = try self.instruction(start + 6);
        if ((marker.command != .nop and marker.command != .check_safe_env) or
            state_load.command != .load_tag or state_check.command != .check_tag or
            control_load.command != .load_tag or control_check.command != .check_tag or
            number_load.command != .load_double or branch.command != .jump_cmp_num)
            return null;
        if ((marker.command == .nop and (marker.operand_count != 0 or (block.flags & 1) == 0)) or
            (marker.command == .check_safe_env and
                (marker.operand_count != 1 or (try self.operand(marker, 0)).kind != .vm_exit)) or
            state_load.operand_count != 1 or state_check.operand_count != 3 or control_load.operand_count != 1 or
            control_check.operand_count != 3 or number_load.operand_count != 1 or branch.operand_count != 5)
            return null;
        const state_register = self.vmRegisterIndex(try self.operand(state_load, 0)) catch return null;
        if (state_register == 0)
            return null;
        const base = state_register - 1;
        if (base + 2 >= self.proto.max_stack_size or
            (self.vmRegisterIndex(try self.operand(control_load, 0)) catch return null) != base + 2 or
            (self.vmRegisterIndex(try self.operand(number_load, 0)) catch return null) != base + 2)
            return null;
        const state_value = try self.operand(state_check, 0);
        const state_tag = try self.operand(state_check, 1);
        const state_fallback = try self.operand(state_check, 2);
        const control_value = try self.operand(control_check, 0);
        const control_tag = try self.operand(control_check, 1);
        const control_fallback = try self.operand(control_check, 2);
        if (state_value.kind != .instruction or state_value.value != start + 1 or
            state_tag.kind != .constant or (try self.constant(state_tag.value)).tagValue() != lua_tag_table or
            state_fallback.kind != .block or state_fallback.value >= self.function.block_count or
            control_value.kind != .instruction or control_value.value != start + 3 or
            control_tag.kind != .constant or (try self.constant(control_tag.value)).tagValue() != lua_tag_number or
            control_fallback.kind != .block or control_fallback.value != state_fallback.value)
            return null;
        const compared = try self.operand(branch, 0);
        const zero = try self.operand(branch, 1);
        const fallback = try self.operand(branch, 3);
        const publish = try self.operand(branch, 4);
        if (compared.kind != .instruction or compared.value != start + 5 or zero.kind != .constant or
            (try self.constant(zero.value)).doubleValue() != 0.0 or
            (try self.conditionOperand(branch, 2)) != .not_equal or
            fallback.kind != .block or fallback.value != state_fallback.value or
            publish.kind != .block or publish.value >= self.function.block_count)
            return null;
        const fallback_block = try self.snapshot.irBlock(self.function, fallback.value);
        const fallback_pattern = (try self.xnextPreparationPattern(fallback_block)) orelse return null;
        const publish_block = try self.snapshot.irBlock(self.function, publish.value);
        if (!publish_block.kind.isCompilable() or publish_block.isEmpty() or
            publish_block.finish != publish_block.start + 4 or fallback_pattern.base != base or
            !try self.xnextCanonicalPublish(publish_block.start, base, fallback_pattern.target))
            return null;
        return .{
            .start = start,
            .pc = fallback_pattern.pc,
            .base = base,
            .target = fallback_pattern.target,
            .fallback = fallback.value,
            .publish = publish.value,
        };
    }

    fn emitXnextFastPreparationBlock(
        self: Context,
        block_id: u32,
        block: snapshot_v1.IrBlock,
        pattern: XnextFastPreparationPattern,
    ) Error!void {
        try self.body.localGet(self.allocator, self.dispatch_local);
        try self.body.i32Const(self.allocator, @intCast(block_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        if (pattern.start > block.start) {
            if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
                return Error.InvalidBlockTermination;
        }
        try self.emitPcLocation(pattern.pc);
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.base));
        try self.body.call(self.allocator, self.forgprep_xnext_fallback orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
        try self.body.i32Const(self.allocator, @intCast(pattern.target));
        try self.body.localSet(self.allocator, self.dispatch_local);
        try self.body.branch(self.allocator, 1);
        try self.body.end(self.allocator);
    }

    fn emitXnextPreparationBlock(
        self: Context,
        block_id: u32,
        pattern: XnextPreparationPattern,
    ) Error!void {
        try self.body.localGet(self.allocator, self.dispatch_local);
        try self.body.i32Const(self.allocator, @intCast(block_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.emitPcLocation(pattern.pc);
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.base));
        try self.body.call(self.allocator, self.forgprep_xnext_fallback orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
        try self.body.i32Const(self.allocator, @intCast(pattern.target));
        try self.body.localSet(self.allocator, self.dispatch_local);
        try self.body.branch(self.allocator, 1);
        try self.body.end(self.allocator);
    }

    fn supportsGenericIterationFallback(self: Context, block: snapshot_v1.IrBlock) Error!bool {
        const fallback = (try self.genericIterationFallbackPattern(block)) orelse return false;
        var fallback_id: ?u32 = null;
        var block_id: u32 = 0;
        while (block_id < self.function.block_count) : (block_id += 1) {
            const candidate = try self.snapshot.irBlock(self.function, block_id);
            if (candidate.kind == block.kind and candidate.start == block.start and candidate.finish == block.finish) {
                if (fallback_id != null)
                    return Error.UnsupportedControlFlow;
                fallback_id = block_id;
            }
        }
        const resolved_fallback_id = fallback_id orelse return Error.UnsupportedControlFlow;

        block_id = 0;
        while (block_id < self.function.block_count) : (block_id += 1) {
            const candidate = try self.snapshot.irBlock(self.function, block_id);
            const fast = (try self.genericIterationPattern(candidate)) orelse continue;
            if (fast.fallback_target != null and fast.fallback_target.? == resolved_fallback_id and fast.base == fallback.base and
                fast.aux == fallback.aux and fast.repeat_target == fallback.repeat_target and
                fast.exit_target == fallback.exit_target)
                return true;
        }
        return false;
    }

    fn supportsSpecializedIpairsFallback(self: Context, block: snapshot_v1.IrBlock) Error!bool {
        const fallback = (try self.genericIterationFallbackPattern(block)) orelse return false;
        if (fallback.aux != 0x8000_0002)
            return false;
        var fallback_id: ?u32 = null;
        var block_id: u32 = 0;
        while (block_id < self.function.block_count) : (block_id += 1) {
            const candidate = try self.snapshot.irBlock(self.function, block_id);
            if (candidate.kind == block.kind and candidate.start == block.start and candidate.finish == block.finish) {
                if (fallback_id != null)
                    return Error.UnsupportedControlFlow;
                fallback_id = block_id;
            }
        }
        const resolved_fallback = fallback_id orelse return Error.UnsupportedControlFlow;

        block_id = 0;
        while (block_id < self.function.block_count) : (block_id += 1) {
            const candidate = try self.snapshot.irBlock(self.function, block_id);
            if (!candidate.kind.isCompilable() or candidate.isEmpty() or candidate.finish != candidate.start + 8)
                continue;
            const commands = [_]snapshot_v1.IrCommand{
                .interrupt,
                .load_tag,
                .check_tag,
                .load_pointer,
                .load_int,
                ir_cmd_get_arr_addr,
                ir_cmd_check_array_size,
                .load_tag,
                .jump_eq_tag,
            };
            if (!try self.commandRangeMatches(candidate.start, &commands))
                continue;
            const iterator_tag = try self.instruction(candidate.start + 1);
            const iterator_guard = try self.instruction(candidate.start + 2);
            const state_pointer = try self.instruction(candidate.start + 3);
            const control = try self.instruction(candidate.start + 4);
            const address = try self.instruction(candidate.start + 5);
            const bounds = try self.instruction(candidate.start + 6);
            const value_tag = try self.instruction(candidate.start + 7);
            const branch = try self.instruction(candidate.start + 8);
            if (iterator_tag.operand_count != 1 or iterator_guard.operand_count != 3 or
                state_pointer.operand_count != 1 or control.operand_count != 1 or address.operand_count != 2 or
                bounds.operand_count != 3 or value_tag.operand_count != 1 or branch.operand_count != 4)
                continue;
            const base = self.vmRegisterIndex(try self.operand(iterator_tag, 0)) catch continue;
            if (base != fallback.base or base + 4 >= self.proto.max_stack_size or
                (try self.operand(iterator_guard, 0)).kind != .instruction or
                (try self.operand(iterator_guard, 0)).value != candidate.start + 1 or
                (try self.operand(iterator_guard, 1)).kind != .constant or
                (try self.constant((try self.operand(iterator_guard, 1)).value)).tagValue() !=
                    @as(u8, @intCast(lua_tag_nil)) or
                (try self.operand(iterator_guard, 2)).kind != .block or
                (try self.operand(iterator_guard, 2)).value != resolved_fallback or
                (try self.operand(state_pointer, 0)).kind != .vm_reg or
                (try self.operand(state_pointer, 0)).value != base + 1 or
                (try self.operand(control, 0)).kind != .vm_reg or
                (try self.operand(control, 0)).value != base + 2 or
                (try self.operand(address, 0)).kind != .instruction or
                (try self.operand(address, 0)).value != candidate.start + 3 or
                (try self.operand(address, 1)).kind != .instruction or
                (try self.operand(address, 1)).value != candidate.start + 4 or
                (try self.operand(bounds, 0)).kind != .instruction or
                (try self.operand(bounds, 0)).value != candidate.start + 3 or
                (try self.operand(bounds, 1)).kind != .instruction or
                (try self.operand(bounds, 1)).value != candidate.start + 4 or
                (try self.operand(bounds, 2)).kind != .block or
                (try self.operand(bounds, 2)).value != fallback.exit_target or
                (try self.operand(value_tag, 0)).kind != .instruction or
                (try self.operand(value_tag, 0)).value != candidate.start + 5 or
                (try self.operand(branch, 0)).kind != .instruction or
                (try self.operand(branch, 0)).value != candidate.start + 7 or
                (try self.operand(branch, 1)).kind != .constant or
                (try self.constant((try self.operand(branch, 1)).value)).tagValue() !=
                    @as(u8, @intCast(lua_tag_nil)) or
                (try self.operand(branch, 2)).kind != .block or
                (try self.operand(branch, 2)).value != fallback.exit_target or
                (try self.operand(branch, 3)).kind != .block)
                continue;
            const publish = try self.snapshot.irBlock(self.function, (try self.operand(branch, 3)).value);
            if (!publish.kind.isCompilable() or publish.isEmpty())
                continue;
            const terminator = try self.instruction(publish.finish);
            if (terminator.command != .jump or terminator.operand_count != 1 or
                (try self.operand(terminator, 0)).kind != .block or
                (try self.operand(terminator, 0)).value != fallback.repeat_target)
                continue;
            return true;
        }
        return false;
    }

    fn specializedIpairsPattern(self: Context, block: snapshot_v1.IrBlock) Error!?GenericIterationPattern {
        if (!block.kind.isCompilable() or block.isEmpty() or block.finish != block.start + 8)
            return null;
        const commands = [_]snapshot_v1.IrCommand{
            .interrupt,
            .load_tag,
            .check_tag,
            .load_pointer,
            .load_int,
            ir_cmd_get_arr_addr,
            ir_cmd_check_array_size,
            .load_tag,
            .jump_eq_tag,
        };
        if (!try self.commandRangeMatches(block.start, &commands))
            return null;
        const marker = try self.instruction(block.start);
        const load_tag = try self.instruction(block.start + 1);
        const check_tag = try self.instruction(block.start + 2);
        if (marker.operand_count != 1 or load_tag.operand_count != 1 or check_tag.operand_count != 3)
            return null;
        const checked = try self.operand(check_tag, 0);
        const expected = try self.operand(check_tag, 1);
        const fallback_target = try self.operand(check_tag, 2);
        if (checked.kind != .instruction or checked.value != block.start + 1 or
            expected.kind != .constant or
            (try self.constant(expected.value)).tagValue() != @as(u8, @intCast(lua_tag_nil)) or
            fallback_target.kind != .block or fallback_target.value >= self.function.block_count)
            return null;
        const fallback_block = try self.snapshot.irBlock(self.function, fallback_target.value);
        if (!try self.supportsSpecializedIpairsFallback(fallback_block))
            return null;
        var fallback = (try self.genericIterationFallbackPattern(fallback_block)) orelse return null;
        const base = self.vmRegisterIndex(try self.operand(load_tag, 0)) catch return null;
        if (base != fallback.base)
            return null;
        fallback.marker = marker;
        fallback.fallback_target = fallback_target.value;
        return fallback;
    }

    fn isBypassedSpecializedIpairsPublishBlock(self: Context, block_id: u32) Error!bool {
        var candidate_id: u32 = 0;
        while (candidate_id < self.function.block_count) : (candidate_id += 1) {
            const candidate = try self.snapshot.irBlock(self.function, candidate_id);
            if (try self.specializedIpairsPattern(candidate) == null)
                continue;
            const branch = try self.instruction(candidate.finish);
            const publish = try self.operand(branch, 3);
            if (publish.kind == .block and publish.value == block_id)
                return true;
        }
        return false;
    }

    fn emitGenericIterationCall(self: Context, pattern: GenericIterationPattern) Error!void {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.base));
        try self.body.i32Const(self.allocator, @bitCast(pattern.aux));
        try self.body.call(self.allocator, self.forg_loop orelse return Error.UnsupportedCommand);
        try self.body.localSet(self.allocator, self.status_local);
        try self.emitReloadBase();
        try self.body.i32Const(self.allocator, @intCast(pattern.repeat_target));
        try self.body.i32Const(self.allocator, @intCast(pattern.exit_target));
        try self.body.localGet(self.allocator, self.status_local);
        // The helper returns one when it published the next key/value tuple and zero at exhaustion.
        try self.body.select(self.allocator);
        try self.body.localSet(self.allocator, self.dispatch_local);
    }

    fn emitGenericIterationFinish(self: Context, pattern: GenericIterationPattern) Error!void {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.base));
        try self.body.i32Const(self.allocator, @bitCast(pattern.aux));
        try self.body.call(self.allocator, self.forg_loop_finish orelse return Error.UnsupportedCommand);
        try self.body.localSet(self.allocator, self.status_local);
        try self.emitReloadBase();
        try self.body.i32Const(self.allocator, @intCast(pattern.repeat_target));
        try self.body.i32Const(self.allocator, @intCast(pattern.exit_target));
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.select(self.allocator);
        try self.body.localSet(self.allocator, self.dispatch_local);
    }

    fn emitGenericIterationFallbackCall(
        self: Context,
        instruction_id: u32,
        pattern: GenericIterationPattern,
    ) Error!void {
        const continuation = self.callContinuation(instruction_id) orelse return Error.UnsupportedControlFlow;
        const admitted = switch (continuation.action) {
            .generic_iteration => |candidate| candidate,
            .call_suffix,
            .interrupt_block_retry,
            .interrupt_suffix,
            .static_require_interrupt,
            => return Error.UnsupportedControlFlow,
        };
        if (admitted.base != pattern.base or admitted.aux != pattern.aux or
            admitted.repeat_target != pattern.repeat_target or admitted.exit_target != pattern.exit_target)
            return Error.UnsupportedControlFlow;

        try self.emitExchangeContinuation(continuation.continuation_id);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.body.else_(self.allocator);
        try self.emitUnexpectedContinuationReturn();
        try self.body.end(self.allocator);

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.base));
        try self.body.i32Const(self.allocator, @bitCast(pattern.aux));
        try self.body.call(self.allocator, self.forg_loop_call orelse return Error.UnsupportedCommand);
        try self.body.localTee(self.allocator, self.status_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.emitClearContinuation(continuation.continuation_id);
        try self.emitReloadBase();
        try self.emitGenericIterationFinish(pattern);
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.return_(self.allocator);
        try self.body.end(self.allocator);
    }

    fn emitGenericIterationBlock(
        self: Context,
        block_id: u32,
        pattern: GenericIterationPattern,
        guarded: bool,
    ) Error!void {
        const block = try self.snapshot.irBlock(self.function, block_id);
        try self.body.localGet(self.allocator, self.dispatch_local);
        try self.body.i32Const(self.allocator, @intCast(block_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        if (guarded) {
            try self.emitInterrupt(block.start, pattern.marker);
            const fallback_target = pattern.fallback_target orelse return Error.UnsupportedControlFlow;
            try self.emitTValueTag(.{ .kind = .vm_reg, .value = pattern.base });
            try self.body.i32Const(self.allocator, lua_tag_nil);
            try self.body.i32Eq(self.allocator);
            try self.body.ifVoid(self.allocator);
            try self.emitGenericIterationCall(pattern);
            try self.body.else_(self.allocator);
            try self.body.i32Const(self.allocator, @intCast(fallback_target));
            try self.body.localSet(self.allocator, self.dispatch_local);
            try self.body.end(self.allocator);
        } else {
            if (block.finish < block.start or block.finish >= self.function.instruction_count)
                return Error.UnsupportedControlFlow;
            try self.emitSavedPcLocation(pattern.marker);
            // A non-nil iterator reaches this fallback. It must use the real callable protocol and
            // therefore must own a validated resumable continuation; builtin table traversal is
            // exclusively the guarded nil-iterator fast arm above.
            try self.emitGenericIterationFallbackCall(block.finish, pattern);
        }
        try self.body.branch(self.allocator, 1);
        try self.body.end(self.allocator);
    }

    fn emitGenericIterationPrep(
        self: Context,
        instruction_id: u32,
        instruction_value: snapshot_v1.IrInstruction,
    ) Error!void {
        var owner: ?snapshot_v1.IrBlock = null;
        var block_id: u32 = 0;
        while (block_id < self.function.block_count) : (block_id += 1) {
            const candidate = try self.snapshot.irBlock(self.function, block_id);
            if (!candidate.isEmpty() and instruction_id >= candidate.start and instruction_id <= candidate.finish) {
                if (owner != null)
                    return Error.UnsupportedControlFlow;
                owner = candidate;
            }
        }
        const block = owner orelse return Error.UnsupportedControlFlow;
        if (!block.kind.isCompilable() or instruction_id != block.finish or instruction_value.operand_count != 3)
            return Error.UnsupportedControlFlow;
        const pc = try self.uintConstant(try self.operand(instruction_value, 0));
        const base = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
        if (self.proto.max_stack_size < 3 or base > @as(u32, self.proto.max_stack_size) - 3)
            return Error.UnsupportedControlFlow;
        const target_operand = try self.operand(instruction_value, 2);
        const target = try self.requireCompiledTarget(target_operand);
        const loop = (try self.genericIterationPattern(try self.snapshot.irBlock(self.function, target))) orelse
            return Error.UnsupportedControlFlow;
        if (loop.base != base)
            return Error.UnsupportedControlFlow;

        try self.emitPcLocation(pc);
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(base));
        try self.body.call(self.allocator, self.forg_prep orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
        try self.body.i32Const(self.allocator, @intCast(target));
        try self.body.localSet(self.allocator, self.dispatch_local);
        try self.body.branch(self.allocator, 1);
    }

    fn emitArrayOperationBlock(
        self: Context,
        block_id: u32,
        block: snapshot_v1.IrBlock,
        pattern: ArrayOperationPattern,
        operation: ArrayOperationKind,
    ) Error!void {
        try self.body.localGet(self.allocator, self.dispatch_local);
        try self.body.i32Const(self.allocator, @intCast(block_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        if (pattern.start > block.start) {
            if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
                return Error.InvalidBlockTermination;
        }
        try self.emitArrayOperation(pattern, operation);
        try self.body.branch(self.allocator, 1);
        try self.body.end(self.allocator);
    }

    fn emitArrayOperation(
        self: Context,
        pattern: ArrayOperationPattern,
        operation: ArrayOperationKind,
    ) Error!void {
        try self.body.localGet(self.allocator, 0);
        switch (operation) {
            .set => {
                try self.body.i32Const(self.allocator, @intCast(pattern.table));
                try self.body.i32Const(self.allocator, @intCast(pattern.source));
                try self.body.i32Const(self.allocator, @intCast(pattern.index));
                try self.body.call(self.allocator, self.array_set orelse return Error.UnsupportedCommand);
            },
            .get => {
                try self.body.i32Const(self.allocator, @intCast(pattern.destination));
                try self.body.i32Const(self.allocator, @intCast(pattern.table));
                try self.body.i32Const(self.allocator, @intCast(pattern.index));
                try self.body.call(self.allocator, self.array_get orelse return Error.UnsupportedCommand);
            },
            .len => {
                try self.body.i32Const(self.allocator, @intCast(pattern.destination));
                try self.body.i32Const(self.allocator, @intCast(pattern.table));
                try self.body.call(self.allocator, self.table_len orelse return Error.UnsupportedCommand);
            },
        }
        try self.emitReloadBase();
        try self.body.i32Const(self.allocator, @intCast(pattern.rejoin));
        try self.body.localSet(self.allocator, self.dispatch_local);
    }

    fn semanticArrayOperation(self: Context, block: snapshot_v1.IrBlock) Error!?SemanticArrayOperation {
        if (try self.arraySetPattern(block)) |pattern|
            return .{ .pattern = pattern, .kind = .set };
        if (try self.arrayGetPattern(block)) |pattern|
            return .{ .pattern = pattern, .kind = .get };
        if (try self.trustedArrayGetPattern(block)) |pattern|
            return .{ .pattern = pattern, .kind = .get };
        if (try self.tableLenPattern(block)) |pattern|
            return .{ .pattern = pattern, .kind = .len };
        return null;
    }

    fn emitStringTableOperationBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock, pattern: StringTablePattern) Error!void {
        try self.body.localGet(self.allocator, self.dispatch_local);
        try self.body.i32Const(self.allocator, @intCast(block_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        if (pattern.start > block.start) {
            if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
                return Error.InvalidBlockTermination;
        }
        try self.emitStringTableOperation(pattern);
        try self.body.end(self.allocator);
    }

    fn emitStringTableOperation(self: Context, pattern: StringTablePattern) Error!void {
        try self.emitStringTableHelper(pattern);
        try self.body.i32Const(self.allocator, @intCast(pattern.rejoin));
        try self.body.localSet(self.allocator, self.dispatch_local);
        try self.body.branch(self.allocator, 1);
    }

    fn emitStringTableHelper(self: Context, pattern: StringTablePattern) Error!void {
        const key = try self.string_keys.intern(self.allocator, pattern.key);
        // The fused helper replaces both the optimized literal slot probe and its semantic
        // fallback. Publish the fallback bytecode location before entering luaV_gettable/settable
        // so receiver, key, readonly, and metamethod errors retain Luau's exact source boundary.
        try self.emitPcLocation(pattern.pc);
        try self.body.localGet(self.allocator, 0);
        switch (pattern.operation) {
            .set => {
                try self.body.i32Const(self.allocator, @intCast(pattern.table));
                try self.body.i32Const(self.allocator, @intCast(pattern.value));
                try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(key.offset));
                try self.body.i32Const(self.allocator, @intCast(key.length));
                try self.body.call(self.allocator, self.table_set_string orelse return Error.UnsupportedCommand);
            },
            .get => {
                try self.body.i32Const(self.allocator, @intCast(pattern.value));
                try self.body.i32Const(self.allocator, @intCast(pattern.table));
                try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(key.offset));
                try self.body.i32Const(self.allocator, @intCast(key.length));
                try self.body.call(self.allocator, self.table_get_string orelse return Error.UnsupportedCommand);
            },
        }
        try self.emitReloadBase();
    }

    fn emitGlobalOperationBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock, pattern: GlobalPattern) Error!void {
        try self.body.localGet(self.allocator, self.dispatch_local);
        try self.body.i32Const(self.allocator, @intCast(block_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        if (pattern.start > block.start) {
            if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
                return Error.InvalidBlockTermination;
        }
        try self.emitGlobalOperation(pattern);
        try self.body.branch(self.allocator, 1);
        try self.body.end(self.allocator);
    }

    fn emitGlobalOperation(self: Context, pattern: GlobalPattern) Error!void {
        const key = try self.string_keys.intern(self.allocator, pattern.key);
        // The fallback's bytecode pc is consumed here solely to publish the decoded source line.
        // The runtime ABI receives only the already-decoded register and literal key bytes.
        try self.emitPcLocation(pattern.pc);
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.value));
        try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(key.offset));
        try self.body.i32Const(self.allocator, @intCast(key.length));
        try self.body.call(self.allocator, switch (pattern.operation) {
            .get => self.get_global orelse return Error.UnsupportedCommand,
            .set => self.set_global orelse return Error.UnsupportedCommand,
        });
        try self.emitReloadBase();
        try self.body.i32Const(self.allocator, @intCast(pattern.rejoin));
        try self.body.localSet(self.allocator, self.dispatch_local);
    }

    fn emitGenericTableFallbackCall(self: Context, pattern: GenericTablePattern) Error!void {
        try self.emitSavedPcLocation(pattern.marker);
        if (pattern.immediate_number_key) |number| {
            if (pattern.operation != .get or pattern.key != pattern.value)
                return Error.UnsupportedControlFlow;
            try self.body.localGet(self.allocator, self.base_local);
            try self.body.f64Const(self.allocator, number);
            try self.body.f64Store(self.allocator, 3, pattern.key * tvalue_size);
            try self.body.localGet(self.allocator, self.base_local);
            try self.body.i32Const(self.allocator, lua_tag_number);
            try self.body.i32Store(self.allocator, 2, pattern.key * tvalue_size + tvalue_tag_offset);
        }
        try self.body.localGet(self.allocator, 0);
        switch (pattern.operation) {
            .set => {
                try self.body.i32Const(self.allocator, @intCast(pattern.table));
                try self.body.i32Const(self.allocator, @intCast(pattern.key));
                try self.body.i32Const(self.allocator, @intCast(pattern.value));
                try self.body.call(self.allocator, self.table_set orelse return Error.UnsupportedCommand);
            },
            .get => {
                try self.body.i32Const(self.allocator, @intCast(pattern.value));
                try self.body.i32Const(self.allocator, @intCast(pattern.table));
                try self.body.i32Const(self.allocator, @intCast(pattern.key));
                try self.body.call(self.allocator, self.table_get orelse return Error.UnsupportedCommand);
            },
        }
        try self.emitReloadBase();
    }

    fn emitGenericTableDirectAttempt(self: Context, pattern: GenericTablePattern) Error!void {
        try self.body.i32Const(self.allocator, 0);
        try self.body.localSet(self.allocator, self.status_local);

        const register_key = pattern.register_key orelse return;
        const key = snapshot_v1.IrOperand{ .kind = .vm_reg, .value = register_key };
        try self.emitTValueTag(key);
        try self.body.i32Const(self.allocator, lua_tag_number);
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);

        // TRY_NUM_TO_INDEX is an exact signed-i32 conversion: truncate without trapping, convert
        // back to f64, and admit only values whose round trip is numerically equal. NaN and values
        // outside the signed-i32 range therefore continue through the generic helper.
        const key_offset = try self.vmRegisterOffset(key, 0);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.f64Load(self.allocator, 3, key_offset);
        try self.body.opcode(self.allocator, 0xfc);
        try self.body.opcode(self.allocator, 0x02); // i32.trunc_sat_f64_s
        try self.body.localSet(self.allocator, self.table_index_local);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.f64Load(self.allocator, 3, key_offset);
        try self.body.localGet(self.allocator, self.table_index_local);
        try self.body.opcode(self.allocator, 0xb7); // f64.convert_i32_s
        try self.body.f64Eq(self.allocator);
        try self.body.ifVoid(self.allocator);

        try self.body.localGet(self.allocator, 0);
        switch (pattern.operation) {
            .set => {
                try self.body.i32Const(self.allocator, @intCast(pattern.table));
                try self.body.localGet(self.allocator, self.table_index_local);
                try self.body.i32Const(self.allocator, @intCast(pattern.value));
                try self.body.call(self.allocator, self.table_array_set orelse return Error.UnsupportedCommand);
            },
            .get => {
                try self.body.i32Const(self.allocator, @intCast(pattern.value));
                try self.body.i32Const(self.allocator, @intCast(pattern.table));
                try self.body.localGet(self.allocator, self.table_index_local);
                try self.body.call(self.allocator, self.table_array_get orelse return Error.UnsupportedCommand);
            },
        }
        try self.body.localSet(self.allocator, self.status_local);
        try self.emitReloadBase();
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
    }

    fn emitGenericTableOperationBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock, pattern: GenericTablePattern) Error!void {
        try self.body.localGet(self.allocator, self.dispatch_local);
        try self.body.i32Const(self.allocator, @intCast(block_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        if (pattern.start > block.start) {
            if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
                return Error.InvalidBlockTermination;
        }
        try self.emitGenericTableDirectAttempt(pattern);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.emitGenericTableFallbackCall(pattern);
        try self.body.end(self.allocator);
        try self.body.i32Const(self.allocator, @intCast(pattern.rejoin));
        try self.body.localSet(self.allocator, self.dispatch_local);
        try self.body.branch(self.allocator, 1);
        try self.body.end(self.allocator);
    }

    fn emitInlineGenericTableSet(self: Context, pattern: GenericTablePattern) Error!void {
        try self.emitGenericTableDirectAttempt(pattern);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.emitGenericTableFallbackCall(pattern);
        try self.body.end(self.allocator);
    }

    fn isBypassedStringLinearizedBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
        if (block.kind != .linearized or self.function.entry_block == block_id)
            return false;
        var has_rewritten_incoming = false;
        var source_block_id: u32 = 0;
        while (source_block_id < self.function.block_count) : (source_block_id += 1) {
            if (source_block_id == block_id)
                continue;
            const source_block = try self.snapshot.irBlock(self.function, source_block_id);
            const source_pattern = try self.stringTablePattern(source_block);
            var instruction_id: u32 = if (source_block.isEmpty()) 0 else source_block.start;
            while (!source_block.isEmpty() and instruction_id <= source_block.finish) : (instruction_id += 1) {
                const instruction_value = try self.instruction(instruction_id);
                var operand_id: u32 = 0;
                while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                    const operand_value = try self.operand(instruction_value, operand_id);
                    if (operand_value.kind != .block or operand_value.value != block_id)
                        continue;
                    if (source_pattern == null or source_pattern.?.fast_target != block_id or
                        instruction_id != source_block.finish or instruction_value.command != .jump)
                        return false;
                    has_rewritten_incoming = true;
                }
            }
        }
        return has_rewritten_incoming;
    }

    fn isBypassedGenericTableLinearizedBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
        if (block.kind != .linearized or self.function.entry_block == block_id)
            return false;
        var has_rewritten_incoming = false;
        var source_block_id: u32 = 0;
        while (source_block_id < self.function.block_count) : (source_block_id += 1) {
            if (source_block_id == block_id)
                continue;
            const source_block = try self.snapshot.irBlock(self.function, source_block_id);
            const source_pattern = try self.genericTablePattern(source_block);
            var instruction_id: u32 = if (source_block.isEmpty()) 0 else source_block.start;
            while (!source_block.isEmpty() and instruction_id <= source_block.finish) : (instruction_id += 1) {
                const instruction_value = try self.instruction(instruction_id);
                var operand_id: u32 = 0;
                while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                    const operand_value = try self.operand(instruction_value, operand_id);
                    if (operand_value.kind != .block or operand_value.value != block_id)
                        continue;
                    if (source_pattern == null or source_pattern.?.fast_target != block_id or
                        instruction_id != source_block.finish or instruction_value.command != .jump)
                        return false;
                    has_rewritten_incoming = true;
                }
            }
        }
        return has_rewritten_incoming;
    }

    fn isBypassedGlobalLinearizedBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
        if (block.kind != .linearized or self.function.entry_block == block_id)
            return false;
        var has_rewritten_incoming = false;
        var source_block_id: u32 = 0;
        while (source_block_id < self.function.block_count) : (source_block_id += 1) {
            if (source_block_id == block_id)
                continue;
            const source_block = try self.snapshot.irBlock(self.function, source_block_id);
            const source_pattern = try self.globalPattern(source_block);
            var instruction_id: u32 = if (source_block.isEmpty()) 0 else source_block.start;
            while (!source_block.isEmpty() and instruction_id <= source_block.finish) : (instruction_id += 1) {
                const instruction_value = try self.instruction(instruction_id);
                var operand_id: u32 = 0;
                while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                    const operand_value = try self.operand(instruction_value, operand_id);
                    if (operand_value.kind != .block or operand_value.value != block_id)
                        continue;
                    if (source_pattern == null or source_pattern.?.fast_target != block_id or
                        instruction_id != source_block.finish or instruction_value.command != .jump)
                        return false;
                    has_rewritten_incoming = true;
                }
            }
        }
        return has_rewritten_incoming;
    }

    fn isBypassedPowLinearizedBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
        if (block.kind != .linearized or self.function.entry_block == block_id)
            return false;
        var has_rewritten_incoming = false;
        var source_block_id: u32 = 0;
        while (source_block_id < self.function.block_count) : (source_block_id += 1) {
            if (source_block_id == block_id)
                continue;
            const source_block = try self.snapshot.irBlock(self.function, source_block_id);
            const source_pattern = try self.powPattern(source_block);
            var instruction_id: u32 = if (source_block.isEmpty()) 0 else source_block.start;
            while (!source_block.isEmpty() and instruction_id <= source_block.finish) : (instruction_id += 1) {
                const instruction_value = try self.instruction(instruction_id);
                var operand_id: u32 = 0;
                while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                    const operand_value = try self.operand(instruction_value, operand_id);
                    if (operand_value.kind != .block or operand_value.value != block_id)
                        continue;
                    if (source_pattern == null or source_pattern.?.fast_target != block_id or
                        instruction_id != source_block.finish or instruction_value.command != .jump)
                        return false;
                    has_rewritten_incoming = true;
                }
            }
        }
        return has_rewritten_incoming;
    }

    fn isBypassedConstantArithmeticLinearizedBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
        if (block.kind != .linearized or self.function.entry_block == block_id)
            return false;
        var has_rewritten_incoming = false;
        var source_block_id: u32 = 0;
        while (source_block_id < self.function.block_count) : (source_block_id += 1) {
            if (source_block_id == block_id)
                continue;
            const source_block = try self.snapshot.irBlock(self.function, source_block_id);
            const source_pattern = (try self.constantArithmeticPattern(source_block)) orelse
                (try self.constantPowPattern(source_block));
            var instruction_id: u32 = if (source_block.isEmpty()) 0 else source_block.start;
            while (!source_block.isEmpty() and instruction_id <= source_block.finish) : (instruction_id += 1) {
                const instruction_value = try self.instruction(instruction_id);
                var operand_id: u32 = 0;
                while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                    const operand_value = try self.operand(instruction_value, operand_id);
                    if (operand_value.kind != .block or operand_value.value != block_id)
                        continue;
                    if (source_pattern == null or source_pattern.?.fast_target != block_id or
                        instruction_id != source_block.finish or instruction_value.command != .jump)
                        return false;
                    has_rewritten_incoming = true;
                }
            }
        }
        return has_rewritten_incoming;
    }

    fn isBypassedStringEqualityBlock(self: Context, block_id: u32) Error!bool {
        if (self.function.entry_block == block_id)
            return false;
        var owner: ?u32 = null;
        var source_block_id: u32 = 0;
        while (source_block_id < self.function.block_count) : (source_block_id += 1) {
            if (source_block_id == block_id)
                continue;
            const source_block = try self.snapshot.irBlock(self.function, source_block_id);
            const pattern = (try self.stringEqualityPattern(source_block)) orelse continue;
            if (pattern.pointer_block == block_id) {
                if (owner != null)
                    return false;
                owner = source_block_id;
            }
        }
        if (owner == null)
            return false;
        var incoming_count: u32 = 0;
        source_block_id = 0;
        while (source_block_id < self.function.block_count) : (source_block_id += 1) {
            if (source_block_id == block_id)
                continue;
            const source_block = try self.snapshot.irBlock(self.function, source_block_id);
            if (source_block.isEmpty())
                continue;
            var instruction_id = source_block.start;
            while (instruction_id <= source_block.finish) : (instruction_id += 1) {
                const instruction_value = try self.instruction(instruction_id);
                var operand_id: u32 = 0;
                while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                    const operand_value = try self.operand(instruction_value, operand_id);
                    if (operand_value.kind == .block and operand_value.value == block_id) {
                        if (source_block_id != owner.?)
                            return false;
                        incoming_count += 1;
                    }
                }
            }
        }
        return incoming_count == 1;
    }

    fn sourceLine(self: Context, pc: u32) Error!u32 {
        const line = try self.snapshot.sourceLine(self.proto, pc);
        if (line > 0xfffff)
            return Error.ResourceLimit;
        return line;
    }

    fn emitSavedPcLocation(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        const saved_pc = try self.savedPc(instruction_value);
        if (saved_pc == 0)
            return Error.InvalidOperandType;
        try self.emitPcLocation(saved_pc - 1);
    }

    fn emitPcLocation(self: Context, pc: u32) Error!void {
        const line = try self.sourceLine(pc);
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(line));
        try self.body.call(self.allocator, self.set_location orelse return Error.UnsupportedCommand);
    }

    fn emitDoArith(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        if (instruction_id == 0)
            return Error.UnsupportedControlFlow;

        // Upstream fallback streams establish the bytecode/source location immediately before the
        // semantic helper. Strict AOT publishes the resolved line through the preceding marker and
        // never fabricates CallInfo::savedpc.
        const location_marker = try self.instruction(instruction_id - 1);
        if (location_marker.command != .set_savedpc)
            return Error.UnsupportedControlFlow;
        _ = try self.savedPc(location_marker);

        const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
        const lhs = try self.valueOperandEncoding(try self.operand(instruction_value, 1));
        const rhs = try self.valueOperandEncoding(try self.operand(instruction_value, 2));
        const operation_operand = try self.operand(instruction_value, 3);
        if (operation_operand.kind != .constant)
            return Error.InvalidOperandType;
        const upstream_operation = (try self.constant(operation_operand.value)).intValue() orelse return Error.InvalidOperandType;
        const operation = aotArithmeticOperation(upstream_operation) orelse return Error.UnsupportedCommand;

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(destination));
        try self.body.i32Const(self.allocator, @bitCast(lhs));
        try self.body.i32Const(self.allocator, @bitCast(rhs));
        try self.body.i32Const(self.allocator, operation);
        try self.body.call(self.allocator, self.do_arith orelse return Error.UnsupportedCommand);
        // Generic arithmetic may allocate, invoke a metamethod, and relocate the stack.
        try self.emitReloadBase();
    }

    fn comparisonOperation(condition: snapshot_v1.IrCondition) Error!i32 {
        return switch (condition) {
            .equal => 0,
            .less => 1,
            .less_equal => 2,
            else => Error.UnsupportedCondition,
        };
    }

    fn emitCompareAny(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        if (instruction_id == 0 or (try self.instruction(instruction_id - 1)).command != .set_savedpc)
            return Error.UnsupportedControlFlow;
        _ = try self.savedPc(try self.instruction(instruction_id - 1));

        const lhs = try self.valueOperandEncoding(try self.operand(instruction_value, 0));
        const rhs = try self.valueOperandEncoding(try self.operand(instruction_value, 1));
        const operation = try comparisonOperation(try self.conditionOperand(instruction_value, 2));

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @bitCast(lhs));
        try self.body.i32Const(self.allocator, @bitCast(rhs));
        try self.body.i32Const(self.allocator, operation);
        try self.body.call(self.allocator, self.compare_any orelse return Error.UnsupportedCommand);
        try self.emitInstructionResultSet(instruction_id);
        // Generic comparison can invoke a metamethod and relocate the active stack.
        try self.emitReloadBase();
    }

    fn stringEqualityPattern(self: Context, block: snapshot_v1.IrBlock) Error!?StringEqualityPattern {
        if (!block.kind.isCompilable() or block.isEmpty() or block.finish < block.start + 1)
            return null;
        const start = block.finish - 1;
        const load_tag = try self.instruction(start);
        const tag_jump = try self.instruction(block.finish);
        if (load_tag.command != .load_tag or load_tag.operand_count != 1 or
            tag_jump.command != .jump_eq_tag or tag_jump.operand_count != 4)
            return null;
        const lhs = try self.operand(load_tag, 0);
        const checked = try self.operand(tag_jump, 0);
        const tag = try self.operand(tag_jump, 1);
        const pointer_target = try self.operand(tag_jump, 2);
        const false_target = try self.operand(tag_jump, 3);
        if (lhs.kind != .vm_reg or lhs.value >= self.proto.max_stack_size or checked.kind != .instruction or
            checked.value != start or tag.kind != .constant or (try self.constant(tag.value)).tagValue() != lua_tag_string or
            pointer_target.kind != .block or false_target.kind != .block)
            return null;
        const pointer_block = try self.snapshot.irBlock(self.function, pointer_target.value);
        if (!pointer_block.kind.isCompilable() or pointer_block.isEmpty() or pointer_block.finish != pointer_block.start + 2)
            return null;
        const load_lhs = try self.instruction(pointer_block.start);
        const load_rhs = try self.instruction(pointer_block.start + 1);
        const pointer_jump = try self.instruction(pointer_block.finish);
        if (load_lhs.command != .load_pointer or load_rhs.command != .load_pointer or
            pointer_jump.command != .jump_eq_pointer or load_lhs.operand_count != 1 or load_rhs.operand_count != 1 or
            pointer_jump.operand_count != 4)
            return null;
        const pointer_lhs = try self.operand(load_lhs, 0);
        const rhs = try self.operand(load_rhs, 0);
        const compared_lhs = try self.operand(pointer_jump, 0);
        const compared_rhs = try self.operand(pointer_jump, 1);
        const true_target = try self.operand(pointer_jump, 2);
        const pointer_false_target = try self.operand(pointer_jump, 3);
        if (pointer_lhs.kind != .vm_reg or pointer_lhs.value != lhs.value or rhs.kind != .vm_const or
            rhs.value >= self.proto.vm_constant_count or (try self.snapshot.vmConstant(self.proto, rhs.value)).kind != .string or
            compared_lhs.kind != .instruction or compared_lhs.value != pointer_block.start or
            compared_rhs.kind != .instruction or compared_rhs.value != pointer_block.start + 1 or true_target.kind != .block or
            pointer_false_target.kind != .block or pointer_false_target.value != false_target.value)
            return null;
        return .{
            .start = start,
            .lhs = lhs.value,
            .rhs = try self.valueOperandEncoding(rhs),
            .true_target = try self.requireCompiledTarget(true_target),
            .false_target = try self.requireCompiledTarget(false_target),
            .pointer_block = pointer_target.value,
        };
    }

    fn emitStringEqualityBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock, pattern: StringEqualityPattern) Error!void {
        try self.body.localGet(self.allocator, self.dispatch_local);
        try self.body.i32Const(self.allocator, @intCast(block_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        if (pattern.start > block.start) {
            if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
                return Error.InvalidBlockTermination;
        }
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.lhs));
        try self.body.i32Const(self.allocator, @bitCast(pattern.rhs));
        try self.body.i32Const(self.allocator, 0);
        try self.body.call(self.allocator, self.compare_any orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
        try self.emitConditionalDispatch(pattern.true_target, pattern.false_target);
        try self.body.end(self.allocator);
    }

    fn supportsArithmeticFallback(self: Context, block: snapshot_v1.IrBlock) Error!bool {
        if (block.kind != .fallback or block.isEmpty() or block.finish - block.start != 2)
            return false;
        const marker = try self.instruction(block.start);
        const arithmetic = try self.instruction(block.start + 1);
        const jump = try self.instruction(block.start + 2);
        if (marker.command != .set_savedpc or arithmetic.command != .do_arith or jump.command != .jump or
            marker.operand_count != 1 or arithmetic.operand_count != 4 or jump.operand_count != 1)
            return false;

        const marker_operand = try self.operand(marker, 0);
        const destination = try self.operand(arithmetic, 0);
        const lhs = try self.operand(arithmetic, 1);
        const rhs = try self.operand(arithmetic, 2);
        const operation = try self.operand(arithmetic, 3);
        const jump_target = try self.operand(jump, 0);
        if (marker_operand.kind != .constant or destination.kind != .vm_reg or
            operation.kind != .constant or jump_target.kind != .block)
            return false;
        if ((try self.constant(marker_operand.value)).uintValue() == null)
            return false;
        const upstream_operation = (try self.constant(operation.value)).intValue() orelse return false;
        if (aotArithmeticOperation(upstream_operation) == null)
            return false;
        if (destination.value >= self.proto.max_stack_size)
            return false;
        _ = self.valueOperandEncoding(lhs) catch return false;
        _ = self.valueOperandEncoding(rhs) catch return false;

        const target = try self.snapshot.irBlock(self.function, jump_target.value);
        return target.kind.isCompilable() and !target.isEmpty();
    }

    fn supportsComparisonFallback(self: Context, block: snapshot_v1.IrBlock) Error!bool {
        if (block.kind != .fallback or block.isEmpty() or block.finish - block.start != 2)
            return false;
        const marker = try self.instruction(block.start);
        const comparison = try self.instruction(block.start + 1);
        const jump = try self.instruction(block.start + 2);
        if (marker.command != .set_savedpc or comparison.command != .cmp_any or jump.command != .jump_cmp_int or
            marker.operand_count != 1 or comparison.operand_count != 3 or jump.operand_count != 5)
            return false;

        const marker_operand = try self.operand(marker, 0);
        const lhs = try self.operand(comparison, 0);
        const rhs = try self.operand(comparison, 1);
        const comparison_condition = try self.operand(comparison, 2);
        const jump_lhs = try self.operand(jump, 0);
        const jump_rhs = try self.operand(jump, 1);
        const jump_condition = try self.operand(jump, 2);
        const true_target = try self.operand(jump, 3);
        const false_target = try self.operand(jump, 4);
        if (marker_operand.kind != .constant or comparison_condition.kind != .condition or
            jump_lhs.kind != .instruction or jump_lhs.value != block.start + 1 or jump_rhs.kind != .constant or
            jump_condition.kind != .condition or true_target.kind != .block or false_target.kind != .block)
            return false;
        if ((try self.constant(marker_operand.value)).uintValue() == null)
            return false;
        _ = self.valueOperandEncoding(lhs) catch return false;
        _ = self.valueOperandEncoding(rhs) catch return false;
        const comparison_condition_value: snapshot_v1.IrCondition = @enumFromInt(@as(u8, @intCast(comparison_condition.value)));
        _ = comparisonOperation(comparison_condition_value) catch return false;
        const zero = (try self.constant(jump_rhs.value)).intValue() orelse return false;
        if (zero != 0)
            return false;
        const jump_condition_value: snapshot_v1.IrCondition = @enumFromInt(@as(u8, @intCast(jump_condition.value)));
        if (jump_condition_value != .equal and jump_condition_value != .not_equal)
            return false;

        const true_block = try self.snapshot.irBlock(self.function, true_target.value);
        const false_block = try self.snapshot.irBlock(self.function, false_target.value);
        return true_block.kind.isCompilable() and !true_block.isEmpty() and
            false_block.kind.isCompilable() and !false_block.isEmpty();
    }

    fn supportsMaterializedComparisonFallback(self: Context, block: snapshot_v1.IrBlock) Error!bool {
        if (block.kind != .fallback or block.isEmpty())
            return false;
        const inverted = block.finish - block.start == 5;
        if (!inverted and block.finish - block.start != 4)
            return false;
        const marker = try self.instruction(block.start);
        const comparison = try self.instruction(block.start + 1);
        const materialized_id = block.start + 1 + @as(u32, @intFromBool(inverted));
        const materialized = try self.instruction(materialized_id);
        const store = try self.instruction(materialized_id + 1);
        const store_tag = try self.instruction(materialized_id + 2);
        const jump = try self.instruction(materialized_id + 3);
        if (marker.command != .set_savedpc or comparison.command != .cmp_any or store.command != .store_int or
            store_tag.command != .store_tag or jump.command != .jump or marker.operand_count != 1 or
            comparison.operand_count != 3 or store.operand_count != 2 or store_tag.operand_count != 2 or
            jump.operand_count != 1)
            return false;
        const marker_operand = try self.operand(marker, 0);
        const lhs = try self.operand(comparison, 0);
        const rhs = try self.operand(comparison, 1);
        const condition = try self.operand(comparison, 2);
        const destination = try self.operand(store, 0);
        const stored = try self.operand(store, 1);
        const tag_destination = try self.operand(store_tag, 0);
        const tag = try self.operand(store_tag, 1);
        const target = try self.operand(jump, 0);
        if (marker_operand.kind != .constant or condition.kind != .condition or
            destination.kind != .vm_reg or stored.kind != .instruction or stored.value != materialized_id or
            tag_destination.kind != .vm_reg or tag_destination.value != destination.value or tag.kind != .constant or
            (try self.constant(tag.value)).tagValue() != @as(u8, @intCast(lua_tag_boolean)) or target.kind != .block)
            return false;
        if ((try self.constant(marker_operand.value)).uintValue() == null or destination.value >= self.proto.max_stack_size)
            return false;
        _ = self.valueOperandEncoding(lhs) catch return false;
        _ = self.valueOperandEncoding(rhs) catch return false;
        const condition_value: snapshot_v1.IrCondition = @enumFromInt(@as(u8, @intCast(condition.value)));
        _ = comparisonOperation(condition_value) catch return false;
        if (inverted) {
            if (materialized.command != .sub_int or materialized.operand_count != 2)
                return false;
            const one = try self.operand(materialized, 0);
            const compared = try self.operand(materialized, 1);
            if (one.kind != .constant or compared.kind != .instruction or compared.value != block.start + 1)
                return false;
            if (((try self.constant(one.value)).intValue() orelse return false) != 1)
                return false;
        } else if (materialized.command != .cmp_any) {
            return false;
        }
        const target_block = try self.snapshot.irBlock(self.function, target.value);
        return target_block.kind.isCompilable() and !target_block.isEmpty();
    }

    fn supportsFallback(self: Context, block: snapshot_v1.IrBlock) Error!bool {
        return (try self.supportsArithmeticFallback(block)) or (try self.supportsComparisonFallback(block)) or
            (try self.supportsMaterializedComparisonFallback(block)) or
            (try self.supportsGenericIterationFallback(block)) or
            (try self.supportsSpecializedIpairsFallback(block)) or
            (try self.xnextPreparationPattern(block) != null) or
            (try self.isFastcallFallbackBlock(block)) or (try self.supportsOrdinaryCallFallback(block));
    }

    fn supportsOrdinaryCallFallback(self: Context, block: snapshot_v1.IrBlock) Error!bool {
        if (block.kind != .fallback or block.isEmpty() or block.finish < block.start + 3)
            return false;
        const saved_id = block.finish - 2;
        const saved = try self.instruction(saved_id);
        const call = try self.instruction(block.finish - 1);
        const jump = try self.instruction(block.finish);
        if (saved.command != .set_savedpc or saved.operand_count != 1 or
            call.command != .call or call.operand_count != 3 or
            jump.command != .jump or jump.operand_count != 1)
            return false;

        const saved_pc = self.savedPc(saved) catch return false;
        if (saved_pc == 0 or saved_pc > self.proto.code_count)
            return false;
        const call_word = try self.snapshot.bytecodeWord(self.proto, saved_pc - 1);
        if (@as(u8, @truncate(call_word)) != lop_call)
            return false;
        const destination = (call_word >> 8) & 0xff;
        const parameter_count = @as(i32, @intCast((call_word >> 16) & 0xff)) - 1;
        const result_count = @as(i32, @intCast((call_word >> 24) & 0xff)) - 1;
        if ((self.vmRegisterIndex(try self.operand(call, 0)) catch return false) != destination or
            (self.intConstant(try self.operand(call, 1)) catch return false) != parameter_count or
            (self.intConstant(try self.operand(call, 2)) catch return false) != result_count)
            return false;
        const target = try self.operand(jump, 0);
        if (target.kind != .block or target.value >= self.function.block_count)
            return false;
        const target_block = try self.snapshot.irBlock(self.function, target.value);
        if (!target_block.kind.isCompilable() or target_block.isEmpty())
            return false;

        var found_import = false;
        var instruction_id = block.start;
        while (instruction_id < saved_id) : (instruction_id += 1) {
            const instruction_value = try self.instruction(instruction_id);
            switch (instruction_value.command) {
                .nop, .load_tvalue, .store_tvalue, .check_safe_env, .interrupt, .fallback_getvarargs => {},
                .get_cached_import => {
                    if (found_import or instruction_value.operand_count != 4 or
                        (self.vmRegisterIndex(try self.operand(instruction_value, 0)) catch return false) != destination)
                        return false;
                    found_import = true;
                },
                else => return false,
            }
        }
        return found_import;
    }

    fn isOwnedSemanticTableFallbackBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
        if (block.kind != .fallback or block.isEmpty())
            return false;

        var source_block_id: u32 = 0;
        while (source_block_id < self.function.block_count) : (source_block_id += 1) {
            if (source_block_id == block_id)
                continue;
            const source = try self.snapshot.irBlock(self.function, source_block_id);
            if (!source.kind.isCompilable() or source.isEmpty())
                continue;

            if (try self.stringTablePattern(source)) |pattern|
                if (pattern.fallback == block_id)
                    return true;
            if (try self.genericTablePattern(source)) |pattern| {
                if (pattern.fallback == block_id)
                    return true;
            }

            var instruction_id = source.start;
            while (instruction_id <= source.finish) : (instruction_id += 1) {
                if (try self.inlineStringGetPatternAt(instruction_id, source)) |pattern|
                    if (pattern.fallback == block_id)
                        return true;
                if ((try self.instruction(instruction_id)).command != .load_tag)
                    continue;
                if (try self.inlineGenericTableSetPatternAt(instruction_id)) |pattern|
                    if (pattern.pattern.fallback == block_id)
                        return true;
            }
        }
        return false;
    }

    fn isOwnedDynamicLengthFallbackBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
        if (block.kind != .fallback or block.isEmpty())
            return false;

        var source_block_id: u32 = 0;
        while (source_block_id < self.function.block_count) : (source_block_id += 1) {
            if (source_block_id == block_id)
                continue;
            const source = try self.snapshot.irBlock(self.function, source_block_id);
            if (!source.kind.isCompilable() or source.isEmpty())
                continue;
            if (try self.dynamicLengthPattern(source)) |pattern|
                if (pattern.fallback == block_id)
                    return true;
        }
        return false;
    }

    fn isBypassedEmissionBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
        return (try self.isBypassedPlainTableNamecallBlock(block_id)) or
            (try self.isBypassedStringEqualityBlock(block_id)) or
            (try self.isBypassedStringLinearizedBlock(block_id, block)) or
            (try self.isBypassedGenericTableLinearizedBlock(block_id, block)) or
            (try self.isBypassedGlobalLinearizedBlock(block_id, block)) or
            (try self.isBypassedPowLinearizedBlock(block_id, block)) or
            (try self.isBypassedConstantArithmeticLinearizedBlock(block_id, block)) or
            (try self.isOwnedDynamicLengthFallbackBlock(block_id, block)) or
            (try self.isOwnedSemanticTableFallbackBlock(block_id, block)) or
            (try self.isBypassedXnextFastPreparationBlock(block_id)) or
            (try self.isBypassedSpecializedIpairsPublishBlock(block_id));
    }

    fn isBypassedXnextFastPreparationBlock(self: Context, block_id: u32) Error!bool {
        var source_id: u32 = 0;
        while (source_id < self.function.block_count) : (source_id += 1) {
            const source = try self.snapshot.irBlock(self.function, source_id);
            const pattern = (try self.xnextFastPreparationPattern(source)) orelse continue;
            if (pattern.fallback == block_id or pattern.publish == block_id)
                return true;
        }
        return false;
    }

    fn isFastcallFallbackBlock(self: Context, block: snapshot_v1.IrBlock) Error!bool {
        var block_id: u32 = 0;
        while (block_id < self.function.block_count) : (block_id += 1) {
            const candidate = try self.snapshot.irBlock(self.function, block_id);
            if (candidate.start == block.start and candidate.finish == block.finish and candidate.kind == block.kind)
                return self.isFastcallFallback(block_id, block);
        }
        return false;
    }

    fn emitInterrupt(
        self: Context,
        instruction_id: u32,
        instruction_value: snapshot_v1.IrInstruction,
    ) Error!void {
        const continuation = self.callContinuation(instruction_id) orelse return Error.UnsupportedControlFlow;
        try self.requireOperandCount(instruction_value, 1);
        const pc_operand = try self.operand(instruction_value, 0);
        if (pc_operand.kind != .constant)
            return Error.InvalidOperandType;
        const pc_constant = try self.constant(pc_operand.value);
        const pc = pc_constant.uintValue() orelse return Error.InvalidOperandType;
        const line = try self.sourceLine(pc);

        try self.emitExchangeContinuation(continuation.continuation_id);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.body.else_(self.allocator);
        try self.emitUnexpectedContinuationReturn();
        try self.body.end(self.allocator);

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(line));
        try self.body.call(self.allocator, self.interrupt);
        try self.body.localTee(self.allocator, self.status_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.emitClearContinuation(continuation.continuation_id);
        try self.emitReloadBase();
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.return_(self.allocator);
        try self.body.end(self.allocator);
    }

    fn emitJump(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 1);
        const target = try self.requireDispatchTarget(try self.operand(instruction_value, 0));
        try self.body.i32Const(self.allocator, @intCast(target));
        try self.body.localSet(self.allocator, self.dispatch_local);
        try self.body.branch(self.allocator, 1);
    }

    fn emitConditionalDispatch(self: Context, true_target: u32, false_target: u32) Error!void {
        try self.body.ifVoid(self.allocator);
        try self.body.i32Const(self.allocator, @intCast(true_target));
        try self.body.localSet(self.allocator, self.dispatch_local);
        try self.body.else_(self.allocator);
        try self.body.i32Const(self.allocator, @intCast(false_target));
        try self.body.localSet(self.allocator, self.dispatch_local);
        try self.body.end(self.allocator);
        try self.body.branch(self.allocator, 1);
    }

    fn emitJumpIfTruthy(self: Context, instruction_value: snapshot_v1.IrInstruction, invert: bool) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        const source = try self.operand(instruction_value, 0);
        _ = try self.vmRegisterIndex(source);
        const true_target = try self.requireCompiledTarget(try self.operand(instruction_value, 1));
        const false_target = try self.requireCompiledTarget(try self.operand(instruction_value, 2));
        try self.emitTValueTruthy(source);
        if (invert)
            try self.body.i32Eqz(self.allocator);
        try self.emitConditionalDispatch(true_target, false_target);
    }

    fn emitJumpEqualTag(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        const true_target = try self.requireCompiledTarget(try self.operand(instruction_value, 2));
        const false_target = try self.requireCompiledTarget(try self.operand(instruction_value, 3));
        try self.emitTagValue(try self.operand(instruction_value, 0));
        try self.emitTagValue(try self.operand(instruction_value, 1));
        try self.body.i32Eq(self.allocator);
        try self.emitConditionalDispatch(true_target, false_target);
    }

    fn emitJumpCompareInteger(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 5);
        const true_target = try self.requireCompiledTarget(try self.operand(instruction_value, 3));
        const false_target = try self.requireCompiledTarget(try self.operand(instruction_value, 4));
        try self.emitI32Value(try self.operand(instruction_value, 0));
        try self.emitI32Value(try self.operand(instruction_value, 1));
        try self.emitIntegerCondition(try self.conditionOperand(instruction_value, 2));
        try self.emitConditionalDispatch(true_target, false_target);
    }

    fn emitJumpEqualPointer(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        const true_target = try self.requireCompiledTarget(try self.operand(instruction_value, 2));
        const false_target = try self.requireCompiledTarget(try self.operand(instruction_value, 3));
        try self.emitPointerValue(try self.operand(instruction_value, 0));
        try self.emitPointerValue(try self.operand(instruction_value, 1));
        try self.body.i32Eq(self.allocator);
        try self.emitConditionalDispatch(true_target, false_target);
    }

    fn emitJumpCompareFloat(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 5);
        const true_target = try self.requireDispatchTarget(try self.operand(instruction_value, 3));
        const false_target = try self.requireDispatchTarget(try self.operand(instruction_value, 4));
        try self.emitF32Value(try self.operand(instruction_value, 0));
        try self.emitF32Value(try self.operand(instruction_value, 1));
        try self.emitFloatCondition(try self.conditionOperand(instruction_value, 2));
        try self.emitConditionalDispatch(true_target, false_target);
    }

    fn emitNumericCondition(self: Context, condition: snapshot_v1.IrCondition) Error!void {
        switch (condition) {
            .equal => try self.body.f64Eq(self.allocator),
            .not_equal => try self.body.f64Ne(self.allocator),
            .less => try self.body.f64Lt(self.allocator),
            .not_less => {
                try self.body.f64Lt(self.allocator);
                try self.body.i32Eqz(self.allocator);
            },
            .less_equal => try self.body.f64Le(self.allocator),
            .not_less_equal => {
                try self.body.f64Le(self.allocator);
                try self.body.i32Eqz(self.allocator);
            },
            .greater => try self.body.f64Gt(self.allocator),
            .not_greater => {
                try self.body.f64Gt(self.allocator);
                try self.body.i32Eqz(self.allocator);
            },
            .greater_equal => try self.body.f64Ge(self.allocator),
            .not_greater_equal => {
                try self.body.f64Ge(self.allocator);
                try self.body.i32Eqz(self.allocator);
            },
            .unsigned_less, .unsigned_less_equal, .unsigned_greater, .unsigned_greater_equal => return Error.UnsupportedCondition,
        }
    }

    fn emitJumpCompareNumber(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 5);
        const condition_operand = try self.operand(instruction_value, 2);
        if (condition_operand.kind != .condition)
            return Error.InvalidOperandType;
        const condition: snapshot_v1.IrCondition = @enumFromInt(@as(u8, @intCast(condition_operand.value)));
        const true_target = try self.requireDispatchTarget(try self.operand(instruction_value, 3));
        const false_target = try self.requireDispatchTarget(try self.operand(instruction_value, 4));

        try self.body.i32Const(self.allocator, @intCast(true_target));
        try self.body.i32Const(self.allocator, @intCast(false_target));
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.emitNumericCondition(condition);
        try self.body.select(self.allocator);
        try self.body.localSet(self.allocator, self.dispatch_local);
        try self.body.branch(self.allocator, 1);
    }

    fn emitJumpFornLoopCondition(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 5);
        const true_target = try self.requireCompiledTarget(try self.operand(instruction_value, 3));
        const false_target = try self.requireCompiledTarget(try self.operand(instruction_value, 4));

        // step > 0 ? index <= limit : limit <= index. Ordered comparisons preserve the
        // upstream behavior for NaN: a NaN index/limit exits, and a NaN step selects the
        // non-positive-step comparison.
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.body.f64Le(self.allocator);
        try self.emitF64Value(try self.operand(instruction_value, 1));
        try self.emitF64Value(try self.operand(instruction_value, 0));
        try self.body.f64Le(self.allocator);
        try self.emitF64Value(try self.operand(instruction_value, 2));
        try self.body.f64Const(self.allocator, 0.0);
        try self.body.f64Gt(self.allocator);
        try self.body.select(self.allocator);
        try self.emitConditionalDispatch(true_target, false_target);
    }

    fn emitReturn(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        const source = try self.operand(instruction_value, 0);
        const return_count_operand = try self.operand(instruction_value, 1);
        if (return_count_operand.kind != .constant)
            return Error.InvalidReturnCount;
        const return_count = (try self.constant(return_count_operand.value)).intValue() orelse return Error.InvalidReturnCount;
        // The pinned builder encodes LUA_MULTRET as exactly -1. Other negative values are malformed.
        if (return_count < -1)
            return Error.InvalidReturnCount;

        const source_register: u32 = if (return_count == 0)
            0
        else blk: {
            const register = try self.vmRegisterIndex(source);
            if (return_count > 0) {
                const return_count_u32: u32 = @intCast(return_count);
                if (return_count_u32 > @as(u32, self.proto.max_stack_size) - register)
                    return Error.InvalidReturnCount;
            }
            break :blk register;
        };

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(source_register));
        try self.body.i32Const(self.allocator, @intCast(return_count));
        try self.body.call(self.allocator, self.return_);
        try self.emitStatusReturn(status_ok);
    }

    fn emitDupClosure(self: Context, instruction_id: u32) Error!void {
        const pattern = try dupClosurePattern(self.snapshot, self.function, self.proto, instruction_id);
        switch (pattern) {
            .closed => |closed| {
                const global_child_id = std.math.add(u32, self.function_id_base, closed.child_proto_id) catch
                    return Error.ResourceLimit;
                try self.body.localGet(self.allocator, 0);
                try self.body.i32Const(self.allocator, @intCast(closed.destination));
                try self.body.i32Const(self.allocator, @intCast(global_child_id));
                try self.body.call(self.allocator, self.dupclosure orelse return Error.UnsupportedCommand);
            },
            .captured => |captured| {
                const global_child_id = std.math.add(u32, self.function_id_base, captured.child_proto_id) catch
                    return Error.ResourceLimit;
                var capture_index: u32 = 0;
                while (capture_index < captured.capture_count) : (capture_index += 1) {
                    const capture = try markerCapture(self.snapshot, self.function, self.proto, captured.marker_start + capture_index, false);
                    try self.emitCaptureCall(captured.destination, global_child_id, capture_index, capture, capture_index + 1 == captured.capture_count);
                }
            },
        }
        // Closure allocation runs GC and can relocate the active stack.
        try self.emitReloadBase();
    }

    fn callContinuation(self: Context, instruction_id: u32) ?CallContinuation {
        for (self.call_continuations) |continuation| {
            if (continuation.instruction_id == instruction_id)
                return continuation;
        }
        return null;
    }

    fn emitExchangeContinuation(self: Context, next_id: u32) Error!void {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(next_id));
        try self.body.call(self.allocator, self.exchange_continuation orelse return Error.UnsupportedCommand);
    }

    fn emitUnexpectedContinuationReturn(self: Context) Error!void {
        try self.body.i32Const(self.allocator, status_internal_error);
        try self.body.return_(self.allocator);
    }

    fn emitClearContinuation(self: Context, expected_id: u32) Error!void {
        try self.emitExchangeContinuation(0);
        try self.body.i32Const(self.allocator, @intCast(expected_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.body.else_(self.allocator);
        try self.emitUnexpectedContinuationReturn();
        try self.body.end(self.allocator);
    }

    fn emitCall(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        const continuation = self.callContinuation(instruction_id);
        try self.requireOperandCount(instruction_value, 3);
        if (instruction_id == 0 or (try self.instruction(instruction_id - 1)).command != .set_savedpc)
            return Error.UnsupportedControlFlow;
        _ = try self.savedPc(try self.instruction(instruction_id - 1));

        const function_register = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
        const parameter_operand = try self.operand(instruction_value, 1);
        const result_operand = try self.operand(instruction_value, 2);
        if (parameter_operand.kind != .constant or result_operand.kind != .constant)
            return Error.InvalidOperandType;
        const parameter_count = (try self.constant(parameter_operand.value)).intValue() orelse return Error.InvalidOperandType;
        const result_count = (try self.constant(result_operand.value)).intValue() orelse return Error.InvalidOperandType;
        // The pinned builder encodes dynamic arguments and LUA_MULTRET results as exactly -1.
        if (parameter_count < -1 or result_count < -1)
            return Error.UnsupportedControlFlow;
        if (parameter_count >= 0) {
            const parameter_count_u32: u32 = @intCast(parameter_count);
            if (parameter_count_u32 >= @as(u32, self.proto.max_stack_size) - function_register)
                return Error.UnsupportedControlFlow;
        }
        if (result_count >= 0) {
            const result_count_u32: u32 = @intCast(result_count);
            if (result_count_u32 > @as(u32, self.proto.max_stack_size) - function_register)
                return Error.UnsupportedControlFlow;
        }

        if (continuation) |resumable| {
            try self.emitExchangeContinuation(resumable.continuation_id);
            try self.body.i32Eqz(self.allocator);
            try self.body.ifVoid(self.allocator);
            try self.body.else_(self.allocator);
            try self.emitUnexpectedContinuationReturn();
            try self.body.end(self.allocator);
        }

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(function_register));
        try self.body.i32Const(self.allocator, parameter_count);
        try self.body.i32Const(self.allocator, result_count);
        try self.body.call(self.allocator, self.call orelse return Error.UnsupportedCommand);
        try self.body.localTee(self.allocator, self.status_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        if (continuation) |resumable|
            try self.emitClearContinuation(resumable.continuation_id);
        try self.emitReloadBase();
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.return_(self.allocator);
        try self.body.end(self.allocator);
    }

    fn emitPrepVarargs(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 2);
        if (!self.function.variadic or !self.proto.is_vararg)
            return Error.UnsupportedVariadicFunction;

        const pc_operand = try self.operand(instruction_value, 0);
        const parameter_operand = try self.operand(instruction_value, 1);
        if (pc_operand.kind != .constant or parameter_operand.kind != .constant)
            return Error.InvalidOperandType;
        _ = (try self.constant(pc_operand.value)).uintValue() orelse return Error.InvalidOperandType;
        const parameter_count = (try self.constant(parameter_operand.value)).intValue() orelse return Error.InvalidOperandType;
        if (parameter_count < 0 or parameter_count != @as(i32, self.proto.num_params))
            return Error.UnsupportedVariadicFunction;

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, parameter_count);
        try self.body.call(self.allocator, self.prep_varargs orelse return Error.UnsupportedCommand);
        // PREPVARARGS checks/grows the stack and always rewires the active frame base.
        try self.emitReloadBase();
    }

    fn emitGetVarargs(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 3);
        if (!self.function.variadic or !self.proto.is_vararg)
            return Error.UnsupportedVariadicFunction;

        const pc_operand = try self.operand(instruction_value, 0);
        if (pc_operand.kind != .constant)
            return Error.InvalidOperandType;
        _ = (try self.constant(pc_operand.value)).uintValue() orelse return Error.InvalidOperandType;

        const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
        const count_operand = try self.operand(instruction_value, 2);
        if (count_operand.kind != .constant)
            return Error.InvalidOperandType;
        const count = (try self.constant(count_operand.value)).intValue() orelse return Error.InvalidOperandType;
        if (count < -1)
            return Error.UnsupportedVariadicFunction;

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(destination));
        if (count == -1) {
            try self.body.call(self.allocator, self.get_varargs_multret orelse return Error.UnsupportedCommand);
            // The multret helper checks/grows the stack and updates L->top.
            try self.emitReloadBase();
        } else {
            const count_u32: u32 = @intCast(count);
            if (count_u32 > @as(u32, self.proto.max_stack_size) - destination)
                return Error.UnsupportedVariadicFunction;
            try self.body.i32Const(self.allocator, count);
            try self.body.call(self.allocator, self.get_varargs_fixed orelse return Error.UnsupportedCommand);
        }
    }

    fn vmString(self: Context, operand_value: snapshot_v1.IrOperand) Error![]const u8 {
        if (operand_value.kind != .vm_const)
            return Error.InvalidOperandType;
        const value = try self.snapshot.vmConstant(self.proto, operand_value.value);
        if (value.kind != .string)
            return Error.InvalidOperandType;
        return self.snapshot.string(value.payload0);
    }

    fn builtinIdentityMatches(id: u32, object: []const u8, name: []const u8) bool {
        const expected_object: []const u8, const expected_name: []const u8 = switch (id) {
            1 => .{ "", "assert" },
            2 => .{ "math", "abs" },
            3 => .{ "math", "acos" },
            4 => .{ "math", "asin" },
            5 => .{ "math", "atan2" },
            6 => .{ "math", "atan" },
            7 => .{ "math", "ceil" },
            8 => .{ "math", "cosh" },
            9 => .{ "math", "cos" },
            10 => .{ "math", "deg" },
            11 => .{ "math", "exp" },
            12 => .{ "math", "floor" },
            13 => .{ "math", "fmod" },
            14 => .{ "math", "frexp" },
            15 => .{ "math", "ldexp" },
            16 => .{ "math", "log10" },
            17 => .{ "math", "log" },
            18 => .{ "math", "max" },
            19 => .{ "math", "min" },
            20 => .{ "math", "modf" },
            21 => .{ "math", "pow" },
            22 => .{ "math", "rad" },
            23 => .{ "math", "sinh" },
            24 => .{ "math", "sin" },
            25 => .{ "math", "sqrt" },
            26 => .{ "math", "tanh" },
            27 => .{ "math", "tan" },
            28 => .{ "bit32", "arshift" },
            29 => .{ "bit32", "band" },
            30 => .{ "bit32", "bnot" },
            31 => .{ "bit32", "bor" },
            32 => .{ "bit32", "bxor" },
            33 => .{ "bit32", "btest" },
            34 => .{ "bit32", "extract" },
            35 => .{ "bit32", "lrotate" },
            36 => .{ "bit32", "lshift" },
            37 => .{ "bit32", "replace" },
            38 => .{ "bit32", "rrotate" },
            39 => .{ "bit32", "rshift" },
            40 => .{ "", "type" },
            41 => .{ "string", "byte" },
            42 => .{ "string", "char" },
            43 => .{ "string", "len" },
            44 => .{ "", "typeof" },
            45 => .{ "string", "sub" },
            46 => .{ "math", "clamp" },
            47 => .{ "math", "sign" },
            48 => .{ "math", "round" },
            49 => .{ "", "rawset" },
            50 => .{ "", "rawget" },
            51 => .{ "", "rawequal" },
            52 => .{ "table", "insert" },
            53 => if (std.mem.eql(u8, object, "table")) .{ "table", "unpack" } else .{ "", "unpack" },
            54 => .{ "vector", "create" },
            55 => .{ "bit32", "countlz" },
            56 => .{ "bit32", "countrz" },
            57 => .{ "", "select" },
            58 => .{ "", "rawlen" },
            59 => .{ "bit32", "extract" },
            60 => .{ "", "getmetatable" },
            61 => .{ "", "setmetatable" },
            62 => .{ "", "tonumber" },
            63 => .{ "", "tostring" },
            64 => .{ "bit32", "byteswap" },
            65 => .{ "buffer", "readi8" },
            66 => .{ "buffer", "readu8" },
            67 => if (std.mem.eql(u8, name, "writeu8")) .{ "buffer", "writeu8" } else .{ "buffer", "writei8" },
            68 => .{ "buffer", "readi16" },
            69 => .{ "buffer", "readu16" },
            70 => if (std.mem.eql(u8, name, "writeu16")) .{ "buffer", "writeu16" } else .{ "buffer", "writei16" },
            71 => .{ "buffer", "readi32" },
            72 => .{ "buffer", "readu32" },
            73 => if (std.mem.eql(u8, name, "writeu32")) .{ "buffer", "writeu32" } else .{ "buffer", "writei32" },
            74 => .{ "buffer", "readf32" },
            75 => .{ "buffer", "writef32" },
            76 => .{ "buffer", "readf64" },
            77 => .{ "buffer", "writef64" },
            78 => .{ "vector", "magnitude" },
            79 => .{ "vector", "normalize" },
            80 => .{ "vector", "cross" },
            81 => .{ "vector", "dot" },
            82 => .{ "vector", "floor" },
            83 => .{ "vector", "ceil" },
            84 => .{ "vector", "abs" },
            85 => .{ "vector", "sign" },
            86 => .{ "vector", "clamp" },
            87 => .{ "vector", "min" },
            88 => .{ "vector", "max" },
            89 => .{ "math", "lerp" },
            90 => .{ "vector", "lerp" },
            91 => .{ "math", "isnan" },
            92 => .{ "math", "isinf" },
            93 => .{ "math", "isfinite" },
            94 => .{ "integer", "create" },
            95 => .{ "integer", "tonumber" },
            96 => .{ "integer", "neg" },
            97 => .{ "integer", "add" },
            98 => .{ "integer", "sub" },
            99 => .{ "integer", "mul" },
            100 => .{ "integer", "div" },
            101 => .{ "integer", "min" },
            102 => .{ "integer", "max" },
            103 => .{ "integer", "rem" },
            104 => .{ "integer", "idiv" },
            105 => .{ "integer", "udiv" },
            106 => .{ "integer", "urem" },
            107 => .{ "integer", "mod" },
            108 => .{ "integer", "clamp" },
            109 => .{ "integer", "band" },
            110 => .{ "integer", "bor" },
            111 => .{ "integer", "bnot" },
            112 => .{ "integer", "bxor" },
            113 => .{ "integer", "lt" },
            114 => .{ "integer", "le" },
            115 => .{ "integer", "ult" },
            116 => .{ "integer", "ule" },
            117 => .{ "integer", "gt" },
            118 => .{ "integer", "ge" },
            119 => .{ "integer", "ugt" },
            120 => .{ "integer", "uge" },
            121 => .{ "integer", "lshift" },
            122 => .{ "integer", "rshift" },
            123 => .{ "integer", "arshift" },
            124 => .{ "integer", "lrotate" },
            125 => .{ "integer", "rrotate" },
            126 => .{ "integer", "extract" },
            127 => .{ "integer", "btest" },
            128 => .{ "integer", "countrz" },
            129 => .{ "integer", "countlz" },
            130 => .{ "integer", "bswap" },
            131 => .{ "buffer", "readinteger" },
            132 => .{ "buffer", "writeinteger" },
            else => return false,
        };
        return std.mem.eql(u8, object, expected_object) and std.mem.eql(u8, name, expected_name);
    }

    fn builtinFallback(self: Context, pc: u32) Error!?BuiltinFallback {
        var fast_pc: u32 = undefined;
        var word: u32 = undefined;
        var opcode: u8 = undefined;
        if (pc >= 1) {
            const candidate = try self.snapshot.bytecodeWord(self.proto, pc - 1);
            const candidate_opcode: u8 = @truncate(candidate);
            if (candidate_opcode == lop_fastcall1) {
                fast_pc = pc - 1;
                word = candidate;
                opcode = candidate_opcode;
            } else if (pc >= 2) {
                const two_word = try self.snapshot.bytecodeWord(self.proto, pc - 2);
                const two_word_opcode: u8 = @truncate(two_word);
                if (two_word_opcode != lop_fastcall2 and two_word_opcode != lop_fastcall2k and
                    two_word_opcode != lop_fastcall3)
                    return null;
                fast_pc = pc - 2;
                word = two_word;
                opcode = two_word_opcode;
            } else return null;
        } else return null;

        const id = (word >> 8) & 0xff;
        var registers = [_]u32{ snapshot_v1.no_id, snapshot_v1.no_id, snapshot_v1.no_id };
        registers[0] = (word >> 16) & 0xff;
        var argument_count: u8 = 1;
        if (opcode == lop_fastcall2 or opcode == lop_fastcall2k or opcode == lop_fastcall3) {
            const aux = try self.snapshot.bytecodeWord(self.proto, fast_pc + 1);
            argument_count = if (opcode == lop_fastcall3) 3 else 2;
            if (opcode != lop_fastcall2k)
                registers[1] = aux & 0xff;
            if (opcode == lop_fastcall3)
                registers[2] = (aux >> 8) & 0xff;
        }

        var import_id: ?u32 = null;
        var found_call = false;
        var cursor = pc;
        const limit = @min(self.proto.code_count, std.math.add(u32, pc, 12) catch self.proto.code_count);
        while (cursor < limit) : (cursor += 1) {
            const fallback_word = try self.snapshot.bytecodeWord(self.proto, cursor);
            const fallback_opcode: u8 = @truncate(fallback_word);
            if (fallback_opcode == lop_getimport)
                import_id = fallback_word >> 16;
            if (fallback_opcode == lop_call) {
                found_call = true;
                break;
            }
        }
        if (!found_call or import_id == null)
            return null;

        const import = try self.snapshot.vmConstant(self.proto, import_id.?);
        if (import.kind != .import or import.payload1 == 0 or import.payload1 > 2)
            return null;
        const object_item = try self.snapshot.vmConstantItem(import.payload0);
        const name_item = try self.snapshot.vmConstantItem(import.payload0 + import.payload1 - 1);
        if (object_item.value != snapshot_v1.no_id or name_item.value != snapshot_v1.no_id)
            return null;
        const object_constant = try self.snapshot.vmConstant(self.proto, object_item.key);
        const name_constant = try self.snapshot.vmConstant(self.proto, name_item.key);
        if (object_constant.kind != .string or name_constant.kind != .string)
            return null;
        const object = if (import.payload1 == 1) "" else try self.snapshot.string(object_constant.payload0);
        const name = try self.snapshot.string(name_constant.payload0);
        if (!builtinIdentityMatches(id, object, name))
            return null;
        return .{
            .id = id,
            .name = name,
            .pc = pc,
            .argument_registers = registers,
            .argument_count = argument_count,
        };
    }

    fn emitSingleGlobalImport(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
        const import_operand = try self.operand(instruction_value, 1);
        const descriptor = try self.operand(instruction_value, 2);
        const pc_operand = try self.operand(instruction_value, 3);
        if (import_operand.kind != .vm_const or descriptor.kind != .constant or pc_operand.kind != .constant)
            return Error.InvalidOperandType;

        const import = try self.snapshot.vmConstant(self.proto, import_operand.value);
        if (import.kind != .import or import.payload1 == 0 or import.payload1 > 3)
            return Error.UnsupportedControlFlow;
        const encoded = (try self.constant(descriptor.value)).importValue() orelse return Error.InvalidOperandType;
        var keys = [_]StringKeyPool.Entry{undefined} ** 3;
        var expected = import.payload1 << 30;
        var index: u32 = 0;
        while (index < import.payload1) : (index += 1) {
            const item = try self.snapshot.vmConstantItem(import.payload0 + index);
            if (item.value != snapshot_v1.no_id or item.key >= (1 << 10))
                return Error.UnsupportedControlFlow;
            const shift: u5 = @intCast(20 - index * 10);
            expected |= item.key << shift;
            keys[index] = try self.string_keys.intern(
                self.allocator,
                try self.vmString(.{ .kind = .vm_const, .value = item.key }),
            );
        }
        if (encoded != expected)
            return Error.UnsupportedControlFlow;
        const pc = (try self.constant(pc_operand.value)).uintValue() orelse return Error.InvalidOperandType;

        // Decode the complete one-to-three-key import into ordinary semantic lookups. This does
        // not consume or trust the optimizer's environment cache: unsafe environments and
        // metatable-backed intermediate objects observe the same luaV boundaries as the bytecode
        // fallback, without carrying bytecode or an import interpreter into the guest.
        try self.emitPcLocation(pc);
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(destination));
        try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(keys[0].offset));
        try self.body.i32Const(self.allocator, @intCast(keys[0].length));
        try self.body.call(self.allocator, self.get_global orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
        index = 1;
        while (index < import.payload1) : (index += 1) {
            try self.body.localGet(self.allocator, 0);
            try self.body.i32Const(self.allocator, @intCast(destination));
            try self.body.i32Const(self.allocator, @intCast(destination));
            try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(keys[index].offset));
            try self.body.i32Const(self.allocator, @intCast(keys[index].length));
            try self.body.call(self.allocator, self.table_get_string orelse return Error.UnsupportedCommand);
            try self.emitReloadBase();
        }
    }

    fn staticRequireTarget(self: Context, start: u32, block: snapshot_v1.IrBlock) Error!?StaticRequirePattern {
        const package = self.static_package orelse return null;
        const end = std.math.add(u32, start, 6) catch return Error.ResourceLimit;
        if (start < block.start or end > block.finish)
            return null;

        const marker = try self.instruction(start);
        const get_import = try self.instruction(start + 1);
        const load_path = try self.instruction(start + 2);
        const store_path = try self.instruction(start + 3);
        const interrupt = try self.instruction(start + 4);
        const saved_pc = try self.instruction(start + 5);
        const call = try self.instruction(start + 6);
        if ((marker.command != .nop and marker.command != .check_safe_env) or
            get_import.command != .get_cached_import or load_path.command != .load_tvalue or
            store_path.command != .store_tvalue or interrupt.command != .interrupt or
            saved_pc.command != .set_savedpc or call.command != .call)
            return null;
        if (!try isRequireImportInstruction(self.snapshot, self.function, self.proto, get_import))
            return null;
        if (marker.command == .nop) {
            const follows_root_prep = start == block.start + 1 and
                (try self.instruction(start - 1)).command == .fallback_prepvarargs;
            if ((start != block.start and !follows_root_prep) or
                (block.flags & (1 << 0)) == 0 or marker.operand_count != 0)
                return Error.UnsupportedControlFlow;
        } else {
            try self.requireOperandCount(marker, 1);
            const failure = try self.operand(marker, 0);
            if (failure.kind != .vm_exit)
                return Error.UnsupportedControlFlow;
        }

        try self.requireOperandCount(get_import, 4);
        const destination = try self.vmRegisterIndex(try self.operand(get_import, 0));
        const import_pc = try self.operand(get_import, 3);
        if (import_pc.kind != .constant or (try self.constant(import_pc.value)).uintValue() == null)
            return Error.InvalidOperandType;

        try self.requireOperandCount(load_path, 3);
        const path_operand = try self.operand(load_path, 0);
        const path = try self.vmString(path_operand);
        const load_offset = try self.operand(load_path, 1);
        const load_tag = try self.operand(load_path, 2);
        if (load_offset.kind != .constant or (try self.constant(load_offset.value)).intValue() != 0 or
            load_tag.kind != .constant or (try self.constant(load_tag.value)).tagValue() != lua_tag_string)
            return Error.UnsupportedControlFlow;

        try self.requireOperandCount(store_path, 2);
        const argument = try self.vmRegisterIndex(try self.operand(store_path, 0));
        const stored = try self.operand(store_path, 1);
        if (argument != destination + 1 or stored.kind != .instruction or stored.value != start + 2)
            return Error.UnsupportedControlFlow;

        try self.requireOperandCount(interrupt, 1);
        const interrupt_pc = try self.operand(interrupt, 0);
        if (interrupt_pc.kind != .constant or (try self.constant(interrupt_pc.value)).uintValue() == null)
            return Error.InvalidOperandType;
        _ = try self.savedPc(saved_pc);

        try self.requireOperandCount(call, 3);
        if (try self.vmRegisterIndex(try self.operand(call, 0)) != destination)
            return Error.UnsupportedControlFlow;
        const parameter_count = try self.operand(call, 1);
        const result_count = try self.operand(call, 2);
        if (parameter_count.kind != .constant or result_count.kind != .constant or
            (try self.constant(parameter_count.value)).intValue() != 1 or
            (try self.constant(result_count.value)).intValue() != 1)
            return Error.UnsupportedControlFlow;

        const target = package.moduleByName(path) orelse return Error.UnsupportedControlFlow;
        return .{ .end = end, .interrupt_id = start + 4, .destination = destination, .module_id = target.id };
    }

    fn emitStaticRequire(self: Context, interrupt_id: u32, destination: u32, module_id: u32) Error!void {
        // The source CALL cluster carries its ordinary interrupt/fuel safepoint. Static resolution
        // replaces import lookup and dispatch, not the observable interrupt boundary.
        try self.emitInterrupt(interrupt_id, try self.instruction(interrupt_id));
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(destination));
        try self.body.i32Const(self.allocator, @intCast(module_id));
        try self.body.call(self.allocator, self.require_static orelse return Error.UnsupportedCommand);
        try self.body.localTee(self.allocator, self.status_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.emitReloadBase();
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.return_(self.allocator);
        try self.body.end(self.allocator);
    }

    fn isTableInsertAppendSafeEnv(self: Context, instruction_id: u32) Error!bool {
        const commands = [_]snapshot_v1.IrCommand{
            .check_safe_env,
            .nop,
            .nop,
            .nop,
            .nop,
        };
        if (!try self.commandRangeMatches(instruction_id, &commands))
            return false;

        const guard = try self.instruction(instruction_id);
        if (guard.operand_count != 1 or (try self.operand(guard, 0)).kind != .vm_exit)
            return false;

        const append_start = instruction_id + @as(u32, @intCast(commands.len));
        const append = (try self.tableInsertAppendPatternAt(append_start)) orelse return false;
        self.requireSingleCompilableBlockRange(instruction_id, append.finish) catch return false;
        return true;
    }

    fn emitStatusCheckedCall(self: Context, helper: wasm.FunctionRef) Error!void {
        try self.body.call(self.allocator, helper);
        try self.body.localTee(self.allocator, self.status_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.emitReloadBase();
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.return_(self.allocator);
        try self.body.end(self.allocator);
    }

    fn emitSafeEnvCheck(self: Context, instruction_id: u32) Error!void {
        const instruction_value = try self.instruction(instruction_id);
        try self.requireOperandCount(instruction_value, 1);
        if ((try self.operand(instruction_value, 0)).kind != .vm_exit)
            return Error.InvalidOperandType;
        try self.body.localGet(self.allocator, 0);
        try self.emitStatusCheckedCall(self.check_safe_env orelse return Error.UnsupportedCommand);
    }

    fn emitAdjustStackConstant(self: Context, destination: u32, count: u32) Error!void {
        const end = std.math.add(u32, destination, count) catch return Error.ResourceLimit;
        if (end > self.proto.max_stack_size)
            return Error.ResourceLimit;
        try self.body.localGet(self.allocator, 0);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Const(self.allocator, @intCast(end * tvalue_size));
        try self.body.opcode(self.allocator, 0x6a); // i32.add
        try self.body.i32Store(self.allocator, 2, lua_state_top_offset);
    }

    fn emitAdjustStackDynamic(self: Context, destination: u32) Error!void {
        if (destination >= self.proto.max_stack_size)
            return Error.ResourceLimit;
        try self.body.localGet(self.allocator, 0);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Const(self.allocator, @intCast(destination * tvalue_size));
        try self.body.opcode(self.allocator, 0x6a); // i32.add
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.i32Const(self.allocator, @intCast(tvalue_size));
        try self.body.opcode(self.allocator, 0x6c); // i32.mul
        try self.body.opcode(self.allocator, 0x6a); // i32.add
        try self.body.i32Store(self.allocator, 2, lua_state_top_offset);
    }

    fn emitAdjustStackToTop(self: Context) Error!void {
        try self.body.localGet(self.allocator, 0);
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Load(self.allocator, 2, lua_state_ci_offset);
        try self.body.i32Load(self.allocator, 2, callinfo_top_offset);
        try self.body.i32Store(self.allocator, 2, lua_state_top_offset);
    }

    fn emitDirectFastcall(self: Context, instruction_value: snapshot_v1.IrInstruction) Error!void {
        try self.requireOperandCount(instruction_value, 4);
        const builtin_operand = try self.operand(instruction_value, 0);
        if (builtin_operand.kind != .constant)
            return Error.InvalidOperandType;
        const builtin_id = (try self.constant(builtin_operand.value)).uintValue() orelse return Error.InvalidOperandType;
        if (builtin_id >= 256)
            return Error.InvalidOperandType;
        const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
        const source = try self.vmRegisterIndex(try self.operand(instruction_value, 2));
        const result_count = try self.intConstant(try self.operand(instruction_value, 3));
        if (result_count < 0 or @as(u32, @intCast(result_count)) > @as(u32, self.proto.max_stack_size) - destination)
            return Error.InvalidOperandType;

        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(builtin_id));
        try self.body.i32Const(self.allocator, @intCast(destination));
        try self.body.i32Const(self.allocator, @intCast(source));
        try self.body.i32Const(self.allocator, @bitCast(lbf_operand_none));
        try self.body.i32Const(self.allocator, @bitCast(lbf_operand_none));
        try self.body.i32Const(self.allocator, result_count);
        try self.body.i32Const(self.allocator, 1);
        try self.body.call(self.allocator, self.fastcall orelse return Error.UnsupportedCommand);
        try self.body.localSet(self.allocator, self.status_local);
        try self.emitReloadBase();
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.i32Const(self.allocator, result_count);
        try self.body.opcode(self.allocator, 0x47); // i32.ne
        try self.emitInternalErrorIf();
    }

    fn emitFastcallCluster(self: Context, pattern: FastcallPattern) Error!void {
        const saved_id = pattern.start + @intFromBool((try self.instruction(pattern.start)).command == .check_safe_env);
        try self.emitSavedPcLocation(try self.instruction(saved_id));
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.builtin_id));
        try self.body.i32Const(self.allocator, @intCast(pattern.destination));
        try self.body.i32Const(self.allocator, @intCast(pattern.source));
        try self.body.i32Const(self.allocator, @bitCast(pattern.argument_two));
        try self.body.i32Const(self.allocator, @bitCast(pattern.argument_three));
        try self.body.i32Const(self.allocator, pattern.result_count);
        try self.body.i32Const(self.allocator, pattern.parameter_count);
        try self.body.call(self.allocator, self.fastcall orelse return Error.UnsupportedCommand);
        try self.body.localSet(self.allocator, self.status_local);
        try self.emitReloadBase();
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.i32Const(self.allocator, 0);
        try self.body.opcode(self.allocator, 0x48); // i32.lt_s
        try self.body.ifVoid(self.allocator);
        try self.body.i32Const(self.allocator, @intCast(pattern.fallback));
        try self.body.localSet(self.allocator, self.dispatch_local);
        try self.body.else_(self.allocator);
        if (pattern.result_count == -1) {
            try self.emitAdjustStackDynamic(pattern.destination);
        } else if (pattern.finish > pattern.start and
            (try self.instruction(pattern.finish - 1)).command == ir_cmd_adjust_stack_to_top)
        {
            try self.emitAdjustStackToTop();
        }
        try self.body.i32Const(self.allocator, @intCast(pattern.fast_target));
        try self.body.localSet(self.allocator, self.dispatch_local);
        try self.body.end(self.allocator);
        try self.body.branch(self.allocator, 1);
    }

    fn isFastcallFallback(self: Context, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
        if (block.kind != .fallback or block.isEmpty())
            return false;
        var source_id: u32 = 0;
        while (source_id < self.function.block_count) : (source_id += 1) {
            const source = try self.snapshot.irBlock(self.function, source_id);
            if (!source.kind.isCompilable() or source.isEmpty())
                continue;
            var instruction_id = source.start;
            while (instruction_id <= source.finish) : (instruction_id += 1)
                if (try self.fastcallPatternAt(instruction_id, source)) |pattern|
                    if (pattern.fallback == block_id)
                        return true;
        }
        return false;
    }

    fn emitFastcallFallbackBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock) Error!void {
        try self.body.localGet(self.allocator, self.dispatch_local);
        try self.body.i32Const(self.allocator, @intCast(block_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        const terminated = try self.emitInstructionRange(block.start, block.finish, block);
        if (!terminated)
            return Error.InvalidBlockTermination;
        try self.body.end(self.allocator);
    }

    fn emitLibm(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        if (instruction_value.operand_count != 2 and instruction_value.operand_count != 3)
            return Error.InvalidOperandCount;
        const bfid = try self.operand(instruction_value, 0);
        if (bfid.kind != .constant)
            return Error.InvalidOperandType;
        const builtin_id = (try self.constant(bfid.value)).uintValue() orelse return Error.InvalidOperandType;
        const binary = switch (builtin_id) {
            5, 13, 15, 21 => true,
            3, 4, 6, 8, 9, 11, 16, 17, 23, 24, 26, 27, 256 => false,
            else => return Error.InvalidOperandType,
        };
        if (binary != (instruction_value.operand_count == 3))
            return Error.InvalidOperandCount;
        try self.body.i32Const(self.allocator, @intCast(builtin_id));
        try self.emitF64Value(try self.operand(instruction_value, 1));
        if (binary) {
            const second = try self.operand(instruction_value, 2);
            if (builtin_id == 15) {
                try self.emitI32Value(second);
                try self.body.opcode(self.allocator, 0xb7); // f64.convert_i32_s
            } else {
                try self.emitF64Value(second);
            }
        } else {
            try self.body.f64Const(self.allocator, 0);
        }
        try self.body.call(self.allocator, self.libm orelse return Error.UnsupportedCommand);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitStringLen(self: Context, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
        const pattern = (try self.stringLengthPattern(instruction_id)) orelse return Error.UnsupportedControlFlow;
        try self.requireOperandCount(instruction_value, 1);
        const pointer = try self.operand(instruction_value, 0);
        if (pointer.kind != .instruction or
            (try self.instruction(pointer.value)).command != .load_pointer)
            return Error.InvalidOperandType;
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Load(self.allocator, 2, pattern.source * tvalue_size);
        try self.body.i32Load(self.allocator, 2, tstring_len_offset);
        try self.emitInstructionResultSet(instruction_id);
    }

    fn emitTypeName(self: Context, pattern: TypeNamePattern) Error!void {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.destination));
        try self.body.i32Const(self.allocator, @intCast(pattern.source));
        try self.body.i32Const(self.allocator, @intCast(pattern.custom));
        try self.emitStatusCheckedCall(self.type_name orelse return Error.UnsupportedCommand);
    }

    fn emitInstruction(self: Context, instruction_id: u32, block_kind: snapshot_v1.IrBlockKind) Error!bool {
        const instruction_value = try self.instruction(instruction_id);
        if (try self.constantTruthyFallbackPatternContaining(instruction_id)) |pattern| {
            if (instruction_id == pattern.finish)
                try self.emitConstantTruthyFallback(pattern);
            return false;
        }
        if (try self.inlineConstantTableGetPatternContaining(instruction_id)) |pattern| {
            if (instruction_id == pattern.finish)
                try self.emitGenericTableFallbackCall(pattern.pattern);
            return false;
        }
        if (try self.inlineArrayGetPatternContaining(instruction_id)) |pattern| {
            if (instruction_id == pattern.finish)
                try self.emitInlineArrayGet(pattern);
            return false;
        }
        if (try self.semanticTableReloadPatternContaining(instruction_id)) |pattern| {
            if (instruction_id == pattern.finish)
                try self.emitSemanticTableReload(pattern);
            return false;
        }
        if (try self.inlineGenericTableSetPatternContaining(instruction_id)) |pattern| {
            if (instruction_id == pattern.finish)
                try self.emitInlineGenericTableSet(pattern.pattern);
            return false;
        }
        if (try self.userdataAllocationPatternContaining(instruction_id)) |pattern| {
            try self.emitUserdataAllocationInstruction(instruction_id, instruction_value, pattern);
            return false;
        }
        if (try self.literalFieldSetPatternContaining(instruction_id)) |pattern| {
            if (instruction_id == pattern.finish)
                try self.emitLiteralFieldSet(pattern);
            return false;
        }
        if (try self.constantLoadPatternContaining(instruction_id)) |pattern| {
            if (instruction_id == pattern.finish)
                try self.emitConstantLoad(pattern);
            return false;
        }
        if (try self.dupTablePatternContaining(instruction_id)) |pattern| {
            if (instruction_id == pattern.finish)
                try self.emitDupTable(pattern);
            return false;
        }
        if (try self.tableInsertAppendPatternContaining(instruction_id)) |pattern| {
            if (instruction_id == pattern.finish)
                try self.emitTableInsertAppend(pattern);
            return false;
        }
        if (try self.concatPatternContaining(instruction_id)) |pattern| {
            if (instruction_id == pattern.finish)
                try self.emitConcat(pattern);
            return false;
        }
        if (try self.tableAllocationPatternContaining(instruction_id)) |pattern| {
            if (instruction_id == pattern.finish)
                try self.emitTableAllocation(pattern);
            return false;
        }
        switch (instruction_value.command) {
            .nop, .substitute, .mark_used, .mark_dead => return false,
            .load_env => {
                if (instruction_id + 1 >= self.function.instruction_count or
                    (try self.instruction(instruction_id + 1)).command != .newclosure)
                    return Error.UnsupportedControlFlow;
                _ = try self.newClosurePattern(instruction_id + 1);
            },
            .get_closure_upval_addr => {
                if (try self.newClosurePatternContaining(instruction_id) == null)
                    return Error.UnsupportedControlFlow;
            },
            .load_tag => try self.emitLoadTag(instruction_id, instruction_value),
            .load_pointer, .load_int => try self.emitLoadI32(instruction_id, instruction_value),
            .load_int64 => try self.emitLoadI64(instruction_id, instruction_value),
            .load_float => try self.emitLoadFloat(instruction_id, instruction_value),
            .load_double => try self.emitLoadDouble(instruction_id, instruction_value),
            .load_tvalue => try self.emitLoadTValue(instruction_id, instruction_value),
            .store_pointer => {
                if (try self.newClosurePatternContaining(instruction_id) == null)
                    try self.emitStoreI32(instruction_value, 0);
            },
            .store_tag => try self.emitStoreTag(instruction_id, instruction_value),
            .store_extra => try self.emitStoreI32(instruction_value, tvalue_extra_offset),
            .store_split_tvalue => if (try self.newClosurePatternContaining(instruction_id) == null)
                try self.emitStoreSplitTValue(instruction_value),
            .store_double => try self.emitStoreDouble(instruction_value),
            .store_int => try self.emitStoreI32(instruction_value, 0),
            .store_int64 => try self.emitStoreI64(instruction_value),
            .store_vector => try self.emitStoreVector(instruction_value),
            .store_tvalue => try self.emitStoreTValue(instruction_id, instruction_value),
            .add_int => try self.emitBinaryI32(instruction_id, instruction_value, 0x6a),
            .sub_int => try self.emitBinaryI32(instruction_id, instruction_value, 0x6b),
            .add_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x7c),
            .sub_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x7d),
            .mul_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x7e),
            .div_int64 => try self.emitSignedDivisionI64(instruction_id, instruction_value, false),
            .idiv_int64 => try self.emitSignedDivisionI64(instruction_id, instruction_value, true),
            .udiv_int64 => try self.emitUnsignedDivisionI64(instruction_id, instruction_value, false),
            .rem_int64 => try self.emitSignedRemainderI64(instruction_id, instruction_value, false),
            .urem_int64 => try self.emitUnsignedDivisionI64(instruction_id, instruction_value, true),
            .mod_int64 => try self.emitSignedRemainderI64(instruction_id, instruction_value, true),
            .sexti8_int => try self.emitUnaryI32(instruction_id, instruction_value, 0xc0),
            .sexti16_int => try self.emitUnaryI32(instruction_id, instruction_value, 0xc1),
            .add_num => try self.emitAddNumber(instruction_id, instruction_value),
            .sub_num => try self.emitBinaryF64(instruction_id, instruction_value, 0xa1),
            .mul_num => try self.emitBinaryF64(instruction_id, instruction_value, 0xa2),
            .div_num => try self.emitBinaryF64(instruction_id, instruction_value, 0xa3),
            .idiv_num => try self.emitFloorDivisionNumber(instruction_id, instruction_value),
            .mod_num => try self.emitModNumber(instruction_id, instruction_value),
            .muladd_num => try self.emitMulAddNumber(instruction_id, instruction_value),
            .min_num => try self.emitMinMaxNumber(instruction_id, instruction_value, 0x63),
            .max_num => try self.emitMinMaxNumber(instruction_id, instruction_value, 0x64),
            .unm_num => try self.emitUnaryF64(instruction_id, instruction_value, 0x9a),
            .floor_num => try self.emitUnaryF64(instruction_id, instruction_value, 0x9c),
            .ceil_num => try self.emitUnaryF64(instruction_id, instruction_value, 0x9b),
            .round_num => try self.emitRoundNumber(instruction_id, instruction_value),
            .sqrt_num => try self.emitUnaryF64(instruction_id, instruction_value, 0x9f),
            .abs_num => try self.emitUnaryF64(instruction_id, instruction_value, 0x99),
            .sign_num => try self.emitSignNumber(instruction_id, instruction_value),
            .add_float => try self.emitBinaryF32(instruction_id, instruction_value, 0x92),
            .sub_float => try self.emitBinaryF32(instruction_id, instruction_value, 0x93),
            .mul_float => try self.emitBinaryF32(instruction_id, instruction_value, 0x94),
            .div_float => try self.emitBinaryF32(instruction_id, instruction_value, 0x95),
            .min_float => try self.emitMinMaxFloat(instruction_id, instruction_value, 0x5d),
            .max_float => try self.emitMinMaxFloat(instruction_id, instruction_value, 0x5e),
            .unm_float => try self.emitUnaryF32(instruction_id, instruction_value, 0x8c),
            .floor_float => try self.emitUnaryF32(instruction_id, instruction_value, 0x8e),
            .ceil_float => try self.emitUnaryF32(instruction_id, instruction_value, 0x8d),
            .sqrt_float => try self.emitUnaryF32(instruction_id, instruction_value, 0x91),
            .abs_float => try self.emitUnaryF32(instruction_id, instruction_value, 0x8b),
            .sign_float => try self.emitSignFloat(instruction_id, instruction_value),
            .select_num => try self.emitSelectNumber(instruction_id, instruction_value),
            .select_int64 => try self.emitSelectInt64(instruction_id, instruction_value),
            .select_vec => try self.emitSelectVector(instruction_id, instruction_value),
            .select_if_truthy => try self.emitSelectIfTruthy(instruction_id, instruction_value),
            .add_vec => try self.emitVectorBinary(instruction_id, instruction_value, 0x92),
            .sub_vec => try self.emitVectorBinary(instruction_id, instruction_value, 0x93),
            .mul_vec => try self.emitVectorBinary(instruction_id, instruction_value, 0x94),
            .div_vec => try self.emitVectorBinary(instruction_id, instruction_value, 0x95),
            .idiv_vec => try self.emitFloorDivisionVector(instruction_id, instruction_value),
            .muladd_vec => try self.emitMulAddVector(instruction_id, instruction_value),
            .unm_vec => try self.emitVectorUnary(instruction_id, instruction_value, 0x8c),
            .min_vec => try self.emitMinMaxVector(instruction_id, instruction_value, 0x5d),
            .max_vec => try self.emitMinMaxVector(instruction_id, instruction_value, 0x5e),
            .floor_vec => try self.emitVectorUnary(instruction_id, instruction_value, 0x8e),
            .ceil_vec => try self.emitVectorUnary(instruction_id, instruction_value, 0x8d),
            .abs_vec => try self.emitVectorUnary(instruction_id, instruction_value, 0x8b),
            .dot_vec => try self.emitDotVector(instruction_id, instruction_value),
            .extract_vec => try self.emitExtractVector(instruction_id, instruction_value),
            .float_to_vec => try self.emitFloatToVector(instruction_id, instruction_value),
            .tag_vector => try self.emitTagVector(instruction_id, instruction_value),
            .not_any => try self.emitNotAny(instruction_id, instruction_value),
            .cmp_any => {
                if (block_kind != .fallback)
                    return Error.UnsupportedControlFlow;
                try self.emitCompareAny(instruction_id, instruction_value);
            },
            .cmp_int => try self.emitComparisonI32(instruction_id, instruction_value),
            .cmp_int64 => try self.emitComparisonI64(instruction_id, instruction_value),
            .cmp_tag => try self.emitComparisonTag(instruction_id, instruction_value),
            .cmp_split_tvalue => try self.emitSplitTValueComparison(instruction_id, instruction_value),
            .int_to_num => try self.emitUnaryI32(instruction_id, instruction_value, 0xb7), // f64.convert_i32_s
            .int64_to_num => try self.emitUnaryI64(instruction_id, instruction_value, 0xb9), // f64.convert_i64_s
            .uint_to_num => try self.emitUnaryI32(instruction_id, instruction_value, 0xb8), // f64.convert_i32_u
            .uint_to_float => try self.emitUnaryI32(instruction_id, instruction_value, 0xb3), // f32.convert_i32_u
            .float_to_num => try self.emitUnaryF32(instruction_id, instruction_value, 0xbb), // f64.promote_f32
            .num_to_float => try self.emitUnaryF64(instruction_id, instruction_value, 0xb6), // f32.demote_f64
            .num_to_int => try self.emitNumToInt(instruction_id, instruction_value),
            .num_to_int64 => try self.emitNumToInt64(instruction_id, instruction_value),
            .num_to_uint => try self.emitNumToUint(instruction_id, instruction_value),
            .truncate_uint => try self.emitCopyI32(instruction_id, instruction_value),
            .bitand_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x83),
            .bitxor_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x85),
            .bitor_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x84),
            .bitnot_int64 => try self.emitNotI64(instruction_id, instruction_value),
            .bitlshift_int64 => try self.emitSignedI64Shift(instruction_id, instruction_value, 0x86, 0x88, false),
            .bitrshift_int64 => try self.emitSignedI64Shift(instruction_id, instruction_value, 0x88, 0x86, false),
            .bitarshift_int64 => try self.emitSignedI64Shift(instruction_id, instruction_value, 0x87, 0x86, true),
            .bitlrotate_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x89),
            .bitrrotate_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x8a),
            .bitcountlz_int64 => try self.emitUnaryI64(instruction_id, instruction_value, 0x79),
            .bitcountrz_int64 => try self.emitUnaryI64(instruction_id, instruction_value, 0x7a),
            .byteswap_int64 => try self.emitByteSwapI64(instruction_id, instruction_value),
            .bitand_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x71),
            .bitxor_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x73),
            .bitor_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x72),
            .bitnot_uint => try self.emitNotI32(instruction_id, instruction_value),
            .bitlshift_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x74),
            .bitrshift_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x76),
            .bitarshift_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x75),
            .bitlrotate_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x77),
            .bitrrotate_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x78),
            .bitcountlz_uint => try self.emitUnaryI32(instruction_id, instruction_value, 0x67),
            .bitcountrz_uint => try self.emitUnaryI32(instruction_id, instruction_value, 0x68),
            .byteswap_uint => try self.emitByteSwapI32(instruction_id, instruction_value),
            .get_upvalue => try self.emitGetUpvalue(instruction_id, instruction_value),
            .set_upvalue => try self.emitSetUpvalue(instruction_id),
            .check_div_int64 => try self.emitCheckDivInt64(instruction_value),
            .check_tag => try self.emitCheckTag(instruction_value),
            ir_cmd_check_buffer_len => try self.emitBufferLengthCheck(instruction_id, instruction_value),
            ir_cmd_check_userdata_tag => try self.emitCheckUserdataTag(instruction_value),
            .check_truthy => try self.emitCheckTruthy(instruction_value),
            .check_cmp_num => try self.emitCheckCompareNumber(instruction_value),
            .check_cmp_int => try self.emitCheckCompareInteger(instruction_value),
            .check_cmp_int64 => try self.emitCheckCompareInt64(instruction_value),
            .check_gc => {
                if (try self.newClosurePatternContaining(instruction_id) == null) {
                    if (!try self.checkGcClosesDeferredTableAllocation(instruction_id))
                        return Error.UnsupportedControlFlow;
                    try self.body.localGet(self.allocator, 0);
                    try self.body.call(self.allocator, self.check_gc orelse return Error.UnsupportedCommand);
                    try self.emitReloadBase();
                }
            },
            ir_cmd_barrier_object => try self.emitBarrierObject(instruction_value),
            ir_cmd_barrier_table_back => try self.emitBarrierTableBack(instruction_value),
            .set_savedpc => {
                try self.emitSavedPcLocation(instruction_value);
                if (block_kind != .fallback) {
                    if (!block_kind.isCompilable())
                        return Error.UnsupportedControlFlow;
                    if (instruction_id + 1 < self.function.instruction_count and
                        (try self.tableAllocationPatternAt(instruction_id + 1) != null or
                            try self.dupTablePatternAt(instruction_id + 1) != null))
                    {} else if (instruction_id + 2 < self.function.instruction_count and
                        (try self.instruction(instruction_id + 2)).command == .newclosure)
                    {
                        _ = try self.newClosurePattern(instruction_id + 2);
                    } else if (instruction_id + 1 >= self.function.instruction_count or
                        (try self.instruction(instruction_id + 1)).command != .call)
                        return Error.UnsupportedControlFlow;
                }
            },
            .capture => {
                if (try self.newClosurePatternContaining(instruction_id) == null and
                    !try self.isDupClosureCapture(instruction_id))
                    return Error.UnsupportedControlFlow;
            },
            .findupval => {
                if (try self.newClosurePatternContaining(instruction_id) == null)
                    return Error.UnsupportedControlFlow;
            },
            .close_upvals => try self.emitCloseUpvalues(instruction_id),
            .do_arith => {
                if (block_kind != .fallback)
                    return Error.UnsupportedControlFlow;
                try self.emitDoArith(instruction_id, instruction_value);
            },
            .check_safe_env => {
                const guards_dynamic_global = instruction_id + 1 < self.function.instruction_count and
                    (try self.instruction(instruction_id + 1)).command == .get_cached_import;
                // Generic cached imports are lowered as real environment lookups, so they do not
                // consume the optimizer's cache or its safe-environment assumption. Pattern-owned
                // fastcall/static-package paths handle their guards before reaching this switch.
                if (!guards_dynamic_global)
                    try self.emitSafeEnvCheck(instruction_id);
            },
            ir_cmd_invoke_libm => try self.emitLibm(instruction_id, instruction_value),
            ir_cmd_fastcall => try self.emitDirectFastcall(instruction_value),
            ir_cmd_string_len => try self.emitStringLen(instruction_id, instruction_value),
            .interrupt => try self.emitInterrupt(instruction_id, instruction_value),
            .jump => {
                try self.emitJump(instruction_value);
                return true;
            },
            .jump_if_truthy => {
                try self.emitJumpIfTruthy(instruction_value, false);
                return true;
            },
            .jump_if_falsy => {
                try self.emitJumpIfTruthy(instruction_value, true);
                return true;
            },
            .jump_eq_tag => {
                try self.emitJumpEqualTag(instruction_value);
                return true;
            },
            .jump_cmp_int => {
                try self.emitJumpCompareInteger(instruction_value);
                return true;
            },
            .jump_eq_pointer => {
                try self.emitJumpEqualPointer(instruction_value);
                return true;
            },
            .jump_cmp_num => {
                try self.emitJumpCompareNumber(instruction_value);
                return true;
            },
            .jump_cmp_float => {
                try self.emitJumpCompareFloat(instruction_value);
                return true;
            },
            .jump_forn_loop_cond => {
                try self.emitJumpFornLoopCondition(instruction_value);
                return true;
            },
            .return_ => {
                try self.emitReturn(instruction_value);
                return true;
            },
            .call => try self.emitCall(instruction_id, instruction_value),
            .get_cached_import => try self.emitSingleGlobalImport(instruction_value),
            ir_cmd_setlist => try self.emitSetList(instruction_value),
            ir_cmd_get_arr_addr => {
                if (!try self.trustedArrayAddress(instruction_id))
                    return Error.UnsupportedControlFlow;
            },
            ir_cmd_fallback_forgprep => {
                try self.emitGenericIterationPrep(instruction_id, instruction_value);
                return true;
            },
            .fallback_prepvarargs => try self.emitPrepVarargs(instruction_value),
            .fallback_getvarargs => try self.emitGetVarargs(instruction_value),
            .newclosure => try self.emitNewClosure(instruction_id),
            .fallback_dupclosure => try self.emitDupClosure(instruction_id),
            ir_cmd_buffer_readi8,
            ir_cmd_buffer_readu8,
            ir_cmd_buffer_readi16,
            ir_cmd_buffer_readu16,
            ir_cmd_buffer_readi32,
            ir_cmd_buffer_readf32,
            ir_cmd_buffer_readf64,
            ir_cmd_buffer_readi64,
            => try self.emitBufferRead(instruction_id, instruction_value),
            ir_cmd_buffer_writei8,
            ir_cmd_buffer_writei16,
            ir_cmd_buffer_writei32,
            ir_cmd_buffer_writef32,
            ir_cmd_buffer_writef64,
            ir_cmd_buffer_writei64,
            => try self.emitBufferWrite(instruction_id, instruction_value),
            ir_cmd_adjust_stack_to_reg => try self.emitBufferAdjustStack(instruction_id, instruction_value),
            else => return Error.UnsupportedCommand,
        }
        return false;
    }

    fn emitInstructionRange(self: Context, start: u32, finish: u32, block: snapshot_v1.IrBlock) Error!bool {
        const dynamic_length = try self.dynamicLengthPattern(block);
        const semantic_array = try self.semanticArrayOperation(block);
        var terminated = false;
        var instruction_id = start;
        while (instruction_id <= finish) : (instruction_id += 1) {
            if (terminated)
                return Error.InvalidBlockTermination;
            if (try self.integerCreatePatternAt(instruction_id)) |pattern| {
                try self.emitIntegerCreate(pattern);
                instruction_id = pattern.finish;
                continue;
            }
            if (try self.linearizedPowPattern(instruction_id, block)) |pattern| {
                try self.emitSavedPcLocation(pattern.marker);
                try self.emitDoArith(pattern.arithmetic_id, try self.instruction(pattern.arithmetic_id));
                instruction_id = pattern.finish;
                continue;
            }
            if (try self.globalHeadPatternAt(instruction_id, block)) |pattern| {
                try self.emitGlobalOperation(pattern);
                try self.body.branch(self.allocator, 1);
                instruction_id = block.finish;
                terminated = true;
                continue;
            }
            if (try self.plainTableNamecallPattern(block)) |pattern| {
                if (instruction_id == pattern.start) {
                    try self.emitPlainTableNamecallOperation(pattern);
                    try self.body.branch(self.allocator, 1);
                    instruction_id = block.finish;
                    terminated = true;
                    continue;
                }
            }
            if (try self.fastcallPatternAt(instruction_id, block)) |pattern| {
                try self.emitFastcallCluster(pattern);
                instruction_id = block.finish;
                terminated = true;
                continue;
            }
            const command = (try self.instruction(instruction_id)).command;
            if (command == ir_cmd_get_type or command == ir_cmd_get_typeof) {
                const pattern = (try self.typeNamePattern(instruction_id, command == ir_cmd_get_typeof)) orelse
                    return Error.UnsupportedControlFlow;
                try self.emitTypeName(pattern);
                instruction_id = pattern.finish;
                continue;
            }
            if (try self.staticRequireTarget(instruction_id, block)) |require| {
                try self.emitStaticRequire(require.interrupt_id, require.destination, require.module_id);
                instruction_id = require.end;
                continue;
            }
            if (try self.stringTablePattern(block)) |pattern| {
                if (instruction_id == pattern.start) {
                    try self.emitStringTableOperation(pattern);
                    instruction_id = block.finish;
                    terminated = true;
                    continue;
                }
            }
            if (try self.inlineStringGetPatternAt(instruction_id, block)) |pattern| {
                try self.emitStringTableHelper(pattern);
                instruction_id += 6;
                continue;
            }
            if (dynamic_length) |pattern| {
                if (instruction_id == pattern.start) {
                    try self.emitDynamicLength(pattern);
                    try self.body.branch(self.allocator, 1);
                    instruction_id = block.finish;
                    terminated = true;
                    continue;
                }
            }
            if (semantic_array) |operation| {
                if (instruction_id == operation.pattern.start) {
                    try self.emitArrayOperation(operation.pattern, operation.kind);
                    try self.body.branch(self.allocator, 1);
                    instruction_id = block.finish;
                    terminated = true;
                    continue;
                }
            }
            terminated = try self.emitInstruction(instruction_id, block.kind);
        }
        return terminated;
    }

    fn emitBlock(self: Context, block_id: u32, block: snapshot_v1.IrBlock) Error!void {
        if (try self.stringEqualityPattern(block)) |pattern|
            return self.emitStringEqualityBlock(block_id, block, pattern);
        if (try self.constantPowPattern(block)) |pattern|
            return self.emitConstantArithmeticBlock(block_id, block, pattern);
        if (try self.constantArithmeticPattern(block)) |pattern|
            return self.emitConstantArithmeticBlock(block_id, block, pattern);
        if (try self.powPattern(block)) |pattern|
            return self.emitPowBlock(block_id, block, pattern);
        if (try self.plainTableNamecallPattern(block)) |pattern|
            return self.emitPlainTableNamecallBlock(block_id, block, pattern);
        if (try self.isFastcallFallback(block_id, block))
            return self.emitFastcallFallbackBlock(block_id, block);
        if (try self.specializedIpairsPattern(block)) |pattern|
            return self.emitGenericIterationBlock(block_id, pattern, true);
        if (try self.genericIterationPattern(block)) |pattern|
            return self.emitGenericIterationBlock(block_id, pattern, true);
        if (try self.genericIterationFallbackPattern(block)) |pattern|
            return self.emitGenericIterationBlock(block_id, pattern, false);
        if (try self.xnextFastPreparationPattern(block)) |pattern|
            return self.emitXnextFastPreparationBlock(block_id, block, pattern);
        if (try self.xnextPreparationPattern(block)) |pattern|
            return self.emitXnextPreparationBlock(block_id, pattern);
        if (try self.globalPattern(block)) |pattern|
            return self.emitGlobalOperationBlock(block_id, block, pattern);
        if (try self.genericTablePattern(block)) |pattern|
            return self.emitGenericTableOperationBlock(block_id, block, pattern);
        if (try self.stringTablePattern(block)) |pattern|
            return self.emitStringTableOperationBlock(block_id, block, pattern);
        if (try self.dynamicLengthPattern(block)) |pattern|
            return self.emitDynamicLengthBlock(block_id, block, pattern);
        if (try self.semanticArrayOperation(block)) |operation|
            return self.emitArrayOperationBlock(block_id, block, operation.pattern, operation.kind);
        if (block.kind == .fallback and !try self.supportsFallback(block))
            return Error.UnsupportedControlFlow;

        try self.body.localGet(self.allocator, self.dispatch_local);
        try self.body.i32Const(self.allocator, @intCast(block_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);

        const terminated = try self.emitInstructionRange(block.start, block.finish, block);
        if (!terminated)
            return Error.InvalidBlockTermination;
        try self.body.end(self.allocator);
    }

    fn emitCallContinuation(self: Context, continuation: CallContinuation) Error!void {
        try self.body.localGet(self.allocator, self.dispatch_local);
        try self.body.i32Const(self.allocator, @intCast(continuation.dispatch_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        switch (continuation.action) {
            .call_suffix => |suffix| {
                const block = try self.snapshot.irBlock(self.function, suffix.block_id);
                const terminated = try self.emitInstructionRange(suffix.suffix_start, suffix.block_finish, block);
                if (!terminated)
                    return Error.InvalidBlockTermination;
            },
            .generic_iteration => |pattern| {
                try self.emitGenericIterationFinish(pattern);
                try self.body.branch(self.allocator, 1);
            },
            .interrupt_block_retry => |retry| {
                try self.body.i32Const(self.allocator, @intCast(retry.block_id));
                try self.body.localSet(self.allocator, self.dispatch_local);
                try self.body.branch(self.allocator, 1);
            },
            .interrupt_suffix => |suffix| {
                const block = try self.snapshot.irBlock(self.function, suffix.block_id);
                try self.emitInterrupt(suffix.interrupt_id, try self.instruction(suffix.interrupt_id));
                const terminated = try self.emitInstructionRange(suffix.suffix_start, suffix.block_finish, block);
                if (!terminated)
                    return Error.InvalidBlockTermination;
            },
            .static_require_interrupt => |suffix| {
                const block = try self.snapshot.irBlock(self.function, suffix.block_id);
                try self.emitStaticRequire(
                    suffix.require.interrupt_id,
                    suffix.require.destination,
                    suffix.require.module_id,
                );
                const terminated = try self.emitInstructionRange(suffix.suffix_start, suffix.block_finish, block);
                if (!terminated)
                    return Error.InvalidBlockTermination;
            },
        }
        try self.body.end(self.allocator);
    }
};

fn validateContinuationRegion(
    allocator: std.mem.Allocator,
    context: Context,
    continuation_block_id: u32,
    suffix_start: u32,
    block_finish: u32,
) Error!bool {
    if (continuation_block_id >= context.function.block_count or
        suffix_start > block_finish or block_finish >= context.function.instruction_count)
        return Error.UnsupportedControlFlow;

    const reachable_blocks = try allocator.alloc(bool, context.function.block_count);
    defer allocator.free(reachable_blocks);
    @memset(reachable_blocks, false);
    const reachable_instructions = try allocator.alloc(bool, context.function.instruction_count);
    defer allocator.free(reachable_instructions);
    @memset(reachable_instructions, false);
    const instruction_blocks = try allocator.alloc(u32, context.function.instruction_count);
    defer allocator.free(instruction_blocks);
    @memset(instruction_blocks, snapshot_v1.no_id);
    const edge_count = std.math.mul(usize, context.function.block_count, context.function.block_count) catch
        return Error.ResourceLimit;
    const edges = try allocator.alloc(bool, edge_count);
    defer allocator.free(edges);
    @memset(edges, false);

    var pending_blocks: std.ArrayList(u32) = .empty;
    defer pending_blocks.deinit(allocator);

    reachable_blocks[continuation_block_id] = true;
    var instruction_id = suffix_start;
    while (instruction_id <= block_finish) : (instruction_id += 1) {
        reachable_instructions[instruction_id] = true;
        instruction_blocks[instruction_id] = continuation_block_id;
        const instruction_value = try context.instruction(instruction_id);
        var operand_id: u32 = 0;
        while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
            const operand_value = try context.operand(instruction_value, operand_id);
            if (operand_value.kind != .block)
                continue;
            if (operand_value.value >= context.function.block_count)
                return false;
            // A loop back to the interrupted block re-enters its ordinary generated dispatch arm
            // from the beginning, where all of that iteration's SSA values are recomputed. It is a
            // safe boundary of the resumed suffix, not a dependency on the pre-suspension locals.
            if (operand_value.value == continuation_block_id)
                continue;
            edges[@as(usize, continuation_block_id) * context.function.block_count + operand_value.value] = true;
            try pending_blocks.append(allocator, operand_value.value);
        }
    }

    while (pending_blocks.items.len != 0) {
        const block_id = pending_blocks.items[pending_blocks.items.len - 1];
        pending_blocks.items.len -= 1;
        if (block_id >= context.function.block_count)
            return Error.UnsupportedControlFlow;
        if (reachable_blocks[block_id])
            continue;
        const block = try context.snapshot.irBlock(context.function, block_id);
        if (block.isEmpty())
            continue;

        // Continuation reachability must describe the CFG that this backend actually emits. A
        // non-compilable block, including a fallback outside the current semantic coverage, has no
        // generated dispatch arm and therefore terminates at the function's fail-closed internal
        // status. Do not follow its raw optimizer edges into blocks that generated code cannot reach.
        if (!block.kind.isCompilable() and
            (block.kind != .fallback or !try context.supportsFallback(block)))
            continue;

        reachable_blocks[block_id] = true;

        instruction_id = block.start;
        while (instruction_id <= block.finish) : (instruction_id += 1) {
            if (instruction_id >= context.function.instruction_count)
                return Error.UnsupportedControlFlow;
            reachable_instructions[instruction_id] = true;
            instruction_blocks[instruction_id] = block_id;
            const instruction_value = try context.instruction(instruction_id);
            var operand_id: u32 = 0;
            while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                const operand_value = try context.operand(instruction_value, operand_id);
                if (operand_value.kind != .block)
                    continue;
                if (operand_value.value >= context.function.block_count)
                    return false;
                if (operand_value.value == continuation_block_id)
                    continue;
                edges[@as(usize, block_id) * context.function.block_count + operand_value.value] = true;
                try pending_blocks.append(allocator, operand_value.value);
            }
        }
    }

    const dominators = try allocator.alloc(bool, edge_count);
    defer allocator.free(dominators);
    @memset(dominators, false);
    var block_id: u32 = 0;
    while (block_id < context.function.block_count) : (block_id += 1) {
        if (!reachable_blocks[block_id])
            continue;
        var candidate: u32 = 0;
        while (candidate < context.function.block_count) : (candidate += 1) {
            if (reachable_blocks[candidate] and
                (block_id != continuation_block_id or candidate == continuation_block_id))
                dominators[@as(usize, block_id) * context.function.block_count + candidate] = true;
        }
    }

    var changed = true;
    while (changed) {
        changed = false;
        block_id = 0;
        while (block_id < context.function.block_count) : (block_id += 1) {
            if (!reachable_blocks[block_id] or block_id == continuation_block_id)
                continue;
            var candidate: u32 = 0;
            while (candidate < context.function.block_count) : (candidate += 1) {
                if (!reachable_blocks[candidate])
                    continue;
                var desired = candidate == block_id;
                if (!desired) {
                    desired = true;
                    var has_predecessor = false;
                    var predecessor: u32 = 0;
                    while (predecessor < context.function.block_count) : (predecessor += 1) {
                        if (!reachable_blocks[predecessor] or
                            !edges[@as(usize, predecessor) * context.function.block_count + block_id])
                            continue;
                        has_predecessor = true;
                        if (!dominators[@as(usize, predecessor) * context.function.block_count + candidate]) {
                            desired = false;
                            break;
                        }
                    }
                    desired = desired and has_predecessor;
                }
                const index = @as(usize, block_id) * context.function.block_count + candidate;
                if (dominators[index] != desired) {
                    dominators[index] = desired;
                    changed = true;
                }
            }
        }
    }

    instruction_id = 0;
    while (instruction_id < context.function.instruction_count) : (instruction_id += 1) {
        if (!reachable_instructions[instruction_id])
            continue;
        const instruction_value = try context.instruction(instruction_id);
        var operand_id: u32 = 0;
        while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
            const operand_value = try context.operand(instruction_value, operand_id);
            if (operand_value.kind != .instruction)
                continue;
            if (operand_value.value >= context.function.instruction_count or
                !reachable_instructions[operand_value.value])
                return false;
            const producer_block = instruction_blocks[operand_value.value];
            const consumer_block = instruction_blocks[instruction_id];
            if (producer_block == consumer_block) {
                if (operand_value.value >= instruction_id)
                    return false;
            } else if (!dominators[@as(usize, consumer_block) * context.function.block_count + producer_block]) {
                return false;
            }
        }
    }
    return true;
}

fn validateStringTableContinuationTail(
    allocator: std.mem.Allocator,
    context: Context,
    block: snapshot_v1.IrBlock,
    suffix_start: u32,
) Error!?bool {
    const pattern = (try context.stringTablePattern(block)) orelse return null;
    if (pattern.start < suffix_start)
        return null;

    // The compiler replaces the whole trailing fast/fallback table graph with one real runtime
    // helper and a canonical rejoin. Only the prefix before that graph executes as raw IR after
    // resumption, so validate that prefix rather than unreachable optimizer blocks.
    var instruction_id = suffix_start;
    while (instruction_id < pattern.start) : (instruction_id += 1) {
        const instruction_value = try context.instruction(instruction_id);
        var operand_id: u32 = 0;
        while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
            const operand_value = try context.operand(instruction_value, operand_id);
            if (operand_value.kind == .instruction and
                (operand_value.value < suffix_start or operand_value.value >= instruction_id))
                return false;
            if (operand_value.kind == .block)
                return false;
        }
    }

    const rejoin = try context.snapshot.irBlock(context.function, pattern.rejoin);
    if (rejoin.isEmpty())
        return false;
    return @as(?bool, try validateContinuationRegion(
        allocator,
        context,
        pattern.rejoin,
        rejoin.start,
        rejoin.finish,
    ));
}

fn validateNamecallContinuationTail(
    allocator: std.mem.Allocator,
    context: Context,
    block: snapshot_v1.IrBlock,
    suffix_start: u32,
) Error!?bool {
    const pattern = (try context.plainTableNamecallPattern(block)) orelse return null;
    if (pattern.start < suffix_start)
        return null;
    var instruction_id = suffix_start;
    while (instruction_id < pattern.start) : (instruction_id += 1) {
        const instruction_value = try context.instruction(instruction_id);
        var operand_id: u32 = 0;
        while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
            const operand_value = try context.operand(instruction_value, operand_id);
            if (operand_value.kind == .instruction and
                (operand_value.value < suffix_start or operand_value.value >= instruction_id))
                return false;
            if (operand_value.kind == .block)
                return false;
        }
    }
    const rejoin = try context.snapshot.irBlock(context.function, pattern.rejoin);
    if (rejoin.isEmpty())
        return false;
    return @as(?bool, try validateContinuationRegion(
        allocator,
        context,
        pattern.rejoin,
        rejoin.start,
        rejoin.finish,
    ));
}

fn validateGenericIterationContinuationRegion(
    allocator: std.mem.Allocator,
    context: Context,
    pattern: GenericIterationPattern,
) Error!bool {
    const reachable_blocks = try allocator.alloc(bool, context.function.block_count);
    defer allocator.free(reachable_blocks);
    @memset(reachable_blocks, false);
    const reachable_instructions = try allocator.alloc(bool, context.function.instruction_count);
    defer allocator.free(reachable_instructions);
    @memset(reachable_instructions, false);
    const instruction_blocks = try allocator.alloc(u32, context.function.instruction_count);
    defer allocator.free(instruction_blocks);
    @memset(instruction_blocks, snapshot_v1.no_id);
    const edge_count = std.math.mul(usize, context.function.block_count, context.function.block_count) catch
        return Error.ResourceLimit;
    const edges = try allocator.alloc(bool, edge_count);
    defer allocator.free(edges);
    @memset(edges, false);

    var pending_blocks: std.ArrayList(u32) = .empty;
    defer pending_blocks.deinit(allocator);
    try pending_blocks.append(allocator, pattern.repeat_target);
    try pending_blocks.append(allocator, pattern.exit_target);

    while (pending_blocks.items.len != 0) {
        const block_id = pending_blocks.items[pending_blocks.items.len - 1];
        pending_blocks.items.len -= 1;
        if (block_id >= context.function.block_count)
            return Error.UnsupportedControlFlow;
        if (reachable_blocks[block_id])
            continue;
        reachable_blocks[block_id] = true;

        const block = try context.snapshot.irBlock(context.function, block_id);
        if (block.isEmpty() or (!block.kind.isCompilable() and block.kind != .fallback))
            return false;
        if (block.kind == .fallback and
            !try context.isBypassedEmissionBlock(block_id, block) and
            !try context.supportsFallback(block))
            return false;

        var instruction_id = block.start;
        while (instruction_id <= block.finish) : (instruction_id += 1) {
            if (instruction_id >= context.function.instruction_count)
                return Error.UnsupportedControlFlow;
            reachable_instructions[instruction_id] = true;
            instruction_blocks[instruction_id] = block_id;
            const instruction_value = try context.instruction(instruction_id);
            var operand_id: u32 = 0;
            while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                const operand_value = try context.operand(instruction_value, operand_id);
                if (operand_value.kind == .block) {
                    if (operand_value.value >= context.function.block_count)
                        return Error.UnsupportedControlFlow;
                    edges[@as(usize, block_id) * context.function.block_count + operand_value.value] = true;
                    try pending_blocks.append(allocator, operand_value.value);
                }
            }
        }
    }

    const dominators = try allocator.alloc(bool, edge_count);
    defer allocator.free(dominators);
    @memset(dominators, false);
    var block_id: u32 = 0;
    while (block_id < context.function.block_count) : (block_id += 1) {
        if (!reachable_blocks[block_id])
            continue;
        const is_root = block_id == pattern.repeat_target or block_id == pattern.exit_target;
        var candidate: u32 = 0;
        while (candidate < context.function.block_count) : (candidate += 1) {
            if (reachable_blocks[candidate] and (!is_root or candidate == block_id))
                dominators[@as(usize, block_id) * context.function.block_count + candidate] = true;
        }
    }

    var changed = true;
    while (changed) {
        changed = false;
        block_id = 0;
        while (block_id < context.function.block_count) : (block_id += 1) {
            if (!reachable_blocks[block_id] or block_id == pattern.repeat_target or block_id == pattern.exit_target)
                continue;
            var candidate: u32 = 0;
            while (candidate < context.function.block_count) : (candidate += 1) {
                if (!reachable_blocks[candidate])
                    continue;
                var desired = candidate == block_id;
                if (!desired) {
                    desired = true;
                    var has_predecessor = false;
                    var predecessor: u32 = 0;
                    while (predecessor < context.function.block_count) : (predecessor += 1) {
                        if (!reachable_blocks[predecessor] or
                            !edges[@as(usize, predecessor) * context.function.block_count + block_id])
                            continue;
                        has_predecessor = true;
                        if (!dominators[@as(usize, predecessor) * context.function.block_count + candidate]) {
                            desired = false;
                            break;
                        }
                    }
                    desired = desired and has_predecessor;
                }
                const index = @as(usize, block_id) * context.function.block_count + candidate;
                if (dominators[index] != desired) {
                    dominators[index] = desired;
                    changed = true;
                }
            }
        }
    }

    var instruction_id: u32 = 0;
    while (instruction_id < context.function.instruction_count) : (instruction_id += 1) {
        if (!reachable_instructions[instruction_id])
            continue;
        const instruction_value = try context.instruction(instruction_id);
        var operand_id: u32 = 0;
        while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
            const operand_value = try context.operand(instruction_value, operand_id);
            if (operand_value.kind == .instruction) {
                if (operand_value.value >= context.function.instruction_count or !reachable_instructions[operand_value.value])
                    return false;
                const producer_block = instruction_blocks[operand_value.value];
                const consumer_block = instruction_blocks[instruction_id];
                if (producer_block == consumer_block) {
                    if (operand_value.value >= instruction_id)
                        return false;
                } else if (!dominators[@as(usize, consumer_block) * context.function.block_count + producer_block])
                    return false;
            }
        }
    }
    return true;
}

fn collectCallContinuations(allocator: std.mem.Allocator, context: Context) Error![]CallContinuation {
    var continuations: std.ArrayList(CallContinuation) = .empty;
    errdefer continuations.deinit(allocator);
    var block_id: u32 = 0;
    while (block_id < context.function.block_count) : (block_id += 1) {
        const block = try context.snapshot.irBlock(context.function, block_id);
        if (block.isEmpty() or (!block.kind.isCompilable() and block.kind != .fallback))
            continue;
        if (try context.isBypassedEmissionBlock(block_id, block))
            continue;
        var instruction_id = block.start;
        while (instruction_id <= block.finish) : (instruction_id += 1) {
            if (try context.staticRequireTarget(instruction_id, block)) |require| {
                const suffix_start = std.math.add(u32, require.end, 1) catch return Error.ResourceLimit;
                if (suffix_start > block.finish or
                    !try validateContinuationRegion(allocator, context, block_id, suffix_start, block.finish))
                    return Error.UnsupportedControlFlow;
                const continuation_id = std.math.cast(u32, continuations.items.len + 1) orelse return Error.ResourceLimit;
                if (continuation_id > 4095)
                    return Error.ResourceLimit;
                const dispatch_id = std.math.add(u32, context.function.block_count, continuation_id) catch
                    return Error.ResourceLimit;
                try continuations.append(allocator, .{
                    .instruction_id = require.interrupt_id,
                    .continuation_id = continuation_id,
                    .dispatch_id = dispatch_id,
                    .action = .{ .static_require_interrupt = .{
                        .block_id = block_id,
                        .require = require,
                        .suffix_start = suffix_start,
                        .block_finish = block.finish,
                    } },
                });
                instruction_id = require.end;
                continue;
            }
            const instruction_value = try context.instruction(instruction_id);
            const action: ContinuationAction = if (instruction_value.command == .call) blk: {
                const suffix_start = std.math.add(u32, instruction_id, 1) catch return Error.ResourceLimit;
                if (suffix_start > block.finish)
                    return Error.UnsupportedControlFlow;
                const tail_valid = try validateStringTableContinuationTail(
                    allocator,
                    context,
                    block,
                    suffix_start,
                );
                const namecall_tail_valid = try validateNamecallContinuationTail(allocator, context, block, suffix_start);
                if (!(tail_valid orelse namecall_tail_valid orelse
                    try validateContinuationRegion(allocator, context, block_id, suffix_start, block.finish)))
                    return Error.UnsupportedControlFlow;
                break :blk .{ .call_suffix = .{
                    .block_id = block_id,
                    .suffix_start = suffix_start,
                    .block_finish = block.finish,
                } };
            } else if (instruction_value.command == .interrupt) blk: {
                if (instruction_id == block.start)
                    break :blk .{ .interrupt_block_retry = .{ .block_id = block_id } };
                const suffix_start = std.math.add(u32, instruction_id, 1) catch return Error.ResourceLimit;
                const tail_valid = try validateStringTableContinuationTail(
                    allocator,
                    context,
                    block,
                    suffix_start,
                );
                const namecall_tail_valid = try validateNamecallContinuationTail(allocator, context, block, suffix_start);
                if (suffix_start > block.finish or !(tail_valid orelse namecall_tail_valid orelse
                    try validateContinuationRegion(allocator, context, block_id, suffix_start, block.finish)))
                    return Error.UnsupportedControlFlow;
                break :blk .{ .interrupt_suffix = .{
                    .block_id = block_id,
                    .interrupt_id = instruction_id,
                    .suffix_start = suffix_start,
                    .block_finish = block.finish,
                } };
            } else if (instruction_value.command == ir_cmd_forgloop_fallback) blk: {
                const pattern = (try context.genericIterationFallbackPattern(block)) orelse continue;
                const has_fast_owner = (try context.supportsGenericIterationFallback(block)) or
                    (try context.supportsSpecializedIpairsFallback(block));
                if (!has_fast_owner or
                    !try validateGenericIterationContinuationRegion(allocator, context, pattern))
                    continue;
                break :blk .{ .generic_iteration = pattern };
            } else continue;
            const continuation_id = std.math.cast(u32, continuations.items.len + 1) orelse return Error.ResourceLimit;
            if (continuation_id > 4095)
                return Error.ResourceLimit;
            const dispatch_id = std.math.add(u32, context.function.block_count, continuation_id) catch return Error.ResourceLimit;
            try continuations.append(allocator, .{
                .instruction_id = instruction_id,
                .continuation_id = continuation_id,
                .dispatch_id = dispatch_id,
                .action = action,
            });
        }
    }
    return continuations.toOwnedSlice(allocator);
}

fn resultShape(command: snapshot_v1.IrCommand) ValueShape {
    return switch (command) {
        .load_tag,
        .load_int,
        .add_int,
        .sub_int,
        .sexti8_int,
        .sexti16_int,
        .not_any,
        .cmp_any,
        .cmp_int,
        .cmp_int64,
        .cmp_tag,
        .cmp_split_tvalue,
        .num_to_int,
        .num_to_uint,
        .truncate_uint,
        .bitand_uint,
        .bitxor_uint,
        .bitor_uint,
        .bitnot_uint,
        .bitlshift_uint,
        .bitrshift_uint,
        .bitarshift_uint,
        .bitlrotate_uint,
        .bitrrotate_uint,
        .bitcountlz_uint,
        .bitcountrz_uint,
        .byteswap_uint,
        ir_cmd_string_len,
        ir_cmd_buffer_readi8,
        ir_cmd_buffer_readu8,
        ir_cmd_buffer_readi16,
        ir_cmd_buffer_readu16,
        ir_cmd_buffer_readi32,
        => .i32,
        .load_pointer,
        .load_env,
        .get_closure_upval_addr,
        .newclosure,
        .findupval,
        ir_cmd_new_userdata,
        => .pointer,
        .load_int64,
        .add_int64,
        .sub_int64,
        .mul_int64,
        .div_int64,
        .idiv_int64,
        .udiv_int64,
        .rem_int64,
        .urem_int64,
        .mod_int64,
        .select_int64,
        .num_to_int64,
        .bitand_int64,
        .bitxor_int64,
        .bitor_int64,
        .bitnot_int64,
        .bitlshift_int64,
        .bitrshift_int64,
        .bitarshift_int64,
        .bitlrotate_int64,
        .bitrrotate_int64,
        .bitcountlz_int64,
        .bitcountrz_int64,
        .byteswap_int64,
        ir_cmd_buffer_readi64,
        => .i64,
        .load_float,
        .add_float,
        .sub_float,
        .mul_float,
        .div_float,
        .min_float,
        .max_float,
        .unm_float,
        .floor_float,
        .ceil_float,
        .sqrt_float,
        .abs_float,
        .sign_float,
        .dot_vec,
        .extract_vec,
        .uint_to_float,
        .num_to_float,
        ir_cmd_buffer_readf32,
        => .f32,
        .load_double,
        .add_num,
        .sub_num,
        .mul_num,
        .div_num,
        .idiv_num,
        .mod_num,
        .muladd_num,
        .min_num,
        .max_num,
        .unm_num,
        .floor_num,
        .ceil_num,
        .round_num,
        .sqrt_num,
        .abs_num,
        .sign_num,
        .select_num,
        .int_to_num,
        .int64_to_num,
        .uint_to_num,
        .float_to_num,
        ir_cmd_invoke_libm,
        ir_cmd_buffer_readf64,
        => .f64,
        .load_tvalue,
        .select_vec,
        .select_if_truthy,
        .add_vec,
        .sub_vec,
        .mul_vec,
        .div_vec,
        .idiv_vec,
        .muladd_vec,
        .unm_vec,
        .min_vec,
        .max_vec,
        .floor_vec,
        .ceil_vec,
        .abs_vec,
        .float_to_vec,
        .tag_vector,
        => .tvalue,
        else => .none,
    };
}

const ImportNeeds = struct {
    do_arith: bool = false,
    compare_any: bool = false,
    dupclosure: bool = false,
    newclosure_capture: bool = false,
    get_upvalue: bool = false,
    set_upvalue: bool = false,
    close_upvalues: bool = false,
    call: bool = false,
    exchange_continuation: bool = false,
    set_location: bool = false,
    new_table: bool = false,
    new_table_deferred: bool = false,
    check_gc: bool = false,
    new_userdata: bool = false,
    check_userdata_tag: bool = false,
    barrier_object: bool = false,
    barrier_table_back: bool = false,
    load_constant: bool = false,
    dup_table: bool = false,
    table_insert_append: bool = false,
    namecall_plain: bool = false,
    set_list: bool = false,
    array_set: bool = false,
    array_get: bool = false,
    table_len: bool = false,
    concat: bool = false,
    do_len: bool = false,
    forg_prep: bool = false,
    forg_loop: bool = false,
    forg_loop_call: bool = false,
    forg_loop_finish: bool = false,
    forgprep_xnext_fallback: bool = false,
    table_set_string: bool = false,
    table_get_string: bool = false,
    table_set: bool = false,
    table_get: bool = false,
    table_array_set: bool = false,
    table_array_get: bool = false,
    get_global: bool = false,
    set_global: bool = false,
    check_safe_env: bool = false,
    fastcall: bool = false,
    type_name: bool = false,
    builtin_type_error: bool = false,
    builtin_number: bool = false,
    buffer_bounds_error: bool = false,
    libm: bool = false,
    prep_varargs: bool = false,
    get_varargs_fixed: bool = false,
    get_varargs_multret: bool = false,
    require_static: bool = false,
};

const RuntimeImports = struct {
    return_: wasm.FunctionRef,
    interrupt: wasm.FunctionRef,
    do_arith: ?wasm.FunctionRef,
    compare_any: ?wasm.FunctionRef,
    dupclosure: ?wasm.FunctionRef,
    newclosure_capture: ?wasm.FunctionRef,
    get_upvalue: ?wasm.FunctionRef,
    set_upvalue: ?wasm.FunctionRef,
    close_upvalues: ?wasm.FunctionRef,
    call: ?wasm.FunctionRef,
    exchange_continuation: ?wasm.FunctionRef,
    set_location: ?wasm.FunctionRef,
    new_table: ?wasm.FunctionRef,
    new_table_deferred: ?wasm.FunctionRef,
    check_gc: ?wasm.FunctionRef,
    new_userdata: ?wasm.FunctionRef,
    check_userdata_tag: ?wasm.FunctionRef,
    barrier_object: ?wasm.FunctionRef,
    barrier_table_back: ?wasm.FunctionRef,
    load_constant: ?wasm.FunctionRef,
    dup_table: ?wasm.FunctionRef,
    table_insert_append: ?wasm.FunctionRef,
    namecall_plain: ?wasm.FunctionRef,
    set_list: ?wasm.FunctionRef,
    array_set: ?wasm.FunctionRef,
    array_get: ?wasm.FunctionRef,
    table_len: ?wasm.FunctionRef,
    concat: ?wasm.FunctionRef,
    do_len: ?wasm.FunctionRef,
    forg_prep: ?wasm.FunctionRef,
    forg_loop: ?wasm.FunctionRef,
    forg_loop_call: ?wasm.FunctionRef,
    forg_loop_finish: ?wasm.FunctionRef,
    forgprep_xnext_fallback: ?wasm.FunctionRef,
    table_set_string: ?wasm.FunctionRef,
    table_get_string: ?wasm.FunctionRef,
    table_set: ?wasm.FunctionRef,
    table_get: ?wasm.FunctionRef,
    table_array_set: ?wasm.FunctionRef,
    table_array_get: ?wasm.FunctionRef,
    get_global: ?wasm.FunctionRef,
    set_global: ?wasm.FunctionRef,
    check_safe_env: ?wasm.FunctionRef,
    fastcall: ?wasm.FunctionRef,
    type_name: ?wasm.FunctionRef,
    libm: ?wasm.FunctionRef,
    builtin_type_error: ?wasm.FunctionRef,
    builtin_number: ?wasm.FunctionRef,
    buffer_bounds_error: ?wasm.FunctionRef,
    prep_varargs: ?wasm.FunctionRef,
    get_varargs_fixed: ?wasm.FunctionRef,
    get_varargs_multret: ?wasm.FunctionRef,
    require_static: ?wasm.FunctionRef,
    generated_type: u32,
};

fn isRequireImportInstruction(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    proto: snapshot_v1.Proto,
    instruction_value: snapshot_v1.IrInstruction,
) Error!bool {
    if (instruction_value.command != .get_cached_import or instruction_value.operand_count != 4)
        return false;
    const import_operand = try snapshot.irOperand(instruction_value, 1);
    const descriptor_operand = try snapshot.irOperand(instruction_value, 2);
    if (import_operand.kind != .vm_const or descriptor_operand.kind != .constant)
        return false;
    const import = try snapshot.vmConstant(proto, import_operand.value);
    if (import.kind != .import or import.payload1 != 1)
        return false;
    const item = try snapshot.vmConstantItem(import.payload0);
    if (item.value != snapshot_v1.no_id)
        return false;
    const name_constant = try snapshot.vmConstant(proto, item.key);
    if (name_constant.kind != .string or !std.mem.eql(u8, try snapshot.string(name_constant.payload0), "require"))
        return false;
    const descriptor = try snapshot.irConstant(function, descriptor_operand.value);
    const encoded = descriptor.importValue() orelse return false;
    const expected = (@as(u32, 1) << 30) | (item.key << 20);
    return encoded == expected;
}

fn isStaticRequireCall(snapshot: snapshot_v1.Snapshot, function: snapshot_v1.IrFunction, instruction_id: u32) Error!bool {
    if (instruction_id < 6)
        return false;
    const marker = try snapshot.irInstruction(function, instruction_id - 6);
    const get_import = try snapshot.irInstruction(function, instruction_id - 5);
    if (!((marker.command == .nop or marker.command == .check_safe_env) and
        (try snapshot.irInstruction(function, instruction_id - 4)).command == .load_tvalue and
        (try snapshot.irInstruction(function, instruction_id - 3)).command == .store_tvalue and
        (try snapshot.irInstruction(function, instruction_id - 2)).command == .interrupt and
        (try snapshot.irInstruction(function, instruction_id - 1)).command == .set_savedpc))
        return false;
    return isRequireImportInstruction(snapshot, function, try snapshot.proto(function.proto_id), get_import);
}

fn scanImportNeeds(snapshot: snapshot_v1.Snapshot, function_id: u32, static_package: bool, needs: *ImportNeeds) Error!void {
    const function = try snapshot.irFunction(function_id);
    const proto = try snapshot.proto(function.proto_id);
    var instruction_id: u32 = 0;
    while (instruction_id < function.instruction_count) : (instruction_id += 1) {
        const instruction_value = try snapshot.irInstruction(function, instruction_id);
        switch (instruction_value.command) {
            .load_pointer => {
                if (instruction_value.operand_count == 1 and
                    (try snapshot.irOperand(instruction_value, 0)).kind == .vm_const)
                    needs.compare_any = true;
            },
            .do_arith => needs.do_arith = true,
            .cmp_any => needs.compare_any = true,
            .fallback_dupclosure => switch (try dupClosurePattern(snapshot, function, proto, instruction_id)) {
                .closed => needs.dupclosure = true,
                .captured => needs.newclosure_capture = true,
            },
            .newclosure => needs.newclosure_capture = true,
            .get_upvalue => needs.get_upvalue = true,
            .set_upvalue => needs.set_upvalue = true,
            .close_upvals => needs.close_upvalues = true,
            .call => {
                needs.call = true;
                if (!static_package or !try isStaticRequireCall(snapshot, function, instruction_id))
                    needs.exchange_continuation = true;
            },
            .interrupt => needs.exchange_continuation = true,
            .set_savedpc => needs.set_location = true,
            ir_cmd_new_table => {
                const owns_immediate_gc = instruction_id + 3 < function.instruction_count and
                    (try snapshot.irInstruction(function, instruction_id + 3)).command == .check_gc;
                if (owns_immediate_gc) {
                    needs.new_table = true;
                } else {
                    needs.new_table_deferred = true;
                    needs.check_gc = true;
                }
            },
            ir_cmd_new_userdata => needs.new_userdata = true,
            ir_cmd_check_userdata_tag => needs.check_userdata_tag = true,
            ir_cmd_barrier_object => needs.barrier_object = true,
            ir_cmd_barrier_table_back => needs.barrier_table_back = true,
            .load_tvalue => {
                if (instruction_value.operand_count >= 1) {
                    const source = try snapshot.irOperand(instruction_value, 0);
                    if (instruction_value.operand_count == 3 and instruction_id + 1 < function.instruction_count) {
                        const store = try snapshot.irInstruction(function, instruction_id + 1);
                        if (source.kind == .vm_const and store.command == .store_tvalue and store.operand_count == 2) {
                            const stored = try snapshot.irOperand(store, 1);
                            if (stored.kind == .instruction and stored.value == instruction_id)
                                needs.load_constant = true;
                        }
                    } else if (instruction_value.operand_count == 1 and source.kind == .vm_const and
                        source.value < proto.vm_constant_count and instruction_id + 2 < function.instruction_count)
                    {
                        const select = try snapshot.irInstruction(function, instruction_id + 1);
                        const store = try snapshot.irInstruction(function, instruction_id + 2);
                        if (select.command == .select_if_truthy and select.operand_count == 3 and
                            store.command == .store_tvalue and store.operand_count == 2)
                        {
                            const condition = try snapshot.irOperand(select, 0);
                            const true_value = try snapshot.irOperand(select, 1);
                            const false_value = try snapshot.irOperand(select, 2);
                            const stored = try snapshot.irOperand(store, 1);
                            const kind = (try snapshot.vmConstant(proto, source.value)).kind;
                            const materialized = switch (kind) {
                                .nil, .boolean, .number, .vector, .string, .integer, .table => true,
                                .import, .closure, .class_shape => false,
                            };
                            if (materialized and condition.kind == true_value.kind and
                                condition.value == true_value.value and false_value.kind == .instruction and
                                false_value.value == instruction_id and stored.kind == .instruction and
                                stored.value == instruction_id + 1)
                                needs.load_constant = true;
                        }
                    }
                }
            },
            ir_cmd_dup_table => needs.dup_table = true,
            ir_cmd_table_setnum => needs.table_insert_append = true,
            ir_cmd_fallback_namecall => {
                needs.namecall_plain = true;
                needs.set_location = true;
            },
            ir_cmd_setlist => needs.set_list = true,
            ir_cmd_set_table => {
                needs.array_set = true;
                needs.table_set = true;
                needs.table_array_set = true;
            },
            ir_cmd_get_table => {
                needs.array_get = true;
                needs.table_get = true;
                needs.table_array_get = true;
            },
            ir_cmd_get_arr_addr => needs.array_get = true,
            ir_cmd_table_len => needs.table_len = true,
            ir_cmd_do_len => needs.do_len = true,
            ir_cmd_concat => needs.concat = true,
            ir_cmd_fallback_forgprep => {
                needs.forg_prep = true;
                needs.set_location = true;
            },
            ir_cmd_forgloop => needs.forg_loop = true,
            ir_cmd_forgloop_fallback => {
                // Every emitted non-nil fallback is paired with a guarded loop arm.  Specialized
                // ipairs graphs encode the builtin arm as scalar IR rather than FORGLOOP, but the
                // semantic lowering still invokes the same builtin iterator helper there.
                needs.forg_loop = true;
                needs.forg_loop_call = true;
                needs.forg_loop_finish = true;
                needs.exchange_continuation = true;
            },
            ir_cmd_forgprep_xnext_fallback => {
                needs.forgprep_xnext_fallback = true;
                needs.set_location = true;
            },
            ir_cmd_fallback_settableks => {
                needs.table_set_string = true;
                needs.set_location = true;
            },
            ir_cmd_fallback_gettableks => {
                needs.table_get_string = true;
                needs.set_location = true;
            },
            .get_cached_import => {
                needs.get_global = true;
                needs.table_get_string = true;
                needs.set_location = true;
                needs.require_static = true;
            },
            ir_cmd_fallback_getglobal => {
                needs.get_global = true;
                needs.set_location = true;
            },
            ir_cmd_fallback_setglobal => {
                needs.set_global = true;
                needs.set_location = true;
            },
            ir_cmd_fastcall => needs.fastcall = true,
            ir_cmd_invoke_fastcall => {
                needs.fastcall = true;
                needs.check_safe_env = true;
            },
            ir_cmd_invoke_libm => needs.libm = true,
            .check_safe_env => needs.check_safe_env = true,
            .check_tag => if (instruction_value.operand_count == 3 and
                (try snapshot.irOperand(instruction_value, 2)).kind == .vm_exit)
            {
                needs.builtin_type_error = true;
                needs.set_location = true;
            },
            ir_cmd_get_type, ir_cmd_get_typeof => needs.type_name = true,
            .num_to_int64 => {
                needs.builtin_type_error = true;
                needs.builtin_number = true;
                needs.set_location = true;
            },
            ir_cmd_check_buffer_len => {
                needs.builtin_type_error = true;
                needs.builtin_number = true;
                needs.buffer_bounds_error = true;
                needs.set_location = true;
            },
            ir_cmd_buffer_readi8,
            ir_cmd_buffer_readu8,
            ir_cmd_buffer_writei8,
            ir_cmd_buffer_readi16,
            ir_cmd_buffer_readu16,
            ir_cmd_buffer_writei16,
            ir_cmd_buffer_readi32,
            ir_cmd_buffer_writei32,
            ir_cmd_buffer_readf32,
            ir_cmd_buffer_writef32,
            ir_cmd_buffer_readf64,
            ir_cmd_buffer_writef64,
            ir_cmd_buffer_readi64,
            ir_cmd_buffer_writei64,
            => {
                needs.builtin_type_error = true;
                needs.builtin_number = true;
                needs.buffer_bounds_error = true;
                needs.set_location = true;
            },
            .fallback_prepvarargs => needs.prep_varargs = true,
            .fallback_getvarargs => {
                needs.get_varargs_fixed = true;
                needs.get_varargs_multret = true;
            },
            else => {},
        }
    }
}

fn addRuntimeImports(object: *wasm.Object, needs: ImportNeeds) Error!RuntimeImports {
    const return_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const interrupt_params = [_]wasm.ValueType{ .i32, .i32 };
    const do_arith_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32, .i32 };
    const compare_any_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const dupclosure_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const newclosure_capture_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32 };
    const get_upvalue_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const set_upvalue_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const close_upvalues_params = [_]wasm.ValueType{ .i32, .i32 };
    const call_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const exchange_continuation_params = [_]wasm.ValueType{ .i32, .i32 };
    const set_location_params = [_]wasm.ValueType{ .i32, .i32 };
    const new_table_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const new_userdata_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const check_userdata_tag_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const barrier_object_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const barrier_table_back_params = [_]wasm.ValueType{ .i32, .i32 };
    const register_pair_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const set_list_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32, .i32, .i32 };
    const array_operation_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const table_len_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const concat_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const do_len_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const forg_prep_params = [_]wasm.ValueType{ .i32, .i32 };
    const forg_loop_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const string_table_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32, .i32 };
    const generic_table_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const prep_varargs_params = [_]wasm.ValueType{ .i32, .i32 };
    const get_varargs_fixed_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const get_varargs_multret_params = [_]wasm.ValueType{ .i32, .i32 };
    const require_static_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const fastcall_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 };
    const type_name_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const builtin_type_error_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32, .i32, .i32 };
    const builtin_number_params = [_]wasm.ValueType{ .i32, .i32 };
    const state_params = [_]wasm.ValueType{.i32};
    const unary_f64_results = [_]wasm.ValueType{.f64};
    const libm_params = [_]wasm.ValueType{ .i32, .f64, .f64 };
    const generated_params = [_]wasm.ValueType{ .i32, .i32 };
    const no_results = [_]wasm.ValueType{};
    const status_result = [_]wasm.ValueType{.i32};

    const return_type = try object.addType(.{ .params = &return_params, .results = &no_results });
    const interrupt_type = try object.addType(.{ .params = &interrupt_params, .results = &status_result });
    const generated_type = try object.addType(.{ .params = &generated_params, .results = &status_result });
    const return_ = try object.importFunction("env", return_symbol, return_type);
    const interrupt = try object.importFunction("env", interrupt_symbol, interrupt_type);
    const do_arith = if (needs.do_arith) blk: {
        const helper_type = try object.addType(.{ .params = &do_arith_params, .results = &no_results });
        break :blk try object.importFunction("env", do_arith_symbol, helper_type);
    } else null;
    const compare_any = if (needs.compare_any) blk: {
        const helper_type = try object.addType(.{ .params = &compare_any_params, .results = &status_result });
        break :blk try object.importFunction("env", compare_any_symbol, helper_type);
    } else null;
    const dupclosure = if (needs.dupclosure) blk: {
        const helper_type = try object.addType(.{ .params = &dupclosure_params, .results = &no_results });
        break :blk try object.importFunction("env", dupclosure_symbol, helper_type);
    } else null;
    const newclosure_capture = if (needs.newclosure_capture) blk: {
        const helper_type = try object.addType(.{ .params = &newclosure_capture_params, .results = &no_results });
        break :blk try object.importFunction("env", newclosure_capture_symbol, helper_type);
    } else null;
    const get_upvalue = if (needs.get_upvalue) blk: {
        const helper_type = try object.addType(.{ .params = &get_upvalue_params, .results = &no_results });
        break :blk try object.importFunction("env", get_upvalue_symbol, helper_type);
    } else null;
    const set_upvalue = if (needs.set_upvalue) blk: {
        const helper_type = try object.addType(.{ .params = &set_upvalue_params, .results = &no_results });
        break :blk try object.importFunction("env", set_upvalue_symbol, helper_type);
    } else null;
    const close_upvalues = if (needs.close_upvalues) blk: {
        const helper_type = try object.addType(.{ .params = &close_upvalues_params, .results = &no_results });
        break :blk try object.importFunction("env", close_upvalues_symbol, helper_type);
    } else null;
    const call = if (needs.call) blk: {
        const helper_type = try object.addType(.{ .params = &call_params, .results = &status_result });
        break :blk try object.importFunction("env", call_symbol, helper_type);
    } else null;
    const exchange_continuation = if (needs.exchange_continuation) blk: {
        const helper_type = try object.addType(.{ .params = &exchange_continuation_params, .results = &status_result });
        break :blk try object.importFunction("env", exchange_continuation_symbol, helper_type);
    } else null;
    const set_location = if (needs.set_location) blk: {
        const helper_type = try object.addType(.{ .params = &set_location_params, .results = &no_results });
        break :blk try object.importFunction("env", set_location_symbol, helper_type);
    } else null;
    const new_table = if (needs.new_table) blk: {
        const helper_type = try object.addType(.{ .params = &new_table_params, .results = &no_results });
        break :blk try object.importFunction("env", new_table_symbol, helper_type);
    } else null;
    const new_table_deferred = if (needs.new_table_deferred) blk: {
        const helper_type = try object.addType(.{ .params = &new_table_params, .results = &no_results });
        break :blk try object.importFunction("env", new_table_deferred_symbol, helper_type);
    } else null;
    const check_gc = if (needs.check_gc) blk: {
        const helper_type = try object.addType(.{ .params = &state_params, .results = &no_results });
        break :blk try object.importFunction("env", check_gc_symbol, helper_type);
    } else null;
    const new_userdata = if (needs.new_userdata) blk: {
        const helper_type = try object.addType(.{ .params = &new_userdata_params, .results = &status_result });
        break :blk try object.importFunction("env", new_userdata_symbol, helper_type);
    } else null;
    const check_userdata_tag = if (needs.check_userdata_tag) blk: {
        const helper_type = try object.addType(.{ .params = &check_userdata_tag_params, .results = &status_result });
        break :blk try object.importFunction("env", check_userdata_tag_symbol, helper_type);
    } else null;
    const barrier_object = if (needs.barrier_object) blk: {
        const helper_type = try object.addType(.{ .params = &barrier_object_params, .results = &no_results });
        break :blk try object.importFunction("env", barrier_object_symbol, helper_type);
    } else null;
    const barrier_table_back = if (needs.barrier_table_back) blk: {
        const helper_type = try object.addType(.{ .params = &barrier_table_back_params, .results = &no_results });
        break :blk try object.importFunction("env", barrier_table_back_symbol, helper_type);
    } else null;
    const load_constant = if (needs.load_constant) blk: {
        const helper_type = try object.addType(.{ .params = &register_pair_params, .results = &no_results });
        break :blk try object.importFunction("env", load_constant_symbol, helper_type);
    } else null;
    const dup_table = if (needs.dup_table) blk: {
        const helper_type = try object.addType(.{ .params = &register_pair_params, .results = &no_results });
        break :blk try object.importFunction("env", dup_table_symbol, helper_type);
    } else null;
    const table_insert_append = if (needs.table_insert_append) blk: {
        const helper_type = try object.addType(.{ .params = &register_pair_params, .results = &no_results });
        break :blk try object.importFunction("env", table_insert_append_symbol, helper_type);
    } else null;
    const namecall_plain = if (needs.namecall_plain) blk: {
        const helper_type = try object.addType(.{ .params = &string_table_params, .results = &no_results });
        break :blk try object.importFunction("env", namecall_plain_symbol, helper_type);
    } else null;
    const set_list = if (needs.set_list) blk: {
        const helper_type = try object.addType(.{ .params = &set_list_params, .results = &no_results });
        break :blk try object.importFunction("env", set_list_symbol, helper_type);
    } else null;
    const array_set = if (needs.array_set) blk: {
        const helper_type = try object.addType(.{ .params = &array_operation_params, .results = &no_results });
        break :blk try object.importFunction("env", array_set_symbol, helper_type);
    } else null;
    const array_get = if (needs.array_get) blk: {
        const helper_type = try object.addType(.{ .params = &array_operation_params, .results = &no_results });
        break :blk try object.importFunction("env", array_get_symbol, helper_type);
    } else null;
    const table_len = if (needs.table_len) blk: {
        const helper_type = try object.addType(.{ .params = &table_len_params, .results = &no_results });
        break :blk try object.importFunction("env", table_len_symbol, helper_type);
    } else null;
    const concat = if (needs.concat) blk: {
        const helper_type = try object.addType(.{ .params = &concat_params, .results = &no_results });
        break :blk try object.importFunction("env", concat_symbol, helper_type);
    } else null;
    const do_len = if (needs.do_len) blk: {
        const helper_type = try object.addType(.{ .params = &do_len_params, .results = &no_results });
        break :blk try object.importFunction("env", do_len_symbol, helper_type);
    } else null;
    const forg_prep = if (needs.forg_prep) blk: {
        const helper_type = try object.addType(.{ .params = &forg_prep_params, .results = &no_results });
        break :blk try object.importFunction("env", forg_prep_symbol, helper_type);
    } else null;
    const forg_loop = if (needs.forg_loop) blk: {
        const helper_type = try object.addType(.{ .params = &forg_loop_params, .results = &status_result });
        break :blk try object.importFunction("env", forg_loop_symbol, helper_type);
    } else null;
    const forg_loop_call = if (needs.forg_loop_call) blk: {
        const helper_type = try object.addType(.{ .params = &forg_loop_params, .results = &status_result });
        break :blk try object.importFunction("env", forg_loop_call_symbol, helper_type);
    } else null;
    const forg_loop_finish = if (needs.forg_loop_finish) blk: {
        const helper_type = try object.addType(.{ .params = &forg_loop_params, .results = &status_result });
        break :blk try object.importFunction("env", forg_loop_finish_symbol, helper_type);
    } else null;
    const forgprep_xnext_fallback = if (needs.forgprep_xnext_fallback) blk: {
        const helper_type = try object.addType(.{ .params = &forg_prep_params, .results = &no_results });
        break :blk try object.importFunction("env", forgprep_xnext_fallback_symbol, helper_type);
    } else null;
    const table_set_string = if (needs.table_set_string) blk: {
        const helper_type = try object.addType(.{ .params = &string_table_params, .results = &no_results });
        break :blk try object.importFunction("env", table_set_string_symbol, helper_type);
    } else null;
    const table_get_string = if (needs.table_get_string) blk: {
        const helper_type = try object.addType(.{ .params = &string_table_params, .results = &no_results });
        break :blk try object.importFunction("env", table_get_string_symbol, helper_type);
    } else null;
    const table_set = if (needs.table_set) blk: {
        const helper_type = try object.addType(.{ .params = &generic_table_params, .results = &no_results });
        break :blk try object.importFunction("env", table_set_symbol, helper_type);
    } else null;
    const table_get = if (needs.table_get) blk: {
        const helper_type = try object.addType(.{ .params = &generic_table_params, .results = &no_results });
        break :blk try object.importFunction("env", table_get_symbol, helper_type);
    } else null;
    const table_array_set = if (needs.table_array_set) blk: {
        const helper_type = try object.addType(.{ .params = &generic_table_params, .results = &status_result });
        break :blk try object.importFunction("env", table_array_set_symbol, helper_type);
    } else null;
    const table_array_get = if (needs.table_array_get) blk: {
        const helper_type = try object.addType(.{ .params = &generic_table_params, .results = &status_result });
        break :blk try object.importFunction("env", table_array_get_symbol, helper_type);
    } else null;
    const get_global = if (needs.get_global) blk: {
        const helper_type = try object.addType(.{ .params = &generic_table_params, .results = &no_results });
        break :blk try object.importFunction("env", get_global_symbol, helper_type);
    } else null;
    const set_global = if (needs.set_global) blk: {
        const helper_type = try object.addType(.{ .params = &generic_table_params, .results = &no_results });
        break :blk try object.importFunction("env", set_global_symbol, helper_type);
    } else null;
    const prep_varargs = if (needs.prep_varargs) blk: {
        const helper_type = try object.addType(.{ .params = &prep_varargs_params, .results = &no_results });
        break :blk try object.importFunction("env", prep_varargs_symbol, helper_type);
    } else null;
    const get_varargs_fixed = if (needs.get_varargs_fixed) blk: {
        const helper_type = try object.addType(.{ .params = &get_varargs_fixed_params, .results = &no_results });
        break :blk try object.importFunction("env", get_varargs_fixed_symbol, helper_type);
    } else null;
    const get_varargs_multret = if (needs.get_varargs_multret) blk: {
        const helper_type = try object.addType(.{ .params = &get_varargs_multret_params, .results = &no_results });
        break :blk try object.importFunction("env", get_varargs_multret_symbol, helper_type);
    } else null;
    const require_static = if (needs.require_static) blk: {
        const helper_type = try object.addType(.{ .params = &require_static_params, .results = &status_result });
        break :blk try object.importFunction("env", require_static_symbol, helper_type);
    } else null;
    const check_safe_env = if (needs.check_safe_env) blk: {
        const helper_type = try object.addType(.{ .params = &state_params, .results = &status_result });
        break :blk try object.importFunction("env", check_safe_env_symbol, helper_type);
    } else null;
    const fastcall = if (needs.fastcall) blk: {
        const helper_type = try object.addType(.{ .params = &fastcall_params, .results = &status_result });
        break :blk try object.importFunction("env", fastcall_symbol, helper_type);
    } else null;
    const type_name = if (needs.type_name) blk: {
        const helper_type = try object.addType(.{ .params = &type_name_params, .results = &status_result });
        break :blk try object.importFunction("env", type_name_symbol, helper_type);
    } else null;
    const libm = if (needs.libm) blk: {
        const helper_type = try object.addType(.{ .params = &libm_params, .results = &unary_f64_results });
        break :blk try object.importFunction("env", libm_symbol, helper_type);
    } else null;
    const builtin_type_error = if (needs.builtin_type_error) blk: {
        const helper_type = try object.addType(.{ .params = &builtin_type_error_params, .results = &status_result });
        break :blk try object.importFunction("env", builtin_type_error_symbol, helper_type);
    } else null;
    const builtin_number = if (needs.builtin_number) blk: {
        const helper_type = try object.addType(.{ .params = &builtin_number_params, .results = &unary_f64_results });
        break :blk try object.importFunction("env", builtin_number_symbol, helper_type);
    } else null;
    const buffer_bounds_error = if (needs.buffer_bounds_error) blk: {
        const helper_type = try object.addType(.{ .params = &state_params, .results = &no_results });
        break :blk try object.importFunction("env", buffer_bounds_error_symbol, helper_type);
    } else null;
    return .{
        .return_ = return_,
        .interrupt = interrupt,
        .do_arith = do_arith,
        .compare_any = compare_any,
        .dupclosure = dupclosure,
        .newclosure_capture = newclosure_capture,
        .get_upvalue = get_upvalue,
        .set_upvalue = set_upvalue,
        .close_upvalues = close_upvalues,
        .call = call,
        .exchange_continuation = exchange_continuation,
        .set_location = set_location,
        .new_table = new_table,
        .new_table_deferred = new_table_deferred,
        .check_gc = check_gc,
        .new_userdata = new_userdata,
        .check_userdata_tag = check_userdata_tag,
        .barrier_object = barrier_object,
        .barrier_table_back = barrier_table_back,
        .load_constant = load_constant,
        .dup_table = dup_table,
        .table_insert_append = table_insert_append,
        .namecall_plain = namecall_plain,
        .set_list = set_list,
        .array_set = array_set,
        .array_get = array_get,
        .table_len = table_len,
        .concat = concat,
        .do_len = do_len,
        .forg_prep = forg_prep,
        .forg_loop = forg_loop,
        .forg_loop_call = forg_loop_call,
        .forg_loop_finish = forg_loop_finish,
        .forgprep_xnext_fallback = forgprep_xnext_fallback,
        .table_set_string = table_set_string,
        .table_get_string = table_get_string,
        .table_set = table_set,
        .table_get = table_get,
        .table_array_set = table_array_set,
        .table_array_get = table_array_get,
        .get_global = get_global,
        .set_global = set_global,
        .check_safe_env = check_safe_env,
        .fastcall = fastcall,
        .type_name = type_name,
        .libm = libm,
        .builtin_type_error = builtin_type_error,
        .builtin_number = builtin_number,
        .buffer_bounds_error = buffer_bounds_error,
        .prep_varargs = prep_varargs,
        .get_varargs_fixed = get_varargs_fixed,
        .get_varargs_multret = get_varargs_multret,
        .require_static = require_static,
        .generated_type = generated_type,
    };
}

fn lowerFunction(
    allocator: std.mem.Allocator,
    snapshot: snapshot_v1.Snapshot,
    function_id: u32,
    object: *wasm.Object,
    imports: RuntimeImports,
    symbol_name: []const u8,
    static_package: ?static_package_v1.Package,
    function_id_base: u32,
    string_keys: *StringKeyPool,
) Error!wasm.FunctionRef {
    const function = try snapshot.irFunction(function_id);
    const proto = try snapshot.proto(function.proto_id);
    if (function.variadic != proto.is_vararg)
        return Error.UnsupportedVariadicFunction;

    const entry_block = try snapshot.irBlock(function, function.entry_block);
    if (!entry_block.kind.isCompilable() or entry_block.isEmpty())
        return Error.UnsupportedControlFlow;

    const slots = try allocator.alloc(ValueSlot, function.instruction_count);
    defer allocator.free(slots);
    @memset(slots, .{});
    const builtin_number_sources = try allocator.alloc(u32, function.instruction_count);
    defer allocator.free(builtin_number_sources);
    @memset(builtin_number_sources, std.math.maxInt(u32));

    var locals: std.ArrayList(wasm.Local) = .empty;
    defer locals.deinit(allocator);
    try locals.append(allocator, .{ .count = 5, .value_type = .i32 });
    var next_local: u32 = 7; // parameters 0/1; base, dispatcher, helper status, continuation, table index are 2..6.

    var instruction_id: u32 = 0;
    while (instruction_id < function.instruction_count) : (instruction_id += 1) {
        const instruction_value = try snapshot.irInstruction(function, instruction_id);
        const shape = resultShape(instruction_value.command);
        slots[instruction_id].shape = shape;
        switch (shape) {
            .none => {},
            .i32 => {
                if (next_local >= max_lowered_locals)
                    return Error.ResourceLimit;
                slots[instruction_id].first = next_local;
                next_local += 1;
                try locals.append(allocator, .{ .count = 1, .value_type = .i32 });
            },
            .pointer => {
                if (next_local >= max_lowered_locals)
                    return Error.ResourceLimit;
                slots[instruction_id].first = next_local;
                next_local += 1;
                try locals.append(allocator, .{ .count = 1, .value_type = .i32 });
            },
            .i64 => {
                if (next_local >= max_lowered_locals)
                    return Error.ResourceLimit;
                slots[instruction_id].first = next_local;
                next_local += 1;
                try locals.append(allocator, .{ .count = 1, .value_type = .i64 });
            },
            .f32 => {
                if (next_local >= max_lowered_locals)
                    return Error.ResourceLimit;
                slots[instruction_id].first = next_local;
                next_local += 1;
                try locals.append(allocator, .{ .count = 1, .value_type = .f32 });
            },
            .f64 => {
                if (next_local >= max_lowered_locals)
                    return Error.ResourceLimit;
                slots[instruction_id].first = next_local;
                next_local += 1;
                try locals.append(allocator, .{ .count = 1, .value_type = .f64 });
            },
            .tvalue => {
                if (next_local > max_lowered_locals - 2)
                    return Error.ResourceLimit;
                slots[instruction_id].first = next_local;
                slots[instruction_id].second = next_local + 1;
                next_local += 2;
                try locals.append(allocator, .{ .count = 2, .value_type = .i64 });
            },
        }
    }

    var body = try wasm.Body.init(allocator, locals.items);
    defer body.deinit(allocator);
    var context = Context{
        .allocator = allocator,
        .snapshot = snapshot,
        .proto = proto,
        .function = function,
        .slots = slots,
        .builtin_number_sources = builtin_number_sources,
        .body = &body,
        .return_ = imports.return_,
        .interrupt = imports.interrupt,
        .do_arith = imports.do_arith,
        .compare_any = imports.compare_any,
        .dupclosure = imports.dupclosure,
        .newclosure_capture = imports.newclosure_capture,
        .get_upvalue = imports.get_upvalue,
        .set_upvalue = imports.set_upvalue,
        .close_upvalues = imports.close_upvalues,
        .call = imports.call,
        .exchange_continuation = imports.exchange_continuation,
        .set_location = imports.set_location,
        .new_table = imports.new_table,
        .new_table_deferred = imports.new_table_deferred,
        .check_gc = imports.check_gc,
        .new_userdata = imports.new_userdata,
        .check_userdata_tag = imports.check_userdata_tag,
        .barrier_object = imports.barrier_object,
        .barrier_table_back = imports.barrier_table_back,
        .load_constant = imports.load_constant,
        .dup_table = imports.dup_table,
        .table_insert_append = imports.table_insert_append,
        .namecall_plain = imports.namecall_plain,
        .set_list = imports.set_list,
        .array_set = imports.array_set,
        .array_get = imports.array_get,
        .table_len = imports.table_len,
        .concat = imports.concat,
        .do_len = imports.do_len,
        .forg_prep = imports.forg_prep,
        .forg_loop = imports.forg_loop,
        .forg_loop_call = imports.forg_loop_call,
        .forg_loop_finish = imports.forg_loop_finish,
        .forgprep_xnext_fallback = imports.forgprep_xnext_fallback,
        .table_set_string = imports.table_set_string,
        .table_get_string = imports.table_get_string,
        .table_set = imports.table_set,
        .table_get = imports.table_get,
        .table_array_set = imports.table_array_set,
        .table_array_get = imports.table_array_get,
        .get_global = imports.get_global,
        .set_global = imports.set_global,
        .check_safe_env = imports.check_safe_env,
        .fastcall = imports.fastcall,
        .type_name = imports.type_name,
        .builtin_type_error = imports.builtin_type_error,
        .builtin_number = imports.builtin_number,
        .buffer_bounds_error = imports.buffer_bounds_error,
        .libm = imports.libm,
        .prep_varargs = imports.prep_varargs,
        .get_varargs_fixed = imports.get_varargs_fixed,
        .get_varargs_multret = imports.get_varargs_multret,
        .require_static = imports.require_static,
        .static_package = static_package,
        .function_id_base = function_id_base,
        .base_local = 2,
        .dispatch_local = 3,
        .status_local = 4,
        .continuation_local = 5,
        .table_index_local = 6,
        .call_continuations = &.{},
        .string_keys = string_keys,
    };
    try context.classifyBuiltinNumberLoads();
    const call_continuations = try collectCallContinuations(allocator, context);
    defer allocator.free(call_continuations);
    context.call_continuations = call_continuations;
    if (call_continuations.len == 0 and context.exchange_continuation != null)
        context.exchange_continuation = null;
    if (call_continuations.len != 0 and context.exchange_continuation == null)
        return Error.UnsupportedCommand;

    var block_id: u32 = 0;
    while (block_id < function.block_count) : (block_id += 1) {
        const block = try snapshot.irBlock(function, block_id);
        if (block.kind == .fallback and try context.supportsArithmeticFallback(block)) {
            if (context.do_arith == null)
                return Error.UnsupportedCommand;
        } else if (block.kind == .fallback and
            ((try context.supportsComparisonFallback(block)) or (try context.supportsMaterializedComparisonFallback(block))))
        {
            if (context.compare_any == null)
                return Error.UnsupportedCommand;
        }
    }

    try context.emitReloadBase();
    if (call_continuations.len == 0) {
        try body.i32Const(allocator, @intCast(function.entry_block));
        try body.localSet(allocator, context.dispatch_local);
    } else {
        try context.emitExchangeContinuation(0);
        try body.localTee(allocator, context.continuation_local);
        try body.i32Eqz(allocator);
        try body.ifVoid(allocator);
        try body.i32Const(allocator, @intCast(function.entry_block));
        try body.localSet(allocator, context.dispatch_local);
        try body.else_(allocator);
        try body.localGet(allocator, context.continuation_local);
        try body.i32Const(allocator, @intCast(function.block_count));
        try body.opcode(allocator, 0x6a); // i32.add
        try body.localSet(allocator, context.dispatch_local);
        try body.end(allocator);
    }
    try body.loop(allocator);

    block_id = 0;
    while (block_id < function.block_count) : (block_id += 1) {
        const block = try snapshot.irBlock(function, block_id);
        const bypassed = try context.isBypassedEmissionBlock(block_id, block);
        if (block.kind.isCompilable() and !block.isEmpty() and !bypassed)
            try context.emitBlock(block_id, block)
        else if (block.kind == .fallback and !bypassed and try context.supportsFallback(block))
            try context.emitBlock(block_id, block);
    }
    for (call_continuations) |continuation|
        try context.emitCallContinuation(continuation);

    // Reaching the bottom means a malformed/generated dispatch target escaped static validation.
    try context.emitStatusReturn(status_internal_error);
    try body.end(allocator);
    try body.i32Const(allocator, status_internal_error);
    try body.finish(allocator);

    return object.defineFunction(symbol_name, imports.generated_type, wasm.symbol.visibility_hidden, body);
}

pub fn build(allocator: std.mem.Allocator, snapshot_bytes: []const u8, function_id: u32) Error![]u8 {
    const snapshot = try snapshot_v1.parse(snapshot_bytes, snapshot_v1.production_identity);
    try snapshot_v1.validateModel(snapshot);
    if (function_id >= snapshot.header.ir_function_count)
        return Error.FunctionOutOfBounds;

    var needs = ImportNeeds{};
    try scanImportNeeds(snapshot, function_id, false, &needs);
    var object = wasm.Object.init(allocator);
    defer object.deinit();
    var string_keys = StringKeyPool{};
    defer string_keys.deinit(allocator);
    const imports = try addRuntimeImports(&object, needs);
    _ = try lowerFunction(allocator, snapshot, function_id, &object, imports, generated_symbol, null, 0, &string_keys);
    try emitStringKeyData(&object, string_keys);
    return object.emit();
}

pub fn buildPackage(allocator: std.mem.Allocator, snapshot_bytes: []const u8) Error![]u8 {
    const snapshot = try snapshot_v1.parse(snapshot_bytes, snapshot_v1.production_identity);
    try snapshot_v1.validateModel(snapshot);

    var needs = ImportNeeds{};
    var function_id: u32 = 0;
    while (function_id < snapshot.header.ir_function_count) : (function_id += 1)
        try scanImportNeeds(snapshot, function_id, false, &needs);

    var object = wasm.Object.init(allocator);
    defer object.deinit();
    var string_keys = StringKeyPool{};
    defer string_keys.deinit(allocator);
    const imports = try addRuntimeImports(&object, needs);

    function_id = 0;
    while (function_id < snapshot.header.ir_function_count) : (function_id += 1) {
        const symbol_name = try std.fmt.allocPrint(allocator, "luauc_runtime_v1_function_{d:0>8}", .{function_id});
        defer allocator.free(symbol_name);
        _ = try lowerFunction(allocator, snapshot, function_id, &object, imports, symbol_name, null, 0, &string_keys);
    }
    try emitStringKeyData(&object, string_keys);
    return object.emit();
}

fn emitStringKeyData(object: *wasm.Object, string_keys: StringKeyPool) Error!void {
    if (string_keys.entries.items.len == 0)
        return;
    const data = try object.defineData(
        ".rodata.luauc_runtime_v1_string_keys",
        generated_string_keys_symbol,
        wasm.symbol.visibility_hidden,
        0,
        string_keys.bytes.items,
    );
    if (data.segment_index != 0)
        return Error.UnsupportedControlFlow;
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

const ProtoConstantSpan = struct {
    constant_offset: u32 = 0,
    constant_count: u32 = 0,
    item_offset: u32 = 0,
    item_count: u32 = 0,
};

const ConstantStringRelocation = struct {
    descriptor_offset: u32,
    string_offset: u32,
};

fn appendProtoConstantMetadata(
    allocator: std.mem.Allocator,
    snapshot: snapshot_v1.Snapshot,
    proto: snapshot_v1.Proto,
    constant_bytes: *std.ArrayList(u8),
    item_bytes: *std.ArrayList(u8),
    constant_strings: *StringKeyPool,
    string_relocations: *std.ArrayList(ConstantStringRelocation),
) Error!ProtoConstantSpan {
    if (constant_bytes.items.len > std.math.maxInt(u32) or item_bytes.items.len > std.math.maxInt(u32))
        return Error.ResourceLimit;
    const constant_offset: u32 = @intCast(constant_bytes.items.len);
    const item_offset: u32 = @intCast(item_bytes.items.len);
    var local_item_count: u32 = 0;

    var constant_id: u32 = 0;
    while (constant_id < proto.vm_constant_count) : (constant_id += 1) {
        const constant = try snapshot.vmConstant(proto, constant_id);
        const descriptor_offset_usize = constant_bytes.items.len;
        try constant_bytes.appendNTimes(allocator, 0, aot_constant_size);
        const descriptor = constant_bytes.items[descriptor_offset_usize..][0..aot_constant_size];
        descriptor[0] = @intFromEnum(constant.kind);
        switch (constant.kind) {
            .nil => {},
            .boolean => writeU32(descriptor, 4, constant.payload0),
            .number, .integer => {
                writeU32(descriptor, 4, @truncate(constant.bits0));
                writeU32(descriptor, 8, @truncate(constant.bits0 >> 32));
            },
            .vector => {
                writeU32(descriptor, 4, constant.payload0);
                writeU32(descriptor, 8, constant.payload1);
                writeU32(descriptor, 12, constant.payload2);
            },
            .string => {
                const value = try snapshot.string(constant.payload0);
                const entry = try constant_strings.intern(allocator, value);
                writeU32(descriptor, 8, entry.length);
                try string_relocations.append(allocator, .{
                    .descriptor_offset = @intCast(descriptor_offset_usize + 4),
                    .string_offset = entry.offset,
                });
            },
            .table => {
                writeU32(descriptor, 4, local_item_count);
                writeU32(descriptor, 8, constant.payload1);
                var item_id: u32 = 0;
                while (item_id < constant.payload1) : (item_id += 1) {
                    const item = try snapshot.vmConstantItem(std.math.add(u32, constant.payload0, item_id) catch
                        return Error.ResourceLimit);
                    const item_record_offset = item_bytes.items.len;
                    try item_bytes.appendNTimes(allocator, 0, aot_constant_item_size);
                    const item_record = item_bytes.items[item_record_offset..][0..aot_constant_item_size];
                    writeU32(item_record, 0, item.key);
                    writeU32(item_record, 4, item.value);
                }
                local_item_count = std.math.add(u32, local_item_count, constant.payload1) catch return Error.ResourceLimit;
            },
            .import, .closure, .class_shape => {},
        }
    }

    return .{
        .constant_offset = constant_offset,
        .constant_count = proto.vm_constant_count,
        .item_offset = item_offset,
        .item_count = local_item_count,
    };
}

fn emitStaticPackageMetadata(
    allocator: std.mem.Allocator,
    object: *wasm.Object,
    package: static_package_v1.Package,
    function_bases: []const u32,
    function_refs: []const wasm.FunctionRef,
) Error!void {
    const proto_bytes_size = std.math.mul(usize, function_refs.len, aot_proto_size) catch return Error.ResourceLimit;
    var proto_bytes = try allocator.alloc(u8, proto_bytes_size);
    defer allocator.free(proto_bytes);
    @memset(proto_bytes, 0);

    const proto_spans = try allocator.alloc(ProtoConstantSpan, function_refs.len);
    defer allocator.free(proto_spans);
    @memset(proto_spans, .{});
    var constant_bytes: std.ArrayList(u8) = .empty;
    defer constant_bytes.deinit(allocator);
    var item_bytes: std.ArrayList(u8) = .empty;
    defer item_bytes.deinit(allocator);
    var constant_strings = StringKeyPool{};
    defer constant_strings.deinit(allocator);
    var string_relocations: std.ArrayList(ConstantStringRelocation) = .empty;
    defer string_relocations.deinit(allocator);
    var module_sources = StringKeyPool{};
    defer module_sources.deinit(allocator);
    const module_source_offsets = try allocator.alloc(u32, @intCast(package.module_count));
    defer allocator.free(module_source_offsets);

    const module_bytes_size = std.math.mul(usize, @as(usize, @intCast(package.module_count)), aot_module_size) catch return Error.ResourceLimit;
    var module_bytes = try allocator.alloc(u8, module_bytes_size);
    defer allocator.free(module_bytes);
    @memset(module_bytes, 0);

    var module_id: u32 = 0;
    while (module_id < package.module_count) : (module_id += 1) {
        const module = try package.module(module_id);
        const snapshot = try snapshot_v1.parse(module.snapshot, snapshot_v1.production_identity);
        const function_base = function_bases[@intCast(module_id)];

        var local_id: u32 = 0;
        while (local_id < snapshot.header.proto_count) : (local_id += 1) {
            const proto = try snapshot.proto(local_id);
            const global_id = std.math.add(u32, function_base, local_id) catch return Error.ResourceLimit;
            const record_offset = std.math.mul(usize, @as(usize, @intCast(global_id)), aot_proto_size) catch return Error.ResourceLimit;
            const record = proto_bytes[record_offset..][0..aot_proto_size];
            writeU32(record, 0, aot_abi_version);
            writeU32(record, 4, aot_proto_size);
            @memcpy(record[8..40], &aot_layout_sha256);
            writeU32(record, 40, std.math.add(u32, global_id, 1) catch return Error.ResourceLimit);
            writeU32(record, 44, global_id);
            writeU32(record, 48, if (proto.parent_id == snapshot_v1.no_id)
                snapshot_v1.no_id
            else
                std.math.add(u32, function_base, proto.parent_id) catch return Error.ResourceLimit);
            writeU32(record, 52, if (proto.parent_id == snapshot_v1.no_id) aot_proto_root_flag else 0);
            record[56] = proto.num_params;
            record[57] = proto.nups;
            record[58] = @intFromBool(proto.is_vararg);
            record[59] = proto.max_stack_size;
            proto_spans[@intCast(global_id)] = try appendProtoConstantMetadata(
                allocator,
                snapshot,
                proto,
                &constant_bytes,
                &item_bytes,
                &constant_strings,
                &string_relocations,
            );
            writeU32(record, 64, proto.vm_constant_count);
            writeU32(record, 72, proto_spans[@intCast(global_id)].item_count);
        }

        const module_record_offset = std.math.mul(usize, @as(usize, @intCast(module_id)), aot_module_size) catch return Error.ResourceLimit;
        const module_record = module_bytes[module_record_offset..][0..aot_module_size];
        writeU32(module_record, 0, aot_abi_version);
        writeU32(module_record, 4, aot_module_size);
        @memcpy(module_record[8..40], &aot_layout_sha256);
        writeU32(module_record, 40, module_id);
        writeU32(module_record, 44, std.math.add(u32, function_base, snapshot.header.root_proto_id) catch return Error.ResourceLimit);
        const source = try module_sources.intern(allocator, module.source_name);
        module_source_offsets[@intCast(module_id)] = source.offset;
        writeU32(module_record, 52, source.length);
    }

    const data_flags = wasm.symbol.visibility_hidden;
    const constant_strings_data = if (constant_strings.entries.items.len != 0)
        try object.defineData(
            ".rodata.luauc_runtime_v1_constant_strings",
            "luauc_runtime_v1_constant_strings",
            data_flags,
            0,
            constant_strings.bytes.items,
        )
    else
        null;
    const constants_data = if (constant_bytes.items.len != 0)
        try object.defineData(
            ".rodata.luauc_runtime_v1_constants",
            "luauc_runtime_v1_constants",
            data_flags,
            2,
            constant_bytes.items,
        )
    else
        null;
    const items_data = if (item_bytes.items.len != 0)
        try object.defineData(
            ".rodata.luauc_runtime_v1_constant_items",
            "luauc_runtime_v1_constant_items",
            data_flags,
            2,
            item_bytes.items,
        )
    else
        null;
    const protos = try object.defineData(
        ".rodata.luauc_runtime_v1_protos",
        generated_protos_symbol,
        data_flags,
        2,
        proto_bytes,
    );
    const module_source_data = try object.defineData(
        ".rodata.luauc_runtime_v1_module_sources",
        "luauc_runtime_v1_module_sources",
        data_flags,
        0,
        module_sources.bytes.items,
    );
    const modules = try object.defineData(
        ".rodata.luauc_runtime_v1_modules",
        generated_modules_symbol,
        data_flags,
        2,
        module_bytes,
    );

    var program_bytes = [_]u8{0} ** aot_program_size;
    writeU32(&program_bytes, 0, aot_abi_version);
    writeU32(&program_bytes, 4, aot_program_size);
    @memcpy(program_bytes[8..40], &aot_layout_sha256);
    writeU32(&program_bytes, 40, protos.memory_offset);
    writeU32(&program_bytes, 44, @intCast(function_refs.len));
    const entry_module = try package.module(package.entry_module_id);
    const entry_snapshot = try snapshot_v1.parse(entry_module.snapshot, snapshot_v1.production_identity);
    writeU32(
        &program_bytes,
        48,
        std.math.add(u32, function_bases[@intCast(package.entry_module_id)], entry_snapshot.header.root_proto_id) catch return Error.ResourceLimit,
    );
    writeU32(&program_bytes, 56, modules.memory_offset);
    writeU32(&program_bytes, 60, package.module_count);
    writeU32(&program_bytes, 64, package.entry_module_id);
    const program = try object.defineData(
        ".rodata.luauc_runtime_v1_program",
        generated_program_symbol,
        0,
        2,
        &program_bytes,
    );

    for (function_refs, 0..) |function_ref, global_id| {
        const record_offset = std.math.mul(u32, @intCast(global_id), aot_proto_size) catch return Error.ResourceLimit;
        try object.relocateDataTableIndex(protos, record_offset + 40, function_ref);
        const span = proto_spans[global_id];
        if (span.constant_count != 0)
            try object.relocateDataMemoryAddress(
                protos,
                record_offset + 60,
                constants_data.?,
                std.math.cast(i32, span.constant_offset) orelse return Error.ResourceLimit,
            );
        if (span.item_count != 0)
            try object.relocateDataMemoryAddress(
                protos,
                record_offset + 68,
                items_data.?,
                std.math.cast(i32, span.item_offset) orelse return Error.ResourceLimit,
            );
    }
    if (constants_data) |data|
        for (string_relocations.items) |relocation|
            try object.relocateDataMemoryAddress(
                data,
                relocation.descriptor_offset,
                constant_strings_data orelse return Error.UnsupportedControlFlow,
                std.math.cast(i32, relocation.string_offset) orelse return Error.ResourceLimit,
            );
    module_id = 0;
    while (module_id < package.module_count) : (module_id += 1) {
        const record_offset = std.math.mul(u32, module_id, aot_module_size) catch return Error.ResourceLimit;
        try object.relocateDataMemoryAddress(
            modules,
            record_offset + 48,
            module_source_data,
            std.math.cast(i32, module_source_offsets[@intCast(module_id)]) orelse return Error.ResourceLimit,
        );
    }
    try object.relocateDataMemoryAddress(program, 40, protos, 0);
    try object.relocateDataMemoryAddress(program, 56, modules, 0);
}

pub fn buildStaticPackage(allocator: std.mem.Allocator, package_bytes: []const u8) Error![]u8 {
    const package = try static_package_v1.parse(package_bytes);
    const function_bases = try allocator.alloc(u32, @intCast(package.module_count));
    defer allocator.free(function_bases);

    var needs = ImportNeeds{};
    var total_functions: u32 = 0;
    var module_id: u32 = 0;
    while (module_id < package.module_count) : (module_id += 1) {
        const module = try package.module(module_id);
        const snapshot = try snapshot_v1.parse(module.snapshot, snapshot_v1.production_identity);
        try snapshot_v1.validateModel(snapshot);
        function_bases[@intCast(module_id)] = total_functions;
        total_functions = std.math.add(u32, total_functions, snapshot.header.ir_function_count) catch return Error.ResourceLimit;

        var function_id: u32 = 0;
        while (function_id < snapshot.header.ir_function_count) : (function_id += 1) {
            try scanImportNeeds(snapshot, function_id, true, &needs);
        }
    }
    if (total_functions == 0)
        return Error.UnsupportedControlFlow;

    var object = wasm.Object.init(allocator);
    defer object.deinit();
    var string_keys = StringKeyPool{};
    defer string_keys.deinit(allocator);
    const imports = try addRuntimeImports(&object, needs);
    const function_refs = try allocator.alloc(wasm.FunctionRef, @intCast(total_functions));
    defer allocator.free(function_refs);

    module_id = 0;
    while (module_id < package.module_count) : (module_id += 1) {
        const module = try package.module(module_id);
        const snapshot = try snapshot_v1.parse(module.snapshot, snapshot_v1.production_identity);
        const function_base = function_bases[@intCast(module_id)];
        var function_id: u32 = 0;
        while (function_id < snapshot.header.ir_function_count) : (function_id += 1) {
            const global_function_id = std.math.add(u32, function_base, function_id) catch return Error.ResourceLimit;
            const symbol_name = try std.fmt.allocPrint(allocator, "luauc_runtime_v1_function_{d:0>8}", .{global_function_id});
            defer allocator.free(symbol_name);
            function_refs[@intCast(global_function_id)] = try lowerFunction(
                allocator,
                snapshot,
                function_id,
                &object,
                imports,
                symbol_name,
                package,
                function_base,
                &string_keys,
            );
        }
    }
    try emitStringKeyData(&object, string_keys);
    try emitStaticPackageMetadata(allocator, &object, package, function_bases, function_refs);
    return object.emit();
}

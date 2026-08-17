const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const static_package_v1 = @import("luauc_backend_static_package_v1");
const wasm = @import("luauc_wasm_object");
const abi = @import("luauc_backend_runtime_abi");

const upstream_tm_add = abi.upstream_tm_add;
const upstream_tm_unm = abi.upstream_tm_unm;
const lbf_buffer_readi8 = abi.lbf_buffer_readi8;
const lbf_buffer_writef64 = abi.lbf_buffer_writef64;
const lbf_buffer_readinteger = abi.lbf_buffer_readinteger;
const lbf_buffer_writeinteger = abi.lbf_buffer_writeinteger;

pub const StringKeyPool = struct {
    pub const Entry = struct { offset: u32, length: u32 };

    bytes: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *StringKeyPool, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    pub fn intern(self: *StringKeyPool, allocator: std.mem.Allocator, key: []const u8) Error!Entry {
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

pub fn aotArithmeticOperation(upstream_operation: i32) ?i32 {
    if (upstream_operation < upstream_tm_add or upstream_operation > upstream_tm_unm)
        return null;
    return upstream_operation - upstream_tm_add;
}

pub fn rotateRight32(value: u32, comptime shift: u5) u32 {
    const inverse: u5 = @intCast(@as(u6, 32) - @as(u6, shift));
    return (value >> shift) | (value << inverse);
}

pub fn upstreamStringHash(key: []const u8) ?u32 {
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

pub const ImportNeeds = struct {
    coverage_hit: bool = false,
    do_arith: bool = false,
    compare_any: bool = false,
    dupclosure: bool = false,
    dupclosure_capture: bool = false,
    newclosure_empty: bool = false,
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
    set_userdata_metatable: bool = false,
    table_store: bool = false,
    barrier_table_forward: bool = false,
    hash_node_addr: bool = false,
    slot_node_addr: bool = false,
    node_slot_match: bool = false,
    try_get_tm: bool = false,
    check_node_no_next: bool = false,
    check_node_value: bool = false,
    closure_matches_proto_id: bool = false,
    check_readonly: bool = false,
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
    table_set_number: bool = false,
    table_get_number: bool = false,
    table_array_set: bool = false,
    table_array_get: bool = false,
    get_global: bool = false,
    set_global: bool = false,
    check_safe_env: bool = false,
    fastcall: bool = false,
    type_name: bool = false,
    builtin_type_error: bool = false,
    builtin_number: bool = false,
    forn_prepare: bool = false,
    buffer_bounds_error: bool = false,
    libm: bool = false,
    prep_varargs: bool = false,
    get_varargs_fixed: bool = false,
    get_varargs_multret: bool = false,
    require_static: bool = false,

    pub fn merge(self: *ImportNeeds, other: ImportNeeds) void {
        self.coverage_hit = self.coverage_hit or other.coverage_hit;
        self.do_arith = self.do_arith or other.do_arith;
        self.compare_any = self.compare_any or other.compare_any;
        self.dupclosure = self.dupclosure or other.dupclosure;
        self.dupclosure_capture = self.dupclosure_capture or other.dupclosure_capture;
        self.newclosure_empty = self.newclosure_empty or other.newclosure_empty;
        self.newclosure_capture = self.newclosure_capture or other.newclosure_capture;
        self.get_upvalue = self.get_upvalue or other.get_upvalue;
        self.set_upvalue = self.set_upvalue or other.set_upvalue;
        self.close_upvalues = self.close_upvalues or other.close_upvalues;
        self.call = self.call or other.call;
        self.exchange_continuation = self.exchange_continuation or other.exchange_continuation;
        self.set_location = self.set_location or other.set_location;
        self.new_table = self.new_table or other.new_table;
        self.new_table_deferred = self.new_table_deferred or other.new_table_deferred;
        self.check_gc = self.check_gc or other.check_gc;
        self.new_userdata = self.new_userdata or other.new_userdata;
        self.check_userdata_tag = self.check_userdata_tag or other.check_userdata_tag;
        self.barrier_object = self.barrier_object or other.barrier_object;
        self.barrier_table_back = self.barrier_table_back or other.barrier_table_back;
        self.set_userdata_metatable = self.set_userdata_metatable or other.set_userdata_metatable;
        self.table_store = self.table_store or other.table_store;
        self.barrier_table_forward = self.barrier_table_forward or other.barrier_table_forward;
        self.hash_node_addr = self.hash_node_addr or other.hash_node_addr;
        self.slot_node_addr = self.slot_node_addr or other.slot_node_addr;
        self.node_slot_match = self.node_slot_match or other.node_slot_match;
        self.try_get_tm = self.try_get_tm or other.try_get_tm;
        self.check_node_no_next = self.check_node_no_next or other.check_node_no_next;
        self.check_node_value = self.check_node_value or other.check_node_value;
        self.closure_matches_proto_id = self.closure_matches_proto_id or other.closure_matches_proto_id;
        self.check_readonly = self.check_readonly or other.check_readonly;
        self.load_constant = self.load_constant or other.load_constant;
        self.dup_table = self.dup_table or other.dup_table;
        self.table_insert_append = self.table_insert_append or other.table_insert_append;
        self.namecall_plain = self.namecall_plain or other.namecall_plain;
        self.set_list = self.set_list or other.set_list;
        self.array_set = self.array_set or other.array_set;
        self.array_get = self.array_get or other.array_get;
        self.table_len = self.table_len or other.table_len;
        self.concat = self.concat or other.concat;
        self.do_len = self.do_len or other.do_len;
        self.forg_prep = self.forg_prep or other.forg_prep;
        self.forg_loop = self.forg_loop or other.forg_loop;
        self.forg_loop_call = self.forg_loop_call or other.forg_loop_call;
        self.forg_loop_finish = self.forg_loop_finish or other.forg_loop_finish;
        self.forgprep_xnext_fallback = self.forgprep_xnext_fallback or other.forgprep_xnext_fallback;
        self.table_set_string = self.table_set_string or other.table_set_string;
        self.table_get_string = self.table_get_string or other.table_get_string;
        self.table_set = self.table_set or other.table_set;
        self.table_get = self.table_get or other.table_get;
        self.table_set_number = self.table_set_number or other.table_set_number;
        self.table_get_number = self.table_get_number or other.table_get_number;
        self.table_array_set = self.table_array_set or other.table_array_set;
        self.table_array_get = self.table_array_get or other.table_array_get;
        self.get_global = self.get_global or other.get_global;
        self.set_global = self.set_global or other.set_global;
        self.check_safe_env = self.check_safe_env or other.check_safe_env;
        self.fastcall = self.fastcall or other.fastcall;
        self.type_name = self.type_name or other.type_name;
        self.builtin_type_error = self.builtin_type_error or other.builtin_type_error;
        self.builtin_number = self.builtin_number or other.builtin_number;
        self.forn_prepare = self.forn_prepare or other.forn_prepare;
        self.buffer_bounds_error = self.buffer_bounds_error or other.buffer_bounds_error;
        self.libm = self.libm or other.libm;
        self.prep_varargs = self.prep_varargs or other.prep_varargs;
        self.get_varargs_fixed = self.get_varargs_fixed or other.get_varargs_fixed;
        self.get_varargs_multret = self.get_varargs_multret or other.get_varargs_multret;
        self.require_static = self.require_static or other.require_static;
    }
};

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

pub const ValueShape = enum {
    none,
    i32,
    pointer,
    i64,
    f32,
    f64,
    tvalue,
};

pub const ValueSlot = struct {
    shape: ValueShape = .none,
    first: u32 = snapshot_v1.no_id,
    second: u32 = snapshot_v1.no_id,
};

pub const CaptureKind = enum(u32) {
    value = 0,
    reference = 1,
    upvalue = 2,
};

pub const Capture = struct {
    kind: CaptureKind,
    source: u32,
};

pub const NewClosurePattern = struct {
    start: u32,
    finish: u32,
    destination: u32,
    child_proto_id: u32,
    capture_count: u32,
    capture_ir_start: u32,
    marker_start: u32,
    check_gc: bool,
};

pub const SetUpvaluePattern = struct {
    upvalue_index: u32,
    source_register: u32,
};

pub const StaticRequirePattern = struct {
    end: u32,
    interrupt_id: u32,
    destination: u32,
    module_id: u32,
};

pub const ContinuationAction = union(enum) {
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

pub const CallContinuation = struct {
    instruction_id: u32,
    continuation_id: u32,
    dispatch_id: u32,
    action: ContinuationAction,
};

pub const TableAllocationPattern = struct {
    start: u32,
    finish: u32,
    assist: bool,
    deferred_to_later_gc: bool,
    destination: u32,
    array_count: u32,
    node_count: u32,
};

pub const DupTablePattern = struct {
    start: u32,
    finish: u32,
    assist: bool,
    destination: u32,
    constant_id: u32,
};

pub const ConstantLoadPattern = struct {
    start: u32,
    finish: u32,
    destination: u32,
    constant_id: u32,
};

pub const ConstantTruthyFallbackPattern = struct {
    start: u32,
    finish: u32,
    destination: u32,
    constant_id: u32,
    true_value: snapshot_v1.IrOperand,
};

pub const ArrayOperationKind = enum { set, get, len };

pub const SemanticArrayOperation = struct {
    pattern: ArrayOperationPattern,
    kind: ArrayOperationKind,
};

pub const LiteralFieldSetPattern = struct {
    start: u32,
    finish: u32,
    pc: u32,
    table: u32,
    value: u32,
    materialized_tag: ?i32 = null,
    key: []const u8,
};

pub const TableInsertAppendPattern = struct {
    start: u32,
    finish: u32,
    table: u32,
    source: u32,
    constant_number: ?f64 = null,
};

pub const PlainTableNamecallPattern = struct {
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

pub const ArrayOperationPattern = struct {
    start: u32,
    destination: u32 = 0,
    table: u32,
    source: u32 = 0,
    index: u32 = 0,
    rejoin: u32,
};

pub const InlineArrayGetPattern = struct {
    start: u32,
    finish: u32,
    destination: u32,
    table: u32,
    index: u32,
};

pub const ConcatPattern = struct {
    start: u32,
    finish: u32,
    destination: u32,
    source: u32,
    count: u32,
};

pub const DynamicLengthPattern = struct {
    start: u32,
    destination: u32,
    source: u32,
    fallback: u32,
    rejoin: u32,
    marker: snapshot_v1.IrInstruction,
};

pub const PowPattern = struct {
    start: u32,
    destination: u32,
    lhs: u32,
    rhs: u32,
    fast_target: u32,
    rejoin: u32,
    marker: snapshot_v1.IrInstruction,
    arithmetic_id: u32,
};

pub const LinearizedPowPattern = struct {
    finish: u32,
    marker: snapshot_v1.IrInstruction,
    arithmetic_id: u32,
};

pub const ConstantArithmeticPattern = struct {
    start: u32,
    fast_target: u32,
    rejoin: u32,
    marker: snapshot_v1.IrInstruction,
    arithmetic_id: u32,
};

pub const ConstantPowPattern = ConstantArithmeticPattern;

pub const StringEqualityPattern = struct {
    start: u32,
    lhs: u32,
    rhs: u32,
    true_target: u32,
    false_target: u32,
    pointer_block: u32,
};

pub const GenericIterationPattern = struct {
    marker: snapshot_v1.IrInstruction,
    base: u32,
    aux: u32,
    variable_count: u32,
    repeat_target: u32,
    exit_target: u32,
    fallback_target: ?u32 = null,
};

pub const XnextPreparationPattern = struct {
    pc: u32,
    base: u32,
    target: u32,
};

pub const XnextFastPreparationPattern = struct {
    start: u32,
    pc: u32,
    base: u32,
    target: u32,
    fallback: u32,
    publish: ?u32 = null,
};

pub const UserdataAllocationPattern = struct {
    start: u32,
    allocation: u32,
    finish: u32,
    destination: u32,
    byte_size: u32,
    user_tag: u32,
};

pub const StringTableOperation = enum { set, get };

pub const GenericTableOperation = enum { set, get };

pub const GenericTablePattern = struct {
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

pub const GenericTableFallback = struct {
    marker: snapshot_v1.IrInstruction,
    rejoin: u32,
};

pub const InlineGenericTablePattern = struct {
    pattern: GenericTablePattern,
    finish: u32,
    address: u32,
};

pub const InlineConstantTableGetPattern = struct {
    pattern: GenericTablePattern,
    finish: u32,
};

pub const SemanticTableReloadPattern = struct {
    start: u32,
    finish: u32,
    destination: u32,
    table: u32,
    key: union(enum) {
        dynamic: struct { register: u32, marker: snapshot_v1.IrInstruction },
        string: struct { value: []const u8, pc: u32 },
    },
};

pub const GlobalOperation = enum { get, set };

pub const GlobalPattern = struct {
    operation: GlobalOperation,
    start: u32,
    value: u32,
    key: []const u8,
    pc: u32,
    fast_target: u32,
    rejoin: u32,
};

pub const FastcallPattern = struct {
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

pub const TypeNamePattern = struct {
    destination: u32,
    source: u32,
    custom: u32,
    finish: u32,
};

pub const StringLengthPattern = struct {
    source: u32,
    destination: u32,
    materialize_tag: bool,
};

pub const BuiltinFallback = struct {
    id: u32,
    name: []const u8,
    pc: u32,
    argument_registers: [3]u32,
    argument_count: u8,
};

pub const IntegerCreatePattern = struct {
    check: u32,
    finish: u32,
    destination: u32,
};

pub fn isBufferBuiltinId(id: u32) bool {
    return (id >= lbf_buffer_readi8 and id <= lbf_buffer_writef64) or
        id == lbf_buffer_readinteger or id == lbf_buffer_writeinteger;
}

pub const StringTablePattern = struct {
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

pub const InlineStringTablePattern = struct {
    pattern: StringTablePattern,
    finish: u32,
};

pub const DupClosurePattern = union(enum) {
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

pub fn markerCapture(
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

pub fn requireSingleBytecodeBlockRangeFor(
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

pub fn dupClosurePattern(
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

pub fn isRequireImportInstruction(
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
    if (instruction_id < 5)
        return false;
    const get_id = instruction_id - 5;
    const get_import = try snapshot.irInstruction(function, get_id);
    if (get_import.command != .get_cached_import)
        return false;
    if ((try snapshot.irInstruction(function, get_id + 1)).command != .load_tvalue or
        (try snapshot.irInstruction(function, get_id + 2)).command != .store_tvalue or
        (try snapshot.irInstruction(function, get_id + 3)).command != .interrupt or
        (try snapshot.irInstruction(function, get_id + 4)).command != .set_savedpc)
        return false;
    return isRequireImportInstruction(snapshot, function, try snapshot.proto(function.proto_id), get_import);
}

pub fn scanImportNeeds(snapshot: snapshot_v1.Snapshot, function_id: u32, static_package: bool, needs: *ImportNeeds) Error!void {
    try scanImportNeedsFor(snapshot, try snapshot.irFunction(function_id), static_package, needs);
}

pub fn scanImportNeedsFor(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    static_package: bool,
    needs: *ImportNeeds,
) Error!void {
    const ir_cmd_new_table = abi.ir_cmd_new_table;
    const ir_cmd_new_userdata = abi.ir_cmd_new_userdata;
    const ir_cmd_check_userdata_tag = abi.ir_cmd_check_userdata_tag;
    const ir_cmd_barrier_object = abi.ir_cmd_barrier_object;
    const ir_cmd_barrier_table_back = abi.ir_cmd_barrier_table_back;
    const ir_cmd_barrier_table_forward = abi.ir_cmd_barrier_table_forward;
    const ir_cmd_get_hash_node_addr = abi.ir_cmd_get_hash_node_addr;
    const ir_cmd_get_slot_node_addr = abi.ir_cmd_get_slot_node_addr;
    const ir_cmd_jump_slot_match = abi.ir_cmd_jump_slot_match;
    const ir_cmd_check_slot_match = abi.ir_cmd_check_slot_match;
    const ir_cmd_try_call_fastgettm = abi.ir_cmd_try_call_fastgettm;
    const ir_cmd_check_node_no_next = abi.ir_cmd_check_node_no_next;
    const ir_cmd_check_node_value = abi.ir_cmd_check_node_value;
    const ir_cmd_jump_cmp_protoid = abi.ir_cmd_jump_cmp_protoid;
    const ir_cmd_check_readonly = abi.ir_cmd_check_readonly;
    const ir_cmd_dup_table = abi.ir_cmd_dup_table;
    const ir_cmd_table_setnum = abi.ir_cmd_table_setnum;
    const ir_cmd_fallback_namecall = abi.ir_cmd_fallback_namecall;
    const ir_cmd_setlist = abi.ir_cmd_setlist;
    const ir_cmd_set_table = abi.ir_cmd_set_table;
    const ir_cmd_get_table = abi.ir_cmd_get_table;
    const ir_cmd_get_arr_addr = abi.ir_cmd_get_arr_addr;
    const ir_cmd_table_len = abi.ir_cmd_table_len;
    const ir_cmd_do_len = abi.ir_cmd_do_len;
    const ir_cmd_concat = abi.ir_cmd_concat;
    const ir_cmd_fallback_forgprep = abi.ir_cmd_fallback_forgprep;
    const ir_cmd_forgloop = abi.ir_cmd_forgloop;
    const ir_cmd_forgloop_fallback = abi.ir_cmd_forgloop_fallback;
    const ir_cmd_forgprep_xnext_fallback = abi.ir_cmd_forgprep_xnext_fallback;
    const ir_cmd_fallback_settableks = abi.ir_cmd_fallback_settableks;
    const ir_cmd_fallback_gettableks = abi.ir_cmd_fallback_gettableks;
    const ir_cmd_fallback_getglobal = abi.ir_cmd_fallback_getglobal;
    const ir_cmd_fallback_setglobal = abi.ir_cmd_fallback_setglobal;
    const ir_cmd_fastcall = abi.ir_cmd_fastcall;
    const ir_cmd_invoke_fastcall = abi.ir_cmd_invoke_fastcall;
    const ir_cmd_invoke_libm = abi.ir_cmd_invoke_libm;
    const ir_cmd_get_type = abi.ir_cmd_get_type;
    const ir_cmd_get_typeof = abi.ir_cmd_get_typeof;
    const ir_cmd_check_buffer_len = abi.ir_cmd_check_buffer_len;
    const ir_cmd_buffer_readi8 = abi.ir_cmd_buffer_readi8;
    const ir_cmd_buffer_readu8 = abi.ir_cmd_buffer_readu8;
    const ir_cmd_buffer_writei8 = abi.ir_cmd_buffer_writei8;
    const ir_cmd_buffer_readi16 = abi.ir_cmd_buffer_readi16;
    const ir_cmd_buffer_readu16 = abi.ir_cmd_buffer_readu16;
    const ir_cmd_buffer_writei16 = abi.ir_cmd_buffer_writei16;
    const ir_cmd_buffer_readi32 = abi.ir_cmd_buffer_readi32;
    const ir_cmd_buffer_writei32 = abi.ir_cmd_buffer_writei32;
    const ir_cmd_buffer_readf32 = abi.ir_cmd_buffer_readf32;
    const ir_cmd_buffer_writef32 = abi.ir_cmd_buffer_writef32;
    const ir_cmd_buffer_readf64 = abi.ir_cmd_buffer_readf64;
    const ir_cmd_buffer_writef64 = abi.ir_cmd_buffer_writef64;
    const ir_cmd_buffer_readi64 = abi.ir_cmd_buffer_readi64;
    const ir_cmd_buffer_writei64 = abi.ir_cmd_buffer_writei64;
    const proto = try snapshot.proto(function.proto_id);
    var instruction_id: u32 = 0;
    while (instruction_id < function.instruction_count) : (instruction_id += 1) {
        const instruction_value = try snapshot.irInstruction(function, instruction_id);
        switch (instruction_value.command) {
            .coverage => needs.coverage_hit = true,
            .load_pointer => {
                if (instruction_value.operand_count == 1 and
                    (try snapshot.irOperand(instruction_value, 0)).kind == .vm_const)
                    needs.compare_any = true;
            },
            .do_arith => needs.do_arith = true,
            .cmp_any => needs.compare_any = true,
            .fallback_dupclosure => switch (try dupClosurePattern(snapshot, function, proto, instruction_id)) {
                .closed => needs.dupclosure = true,
                .captured => needs.dupclosure_capture = true,
            },
            .newclosure => {
                if (instruction_value.operand_count != 3)
                    return Error.InvalidOperandCount;
                const count_operand = try snapshot.irOperand(instruction_value, 0);
                if (count_operand.kind != .constant)
                    return Error.InvalidOperandType;
                const count = (try snapshot.irConstant(function, count_operand.value)).uintValue() orelse
                    return Error.InvalidOperandType;
                if (count == 0)
                    needs.newclosure_empty = true
                else
                    needs.newclosure_capture = true;
            },
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
                }
            },
            .check_gc => needs.check_gc = true,
            ir_cmd_new_userdata => needs.new_userdata = true,
            ir_cmd_check_userdata_tag => needs.check_userdata_tag = true,
            ir_cmd_barrier_object => needs.barrier_object = true,
            ir_cmd_barrier_table_back => needs.barrier_table_back = true,
            ir_cmd_barrier_table_forward => needs.barrier_table_forward = true,
            ir_cmd_get_hash_node_addr => needs.hash_node_addr = true,
            ir_cmd_get_slot_node_addr => needs.slot_node_addr = true,
            ir_cmd_jump_slot_match, ir_cmd_check_slot_match => needs.node_slot_match = true,
            ir_cmd_try_call_fastgettm => needs.try_get_tm = true,
            ir_cmd_check_node_no_next => needs.check_node_no_next = true,
            ir_cmd_check_node_value => needs.check_node_value = true,
            ir_cmd_jump_cmp_protoid => needs.closure_matches_proto_id = true,
            ir_cmd_check_readonly => {
                needs.check_readonly = true;
                needs.set_location = true;
            },
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
                needs.table_set_number = true;
                if (instruction_id > 0) {
                    var cursor = instruction_id -| 12;
                    var saw_userdata_tag = false;
                    while (cursor < instruction_id) : (cursor += 1) {
                        if ((try snapshot.irInstruction(function, cursor)).command == ir_cmd_check_userdata_tag)
                            saw_userdata_tag = true;
                    }
                    if (saw_userdata_tag) {
                        needs.set_userdata_metatable = true;
                        needs.table_store = true;
                    }
                }
            },
            ir_cmd_get_table => {
                needs.array_get = true;
                needs.table_get = true;
                needs.table_array_get = true;
                needs.table_get_number = true;
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
            .check_safe_env => {
                needs.check_safe_env = true;
                if (instruction_value.operand_count != 1)
                    return Error.InvalidOperandCount;
                const failure = try snapshot.irOperand(instruction_value, 0);
                if (failure.kind != .block)
                    return Error.UnsupportedControlFlow;
            },
            .check_tag => if (instruction_value.operand_count == 3) {
                const failure = try snapshot.irOperand(instruction_value, 2);
                if (failure.kind == .vm_exit) {
                    if (failure.value < proto.code_count) {
                        const word = try snapshot.bytecodeWord(proto, failure.value);
                        if (@as(u8, @truncate(word)) == abi.lop_fornprep)
                            needs.forn_prepare = true
                        else
                            needs.builtin_type_error = true;
                    } else {
                        needs.builtin_type_error = true;
                    }
                    needs.set_location = true;
                }
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
            else => switch (@intFromEnum(instruction_value.command)) {
                100 => {
                    const owns_immediate_gc = instruction_id + 3 < function.instruction_count and
                        (try snapshot.irInstruction(function, instruction_id + 3)).command == .check_gc;
                    if (owns_immediate_gc) {
                        needs.new_table = true;
                    } else {
                        needs.new_table_deferred = true;
                    }
                },
                101 => needs.dup_table = true,
                102 => needs.table_insert_append = true,
                else => {},
            },
        }
    }
}

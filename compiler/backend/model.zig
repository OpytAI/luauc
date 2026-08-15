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

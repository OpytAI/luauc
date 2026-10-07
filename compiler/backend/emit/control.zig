const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");
const admission = @import("luauc_backend_admission");

const aotArithmeticOperation = model.aotArithmeticOperation;
const Error = model.Error;
const CallContinuation = model.CallContinuation;
const StringEqualityPattern = model.StringEqualityPattern;
const status_ok = abi.status_ok;
const status_internal_error = abi.status_internal_error;
const status_yielded = abi.status_yielded;
const status_prepared = abi.status_prepared;
const proto_function_id_offset = abi.proto_function_id_offset;
const metadata_entry_offset = abi.metadata_entry_offset;
const prepared_call_status_offset = abi.prepared_call_status_offset;
const prepared_call_table_index_offset = abi.prepared_call_table_index_offset;
const prepared_call_metadata_offset = abi.prepared_call_metadata_offset;
const lua_tag_boolean = abi.lua_tag_boolean;
const lua_tag_string = abi.lua_tag_string;
const lua_tag_function = abi.lua_tag_function;
const lop_call = abi.lop_call;
const tvalue_size: i32 = @intCast(abi.tvalue_size);
const tvalue_tag_offset = abi.tvalue_tag_offset;
const i32_add: u8 = 0x6a;
const i32_sub: u8 = 0x6b;
const i32_mul: u8 = 0x6c;
const i32_lt_s: u8 = 0x48;
const i32_and: u8 = 0x71;
const i32_lt_u: u8 = 0x49;
const i32_gt_u: u8 = 0x4b;
const i32_ge_u: u8 = 0x4f;
const i32_or: u8 = 0x72;
const i32_shr_u: u8 = 0x76;
const i32_shl: u8 = 0x74;
const i64_eq: u8 = 0x51;
// Guard miss from the shared fast call. The Lua stack is unchanged.
const fast_lua_guard_miss: i32 = -1;
// A preface still treats this sentinel as interrupt success. The shared interrupt
// itself returns 0 for both a quiet update and a slow success, and the caller reloads.
const outlined_reload: i32 = -1;
pub const call_preface_count: usize = 16;

pub fn sourceLine(self: anytype, pc: u32) Error!u32 {
    const line = try self.snapshot.sourceLine(self.proto, pc);
    if (line > 0xfffff)
        return Error.ResourceLimit;
    return line;
}
pub noinline fn emitSavedPcLocation(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    const saved_pc = try self.savedPc(instruction_value);
    if (saved_pc == 0)
        return Error.InvalidOperandType;
    try self.emitPcLocation(saved_pc - 1);
}
pub noinline fn emitPcLocation(self: anytype, pc: u32) Error!void {
    const line = try self.sourceLine(pc);
    // sourceLine rejects a line outside the aotstate mask. The store is the success path of
    // luauc_runtime_v1_set_location on the active native frame.
    try emitQuietLineUpdate(self, line);
}
pub noinline fn emitDoArith(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
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
pub noinline fn emitDoLen(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    if (instruction_id == 0 or (try self.instruction(instruction_id - 1)).command != .set_savedpc)
        return Error.UnsupportedControlFlow;
    _ = try self.savedPc(try self.instruction(instruction_id - 1));
    const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
    const source = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(destination));
    try self.body.i32Const(self.allocator, @intCast(source));
    try self.body.call(self.allocator, self.do_len orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
    if (try fallbackLengthConvert(self, instruction_id, destination)) |convert_id|
        try self.publishLengthSlot(convert_id, destination);
}

fn fallbackLengthConvert(self: anytype, do_len_id: u32, destination: u32) Error!?u32 {
    const window: u32 = 12;
    var cursor = do_len_id;
    const begin = if (do_len_id > window) do_len_id - window else 0;
    while (cursor > begin) {
        cursor -= 1;
        const convert = try self.instruction(cursor);
        if (convert.command != .int_to_num or convert.operand_count != 1)
            continue;
        const produced = try self.operand(convert, 0);
        if (produced.kind != .instruction or produced.value >= cursor)
            continue;
        const producer = try self.instruction(produced.value);
        if (producer.command != abi.ir_cmd_table_len and producer.command != abi.ir_cmd_string_len)
            continue;
        if (cursor + 1 >= self.function.instruction_count)
            continue;
        const store = try self.instruction(cursor + 1);
        if (store.command != .store_double or store.operand_count != 2)
            continue;
        const dest = try self.operand(store, 0);
        const stored = try self.operand(store, 1);
        if (dest.kind == .vm_reg and dest.value == destination and
            stored.kind == .instruction and stored.value == cursor)
            return cursor;
    }
    return null;
}

/// `#` in a compilable block is the userdata form of length. A string length is a
/// load. A plain table uses the table-length helper. Every other value uses `do_len`.
pub noinline fn emitCompilableDoLen(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    if (instruction_id == 0 or (try self.instruction(instruction_id - 1)).command != .set_savedpc)
        return Error.UnsupportedControlFlow;
    _ = try self.savedPc(try self.instruction(instruction_id - 1));
    const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
    const source = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
    try self.emitRegisterLength(destination, source);
    if (try fallbackLengthConvert(self, instruction_id, destination)) |convert_id|
        try self.publishLengthSlot(convert_id, destination);
}
pub noinline fn emitGeneralConcat(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    if (instruction_id == 0 or (try self.instruction(instruction_id - 1)).command != .set_savedpc)
        return Error.UnsupportedControlFlow;
    _ = try self.savedPc(try self.instruction(instruction_id - 1));
    const source = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
    const count_operand = try self.operand(instruction_value, 1);
    const count = if (count_operand.kind == .constant)
        (try self.constant(count_operand.value)).uintValue() orelse return Error.InvalidOperandType
    else
        return Error.InvalidOperandType;
    if (count < 2 or count > @as(u32, self.proto.max_stack_size) - source)
        return Error.UnsupportedControlFlow;
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(source));
    try self.body.i32Const(self.allocator, @intCast(source));
    try self.body.i32Const(self.allocator, @intCast(count));
    try self.body.call(self.allocator, self.concat orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
}
pub fn comparisonOperation(_: anytype, condition: snapshot_v1.IrCondition) Error!i32 {
    return switch (condition) {
        .equal => 0,
        .less => 1,
        .less_equal => 2,
        else => Error.UnsupportedCondition,
    };
}
pub noinline fn emitCompareAny(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    if (instruction_id == 0 or (try self.instruction(instruction_id - 1)).command != .set_savedpc)
        return Error.UnsupportedControlFlow;
    _ = try self.savedPc(try self.instruction(instruction_id - 1));

    const lhs_operand = try self.operand(instruction_value, 0);
    const rhs_operand = try self.operand(instruction_value, 1);
    const lhs = try self.valueOperandEncoding(lhs_operand);
    const rhs = try self.valueOperandEncoding(rhs_operand);
    const operation = try self.comparisonOperation(try self.conditionOperand(instruction_value, 2));

    if (lhs_operand.kind == .vm_reg and rhs_operand.kind == .vm_reg)
        try emitPrimitiveCompare(self, lhs_operand.value, rhs_operand.value, lhs, rhs, operation)
    else
        try emitCompareHelper(self, lhs, rhs, operation);
    try self.emitInstructionResultSet(instruction_id);
    // The helper can invoke a metamethod and relocate the active stack. A primitive hit does not.
    try self.emitReloadBase();
}

fn emitCompareHelper(self: anytype, lhs: u32, rhs: u32, operation: i32) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @bitCast(lhs));
    try self.body.i32Const(self.allocator, @bitCast(rhs));
    try self.body.i32Const(self.allocator, operation);
    try self.body.call(self.allocator, self.compare_any orelse return Error.UnsupportedCommand);
}

fn emitRegisterF64(self: anytype, register: u32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.f64Load(self.allocator, 3, try registerByteOffset(register, 0));
}

fn emitRegisterI32(self: anytype, register: u32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, try registerByteOffset(register, 0));
}

fn registerByteOffset(register: u32, extra: u32) Error!u32 {
    const base = std.math.mul(u32, register, abi.tvalue_size) catch return Error.ResourceLimit;
    return std.math.add(u32, base, extra) catch return Error.ResourceLimit;
}

fn emitTagIs(self: anytype, register: u32, tag: i32) Error!void {
    const operand = snapshot_v1.IrOperand{ .kind = .vm_reg, .value = register };
    try self.emitTValueTag(operand);
    try self.body.i32Const(self.allocator, tag);
    try self.body.i32Eq(self.allocator);
}

// Same-type primitives have no metamethod. Different tags are not equal.
// Tables, userdata, and mixed values stay on compare_any.
fn emitSameTypeEqual(self: anytype, lhs: u32, rhs: u32, lhs_encoded: u32, rhs_encoded: u32) Error!void {
    try emitTagIs(self, lhs, @intCast(abi.lua_tag_number));
    try self.body.ifI32(self.allocator);
    try emitRegisterF64(self, lhs);
    try emitRegisterF64(self, rhs);
    try self.body.f64Eq(self.allocator);
    try self.body.else_(self.allocator);
    try emitTagIs(self, lhs, @intCast(abi.lua_tag_string));
    try self.body.ifI32(self.allocator);
    try emitRegisterI32(self, lhs);
    try emitRegisterI32(self, rhs);
    try self.body.i32Eq(self.allocator);
    try self.body.else_(self.allocator);
    try emitTagIs(self, lhs, abi.lua_tag_boolean);
    try self.body.ifI32(self.allocator);
    try emitRegisterI32(self, lhs);
    try emitRegisterI32(self, rhs);
    try self.body.i32Eq(self.allocator);
    try self.body.else_(self.allocator);
    try emitTagIs(self, lhs, abi.lua_tag_nil);
    try self.body.ifI32(self.allocator);
    try self.body.i32Const(self.allocator, 1);
    try self.body.else_(self.allocator);
    try emitCompareHelper(self, lhs_encoded, rhs_encoded, 0);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}

fn emitPrimitiveCompare(
    self: anytype,
    lhs: u32,
    rhs: u32,
    lhs_encoded: u32,
    rhs_encoded: u32,
    operation: i32,
) Error!void {
    if (operation == 0) {
        const lhs_operand = snapshot_v1.IrOperand{ .kind = .vm_reg, .value = lhs };
        const rhs_operand = snapshot_v1.IrOperand{ .kind = .vm_reg, .value = rhs };
        try self.emitTValueTag(lhs_operand);
        try self.emitTValueTag(rhs_operand);
        try self.body.i32Eq(self.allocator);
        try self.body.ifI32(self.allocator);
        try emitSameTypeEqual(self, lhs, rhs, lhs_encoded, rhs_encoded);
        try self.body.else_(self.allocator);
        try self.body.i32Const(self.allocator, 0);
        try self.body.end(self.allocator);
        return;
    }
    try emitTagIs(self, lhs, @intCast(abi.lua_tag_number));
    try emitTagIs(self, rhs, @intCast(abi.lua_tag_number));
    try self.body.opcode(self.allocator, i32_and);
    try self.body.ifI32(self.allocator);
    try emitRegisterF64(self, lhs);
    try emitRegisterF64(self, rhs);
    if (operation == 1)
        try self.body.f64Lt(self.allocator)
    else
        try self.body.f64Le(self.allocator);
    try self.body.else_(self.allocator);
    try emitCompareHelper(self, lhs_encoded, rhs_encoded, operation);
    try self.body.end(self.allocator);
}

pub noinline fn stringEqualityPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?StringEqualityPattern {
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
pub noinline fn emitStringEqualityBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock, pattern: StringEqualityPattern) Error!void {
    _ = block_id;
    if (pattern.start > block.start) {
        if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
            return;
    }
    if (try self.tryEmitElidedSubCondition(pattern.start, pattern.rhs)) {
        try self.emitConditionalDispatch(pattern.true_target, pattern.false_target);
        return;
    }
    // Luau interns every string, so TString* identity is equality. A non-string tag is the false edge.
    // Strings have no __eq, and this load does not allocate.
    if ((pattern.rhs & 0x8000_0000) == 0)
        return Error.InvalidOperandType;
    const value_offset = pattern.lhs * abi.tvalue_size;
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, value_offset + abi.tvalue_tag_offset);
    try self.body.i32Const(self.allocator, lua_tag_string);
    try self.body.i32Eq(self.allocator);
    try self.body.ifI32(self.allocator);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, value_offset);
    try self.emitVmConstantAddress(.{
        .kind = .vm_const,
        .value = pattern.rhs & 0x7fff_ffff,
    });
    try self.body.i32Load(self.allocator, 2, 0);
    try self.body.i32Eq(self.allocator);
    try self.body.else_(self.allocator);
    try self.body.i32Const(self.allocator, 0);
    try self.body.end(self.allocator);
    try self.emitConditionalDispatch(pattern.true_target, pattern.false_target);
}
fn emitReadContinuationId(body: *wasm.Body, allocator: std.mem.Allocator) Error!void {
    // Previous continuation id. Local 0 is the lua_State* in every shared helper.
    try body.localGet(allocator, 0);
    try body.i32Load(allocator, 2, abi.lua_state_ci_offset);
    try body.i32Load(allocator, 2, abi.callinfo_aotstate_offset);
    try body.i32Const(allocator, @intCast(abi.aot_continuation_shift));
    try body.opcode(allocator, i32_shr_u);
    try body.i32Const(allocator, @intCast(abi.aot_continuation_mask));
    try body.opcode(allocator, i32_and);
}

fn emitStoreClearedContinuation(body: *wasm.Body, allocator: std.mem.Allocator) Error!void {
    try body.localGet(allocator, 0);
    try body.i32Load(allocator, 2, abi.lua_state_ci_offset);
    try body.localGet(allocator, 0);
    try body.i32Load(allocator, 2, abi.lua_state_ci_offset);
    try body.i32Load(allocator, 2, abi.callinfo_aotstate_offset);
    try body.i32Const(allocator, @intCast(abi.aot_line_mask));
    try body.opcode(allocator, i32_and);
    try body.i32Store(allocator, 2, abi.callinfo_aotstate_offset);
}

fn emitStoreContinuationFromParam(body: *wasm.Body, allocator: std.mem.Allocator, next_local: u32) Error!void {
    try body.localGet(allocator, 0);
    try body.i32Load(allocator, 2, abi.lua_state_ci_offset);
    try body.localGet(allocator, 0);
    try body.i32Load(allocator, 2, abi.lua_state_ci_offset);
    try body.i32Load(allocator, 2, abi.callinfo_aotstate_offset);
    try body.i32Const(allocator, @intCast(abi.aot_line_mask));
    try body.opcode(allocator, i32_and);
    try body.localGet(allocator, next_local);
    try body.i32Const(allocator, @intCast(abi.aot_continuation_shift));
    try body.opcode(allocator, i32_shl);
    try body.opcode(allocator, i32_or);
    try body.i32Store(allocator, 2, abi.callinfo_aotstate_offset);
}

fn emitHelperClearContinuation(
    body: *wasm.Body,
    allocator: std.mem.Allocator,
    expected_local: u32,
    scratch: u32,
) Error!void {
    // Exchange zero, then require the previous id. A mismatch returns internal error
    // after the store, matching emitClearContinuation.
    try emitReadContinuationId(body, allocator);
    try body.localSet(allocator, scratch);
    try emitStoreClearedContinuation(body, allocator);
    try body.localGet(allocator, scratch);
    try body.localGet(allocator, expected_local);
    try body.i32Eq(allocator);
    try body.ifVoid(allocator);
    try body.else_(allocator);
    try body.i32Const(allocator, status_internal_error);
    try body.return_(allocator);
    try body.end(allocator);
}

fn emitHelperWriteLine(body: *wasm.Body, allocator: std.mem.Allocator, line_local: u32) Error!void {
    try body.localGet(allocator, 0);
    try body.i32Load(allocator, 2, abi.lua_state_ci_offset);
    try body.localGet(allocator, 0);
    try body.i32Load(allocator, 2, abi.lua_state_ci_offset);
    try body.i32Load(allocator, 2, abi.callinfo_aotstate_offset);
    try body.i32Const(allocator, @bitCast(abi.aot_line_preserved_mask));
    try body.opcode(allocator, i32_and);
    try body.localGet(allocator, line_local);
    try body.opcode(allocator, i32_or);
    try body.i32Store(allocator, 2, abi.callinfo_aotstate_offset);
}

/// One continuation exchange for every package larger than the inline sibling chain.
/// Parameters are L and the next continuation id. The result is the previous id.
/// The new id is stored before the caller tests the previous id.
pub fn emitFastExchange(
    allocator: std.mem.Allocator,
    object: *wasm.Object,
) Error!wasm.FunctionRef {
    const params = [_]wasm.ValueType{.i32} ** 2;
    const results = [_]wasm.ValueType{.i32};
    const function_type = try object.addType(.{ .params = &params, .results = &results });
    const locals = [_]wasm.Local{.{ .count = 1, .value_type = .i32 }};
    var body = try wasm.Body.init(allocator, &locals);
    defer body.deinit(allocator);

    try emitReadContinuationId(&body, allocator);
    try body.localSet(allocator, 2);
    try emitStoreContinuationFromParam(&body, allocator, 1);
    try body.localGet(allocator, 2);
    try body.finish(allocator);
    return object.defineFunction(
        "luauc_runtime_v1_fast_exchange",
        function_type,
        wasm.symbol.visibility_hidden,
        body,
    );
}

/// One quiet line store for every package larger than the inline sibling chain.
/// Parameters are L and the source line. Line 0 always writes. Any other line writes when the stored line differs.
pub fn emitFastLine(
    allocator: std.mem.Allocator,
    object: *wasm.Object,
) Error!wasm.FunctionRef {
    const params = [_]wasm.ValueType{.i32} ** 2;
    const results = [_]wasm.ValueType{};
    const function_type = try object.addType(.{ .params = &params, .results = &results });
    var body = try wasm.Body.init(allocator, &.{});
    defer body.deinit(allocator);

    try body.localGet(allocator, 1);
    try body.i32Eqz(allocator);
    try body.ifVoid(allocator);
    try emitHelperWriteLine(&body, allocator, 1);
    try body.return_(allocator);
    try body.end(allocator);
    try body.localGet(allocator, 0);
    try body.i32Load(allocator, 2, abi.lua_state_ci_offset);
    try body.i32Load(allocator, 2, abi.callinfo_aotstate_offset);
    try body.i32Const(allocator, @intCast(abi.aot_line_mask));
    try body.opcode(allocator, i32_and);
    try body.localGet(allocator, 1);
    try body.i32Ne(allocator);
    try body.ifVoid(allocator);
    try emitHelperWriteLine(&body, allocator, 1);
    try body.end(allocator);
    try body.finish(allocator);
    return object.defineFunction(
        "luauc_runtime_v1_fast_line",
        function_type,
        wasm.symbol.visibility_hidden,
        body,
    );
}

pub noinline fn emitInterrupt(
    self: anytype,
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

    if (self.interrupt_helper) |helper| {
        try emitOutlinedInterrupt(self, helper, line, continuation.continuation_id);
        return;
    }

    // A null callback cannot yield. Publish the line and skip the helper calls.
    // A live callback keeps the exchange, interrupt, and clear sequence.
    try emitNullInterruptCallback(self);
    try self.body.ifVoid(self.allocator);
    try emitQuietInterrupt(self, line);
    try self.body.else_(self.allocator);
    try emitSlowInterrupt(self, continuation.continuation_id, line);
    try self.body.end(self.allocator);
}

fn emitOutlinedInterrupt(self: anytype, helper: wasm.FunctionRef, line: u32, continuation_id: u32) Error!void {
    // 0: quiet success, and the stored line matches `line`.
    // outlined_reload: the import returned 0. Memory continuation is already clear.
    // Any other status returns from this function.
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(line));
    try self.body.i32Const(self.allocator, @intCast(continuation_id));
    try self.body.call(self.allocator, helper);
    // 0 continues. Quiet and slow success both return 0, and a callback may move the stack.
    // last_line_local and live_continuation_local have no reader on this path.
    try self.body.localTee(self.allocator, self.status_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.return_(self.allocator);
    try self.body.end(self.allocator);
    try self.emitReloadBase();
}

/// One interrupt sequence for every package larger than the inline sibling chain.
/// Parameters are L, the source line, and the continuation id.
/// The result is 0 or a runtime status. 0 is a quiet line update or a slow success.
pub fn emitFastInterrupt(
    allocator: std.mem.Allocator,
    object: *wasm.Object,
    interrupt: wasm.FunctionRef,
) Error!wasm.FunctionRef {
    const params = [_]wasm.ValueType{.i32} ** 3;
    const results = [_]wasm.ValueType{.i32};
    const function_type = try object.addType(.{ .params = &params, .results = &results });
    const locals = [_]wasm.Local{.{ .count = 1, .value_type = .i32 }};
    var body = try wasm.Body.init(allocator, &locals);
    defer body.deinit(allocator);

    try body.localGet(allocator, 0);
    try body.i32Load(allocator, 2, abi.lua_state_global_offset);
    try body.i32Load(allocator, 2, abi.global_interrupt_offset);
    try body.i32Eqz(allocator);
    try body.ifVoid(allocator);
    try emitReadContinuationId(&body, allocator);
    try body.i32Eqz(allocator);
    try body.ifVoid(allocator);
    try body.else_(allocator);
    try body.i32Const(allocator, status_internal_error);
    try body.return_(allocator);
    try body.end(allocator);
    try body.localGet(allocator, 0);
    try body.i32Load(allocator, 2, abi.lua_state_ci_offset);
    try body.i32Load(allocator, 2, abi.callinfo_aotstate_offset);
    try body.i32Const(allocator, @intCast(abi.aot_line_mask));
    try body.opcode(allocator, i32_and);
    try body.localGet(allocator, 1);
    try body.i32Ne(allocator);
    try body.ifVoid(allocator);
    try emitHelperWriteLine(&body, allocator, 1);
    try body.end(allocator);
    try body.i32Const(allocator, status_ok);
    try body.return_(allocator);
    try body.else_(allocator);
    try emitReadContinuationId(&body, allocator);
    try body.localSet(allocator, 3);
    try emitStoreContinuationFromParam(&body, allocator, 2);
    try body.localGet(allocator, 3);
    try body.i32Eqz(allocator);
    try body.ifVoid(allocator);
    try body.else_(allocator);
    try body.i32Const(allocator, status_internal_error);
    try body.return_(allocator);
    try body.end(allocator);
    try body.localGet(allocator, 0);
    try body.localGet(allocator, 1);
    try body.call(allocator, interrupt);
    try body.localTee(allocator, 3);
    try body.i32Eqz(allocator);
    try body.ifVoid(allocator);
    try emitHelperClearContinuation(&body, allocator, 2, 3);
    try body.i32Const(allocator, status_ok);
    try body.return_(allocator);
    try body.else_(allocator);
    try body.localGet(allocator, 3);
    try body.return_(allocator);
    try body.end(allocator);
    try body.end(allocator);
    try body.i32Const(allocator, status_ok);
    try body.finish(allocator);
    return object.defineFunction(
        "luauc_runtime_v1_fast_interrupt",
        function_type,
        wasm.symbol.visibility_hidden,
        body,
    );
}
fn emitNullInterruptCallback(self: anytype) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_global_offset);
    try self.body.i32Load(self.allocator, 2, abi.global_interrupt_offset);
    try self.body.i32Eqz(self.allocator);
}
fn emitQuietInterrupt(self: anytype, line: u32) Error!void {
    // The live id is the continuation last exchanged on this activation. Resume clears it
    // before a continuation body runs, so a set id here is the same internal error as a
    // non-zero aotstate field. A null callback cannot have stored a new id.
    try self.body.localGet(self.allocator, self.live_continuation_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try emitQuietLineUpdate(self, line);
    try self.body.else_(self.allocator);
    try self.emitUnexpectedContinuationReturn();
    try self.body.end(self.allocator);
}
fn emitQuietLineUpdate(self: anytype, line: u32) Error!void {
    // Same line as the last store: the low bits already match and continuation bits stay put.
    if (self.line_helper) |helper| {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(line));
        try self.body.call(self.allocator, helper);
        return;
    }
    if (line != 0) {
        try self.body.localGet(self.allocator, self.last_line_local);
        try self.body.i32Const(self.allocator, @intCast(line));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.body.else_(self.allocator);
        try writeQuietLine(self, line);
        try self.body.i32Const(self.allocator, @intCast(line));
        try self.body.localSet(self.allocator, self.last_line_local);
        try self.body.end(self.allocator);
        return;
    }
    try writeQuietLine(self, line);
}
fn writeQuietLine(self: anytype, line: u32) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_aotstate_offset);
    try self.body.i32Const(self.allocator, @bitCast(abi.aot_line_preserved_mask));
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.i32Const(self.allocator, @intCast(line));
    try self.body.opcode(self.allocator, 0x72); // i32.or
    try self.body.i32Store(self.allocator, 2, abi.callinfo_aotstate_offset);
}
fn emitSlowInterrupt(self: anytype, continuation_id: u32, line: u32) Error!void {
    try self.emitExchangeContinuation(continuation_id);
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
    try self.emitClearContinuation(continuation_id);
    try self.emitReloadBase();
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.return_(self.allocator);
    try self.body.end(self.allocator);
}
pub noinline fn emitCoverage(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const pc_operand = try self.operand(instruction_value, 0);
    if (pc_operand.kind != .constant or
        (try self.constant(pc_operand.value)).uintValue() == null)
        return Error.InvalidOperandType;
    const site_id = self.coverage_site_ids[instruction_id];
    if (site_id == snapshot_v1.no_id)
        return Error.UnsupportedControlFlow;
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(site_id));
    try self.body.call(self.allocator, self.coverage_hit orelse return Error.UnsupportedCommand);
}
pub noinline fn emitJump(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const target = try self.requireDispatchTarget(try self.operand(instruction_value, 0));
    try self.body.i32Const(self.allocator, @intCast(target));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.branch(self.allocator, self.loop_branch_depth);
}
pub fn emitDispatchRejoin(self: anytype, rejoin: u32) Error!void {
    if (self.rejoin_fallthrough)
        return;
    try self.body.i32Const(self.allocator, @intCast(rejoin));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.branch(self.allocator, self.loop_branch_depth);
}
pub noinline fn emitConditionalDispatch(self: anytype, true_target: u32, false_target: u32) Error!void {
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, @intCast(true_target));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.else_(self.allocator);
    try self.body.i32Const(self.allocator, @intCast(false_target));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.end(self.allocator);
    try self.body.branch(self.allocator, self.loop_branch_depth);
}
pub noinline fn emitJumpIfTruthy(self: anytype, instruction_value: snapshot_v1.IrInstruction, invert: bool) Error!void {
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
pub noinline fn emitJumpEqualTag(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 4);
    const true_target = try self.requireCompiledTarget(try self.operand(instruction_value, 2));
    const false_target = try self.requireCompiledTarget(try self.operand(instruction_value, 3));
    try self.emitTagValue(try self.operand(instruction_value, 0));
    try self.emitTagValue(try self.operand(instruction_value, 1));
    try self.body.i32Eq(self.allocator);
    try self.emitConditionalDispatch(true_target, false_target);
}
pub noinline fn emitJumpCompareInteger(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 5);
    const true_target = try self.requireDispatchTarget(try self.operand(instruction_value, 3));
    const false_target = try self.requireDispatchTarget(try self.operand(instruction_value, 4));
    try self.emitI32Value(try self.operand(instruction_value, 0));
    try self.emitI32Value(try self.operand(instruction_value, 1));
    try self.emitIntegerCondition(try self.conditionOperand(instruction_value, 2));
    try self.emitConditionalDispatch(true_target, false_target);
}
pub noinline fn emitJumpEqualPointer(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 4);
    const true_target = try self.requireCompiledTarget(try self.operand(instruction_value, 2));
    const false_target = try self.requireCompiledTarget(try self.operand(instruction_value, 3));
    try self.emitPointerValue(try self.operand(instruction_value, 0));
    try self.emitPointerValue(try self.operand(instruction_value, 1));
    try self.body.i32Eq(self.allocator);
    try self.emitConditionalDispatch(true_target, false_target);
}
pub noinline fn emitJumpCompareProtoId(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 4);
    const closure_register = (try self.loadedPointerRegister(try self.operand(instruction_value, 0))) orelse
        return Error.InvalidOperandType;
    const proto_id_operand = try self.operand(instruction_value, 1);
    if (proto_id_operand.kind != .constant)
        return Error.InvalidOperandType;
    const source_proto_id = (try self.constant(proto_id_operand.value)).uintValue() orelse
        return Error.InvalidOperandType;
    if (source_proto_id >= self.proto_id_by_bytecode_id.len)
        return Error.UnsupportedControlFlow;
    const target_proto_id = self.proto_id_by_bytecode_id[source_proto_id];
    if (target_proto_id == snapshot_v1.no_id)
        return Error.UnsupportedControlFlow;
    const global_proto_id = std.math.add(u32, self.function_id_base, target_proto_id) catch
        return Error.ResourceLimit;
    const match_target = try self.requireCompiledTarget(try self.operand(instruction_value, 2));
    const mismatch_target = try self.requireCompiledTarget(try self.operand(instruction_value, 3));

    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(closure_register));
    try self.body.i32Const(self.allocator, @bitCast(global_proto_id));
    try self.body.call(self.allocator, self.closure_matches_proto_id orelse return Error.UnsupportedCommand);
    try self.emitConditionalDispatch(match_target, mismatch_target);
}
pub noinline fn emitJumpCompareFloat(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 5);
    const true_target = try self.requireDispatchTarget(try self.operand(instruction_value, 3));
    const false_target = try self.requireDispatchTarget(try self.operand(instruction_value, 4));
    try self.emitF32Value(try self.operand(instruction_value, 0));
    try self.emitF32Value(try self.operand(instruction_value, 1));
    try self.emitFloatCondition(try self.conditionOperand(instruction_value, 2));
    try self.emitConditionalDispatch(true_target, false_target);
}
pub noinline fn emitNumericCondition(self: anytype, condition: snapshot_v1.IrCondition) Error!void {
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
pub noinline fn emitJumpCompareNumber(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
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
    try self.body.branch(self.allocator, self.loop_branch_depth);
}
pub noinline fn emitJumpFornLoopCondition(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
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
pub noinline fn emitReturn(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
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

    // MULTRET reads L->top in the host. close_upvalues(L, 0) rejects a zero-sized frame.
    if (return_count < 0 or self.close_upvalues == null or self.proto.max_stack_size == 0) {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(source_register));
        try self.body.i32Const(self.allocator, @intCast(return_count));
        try self.body.call(self.allocator, self.return_);
        try self.emitStatusReturn(status_ok);
        return;
    }

    try emitFixedReturn(self, source_register, @intCast(return_count));
}

fn emitFixedReturn(self: anytype, source_register: u32, return_count: u32) Error!void {
    // Match luauc_runtime_v1_return: close while UpVal::v still points into this frame,
    // then copy. luaF_close can move the stack, so both the compare and the copy read L->base.
    try self.emitReloadBase();
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_openupval_offset);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_openupval_offset);
    try self.body.i32Load(self.allocator, 2, abi.upval_v_offset);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.opcode(self.allocator, i32_ge_u);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, 0);
    try self.body.call(self.allocator, self.close_upvalues orelse return Error.UnsupportedCommand);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);

    try self.emitReloadBase();
    var index: u32 = 0;
    while (index < return_count) : (index += 1) {
        const source = std.math.add(u32, source_register, index) catch return Error.ResourceLimit;
        try emitCopyStackSlot(self, index, source);
    }
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, try slotByteOffset(return_count));
    try self.body.opcode(self.allocator, i32_add);
    try self.body.i32Store(self.allocator, 2, abi.lua_state_top_offset);
    try self.emitStatusReturn(status_ok);
}

pub fn callContinuation(self: anytype, instruction_id: u32) ?CallContinuation {
    if (instruction_id >= self.continuation_indices.len)
        return null;
    const index = self.continuation_indices[instruction_id];
    if (index == snapshot_v1.no_id or index >= self.call_continuations.len)
        return null;
    return self.call_continuations[index];
}
pub noinline fn emitExchangeContinuation(self: anytype, next_id: u32) Error!void {
    // The running frame was validated at entry. Keep the low 20 source-line bits.
    // Leave the previous continuation id on the stack. Callers compare it.
    if (next_id > abi.aot_continuation_mask)
        return Error.ResourceLimit;
    if (self.exchange_helper) |helper| {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(next_id));
        try self.body.call(self.allocator, helper);
        return;
    }
    const next_bits: i32 = @bitCast(next_id << abi.aot_continuation_shift);

    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_aotstate_offset);
    try self.body.i32Const(self.allocator, @intCast(abi.aot_continuation_shift));
    try self.body.opcode(self.allocator, i32_shr_u);
    try self.body.i32Const(self.allocator, @intCast(abi.aot_continuation_mask));
    try self.body.opcode(self.allocator, i32_and);

    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_aotstate_offset);
    try self.body.i32Const(self.allocator, @intCast(abi.aot_line_mask));
    try self.body.opcode(self.allocator, i32_and);
    try self.body.i32Const(self.allocator, next_bits);
    try self.body.opcode(self.allocator, i32_or);
    try self.body.i32Store(self.allocator, 2, abi.callinfo_aotstate_offset);
    try self.body.i32Const(self.allocator, @intCast(next_id));
    try self.body.localSet(self.allocator, self.live_continuation_local);
}
pub noinline fn emitUnexpectedContinuationReturn(self: anytype) Error!void {
    try self.body.i32Const(self.allocator, status_internal_error);
    try self.body.return_(self.allocator);
}
pub noinline fn emitClearContinuation(self: anytype, expected_id: u32) Error!void {
    try self.emitExchangeContinuation(0);
    try self.body.i32Const(self.allocator, @intCast(expected_id));
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.else_(self.allocator);
    try self.emitUnexpectedContinuationReturn();
    try self.body.end(self.allocator);
}
fn emitFastIdentityPredicate(self: anytype) Error!void {
    // Running condition. Every load below is from a pointer the guard already proved non-null.
    // The layout hash and proto shape do not change for a rooted closure.
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load8U(self.allocator, 0, abi.closure_is_c_offset);
    try self.body.i32Eqz(self.allocator);

    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Load(self.allocator, 2, abi.proto_code_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.opcode(self.allocator, i32_and);

    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Load(self.allocator, 2, abi.proto_codeentry_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.opcode(self.allocator, i32_and);

    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Load(self.allocator, 2, abi.proto_sizecode_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.opcode(self.allocator, i32_and);

    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Load(self.allocator, 2, abi.proto_source_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.i32Eqz(self.allocator);
    try self.body.opcode(self.allocator, i32_and);

    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Load8U(self.allocator, 0, abi.proto_is_vararg_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.opcode(self.allocator, i32_and);

    // Same record the runtime accepts before it installs a frame. A mismatch falls back.
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.metadata_abi_version_offset);
    try self.body.i32Const(self.allocator, @intCast(abi.aot_abi_version));
    try self.body.i32Eq(self.allocator);
    try self.body.opcode(self.allocator, i32_and);

    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.metadata_struct_size_offset);
    try self.body.i32Const(self.allocator, @intCast(abi.aot_proto_size));
    try self.body.i32Eq(self.allocator);
    try self.body.opcode(self.allocator, i32_and);

    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.metadata_entry_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.i32Eqz(self.allocator);
    try self.body.opcode(self.allocator, i32_and);

    var word: u32 = 0;
    while (word < 4) : (word += 1) {
        const start = word * 8;
        const bits = std.mem.readInt(u64, abi.aot_layout_sha256[start..][0..8], .little);
        try self.body.localGet(self.allocator, self.call_meta_local);
        try self.body.i64Load(self.allocator, 2, abi.metadata_layout_offset + start);
        try self.body.i64Const(self.allocator, @bitCast(bits));
        try self.body.opcode(self.allocator, i64_eq);
        try self.body.opcode(self.allocator, i32_and);
    }

    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Load8U(self.allocator, 0, abi.proto_nups_offset);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load8U(self.allocator, 0, abi.metadata_nups_offset);
    try self.body.i32Eq(self.allocator);
    try self.body.opcode(self.allocator, i32_and);

    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Load8U(self.allocator, 0, abi.proto_numparams_offset);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load8U(self.allocator, 0, abi.metadata_num_params_offset);
    try self.body.i32Eq(self.allocator);
    try self.body.opcode(self.allocator, i32_and);

    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load8U(self.allocator, 0, abi.metadata_is_vararg_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.opcode(self.allocator, i32_and);

    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load8U(self.allocator, 0, abi.closure_nupvalues_offset);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load8U(self.allocator, 0, abi.metadata_nups_offset);
    try self.body.i32Eq(self.allocator);
    try self.body.opcode(self.allocator, i32_and);

    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load8U(self.allocator, 0, abi.closure_stacksize_offset);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load8U(self.allocator, 0, abi.metadata_max_stack_offset);
    try self.body.i32Eq(self.allocator);
    try self.body.opcode(self.allocator, i32_and);

    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Load8U(self.allocator, 0, abi.proto_maxstacksize_offset);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load8U(self.allocator, 0, abi.metadata_max_stack_offset);
    try self.body.i32Eq(self.allocator);
    try self.body.opcode(self.allocator, i32_and);
}
fn structType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.child,
        else => T,
    };
}
fn emitFastImm(self: anytype, comptime field: []const u8, value: i32) Error!void {
    // The shared fast call reads the frame shape from parameters. An inlined site bakes the constant.
    if (comptime @hasField(structType(@TypeOf(self)), field)) {
        try self.body.localGet(self.allocator, @field(self, field));
    } else try self.body.i32Const(self.allocator, value);
}
fn emitFastStackPredicate(self: anytype, arg_bytes: i32) Error!void {
    // CallInfo and stack room change between calls. The value already on the stack is the identity condition.
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_end_ci_offset);
    try self.body.i32Ne(self.allocator);
    try self.body.opcode(self.allocator, i32_and);

    try self.body.localGet(self.allocator, self.call_func_local);
    try emitFastImm(self, "fast_arg_bytes_local", arg_bytes);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_stack_last_offset);
    try self.body.opcode(self.allocator, i32_lt_u);
    try self.body.opcode(self.allocator, i32_and);

    // luaD_checkstackfornewci grows when stack_last - arg_top <= stacksize * sizeof(TValue).
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_stack_last_offset);
    try self.body.localGet(self.allocator, self.call_func_local);
    try emitFastImm(self, "fast_arg_bytes_local", arg_bytes);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load8U(self.allocator, 0, abi.closure_stacksize_offset);
    try self.body.i32Const(self.allocator, tvalue_size);
    try self.body.opcode(self.allocator, i32_mul);
    try self.body.opcode(self.allocator, i32_gt_u);
    try self.body.opcode(self.allocator, i32_and);
}
fn emitFastLuaGuard(self: anytype, function_register: u32, arg_bytes: i32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, @intCast(function_register * abi.tvalue_size));
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.call_func_local);
    try emitFastLuaGuardAt(self, arg_bytes);
}
fn emitFastLuaGuardAt(self: anytype, arg_bytes: i32) Error!void {
    // call_func_local is the callee TValue. A miss writes only wasm locals.
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Load(self.allocator, 2, tvalue_tag_offset);
    try self.body.i32Const(self.allocator, lua_tag_function);
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Load(self.allocator, 2, 0);
    try self.body.localTee(self.allocator, self.call_closure_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load8U(self.allocator, 0, abi.closure_is_c_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load(self.allocator, 2, abi.closure_l_proto_offset);
    try self.body.localTee(self.allocator, self.call_proto_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Load(self.allocator, 2, abi.proto_execdata_offset);
    try self.body.localTee(self.allocator, self.call_meta_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.localGet(self.allocator, self.call_cached_closure_local);
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, 1);
    try emitFastStackPredicate(self, arg_bytes);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.else_(self.allocator);
    try emitFastIdentityPredicate(self);
    try emitFastStackPredicate(self, arg_bytes);
    try self.body.localTee(self.allocator, self.status_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.localSet(self.allocator, self.call_cached_closure_local);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}
fn emitFastNilFill(self: anytype, arg_bytes: i32) Error!void {
    try self.body.localGet(self.allocator, self.call_func_local);
    try emitFastImm(self, "fast_arg_bytes_local", arg_bytes);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.table_index_local);
    try self.body.block(self.allocator);
    try self.body.loop(self.allocator);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Load8U(self.allocator, 0, abi.proto_numparams_offset);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.i32Const(self.allocator, tvalue_size);
    try self.body.opcode(self.allocator, i32_mul);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.opcode(self.allocator, i32_ge_u);
    try self.body.ifVoid(self.allocator);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.i32Store(self.allocator, 2, tvalue_tag_offset);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Const(self.allocator, tvalue_size);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.table_index_local);
    try self.body.branch(self.allocator, 0);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}
fn emitFastInstallFrame(self: anytype, arg_bytes: i32, result_count: i32, frame_flags: i32) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.i32Const(self.allocator, @intCast(abi.callinfo_size));
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.table_index_local);

    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, tvalue_size);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.i32Store(self.allocator, 2, abi.callinfo_base_offset);

    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Store(self.allocator, 2, abi.callinfo_func_offset);

    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try emitFastImm(self, "fast_arg_bytes_local", arg_bytes);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load8U(self.allocator, 0, abi.closure_stacksize_offset);
    try self.body.i32Const(self.allocator, tvalue_size);
    try self.body.opcode(self.allocator, i32_mul);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.i32Store(self.allocator, 2, abi.callinfo_top_offset);

    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.i32Store(self.allocator, 2, abi.callinfo_aotstate_offset);

    try self.body.localGet(self.allocator, self.table_index_local);
    try emitFastImm(self, "fast_result_count_local", result_count);
    try self.body.i32Store(self.allocator, 2, abi.callinfo_nresults_offset);

    try self.body.localGet(self.allocator, self.table_index_local);
    try emitFastImm(self, "fast_frame_flags_local", frame_flags);
    try self.body.i32Store(self.allocator, 2, abi.callinfo_flags_offset);

    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Store(self.allocator, 2, abi.lua_state_ci_offset);

    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, tvalue_size);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.i32Store(self.allocator, 2, abi.lua_state_base_offset);

    try emitFastNilFill(self, arg_bytes);

    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_top_offset);
    try self.body.i32Store(self.allocator, 2, abi.lua_state_top_offset);
}
/// An id chain of this length stays at the call site. One compare plus a direct
/// call is cheaper than a shared dispatch when the package only has a few functions.
pub const max_inline_direct_siblings: usize = 8;
/// One br_table covers a larger package. Past this, the existing self-or-indirect
/// transfer stays smaller than a deep dispatch function.
pub const max_direct_dispatch_arms: usize = 256;

fn emitDirectCall(self: anytype, function: wasm.FunctionRef) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.call(self.allocator, function);
    try self.body.localSet(self.allocator, self.status_local);
}
fn emitIndirectCall(self: anytype) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.metadata_entry_offset);
    try self.body.callIndirect(self.allocator, self.generated_type, 0);
    try self.body.localSet(self.allocator, self.status_local);
}
fn emitSiblingDispatch(self: anytype, index: u32) Error!void {
    const siblings = self.sibling_functions;
    if (index >= siblings.len)
        return emitIndirectCall(self);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, proto_function_id_offset);
    try self.body.i32Const(self.allocator, @intCast(index));
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try emitDirectCall(self, siblings[index]);
    try self.body.else_(self.allocator);
    try emitSiblingDispatch(self, index + 1);
    try self.body.end(self.allocator);
}

/// One function for the package. Function id `k` is br_table depth `k`.
/// The default arm is the indirect call used for a closure outside this package.
pub fn emitDirectDispatchTrampoline(
    allocator: std.mem.Allocator,
    object: *wasm.Object,
    generated_type: u32,
    siblings: []const wasm.FunctionRef,
) Error!wasm.FunctionRef {
    const arm_count: u32 = @intCast(siblings.len);
    const labels = try allocator.alloc(u32, siblings.len);
    defer allocator.free(labels);
    for (labels, 0..) |*label, index|
        label.* = @intCast(index);

    const locals = [_]wasm.Local{.{ .count = 1, .value_type = .i32 }};
    var body = try wasm.Body.init(allocator, &locals);
    defer body.deinit(allocator);

    // done, default, then function ids from last to first. Id 0 is the innermost block.
    var opened: u32 = 0;
    while (opened < arm_count + 2) : (opened += 1)
        try body.block(allocator);
    try body.localGet(allocator, 1);
    try body.i32Load(allocator, 2, proto_function_id_offset);
    try body.brTable(allocator, labels, arm_count);

    for (siblings, 0..) |function, index| {
        const id: u32 = @intCast(index);
        try body.end(allocator);
        // Same wasmi loop-fuel rule as the bytecode dispatcher. This function
        // has no loop, but its entry fuel still covers every block arm. local 0
        // is the lua_State* and is never null.
        try body.localGet(allocator, 0);
        try body.ifVoid(allocator);
        try body.localGet(allocator, 0);
        try body.localGet(allocator, 1);
        try body.call(allocator, function);
        try body.localSet(allocator, 2);
        try body.branch(allocator, arm_count - id + 1);
        try body.end(allocator);
    }
    try body.end(allocator);
    try body.localGet(allocator, 0);
    try body.ifVoid(allocator);
    try body.localGet(allocator, 0);
    try body.localGet(allocator, 1);
    try body.localGet(allocator, 1);
    try body.i32Load(allocator, 2, metadata_entry_offset);
    try body.callIndirect(allocator, generated_type, 0);
    try body.localSet(allocator, 2);
    try body.branch(allocator, 1);
    try body.end(allocator);
    try body.end(allocator);
    try body.localGet(allocator, 2);
    try body.finish(allocator);
    return object.defineFunction(
        "luauc_runtime_v1_direct_dispatch",
        generated_type,
        wasm.symbol.visibility_hidden,
        body,
    );
}

fn emitFastLuaTransfer(self: anytype) Error!void {
    // Metadata function ids in one package are dense. A direct call avoids the table lookup.
    if (self.sibling_trampoline) |trampoline| {
        try self.body.localGet(self.allocator, 0);
        try self.body.localGet(self.allocator, self.call_meta_local);
        try self.body.call(self.allocator, trampoline);
        try self.body.localSet(self.allocator, self.status_local);
        return;
    }
    // The shared helper serves every caller, so it cannot specialize one function id.
    if (comptime @hasField(structType(@TypeOf(self)), "shared_fast_call")) {
        return emitIndirectCall(self);
    } else {
        if (self.sibling_functions.len > 0 and self.sibling_functions.len <= max_inline_direct_siblings)
            return emitSiblingDispatch(self, 0);
        try self.body.localGet(self.allocator, self.call_meta_local);
        try self.body.i32Load(self.allocator, 2, proto_function_id_offset);
        try self.body.i32Const(self.allocator, @intCast(self.planned_function_id));
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        try emitDirectCall(self, self.self_function);
        try self.body.else_(self.allocator);
        try emitIndirectCall(self);
        try self.body.end(self.allocator);
    }
}

const FastLuaCall = struct {
    allocator: std.mem.Allocator,
    body: *wasm.Body,
    base_local: u32,
    status_local: u32,
    table_index_local: u32,
    call_func_local: u32,
    call_closure_local: u32,
    call_proto_local: u32,
    call_meta_local: u32,
    call_cached_closure_local: u32,
    fast_arg_bytes_local: u32,
    fast_result_count_local: u32,
    fast_frame_flags_local: u32,
    sibling_trampoline: ?wasm.FunctionRef,
    generated_type: u32,
    finish_compiled_call: ?wasm.FunctionRef,
    check_gc: ?wasm.FunctionRef,
    shared_fast_call: bool = true,
};

/// One function for every fixed Lua call in a package larger than the inline sibling chain.
/// Parameters are L, the callee byte offset from L->base, argument bytes, result count, frame flags,
/// the continuation id, and prepare_on_miss. Id 0 skips the success clear.
/// prepare_on_miss calls the prepare helper and returns its status. A zero flag returns `fast_lua_guard_miss`.
/// The result is `fast_lua_guard_miss` when the stack is unchanged, `status_yielded` when the caller
/// must return, `status_internal_error` when the clear sees a different id, and `status_ok` after
/// poscall or finish_compiled_call. The success clear is already stored.
pub fn emitFastLuaCall(
    allocator: std.mem.Allocator,
    object: *wasm.Object,
    generated_type: u32,
    trampoline: ?wasm.FunctionRef,
    finish_compiled_call: wasm.FunctionRef,
    check_gc: wasm.FunctionRef,
    prepare_helper: ?wasm.FunctionRef,
) Error!wasm.FunctionRef {
    const params = [_]wasm.ValueType{.i32} ** 7;
    const results = [_]wasm.ValueType{.i32};
    const function_type = try object.addType(.{ .params = &params, .results = &results });
    const locals = [_]wasm.Local{.{ .count = 8, .value_type = .i32 }};
    var body = try wasm.Body.init(allocator, &locals);
    defer body.deinit(allocator);

    var ctx = FastLuaCall{
        .allocator = allocator,
        .body = &body,
        .base_local = 7,
        .status_local = 8,
        .table_index_local = 9,
        .call_func_local = 10,
        .call_closure_local = 11,
        .call_proto_local = 12,
        .call_meta_local = 13,
        .call_cached_closure_local = 14,
        .fast_arg_bytes_local = 2,
        .fast_result_count_local = 3,
        .fast_frame_flags_local = 4,
        .sibling_trampoline = trampoline,
        .generated_type = generated_type,
        .finish_compiled_call = finish_compiled_call,
        .check_gc = check_gc,
    };

    try body.localGet(allocator, 0);
    try body.i32Load(allocator, 2, abi.lua_state_base_offset);
    try body.localTee(allocator, ctx.base_local);
    try body.localGet(allocator, 1);
    try body.opcode(allocator, i32_add);
    try body.localSet(allocator, ctx.call_func_local);
    try emitFastLuaGuardAt(&ctx, 0);
    try body.localGet(allocator, ctx.status_local);
    try body.ifVoid(allocator);
    try emitFastLuaInvoke(&ctx, 0, 0, null, 0, false, true);
    try body.localGet(allocator, 5);
    try body.ifVoid(allocator);
    try emitHelperClearContinuation(&body, allocator, 5, ctx.status_local);
    try body.end(allocator);
    try body.i32Const(allocator, status_ok);
    try body.return_(allocator);
    try body.end(allocator);
    try body.localGet(allocator, 6);
    try body.ifVoid(allocator);
    if (prepare_helper) |prepare| {
        // Register is the byte offset shifted by the TValue size. Argument count is one less than the frame slots.
        try body.localGet(allocator, 0);
        try body.localGet(allocator, 1);
        try body.i32Const(allocator, 4);
        try body.opcode(allocator, i32_shr_u);
        try body.localGet(allocator, 2);
        try body.i32Const(allocator, 4);
        try body.opcode(allocator, i32_shr_u);
        try body.i32Const(allocator, 1);
        try body.opcode(allocator, i32_sub);
        try body.localGet(allocator, 3);
        try body.localGet(allocator, 5);
        try body.call(allocator, prepare);
        try body.return_(allocator);
    } else {
        try body.i32Const(allocator, fast_lua_guard_miss);
        try body.return_(allocator);
    }
    try body.end(allocator);
    try body.i32Const(allocator, fast_lua_guard_miss);
    try body.finish(allocator);
    return object.defineFunction(
        "luauc_runtime_v1_fast_lua_call",
        function_type,
        wasm.symbol.visibility_hidden,
        body,
    );
}

fn emitFastLuaCallSite(
    self: anytype,
    helper: wasm.FunctionRef,
    func_offset: i32,
    arg_bytes: i32,
    result_count: i32,
    frame_flags: i32,
    continuation_id: i32,
    prepare_on_miss: i32,
) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, func_offset);
    try self.body.i32Const(self.allocator, arg_bytes);
    try self.body.i32Const(self.allocator, result_count);
    try self.body.i32Const(self.allocator, frame_flags);
    try self.body.i32Const(self.allocator, continuation_id);
    try self.body.i32Const(self.allocator, prepare_on_miss);
    try self.body.call(self.allocator, helper);
    try self.body.localSet(self.allocator, self.status_local);
}

fn prefaceSymbol(move: bool, constant: bool, capture_count: u32) []const u8 {
    const symbols = [_][]const u8{
        "luauc_runtime_v1_fast_call_preface",
        "luauc_runtime_v1_fast_call_preface_c1",
        "luauc_runtime_v1_fast_call_preface_c2",
        "luauc_runtime_v1_fast_call_preface_c3",
        "luauc_runtime_v1_fast_call_preface_k",
        "luauc_runtime_v1_fast_call_preface_k_c1",
        "luauc_runtime_v1_fast_call_preface_k_c2",
        "luauc_runtime_v1_fast_call_preface_k_c3",
        "luauc_runtime_v1_fast_call_preface_m",
        "luauc_runtime_v1_fast_call_preface_m_c1",
        "luauc_runtime_v1_fast_call_preface_m_c2",
        "luauc_runtime_v1_fast_call_preface_m_c3",
        "luauc_runtime_v1_fast_call_preface_m_k",
        "luauc_runtime_v1_fast_call_preface_m_k_c1",
        "luauc_runtime_v1_fast_call_preface_m_k_c2",
        "luauc_runtime_v1_fast_call_preface_m_k_c3",
    };
    return symbols[callPrefaceIndex(move, constant, capture_count)];
}

pub fn callPrefaceIndex(move: bool, constant: bool, capture_count: u32) u32 {
    return @as(u32, @intFromBool(move)) * 8 + @as(u32, @intFromBool(constant)) * 4 + capture_count;
}

/// One stack-to-stack TValue copy. The packed immediate is source in the low 16 bits and destination in the high 16.
pub fn emitMoveReg(
    allocator: std.mem.Allocator,
    object: *wasm.Object,
) Error!wasm.FunctionRef {
    const params = [_]wasm.ValueType{ .i32, .i32 };
    const no_results = [_]wasm.ValueType{};
    const function_type = try object.addType(.{ .params = &params, .results = &no_results });
    var body = try wasm.Body.init(allocator, &.{});
    defer body.deinit(allocator);
    try emitPrefaceRegisterCopy(&body, allocator, 1);
    try body.finish(allocator);
    return object.defineFunction(
        "luauc_runtime_v1_move_reg",
        function_type,
        wasm.symbol.visibility_hidden,
        body,
    );
}

fn prefaceParamCount(move: bool, constant: bool, capture_count: u32) u32 {
    // L, packed interrupt line and continuation, packed call line and continuation,
    // byte offset, argument bytes, result count.
    var count: u32 = 6;
    if (move)
        count += 1;
    if (constant)
        count += 2;
    if (capture_count != 0)
        count += 2 + capture_count;
    return count;
}

fn emitMasked(body: *wasm.Body, allocator: std.mem.Allocator, local_index: u32, mask: u32) Error!void {
    try body.localGet(allocator, local_index);
    try body.i32Const(allocator, @intCast(mask));
    try body.opcode(allocator, i32_and);
}

fn emitShifted(body: *wasm.Body, allocator: std.mem.Allocator, local_index: u32, shift: u32) Error!void {
    try body.localGet(allocator, local_index);
    try body.i32Const(allocator, @intCast(shift));
    try body.opcode(allocator, i32_shr_u);
}

/// One straight-line preface for packages larger than the inline sibling chain.
/// The tail is a constant load, then 0..3 dupclosure captures. Each shape is its own function.
/// Interrupt 0 and `outlined_reload` continue. Any other interrupt status returns raw.
/// A call-region failure returns that status. Success returns 0 after the tail.
pub fn emitCallPreface(
    allocator: std.mem.Allocator,
    object: *wasm.Object,
    interrupt_helper: wasm.FunctionRef,
    line_helper: wasm.FunctionRef,
    exchange_helper: wasm.FunctionRef,
    fast_lua_call: wasm.FunctionRef,
    load_constant: ?wasm.FunctionRef,
    dupclosure_capture: ?wasm.FunctionRef,
    move: bool,
    constant: bool,
    capture_count: u32,
) Error!wasm.FunctionRef {
    if (capture_count > 3)
        return Error.UnsupportedControlFlow;
    if (constant and load_constant == null)
        return Error.UnsupportedCommand;
    if (capture_count != 0 and dupclosure_capture == null)
        return Error.UnsupportedCommand;

    const param_count = prefaceParamCount(move, constant, capture_count);
    var params: [20]wasm.ValueType = .{.i32} ** 20;
    const results = [_]wasm.ValueType{.i32};
    const function_type = try object.addType(.{ .params = params[0..param_count], .results = &results });
    const locals = [_]wasm.Local{.{ .count = 1, .value_type = .i32 }};
    var body = try wasm.Body.init(allocator, &locals);
    defer body.deinit(allocator);
    const status: u32 = param_count;
    const move_at: u32 = 6;
    const const_at: u32 = 6 + @as(u32, if (move) 1 else 0);
    const cap_base: u32 = const_at + @as(u32, if (constant) 2 else 0);

    try body.localGet(allocator, 0);
    try emitMasked(&body, allocator, 1, abi.aot_line_mask);
    try emitShifted(&body, allocator, 1, abi.aot_continuation_shift);
    try body.call(allocator, interrupt_helper);
    try body.localTee(allocator, status);
    try body.i32Eqz(allocator);
    try body.localGet(allocator, status);
    try body.i32Const(allocator, outlined_reload);
    try body.i32Eq(allocator);
    try body.opcode(allocator, i32_or);
    try body.i32Eqz(allocator);
    try body.ifVoid(allocator);
    try body.localGet(allocator, status);
    try body.return_(allocator);
    try body.end(allocator);

    // Slow interrupt success does not write the call line. This store still runs.
    try body.localGet(allocator, 0);
    try emitMasked(&body, allocator, 2, abi.aot_line_mask);
    try body.call(allocator, line_helper);

    // Id 0 skips the exchange. A mismatch has already stored the new id.
    try emitShifted(&body, allocator, 2, abi.aot_continuation_shift);
    try body.ifVoid(allocator);
    try body.localGet(allocator, 0);
    try emitShifted(&body, allocator, 2, abi.aot_continuation_shift);
    try body.call(allocator, exchange_helper);
    try body.i32Eqz(allocator);
    try body.i32Eqz(allocator);
    try body.ifVoid(allocator);
    try body.i32Const(allocator, status_internal_error);
    try body.return_(allocator);
    try body.end(allocator);
    try body.end(allocator);

    try body.localGet(allocator, 0);
    try body.localGet(allocator, 3);
    try body.localGet(allocator, 4);
    try body.localGet(allocator, 5);
    try body.i32Const(allocator, abi.lua_callinfo_native);
    try emitShifted(&body, allocator, 2, abi.aot_continuation_shift);
    try body.i32Const(allocator, 1);
    try body.call(allocator, fast_lua_call);
    try body.localTee(allocator, status);
    try body.i32Eqz(allocator);
    try body.ifVoid(allocator);
    if (move)
        try emitPrefaceRegisterCopy(&body, allocator, move_at);
    if (constant) {
        try body.localGet(allocator, 0);
        try body.localGet(allocator, const_at);
        try body.localGet(allocator, const_at + 1);
        try body.call(allocator, load_constant orelse return Error.UnsupportedCommand);
    }
    if (capture_count != 0) {
        const capture_fn = dupclosure_capture orelse return Error.UnsupportedCommand;
        var index: u32 = 0;
        while (index < capture_count) : (index += 1) {
            const packed_capture = cap_base + 2 + index;
            try body.localGet(allocator, 0);
            try body.localGet(allocator, cap_base);
            try body.localGet(allocator, cap_base + 1);
            try body.i32Const(allocator, @intCast(index));
            try emitShifted(&body, allocator, packed_capture, 16);
            try emitMasked(&body, allocator, packed_capture, 0xffff);
            try body.i32Const(allocator, @intFromBool(index + 1 == capture_count));
            try body.call(allocator, capture_fn);
        }
    }
    try body.else_(allocator);
    try body.localGet(allocator, status);
    try body.return_(allocator);
    try body.end(allocator);
    try body.i32Const(allocator, status_ok);
    try body.finish(allocator);
    return object.defineFunction(
        prefaceSymbol(move, constant, capture_count),
        function_type,
        wasm.symbol.visibility_hidden,
        body,
    );
}

fn emitPrefaceRegisterCopy(body: *wasm.Body, allocator: std.mem.Allocator, packed_local: u32) Error!void {
    // Copy one stack TValue. The call has returned, so L->base is the caller's base.
    // The packed local holds the source register in the low 16 bits and the destination in the high 16.
    try emitPrefaceCopyHalf(body, allocator, packed_local, 0);
    try emitPrefaceCopyHalf(body, allocator, packed_local, 8);
}

fn emitPackedRegister(body: *wasm.Body, allocator: std.mem.Allocator, packed_local: u32, high: bool) Error!void {
    try body.localGet(allocator, packed_local);
    if (high) {
        try body.i32Const(allocator, 16);
        try body.opcode(allocator, i32_shr_u);
    } else {
        try body.i32Const(allocator, 0xffff);
        try body.opcode(allocator, i32_and);
    }
}

fn emitPrefaceCopyHalf(
    body: *wasm.Body,
    allocator: std.mem.Allocator,
    packed_local: u32,
    offset: u32,
) Error!void {
    try body.localGet(allocator, 0);
    try body.i32Load(allocator, 2, abi.lua_state_base_offset);
    try emitPackedRegister(body, allocator, packed_local, true);
    try body.i32Const(allocator, 4);
    try body.opcode(allocator, i32_shl);
    try body.i32Const(allocator, @intCast(offset));
    try body.opcode(allocator, i32_add);
    try body.opcode(allocator, i32_add);
    try body.localGet(allocator, 0);
    try body.i32Load(allocator, 2, abi.lua_state_base_offset);
    try emitPackedRegister(body, allocator, packed_local, false);
    try body.i32Const(allocator, 4);
    try body.opcode(allocator, i32_shl);
    try body.i32Const(allocator, @intCast(offset));
    try body.opcode(allocator, i32_add);
    try body.opcode(allocator, i32_add);
    try body.i64Load(allocator, 3, 0);
    try body.i64Store(allocator, 3, 0);
}

fn emitFastAdvanceResult(self: anytype) Error!void {
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i64Load(self.allocator, 3, 0);
    try self.body.i64Store(self.allocator, 3, 0);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i64Load(self.allocator, 3, 8);
    try self.body.i64Store(self.allocator, 3, 8);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, tvalue_size);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.call_func_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Const(self.allocator, tvalue_size);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.call_closure_local);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.localSet(self.allocator, self.table_index_local);
}
fn emitFastPoscall(self: anytype) Error!void {
    // The callee return helper already placed results at the callee base. This is luau_poscall
    // for a fixed result count: copy, nil-fill, then restore the caller frame.
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.localSet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_func_offset);
    try self.body.localSet(self.allocator, self.call_func_local);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_base_offset);
    try self.body.localSet(self.allocator, self.call_closure_local);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_top_offset);
    try self.body.localSet(self.allocator, self.call_proto_local);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_nresults_offset);
    try self.body.localSet(self.allocator, self.table_index_local);

    try self.body.block(self.allocator);
    try self.body.loop(self.allocator);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.opcode(self.allocator, i32_ge_u);
    try self.body.ifVoid(self.allocator);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try emitFastAdvanceResult(self);
    try self.body.branch(self.allocator, 0);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);

    try self.body.block(self.allocator);
    try self.body.loop(self.allocator);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.i32Store(self.allocator, 2, tvalue_tag_offset);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, tvalue_size);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.call_func_local);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.localSet(self.allocator, self.table_index_local);
    try self.body.branch(self.allocator, 0);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);

    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Const(self.allocator, @intCast(abi.callinfo_size));
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.localTee(self.allocator, self.call_meta_local);
    try self.body.i32Store(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_base_offset);
    try self.body.i32Store(self.allocator, 2, abi.lua_state_base_offset);
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_top_offset);
    try self.body.i32Store(self.allocator, 2, abi.lua_state_top_offset);
}
/// `luaC_checkGC` is a threshold compare. The collector runs only when
/// `totalbytes >= GCthreshold`. A live state has a global. The base is refreshed
/// only after that call, because only the collector moves the stack.
pub noinline fn emitGuardedCheckGc(self: anytype) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_global_offset);
    try self.body.i32Load(self.allocator, 2, abi.global_totalbytes_offset);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_global_offset);
    try self.body.i32Load(self.allocator, 2, abi.global_gc_threshold_offset);
    try self.body.opcode(self.allocator, i32_ge_u);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, 0);
    try self.body.call(self.allocator, self.check_gc orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
    try self.body.end(self.allocator);
}
fn emitFastGcAssist(self: anytype) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_global_offset);
    try self.body.localTee(self.allocator, self.call_func_local);
    try self.body.i32Load(self.allocator, 2, abi.global_totalbytes_offset);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Load(self.allocator, 2, abi.global_gc_threshold_offset);
    try self.body.opcode(self.allocator, i32_ge_u);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, 0);
    try self.body.call(self.allocator, self.check_gc orelse return Error.UnsupportedCommand);
    try self.body.end(self.allocator);
}
fn emitMarkIteratorYield(self: anytype) Error!void {
    // performcally records OPYIELD on the caller that was current before the iterator frame.
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_base_ci_offset);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localTee(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_flags_offset);
    try self.body.i32Const(self.allocator, abi.lua_callinfo_opyield);
    try self.body.opcode(self.allocator, i32_or);
    try self.body.i32Store(self.allocator, 2, abi.callinfo_flags_offset);
}
fn emitFastLuaInvoke(
    self: anytype,
    arg_bytes: i32,
    result_count: i32,
    continuation: ?CallContinuation,
    frame_flags: i32,
    comptime mark_opyield: bool,
    comptime outlined: bool,
) Error!void {
    try emitFastInstallFrame(self, arg_bytes, result_count, frame_flags);
    try emitFastLuaTransfer(self);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Const(self.allocator, status_yielded);
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    if (mark_opyield)
        try emitMarkIteratorYield(self);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.return_(self.allocator);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try emitFastPoscall(self);
    try emitFastGcAssist(self);
    if (comptime !outlined) {
        if (continuation) |resumable|
            try self.emitClearContinuation(resumable.continuation_id);
        try self.emitReloadBase();
    }
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.call(self.allocator, self.finish_compiled_call orelse return Error.UnsupportedCommand);
    if (comptime !outlined) {
        if (continuation) |resumable|
            try self.emitClearContinuation(resumable.continuation_id);
        try self.emitReloadBase();
    }
    try self.body.end(self.allocator);
}
/// One prepare sequence for every package larger than the inline sibling chain.
/// Parameters are L, the function register, the parameter count, the result count, and the continuation id.
/// Id 0 skips the clear. The result is 0 after a finished call, or the runtime status unchanged.
/// Yield does not clear. The caller reloads base only when the result is 0.
pub fn emitPreparedCallHelper(
    allocator: std.mem.Allocator,
    object: *wasm.Object,
    generated_type: u32,
    trampoline: ?wasm.FunctionRef,
    prepare_compiled_call: wasm.FunctionRef,
    finish_compiled_call: wasm.FunctionRef,
) Error!wasm.FunctionRef {
    const params = [_]wasm.ValueType{.i32} ** 5;
    const results = [_]wasm.ValueType{.i32};
    const function_type = try object.addType(.{ .params = &params, .results = &results });
    const locals = [_]wasm.Local{.{ .count = 3, .value_type = .i32 }};
    var body = try wasm.Body.init(allocator, &locals);
    defer body.deinit(allocator);

    try body.localGet(allocator, 0);
    try body.localGet(allocator, 1);
    try body.localGet(allocator, 2);
    try body.localGet(allocator, 3);
    try body.call(allocator, prepare_compiled_call);
    try body.localSet(allocator, 5);
    try body.localGet(allocator, 5);
    try body.i32Load(allocator, 2, prepared_call_status_offset);
    try body.localTee(allocator, 6);
    try body.i32Eqz(allocator);
    try body.ifVoid(allocator);
    try body.localGet(allocator, 4);
    try body.ifVoid(allocator);
    try emitHelperClearContinuation(&body, allocator, 4, 6);
    try body.end(allocator);
    try body.i32Const(allocator, status_ok);
    try body.return_(allocator);
    try body.end(allocator);

    try body.localGet(allocator, 6);
    try body.i32Const(allocator, status_prepared);
    try body.i32Eq(allocator);
    try body.ifVoid(allocator);
    try body.localGet(allocator, 5);
    try body.i32Load(allocator, 2, prepared_call_metadata_offset);
    try body.localSet(allocator, 7);
    try body.localGet(allocator, 0);
    try body.localGet(allocator, 7);
    if (trampoline) |direct| {
        try body.call(allocator, direct);
    } else {
        try body.localGet(allocator, 5);
        try body.i32Load(allocator, 2, prepared_call_table_index_offset);
        try body.callIndirect(allocator, generated_type, 0);
    }
    try body.localSet(allocator, 6);
    try body.localGet(allocator, 6);
    try body.i32Const(allocator, status_yielded);
    try body.i32Eq(allocator);
    try body.ifVoid(allocator);
    try body.localGet(allocator, 6);
    try body.return_(allocator);
    try body.end(allocator);
    try body.localGet(allocator, 0);
    try body.localGet(allocator, 6);
    try body.call(allocator, finish_compiled_call);
    try body.localGet(allocator, 4);
    try body.ifVoid(allocator);
    try emitHelperClearContinuation(&body, allocator, 4, 6);
    try body.end(allocator);
    try body.i32Const(allocator, status_ok);
    try body.return_(allocator);
    try body.end(allocator);

    try body.localGet(allocator, 6);
    try body.finish(allocator);
    return object.defineFunction(
        "luauc_runtime_v1_fast_prepare",
        function_type,
        wasm.symbol.visibility_hidden,
        body,
    );
}

fn emitPreparedCompiledCall(
    self: anytype,
    function_register: u32,
    parameter_count: i32,
    result_count: i32,
    continuation: ?CallContinuation,
) Error!void {
    if (self.prepare_helper) |helper| {
        const continuation_id: i32 = if (continuation) |resumable|
            std.math.cast(i32, resumable.continuation_id) orelse return Error.ResourceLimit
        else
            0;
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(function_register));
        try self.body.i32Const(self.allocator, parameter_count);
        try self.body.i32Const(self.allocator, result_count);
        try self.body.i32Const(self.allocator, continuation_id);
        try self.body.call(self.allocator, helper);
        try self.body.localSet(self.allocator, self.status_local);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.emitReloadBase();
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.return_(self.allocator);
        try self.body.end(self.allocator);
        return;
    }
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(function_register));
    try self.body.i32Const(self.allocator, parameter_count);
    try self.body.i32Const(self.allocator, result_count);
    try self.body.call(self.allocator, self.prepare_compiled_call orelse return Error.UnsupportedCommand);
    try self.body.localTee(self.allocator, self.table_index_local);
    try self.body.i32Load(self.allocator, 2, prepared_call_status_offset);
    try self.body.localTee(self.allocator, self.status_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    if (continuation) |resumable|
        try self.emitClearContinuation(resumable.continuation_id);
    try self.emitReloadBase();
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Const(self.allocator, status_prepared);
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Load(self.allocator, 2, prepared_call_metadata_offset);
    try self.body.i32Load(self.allocator, 2, proto_function_id_offset);
    try self.body.i32Const(self.allocator, @intCast(self.planned_function_id));
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Load(self.allocator, 2, prepared_call_metadata_offset);
    try self.body.call(self.allocator, self.self_function);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Load(self.allocator, 2, prepared_call_metadata_offset);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Load(self.allocator, 2, prepared_call_table_index_offset);
    try self.body.callIndirect(self.allocator, self.generated_type, 0);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Const(self.allocator, status_yielded);
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.return_(self.allocator);
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.call(self.allocator, self.finish_compiled_call orelse return Error.UnsupportedCommand);
    if (continuation) |resumable|
        try self.emitClearContinuation(resumable.continuation_id);
    try self.emitReloadBase();
    try self.body.end(self.allocator);
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.return_(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}
fn ipairsImportId(self: anytype) Error!?u32 {
    var index: u32 = 0;
    while (index < self.proto.vm_constant_count) : (index += 1) {
        const value = try self.snapshot.vmConstant(self.proto, index);
        if (value.kind != .import or value.payload1 != 1)
            continue;
        const name_item = try self.snapshot.vmConstantItem(value.payload0);
        if (name_item.value != snapshot_v1.no_id)
            continue;
        const name_constant = try self.snapshot.vmConstant(self.proto, name_item.key);
        if (name_constant.kind != .string)
            continue;
        const name = try self.snapshot.string(name_constant.payload0);
        if (std.mem.eql(u8, name, "ipairs"))
            return index;
    }
    return null;
}

fn syntheticIpairsApplies(
    self: anytype,
    function_register: u32,
    parameter_count: i32,
    result_count: i32,
) Error!bool {
    if (parameter_count != 1 or result_count != 3)
        return false;
    if (try ipairsImportId(self) == null)
        return false;
    return function_register + 2 < self.proto.max_stack_size;
}

// ipairs(table) pushes its C upvalue (inext), the table, and integer 0.
// The callee must be the closure stored for that import. Any other call uses prepare.
fn emitSyntheticIpairs(
    self: anytype,
    function_register: u32,
    parameter_count: i32,
    result_count: i32,
    continuation: ?CallContinuation,
) Error!bool {
    if (!try syntheticIpairsApplies(self, function_register, parameter_count, result_count))
        return false;
    const import_id = (try ipairsImportId(self)) orelse return false;
    const import_i32 = std.math.cast(i32, import_id) orelse return false;
    const slot_addend = std.math.cast(i32, std.math.mul(u32, import_id, abi.tvalue_size) catch return false) orelse return false;
    const upval = abi.closure_c_upvals_offset;
    const result = function_register * abi.tvalue_size;
    const control = (function_register + 2) * abi.tvalue_size;

    // call_proto is the hit flag. status stays 0: 1 is status_unsupported_type.
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.call_proto_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.status_local);

    try emitTagIs(self, function_register, @intCast(abi.lua_tag_function));
    try self.body.ifVoid(self.allocator);
    try emitRegisterI32(self, function_register);
    try self.body.localTee(self.allocator, self.call_closure_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load8U(self.allocator, 0, abi.closure_is_c_offset);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load8U(self.allocator, 0, abi.closure_nupvalues_offset);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_ge_u);
    try self.body.ifVoid(self.allocator);
    // The entry cache stays zero when the frame-id check misses. GETIMPORT still
    // copies this Proto.k slot, so the proof reads the caller proto directly.
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_func_offset);
    try self.body.i32Load(self.allocator, 2, 0);
    try self.body.localTee(self.allocator, self.call_meta_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load8U(self.allocator, 0, abi.closure_is_c_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.closure_l_proto_offset);
    try self.body.localTee(self.allocator, self.call_meta_local);
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, import_i32);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.proto_sizek_offset);
    try self.body.opcode(self.allocator, i32_lt_u);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.proto_constants_offset);
    try self.body.localTee(self.allocator, self.call_func_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, slot_addend);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localTee(self.allocator, self.call_func_local);
    try self.body.i32Load(self.allocator, 2, abi.tvalue_tag_offset);
    try self.body.i32Const(self.allocator, @intCast(abi.lua_tag_function));
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Load(self.allocator, 2, 0);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try emitTagIs(self, function_register + 1, @intCast(abi.lua_tag_table));
    try self.body.ifVoid(self.allocator);

    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i64Load(self.allocator, 3, upval);
    try self.body.i64Store(self.allocator, 3, result);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i64Load(self.allocator, 3, upval + 8);
    try self.body.i64Store(self.allocator, 3, result + 8);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.f64Const(self.allocator, 0);
    try self.body.f64Store(self.allocator, 3, control);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, @intCast(abi.lua_tag_number));
    try self.body.i32Store(self.allocator, 2, control + abi.tvalue_tag_offset);
    try self.body.i32Const(self.allocator, 1);
    try self.body.localSet(self.allocator, self.call_proto_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.status_local);
    // The call prologue already installed this continuation. A synchronous hit must
    // clear it, the same way prepare does, or the next resumable instruction returns 2.
    if (continuation) |resumable|
        try self.emitClearContinuation(resumable.continuation_id);

    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);

    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try emitPreparedCompiledCall(self, function_register, parameter_count, result_count, continuation);
    try self.body.end(self.allocator);
    return true;
}

fn emitCallMiss(
    self: anytype,
    instruction_id: u32,
    function_register: u32,
    parameter_count: i32,
    result_count: i32,
    continuation: ?CallContinuation,
) Error!void {
    if (try emitSyntheticIpairs(self, function_register, parameter_count, result_count, continuation)) {
        // The miss arm calls prepare. A hit already published inext, the table, and 0.
    } else if (try self.stringMethodShape(instruction_id, function_register, parameter_count, result_count)) |shape| {
        try self.emitStringMethodGuards(shape);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.ifVoid(self.allocator);
        try self.emitStringMethodOperation(shape, continuation);
        try self.body.else_(self.allocator);
        // The fused namecall left the method nil. A table fast path stored a function and must be kept.
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Load(self.allocator, 2, function_register * abi.tvalue_size + tvalue_tag_offset);
        try self.body.i32Const(self.allocator, lua_tag_function);
        try self.body.i32Eq(self.allocator);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.emitResolveDeferredNamecall(function_register, shape.receiver, shape.key_constant);
        try self.body.end(self.allocator);
        try emitPreparedCompiledCall(self, function_register, parameter_count, result_count, continuation);
        try self.body.end(self.allocator);
    } else try emitPreparedCompiledCall(self, function_register, parameter_count, result_count, continuation);
}

fn emitOutlinedFastLuaResult(self: anytype, continuation: ?CallContinuation) Error!void {
    // The helper already cleared a non-zero continuation on success. A second exchange
    // would see previous id 0 and return internal error. live_continuation_local has no reader here.
    // Yielded and every other non-zero status return. Zero reloads base and continues.
    _ = continuation;
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.return_(self.allocator);
    try self.body.end(self.allocator);
    try self.emitReloadBase();
}

const PrefaceConstant = struct {
    load_id: u32,
    destination: u32,
    constant_id: u32,
};

const PrefaceMove = struct {
    source: u32,
    destination: u32,
    finish: u32,
};

const PrefaceCaptures = struct {
    count: u32,
    destination: u32,
    child_id: u32,
    kinds: [3]u32,
    sources: [3]u32,
};

pub const CallPreface = struct {
    start: u32,
    finish: u32,
    interrupt_line: u32,
    interrupt_continuation: u32,
    call_line: u32,
    call_continuation: u32,
    func_offset: i32,
    arg_bytes: i32,
    result_count: i32,
    move: ?PrefaceMove,
    constant: ?PrefaceConstant,
    captures: ?PrefaceCaptures,
};

fn prefaceHelpersReady(self: anytype) bool {
    return self.fast_lua_call != null and self.interrupt_helper != null and
        self.line_helper != null and self.exchange_helper != null and
        self.prepare_helper != null and self.call_preface[0] != null;
}

fn prefaceSpanOwned(self: anytype, start: u32, finish: u32) bool {
    const owner = self.plan.instructionBlock(start) orelse return false;
    var cursor = start;
    while (cursor <= finish) : (cursor += 1) {
        if ((self.plan.instructionBlock(cursor) orelse return false) != owner)
            return false;
        if (self.plan.clusterAt(cursor) != null)
            return false;
    }
    return true;
}

/// A constant load is a planned cluster. That cluster is the load itself, so the tail may own it.
fn prefaceConstantLoadOwned(self: anytype, owner: u32, start: u32, finish: u32) bool {
    var cursor = start;
    while (cursor <= finish) : (cursor += 1) {
        if ((self.plan.instructionBlock(cursor) orelse return false) != owner)
            return false;
        if (self.plan.clusterAt(cursor)) |cluster| {
            if (cluster.kind != .constant_load or cluster.start != start or cluster.finish != finish)
                return false;
        }
    }
    return true;
}

fn i32Immediate(value: u32) Error!i32 {
    return std.math.cast(i32, value) orelse Error.ResourceLimit;
}

fn prefaceCapturesAt(self: anytype, start: u32, range_finish: u32, move: bool) Error!?PrefaceCaptures {
    if (start > range_finish)
        return null;
    if ((try self.instruction(start)).command != .fallback_dupclosure)
        return null;
    const pattern = model.dupClosurePattern(self.snapshot, self.function, self.proto, start) catch return null;
    const captured = switch (pattern) {
        .closed => return null,
        .captured => |found| found,
    };
    if (captured.capture_count < 1 or captured.capture_count > 3)
        return null;
    const finish = std.math.add(u32, start, captured.capture_count) catch return Error.ResourceLimit;
    if (finish > range_finish or !prefaceSpanOwned(self, start, finish))
        return null;
    if (self.call_preface[callPrefaceIndex(move, false, captured.capture_count)] == null and
        self.call_preface[callPrefaceIndex(move, true, captured.capture_count)] == null)
        return null;
    var tail = PrefaceCaptures{
        .count = captured.capture_count,
        .destination = captured.destination,
        .child_id = std.math.add(u32, self.function_id_base, captured.child_proto_id) catch return Error.ResourceLimit,
        .kinds = .{ 0, 0, 0 },
        .sources = .{ 0, 0, 0 },
    };
    var index: u32 = 0;
    while (index < captured.capture_count) : (index += 1) {
        const capture = try model.markerCapture(
            self.snapshot,
            self.function,
            self.proto,
            captured.marker_start + index,
            false,
        );
        tail.kinds[index] = @intFromEnum(capture.kind);
        tail.sources[index] = capture.source;
    }
    return tail;
}

/// Interrupt, saved-pc line, and a fixed ordinary Lua call. A following constant load and
/// one to three dupclosure captures join when that exact helper exists.
/// Generic-for, string-method, and ipairs stay on the prepare-on-miss path.
pub noinline fn callPrefaceAt(self: anytype, start: u32, range_finish: u32) Error!?CallPreface {
    if (!prefaceHelpersReady(self))
        return null;
    if (start + 2 > range_finish or start + 2 >= self.function.instruction_count)
        return null;
    const interrupt = try self.instruction(start);
    const saved = try self.instruction(start + 1);
    const call = try self.instruction(start + 2);
    if (interrupt.command != .interrupt or saved.command != .set_savedpc or call.command != .call)
        return null;
    const owner = self.plan.instructionBlock(start) orelse return null;
    if (!prefaceSpanOwned(self, start, start + 2))
        return null;

    const interrupt_continuation = self.callContinuation(start) orelse return null;
    const call_continuation = self.callContinuation(start + 2) orelse return null;
    if (interrupt.operand_count != 1 or saved.operand_count != 1 or call.operand_count != 3)
        return null;
    const interrupt_line = try self.sourceLine(try self.uintConstant(try self.operand(interrupt, 0)));
    const saved_pc = try self.savedPc(saved);
    if (saved_pc == 0)
        return Error.InvalidOperandType;
    const call_line = try self.sourceLine(saved_pc - 1);

    const function_register = try self.vmRegisterIndex(try self.operand(call, 0));
    const parameter_count = try self.intConstant(try self.operand(call, 1));
    const result_count = try self.intConstant(try self.operand(call, 2));
    if (parameter_count < -1 or result_count < -1)
        return Error.UnsupportedControlFlow;
    if (parameter_count < 0 or result_count < 0)
        return null;
    const parameter_count_u32: u32 = @intCast(parameter_count);
    const result_count_u32: u32 = @intCast(result_count);
    if (parameter_count_u32 >= @as(u32, self.proto.max_stack_size) - function_register)
        return Error.UnsupportedControlFlow;
    if (result_count_u32 > @as(u32, self.proto.max_stack_size) - function_register)
        return Error.UnsupportedControlFlow;
    if (try syntheticIpairsApplies(self, function_register, parameter_count, result_count))
        return null;
    if (try self.stringMethodShape(start + 2, function_register, parameter_count, result_count) != null)
        return null;

    var preface = CallPreface{
        .start = start,
        .finish = start + 2,
        .interrupt_line = interrupt_line,
        .interrupt_continuation = interrupt_continuation.continuation_id,
        .call_line = call_line,
        .call_continuation = call_continuation.continuation_id,
        .func_offset = try slotByteOffset(function_register),
        .arg_bytes = (parameter_count + 1) * tvalue_size,
        .result_count = result_count,
        .move = null,
        .constant = null,
        .captures = null,
    };

    // A register move often sits between the call and the constant load. Take it only when
    // that lets the constant load or the captures join the same straight-line helper.
    const moved = try prefaceMoveAt(self, start + 3, range_finish, owner);
    const load_at: u32 = if (moved) |copy| copy.finish + 1 else start + 3;
    var took_move = false;
    if (self.call_preface[callPrefaceIndex(moved != null, true, 0)] != null) {
        if (try self.constantLoadPatternAt(load_at)) |load| {
            if (load.finish <= range_finish and prefaceConstantLoadOwned(self, owner, load.start, load.finish) and
                load.start < self.slots.len and
                (self.slots[load.start].shape == .tvalue or self.slots[load.start].shape == .none))
            {
                took_move = moved != null;
                preface.constant = .{
                    .load_id = load.start,
                    .destination = load.destination,
                    .constant_id = load.constant_id,
                };
                preface.finish = load.finish;
            }
        }
    }
    const capture_at: u32 = if (preface.constant != null)
        preface.finish + 1
    else if (moved) |copy|
        copy.finish + 1
    else
        start + 3;
    if (try prefaceCapturesAt(self, capture_at, range_finish, moved != null and capture_at != start + 3)) |tail| {
        const same_block = if (self.plan.instructionBlock(capture_at)) |found| found == owner else false;
        const aliases = if (preface.constant) |load| load.destination == tail.destination else false;
        const use_move = took_move or (moved != null and capture_at != start + 3);
        const helper = self.call_preface[callPrefaceIndex(use_move, preface.constant != null, tail.count)];
        if (same_block and !aliases and helper != null) {
            took_move = use_move;
            preface.captures = tail;
            preface.finish = capture_at + tail.count;
        }
    }
    if (took_move) {
        const copy = moved orelse return Error.UnsupportedCommand;
        preface.move = copy;
        if (preface.finish < copy.finish)
            preface.finish = copy.finish;
    }
    const capture_count: u32 = if (preface.captures) |tail| tail.count else 0;
    if (self.call_preface[callPrefaceIndex(preface.move != null, preface.constant != null, capture_count)] == null)
        return null;
    return preface;
}

fn prefaceMoveAt(self: anytype, start: u32, range_finish: u32, owner: u32) Error!?PrefaceMove {
    if (start + 1 > range_finish or start + 1 >= self.function.instruction_count)
        return null;
    const load = try self.instruction(start);
    const store = try self.instruction(start + 1);
    if (load.command != .load_tvalue or load.operand_count != 1 or
        store.command != .store_tvalue or store.operand_count != 2)
        return null;
    if (!prefaceSpanOwned(self, start, start + 1))
        return null;
    if ((self.plan.instructionBlock(start) orelse return null) != owner)
        return null;
    const source = try self.operand(load, 0);
    const destination = try self.operand(store, 0);
    const stored = try self.operand(store, 1);
    if (source.kind != .vm_reg or source.value >= self.proto.max_stack_size or
        destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
        stored.kind != .instruction or stored.value != start)
        return null;
    return .{
        .source = source.value,
        .destination = destination.value,
        .finish = start + 1,
    };
}

fn emitPrefaceImmediate(self: anytype, value: u32) Error!void {
    try self.body.i32Const(self.allocator, try i32Immediate(value));
}

fn emitPackedBits(self: anytype, value: u32) Error!void {
    try self.body.i32Const(self.allocator, @bitCast(value));
}

fn packLineContinuation(line: u32, continuation: u32) Error!u32 {
    if (line > abi.aot_line_mask or continuation > abi.aot_continuation_mask)
        return Error.ResourceLimit;
    return line | (continuation << abi.aot_continuation_shift);
}

fn packLowHigh(low: u32, high: u32) Error!u32 {
    if (low > 0xffff or high > 0xffff)
        return Error.ResourceLimit;
    return low | (high << 16);
}

/// A one-register move whose load is used only by the following store.
/// The helper reads both registers through L->base. The load allocates no read here.
pub fn emitRegisterMove(self: anytype, start: u32, range_finish: u32) Error!?u32 {
    const helper = self.move_reg orelse return null;
    if (self.plan.closureContaining(start) != null)
        return null;
    if (try self.isDupClosureCapture(start))
        return null;
    const owner = self.plan.instructionBlock(start) orelse return null;
    const copy = (try prefaceMoveAt(self, start, range_finish, owner)) orelse return null;
    if (self.plan.closureContaining(copy.finish) != null)
        return null;
    if (try self.isDupClosureCapture(copy.finish))
        return null;
    const uses = self.plan.instructionUses(start) orelse return null;
    if (uses != 1)
        return null;
    try self.body.localGet(self.allocator, 0);
    try emitPackedBits(self, try packLowHigh(copy.source, copy.destination));
    try self.body.call(self.allocator, helper);
    return copy.finish;
}

pub noinline fn emitFusedCallPreface(self: anytype, preface: CallPreface) Error!void {
    const capture_count: u32 = if (preface.captures) |tail| tail.count else 0;
    const helper = self.call_preface[callPrefaceIndex(preface.move != null, preface.constant != null, capture_count)] orelse
        return Error.UnsupportedCommand;
    try self.body.localGet(self.allocator, 0);
    try emitPackedBits(self, try packLineContinuation(preface.interrupt_line, preface.interrupt_continuation));
    try emitPackedBits(self, try packLineContinuation(preface.call_line, preface.call_continuation));
    try self.body.i32Const(self.allocator, preface.func_offset);
    try self.body.i32Const(self.allocator, preface.arg_bytes);
    try self.body.i32Const(self.allocator, preface.result_count);
    if (preface.move) |copy| {
        try emitPackedBits(self, try packLowHigh(copy.source, copy.destination));
    }
    if (preface.constant) |load| {
        try emitPrefaceImmediate(self, load.destination);
        try emitPrefaceImmediate(self, load.constant_id);
    }
    if (preface.captures) |tail| {
        try emitPrefaceImmediate(self, tail.destination);
        try emitPrefaceImmediate(self, tail.child_id);
        var index: u32 = 0;
        while (index < tail.count) : (index += 1)
            try emitPackedBits(self, try packLowHigh(tail.sources[index], tail.kinds[index]));
    }
    try self.body.call(self.allocator, helper);
    // Non-zero is the status this function returns. The abort block sits outside the dispatcher loop.
    try self.body.localTee(self.allocator, self.status_local);
    try self.body.branchIf(self.allocator, self.loop_branch_depth + 1);
    try self.emitReloadBase();
    if (preface.constant) |load| {
        const uses = self.plan.instructionUses(load.load_id) orelse return Error.InvalidInstructionResult;
        if (uses > 1 and (load.load_id >= self.slots.len or self.slots[load.load_id].shape != .none)) {
            if (load.load_id >= self.slots.len or self.slots[load.load_id].shape != .tvalue)
                return Error.InvalidInstructionResult;
            const published = snapshot_v1.IrOperand{ .kind = .vm_reg, .value = load.destination };
            try self.emitTValuePart(published, false);
            try self.body.localSet(self.allocator, self.slots[load.load_id].first);
            try self.emitTValuePart(published, true);
            try self.body.localSet(self.allocator, self.slots[load.load_id].second);
        }
    }
}

pub noinline fn emitCall(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
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

    // Room for a fixed Lua frame is decided by the guard. prepare_compiled_call remains the other arm.
    if (parameter_count >= 0 and result_count >= 0) {
        const arg_bytes: i32 = (parameter_count + 1) * tvalue_size;
        if (self.fast_lua_call) |helper| {
            const continuation_id: i32 = if (continuation) |resumable|
                std.math.cast(i32, resumable.continuation_id) orelse return Error.ResourceLimit
            else
                0;
            // String-method and ipairs hits still return the guard miss. Every other fixed call prepares inside the helper.
            const prepare_on_miss: i32 = if (self.prepare_helper != null and
                !try syntheticIpairsApplies(self, function_register, parameter_count, result_count) and
                (try self.stringMethodShape(instruction_id, function_register, parameter_count, result_count)) == null)
                1
            else
                0;
            try emitFastLuaCallSite(self, helper, try slotByteOffset(function_register), arg_bytes, result_count, abi.lua_callinfo_native, continuation_id, prepare_on_miss);
            if (prepare_on_miss != 0) {
                try emitOutlinedFastLuaResult(self, continuation);
            } else {
                try self.body.localGet(self.allocator, self.status_local);
                try self.body.i32Const(self.allocator, fast_lua_guard_miss);
                try self.body.i32Eq(self.allocator);
                try self.body.ifVoid(self.allocator);
                try emitCallMiss(self, instruction_id, function_register, parameter_count, result_count, continuation);
                try self.body.else_(self.allocator);
                try emitOutlinedFastLuaResult(self, continuation);
                try self.body.end(self.allocator);
            }
        } else {
            try emitFastLuaGuard(self, function_register, arg_bytes);
            try self.body.localGet(self.allocator, self.status_local);
            try self.body.ifVoid(self.allocator);
            try emitFastLuaInvoke(self, arg_bytes, result_count, continuation, abi.lua_callinfo_native, false, false);
            try self.body.else_(self.allocator);
            try emitCallMiss(self, instruction_id, function_register, parameter_count, result_count, continuation);
            try self.body.end(self.allocator);
        }
    } else {
        try emitPreparedCompiledCall(self, function_register, parameter_count, result_count, continuation);
    }
}

fn slotByteOffset(register: u32) Error!i32 {
    const bytes = std.math.mul(u32, register, abi.tvalue_size) catch return Error.ResourceLimit;
    return std.math.cast(i32, bytes) orelse return Error.ResourceLimit;
}

fn emitCopyStackSlot(self: anytype, destination: u32, source: u32) Error!void {
    // setobj2s copies the whole TValue. These slots do not overlap.
    const destination_bytes = try slotByteOffset(destination);
    const source_bytes = try slotByteOffset(source);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, destination_bytes);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, source_bytes);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.i64Load(self.allocator, 3, 0);
    try self.body.i64Store(self.allocator, 3, 0);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, destination_bytes);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, source_bytes);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.i64Load(self.allocator, 3, 8);
    try self.body.i64Store(self.allocator, 3, 8);
}

fn genericForFrameFits(self: anytype, pattern: model.GenericIterationPattern) bool {
    // forgLoopVariableCount rejects a zero count, stray aux bits, and the ipairs bit unless
    // the loop publishes exactly two variables. Those shapes stay on the helper, which runerrors.
    const variable_count = pattern.variable_count;
    if (variable_count == 0 or variable_count != (pattern.aux & 0xff))
        return false;
    if ((pattern.aux & 0x7fff_ff00) != 0)
        return false;
    if ((pattern.aux & 0x8000_0000) != 0 and variable_count != 2)
        return false;
    const max_stack: u32 = self.proto.max_stack_size;
    if (pattern.base > max_stack)
        return false;
    const required = @max(variable_count +| 3, 5);
    return required <= max_stack - pattern.base;
}

fn emitGenericForHelper(self: anytype, pattern: model.GenericIterationPattern, continuation: CallContinuation) Error!void {
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

fn emitSaveCallerCi(self: anytype) Error!void {
    // Byte offset, not a pointer: the CallInfo array can move while the iterator runs.
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_base_ci_offset);
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.localSet(self.allocator, self.call_aux_local);
}

fn emitGenericForPublish(self: anytype, pattern: model.GenericIterationPattern) Error!void {
    // The caller frame is already restored. Canonical top, then result one becomes the next control.
    // Nil terminates. false and every other Luau value repeat.
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_top_offset);
    try self.body.i32Store(self.allocator, 2, abi.lua_state_top_offset);
    try emitCopyStackSlot(self, pattern.base + 2, pattern.base + 3);
    try self.body.i32Const(self.allocator, @intCast(pattern.repeat_target));
    try self.body.i32Const(self.allocator, @intCast(pattern.exit_target));
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, try slotByteOffset(pattern.base + 3));
    try self.body.opcode(self.allocator, i32_add);
    try self.body.i32Load(self.allocator, 2, tvalue_tag_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.i32Eqz(self.allocator);
    try self.body.select(self.allocator);
    try self.body.localSet(self.allocator, self.dispatch_local);
}

fn emitGenericForStay(self: anytype, pattern: model.GenericIterationPattern) Error!void {
    // Same publish as the dispatcher. A non-nil control stays in the fused loop.
    // Nil records the exit block and leaves status at zero so the loop can branch out.
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_top_offset);
    try self.body.i32Store(self.allocator, 2, abi.lua_state_top_offset);
    try emitCopyStackSlot(self, pattern.base + 2, pattern.base + 3);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, try slotByteOffset(pattern.base + 3));
    try self.body.opcode(self.allocator, i32_add);
    try self.body.i32Load(self.allocator, 2, tvalue_tag_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.i32Eqz(self.allocator);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, @intCast(pattern.exit_target));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.end(self.allocator);
}

pub noinline fn emitGenericForProtocol(self: anytype, pattern: model.GenericIterationPattern, continuation: CallContinuation, stay: bool) Error!void {
    if (!genericForFrameFits(self, pattern)) {
        try emitGenericForHelper(self, pattern, continuation);
        return;
    }

    // performcally charges nCcalls because it has a C frame. This transfer is a wasm call, so the
    // counters stay put and yieldability (nCcalls <= baseCcalls) is unchanged.
    const required = @max(pattern.variable_count +| 3, 5);
    const arg_bytes: i32 = 3 * tvalue_size;
    try self.emitReloadBase();
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.status_local);

    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load8U(self.allocator, 0, abi.lua_state_marked_offset);
    try self.body.i32Const(self.allocator, abi.lua_black_bit);
    try self.body.opcode(self.allocator, i32_and);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_top_offset);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, try slotByteOffset(pattern.base + required));
    try self.body.opcode(self.allocator, i32_add);
    try self.body.opcode(self.allocator, i32_ge_u);
    try self.body.ifVoid(self.allocator);
    // ra+3..ra+5 receive the iterator triple. The last slot can sit one past the proto frame.
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_stack_last_offset);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, try slotByteOffset(pattern.base + 6));
    try self.body.opcode(self.allocator, i32_add);
    try self.body.opcode(self.allocator, i32_ge_u);
    try self.body.ifVoid(self.allocator);
    try emitCopyStackSlot(self, pattern.base + 5, pattern.base + 2);
    try emitCopyStackSlot(self, pattern.base + 4, pattern.base + 1);
    try emitCopyStackSlot(self, pattern.base + 3, pattern.base);
    if (self.fast_lua_call != null) {
        // The room checks passed. The shared call owns the closure guard.
        try self.body.i32Const(self.allocator, 1);
        try self.body.localSet(self.allocator, self.status_local);
    } else try emitFastLuaGuard(self, pattern.base + 3, arg_bytes);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);

    try self.body.localGet(self.allocator, self.status_local);
    try self.body.ifVoid(self.allocator);
    try emitSaveCallerCi(self);
    const iterator_flags = abi.lua_callinfo_native | abi.lua_callinfo_return;
    if (self.fast_lua_call) |helper| {
        const variable_count: i32 = @intCast(pattern.variable_count);
        const continuation_id = std.math.cast(i32, continuation.continuation_id) orelse return Error.ResourceLimit;
        try emitFastLuaCallSite(self, helper, try slotByteOffset(pattern.base + 3), arg_bytes, variable_count, iterator_flags, continuation_id, 0);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.i32Const(self.allocator, fast_lua_guard_miss);
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        try emitGenericForHelper(self, pattern, continuation);
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.i32Const(self.allocator, status_yielded);
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        try emitMarkIteratorYield(self);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.return_(self.allocator);
        try self.body.end(self.allocator);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.emitReloadBase();
        if (stay)
            try emitGenericForStay(self, pattern)
        else
            try emitGenericForPublish(self, pattern);
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.return_(self.allocator);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
    } else {
        try emitFastLuaInvoke(
            self,
            arg_bytes,
            @intCast(pattern.variable_count),
            continuation,
            iterator_flags,
            true,
            false,
        );
        if (stay)
            try emitGenericForStay(self, pattern)
        else
            try emitGenericForPublish(self, pattern);
    }
    try self.body.else_(self.allocator);
    try emitGenericForHelper(self, pattern, continuation);
    try self.body.end(self.allocator);
}

pub noinline fn emitUniformNumericRun(self: anytype, run: admission.UniformNumericRun) Error!void {
    if (run.accumulator >= self.slots.len or self.slots[run.accumulator].shape != .f64)
        return Error.InvalidInstructionResult;
    const accumulator = self.slots[run.accumulator].first;
    const offset = std.math.mul(u32, run.register, abi.tvalue_size) catch return Error.ResourceLimit;
    const count = std.math.cast(i32, run.count) orelse return Error.ResourceLimit;
    // Each iteration loads the register, applies the constant, and stores it.
    // The last result stays in the accumulator local for a later reader.
    try self.body.i32Const(self.allocator, count);
    try self.body.localSet(self.allocator, self.call_func_local);
    try self.body.loop(self.allocator);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.f64Load(self.allocator, 3, offset);
    try self.body.f64Const(self.allocator, @bitCast(run.constant_bits));
    try self.body.opcode(self.allocator, run.wasm_opcode);
    try self.body.localTee(self.allocator, accumulator);
    try self.body.f64Store(self.allocator, 3, offset);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.localTee(self.allocator, self.call_func_local);
    try self.body.branchIf(self.allocator, 0);
    try self.body.end(self.allocator);
}

const UniformArithmeticFallback = struct {
    count: u32,
    destination: u32,
    lhs: u32,
    rhs: u32,
    operation: i32,
    line0: u32,
    stride: i32,
};

fn uniformArithmeticFallback(self: anytype, block: snapshot_v1.IrBlock) Error!?UniformArithmeticFallback {
    if (!try admission.supportsArithmeticFallback(self, block))
        return null;
    const count = (block.finish - block.start) / 2;
    if (count < admission.uniform_numeric_run_minimum)
        return null;
    var destination: u32 = 0;
    var lhs: u32 = 0;
    var rhs: u32 = 0;
    var operation: i32 = 0;
    var line0: u32 = 0;
    var stride: i64 = 0;
    var index: u32 = 0;
    var cursor = block.start;
    while (cursor < block.finish) : ({
        cursor += 2;
        index += 1;
    }) {
        const marker = try self.instruction(cursor);
        const arithmetic = try self.instruction(cursor + 1);
        const saved = try self.savedPc(marker);
        if (saved == 0)
            return null;
        const line = try self.sourceLine(saved - 1);
        const step_destination = (try self.operand(arithmetic, 0)).value;
        const step_lhs = try self.valueOperandEncoding(try self.operand(arithmetic, 1));
        const step_rhs = try self.valueOperandEncoding(try self.operand(arithmetic, 2));
        const operation_operand = try self.operand(arithmetic, 3);
        if (operation_operand.kind != .constant)
            return null;
        const upstream = (try self.constant(operation_operand.value)).intValue() orelse return null;
        const step_operation = aotArithmeticOperation(upstream) orelse return null;
        if (index == 0) {
            destination = step_destination;
            lhs = step_lhs;
            rhs = step_rhs;
            operation = step_operation;
            line0 = line;
            continue;
        }
        if (step_destination != destination or step_lhs != lhs or step_rhs != rhs or
            step_operation != operation)
            return null;
        if (index == 1)
            stride = @as(i64, line) - @as(i64, line0);
        const expected = @as(i64, line0) + stride * @as(i64, index);
        if (expected != @as(i64, line))
            return null;
    }
    if (stride > std.math.maxInt(i32) or stride < std.math.minInt(i32))
        return null;
    const last = @as(i64, line0) + stride * (@as(i64, count) - 1);
    if (last < 0 or last > 0xfffff)
        return null;
    return .{
        .count = count,
        .destination = destination,
        .lhs = lhs,
        .rhs = rhs,
        .operation = operation,
        .line0 = line0,
        .stride = @intCast(stride),
    };
}

fn emitQuietLineFromLocal(self: anytype, line_local: u32) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_aotstate_offset);
    try self.body.i32Const(self.allocator, @bitCast(abi.aot_line_preserved_mask));
    try self.body.opcode(self.allocator, i32_and);
    try self.body.localGet(self.allocator, line_local);
    try self.body.opcode(self.allocator, i32_or);
    try self.body.i32Store(self.allocator, 2, abi.callinfo_aotstate_offset);
}

pub noinline fn emitUniformArithmeticFallback(self: anytype, block: snapshot_v1.IrBlock) Error!bool {
    const uniform = (try uniformArithmeticFallback(self, block)) orelse return false;
    const count = std.math.cast(i32, uniform.count) orelse return false;
    if (self.do_arith == null)
        return Error.UnsupportedCommand;
    try self.body.i32Const(self.allocator, count);
    try self.body.localSet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, @intCast(uniform.line0));
    try self.body.localSet(self.allocator, self.call_closure_local);
    try self.body.loop(self.allocator);
    try emitQuietLineFromLocal(self, self.call_closure_local);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(uniform.destination));
    try self.body.i32Const(self.allocator, @bitCast(uniform.lhs));
    try self.body.i32Const(self.allocator, @bitCast(uniform.rhs));
    try self.body.i32Const(self.allocator, uniform.operation);
    try self.body.call(self.allocator, self.do_arith.?);
    try self.emitReloadBase();
    if (uniform.stride != 0) {
        try self.body.localGet(self.allocator, self.call_closure_local);
        try self.body.i32Const(self.allocator, uniform.stride);
        try self.body.opcode(self.allocator, i32_add);
        try self.body.localSet(self.allocator, self.call_closure_local);
    }
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.localTee(self.allocator, self.call_func_local);
    try self.body.branchIf(self.allocator, 0);
    try self.body.end(self.allocator);
    try self.emitJump(try self.instruction(block.finish));
    return true;
}

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
const i32_and: u8 = 0x71;
const i32_lt_u: u8 = 0x49;
const i32_gt_u: u8 = 0x4b;
const i32_ge_u: u8 = 0x4f;
const i32_or: u8 = 0x72;
const i32_shr_u: u8 = 0x76;
const i64_eq: u8 = 0x51;

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

    // A null callback cannot yield. Publish the line and skip the helper calls.
    // A live callback keeps the exchange, interrupt, and clear sequence.
    try emitNullInterruptCallback(self);
    try self.body.ifVoid(self.allocator);
    try emitQuietInterrupt(self, line);
    try self.body.else_(self.allocator);
    try emitSlowInterrupt(self, continuation.continuation_id, line);
    try self.body.end(self.allocator);
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
fn emitFastStackPredicate(self: anytype, arg_bytes: i32) Error!void {
    // CallInfo and stack room change between calls. The value already on the stack is the identity condition.
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_end_ci_offset);
    try self.body.i32Ne(self.allocator);
    try self.body.opcode(self.allocator, i32_and);

    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, arg_bytes);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_stack_last_offset);
    try self.body.opcode(self.allocator, i32_lt_u);
    try self.body.opcode(self.allocator, i32_and);

    // luaD_checkstackfornewci grows when stack_last - arg_top <= stacksize * sizeof(TValue).
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_stack_last_offset);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, arg_bytes);
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
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, @intCast(function_register * abi.tvalue_size));
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.call_func_local);

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
    try self.body.i32Const(self.allocator, arg_bytes);
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
    try self.body.i32Const(self.allocator, arg_bytes);
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
    try self.body.i32Const(self.allocator, result_count);
    try self.body.i32Store(self.allocator, 2, abi.callinfo_nresults_offset);

    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Const(self.allocator, frame_flags);
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

fn emitCountedDirectCall(self: anytype, function: wasm.FunctionRef) Error!void {
    try self.body.call(self.allocator, self.count_direct_call orelse return Error.UnsupportedCommand);
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.call(self.allocator, function);
    try self.body.localSet(self.allocator, self.status_local);
}
fn emitCountedIndirectCall(self: anytype) Error!void {
    try self.body.call(self.allocator, self.count_indirect_call orelse return Error.UnsupportedCommand);
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
        return emitCountedIndirectCall(self);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, proto_function_id_offset);
    try self.body.i32Const(self.allocator, @intCast(index));
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try emitCountedDirectCall(self, siblings[index]);
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
    count_direct_call: wasm.FunctionRef,
    count_indirect_call: wasm.FunctionRef,
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
        try body.call(allocator, count_direct_call);
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
    try body.call(allocator, count_indirect_call);
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
    if (self.sibling_functions.len > 0 and self.sibling_functions.len <= max_inline_direct_siblings)
        return emitSiblingDispatch(self, 0);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, proto_function_id_offset);
    try self.body.i32Const(self.allocator, @intCast(self.planned_function_id));
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try emitCountedDirectCall(self, self.self_function);
    try self.body.else_(self.allocator);
    try emitCountedIndirectCall(self);
    try self.body.end(self.allocator);
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
    mark_opyield: bool,
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
    if (continuation) |resumable|
        try self.emitClearContinuation(resumable.continuation_id);
    try self.emitReloadBase();
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.call(self.allocator, self.finish_compiled_call orelse return Error.UnsupportedCommand);
    if (continuation) |resumable|
        try self.emitClearContinuation(resumable.continuation_id);
    try self.emitReloadBase();
    try self.body.end(self.allocator);
}
fn emitPreparedCompiledCall(
    self: anytype,
    function_register: u32,
    parameter_count: i32,
    result_count: i32,
    continuation: ?CallContinuation,
) Error!void {
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
    try self.body.call(self.allocator, self.count_direct_call orelse return Error.UnsupportedCommand);
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Load(self.allocator, 2, prepared_call_metadata_offset);
    try self.body.call(self.allocator, self.self_function);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.else_(self.allocator);
    try self.body.call(self.allocator, self.count_indirect_call orelse return Error.UnsupportedCommand);
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

// ipairs(table) pushes its C upvalue (inext), the table, and integer 0.
// The callee must be the closure stored for that import. Any other call uses prepare.
fn emitSyntheticIpairs(
    self: anytype,
    function_register: u32,
    parameter_count: i32,
    result_count: i32,
    continuation: ?CallContinuation,
) Error!bool {
    if (parameter_count != 1 or result_count != 3)
        return false;
    const import_id = (try ipairsImportId(self)) orelse return false;
    if (function_register + 2 >= self.proto.max_stack_size)
        return false;
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
    if (self.count_block) |probe|
        try self.body.call(self.allocator, probe);

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
    if (self.count_chain) |probe|
        try self.body.call(self.allocator, probe);
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
    if (self.count_scan) |probe|
        try self.body.call(self.allocator, probe);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Load(self.allocator, 2, 0);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    if (self.count_loop) |probe|
        try self.body.call(self.allocator, probe);
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
        try emitFastLuaGuard(self, function_register, arg_bytes);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.ifVoid(self.allocator);
        try emitFastLuaInvoke(self, arg_bytes, result_count, continuation, abi.lua_callinfo_native, false);
        try self.body.else_(self.allocator);
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
        try self.body.end(self.allocator);
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
    try emitFastLuaGuard(self, pattern.base + 3, arg_bytes);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);

    try self.body.localGet(self.allocator, self.status_local);
    try self.body.ifVoid(self.allocator);
    try emitSaveCallerCi(self);
    const iterator_flags = abi.lua_callinfo_native | abi.lua_callinfo_return;
    try emitFastLuaInvoke(
        self,
        arg_bytes,
        @intCast(pattern.variable_count),
        continuation,
        iterator_flags,
        true,
    );
    if (stay)
        try emitGenericForStay(self, pattern)
    else
        try emitGenericForPublish(self, pattern);
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

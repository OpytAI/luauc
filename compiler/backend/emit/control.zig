const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");

const aotArithmeticOperation = model.aotArithmeticOperation;
const Error = model.Error;
const CallContinuation = model.CallContinuation;
const StringEqualityPattern = model.StringEqualityPattern;
const status_ok = abi.status_ok;
const status_internal_error = abi.status_internal_error;
const status_yielded = abi.status_yielded;
const status_prepared = abi.status_prepared;
const proto_function_id_offset = abi.proto_function_id_offset;
const prepared_call_status_offset = abi.prepared_call_status_offset;
const prepared_call_table_index_offset = abi.prepared_call_table_index_offset;
const prepared_call_metadata_offset = abi.prepared_call_metadata_offset;
const lua_tag_boolean = abi.lua_tag_boolean;
const lua_tag_string = abi.lua_tag_string;
const lop_call = abi.lop_call;

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
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(line));
    try self.body.call(self.allocator, self.set_location orelse return Error.UnsupportedCommand);
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

    const lhs = try self.valueOperandEncoding(try self.operand(instruction_value, 0));
    const rhs = try self.valueOperandEncoding(try self.operand(instruction_value, 1));
    const operation = try self.comparisonOperation(try self.conditionOperand(instruction_value, 2));

    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @bitCast(lhs));
    try self.body.i32Const(self.allocator, @bitCast(rhs));
    try self.body.i32Const(self.allocator, operation);
    try self.body.call(self.allocator, self.compare_any orelse return Error.UnsupportedCommand);
    try self.emitInstructionResultSet(instruction_id);
    // Generic comparison can invoke a metamethod and relocate the active stack.
    try self.emitReloadBase();
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
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(pattern.lhs));
    try self.body.i32Const(self.allocator, @bitCast(pattern.rhs));
    try self.body.i32Const(self.allocator, 0);
    try self.body.call(self.allocator, self.compare_any orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
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

    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(source_register));
    try self.body.i32Const(self.allocator, @intCast(return_count));
    try self.body.call(self.allocator, self.return_);
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
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(next_id));
    try self.body.call(self.allocator, self.exchange_continuation orelse return Error.UnsupportedCommand);
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
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, 0);
    try self.body.call(self.allocator, self.finish_compiled_call orelse return Error.UnsupportedCommand);
    if (continuation) |resumable|
        try self.emitClearContinuation(resumable.continuation_id);
    try self.emitReloadBase();
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.return_(self.allocator);
    try self.body.end(self.allocator);
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.return_(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}

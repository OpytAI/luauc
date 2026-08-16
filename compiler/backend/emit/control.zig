const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");

const aotArithmeticOperation = model.aotArithmeticOperation;
const Error = model.Error;
const CallContinuation = model.CallContinuation;
const StringEqualityPattern = model.StringEqualityPattern;
const markerCapture = model.markerCapture;
const dupClosurePattern = model.dupClosurePattern;
const status_ok = abi.status_ok;
const status_internal_error = abi.status_internal_error;
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
pub noinline fn supportsArithmeticFallback(self: anytype, block: snapshot_v1.IrBlock) Error!bool {
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
pub noinline fn supportsComparisonFallback(self: anytype, block: snapshot_v1.IrBlock) Error!bool {
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
    _ = self.comparisonOperation(comparison_condition_value) catch return false;
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
pub noinline fn supportsMaterializedComparisonFallback(self: anytype, block: snapshot_v1.IrBlock) Error!bool {
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
    _ = self.comparisonOperation(condition_value) catch return false;
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
pub noinline fn supportsFallback(self: anytype, block: snapshot_v1.IrBlock) Error!bool {
    return (try self.supportsArithmeticFallback(block)) or (try self.supportsComparisonFallback(block)) or
        (try self.supportsMaterializedComparisonFallback(block)) or
        (try self.supportsGenericIterationFallback(block)) or
        (try self.supportsSpecializedIpairsFallback(block)) or
        (try self.xnextPreparationPattern(block) != null) or
        (try self.isFastcallFallbackBlock(block)) or (try self.supportsOrdinaryCallFallback(block)) or
        (try self.supportsNamecallFallback(block));
}
pub noinline fn supportsNamecallFallback(self: anytype, block: snapshot_v1.IrBlock) Error!bool {
    if (block.kind != .fallback or block.isEmpty() or block.finish != block.start + 1)
        return false;
    const semantic = try self.instruction(block.start);
    const jump = try self.instruction(block.finish);
    if (semantic.command != abi.ir_cmd_fallback_namecall or semantic.operand_count != 4 or
        jump.command != .jump or jump.operand_count != 1)
        return false;
    const pc = try self.operand(semantic, 0);
    const destination = try self.operand(semantic, 1);
    const source = try self.operand(semantic, 2);
    const key = try self.operand(semantic, 3);
    const target = try self.operand(jump, 0);
    if (pc.kind != .constant or (try self.constant(pc.value)).uintValue() == null or
        destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
        source.kind != .vm_reg or source.value >= self.proto.max_stack_size or
        key.kind != .vm_const or key.value >= self.proto.vm_constant_count or target.kind != .block)
        return false;
    const target_block = try self.snapshot.irBlock(self.function, target.value);
    return target_block.kind.isCompilable() and !target_block.isEmpty();
}
pub noinline fn supportsOrdinaryCallFallback(self: anytype, block: snapshot_v1.IrBlock) Error!bool {
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
pub noinline fn isOwnedSemanticTableFallbackBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
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
            if (try self.literalFieldSetPatternAt(instruction_id)) |pattern| {
                const match = try self.instruction(pattern.start + 1);
                const fallback = try self.operand(match, 2);
                if (fallback.kind == .block and fallback.value == block_id)
                    return true;
            }
            if (try self.inlineStringSetPatternAt(instruction_id, source)) |operation|
                if (operation.pattern.fallback == block_id)
                    return true;
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
pub noinline fn isOwnedDynamicLengthFallbackBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
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
pub noinline fn isBypassedEmissionBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
    return (try self.isBypassedStringEqualityBlock(block_id)) or
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
pub noinline fn isBypassedXnextFastPreparationBlock(self: anytype, block_id: u32) Error!bool {
    var source_id: u32 = 0;
    while (source_id < self.function.block_count) : (source_id += 1) {
        const source = try self.snapshot.irBlock(self.function, source_id);
        const pattern = (try self.xnextFastPreparationPattern(source)) orelse continue;
        if (pattern.fallback == block_id or pattern.publish == block_id)
            return true;
    }
    return false;
}
pub fn isFastcallFallbackBlock(self: anytype, block: snapshot_v1.IrBlock) Error!bool {
    var block_id: u32 = 0;
    while (block_id < self.function.block_count) : (block_id += 1) {
        const candidate = try self.snapshot.irBlock(self.function, block_id);
        if (candidate.start == block.start and candidate.finish == block.finish and candidate.kind == block.kind)
            return self.isFastcallFallback(block_id, block);
    }
    return false;
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
    try self.body.branch(self.allocator, 1);
}
pub noinline fn emitConditionalDispatch(self: anytype, true_target: u32, false_target: u32) Error!void {
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, @intCast(true_target));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.else_(self.allocator);
    try self.body.i32Const(self.allocator, @intCast(false_target));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.end(self.allocator);
    try self.body.branch(self.allocator, 1);
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
    const true_target = try self.requireCompiledTarget(try self.operand(instruction_value, 3));
    const false_target = try self.requireCompiledTarget(try self.operand(instruction_value, 4));
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
    try self.body.branch(self.allocator, 1);
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
pub noinline fn emitDupClosure(self: anytype, instruction_id: u32) Error!void {
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
pub fn callContinuation(self: anytype, instruction_id: u32) ?CallContinuation {
    for (self.call_continuations) |continuation| {
        if (continuation.instruction_id == instruction_id)
            return continuation;
    }
    return null;
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

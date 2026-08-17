const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");

const Error = model.Error;
const aotArithmeticOperation = model.aotArithmeticOperation;
const lua_tag_boolean = abi.lua_tag_boolean;
const lua_tag_nil = abi.lua_tag_nil;
const lua_tag_string = abi.lua_tag_string;
const lop_call = abi.lop_call;
const ir_cmd_get_arr_addr = abi.ir_cmd_get_arr_addr;
const ir_cmd_check_array_size = abi.ir_cmd_check_array_size;
const ir_cmd_do_len = abi.ir_cmd_do_len;
const ir_cmd_fallback_namecall = abi.ir_cmd_fallback_namecall;
const ir_cmd_get_table = abi.ir_cmd_get_table;
const ir_cmd_set_table = abi.ir_cmd_set_table;

fn immediateNumber(self: anytype, operand: snapshot_v1.IrOperand) Error!?f64 {
    if (operand.kind != .constant)
        return null;
    const constant = try self.constant(operand.value);
    return switch (constant.kind) {
        .int => @floatFromInt(constant.intValue() orelse return Error.InvalidOperandType),
        .uint => @floatFromInt(constant.uintValue() orelse return Error.InvalidOperandType),
        .int64 => @floatFromInt(constant.int64Value() orelse return Error.InvalidOperandType),
        .double => constant.doubleValue() orelse return Error.InvalidOperandType,
        .tag, .import => return Error.InvalidOperandType,
    };
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

pub noinline fn supportsLengthFallback(self: anytype, block: snapshot_v1.IrBlock) Error!bool {
    if (block.kind != .fallback or block.isEmpty() or block.finish - block.start != 2)
        return false;
    const marker = try self.instruction(block.start);
    const length = try self.instruction(block.start + 1);
    const jump = try self.instruction(block.start + 2);
    if (marker.command != .set_savedpc or length.command != abi.ir_cmd_do_len or jump.command != .jump or
        marker.operand_count != 1 or length.operand_count != 2 or jump.operand_count != 1)
        return false;
    const destination = try self.operand(length, 0);
    const source = try self.operand(length, 1);
    const jump_target = try self.operand(jump, 0);
    if (destination.kind != .vm_reg or source.kind != .vm_reg or jump_target.kind != .block or
        destination.value >= self.proto.max_stack_size or source.value >= self.proto.max_stack_size)
        return false;
    const target = try self.snapshot.irBlock(self.function, jump_target.value);
    return target.kind.isCompilable() and !target.isEmpty();
}

pub noinline fn supportsFallback(self: anytype, block: snapshot_v1.IrBlock) Error!bool {
    if (block.kind != .fallback or block.isEmpty())
        return false;
    const block_id = self.plan.instructionBlock(block.start) orelse return false;
    return self.plan.supportsFallback(block_id);
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

pub noinline fn ordinaryCallFallbackTarget(self: anytype, block: snapshot_v1.IrBlock) Error!?u32 {
    if (block.kind != .fallback or block.isEmpty() or block.finish < block.start + 3)
        return null;
    const saved_id = block.finish - 2;
    const saved = try self.instruction(saved_id);
    const call = try self.instruction(block.finish - 1);
    const jump = try self.instruction(block.finish);
    if (saved.command != .set_savedpc or saved.operand_count != 1 or
        call.command != .call or call.operand_count != 3 or
        jump.command != .jump or jump.operand_count != 1)
        return null;

    const saved_pc = self.savedPc(saved) catch return null;
    if (saved_pc == 0 or saved_pc > self.proto.code_count)
        return null;
    const call_word = try self.snapshot.bytecodeWord(self.proto, saved_pc - 1);
    if (@as(u8, @truncate(call_word)) != lop_call)
        return null;
    const destination = (call_word >> 8) & 0xff;
    const parameter_count = @as(i32, @intCast((call_word >> 16) & 0xff)) - 1;
    const result_count = @as(i32, @intCast((call_word >> 24) & 0xff)) - 1;
    if ((self.vmRegisterIndex(try self.operand(call, 0)) catch return null) != destination or
        (self.intConstant(try self.operand(call, 1)) catch return null) != parameter_count or
        (self.intConstant(try self.operand(call, 2)) catch return null) != result_count)
        return null;
    const target = try self.operand(jump, 0);
    if (target.kind != .block or target.value >= self.function.block_count)
        return null;
    const target_block = try self.snapshot.irBlock(self.function, target.value);
    if (!target_block.kind.isCompilable() or target_block.isEmpty())
        return null;

    var found_import = false;
    var instruction_id = block.start;
    while (instruction_id < saved_id) : (instruction_id += 1) {
        const instruction_value = try self.instruction(instruction_id);
        if (instruction_value.command == .get_cached_import) {
            if (found_import or instruction_value.operand_count != 4 or
                (self.vmRegisterIndex(try self.operand(instruction_value, 0)) catch return null) != destination)
                return null;
            found_import = true;
        }
    }
    return if (found_import) target.value else null;
}

pub noinline fn supportsOrdinaryCallFallback(self: anytype, block: snapshot_v1.IrBlock) Error!bool {
    return try ordinaryCallFallbackTarget(self, block) != null;
}

pub noinline fn isOwnedSemanticTableFallbackBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
    if (block.kind != .fallback or block.isEmpty())
        return false;
    return self.plan.ownsFallback(block_id);
}

pub noinline fn isOwnedDynamicLengthFallbackBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
    if (block.kind != .fallback or block.isEmpty())
        return false;
    return self.plan.ownsFallback(block_id);
}

pub noinline fn isBypassedEmissionBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
    if (block.kind == .linearized and self.function.entry_block != block_id and
        (self.plan.blockReferences(block_id) orelse return Error.UnsupportedControlFlow) == 0)
        return true;
    return self.plan.isPlannedBypass(block_id);
}

pub noinline fn isBypassedXnextFastPreparationBlock(self: anytype, block_id: u32) Error!bool {
    return self.plan.ownsFallback(block_id);
}

pub fn isFastcallFallbackBlock(self: anytype, block: snapshot_v1.IrBlock) Error!bool {
    const block_id = self.plan.instructionBlock(block.start) orelse return false;
    return self.plan.blockKind(block_id) == .fastcall_fallback;
}

pub noinline fn supportsGenericIterationFallback(self: anytype, block: snapshot_v1.IrBlock) Error!bool {
    const fallback = (try self.genericIterationFallbackPattern(block)) orelse return false;
    const resolved_fallback_id = self.plan.instructionBlock(block.start) orelse return Error.UnsupportedControlFlow;
    const fallback_block = try self.snapshot.irBlock(self.function, resolved_fallback_id);
    if (fallback_block.kind != block.kind or fallback_block.start != block.start or
        fallback_block.finish != block.finish)
        return Error.UnsupportedControlFlow;

    if (self.plan.fallbackOwner(resolved_fallback_id)) |owner| {
        if (self.plan.blockKind(owner) != .generic_iteration)
            return false;
        const owner_block = try self.snapshot.irBlock(self.function, owner);
        const fast = (try self.genericIterationPattern(owner_block)) orelse return false;
        return fast.fallback_target != null and fast.fallback_target.? == resolved_fallback_id and
            fast.base == fallback.base and fast.aux == fallback.aux and
            fast.repeat_target == fallback.repeat_target and
            fast.exit_target == fallback.exit_target;
    }

    var block_id: u32 = 0;
    while (block_id < self.function.block_count) : (block_id += 1) {
        const candidate = try self.snapshot.irBlock(self.function, block_id);
        const fast = (try self.genericIterationPattern(candidate)) orelse continue;
        if (fast.fallback_target != null and fast.fallback_target.? == resolved_fallback_id and
            fast.base == fallback.base and fast.aux == fallback.aux and
            fast.repeat_target == fallback.repeat_target and
            fast.exit_target == fallback.exit_target)
            return true;
    }
    return false;
}

pub noinline fn supportsSpecializedIpairsFallback(self: anytype, block: snapshot_v1.IrBlock) Error!bool {
    const fallback = (try self.genericIterationFallbackPattern(block)) orelse return false;
    if (fallback.aux != 0x8000_0002)
        return false;
    const resolved_fallback = self.plan.instructionBlock(block.start) orelse return Error.UnsupportedControlFlow;
    const fallback_block = try self.snapshot.irBlock(self.function, resolved_fallback);
    if (fallback_block.kind != block.kind or fallback_block.start != block.start or
        fallback_block.finish != block.finish)
        return Error.UnsupportedControlFlow;

    const indexed = self.plan.fallbackOwner(resolved_fallback);
    if (indexed) |owner| {
        if (self.plan.blockKind(owner) != .specialized_ipairs)
            return false;
    }
    var block_id: u32 = indexed orelse 0;
    while (block_id < self.function.block_count) : (block_id += 1) {
        if (indexed != null and block_id != indexed.?)
            break;
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

pub noinline fn isBypassedSpecializedIpairsPublishBlock(self: anytype, block_id: u32) Error!bool {
    return self.plan.ownsFallback(block_id);
}

pub noinline fn isBypassedStringLinearizedBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
    if (block.kind != .linearized or self.function.entry_block == block_id)
        return false;
    return self.plan.isPlannedBypass(block_id);
}

pub noinline fn isBypassedGenericTableLinearizedBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
    if (block.kind != .linearized or self.function.entry_block == block_id)
        return false;
    return self.plan.isPlannedBypass(block_id);
}

pub noinline fn isBypassedGlobalLinearizedBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
    if (block.kind != .linearized or self.function.entry_block == block_id)
        return false;
    return self.plan.isPlannedBypass(block_id);
}

pub noinline fn isBypassedPowLinearizedBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
    if (block.kind != .linearized or self.function.entry_block == block_id)
        return false;
    return self.plan.isPlannedBypass(block_id);
}

pub noinline fn isBypassedConstantArithmeticLinearizedBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
    if (block.kind != .linearized or self.function.entry_block == block_id)
        return false;
    return self.plan.isPlannedBypass(block_id);
}

pub noinline fn isBypassedStringEqualityBlock(self: anytype, block_id: u32) Error!bool {
    if (self.function.entry_block == block_id)
        return false;
    return self.plan.isPlannedBypass(block_id);
}

pub noinline fn isBypassedPlainTableNamecallBlock(self: anytype, block_id: u32) Error!bool {
    if (self.function.entry_block == block_id)
        return false;
    return self.plan.ownsFallback(block_id);
}

pub noinline fn supportsGeneralTableFallback(
    self: anytype,
    block: snapshot_v1.IrBlock,
) Error!bool {
    if (block.kind != .fallback or block.isEmpty() or block.finish != block.start + 2)
        return false;
    const marker = try self.instruction(block.start);
    const semantic = try self.instruction(block.start + 1);
    const jump = try self.instruction(block.finish);
    if (marker.command != .set_savedpc or marker.operand_count != 1 or
        (semantic.command != abi.ir_cmd_get_table and semantic.command != abi.ir_cmd_set_table) or
        semantic.operand_count != 3 or jump.command != .jump or jump.operand_count != 1)
        return false;
    _ = self.savedPc(marker) catch return false;
    _ = self.vmRegisterIndex(try self.operand(semantic, 0)) catch return false;
    _ = self.vmRegisterIndex(try self.operand(semantic, 1)) catch return false;
    const key = try self.operand(semantic, 2);
    if (key.kind == .constant) {
        _ = (immediateNumber(self, key) catch return false) orelse return false;
    } else {
        _ = self.valueOperandEncoding(key) catch return false;
    }
    const target = try self.operand(jump, 0);
    if (target.kind != .block or target.value >= self.function.block_count)
        return false;
    const target_block = try self.snapshot.irBlock(self.function, target.value);
    return target_block.kind.isCompilable() and !target_block.isEmpty();
}

pub const isRequireImportInstruction = model.isRequireImportInstruction;


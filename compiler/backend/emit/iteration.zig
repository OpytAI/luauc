const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");

const Error = model.Error;
const ArrayOperationKind = model.ArrayOperationKind;
const SemanticArrayOperation = model.SemanticArrayOperation;
const ArrayOperationPattern = model.ArrayOperationPattern;
const GenericIterationPattern = model.GenericIterationPattern;
const XnextPreparationPattern = model.XnextPreparationPattern;
const XnextFastPreparationPattern = model.XnextFastPreparationPattern;
const GenericTablePattern = model.GenericTablePattern;
const GlobalPattern = model.GlobalPattern;
const StringTablePattern = model.StringTablePattern;
const ir_cmd_get_arr_addr = abi.ir_cmd_get_arr_addr;
const ir_cmd_check_array_size = abi.ir_cmd_check_array_size;
const ir_cmd_forgloop = abi.ir_cmd_forgloop;
const ir_cmd_forgloop_fallback = abi.ir_cmd_forgloop_fallback;
const ir_cmd_forgprep_xnext_fallback = abi.ir_cmd_forgprep_xnext_fallback;
const tvalue_size = abi.tvalue_size;
const tvalue_tag_offset = abi.tvalue_tag_offset;
const lua_tag_nil = abi.lua_tag_nil;
const lua_tag_lightuserdata = abi.lua_tag_lightuserdata;
const lua_tag_number = abi.lua_tag_number;
const lua_tag_table = abi.lua_tag_table;
const lu_tag_iterator = abi.lu_tag_iterator;

pub noinline fn genericIterationFallbackPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?GenericIterationPattern {
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
pub noinline fn genericIterationPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?GenericIterationPattern {
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
pub noinline fn xnextPreparationPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?XnextPreparationPattern {
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
pub fn xnextCanonicalPublish(self: anytype, start: u32, base: u32, target: u32) Error!bool {
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
pub noinline fn xnextFastPreparationPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?XnextFastPreparationPattern {
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
pub noinline fn emitXnextFastPreparationBlock(
    self: anytype,
    block_id: u32,
    block: snapshot_v1.IrBlock,
    pattern: XnextFastPreparationPattern,
) Error!void {
    _ = block_id;
    if (pattern.start > block.start) {
        if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
            return;
    }
    try self.emitPcLocation(pattern.pc);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(pattern.base));
    try self.body.call(self.allocator, self.forgprep_xnext_fallback orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
    try self.body.i32Const(self.allocator, @intCast(pattern.target));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.branch(self.allocator, self.loop_branch_depth);
}
pub noinline fn emitXnextPreparationBlock(
    self: anytype,
    block_id: u32,
    pattern: XnextPreparationPattern,
) Error!void {
    _ = block_id;
    try self.emitPcLocation(pattern.pc);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(pattern.base));
    try self.body.call(self.allocator, self.forgprep_xnext_fallback orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
    try self.body.i32Const(self.allocator, @intCast(pattern.target));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.branch(self.allocator, self.loop_branch_depth);
}
pub noinline fn specializedIpairsPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?GenericIterationPattern {
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
pub noinline fn emitGeneralForgLoop(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 4);
    const base = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
    const aux = try self.genericIterationAux(try self.operand(instruction_value, 1));
    const repeat = try self.requireCompiledTarget(try self.operand(instruction_value, 2));
    const exit = try self.requireCompiledTarget(try self.operand(instruction_value, 3));
    const live_count = @max(std.math.add(u32, aux & 0xff, 3) catch return Error.UnsupportedControlFlow, 5);
    if (live_count > self.proto.max_stack_size or
        base > @as(u32, self.proto.max_stack_size) - live_count)
        return Error.UnsupportedControlFlow;
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(base));
    try self.body.i32Const(self.allocator, @bitCast(aux));
    try self.body.call(self.allocator, self.forg_loop orelse return Error.UnsupportedCommand);
    try self.body.localSet(self.allocator, self.status_local);
    try self.emitReloadBase();
    try self.body.i32Const(self.allocator, @intCast(repeat));
    try self.body.i32Const(self.allocator, @intCast(exit));
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.select(self.allocator);
    try self.body.localSet(self.allocator, self.dispatch_local);
}

pub noinline fn emitGeneralForgLoopFallback(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    try self.requireOperandCount(instruction_value, 4);
    const base = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
    const aux = try self.genericIterationAux(try self.operand(instruction_value, 1));
    const repeat = try self.requireCompiledTarget(try self.operand(instruction_value, 2));
    const exit = try self.requireCompiledTarget(try self.operand(instruction_value, 3));
    try self.emitGenericIterationFallbackCall(instruction_id, .{
        .marker = if (instruction_id != 0) try self.instruction(instruction_id - 1) else instruction_value,
        .base = base,
        .aux = aux,
        .variable_count = aux & 0xff,
        .repeat_target = repeat,
        .exit_target = exit,
    });
}

pub noinline fn emitGenericIterationCall(self: anytype, pattern: GenericIterationPattern) Error!void {
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
pub noinline fn emitGenericIterationFinish(self: anytype, pattern: GenericIterationPattern) Error!void {
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
pub noinline fn emitGenericIterationFallbackCall(
    self: anytype,
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
pub noinline fn emitGenericIterationBlock(
    self: anytype,
    block_id: u32,
    pattern: GenericIterationPattern,
    guarded: bool,
) Error!void {
    const block = try self.snapshot.irBlock(self.function, block_id);
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
    try self.body.branch(self.allocator, self.loop_branch_depth);
}
pub noinline fn emitGenericIterationPrep(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    const owner_id = self.plan.instructionBlock(instruction_id) orelse return Error.UnsupportedControlFlow;
    const block = try self.snapshot.irBlock(self.function, owner_id);
    if (block.isEmpty() or instruction_id < block.start or instruction_id > block.finish)
        return Error.UnsupportedControlFlow;
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
    try self.body.branch(self.allocator, self.loop_branch_depth);
}
pub noinline fn emitArrayOperationBlock(
    self: anytype,
    block_id: u32,
    block: snapshot_v1.IrBlock,
    pattern: ArrayOperationPattern,
    operation: ArrayOperationKind,
) Error!void {
    _ = block_id;
    if (pattern.start > block.start) {
        if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
            return;
    }
    try self.emitArrayOperation(pattern, operation);
    try self.body.branch(self.allocator, self.loop_branch_depth);
}
pub noinline fn emitArrayOperation(
    self: anytype,
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
pub fn semanticArrayOperation(self: anytype, block: snapshot_v1.IrBlock) Error!?SemanticArrayOperation {
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
pub noinline fn emitStringTableOperationBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock, pattern: StringTablePattern) Error!void {
    _ = block_id;
    if (pattern.start > block.start) {
        if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
            return;
    }
    try self.emitStringTableOperation(pattern);
}
pub noinline fn emitStringTableOperation(self: anytype, pattern: StringTablePattern) Error!void {
    try self.emitStringTableHelper(pattern);
    try self.body.i32Const(self.allocator, @intCast(pattern.rejoin));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.branch(self.allocator, self.loop_branch_depth);
}
pub noinline fn emitStringTableHelper(self: anytype, pattern: StringTablePattern) Error!void {
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
pub noinline fn emitGlobalOperationBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock, pattern: GlobalPattern) Error!void {
    _ = block_id;
    if (pattern.start > block.start) {
        if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
            return;
    }
    try self.emitGlobalOperation(pattern);
    try self.body.branch(self.allocator, self.loop_branch_depth);
}
pub noinline fn emitGlobalOperation(self: anytype, pattern: GlobalPattern) Error!void {
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
pub noinline fn emitGenericTableFallbackCall(self: anytype, pattern: GenericTablePattern) Error!void {
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
pub noinline fn emitGenericTableDirectAttempt(self: anytype, pattern: GenericTablePattern) Error!void {
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
pub noinline fn emitGenericTableOperationBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock, pattern: GenericTablePattern) Error!void {
    _ = block_id;
    if (pattern.start > block.start) {
        if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
            return;
    }
    try self.emitGenericTableDirectAttempt(pattern);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.emitGenericTableFallbackCall(pattern);
    try self.body.end(self.allocator);
    try self.body.i32Const(self.allocator, @intCast(pattern.rejoin));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.branch(self.allocator, self.loop_branch_depth);
}
pub noinline fn emitInlineGenericTableSet(self: anytype, pattern: GenericTablePattern) Error!void {
    try self.emitGenericTableDirectAttempt(pattern);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.emitGenericTableFallbackCall(pattern);
    try self.body.end(self.allocator);
}

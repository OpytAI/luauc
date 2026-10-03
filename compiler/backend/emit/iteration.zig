const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");
const tables = @import("luauc_backend_emit_tables");

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
const lua_tag_string = abi.lua_tag_string;
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
    var fallback = (try self.genericIterationFallbackPattern(fallback_block)) orelse return null;
    if (fallback.aux != 0x8000_0002)
        return null;
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
    }, false);
}

pub noinline fn emitGenericIterationCall(self: anytype, pattern: GenericIterationPattern) Error!void {
    // ipairs (aux 0x80000002) stops at the first hole. The array step is a few loads.
    // Every other proved builtin cursor walks the array, skipping holes, then the live hash nodes.
    // A cursor that fails the same tag proof still enters the pinned helper.
    if (pattern.aux == 0x8000_0002) {
        try emitIpairsIteratorOk(self, pattern.base);
        try self.body.ifVoid(self.allocator);
        try emitIpairsArrayStep(self, pattern);
        try self.body.else_(self.allocator);
        try emitForgLoopHelper(self, pattern);
        try self.body.end(self.allocator);
        return;
    }
    try emitIpairsIteratorOk(self, pattern.base);
    try self.body.ifVoid(self.allocator);
    try emitBuiltinTableStep(self, pattern);
    try self.body.else_(self.allocator);
    try emitForgLoopHelper(self, pattern);
    try self.body.end(self.allocator);
}
fn emitForgLoopHelper(self: anytype, pattern: GenericIterationPattern) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(pattern.base));
    try self.body.i32Const(self.allocator, @bitCast(pattern.aux));
    try self.body.call(self.allocator, self.forg_loop orelse return Error.UnsupportedCommand);
    try self.body.localSet(self.allocator, self.status_local);
    try self.emitReloadBase();
    try emitIterationSelect(self, pattern);
}
fn emitIterationSelect(self: anytype, pattern: GenericIterationPattern) Error!void {
    try self.body.i32Const(self.allocator, @intCast(pattern.repeat_target));
    try self.body.i32Const(self.allocator, @intCast(pattern.exit_target));
    try self.body.localGet(self.allocator, self.status_local);
    // One means the next key/value tuple was published. Zero means the loop is done.
    try self.body.select(self.allocator);
    try self.body.localSet(self.allocator, self.dispatch_local);
}
fn slotField(base: u32, register: u32, field: u32) u32 {
    return (base + register) * tvalue_size + field;
}
fn emitIpairsIteratorOk(self: anytype, base: u32) Error!void {
    const table_slot = slotField(base, 1, 0);
    const cursor_slot = slotField(base, 2, 0);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, table_slot + tvalue_tag_offset);
    try self.body.i32Const(self.allocator, @intCast(lua_tag_table));
    try self.body.i32Eq(self.allocator);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, cursor_slot + tvalue_tag_offset);
    try self.body.i32Const(self.allocator, @intCast(lua_tag_lightuserdata));
    try self.body.i32Eq(self.allocator);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, cursor_slot + abi.tvalue_extra_offset);
    try self.body.i32Const(self.allocator, lu_tag_iterator);
    try self.body.i32Eq(self.allocator);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, cursor_slot);
    try self.body.i32Const(self.allocator, 0);
    try self.body.opcode(self.allocator, 0x4e); // i32.ge_s
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, table_slot);
    try self.body.opcode(self.allocator, 0x45); // i32.eqz
    try self.body.opcode(self.allocator, 0x45); // i32.eqz
    try self.body.opcode(self.allocator, 0x71); // i32.and
}
fn emitIpairsArrayStep(self: anytype, pattern: GenericIterationPattern) Error!void {
    const base = pattern.base;
    const cursor_slot = slotField(base, 2, 0);
    const key_slot = slotField(base, 3, 0);
    const value_slot = slotField(base, 4, 0);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, slotField(base, 1, 0));
    try self.body.localSet(self.allocator, self.call_aux_local);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, cursor_slot);
    try self.body.localSet(self.allocator, self.call_func_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Load(self.allocator, 2, abi.table_sizearray_offset);
    try self.body.opcode(self.allocator, 0x4f); // i32.ge_u
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Load(self.allocator, 2, abi.table_array_offset);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, @intCast(tvalue_size));
    try self.body.opcode(self.allocator, 0x6c); // i32.mul
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.localSet(self.allocator, self.call_closure_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load(self.allocator, 2, tvalue_tag_offset);
    try self.body.opcode(self.allocator, 0x45); // i32.eqz
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.i32Store(self.allocator, 2, cursor_slot);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, lu_tag_iterator);
    try self.body.i32Store(self.allocator, 2, cursor_slot + abi.tvalue_extra_offset);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, @intCast(lua_tag_lightuserdata));
    try self.body.i32Store(self.allocator, 2, cursor_slot + tvalue_tag_offset);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.opcode(self.allocator, 0xb7); // f64.convert_i32_s
    try self.body.f64Store(self.allocator, 3, key_slot);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, @intCast(lua_tag_number));
    try self.body.i32Store(self.allocator, 2, key_slot + tvalue_tag_offset);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i64Load(self.allocator, 3, 0);
    try self.body.i64Store(self.allocator, 3, value_slot);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i64Load(self.allocator, 3, 8);
    try self.body.i64Store(self.allocator, 3, value_slot + 8);
    try self.body.i32Const(self.allocator, 1);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try emitIterationSelect(self, pattern);
}
fn emitBuiltinTableStep(self: anytype, pattern: GenericIterationPattern) Error!void {
    // luauc_runtime_v1_forg_loop publishes one live pair per entry. Variables past the key and
    // value are nil on both the body and the exit. The miss path is the helper above.
    try emitIterationExtraNils(self, pattern);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, slotField(pattern.base, 1, 0));
    try self.body.localSet(self.allocator, self.call_aux_local);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, slotField(pattern.base, 2, 0));
    try self.body.localSet(self.allocator, self.call_func_local);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Load(self.allocator, 2, abi.table_sizearray_offset);
    try self.body.localSet(self.allocator, self.call_proto_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.status_local);
    try emitBuiltinArrayScan(self, pattern.base);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try emitBuiltinHashScan(self, pattern.base);
    try self.body.end(self.allocator);
    try emitIterationSelect(self, pattern);
}
fn emitIterationExtraNils(self: anytype, pattern: GenericIterationPattern) Error!void {
    if (pattern.variable_count <= 2)
        return;
    const origin = std.math.add(u32, pattern.base, 3) catch return Error.UnsupportedControlFlow;
    try self.body.i32Const(self.allocator, 2);
    try self.body.localSet(self.allocator, self.table_index_local);
    try self.body.block(self.allocator);
    try self.body.loop(self.allocator);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Const(self.allocator, @intCast(pattern.variable_count));
    try self.body.opcode(self.allocator, 0x4f); // i32.ge_u
    try self.body.ifVoid(self.allocator);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Const(self.allocator, @intCast(origin));
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.i32Const(self.allocator, @intCast(tvalue_size));
    try self.body.opcode(self.allocator, 0x6c); // i32.mul
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.i32Const(self.allocator, lua_tag_nil);
    try self.body.i32Store(self.allocator, 2, tvalue_tag_offset);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.localSet(self.allocator, self.table_index_local);
    try self.body.branch(self.allocator, 0);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}
fn emitAdvanceIteratorIndex(self: anytype) Error!void {
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.localSet(self.allocator, self.call_func_local);
}
fn emitStoreIteratorCursor(self: anytype, base: u32) Error!void {
    const cursor_slot = slotField(base, 2, 0);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Store(self.allocator, 2, cursor_slot);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, lu_tag_iterator);
    try self.body.i32Store(self.allocator, 2, cursor_slot + abi.tvalue_extra_offset);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, @intCast(lua_tag_lightuserdata));
    try self.body.i32Store(self.allocator, 2, cursor_slot + tvalue_tag_offset);
}
fn emitStoreNumberKey(self: anytype, base: u32) Error!void {
    const key_slot = slotField(base, 3, 0);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.opcode(self.allocator, 0xb7); // f64.convert_i32_s
    try self.body.f64Store(self.allocator, 3, key_slot);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, @intCast(lua_tag_number));
    try self.body.i32Store(self.allocator, 2, key_slot + tvalue_tag_offset);
}
fn emitStoreCopiedValue(self: anytype, base: u32, source_offset: u32) Error!void {
    const value_slot = slotField(base, 4, 0);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i64Load(self.allocator, 3, source_offset);
    try self.body.i64Store(self.allocator, 3, value_slot);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i64Load(self.allocator, 3, source_offset + 8);
    try self.body.i64Store(self.allocator, 3, value_slot + 8);
}
fn emitStoreNodeKey(self: anytype, base: u32) Error!void {
    // getnodekey copies the key value, its extra word, and the 4-bit tag. The chain link stays put.
    const key_slot = slotField(base, 3, 0);
    const key_extra = abi.lua_node_key_offset + abi.tvalue_extra_offset;
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i64Load(self.allocator, 3, abi.lua_node_key_offset);
    try self.body.i64Store(self.allocator, 3, key_slot);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load(self.allocator, 2, key_extra);
    try self.body.i32Store(self.allocator, 2, key_slot + abi.tvalue_extra_offset);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load(self.allocator, 2, abi.lua_node_key_tag_offset);
    try self.body.i32Const(self.allocator, abi.lua_node_key_tag_mask);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.i32Store(self.allocator, 2, key_slot + tvalue_tag_offset);
}
fn emitBuiltinArrayScan(self: anytype, base: u32) Error!void {
    try self.body.block(self.allocator);
    try self.body.loop(self.allocator);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.opcode(self.allocator, 0x4f); // i32.ge_u
    try self.body.ifVoid(self.allocator);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Load(self.allocator, 2, abi.table_array_offset);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, @intCast(tvalue_size));
    try self.body.opcode(self.allocator, 0x6c); // i32.mul
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.localSet(self.allocator, self.call_closure_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load(self.allocator, 2, tvalue_tag_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try emitAdvanceIteratorIndex(self);
    try self.body.branch(self.allocator, 1);
    try self.body.end(self.allocator);
    try emitAdvanceIteratorIndex(self);
    try emitStoreIteratorCursor(self, base);
    try emitStoreNumberKey(self, base);
    try emitStoreCopiedValue(self, base, 0);
    try self.body.i32Const(self.allocator, 1);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.branch(self.allocator, 1);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}
fn emitBuiltinHashScan(self: anytype, base: u32) Error!void {
    try self.body.i32Const(self.allocator, 1);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Load8U(self.allocator, 0, abi.table_lsizenode_offset);
    try self.body.opcode(self.allocator, 0x74); // i32.shl
    try self.body.localSet(self.allocator, self.call_meta_local);
    try self.body.block(self.allocator);
    try self.body.loop(self.allocator);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.opcode(self.allocator, 0x6b); // i32.sub
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.opcode(self.allocator, 0x4f); // i32.ge_u
    try self.body.ifVoid(self.allocator);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Load(self.allocator, 2, abi.table_node_offset);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.opcode(self.allocator, 0x6b); // i32.sub
    try self.body.i32Const(self.allocator, @intCast(abi.lua_node_size));
    try self.body.opcode(self.allocator, 0x6c); // i32.mul
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.localSet(self.allocator, self.call_closure_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load(self.allocator, 2, tvalue_tag_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try emitAdvanceIteratorIndex(self);
    try self.body.branch(self.allocator, 1);
    try self.body.end(self.allocator);
    try emitAdvanceIteratorIndex(self);
    try emitStoreIteratorCursor(self, base);
    try emitStoreNodeKey(self, base);
    try emitStoreCopiedValue(self, base, 0);
    try self.body.i32Const(self.allocator, 1);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.branch(self.allocator, 1);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
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
    stay: bool,
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

    // Same callable protocol for every non-nil iterator. The wasm frame install is the taken path
    // when the iterator is a fixed AOT Lua closure; every other shape keeps the helper.
    try self.emitGenericForProtocol(pattern, continuation, stay);
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
        try self.emitGenericIterationFallbackCall(block.finish, pattern, false);
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
    if (!self.rejoin_fallthrough)
        try self.body.branch(self.allocator, self.loop_branch_depth);
}
fn emitConstantArrayAttempt(
    self: anytype,
    operation: model.GenericTableOperation,
    table: u32,
    slot: u32,
    index: u32,
) Error!void {
    const index_i32 = std.math.cast(i32, index) orelse {
        try self.body.i32Const(self.allocator, 0);
        try self.body.localSet(self.allocator, self.status_local);
        return;
    };
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.i32Const(self.allocator, index_i32);
    try self.body.localSet(self.allocator, self.table_index_local);
    try emitInlineArrayHit(self, operation, table, slot);
}

fn emitArrayMiss(self: anytype) Error!void {
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
}

fn emitArrayMissEnd(self: anytype) Error!void {
    try self.body.end(self.allocator);
    // The hit flag shares the status local. A successful guest returns 0.
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.status_local);
}

pub noinline fn emitInlineArrayGet(self: anytype, pattern: model.InlineArrayGetPattern) Error!void {
    try emitConstantArrayAttempt(self, .get, pattern.table, pattern.destination, pattern.index);
    try emitArrayMiss(self);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(pattern.destination));
    try self.body.i32Const(self.allocator, @intCast(pattern.table));
    try self.body.i32Const(self.allocator, @intCast(pattern.index));
    try self.body.call(self.allocator, self.array_get orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
    try emitArrayMissEnd(self);
}

pub noinline fn emitGuardedConstantTableGet(self: anytype, pattern: GenericTablePattern) Error!void {
    const number = pattern.immediate_number_key orelse return emitGenericTableFallbackCall(self, pattern);
    if (number < 1 or number > @as(f64, @floatFromInt(std.math.maxInt(i32))) or @trunc(number) != number)
        return emitGenericTableFallbackCall(self, pattern);
    try emitConstantArrayAttempt(self, .get, pattern.table, pattern.value, @intFromFloat(number));
    try emitArrayMiss(self);
    try emitGenericTableFallbackCall(self, pattern);
    try emitArrayMissEnd(self);
}

pub noinline fn emitArrayOperation(
    self: anytype,
    pattern: ArrayOperationPattern,
    operation: ArrayOperationKind,
) Error!void {
    switch (operation) {
        .set => {
            try emitConstantArrayAttempt(self, .set, pattern.table, pattern.source, pattern.index);
            try emitArrayMiss(self);
            try self.body.localGet(self.allocator, 0);
            try self.body.i32Const(self.allocator, @intCast(pattern.table));
            try self.body.i32Const(self.allocator, @intCast(pattern.source));
            try self.body.i32Const(self.allocator, @intCast(pattern.index));
            try self.body.call(self.allocator, self.array_set orelse return Error.UnsupportedCommand);
            try self.emitReloadBase();
            try emitArrayMissEnd(self);
        },
        .get => {
            try emitConstantArrayAttempt(self, .get, pattern.table, pattern.destination, pattern.index);
            try emitArrayMiss(self);
            try self.body.localGet(self.allocator, 0);
            try self.body.i32Const(self.allocator, @intCast(pattern.destination));
            try self.body.i32Const(self.allocator, @intCast(pattern.table));
            try self.body.i32Const(self.allocator, @intCast(pattern.index));
            try self.body.call(self.allocator, self.array_get orelse return Error.UnsupportedCommand);
            try self.emitReloadBase();
            try emitArrayMissEnd(self);
        },
        .len => {
            try self.emitPlainTableLen(pattern.destination, pattern.table);
            try self.publishLengthSlot(pattern.start + 5, pattern.destination);
        },
    }
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
    try self.publishEscapedSlotNodes(pattern.start, block.finish);
    try self.emitStringTableOperation(pattern);
}
pub noinline fn emitStringTableOperation(self: anytype, pattern: StringTablePattern) Error!void {
    try self.emitStringTableHelper(pattern);
    try self.emitDispatchRejoin(pattern.rejoin);
}
pub noinline fn emitStringTableHelper(self: anytype, pattern: StringTablePattern) Error!void {
    // The fused helper replaces both the optimized literal slot probe and its semantic
    // fallback. Publish the fallback bytecode location before entering luaV_gettable/settable
    // so receiver, key, readonly, and metamethod errors retain Luau's exact source boundary.
    try self.emitPcLocation(pattern.pc);
    switch (pattern.operation) {
        .set => try tables.emitStringSlotSetOrHelper(self, pattern.table, pattern.value, pattern.key, pattern.key_constant),
        .get => try tables.emitStringKeyGet(self, pattern.value, pattern.table, pattern.key, pattern.key_constant),
    }
}
pub noinline fn emitGlobalOperationBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock, pattern: GlobalPattern) Error!void {
    _ = block_id;
    if (pattern.start > block.start) {
        if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
            return;
    }
    try self.publishEscapedSlotNodes(pattern.start, block.finish);
    try self.emitGlobalOperation(pattern);
    if (!self.rejoin_fallthrough)
        try self.body.branch(self.allocator, self.loop_branch_depth);
}
pub noinline fn emitGlobalOperation(self: anytype, pattern: GlobalPattern) Error!void {
    const key = try self.string_keys.intern(self.allocator, pattern.key);
    // The fallback's bytecode pc is consumed here solely to publish the decoded source line.
    // The runtime ABI receives only the already-decoded register and literal key bytes.
    try self.emitPcLocation(pattern.pc);
    if (pattern.operation == .get) {
        try tables.emitInlineEnvGet(self, pattern.value, pattern.key_constant);
        try self.body.localGet(self.allocator, self.call_proto_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try emitGlobalLookup(self, pattern, key.offset, key.length);
        try self.body.end(self.allocator);
    } else {
        try emitGlobalLookup(self, pattern, key.offset, key.length);
    }
    try self.body.i32Const(self.allocator, @intCast(pattern.rejoin));
    try self.body.localSet(self.allocator, self.dispatch_local);
}

fn emitGlobalLookup(
    self: anytype,
    pattern: GlobalPattern,
    key_offset: u32,
    key_length: u32,
) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(pattern.value));
    try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(key_offset));
    try self.body.i32Const(self.allocator, @intCast(key_length));
    try self.body.call(self.allocator, switch (pattern.operation) {
        .get => self.get_global orelse return Error.UnsupportedCommand,
        .set => self.set_global orelse return Error.UnsupportedCommand,
    });
    try self.emitReloadBase();
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
fn publishedNumberStore(self: anytype, register: u32, consumer: u32) Error!?u32 {
    const block_id = self.plan.instructionBlock(consumer) orelse return null;
    const block = try self.snapshot.irBlock(self.function, block_id);
    if (!block.kind.isCompilable() or consumer < block.start or consumer > block.finish)
        return null;
    var payload: ?u32 = null;
    var instruction_id = block.start;
    while (instruction_id < consumer) : (instruction_id += 1) {
        if (!try self.instructionWritesRegister(instruction_id, register))
            continue;
        const instruction_value = try self.instruction(instruction_id);
        if (instruction_value.command == .store_double and instruction_value.operand_count == 2) {
            const destination = try self.operand(instruction_value, 0);
            if (destination.kind == .vm_reg and destination.value == register)
                payload = instruction_id
            else
                payload = null;
        } else if (instruction_value.command != .store_tag)
            payload = null;
    }
    const published = payload orelse return null;
    if (published + 1 >= consumer)
        return null;
    const tag_store = try self.instruction(published + 1);
    if (tag_store.command != .store_tag or tag_store.operand_count != 2)
        return null;
    const tag_destination = try self.operand(tag_store, 0);
    const tag = try self.operand(tag_store, 1);
    if (tag_destination.kind != .vm_reg or tag_destination.value != register or tag.kind != .constant or
        (try self.constant(tag.value)).tagValue() != lua_tag_number)
        return null;
    if (!try self.preservesRegisterToConsumer(register, published + 1, consumer))
        return null;
    return published;
}

// A fresh NEW_TABLE covers a numeric store when its recorded array size contains the key.
// The key and the value are numbers already published in this block. The table register
// still holds that allocation. The caller still checks the live sizearray before writing.
fn coveredFreshNumericStore(self: anytype, pattern: GenericTablePattern) Error!bool {
    const key_register = pattern.register_key orelse return false;
    var covered: ?u32 = null;
    for (self.plan.facts.table_allocs) |candidate| {
        if (candidate.dest_reg != pattern.table or candidate.finish >= pattern.start)
            continue;
        if (covered == null or candidate.start > covered.?)
            covered = candidate.start;
    }
    const allocation_start = covered orelse return false;
    const allocation = self.plan.tableAllocAt(allocation_start) orelse return false;
    if (allocation.array_count == 0 or allocation.destination != pattern.table)
        return false;
    var cursor = allocation.finish + 1;
    while (cursor < pattern.start) : (cursor += 1) {
        if (try self.instructionWritesRegister(cursor, pattern.table))
            return false;
    }
    const published = (try publishedNumberStore(self, key_register, pattern.start)) orelse return false;
    const stored = try self.operand(try self.instruction(published), 1);
    if (stored.kind != .constant)
        return false;
    const number = (try self.constant(stored.value)).doubleValue() orelse return false;
    if (!std.math.isFinite(number) or @trunc(number) != number or number < 1 or
        number > @as(f64, @floatFromInt(allocation.array_count)))
        return false;
    return (try publishedNumberStore(self, pattern.value, pattern.start)) != null;
}

fn emitUnprovedNumericTableSet(
    self: anytype,
    pattern: GenericTablePattern,
    key: snapshot_v1.IrOperand,
) Error!void {
    // table_set_number owns growth, deletion, and the metamethod boundary. The f64 is the
    // number payload; a non-number key never reaches this call.
    const key_offset = try self.vmRegisterOffset(key, 0);
    try self.emitSavedPcLocation(pattern.marker);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(pattern.table));
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.f64Load(self.allocator, 3, key_offset);
    try self.body.i32Const(self.allocator, @intCast(pattern.value));
    try self.body.call(self.allocator, self.table_set_number orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
    try self.body.i32Const(self.allocator, 1);
    try self.body.localSet(self.allocator, self.status_local);
}

pub noinline fn emitGenericTableDirectAttempt(self: anytype, pattern: GenericTablePattern) Error!void {
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.status_local);

    const register_key = pattern.register_key orelse return;
    const key = snapshot_v1.IrOperand{ .kind = .vm_reg, .value = register_key };
    // An unproved numeric store has no recorded slot. The bounds probe would miss, then
    // table_set would repeat the same numeric checks. Call the numeric helper once instead.
    if (pattern.operation == .set and !try coveredFreshNumericStore(self, pattern)) {
        try self.emitTValueTag(key);
        try self.body.i32Const(self.allocator, lua_tag_number);
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        try emitUnprovedNumericTableSet(self, pattern, key);
        try self.body.end(self.allocator);
    } else {
        try self.emitTValueTag(key);
        try self.body.i32Const(self.allocator, lua_tag_number);
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);

        // TRY_NUM_TO_INDEX is an exact signed-i32 conversion: truncate without trapping, convert
        // back to f64, and admit only values whose round trip is numerically equal. NaN and values
        // outside the signed-i32 range keep status 0 and use table_set/table_get.
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

        // The index local is still the converted key. A hit overwrites it with the slot address.
        // emitInlineArrayHit keeps the live sizearray check and refuses a write past the array.
        try emitInlineArrayHit(self, pattern.operation, pattern.table, pattern.value);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
    }
    if (pattern.operation == .get) {
        try self.emitTValueTag(key);
        try self.body.i32Const(self.allocator, lua_tag_string);
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        try tables.emitInlineRegisterStringGet(self, pattern.value, pattern.table, register_key);
        try self.body.localGet(self.allocator, self.call_proto_local);
        try self.body.ifVoid(self.allocator);
        try self.body.i32Const(self.allocator, 1);
        try self.body.localSet(self.allocator, self.status_local);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
    }
    if (pattern.operation == .set) {
        // A completed numeric store owns the key. Existing string keys update in place.
        // A missing key or a hash growth stays on table_set.
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.emitTValueTag(key);
        try self.body.i32Const(self.allocator, lua_tag_string);
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        try tables.emitInlineRegisterStringSet(self, pattern.table, pattern.value, register_key);
        try self.body.localGet(self.allocator, self.call_proto_local);
        try self.body.ifVoid(self.allocator);
        try self.body.i32Const(self.allocator, 1);
        try self.body.localSet(self.allocator, self.status_local);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
    }
}
fn emitAddressBelowTop(self: anytype, register_offset: u32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, @intCast(register_offset));
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_top_offset);
    try self.body.opcode(self.allocator, 0x49); // i32.lt_u
}
fn emitLoadedTableField(self: anytype, table_offset: u32, field: u32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, table_offset);
    try self.body.i32Load(self.allocator, 2, field);
}
fn emitLoadedTableByte(self: anytype, table_offset: u32, field: u32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, table_offset);
    try self.body.i32Load8U(self.allocator, 0, field);
}
fn emitPositiveArrayIndex(self: anytype, table_offset: u32) Error!void {
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.i32Eqz(self.allocator);
    try self.body.localGet(self.allocator, self.table_index_local);
    try emitLoadedTableField(self, table_offset, abi.table_sizearray_offset);
    try self.body.opcode(self.allocator, 0x4d); // i32.le_u
    try self.body.opcode(self.allocator, 0x71); // i32.and
}
fn emitArraySlot(self: anytype, table_offset: u32) Error!void {
    try emitLoadedTableField(self, table_offset, abi.table_array_offset);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, 0x6b); // i32.sub
    try self.body.i32Const(self.allocator, @intCast(tvalue_size));
    try self.body.opcode(self.allocator, 0x6c); // i32.mul
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.localSet(self.allocator, self.table_index_local);
}
fn emitCopyRegisterToSlot(self: anytype, register_offset: u32) Error!void {
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i64Load(self.allocator, 3, register_offset);
    try self.body.i64Store(self.allocator, 3, 0);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i64Load(self.allocator, 3, register_offset + 8);
    try self.body.i64Store(self.allocator, 3, 8);
}
fn emitCopySlotToRegister(self: anytype, register_offset: u32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i64Load(self.allocator, 3, 0);
    try self.body.i64Store(self.allocator, 3, register_offset);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i64Load(self.allocator, 3, 8);
    try self.body.i64Store(self.allocator, 3, register_offset + 8);
}
fn emitInlineArrayHit(
    self: anytype,
    operation: model.GenericTableOperation,
    table_register: u32,
    slot_register: u32,
) Error!void {
    // Misses leave status 0. The caller then uses table_set/table_get for growth,
    // metamethods, and errors. A hit copies one 16-byte TValue, the same bytes setobj copies.
    // table_index_local is the one-based index on entry and the slot address after a bounds hit.
    const barrier = if (operation == .set) self.barrier_table_forward else null;
    const table = snapshot_v1.IrOperand{ .kind = .vm_reg, .value = table_register };
    const slot = snapshot_v1.IrOperand{ .kind = .vm_reg, .value = slot_register };
    const table_offset = try self.vmRegisterOffset(table, 0);
    const slot_offset = try self.vmRegisterOffset(slot, 0);

    try emitAddressBelowTop(self, table_offset);
    try emitAddressBelowTop(self, slot_offset);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.ifVoid(self.allocator);
    try self.emitTValueTag(table);
    try self.body.i32Const(self.allocator, lua_tag_table);
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try emitLoadedTableField(self, table_offset, abi.table_metatable_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    switch (operation) {
        .set => {
            try emitLoadedTableByte(self, table_offset, abi.table_readonly_offset);
            try self.body.i32Eqz(self.allocator);
            try self.body.ifVoid(self.allocator);
            try emitPositiveArrayIndex(self, table_offset);
            try self.body.ifVoid(self.allocator);
            try emitArraySlot(self, table_offset);
            try emitCopyRegisterToSlot(self, slot_offset);
            // luaC_barriert is a no-op below LUA_TSTRING. Numbers skip the helper.
            // The barrier can move the stack, so reload base before the next register use.
            if (barrier) |barrier_fn| {
                try self.emitTValueTag(slot);
                try self.body.i32Const(self.allocator, @intCast(lua_tag_string));
                try self.body.opcode(self.allocator, 0x4e); // i32.ge_s
                try self.body.ifVoid(self.allocator);
                try self.body.localGet(self.allocator, 0);
                try self.body.localGet(self.allocator, self.base_local);
                try self.body.i32Load(self.allocator, 2, table_offset);
                try self.body.i32Const(self.allocator, @intCast(slot_register));
                try self.body.call(self.allocator, barrier_fn);
                try self.emitReloadBase();
                try self.body.end(self.allocator);
            }
            try self.body.i32Const(self.allocator, 1);
            try self.body.localSet(self.allocator, self.status_local);
            try self.body.end(self.allocator);
            try self.body.end(self.allocator);
        },
        .get => {
            try emitPositiveArrayIndex(self, table_offset);
            try self.body.ifVoid(self.allocator);
            try emitArraySlot(self, table_offset);
            try emitCopySlotToRegister(self, slot_offset);
            try self.body.i32Const(self.allocator, 1);
            try self.body.localSet(self.allocator, self.status_local);
            try self.body.end(self.allocator);
        },
    }
    try self.body.end(self.allocator);
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
    try self.emitDispatchRejoin(pattern.rejoin);
}
pub noinline fn emitInlineGenericTableSet(self: anytype, pattern: GenericTablePattern) Error!void {
    try self.emitGenericTableDirectAttempt(pattern);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.emitGenericTableFallbackCall(pattern);
    try self.body.end(self.allocator);
}

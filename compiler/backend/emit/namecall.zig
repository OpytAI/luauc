const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");

const upstreamStringHash = model.upstreamStringHash;
const Error = model.Error;
const TableAllocationPattern = model.TableAllocationPattern;
const PlainTableNamecallPattern = model.PlainTableNamecallPattern;
const ConcatPattern = model.ConcatPattern;
const UserdataAllocationPattern = model.UserdataAllocationPattern;
const ir_cmd_get_slot_node_addr = abi.ir_cmd_get_slot_node_addr;
const ir_cmd_get_hash_node_addr = abi.ir_cmd_get_hash_node_addr;
const ir_cmd_try_call_fastgettm = abi.ir_cmd_try_call_fastgettm;
const ir_cmd_concat = abi.ir_cmd_concat;
const ir_cmd_check_slot_match = abi.ir_cmd_check_slot_match;
const ir_cmd_check_node_no_next = abi.ir_cmd_check_node_no_next;
const ir_cmd_fallback_namecall = abi.ir_cmd_fallback_namecall;
const ir_cmd_jump_slot_match = abi.ir_cmd_jump_slot_match;
const lua_tag_table = abi.lua_tag_table;

pub fn blockReferenceCount(self: anytype, target: u32) Error!u32 {
    return self.plan.blockReferences(target) orelse Error.UnsupportedControlFlow;
}
pub noinline fn plainTableNamecallPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?PlainTableNamecallPattern {
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
pub noinline fn isBypassedPlainTableNamecallBlock(self: anytype, block_id: u32) Error!bool {
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
pub noinline fn emitPlainTableNamecallBlock(
    self: anytype,
    block_id: u32,
    block: snapshot_v1.IrBlock,
    pattern: PlainTableNamecallPattern,
) Error!void {
    try self.body.localGet(self.allocator, self.dispatch_local);
    try self.body.i32Const(self.allocator, @intCast(block_id));
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    if (pattern.start > block.start) {
        if (try self.emitInstructionRange(block.start, pattern.start - 1, block)) {
            try self.body.end(self.allocator);
            return;
        }
    }
    try self.emitPlainTableNamecallOperation(pattern);
    try self.body.branch(self.allocator, 1);
    try self.body.end(self.allocator);
}
pub noinline fn emitFallbackNamecall(
    self: anytype,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    try self.requireOperandCount(instruction_value, 4);
    const pc_operand = try self.operand(instruction_value, 0);
    if (pc_operand.kind != .constant)
        return Error.InvalidOperandType;
    const pc = (try self.constant(pc_operand.value)).uintValue() orelse return Error.InvalidOperandType;
    const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
    const source = try self.vmRegisterIndex(try self.operand(instruction_value, 2));
    const key_bytes = (try self.stringKey(try self.operand(instruction_value, 3))) orelse
        return Error.InvalidOperandType;
    const key = try self.string_keys.intern(self.allocator, key_bytes);
    try self.emitPcLocation(pc);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(destination));
    try self.body.i32Const(self.allocator, @intCast(source));
    try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(key.offset));
    try self.body.i32Const(self.allocator, @intCast(key.length));
    try self.body.call(self.allocator, self.namecall_plain orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
}
pub noinline fn emitPlainTableNamecallOperation(self: anytype, pattern: PlainTableNamecallPattern) Error!void {
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
pub noinline fn tableAllocationPatternContaining(self: anytype, instruction_id: u32) Error!?TableAllocationPattern {
    var back: u32 = 0;
    while (back <= 3 and back <= instruction_id) : (back += 1) {
        if (try self.tableAllocationPatternAt(instruction_id - back)) |pattern| {
            if (instruction_id <= pattern.finish)
                return pattern;
        }
    }
    return null;
}
pub noinline fn emitTableAllocation(self: anytype, pattern: TableAllocationPattern) Error!void {
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
pub noinline fn emitUserdataAllocationInstruction(
    self: anytype,
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
    if (self.userdataWriteWidth(instruction_value.command) != null) {
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
pub noinline fn emitSetList(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
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
pub fn commandRangeMatches(self: anytype, start: u32, commands: []const snapshot_v1.IrCommand) Error!bool {
    if (start > self.function.instruction_count -| @as(u32, @intCast(commands.len)))
        return false;
    for (commands, 0..) |command, offset| {
        if ((try self.instruction(start + @as(u32, @intCast(offset)))).command != command)
            return false;
    }
    return true;
}
pub noinline fn concatPatternAt(self: anytype, start: u32) Error!?ConcatPattern {
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
pub noinline fn concatPatternContaining(self: anytype, instruction_id: u32) Error!?ConcatPattern {
    var distance: u32 = 0;
    while (distance < 5 and distance <= instruction_id) : (distance += 1) {
        if (try self.concatPatternAt(instruction_id - distance)) |pattern| {
            if (instruction_id <= pattern.finish)
                return pattern;
        }
    }
    return null;
}
pub noinline fn emitConcat(self: anytype, pattern: ConcatPattern) Error!void {
    try self.emitSavedPcLocation(try self.instruction(pattern.start));
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(pattern.destination));
    try self.body.i32Const(self.allocator, @intCast(pattern.source));
    try self.body.i32Const(self.allocator, @intCast(pattern.count));
    try self.body.call(self.allocator, self.concat orelse return Error.UnsupportedCommand);
    // Concatenation publishes the result and runs its ordinary GC boundary in the runtime helper.
    try self.emitReloadBase();
}

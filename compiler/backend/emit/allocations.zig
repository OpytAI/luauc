const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");
const recognize = @import("luauc_backend_recognize");

const Error = model.Error;
const TableAllocationPattern = model.TableAllocationPattern;
const DupTablePattern = model.DupTablePattern;
const ConstantLoadPattern = model.ConstantLoadPattern;
const ConstantTruthyFallbackPattern = model.ConstantTruthyFallbackPattern;
const LiteralFieldSetPattern = model.LiteralFieldSetPattern;
const TableInsertAppendPattern = model.TableInsertAppendPattern;
const UserdataAllocationPattern = model.UserdataAllocationPattern;
const ir_cmd_table_len = abi.ir_cmd_table_len;
const ir_cmd_get_slot_node_addr = abi.ir_cmd_get_slot_node_addr;
const ir_cmd_new_table = abi.ir_cmd_new_table;
const ir_cmd_new_userdata = abi.ir_cmd_new_userdata;
const ir_cmd_dup_table = abi.ir_cmd_dup_table;
const ir_cmd_table_setnum = abi.ir_cmd_table_setnum;
const ir_cmd_check_readonly = abi.ir_cmd_check_readonly;
const ir_cmd_check_slot_match = abi.ir_cmd_check_slot_match;
const ir_cmd_barrier_table_forward = abi.ir_cmd_barrier_table_forward;
const ir_cmd_buffer_writei8 = abi.ir_cmd_buffer_writei8;
const ir_cmd_buffer_writei16 = abi.ir_cmd_buffer_writei16;
const ir_cmd_buffer_writei32 = abi.ir_cmd_buffer_writei32;
const ir_cmd_buffer_writef32 = abi.ir_cmd_buffer_writef32;
const ir_cmd_buffer_writef64 = abi.ir_cmd_buffer_writef64;
const ir_cmd_buffer_writei64 = abi.ir_cmd_buffer_writei64;
const tvalue_size = abi.tvalue_size;
const tvalue_tag_offset = abi.tvalue_tag_offset;
const lua_tag_nil = abi.lua_tag_nil;
const lua_tag_boolean = abi.lua_tag_boolean;
const lua_tag_number = abi.lua_tag_number;
const lua_tag_integer = abi.lua_tag_integer;
const lua_tag_vector = abi.lua_tag_vector;
const lua_tag_string = abi.lua_tag_string;
const lua_tag_table = abi.lua_tag_table;
const lua_tag_userdata = abi.lua_tag_userdata;
const lua_utag_limit = abi.lua_utag_limit;
const lop_call = abi.lop_call;
const lop_fastcall2k = abi.lop_fastcall2k;

pub noinline fn tableAllocationPatternAt(self: anytype, start: u32) Error!?TableAllocationPattern {
    return recognize.tableAllocationAt(self.snapshot, self.function, self.proto, self.plan.instruction_blocks, start);
}
pub fn isDeferredTableInitializationCommand(_: anytype, command: snapshot_v1.IrCommand) bool {
    return recognize.isDeferredTableInitializationCommand(command);
}
pub fn userdataWriteWidth(_: anytype, command: snapshot_v1.IrCommand) ?u32 {
    return if (command == ir_cmd_buffer_writei8)
        1
    else if (command == ir_cmd_buffer_writei16)
        2
    else if (command == ir_cmd_buffer_writei32 or command == ir_cmd_buffer_writef32)
        4
    else if (command == ir_cmd_buffer_writef64 or command == ir_cmd_buffer_writei64)
        8
    else
        null;
}
pub noinline fn userdataAllocationPatternAt(self: anytype, start: u32) Error!?UserdataAllocationPattern {
    if (start + 3 >= self.function.instruction_count)
        return null;
    const check_gc = try self.instruction(start);
    const allocation = try self.instruction(start + 1);
    if (check_gc.command != .check_gc or check_gc.operand_count != 0 or
        allocation.command != ir_cmd_new_userdata or allocation.operand_count != 2)
        return null;

    const byte_size = self.uintConstant(try self.operand(allocation, 0)) catch return null;
    const user_tag = self.uintConstant(try self.operand(allocation, 1)) catch return null;
    if (user_tag >= lua_utag_limit)
        return null;
    var cursor = start + 2;
    while (cursor < self.function.instruction_count) : (cursor += 1) {
        const candidate = try self.instruction(cursor);
        if (self.userdataWriteWidth(candidate.command)) |width| {
            if (candidate.operand_count != 4)
                return null;
            const pointer = try self.operand(candidate, 0);
            const offset = self.uintConstant(try self.operand(candidate, 1)) catch return null;
            const tag = try self.operand(candidate, 3);
            if (pointer.kind != .instruction or pointer.value != start + 1 or
                tag.kind != .constant or (try self.constant(tag.value)).tagValue() != lua_tag_userdata or
                offset > byte_size or width > byte_size - offset)
                return null;
            continue;
        }
        if (candidate.command != .store_pointer or candidate.operand_count != 2 or
            cursor + 1 >= self.function.instruction_count)
            return null;
        const store_tag = try self.instruction(cursor + 1);
        if (store_tag.command != .store_tag or store_tag.operand_count != 2)
            return null;
        const destination = try self.operand(candidate, 0);
        const pointer = try self.operand(candidate, 1);
        const tag_destination = try self.operand(store_tag, 0);
        const tag = try self.operand(store_tag, 1);
        if (destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
            pointer.kind != .instruction or pointer.value != start + 1 or
            tag_destination.kind != .vm_reg or tag_destination.value != destination.value or
            tag.kind != .constant or (try self.constant(tag.value)).tagValue() != lua_tag_userdata)
            return null;
        self.requireSingleCompilableBlockRange(start, cursor + 1) catch return null;
        return .{
            .start = start,
            .allocation = start + 1,
            .finish = cursor + 1,
            .destination = destination.value,
            .byte_size = byte_size,
            .user_tag = user_tag,
        };
    }
    return null;
}
pub noinline fn userdataAllocationPatternContaining(self: anytype, instruction_id: u32) Error!?UserdataAllocationPattern {
    var cursor = instruction_id + 1;
    while (cursor != 0) {
        cursor -= 1;
        const candidate = try self.instruction(cursor);
        if (candidate.command != .check_gc)
            continue;
        if (try self.userdataAllocationPatternAt(cursor)) |pattern|
            if (instruction_id <= pattern.finish) return pattern;
    }
    return null;
}
pub fn materializedConstantTag(_: anytype, kind: snapshot_v1.VmConstantKind) ?u8 {
    return switch (kind) {
        .nil => @intCast(lua_tag_nil),
        .boolean => @intCast(lua_tag_boolean),
        .number => lua_tag_number,
        .vector => @intCast(lua_tag_vector),
        .string => lua_tag_string,
        .integer => lua_tag_integer,
        .table => lua_tag_table,
        .import, .closure, .class_shape => null,
    };
}
pub noinline fn constantLoadPatternAt(self: anytype, start: u32) Error!?ConstantLoadPattern {
    if (start + 1 >= self.function.instruction_count)
        return null;
    const load = try self.instruction(start);
    const store = try self.instruction(start + 1);
    if (load.command != .load_tvalue or load.operand_count != 3 or
        store.command != .store_tvalue or store.operand_count != 2)
        return null;
    self.requireSingleCallBlockRange(start, start + 1) catch return null;

    const constant_operand = try self.operand(load, 0);
    const offset = try self.operand(load, 1);
    const tag = try self.operand(load, 2);
    const destination = try self.operand(store, 0);
    const stored = try self.operand(store, 1);
    if (constant_operand.kind != .vm_const or constant_operand.value >= self.proto.vm_constant_count or
        !try self.intOperandEquals(offset, 0) or tag.kind != .constant or
        destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
        stored.kind != .instruction or stored.value != start)
        return null;
    const expected_tag = self.materializedConstantTag((try self.snapshot.vmConstant(self.proto, constant_operand.value)).kind) orelse
        return null;
    if ((try self.constant(tag.value)).tagValue() != expected_tag)
        return null;
    return .{
        .start = start,
        .finish = start + 1,
        .destination = destination.value,
        .constant_id = constant_operand.value,
    };
}
pub noinline fn constantLoadPatternContaining(self: anytype, instruction_id: u32) Error!?ConstantLoadPattern {
    if (try self.constantLoadPatternAt(instruction_id)) |pattern|
        return pattern;
    if (instruction_id != 0)
        if (try self.constantLoadPatternAt(instruction_id - 1)) |pattern|
            if (pattern.finish == instruction_id) return pattern;
    return null;
}
pub noinline fn emitConstantLoad(self: anytype, pattern: ConstantLoadPattern) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(pattern.destination));
    try self.body.i32Const(self.allocator, @intCast(pattern.constant_id));
    try self.body.call(self.allocator, self.load_constant orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
}
pub noinline fn constantTruthyFallbackPatternAt(self: anytype, start: u32) Error!?ConstantTruthyFallbackPattern {
    const commands = [_]snapshot_v1.IrCommand{ .load_tvalue, .select_if_truthy, .store_tvalue };
    if (!try self.commandRangeMatches(start, &commands))
        return null;
    const finish = start + @as(u32, @intCast(commands.len - 1));
    self.requireSingleCompilableBlockRange(start, finish) catch return null;

    const load = try self.instruction(start);
    const select = try self.instruction(start + 1);
    const store = try self.instruction(finish);
    if (load.operand_count != 1 or select.operand_count != 3 or store.operand_count != 2 or
        load.use_count != 1)
        return null;
    const constant_operand = try self.operand(load, 0);
    const condition = try self.operand(select, 0);
    const true_value = try self.operand(select, 1);
    const false_value = try self.operand(select, 2);
    const destination = try self.operand(store, 0);
    const stored = try self.operand(store, 1);
    if (constant_operand.kind != .vm_const or constant_operand.value >= self.proto.vm_constant_count or
        self.materializedConstantTag((try self.snapshot.vmConstant(self.proto, constant_operand.value)).kind) == null or
        (true_value.kind != .vm_reg and true_value.kind != .instruction) or
        condition.kind != true_value.kind or condition.value != true_value.value or
        false_value.kind != .instruction or false_value.value != start or
        destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
        stored.kind != .instruction or stored.value != start + 1)
        return null;
    return .{
        .start = start,
        .finish = finish,
        .destination = destination.value,
        .constant_id = constant_operand.value,
        .true_value = true_value,
    };
}
pub noinline fn constantTruthyFallbackPatternContaining(self: anytype, instruction_id: u32) Error!?ConstantTruthyFallbackPattern {
    var distance: u32 = 0;
    while (distance < 3 and distance <= instruction_id) : (distance += 1) {
        if (try self.constantTruthyFallbackPatternAt(instruction_id - distance)) |pattern|
            if (instruction_id <= pattern.finish) return pattern;
    }
    return null;
}
pub noinline fn emitConstantTruthyFallback(self: anytype, pattern: ConstantTruthyFallbackPattern) Error!void {
    try self.emitTValueTruthy(pattern.true_value);
    try self.body.ifVoid(self.allocator);
    try self.emitStoreTValueOperand(pattern.destination, pattern.true_value);
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(pattern.destination));
    try self.body.i32Const(self.allocator, @intCast(pattern.constant_id));
    try self.body.call(self.allocator, self.load_constant orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
    try self.body.end(self.allocator);

    const result_id = pattern.start + 1;
    if (result_id >= self.slots.len or self.slots[result_id].shape != .tvalue)
        return Error.InvalidInstructionResult;
    const published = snapshot_v1.IrOperand{ .kind = .vm_reg, .value = pattern.destination };
    try self.emitTValuePart(published, false);
    try self.body.localSet(self.allocator, self.slots[result_id].first);
    try self.emitTValuePart(published, true);
    try self.body.localSet(self.allocator, self.slots[result_id].second);
}
pub noinline fn dupTablePatternAt(self: anytype, start: u32) Error!?DupTablePattern {
    return recognize.dupTableAt(self.snapshot, self.function, self.proto, self.plan.instruction_blocks, start);
}
pub noinline fn dupTablePatternContaining(self: anytype, instruction_id: u32) Error!?DupTablePattern {
    var distance: u32 = 0;
    while (distance < 5 and distance <= instruction_id) : (distance += 1) {
        if (try self.dupTablePatternAt(instruction_id - distance)) |pattern|
            if (instruction_id <= pattern.finish) return pattern;
    }
    return null;
}
pub noinline fn emitDupTable(self: anytype, pattern: DupTablePattern) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(pattern.destination));
    try self.body.i32Const(self.allocator, @intCast(pattern.constant_id));
    try self.body.call(self.allocator, self.dup_table orelse return Error.UnsupportedCommand);
    if (pattern.assist) {
        try self.body.localGet(self.allocator, 0);
        try self.body.call(self.allocator, self.check_gc orelse return Error.UnsupportedCommand);
    }
    try self.emitReloadBase();
}
pub fn tableRegisterForPointer(self: anytype, pointer_id: u32) Error!?u32 {
    const pointer = try self.instruction(pointer_id);
    if (pointer.command == .load_pointer and pointer.operand_count == 1) {
        const source = try self.operand(pointer, 0);
        if (source.kind != .vm_reg)
            return null;
        return try self.vmRegisterIndex(source);
    }
    if (pointer.command == ir_cmd_dup_table and pointer_id != 0) {
        const clone = (try self.dupTablePatternAt(pointer_id - 1)) orelse return null;
        if (clone.start + 1 != pointer_id)
            return null;
        return clone.destination;
    }
    return null;
}
pub fn dupTableRegisterForPointer(self: anytype, pointer_id: u32) Error!?u32 {
    const pointer = try self.instruction(pointer_id);
    if (pointer.command == ir_cmd_dup_table and pointer_id != 0) {
        const clone = (try self.dupTablePatternAt(pointer_id - 1)) orelse return null;
        return clone.destination;
    }
    if (pointer.command != .load_pointer or pointer.operand_count != 1)
        return null;
    const source = try self.operand(pointer, 0);
    if (source.kind != .vm_reg or source.value >= self.proto.max_stack_size)
        return null;

    var cursor = pointer_id;
    while (cursor != 0) {
        cursor -= 1;
        const candidate = try self.instruction(cursor);
        if (candidate.command != .store_pointer or candidate.operand_count != 2)
            continue;
        const destination = try self.operand(candidate, 0);
        if (destination.kind != .vm_reg or destination.value != source.value)
            continue;
        if (cursor != 0)
            if (try self.tableAllocationPatternAt(cursor - 1)) |pattern|
                if (pattern.start + 1 == cursor and pattern.destination == source.value)
                    return pattern.destination;
        if (cursor < 2)
            return null;
        const clone = (try self.dupTablePatternAt(cursor - 2)) orelse return null;
        if (clone.start + 2 != cursor or clone.destination != source.value)
            return null;
        return clone.destination;
    }
    return null;
}
fn rootedCollectablePointerRegister(
    self: anytype,
    pointer: snapshot_v1.IrOperand,
    expected_tag: u8,
    consumer_id: u32,
) Error!?u32 {
    if (expected_tag < lua_tag_string or expected_tag > 12 or
        pointer.kind != .instruction or pointer.value >= consumer_id)
        return null;

    if (try self.loadedPointerRegister(pointer)) |register| {
        if (try self.preservesRegisterToConsumer(register, pointer.value, consumer_id))
            return register;
        return null;
    }

    if (pointer.value + 2 >= consumer_id)
        return null;
    const publication = try self.instruction(pointer.value + 1);
    const tag_publication = try self.instruction(pointer.value + 2);
    if (publication.command != .store_pointer or publication.operand_count != 2 or
        tag_publication.command != .store_tag or tag_publication.operand_count != 2)
        return null;
    const destination = try self.operand(publication, 0);
    const published_pointer = try self.operand(publication, 1);
    const tag_destination = try self.operand(tag_publication, 0);
    const published_tag = try self.operand(tag_publication, 1);
    if (destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
        published_pointer.kind != .instruction or published_pointer.value != pointer.value or
        tag_destination.kind != .vm_reg or tag_destination.value != destination.value or
        published_tag.kind != .constant or
        (try self.constant(published_tag.value)).tagValue() != expected_tag or
        !try self.preservesRegisterToConsumer(destination.value, pointer.value + 2, consumer_id))
        return null;
    return destination.value;
}
pub noinline fn literalFieldSetPatternAt(self: anytype, start: u32) Error!?LiteralFieldSetPattern {
    if (start + 4 >= self.function.instruction_count)
        return null;
    const slot = try self.instruction(start);
    const match = try self.instruction(start + 1);
    const readonly = try self.instruction(start + 2);
    if (slot.command != ir_cmd_get_slot_node_addr or slot.operand_count != 3 or
        match.command != ir_cmd_check_slot_match or match.operand_count != 3 or
        ((readonly.command != ir_cmd_check_readonly or readonly.operand_count != 2) and
            (readonly.command != .nop or readonly.operand_count != 0)))
        return null;

    const pointer = try self.operand(slot, 0);
    const pc = try self.operand(slot, 1);
    const key_operand = try self.operand(slot, 2);
    const matched_slot = try self.operand(match, 0);
    const matched_key = try self.operand(match, 1);
    const fallback = try self.operand(match, 2);
    if (pointer.kind != .instruction or pointer.value >= start or pc.kind != .constant or
        key_operand.kind != .vm_const or matched_slot.kind != .instruction or matched_slot.value != start or
        matched_key.kind != .vm_const or matched_key.value != key_operand.value or fallback.kind != .block)
        return null;
    const readonly_elided = readonly.command == .nop;
    if (!readonly_elided) {
        const readonly_pointer = try self.operand(readonly, 0);
        const readonly_fallback = try self.operand(readonly, 1);
        if (readonly_pointer.kind != .instruction or readonly_pointer.value != pointer.value or
            readonly_fallback.kind != .block or readonly_fallback.value != fallback.value)
            return null;
    }
    const table = (try self.tableRegisterForPointer(pointer.value)) orelse return null;
    const key = (try self.stringKey(key_operand)) orelse return null;
    const pc_value = (try self.constant(pc.value)).uintValue() orelse return null;

    var store_id = start + 3;
    if ((try self.instruction(store_id)).command == .nop) {
        if ((try self.instruction(store_id)).operand_count != 0)
            return null;
        store_id += 1;
    }
    if (store_id < self.function.instruction_count and
        (try self.instruction(store_id)).command == .load_tvalue)
        store_id += 1;
    if (store_id >= self.function.instruction_count)
        return null;
    const store = try self.instruction(store_id);
    if (store.command == .store_tvalue) {
        if (store_id + 1 >= self.function.instruction_count or store.operand_count != 3)
            return null;
        const suffix = try self.instruction(store_id + 1);
        const destination = try self.operand(store, 0);
        const stored = try self.operand(store, 1);
        const offset = try self.operand(store, 2);
        if (destination.kind != .instruction or destination.value != start or
            stored.kind != .instruction or !try self.intOperandEquals(offset, 0))
            return null;

        if (suffix.command == .nop and suffix.operand_count == 0) {
            const load = try self.instruction(stored.value);
            if (load.command != .load_tvalue or load.operand_count != 3)
                return null;
            const source = try self.operand(load, 0);
            const load_offset = try self.operand(load, 1);
            const known_tag = try self.operand(load, 2);
            if (source.kind != .vm_reg or source.value >= self.proto.max_stack_size or
                !try self.intOperandEquals(load_offset, 0) or known_tag.kind != .constant or
                ((try self.constant(known_tag.value)).tagValue() orelse return null) >= lua_tag_string)
                return null;
            self.requireSingleCompilableBlockRange(start, store_id + 1) catch return null;
            if ((try self.stringFallbackRejoin(fallback.value, .set, pc_value, source.value, table, key_operand.value)) == null)
                return null;
            return .{ .start = start, .finish = store_id + 1, .pc = pc_value, .table = table, .value = source.value, .key = key };
        }

        if (suffix.command != ir_cmd_barrier_table_forward or suffix.operand_count != 3)
            return null;
        const barrier_pointer = try self.operand(suffix, 0);
        const value = try self.operand(suffix, 1);
        const barrier_tag = try self.operand(suffix, 2);
        if (barrier_pointer.kind != .instruction or barrier_pointer.value != pointer.value or
            value.kind != .vm_reg or value.value >= self.proto.max_stack_size)
            return null;
        if (barrier_tag.kind == .undef) {
            const load = try self.instruction(stored.value);
            if (load.command != .load_tvalue or load.operand_count != 1)
                return null;
            const source = try self.operand(load, 0);
            if (source.kind != .vm_reg or source.value != value.value)
                return null;
            self.requireSingleCompilableBlockRange(start, store_id + 1) catch return null;
            if ((try self.stringFallbackRejoin(fallback.value, .set, pc_value, value.value, table, key_operand.value)) == null)
                return null;
            return .{
                .start = start,
                .finish = store_id + 1,
                .pc = pc_value,
                .table = table,
                .value = value.value,
                .key = key,
            };
        }
        if (barrier_tag.kind != .constant or (try self.constant(barrier_tag.value)).tagValue() != lua_tag_string or
            stored.value + 1 >= start)
            return null;
        const publication = try self.instruction(stored.value + 1);
        if (publication.command != .store_tvalue or publication.operand_count != 2 or
            (try self.operand(publication, 0)).kind != .vm_reg or
            (try self.operand(publication, 0)).value != value.value or
            (try self.operand(publication, 1)).kind != .instruction or
            (try self.operand(publication, 1)).value != stored.value or
            try self.constantLoadPatternAt(stored.value) == null)
            return null;
        self.requireSingleCompilableBlockRange(start, store_id + 1) catch return null;
        if ((try self.stringFallbackRejoin(fallback.value, .set, pc_value, value.value, table, key_operand.value)) == null)
            return null;
        return .{ .start = start, .finish = store_id + 1, .pc = pc_value, .table = table, .value = value.value, .key = key };
    }
    if (store.command != .store_split_tvalue or store.operand_count != 4 or
        store_id + 1 >= self.function.instruction_count or start < 2)
        return null;
    const suffix = try self.instruction(store_id + 1);
    const destination = try self.operand(store, 0);
    const tag = try self.operand(store, 1);
    const value = try self.operand(store, 2);
    const offset = try self.operand(store, 3);
    if (destination.kind != .instruction or destination.value != start or
        tag.kind != .constant or !try self.intOperandEquals(offset, 0))
        return null;
    const tag_value = (try self.constant(tag.value)).tagValue() orelse return null;
    if (tag_value >= lua_tag_string and tag_value <= 12) {
        if (suffix.command != ir_cmd_barrier_table_forward or suffix.operand_count != 3 or
            value.kind != .instruction)
            return null;
        const value_register = (try rootedCollectablePointerRegister(self, value, tag_value, store_id)) orelse return null;
        if ((try self.operand(suffix, 0)).kind != .instruction or
            (try self.operand(suffix, 0)).value != pointer.value or
            (try self.operand(suffix, 1)).kind != .vm_reg or
            (try self.operand(suffix, 1)).value != value_register or
            (try self.operand(suffix, 2)).kind != .constant or
            (try self.constant((try self.operand(suffix, 2)).value)).tagValue() != tag_value)
            return null;
        self.requireSingleCompilableBlockRange(start, store_id + 1) catch return null;
        if ((try self.stringFallbackRejoin(fallback.value, .set, pc_value, value_register, table, key_operand.value)) == null)
            return null;
        return .{ .start = start, .finish = store_id + 1, .pc = pc_value, .table = table, .value = value_register, .key = key };
    }
    if (tag_value == lua_tag_number and value.kind == .instruction) {
        if (suffix.command != .nop or suffix.operand_count != 0)
            return null;
        const owner = (try self.compilableOwnerBlock(start)) orelse return null;
        const source = (try self.publishedNumberPayloadRegister(owner, value, store_id)) orelse return null;
        if ((try self.stringFallbackRejoin(fallback.value, .set, pc_value, source, table, key_operand.value)) == null)
            return null;
        return .{
            .start = start,
            .finish = store_id + 1,
            .pc = pc_value,
            .table = table,
            .value = source,
            .materialized_tag = lua_tag_number,
            .key = key,
        };
    }
    if (suffix.command != .nop or suffix.operand_count != 0 or value.kind != .constant)
        return null;
    if (tag_value != lua_tag_number and tag_value != lua_tag_boolean)
        return null;

    const value_command: snapshot_v1.IrCommand = if (tag_value == lua_tag_number) .store_double else .store_int;
    var value_store_id: ?u32 = null;
    if (start >= 5 and (try self.instruction(start - 5)).command == value_command and
        (try self.instruction(start - 4)).command == .store_tag)
        value_store_id = start - 5;
    if (value_store_id == null and (try self.instruction(start - 2)).command == value_command and
        (try self.instruction(start - 1)).command == .store_tag)
        value_store_id = start - 2;
    const publication_id = value_store_id orelse return null;
    const value_store = try self.instruction(publication_id);
    const tag_store = try self.instruction(publication_id + 1);
    if (value_store.operand_count != 2 or tag_store.operand_count != 2)
        return null;
    if (publication_id + 5 == start) {
        const guard0 = try self.instruction(publication_id + 2);
        const guard1 = try self.instruction(publication_id + 3);
        const guard2 = try self.instruction(publication_id + 4);
        const optimized = guard0.command == .nop and guard0.operand_count == 0 and
            guard1.command == .nop and guard1.operand_count == 0 and
            guard2.command == .nop and guard2.operand_count == 0;
        if (!optimized) {
            if (guard0.command != .load_tag or guard0.operand_count != 1 or
                guard1.command != .check_tag or guard1.operand_count != 3 or
                guard2.command != .load_pointer or guard2.operand_count != 1)
                return null;
            const guarded_table = try self.operand(guard0, 0);
            const checked_tag = try self.operand(guard1, 0);
            const required_tag = try self.operand(guard1, 1);
            const exit = try self.operand(guard1, 2);
            const loaded_table = try self.operand(guard2, 0);
            if (guarded_table.kind != .vm_reg or guarded_table.value != table or
                checked_tag.kind != .instruction or checked_tag.value != publication_id + 2 or
                required_tag.kind != .constant or (try self.constant(required_tag.value)).tagValue() != lua_tag_table or
                ((exit.kind != .vm_exit) and (exit.kind != .block or exit.value != fallback.value)) or
                loaded_table.kind != .vm_reg or loaded_table.value != table or
                pointer.value != publication_id + 4)
                return null;
        }
    }
    const value_destination = try self.operand(value_store, 0);
    const tag_destination = try self.operand(tag_store, 0);
    const stored_value = try self.operand(value_store, 1);
    const stored_tag = try self.operand(tag_store, 1);
    if (value_destination.kind != .vm_reg or value_destination.value >= self.proto.max_stack_size or
        tag_destination.kind != .vm_reg or tag_destination.value != value_destination.value or
        stored_value.kind != .constant or stored_value.value != value.value or
        stored_tag.kind != .constant or stored_tag.value != tag.value)
        return null;
    self.requireSingleCompilableBlockRange(publication_id, store_id + 1) catch return null;
    if ((try self.stringFallbackRejoin(fallback.value, .set, pc_value, value_destination.value, table, key_operand.value)) == null)
        return null;
    return .{ .start = start, .finish = store_id + 1, .pc = pc_value, .table = table, .value = value_destination.value, .key = key };
}
pub noinline fn literalFieldSetPatternContaining(self: anytype, instruction_id: u32) Error!?LiteralFieldSetPattern {
    var distance: u32 = 0;
    while (distance < 7 and distance <= instruction_id) : (distance += 1) {
        const start = instruction_id - distance;
        if ((try self.instruction(start)).command == ir_cmd_get_slot_node_addr)
            if (try self.literalFieldSetPatternAt(start)) |pattern|
                if (instruction_id <= pattern.finish) return pattern;
    }
    return null;
}
pub noinline fn guardedLiteralFieldSetPatternAt(self: anytype, start: u32) Error!?LiteralFieldSetPattern {
    if (start + 3 >= self.function.instruction_count)
        return null;
    const load_tag = try self.instruction(start);
    const check_tag = try self.instruction(start + 1);
    const load_pointer = try self.instruction(start + 2);
    if (load_tag.command != .load_tag or load_tag.operand_count != 1 or
        check_tag.command != .check_tag or check_tag.operand_count != 3 or
        load_pointer.command != .load_pointer or load_pointer.operand_count != 1 or
        (try self.instruction(start + 3)).command != ir_cmd_get_slot_node_addr)
        return null;

    const pattern = (try self.literalFieldSetPatternAt(start + 3)) orelse return null;
    const table = try self.operand(load_tag, 0);
    const checked = try self.operand(check_tag, 0);
    const tag = try self.operand(check_tag, 1);
    const guard_fallback = try self.operand(check_tag, 2);
    const pointer_table = try self.operand(load_pointer, 0);
    const slot = try self.instruction(pattern.start);
    const match = try self.instruction(pattern.start + 1);
    const slot_pointer = try self.operand(slot, 0);
    const semantic_fallback = try self.operand(match, 2);
    if (table.kind != .vm_reg or table.value != pattern.table or
        checked.kind != .instruction or checked.value != start or
        tag.kind != .constant or (try self.constant(tag.value)).tagValue() != lua_tag_table or
        guard_fallback.kind != .block or semantic_fallback.kind != .block or
        guard_fallback.value != semantic_fallback.value or
        pointer_table.kind != .vm_reg or pointer_table.value != table.value or
        slot_pointer.kind != .instruction or slot_pointer.value != start + 2)
        return null;
    self.requireSingleCompilableBlockRange(start, pattern.finish) catch return null;
    return pattern;
}
pub noinline fn emitLiteralFieldSet(self: anytype, pattern: LiteralFieldSetPattern) Error!void {
    const key = try self.string_keys.intern(self.allocator, pattern.key);
    try self.emitPcLocation(pattern.pc);
    if (pattern.materialized_tag) |tag| {
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Const(self.allocator, tag);
        try self.body.i32Store(self.allocator, 2, pattern.value * tvalue_size + tvalue_tag_offset);
    }
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(pattern.table));
    try self.body.i32Const(self.allocator, @intCast(pattern.value));
    try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(key.offset));
    try self.body.i32Const(self.allocator, @intCast(key.length));
    try self.body.call(self.allocator, self.table_set_string orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
}
pub noinline fn tableInsertAppendPatternAt(self: anytype, cluster_start: u32) Error!?TableInsertAppendPattern {
    const dynamic_commands = [_]snapshot_v1.IrCommand{
        ir_cmd_table_len, .add_int, ir_cmd_table_setnum, .load_tvalue, .store_tvalue, ir_cmd_barrier_table_forward,
    };
    const number_commands = [_]snapshot_v1.IrCommand{
        ir_cmd_table_len, .add_int, ir_cmd_table_setnum, .store_double, .store_tag,
    };
    const dynamic = try self.commandRangeMatches(cluster_start, &dynamic_commands);
    const number = !dynamic and try self.commandRangeMatches(cluster_start, &number_commands);
    if (!dynamic and !number)
        return null;
    const command_count = if (dynamic) dynamic_commands.len else number_commands.len;
    const finish = cluster_start + @as(u32, @intCast(command_count - 1));
    var start = cluster_start;
    if (cluster_start != 0 and (try self.instruction(cluster_start - 1)).command == ir_cmd_check_readonly)
        start = cluster_start - 1;
    self.requireSingleCompilableBlockRange(start, finish) catch return null;

    const length = try self.instruction(cluster_start);
    const increment = try self.instruction(cluster_start + 1);
    const destination = try self.instruction(cluster_start + 2);
    if (length.operand_count != 1 or increment.operand_count != 2 or destination.operand_count != 2)
        return null;

    const length_pointer = try self.operand(length, 0);
    if (length_pointer.kind != .instruction or length_pointer.value >= cluster_start)
        return null;
    const table_register = (try self.tableRegisterForPointer(length_pointer.value)) orelse return null;
    const increment_lhs = try self.operand(increment, 0);
    const setnum_pointer = try self.operand(destination, 0);
    const setnum_key = try self.operand(destination, 1);
    if (increment_lhs.kind != .instruction or increment_lhs.value != cluster_start or
        !try self.intOperandEquals(try self.operand(increment, 1), 1) or
        setnum_pointer.kind != .instruction or setnum_pointer.value != length_pointer.value or
        setnum_key.kind != .instruction or setnum_key.value != cluster_start + 1)
        return null;
    var source: u32 = undefined;
    var constant_number: ?f64 = null;
    if (dynamic) {
        const load = try self.instruction(cluster_start + 3);
        const store = try self.instruction(cluster_start + 4);
        const barrier = try self.instruction(finish);
        if (load.operand_count != 1 or store.operand_count != 2 or barrier.operand_count != 3)
            return null;
        const source_operand = try self.operand(load, 0);
        const store_destination = try self.operand(store, 0);
        const store_source = try self.operand(store, 1);
        const barrier_pointer = try self.operand(barrier, 0);
        const barrier_source = try self.operand(barrier, 1);
        const barrier_tag = try self.operand(barrier, 2);
        if (source_operand.kind != .vm_reg or
            store_destination.kind != .instruction or store_destination.value != cluster_start + 2 or
            store_source.kind != .instruction or store_source.value != cluster_start + 3 or
            barrier_pointer.kind != .instruction or barrier_pointer.value != length_pointer.value or
            barrier_source.kind != .vm_reg or barrier_source.value != source_operand.value or barrier_tag.kind != .undef)
            return null;
        source = try self.vmRegisterIndex(source_operand);
    } else {
        const store = try self.instruction(cluster_start + 3);
        const store_tag = try self.instruction(cluster_start + 4);
        if (store.operand_count != 2 or store_tag.operand_count != 2)
            return null;
        const store_destination = try self.operand(store, 0);
        const stored = try self.operand(store, 1);
        const tag_destination = try self.operand(store_tag, 0);
        const tag = try self.operand(store_tag, 1);
        if (store_destination.kind != .instruction or store_destination.value != cluster_start + 2 or
            !self.sameOperand(store_destination, tag_destination) or stored.kind != .constant or tag.kind != .constant or
            (try self.constant(tag.value)).tagValue() != lua_tag_number)
            return null;
        constant_number = (try self.constant(stored.value)).doubleValue() orelse return null;
    }
    if (start != cluster_start) {
        const readonly = try self.instruction(start);
        if (readonly.operand_count != 2 or
            (try self.operand(readonly, 0)).kind != .instruction or
            (try self.operand(readonly, 0)).value != length_pointer.value)
            return null;
        const failure = try self.operand(readonly, 1);
        if (!try self.guardFailureIsBuiltin(failure, "table", "insert"))
            return null;
        if (number) {
            if (failure.kind == .block) {
                const fallback_block = (try self.guardFailureBlock(failure)) orelse return null;
                const call = try self.instruction(fallback_block.finish - 1);
                const function_register = self.vmRegisterIndex(try self.operand(call, 0)) catch return null;
                if ((self.intConstant(try self.operand(call, 1)) catch return null) != 2 or
                    (self.intConstant(try self.operand(call, 2)) catch return null) != 0)
                    return null;
                source = std.math.add(u32, function_register, 2) catch return null;
            } else {
                if (failure.value < 2)
                    return null;
                const fast_pc = failure.value - 2;
                const fast_word = try self.snapshot.bytecodeWord(self.proto, fast_pc);
                if (@as(u8, @truncate(fast_word)) != lop_fastcall2k or
                    ((fast_word >> 8) & 0xff) != 52 or ((fast_word >> 16) & 0xff) != table_register)
                    return null;
                const call_pc = std.math.add(u32, fast_pc, ((fast_word >> 24) & 0xff) + 1) catch return null;
                if (call_pc >= self.proto.code_count)
                    return null;
                const call_word = try self.snapshot.bytecodeWord(self.proto, call_pc);
                if (@as(u8, @truncate(call_word)) != lop_call or ((call_word >> 16) & 0xff) != 3)
                    return null;
                source = ((call_word >> 8) & 0xff) + 2;
            }
            if (source >= self.proto.max_stack_size)
                return null;
        }
    } else if (number) {
        return null;
    }
    return .{
        .start = start,
        .finish = finish,
        .table = table_register,
        .source = source,
        .constant_number = constant_number,
    };
}
pub noinline fn tableInsertAppendPatternContaining(self: anytype, instruction_id: u32) Error!?TableInsertAppendPattern {
    if ((try self.instruction(instruction_id)).command == ir_cmd_check_readonly and
        instruction_id + 1 < self.function.instruction_count)
        if (try self.tableInsertAppendPatternAt(instruction_id + 1)) |pattern|
            if (pattern.start == instruction_id) return pattern;
    var distance: u32 = 0;
    while (distance < 7 and distance <= instruction_id) : (distance += 1) {
        const candidate = instruction_id - distance;
        if ((try self.instruction(candidate)).command == ir_cmd_table_len)
            if (try self.tableInsertAppendPatternAt(candidate)) |pattern|
                if (instruction_id <= pattern.finish) return pattern;
    }
    return null;
}
pub noinline fn emitTableInsertAppend(self: anytype, pattern: TableInsertAppendPattern) Error!void {
    if (pattern.constant_number) |value| {
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.f64Const(self.allocator, value);
        try self.body.f64Store(self.allocator, 3, pattern.source * tvalue_size);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Const(self.allocator, lua_tag_number);
        try self.body.i32Store(self.allocator, 2, pattern.source * tvalue_size + tvalue_tag_offset);
    }
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(pattern.table));
    try self.body.i32Const(self.allocator, @intCast(pattern.source));
    try self.body.call(self.allocator, self.table_insert_append orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
}

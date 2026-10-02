//! General value, array-address, and table semantic IR lowering.

const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");
const diagnostics = @import("luauc_backend_diagnostics");

const Error = model.Error;
const tvalue_size = abi.tvalue_size;

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

fn hookSetTableKind(
    self: anytype,
    instruction_id: u32,
    value_reg: u32,
    table_reg: u32,
    key: snapshot_v1.IrOperand,
) Error!?enum { hold, store } {
    if (!self.plan.tableAllocHasDest(value_reg))
        return null;
    const index = (try immediateNumber(self, key)) orelse return null;
    if (index != 0 and index != 1)
        return null;
    var userdata_reg: ?u32 = null;
    var saw_table_tag = false;
    var cursor = instruction_id -| 12;
    while (cursor < instruction_id) : (cursor += 1) {
        const instruction = try self.instruction(cursor);
        if (instruction.command == abi.ir_cmd_check_userdata_tag and instruction.operand_count >= 1) {
            if ((try self.loadedPointerRegister(try self.operand(instruction, 0)))) |owner|
                userdata_reg = owner;
        }
        if (instruction.command == .check_tag and instruction.operand_count >= 2) {
            const expected = try self.operand(instruction, 1);
            if (expected.kind == .constant and (try self.constant(expected.value)).tagValue() == abi.lua_tag_table)
                saw_table_tag = true;
        }
    }
    const owner = userdata_reg orelse return null;
    if (index == 0 and owner == table_reg)
        return .hold;
    if (index == 1 and owner != table_reg and saw_table_tag)
        return .store;
    return null;
}


pub noinline fn emitTryNumberToIndex(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const source = try self.operand(instruction_value, 0);
    const failure = try self.operand(instruction_value, 1);

    try self.emitInvalidSignedConversion(source, -2147483648.0, 2147483648.0);
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, std.math.minInt(i32));
    try self.emitInstructionResultSet(instruction_id);
    try self.body.else_(self.allocator);
    try self.emitF64Value(source);
    try self.body.opcode(self.allocator, 0xaa); // i32.trunc_f64_s
    try self.emitInstructionResultSet(instruction_id);
    try self.body.end(self.allocator);

    // Native continues for NaN with INT_MIN, but rejects every other non-integral roundtrip.
    try self.emitF64Value(source);
    try self.emitF64Value(source);
    try self.body.f64Eq(self.allocator);
    try self.body.localGet(self.allocator, self.slots[instruction_id].first);
    try self.body.opcode(self.allocator, 0xb7); // f64.convert_i32_s
    try self.emitF64Value(source);
    try self.body.f64Ne(self.allocator);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.emitGuardFailure(failure);
}

pub noinline fn emitGetArrayAddress(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const table = try self.operand(instruction_value, 0);
    const fresh = if (table.kind == .instruction)
        try self.freshTableRegister(table.value)
    else
        null;
    const proved = table.kind == .instruction and self.plan.isProvenTablePointer(table.value);
    const guarded = self.plan.isGuardedArrayAddress(instruction_id);
    // A killed size check leaves a proved address unguarded. A register whose
    // tag check was deleted stays unproved, and the size check that remains is
    // the bounds gate. The load still rejects an index outside that guard.
    if (!guarded and fresh == null and !proved) {
        diagnostics.trace("arr unguarded");
        return Error.UnsupportedControlFlow;
    }

    if (fresh) |register| {
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Load(self.allocator, 2, register * tvalue_size);
    } else {
        try self.emitPointerValue(table);
    }
    try self.body.i32Load(self.allocator, 2, abi.table_array_offset);
    try self.emitI32Value(try self.operand(instruction_value, 1));
    try self.body.i32Const(self.allocator, @intCast(abi.tvalue_size));
    try self.body.opcode(self.allocator, 0x6c); // i32.mul
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.emitInstructionResultSet(instruction_id);
}

/// A linearized block can reload a fresh table without repeating `CHECK_TAG`.
/// The register stays a table when this function allocated it and no later store replaced it.
pub fn preservedFreshTablePointer(self: anytype, pointer: snapshot_v1.IrOperand, consumer_id: u32) Error!bool {
    const register = (try self.loadedPointerRegister(pointer)) orelse return false;
    var producer: ?u32 = null;
    var cursor: u32 = 0;
    while (cursor < consumer_id) : (cursor += 1) {
        const instruction_value = try self.instruction(cursor);
        if (instruction_value.command != .store_tag or instruction_value.operand_count != 2 or cursor == 0)
            continue;
        const destination = try self.operand(instruction_value, 0);
        const tag = try self.operand(instruction_value, 1);
        if (destination.kind != .vm_reg or destination.value != register or tag.kind != .constant or
            (try self.constant(tag.value)).tagValue() != abi.lua_tag_table)
            continue;
        const publication = try self.instruction(cursor - 1);
        if (publication.command != .store_pointer or publication.operand_count != 2)
            continue;
        const published_destination = try self.operand(publication, 0);
        const published_source = try self.operand(publication, 1);
        if (published_destination.kind != .vm_reg or published_destination.value != register or
            published_source.kind != .instruction)
            continue;
        const allocation = (try self.tableAllocationPatternAt(published_source.value)) orelse continue;
        if (allocation.start != published_source.value or allocation.destination != register)
            continue;
        producer = cursor;
    }
    const published = producer orelse return false;
    if (try self.preservesRegisterToConsumer(register, published, consumer_id))
        return true;
    // The publication can sit several unique-predecessor hops before a
    // linearized reload. One hop is the direct case above.
    const origin = self.plan.instructionBlock(published) orelse return false;
    var block_id = self.plan.instructionBlock(consumer_id) orelse return false;
    var seen: u32 = 0;
    while (block_id != origin) {
        seen += 1;
        if (seen > 8)
            return false;
        const block = try self.snapshot.irBlock(self.function, block_id);
        if (!block.kind.isCompilable() or block.isEmpty())
            return false;
        var instruction_id = block.start;
        while (instruction_id <= block.finish and instruction_id < consumer_id) : (instruction_id += 1) {
            if (instruction_id > published and try self.instructionWritesRegister(instruction_id, register))
                return false;
        }
        const predecessors = self.plan.predecessorSlice(block_id) orelse return false;
        if (predecessors.len != 1)
            return false;
        block_id = predecessors[0];
    }
    const origin_block = try self.snapshot.irBlock(self.function, origin);
    var tail = published + 1;
    while (tail <= origin_block.finish and tail < consumer_id) : (tail += 1)
        if (try self.instructionWritesRegister(tail, register))
            return false;
    return true;
}

fn layoutTablePointer(self: anytype, table: snapshot_v1.IrOperand, instruction_id: u32) Error!bool {
    if (table.kind != .instruction)
        return false;
    if (self.plan.isProvenTablePointer(table.value))
        return true;
    if (try preservedFreshTablePointer(self, table, instruction_id))
        return true;
    if (try self.dupTableRegisterForPointer(table.value)) |_|
        return true;
    const producer = try self.instruction(table.value);
    // A killed CHECK_TAG leaves the fast-path size check on a pointer the frontend
    // already proved was a table. The guard still branches to the fallback.
    if (producer.command == .load_pointer and producer.operand_count == 1) {
        const source = try self.operand(producer, 0);
        if (source.kind == .vm_reg)
            return true;
        if (source.kind == .vm_const)
            return (try self.snapshot.vmConstant(self.proto, source.value)).kind == .table;
    }
    return producer.command == abi.ir_cmd_new_table or producer.command == abi.ir_cmd_dup_table;
}

pub noinline fn emitTableLayoutGuard(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    if (instruction_value.command == abi.ir_cmd_check_no_metatable) {
        try self.requireOperandCount(instruction_value, 2);
        const table = try self.operand(instruction_value, 0);
        if (!try layoutTablePointer(self, table, instruction_id))
            return Error.UnsupportedControlFlow;
        try self.emitPointerValue(table);
        try self.body.i32Load(self.allocator, 2, abi.table_metatable_offset);
        try self.body.i32Eqz(self.allocator);
        try self.body.i32Eqz(self.allocator);
        try self.emitGuardFailure(try self.operand(instruction_value, 1));
        return;
    }

    if (instruction_value.command != abi.ir_cmd_check_array_size)
        return Error.UnsupportedCommand;
    try self.requireOperandCount(instruction_value, 3);
    const table = try self.operand(instruction_value, 0);
    if (!try layoutTablePointer(self, table, instruction_id)) {
        const producer_cmd: u32 = if (table.kind == .instruction)
            @intFromEnum((self.instruction(table.value) catch return Error.UnsupportedControlFlow).command)
        else
            0;
        var detail: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&detail, "arrsz k{d} c{d}", .{
            @intFromEnum(table.kind),
            producer_cmd,
        }) catch "arrsz";
        diagnostics.trace(text);
        return Error.UnsupportedControlFlow;
    }
    try self.emitPointerValue(table);
    try self.body.i32Load(self.allocator, 2, abi.table_sizearray_offset);
    try self.emitI32Value(try self.operand(instruction_value, 1));
    try self.body.opcode(self.allocator, 0x4d); // i32.le_u
    try self.emitGuardFailure(try self.operand(instruction_value, 2));
}

pub noinline fn emitForwardTableBarrier(
    self: anytype,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    const table = try self.operand(instruction_value, 0);
    const source = try self.operand(instruction_value, 1);
    const known_tag = try self.operand(instruction_value, 2);
    const fresh = if (table.kind == .instruction)
        try self.freshTableRegister(table.value)
    else
        null;
    // A collector check clears the planner's type guard. The register publication remains a table.
    var proved = table.kind == .instruction and self.plan.isProvenTablePointer(table.value);
    if (!proved and fresh == null and table.kind == .instruction)
        proved = (try self.dupTableRegisterForPointer(table.value)) != null;
    // Const-prop deletes CHECK_TAG and leaves the barrier on the register load.
    if (!proved and fresh == null and table.kind == .instruction) {
        const producer = try self.instruction(table.value);
        if (producer.command == .load_pointer and producer.operand_count == 1) {
            const loaded = try self.operand(producer, 0);
            if (loaded.kind == .vm_reg)
                proved = true;
            if (loaded.kind == .vm_const)
                proved = (try self.snapshot.vmConstant(self.proto, loaded.value)).kind == .table;
        }
    }
    if ((fresh == null and !proved) or
        source.kind != .vm_reg or source.value >= self.proto.max_stack_size or
        (known_tag.kind != .undef and known_tag.kind != .constant))
    {
        const producer_cmd: u32 = if (table.kind == .instruction)
            @intFromEnum((self.instruction(table.value) catch return Error.UnsupportedControlFlow).command)
        else
            0;
        var detail: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&detail, "bar k{d} c{d} s{d} t{d}", .{
            @intFromEnum(table.kind),
            producer_cmd,
            @intFromEnum(source.kind),
            @intFromEnum(known_tag.kind),
        }) catch "bar";
        diagnostics.trace(text);
        return Error.UnsupportedControlFlow;
    }
    if (known_tag.kind == .constant and (try self.constant(known_tag.value)).tagValue() == null)
        return Error.InvalidOperandType;

    // luaC_barriert is a no-op unless the value is collectable, the table is black, and the value is white.
    const known_collectable: ?bool = if (known_tag.kind == .constant)
        (try self.constant(known_tag.value)).tagValue().? >= abi.lua_tag_string
    else
        null;
    if (known_collectable == false)
        return;
    if (known_collectable == null) {
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Load(self.allocator, 2, source.value * tvalue_size + abi.tvalue_tag_offset);
        try self.body.i32Const(self.allocator, abi.lua_tag_string);
        try self.body.opcode(self.allocator, 0x4e); // i32.ge_s
        try self.body.ifVoid(self.allocator);
        try emitForwardBarrierWhenMarked(self, table, fresh, source.value);
        try self.body.end(self.allocator);
        return;
    }
    try emitForwardBarrierWhenMarked(self, table, fresh, source.value);
}

fn emitForwardBarrierTable(self: anytype, table: snapshot_v1.IrOperand, fresh: ?u32) Error!void {
    if (fresh) |register| {
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Load(self.allocator, 2, register * tvalue_size);
    } else {
        try self.emitPointerValue(table);
    }
}

fn emitForwardBarrierWhenMarked(self: anytype, table: snapshot_v1.IrOperand, fresh: ?u32, source_reg: u32) Error!void {
    try emitForwardBarrierTable(self, table, fresh);
    try self.body.i32Load8U(self.allocator, 0, abi.lua_state_marked_offset);
    try self.body.i32Const(self.allocator, abi.lua_black_bit);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, source_reg * tvalue_size);
    try self.body.i32Load8U(self.allocator, 0, abi.lua_state_marked_offset);
    try self.body.i32Const(self.allocator, abi.lua_white_bits);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, 0);
    try emitForwardBarrierTable(self, table, fresh);
    try self.body.i32Const(self.allocator, @intCast(source_reg));
    try self.body.call(self.allocator, self.barrier_table_forward orelse return Error.UnsupportedCommand);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}

pub noinline fn emitGeneralTableOperation(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    if ((instruction_value.command != abi.ir_cmd_set_table and
        instruction_value.command != abi.ir_cmd_get_table) or instruction_value.operand_count != 3)
        return Error.UnsupportedCommand;
    const value = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
    const table = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
    const key = try self.operand(instruction_value, 2);
    if (instruction_value.command == abi.ir_cmd_set_table) {
        if (try hookSetTableKind(self, instruction_id, value, table, key)) |kind| switch (kind) {
            .hold => {
                try self.body.localGet(self.allocator, 0);
                try self.body.localGet(self.allocator, self.base_local);
                try self.body.i32Load(self.allocator, 2, table * tvalue_size);
                try self.body.i32Const(self.allocator, @intCast(value));
                try self.body.call(self.allocator, self.set_userdata_metatable orelse return Error.UnsupportedCommand);
                return;
            },
            .store => {
                try self.body.localGet(self.allocator, 0);
                try self.body.i32Const(self.allocator, @intCast(table));
                try self.body.i32Const(self.allocator, 1);
                try self.body.i32Const(self.allocator, @intCast(value));
                try self.body.call(self.allocator, self.table_store orelse return Error.UnsupportedCommand);
                try self.emitReloadBase();
                return;
            },
        };
    }

    try self.body.localGet(self.allocator, 0);
    if (key.kind == .constant) {
        const number = (try immediateNumber(self, key)) orelse return Error.InvalidOperandType;
        if (instruction_value.command == abi.ir_cmd_set_table) {
            try self.body.i32Const(self.allocator, @intCast(table));
            try self.body.f64Const(self.allocator, number);
            try self.body.i32Const(self.allocator, @intCast(value));
            try self.body.call(self.allocator, self.table_set_number orelse return Error.UnsupportedCommand);
        } else {
            try self.body.i32Const(self.allocator, @intCast(value));
            try self.body.i32Const(self.allocator, @intCast(table));
            try self.body.f64Const(self.allocator, number);
            try self.body.call(self.allocator, self.table_get_number orelse return Error.UnsupportedCommand);
        }
    } else {
        const encoded = try self.valueOperandEncoding(key);
        if (instruction_value.command == abi.ir_cmd_set_table) {
            try self.body.i32Const(self.allocator, @intCast(table));
            try self.body.i32Const(self.allocator, @bitCast(encoded));
            try self.body.i32Const(self.allocator, @intCast(value));
            try self.body.call(self.allocator, self.table_set orelse return Error.UnsupportedCommand);
        } else {
            try self.body.i32Const(self.allocator, @intCast(value));
            try self.body.i32Const(self.allocator, @intCast(table));
            try self.body.i32Const(self.allocator, @bitCast(encoded));
            try self.body.call(self.allocator, self.table_get orelse return Error.UnsupportedCommand);
        }
    }
    try self.emitReloadBase();
}

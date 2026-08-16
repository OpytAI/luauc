//! General value, array-address, and table semantic IR lowering.

const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");

const Error = model.Error;

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
    if (!self.plan.isGuardedArrayAddress(instruction_id))
        return Error.UnsupportedControlFlow;
    const table = try self.operand(instruction_value, 0);
    if (table.kind != .instruction or !self.plan.isProvenTablePointer(table.value))
        return Error.UnsupportedControlFlow;

    try self.emitPointerValue(table);
    try self.body.i32Load(self.allocator, 2, abi.table_array_offset);
    try self.emitI32Value(try self.operand(instruction_value, 1));
    try self.body.i32Const(self.allocator, @intCast(abi.tvalue_size));
    try self.body.opcode(self.allocator, 0x6c); // i32.mul
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.emitInstructionResultSet(instruction_id);
}

pub noinline fn emitTableLayoutGuard(
    self: anytype,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    if (instruction_value.command == abi.ir_cmd_check_no_metatable) {
        try self.requireOperandCount(instruction_value, 2);
        const table = try self.operand(instruction_value, 0);
        if (table.kind != .instruction or !self.plan.isProvenTablePointer(table.value))
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
    if (table.kind != .instruction or !self.plan.isProvenTablePointer(table.value))
        return Error.UnsupportedControlFlow;
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
    if (table.kind != .instruction or !self.plan.isProvenTablePointer(table.value) or
        source.kind != .vm_reg or source.value >= self.proto.max_stack_size or
        (known_tag.kind != .undef and known_tag.kind != .constant))
        return Error.UnsupportedControlFlow;
    if (known_tag.kind == .constant and (try self.constant(known_tag.value)).tagValue() == null)
        return Error.InvalidOperandType;

    try self.body.localGet(self.allocator, 0);
    try self.emitPointerValue(table);
    try self.body.i32Const(self.allocator, @intCast(source.value));
    try self.body.call(self.allocator, self.barrier_table_forward orelse return Error.UnsupportedCommand);
}

pub noinline fn emitGeneralTableOperation(
    self: anytype,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    if ((instruction_value.command != abi.ir_cmd_set_table and
        instruction_value.command != abi.ir_cmd_get_table) or instruction_value.operand_count != 3)
        return Error.UnsupportedCommand;
    const value = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
    const table = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
    const key = try self.operand(instruction_value, 2);

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

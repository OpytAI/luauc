//! Scalar loads, stores, arithmetic, vector operations, selections, and comparisons.

const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");

const Error = model.Error;
const ValueSlot = model.ValueSlot;
const Capture = model.Capture;
const status_internal_error = abi.status_internal_error;
const tvalue_tag_offset = abi.tvalue_tag_offset;
const lua_tag_nil = abi.lua_tag_nil;
const lua_tag_boolean = abi.lua_tag_boolean;
const lua_tag_number = abi.lua_tag_number;
const lua_tag_integer = abi.lua_tag_integer;
const lua_tag_vector = abi.lua_tag_vector;
const lua_tag_string = abi.lua_tag_string;
const vector_lane_count = abi.vector_lane_count;
const tvalue_lane_count = abi.tvalue_lane_count;
const round_number_bias = abi.round_number_bias;

pub noinline fn emitStatusReturn(self: anytype, status: i32) Error!void {
    try self.body.i32Const(self.allocator, status);
    try self.body.return_(self.allocator);
}
pub noinline fn emitInstructionResultSet(self: anytype, instruction_id: u32) Error!void {
    if (instruction_id >= self.slots.len or self.slots[instruction_id].shape == .none)
        return Error.InvalidInstructionResult;
    try self.body.localSet(self.allocator, self.slots[instruction_id].first);
}
pub noinline fn emitLoadTag(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const source = try self.operand(instruction_value, 0);
    if (source.kind == .vm_const) {
        try self.body.i32Const(self.allocator, try self.vmConstantTag(source));
    } else {
        try self.emitTValueAddress(source);
        const offset = if (source.kind == .vm_reg)
            try self.vmRegisterOffset(source, tvalue_tag_offset)
        else
            tvalue_tag_offset;
        try self.body.i32Load(self.allocator, 2, offset);
    }
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitLoadI32(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const source = try self.operand(instruction_value, 0);
    if (instruction_value.command == .load_pointer) {
        if (source.kind == .vm_const) {
            try self.body.i32Const(self.allocator, @bitCast(@as(u32, @truncate((try self.vmConstantParts(source)).low))));
        } else {
            try self.emitTValueAddress(source);
            const offset = if (source.kind == .vm_reg) try self.vmRegisterOffset(source, 0) else 0;
            try self.body.i32Load(self.allocator, 2, offset);
        }
    } else {
        if (source.kind != .vm_reg)
            return Error.UnsupportedOperand;
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Load(self.allocator, 2, try self.vmRegisterOffset(source, 0));
    }
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitLoadI64(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const source = try self.operand(instruction_value, 0);
    if (source.kind == .vm_const) {
        try self.body.i64Const(self.allocator, @bitCast((try self.vmConstantParts(source)).low));
    } else {
        try self.emitTValueAddress(source);
        const offset = if (source.kind == .vm_reg) try self.vmRegisterOffset(source, 0) else 0;
        try self.body.i64Load(self.allocator, 3, offset);
    }
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitLoadFloat(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const source = try self.operand(instruction_value, 0);
    const offset_operand = try self.operand(instruction_value, 1);
    if (offset_operand.kind != .constant)
        return Error.InvalidOperandType;
    const offset = (try self.constant(offset_operand.value)).intValue() orelse return Error.InvalidOperandType;
    if (offset < 0 or offset > 8 or @mod(offset, 4) != 0)
        return Error.InvalidOperandType;
    if (source.kind == .vm_const) {
        const parts = try self.vmConstantParts(source);
        const bits: u32 = switch (offset) {
            0 => @truncate(parts.low),
            4 => @truncate(parts.low >> 32),
            8 => @truncate(parts.high),
            else => unreachable,
        };
        try self.body.f32Const(self.allocator, @bitCast(bits));
    } else {
        try self.emitTValueAddress(source);
        const address_offset = if (source.kind == .vm_reg)
            try self.vmRegisterOffset(source, @intCast(offset))
        else
            @as(u32, @intCast(offset));
        try self.body.f32Load(self.allocator, 2, address_offset);
    }
    try self.emitInstructionResultSet(instruction_id);
}
pub fn storesVmRegister(self: anytype, instruction_value: snapshot_v1.IrInstruction, register: u32) Error!bool {
    switch (instruction_value.command) {
        .store_tag,
        .store_extra,
        .store_pointer,
        .store_double,
        .store_int,
        .store_int64,
        .store_vector,
        .store_tvalue,
        .store_split_tvalue,
        => {},
        else => return false,
    }
    if (instruction_value.operand_count == 0)
        return false;
    const destination = try self.operand(instruction_value, 0);
    return destination.kind == .vm_reg and destination.value == register;
}
pub fn classifyBuiltinNumberLoads(self: anytype) Error!void {
    @memset(self.builtin_number_sources, std.math.maxInt(u32));
    if (self.builtin_number == null)
        return;
    var block_id: u32 = 0;
    while (block_id < self.function.block_count) : (block_id += 1) {
        const block = try self.snapshot.irBlock(self.function, block_id);
        if (!block.kind.isCompilable() or block.isEmpty())
            continue;

        var guarded_registers = [_]bool{false} ** 256;
        var instruction_id = block.start;
        while (instruction_id <= block.finish) : (instruction_id += 1) {
            const instruction_value = try self.instruction(instruction_id);
            if (instruction_value.command == .load_double and instruction_value.operand_count == 1) {
                const source = try self.operand(instruction_value, 0);
                if (source.kind == .vm_reg and source.value < guarded_registers.len and
                    guarded_registers[source.value])
                    self.builtin_number_sources[instruction_id] = source.value;
            }

            if (instruction_value.command == .check_tag and instruction_value.operand_count == 3) {
                const checked = try self.operand(instruction_value, 0);
                const expected = try self.operand(instruction_value, 1);
                const failure = try self.operand(instruction_value, 2);
                if (checked.kind == .instruction and expected.kind == .constant and
                    failure.kind == .vm_exit and
                    (try self.constant(expected.value)).tagValue() == lua_tag_number and
                    (try self.builtinFallback(failure.value)) != null)
                {
                    const load_tag = try self.instruction(checked.value);
                    if (load_tag.command == .load_tag and load_tag.operand_count == 1) {
                        const source = try self.operand(load_tag, 0);
                        if (source.kind == .vm_reg and source.value < guarded_registers.len)
                            guarded_registers[source.value] = true;
                    }
                }
            }

            if (instruction_value.command != .load_double and instruction_value.operand_count != 0) {
                const destination = try self.operand(instruction_value, 0);
                if (destination.kind == .vm_reg and destination.value < guarded_registers.len and
                    try self.storesVmRegister(instruction_value, destination.value))
                    guarded_registers[destination.value] = false;
            }
        }
    }
}
pub noinline fn emitLoadDouble(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const source = try self.operand(instruction_value, 0);
    if (source.kind == .vm_const) {
        try self.body.f64Const(self.allocator, @bitCast((try self.vmConstantParts(source)).low));
    } else if (self.builtin_number_sources[instruction_id] != std.math.maxInt(u32)) {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(source.value));
        try self.body.call(self.allocator, self.builtin_number orelse return Error.UnsupportedCommand);
    } else {
        try self.emitTValueAddress(source);
        const offset = if (source.kind == .vm_reg) try self.vmRegisterOffset(source, 0) else 0;
        try self.body.f64Load(self.allocator, 3, offset);
    }
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitLoadTValue(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    if (try self.newClosurePatternContaining(instruction_id) != null)
        return;
    if (instruction_id + 1 < self.function.instruction_count and
        (try self.instruction(instruction_id + 1)).command == .set_upvalue)
        _ = try self.setUpvaluePattern(instruction_id + 1);
    if (instruction_value.operand_count != 1 and instruction_value.operand_count != 2 and
        instruction_value.operand_count != 3)
        return Error.InvalidOperandCount;
    if (instruction_id >= self.slots.len or self.slots[instruction_id].shape != .tvalue)
        return Error.InvalidInstructionResult;
    const source = try self.operand(instruction_value, 0);
    const address_offset = if (instruction_value.operand_count >= 2)
        try self.tvalueByteOffset(instruction_value, 1)
    else
        0;
    if (source.kind == .instruction) {
        const producer = try self.instruction(source.value);
        if (producer.command == abi.ir_cmd_get_hash_node_addr or producer.command == abi.ir_cmd_get_slot_node_addr) {
            if (address_offset != 0 or
                !try self.plan.validateNodeUse(self.snapshot, self.function, source.value, instruction_id))
                return Error.UnsupportedControlFlow;
        }
    }
    if (instruction_value.operand_count == 3) {
        const tag = try self.operand(instruction_value, 2);
        if (tag.kind != .constant or (try self.constant(tag.value)).tagValue() == null)
            return Error.InvalidOperandType;
    }
    if (source.kind != .instruction and address_offset != 0)
        return Error.InvalidOperandType;
    if (source.kind == .vm_const) {
        const parts = try self.vmConstantParts(source);
        try self.body.i64Const(self.allocator, @bitCast(parts.low));
        try self.body.localSet(self.allocator, self.slots[instruction_id].first);
        try self.body.i64Const(self.allocator, @bitCast(parts.high));
        try self.body.localSet(self.allocator, self.slots[instruction_id].second);
        return;
    }
    try self.emitTValueAddress(source);
    const value_offset = if (source.kind == .vm_reg)
        try self.vmRegisterOffset(source, address_offset)
    else
        address_offset;
    try self.body.i64Load(self.allocator, 3, value_offset);
    try self.body.localSet(self.allocator, self.slots[instruction_id].first);
    try self.emitTValueAddress(source);
    try self.body.i64Load(self.allocator, 3, value_offset + 8);
    try self.body.localSet(self.allocator, self.slots[instruction_id].second);
}
pub noinline fn emitStoreTag(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    if (try self.newClosurePatternContaining(instruction_id) != null)
        return;
    try self.requireOperandCount(instruction_value, 2);
    const destination = try self.operand(instruction_value, 0);
    const source = try self.operand(instruction_value, 1);
    if (source.kind != .constant or (try self.constant(source.value)).kind != .tag)
        return Error.InvalidOperandType;
    try self.emitTValueAddress(destination);
    try self.emitI32Value(source);
    const offset = if (destination.kind == .vm_reg)
        try self.vmRegisterOffset(destination, tvalue_tag_offset)
    else
        tvalue_tag_offset;
    try self.body.i32Store(self.allocator, 2, offset);
}
pub noinline fn emitStoreDouble(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const destination = try self.operand(instruction_value, 0);
    try self.emitTValueAddress(destination);
    try self.emitF64Value(try self.operand(instruction_value, 1));
    const offset = if (destination.kind == .vm_reg) try self.vmRegisterOffset(destination, 0) else 0;
    try self.body.f64Store(self.allocator, 3, offset);
}
pub noinline fn emitStoreI32(self: anytype, instruction_value: snapshot_v1.IrInstruction, field_offset: u32) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const destination = try self.operand(instruction_value, 0);
    const source = try self.operand(instruction_value, 1);
    if (instruction_value.command == .store_int) {
        try self.body.localGet(self.allocator, self.base_local);
        try self.emitI32Value(source);
        try self.body.i32Store(self.allocator, 2, try self.vmRegisterOffset(destination, field_offset));
        return;
    }
    try self.emitTValueAddress(destination);
    switch (instruction_value.command) {
        .store_pointer => try self.emitPointerValue(source),
        .store_extra => {
            if (source.kind != .constant or (try self.constant(source.value)).kind != .int)
                return Error.InvalidOperandType;
            try self.emitI32Value(source);
        },
        else => return Error.UnsupportedCommand,
    }
    const offset = if (destination.kind == .vm_reg)
        try self.vmRegisterOffset(destination, field_offset)
    else
        field_offset;
    try self.body.i32Store(self.allocator, 2, offset);
}
pub noinline fn emitStoreI64(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const destination = try self.operand(instruction_value, 0);
    try self.body.localGet(self.allocator, self.base_local);
    try self.emitI64Value(try self.operand(instruction_value, 1));
    try self.body.i64Store(self.allocator, 3, try self.vmRegisterOffset(destination, 0));
}
pub noinline fn emitStoreVector(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    if (instruction_value.operand_count != 4 and instruction_value.operand_count != 5)
        return Error.InvalidOperandCount;
    const destination = try self.operand(instruction_value, 0);
    _ = try self.vmRegisterIndex(destination);
    var lane: u32 = 0;
    while (lane < vector_lane_count) : (lane += 1) {
        try self.body.localGet(self.allocator, self.base_local);
        try self.emitF32Value(try self.operand(instruction_value, lane + 1));
        try self.body.f32Store(self.allocator, 2, try self.vmRegisterOffset(destination, lane * 4));
    }
    if (instruction_value.operand_count == 5) {
        try self.body.localGet(self.allocator, self.base_local);
        try self.emitTagValue(try self.operand(instruction_value, 4));
        try self.body.i32Store(self.allocator, 2, try self.vmRegisterOffset(destination, tvalue_tag_offset));
    }
}
pub noinline fn emitStoreTValue(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    if (try self.newClosurePatternContaining(instruction_id) != null)
        return;
    if (instruction_value.operand_count != 2 and instruction_value.operand_count != 3)
        return Error.InvalidOperandCount;
    const destination = try self.operand(instruction_value, 0);
    const source = try self.operand(instruction_value, 1);
    if (source.kind == .instruction) {
        const source_instruction = try self.instruction(source.value);
        if (source_instruction.command == .get_upvalue) {
            if (source.value + 1 != instruction_id) {
                const first_store = try self.instruction(source.value + 1);
                if (first_store.command != .store_tvalue or first_store.operand_count != 2)
                    return Error.UnsupportedControlFlow;
                const first_source = try self.operand(first_store, 1);
                if (first_source.kind != .instruction or first_source.value != source.value)
                    return Error.UnsupportedControlFlow;
                var gap = source.value + 2;
                while (gap < instruction_id) : (gap += 1) {
                    const marker = try self.instruction(gap);
                    if (marker.command != .nop or marker.operand_count != 0)
                        return Error.UnsupportedControlFlow;
                }
            }
            if (instruction_value.operand_count != 2)
                return Error.UnsupportedControlFlow;
            try self.requireOperandCount(source_instruction, 1);
            const upvalue = try self.operand(source_instruction, 0);
            if (upvalue.kind != .vm_upvalue or upvalue.value >= self.proto.nups)
                return Error.InvalidOperandType;

            try self.body.localGet(self.allocator, 0);
            try self.body.i32Const(self.allocator, @intCast(try self.vmRegisterIndex(destination)));
            try self.body.i32Const(self.allocator, @intCast(upvalue.value));
            try self.body.call(self.allocator, self.get_upvalue orelse return Error.UnsupportedCommand);
            return;
        }
    }
    if (source.kind != .instruction or source.value >= self.slots.len or self.slots[source.value].shape != .tvalue)
        return Error.InvalidOperandType;
    const address_offset = if (instruction_value.operand_count == 3)
        try self.tvalueByteOffset(instruction_value, 2)
    else
        0;
    if (destination.kind != .instruction and address_offset != 0)
        return Error.InvalidOperandType;
    try self.emitTValueAddress(destination);
    const destination_offset = if (destination.kind == .vm_reg)
        try self.vmRegisterOffset(destination, address_offset)
    else
        address_offset;
    try self.body.localGet(self.allocator, self.slots[source.value].first);
    try self.body.i64Store(self.allocator, 3, destination_offset);
    try self.emitTValueAddress(destination);
    try self.body.localGet(self.allocator, self.slots[source.value].second);
    try self.body.i64Store(self.allocator, 3, destination_offset + 8);
}
pub noinline fn emitGetUpvalue(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const upvalue = try self.operand(instruction_value, 0);
    if (upvalue.kind != .vm_upvalue or upvalue.value >= self.proto.nups or
        instruction_id + 1 >= self.function.instruction_count)
        return Error.InvalidOperandType;
    const store = try self.instruction(instruction_id + 1);
    if (store.command != .store_tvalue or store.operand_count != 2)
        return Error.UnsupportedControlFlow;
    const store_source = try self.operand(store, 1);
    if (store_source.kind != .instruction or store_source.value != instruction_id)
        return Error.UnsupportedControlFlow;
}
pub noinline fn emitNewClosure(self: anytype, instruction_id: u32) Error!void {
    const pattern = try self.newClosurePattern(instruction_id);
    const child_id = std.math.add(u32, self.function_id_base, pattern.child_proto_id) catch return Error.ResourceLimit;
    var capture_index: u32 = 0;
    while (capture_index < pattern.capture_count) : (capture_index += 1) {
        const capture = try self.initializedCapture(capture_index, pattern.capture_ir_start);
        try self.emitCaptureCall(pattern.destination, child_id, capture_index, capture, pattern.check_gc and capture_index + 1 == pattern.capture_count);
    }
    try self.emitReloadBase();
}
pub noinline fn emitCaptureCall(self: anytype, destination: u32, child_id: u32, capture_index: u32, capture: Capture, check_gc: bool) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(destination));
    try self.body.i32Const(self.allocator, @intCast(child_id));
    try self.body.i32Const(self.allocator, @intCast(capture_index));
    try self.body.i32Const(self.allocator, @intCast(@intFromEnum(capture.kind)));
    try self.body.i32Const(self.allocator, @intCast(capture.source));
    try self.body.i32Const(self.allocator, @intFromBool(check_gc));
    try self.body.call(self.allocator, self.newclosure_capture orelse return Error.UnsupportedCommand);
}
pub noinline fn emitSetUpvalue(self: anytype, instruction_id: u32) Error!void {
    const pattern = try self.setUpvaluePattern(instruction_id);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(pattern.upvalue_index));
    try self.body.i32Const(self.allocator, @intCast(pattern.source_register));
    try self.body.call(self.allocator, self.set_upvalue orelse return Error.UnsupportedCommand);
}
pub noinline fn emitCloseUpvalues(self: anytype, instruction_id: u32) Error!void {
    const instruction_value = try self.instruction(instruction_id);
    try self.requireOperandCount(instruction_value, 1);
    const source = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(source));
    try self.body.call(self.allocator, self.close_upvalues orelse return Error.UnsupportedCommand);
}
pub noinline fn emitAddNumber(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    try self.emitF64Value(try self.operand(instruction_value, 0));
    try self.emitF64Value(try self.operand(instruction_value, 1));
    try self.body.f64Add(self.allocator);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitUnaryI32(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    try self.emitI32Value(try self.operand(instruction_value, 0));
    try self.body.opcode(self.allocator, opcode);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitUnaryI64(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    try self.emitI64Value(try self.operand(instruction_value, 0));
    try self.body.opcode(self.allocator, opcode);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitUnaryF32(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    try self.emitF32Value(try self.operand(instruction_value, 0));
    try self.body.opcode(self.allocator, opcode);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitUnaryF64(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    try self.emitF64Value(try self.operand(instruction_value, 0));
    try self.body.opcode(self.allocator, opcode);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitBinaryI32(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    try self.emitI32Value(try self.operand(instruction_value, 0));
    try self.emitI32Value(try self.operand(instruction_value, 1));
    try self.body.opcode(self.allocator, opcode);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitBinaryI64(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    try self.emitI64Value(try self.operand(instruction_value, 0));
    try self.emitI64Value(try self.operand(instruction_value, 1));
    try self.body.opcode(self.allocator, opcode);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitInvalidI64DivisionGuard(self: anytype, lhs: snapshot_v1.IrOperand, rhs: snapshot_v1.IrOperand) Error!void {
    try self.emitI64Value(rhs);
    try self.body.opcode(self.allocator, 0x50); // i64.eqz

    try self.emitI64Value(lhs);
    try self.body.i64Const(self.allocator, std.math.minInt(i64));
    try self.body.opcode(self.allocator, 0x51); // i64.eq
    try self.emitI64Value(rhs);
    try self.body.i64Const(self.allocator, -1);
    try self.body.opcode(self.allocator, 0x51); // i64.eq
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.opcode(self.allocator, 0x72); // i32.or

    try self.body.ifVoid(self.allocator);
    // Well-formed upstream IR puts CHECK_DIV_INT64 before signed division. Keep malformed
    // snapshots on the explicit status boundary instead of exposing Wasm's integer trap.
    try self.emitStatusReturn(status_internal_error);
    try self.body.end(self.allocator);
}
pub noinline fn emitZeroI64DivisorGuard(self: anytype, rhs: snapshot_v1.IrOperand) Error!void {
    try self.emitI64Value(rhs);
    try self.body.opcode(self.allocator, 0x50); // i64.eqz
    try self.body.ifVoid(self.allocator);
    // UDIV/UREM and REM/MOD are guarded separately by upstream. Reject malformed streams
    // explicitly so the raw Wasm div/rem instructions below can never trap.
    try self.emitStatusReturn(status_internal_error);
    try self.body.end(self.allocator);
}
pub noinline fn emitSignedDivisionI64(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
    floor_result: bool,
) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const lhs = try self.operand(instruction_value, 0);
    const rhs = try self.operand(instruction_value, 1);
    try self.emitInvalidI64DivisionGuard(lhs, rhs);

    try self.emitI64Value(lhs);
    try self.emitI64Value(rhs);
    try self.body.opcode(self.allocator, 0x7f); // i64.div_s
    try self.emitInstructionResultSet(instruction_id);

    if (floor_result) {
        // Native x64 adjusts a truncating quotient when a non-zero remainder and the divisor
        // have opposite signs. This is the mathematical floor for every guarded input.
        try self.emitI64Value(lhs);
        try self.emitI64Value(rhs);
        try self.body.opcode(self.allocator, 0x81); // i64.rem_s
        try self.body.i64Const(self.allocator, 0);
        try self.body.opcode(self.allocator, 0x52); // i64.ne

        try self.emitI64Value(lhs);
        try self.emitI64Value(rhs);
        try self.body.opcode(self.allocator, 0x81); // i64.rem_s
        try self.emitI64Value(rhs);
        try self.body.opcode(self.allocator, 0x85); // i64.xor
        try self.body.i64Const(self.allocator, 0);
        try self.body.opcode(self.allocator, 0x53); // i64.lt_s
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.ifVoid(self.allocator);
        try self.body.localGet(self.allocator, self.slots[instruction_id].first);
        try self.body.i64Const(self.allocator, 1);
        try self.body.opcode(self.allocator, 0x7d); // i64.sub
        try self.emitInstructionResultSet(instruction_id);
        try self.body.end(self.allocator);
    }
}
pub noinline fn emitUnsignedDivisionI64(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
    remainder: bool,
) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const lhs = try self.operand(instruction_value, 0);
    const rhs = try self.operand(instruction_value, 1);
    try self.emitZeroI64DivisorGuard(rhs);
    try self.emitI64Value(lhs);
    try self.emitI64Value(rhs);
    try self.body.opcode(self.allocator, if (remainder) 0x82 else 0x80); // i64.rem_u / i64.div_u
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitSignedRemainderI64(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
    floor_result: bool,
) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const lhs = try self.operand(instruction_value, 0);
    const rhs = try self.operand(instruction_value, 1);
    try self.emitZeroI64DivisorGuard(rhs);

    // Wasm rem_s traps for INT64_MIN % -1, while both pinned native lowerers define the
    // remainder (and modulus) as zero for that otherwise overflowing quotient.
    try self.emitI64Value(lhs);
    try self.body.i64Const(self.allocator, std.math.minInt(i64));
    try self.body.opcode(self.allocator, 0x51); // i64.eq
    try self.emitI64Value(rhs);
    try self.body.i64Const(self.allocator, -1);
    try self.body.opcode(self.allocator, 0x51); // i64.eq
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.ifVoid(self.allocator);
    try self.body.i64Const(self.allocator, 0);
    try self.emitInstructionResultSet(instruction_id);
    try self.body.else_(self.allocator);
    try self.emitI64Value(lhs);
    try self.emitI64Value(rhs);
    try self.body.opcode(self.allocator, 0x81); // i64.rem_s
    try self.emitInstructionResultSet(instruction_id);

    if (floor_result) {
        // Lua modulus has the divisor's sign: adjust C's truncating remainder only when it is
        // non-zero and its sign differs from the divisor.
        try self.body.localGet(self.allocator, self.slots[instruction_id].first);
        try self.body.i64Const(self.allocator, 0);
        try self.body.opcode(self.allocator, 0x52); // i64.ne
        try self.body.localGet(self.allocator, self.slots[instruction_id].first);
        try self.emitI64Value(rhs);
        try self.body.opcode(self.allocator, 0x85); // i64.xor
        try self.body.i64Const(self.allocator, 0);
        try self.body.opcode(self.allocator, 0x53); // i64.lt_s
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.ifVoid(self.allocator);
        try self.body.localGet(self.allocator, self.slots[instruction_id].first);
        try self.emitI64Value(rhs);
        try self.body.opcode(self.allocator, 0x7c); // i64.add
        try self.emitInstructionResultSet(instruction_id);
        try self.body.end(self.allocator);
    }
    try self.body.end(self.allocator);
}
pub noinline fn emitNotI32(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    try self.emitI32Value(try self.operand(instruction_value, 0));
    try self.body.i32Const(self.allocator, -1);
    try self.body.opcode(self.allocator, 0x73); // i32.xor
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitNotI64(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    try self.emitI64Value(try self.operand(instruction_value, 0));
    try self.body.i64Const(self.allocator, -1);
    try self.body.opcode(self.allocator, 0x85); // i64.xor
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitSignedI64Shift(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
    positive_opcode: u8,
    negative_opcode: u8,
    saturate_sign: bool,
) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const value = try self.operand(instruction_value, 0);
    const amount = try self.operand(instruction_value, 1);

    try self.emitI64Value(amount);
    try self.body.i64Const(self.allocator, -64);
    try self.body.opcode(self.allocator, 0x57); // i64.le_s
    try self.body.ifVoid(self.allocator);
    try self.body.i64Const(self.allocator, 0);
    try self.emitInstructionResultSet(instruction_id);
    try self.body.else_(self.allocator);

    try self.emitI64Value(amount);
    try self.body.i64Const(self.allocator, 64);
    try self.body.opcode(self.allocator, 0x59); // i64.ge_s
    try self.body.ifVoid(self.allocator);
    if (saturate_sign) {
        try self.emitI64Value(value);
        try self.body.i64Const(self.allocator, 63);
        try self.body.opcode(self.allocator, 0x87); // i64.shr_s
    } else {
        try self.body.i64Const(self.allocator, 0);
    }
    try self.emitInstructionResultSet(instruction_id);
    try self.body.else_(self.allocator);

    try self.emitI64Value(amount);
    try self.body.i64Const(self.allocator, 0);
    try self.body.opcode(self.allocator, 0x53); // i64.lt_s
    try self.body.ifVoid(self.allocator);
    try self.emitI64Value(value);
    try self.body.i64Const(self.allocator, 0);
    try self.emitI64Value(amount);
    try self.body.opcode(self.allocator, 0x7d); // i64.sub
    try self.body.opcode(self.allocator, negative_opcode);
    try self.emitInstructionResultSet(instruction_id);
    try self.body.else_(self.allocator);
    try self.emitI64Value(value);
    try self.emitI64Value(amount);
    try self.body.opcode(self.allocator, positive_opcode);
    try self.emitInstructionResultSet(instruction_id);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}
pub noinline fn emitByteSwapI32(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const value = try self.operand(instruction_value, 0);
    try self.emitI32Value(value);
    try self.body.i32Const(self.allocator, 0x00ff_00ff);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.i32Const(self.allocator, 8);
    try self.body.opcode(self.allocator, 0x74); // i32.shl
    try self.emitI32Value(value);
    try self.body.i32Const(self.allocator, 8);
    try self.body.opcode(self.allocator, 0x76); // i32.shr_u
    try self.body.i32Const(self.allocator, 0x00ff_00ff);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.opcode(self.allocator, 0x72); // i32.or
    try self.body.i32Const(self.allocator, 16);
    try self.body.opcode(self.allocator, 0x77); // i32.rotl
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitAdjacentByteSwapI64(self: anytype, value: snapshot_v1.IrOperand) Error!void {
    try self.emitI64Value(value);
    try self.body.i64Const(self.allocator, 0x00ff_00ff_00ff_00ff);
    try self.body.opcode(self.allocator, 0x83); // i64.and
    try self.body.i64Const(self.allocator, 8);
    try self.body.opcode(self.allocator, 0x86); // i64.shl
    try self.emitI64Value(value);
    try self.body.i64Const(self.allocator, 8);
    try self.body.opcode(self.allocator, 0x88); // i64.shr_u
    try self.body.i64Const(self.allocator, 0x00ff_00ff_00ff_00ff);
    try self.body.opcode(self.allocator, 0x83); // i64.and
    try self.body.opcode(self.allocator, 0x84); // i64.or
}
pub noinline fn emitByteSwapI64(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const value = try self.operand(instruction_value, 0);
    try self.emitAdjacentByteSwapI64(value);
    try self.body.i64Const(self.allocator, 0x0000_ffff_0000_ffff);
    try self.body.opcode(self.allocator, 0x83); // i64.and
    try self.body.i64Const(self.allocator, 16);
    try self.body.opcode(self.allocator, 0x86); // i64.shl
    try self.emitAdjacentByteSwapI64(value);
    try self.body.i64Const(self.allocator, 16);
    try self.body.opcode(self.allocator, 0x88); // i64.shr_u
    try self.body.i64Const(self.allocator, 0x0000_ffff_0000_ffff);
    try self.body.opcode(self.allocator, 0x83); // i64.and
    try self.body.opcode(self.allocator, 0x84); // i64.or
    try self.body.i64Const(self.allocator, 32);
    try self.body.opcode(self.allocator, 0x89); // i64.rotl
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitBinaryF32(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    try self.emitF32Value(try self.operand(instruction_value, 0));
    try self.emitF32Value(try self.operand(instruction_value, 1));
    try self.body.opcode(self.allocator, opcode);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitBinaryF64(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    try self.emitF64Value(try self.operand(instruction_value, 0));
    try self.emitF64Value(try self.operand(instruction_value, 1));
    try self.body.opcode(self.allocator, opcode);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitMulAddNumber(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    try self.emitF64Value(try self.operand(instruction_value, 0));
    try self.emitF64Value(try self.operand(instruction_value, 1));
    try self.body.opcode(self.allocator, 0xa2); // f64.mul
    try self.emitF64Value(try self.operand(instruction_value, 2));
    try self.body.opcode(self.allocator, 0xa0); // f64.add
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitFloorDivisionNumber(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    try self.emitF64Value(try self.operand(instruction_value, 0));
    try self.emitF64Value(try self.operand(instruction_value, 1));
    try self.body.opcode(self.allocator, 0xa3); // f64.div
    try self.body.opcode(self.allocator, 0x9c); // f64.floor
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitModNumber(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const lhs = try self.operand(instruction_value, 0);
    const rhs = try self.operand(instruction_value, 1);
    try self.emitF64Value(lhs);
    try self.emitF64Value(lhs);
    try self.emitF64Value(rhs);
    try self.body.opcode(self.allocator, 0xa3); // f64.div
    try self.body.opcode(self.allocator, 0x9c); // f64.floor
    try self.emitF64Value(rhs);
    try self.body.opcode(self.allocator, 0xa2); // f64.mul
    try self.body.opcode(self.allocator, 0xa1); // f64.sub
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitMinMaxNumber(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, comparison_opcode: u8) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const lhs = try self.operand(instruction_value, 0);
    const rhs = try self.operand(instruction_value, 1);
    try self.emitF64Value(lhs);
    try self.emitF64Value(rhs);
    try self.emitF64Value(lhs);
    try self.emitF64Value(rhs);
    try self.body.opcode(self.allocator, comparison_opcode);
    try self.body.select(self.allocator);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitRoundNumber(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const value = try self.operand(instruction_value, 0);
    try self.emitF64Value(value);
    try self.body.f64Const(self.allocator, round_number_bias);
    try self.emitF64Value(value);
    try self.body.opcode(self.allocator, 0xa6); // f64.copysign
    try self.body.opcode(self.allocator, 0xa0); // f64.add
    try self.body.opcode(self.allocator, 0x9d); // f64.trunc
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitSignNumber(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const value = try self.operand(instruction_value, 0);
    try self.body.f64Const(self.allocator, 1.0);
    try self.body.f64Const(self.allocator, -1.0);
    try self.body.f64Const(self.allocator, 0.0);
    try self.emitF64Value(value);
    try self.body.f64Const(self.allocator, 0.0);
    try self.body.opcode(self.allocator, 0x63); // f64.lt
    try self.body.select(self.allocator);
    try self.emitF64Value(value);
    try self.body.f64Const(self.allocator, 0.0);
    try self.body.opcode(self.allocator, 0x64); // f64.gt
    try self.body.select(self.allocator);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitMinMaxFloat(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, comparison_opcode: u8) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const lhs = try self.operand(instruction_value, 0);
    const rhs = try self.operand(instruction_value, 1);
    try self.emitF32Value(lhs);
    try self.emitF32Value(rhs);
    try self.emitF32Value(lhs);
    try self.emitF32Value(rhs);
    try self.body.opcode(self.allocator, comparison_opcode);
    try self.body.select(self.allocator);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitSignFloat(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const value = try self.operand(instruction_value, 0);
    try self.body.f32Const(self.allocator, 1.0);
    try self.body.f32Const(self.allocator, -1.0);
    try self.body.f32Const(self.allocator, 0.0);
    try self.emitF32Value(value);
    try self.body.f32Const(self.allocator, 0.0);
    try self.body.opcode(self.allocator, 0x5d); // f32.lt
    try self.body.select(self.allocator);
    try self.emitF32Value(value);
    try self.body.f32Const(self.allocator, 0.0);
    try self.body.opcode(self.allocator, 0x5e); // f32.gt
    try self.body.select(self.allocator);
    try self.emitInstructionResultSet(instruction_id);
}
pub fn vectorSlot(self: anytype, operand_value: snapshot_v1.IrOperand) Error!ValueSlot {
    if (operand_value.kind != .instruction or operand_value.value >= self.slots.len)
        return Error.InvalidOperandType;
    const slot = self.slots[operand_value.value];
    if (slot.shape != .tvalue)
        return Error.InvalidInstructionResult;
    return slot;
}
pub noinline fn emitVectorLaneBits(self: anytype, operand_value: snapshot_v1.IrOperand, lane: u32) Error!void {
    const slot = try self.vectorSlot(operand_value);
    switch (lane) {
        0 => try self.body.localGet(self.allocator, slot.first),
        1 => {
            try self.body.localGet(self.allocator, slot.first);
            try self.body.i64Const(self.allocator, 32);
            try self.body.opcode(self.allocator, 0x88); // i64.shr_u
        },
        2 => try self.body.localGet(self.allocator, slot.second),
        3 => {
            try self.body.localGet(self.allocator, slot.second);
            try self.body.i64Const(self.allocator, 32);
            try self.body.opcode(self.allocator, 0x88); // i64.shr_u
        },
        else => return Error.InvalidOperandType,
    }
    try self.body.opcode(self.allocator, 0xa7); // i32.wrap_i64
}
pub noinline fn emitVectorLane(self: anytype, operand_value: snapshot_v1.IrOperand, lane: u32) Error!void {
    try self.emitVectorLaneBits(operand_value, lane);
    try self.body.opcode(self.allocator, 0xbe); // f32.reinterpret_i32
}
pub noinline fn emitVectorPackPrefix(self: anytype, instruction_id: u32, lane: u32) Error!void {
    if (instruction_id >= self.slots.len or self.slots[instruction_id].shape != .tvalue)
        return Error.InvalidInstructionResult;
    if (lane == 1)
        try self.body.localGet(self.allocator, self.slots[instruction_id].first)
    else if (lane == 3)
        try self.body.localGet(self.allocator, self.slots[instruction_id].second);
}
pub noinline fn emitVectorLaneBitsSet(self: anytype, instruction_id: u32, lane: u32) Error!void {
    const slot = self.slots[instruction_id];
    try self.body.opcode(self.allocator, 0xad); // i64.extend_i32_u
    switch (lane) {
        0 => try self.body.localSet(self.allocator, slot.first),
        1 => {
            try self.body.i64Const(self.allocator, 32);
            try self.body.opcode(self.allocator, 0x86); // i64.shl
            try self.body.opcode(self.allocator, 0x84); // i64.or
            try self.body.localSet(self.allocator, slot.first);
        },
        2 => try self.body.localSet(self.allocator, slot.second),
        3 => {
            try self.body.i64Const(self.allocator, 32);
            try self.body.opcode(self.allocator, 0x86); // i64.shl
            try self.body.opcode(self.allocator, 0x84); // i64.or
            try self.body.localSet(self.allocator, slot.second);
        },
        else => return Error.InvalidOperandType,
    }
}
pub noinline fn emitVectorLaneSet(self: anytype, instruction_id: u32, lane: u32) Error!void {
    try self.body.opcode(self.allocator, 0xbc); // i32.reinterpret_f32
    try self.emitVectorLaneBitsSet(instruction_id, lane);
}
pub noinline fn emitVectorUnary(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const value = try self.operand(instruction_value, 0);
    var lane: u32 = 0;
    while (lane < vector_lane_count) : (lane += 1) {
        try self.emitVectorPackPrefix(instruction_id, lane);
        try self.emitVectorLane(value, lane);
        try self.body.opcode(self.allocator, opcode);
        try self.emitVectorLaneSet(instruction_id, lane);
    }
}
pub noinline fn emitVectorBinary(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, opcode: u8) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const lhs = try self.operand(instruction_value, 0);
    const rhs = try self.operand(instruction_value, 1);
    var lane: u32 = 0;
    while (lane < vector_lane_count) : (lane += 1) {
        try self.emitVectorPackPrefix(instruction_id, lane);
        try self.emitVectorLane(lhs, lane);
        try self.emitVectorLane(rhs, lane);
        try self.body.opcode(self.allocator, opcode);
        try self.emitVectorLaneSet(instruction_id, lane);
    }
}
pub noinline fn emitFloorDivisionVector(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const lhs = try self.operand(instruction_value, 0);
    const rhs = try self.operand(instruction_value, 1);
    var lane: u32 = 0;
    while (lane < vector_lane_count) : (lane += 1) {
        try self.emitVectorPackPrefix(instruction_id, lane);
        try self.emitVectorLane(lhs, lane);
        try self.emitVectorLane(rhs, lane);
        try self.body.opcode(self.allocator, 0x95); // f32.div
        try self.body.opcode(self.allocator, 0x8e); // f32.floor
        try self.emitVectorLaneSet(instruction_id, lane);
    }
}
pub noinline fn emitMulAddVector(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    const lhs = try self.operand(instruction_value, 0);
    const rhs = try self.operand(instruction_value, 1);
    const addend = try self.operand(instruction_value, 2);
    var lane: u32 = 0;
    while (lane < vector_lane_count) : (lane += 1) {
        try self.emitVectorPackPrefix(instruction_id, lane);
        try self.emitVectorLane(lhs, lane);
        try self.emitVectorLane(rhs, lane);
        try self.body.opcode(self.allocator, 0x94); // f32.mul
        try self.emitVectorLane(addend, lane);
        try self.body.opcode(self.allocator, 0x92); // f32.add
        try self.emitVectorLaneSet(instruction_id, lane);
    }
}
pub noinline fn emitMinMaxVector(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction, comparison_opcode: u8) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const lhs = try self.operand(instruction_value, 0);
    const rhs = try self.operand(instruction_value, 1);
    var lane: u32 = 0;
    while (lane < vector_lane_count) : (lane += 1) {
        try self.emitVectorPackPrefix(instruction_id, lane);
        try self.emitVectorLaneBits(lhs, lane);
        try self.emitVectorLaneBits(rhs, lane);
        try self.emitVectorLane(lhs, lane);
        try self.emitVectorLane(rhs, lane);
        try self.body.opcode(self.allocator, comparison_opcode);
        try self.body.select(self.allocator);
        try self.emitVectorLaneBitsSet(instruction_id, lane);
    }
}
pub noinline fn emitDotVector(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const lhs = try self.operand(instruction_value, 0);
    const rhs = try self.operand(instruction_value, 1);
    var lane: u32 = 0;
    while (lane < vector_lane_count) : (lane += 1) {
        try self.emitVectorLane(lhs, lane);
        try self.emitVectorLane(rhs, lane);
        try self.body.opcode(self.allocator, 0x94); // f32.mul
        if (lane != 0)
            try self.body.opcode(self.allocator, 0x92); // f32.add
    }
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitExtractVector(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const lane_operand = try self.operand(instruction_value, 1);
    if (lane_operand.kind != .constant)
        return Error.InvalidOperandType;
    const lane = (try self.constant(lane_operand.value)).intValue() orelse return Error.InvalidOperandType;
    if (lane < 0 or lane >= @as(i32, @intCast(vector_lane_count)))
        return Error.InvalidOperandType;
    try self.emitVectorLane(try self.operand(instruction_value, 0), @intCast(lane));
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitFloatToVector(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const value = try self.operand(instruction_value, 0);
    var lane: u32 = 0;
    while (lane < vector_lane_count) : (lane += 1) {
        try self.emitVectorPackPrefix(instruction_id, lane);
        try self.emitF32Value(value);
        try self.emitVectorLaneSet(instruction_id, lane);
    }
}
pub noinline fn emitTagVector(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    if (instruction_id >= self.slots.len or self.slots[instruction_id].shape != .tvalue)
        return Error.InvalidInstructionResult;
    const source = try self.vectorSlot(try self.operand(instruction_value, 0));
    const destination = self.slots[instruction_id];
    try self.body.localGet(self.allocator, source.first);
    try self.body.localSet(self.allocator, destination.first);
    try self.body.localGet(self.allocator, source.second);
    try self.body.i64Const(self.allocator, 0xffff_ffff);
    try self.body.opcode(self.allocator, 0x83); // i64.and
    try self.body.i64Const(self.allocator, lua_tag_vector << 32);
    try self.body.opcode(self.allocator, 0x84); // i64.or
    try self.body.localSet(self.allocator, destination.second);
}
pub fn conditionOperand(self: anytype, instruction_value: snapshot_v1.IrInstruction, index: u32) Error!snapshot_v1.IrCondition {
    const operand_value = try self.operand(instruction_value, index);
    if (operand_value.kind != .condition)
        return Error.InvalidOperandType;
    return @enumFromInt(@as(u8, @intCast(operand_value.value)));
}
pub noinline fn emitIntegerCondition(self: anytype, condition: snapshot_v1.IrCondition) Error!void {
    const opcode: u8 = switch (condition) {
        .equal => 0x46,
        .not_equal => 0x47,
        .less => 0x48,
        .not_less => 0x4e,
        .less_equal => 0x4c,
        .not_less_equal => 0x4a,
        .greater => 0x4a,
        .not_greater => 0x4c,
        .greater_equal => 0x4e,
        .not_greater_equal => 0x48,
        .unsigned_less => 0x49,
        .unsigned_less_equal => 0x4d,
        .unsigned_greater => 0x4b,
        .unsigned_greater_equal => 0x4f,
    };
    try self.body.opcode(self.allocator, opcode);
}
pub noinline fn emitInt64Condition(self: anytype, condition: snapshot_v1.IrCondition) Error!void {
    const opcode: u8 = switch (condition) {
        .equal => 0x51,
        .not_equal => 0x52,
        .less => 0x53,
        .not_less => 0x59,
        .less_equal => 0x57,
        .not_less_equal => 0x55,
        .greater => 0x55,
        .not_greater => 0x57,
        .greater_equal => 0x59,
        .not_greater_equal => 0x53,
        .unsigned_less => 0x54,
        .unsigned_less_equal => 0x58,
        .unsigned_greater => 0x56,
        .unsigned_greater_equal => 0x5a,
    };
    try self.body.opcode(self.allocator, opcode);
}
pub noinline fn emitFloatCondition(self: anytype, condition: snapshot_v1.IrCondition) Error!void {
    switch (condition) {
        .equal => try self.body.opcode(self.allocator, 0x5b),
        .not_equal => try self.body.opcode(self.allocator, 0x5c),
        .less => try self.body.opcode(self.allocator, 0x5d),
        .not_less => {
            try self.body.opcode(self.allocator, 0x5d);
            try self.body.i32Eqz(self.allocator);
        },
        .less_equal => try self.body.opcode(self.allocator, 0x5f),
        .not_less_equal => {
            try self.body.opcode(self.allocator, 0x5f);
            try self.body.i32Eqz(self.allocator);
        },
        .greater => try self.body.opcode(self.allocator, 0x5e),
        .not_greater => {
            try self.body.opcode(self.allocator, 0x5e);
            try self.body.i32Eqz(self.allocator);
        },
        .greater_equal => try self.body.opcode(self.allocator, 0x60),
        .not_greater_equal => {
            try self.body.opcode(self.allocator, 0x60);
            try self.body.i32Eqz(self.allocator);
        },
        .unsigned_less, .unsigned_less_equal, .unsigned_greater, .unsigned_greater_equal => return Error.UnsupportedCondition,
    }
}
pub noinline fn emitComparisonI32(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    try self.emitI32Value(try self.operand(instruction_value, 0));
    try self.emitI32Value(try self.operand(instruction_value, 1));
    try self.emitIntegerCondition(try self.conditionOperand(instruction_value, 2));
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitComparisonI64(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    try self.emitI64Value(try self.operand(instruction_value, 0));
    try self.emitI64Value(try self.operand(instruction_value, 1));
    try self.emitInt64Condition(try self.conditionOperand(instruction_value, 2));
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitComparisonTag(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    const condition = try self.conditionOperand(instruction_value, 2);
    if (condition != .equal and condition != .not_equal)
        return Error.UnsupportedCondition;
    try self.emitTagValue(try self.operand(instruction_value, 0));
    try self.emitTagValue(try self.operand(instruction_value, 1));
    try self.emitIntegerCondition(condition);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitSplitTValueComparison(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 5);
    const expected_tag_operand = try self.operand(instruction_value, 1);
    if (expected_tag_operand.kind != .constant)
        return Error.InvalidOperandType;
    const expected_tag = (try self.constant(expected_tag_operand.value)).tagValue() orelse return Error.InvalidOperandType;
    const condition = try self.conditionOperand(instruction_value, 4);
    if (condition != .equal and condition != .not_equal)
        return Error.UnsupportedCondition;

    try self.emitTagValue(try self.operand(instruction_value, 0));
    try self.emitTagValue(expected_tag_operand);
    try self.emitIntegerCondition(condition);

    const lhs = try self.operand(instruction_value, 2);
    const rhs = try self.operand(instruction_value, 3);
    switch (expected_tag) {
        lua_tag_boolean, lua_tag_string => {
            try self.emitI32Value(lhs);
            try self.emitI32Value(rhs);
            try self.emitIntegerCondition(condition);
        },
        lua_tag_number => {
            try self.emitF64Value(lhs);
            try self.emitF64Value(rhs);
            if (condition == .equal)
                try self.body.f64Eq(self.allocator)
            else
                try self.body.f64Ne(self.allocator);
        },
        lua_tag_integer => {
            try self.emitI64Value(lhs);
            try self.emitI64Value(rhs);
            try self.emitInt64Condition(condition);
        },
        else => return Error.UnsupportedOperand,
    }

    try self.body.opcode(self.allocator, if (condition == .equal) 0x71 else 0x72); // i32.and / i32.or
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitSelectNumber(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 4);
    try self.emitF64Value(try self.operand(instruction_value, 1));
    try self.emitF64Value(try self.operand(instruction_value, 0));
    try self.emitF64Value(try self.operand(instruction_value, 2));
    try self.emitF64Value(try self.operand(instruction_value, 3));
    try self.body.f64Eq(self.allocator);
    try self.body.select(self.allocator);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitSelectInt64(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 5);
    try self.emitI64Value(try self.operand(instruction_value, 1));
    try self.emitI64Value(try self.operand(instruction_value, 0));
    try self.emitI64Value(try self.operand(instruction_value, 2));
    try self.emitI64Value(try self.operand(instruction_value, 3));
    try self.emitInt64Condition(try self.conditionOperand(instruction_value, 4));
    try self.body.select(self.allocator);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitSelectVector(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 4);
    const false_value = try self.operand(instruction_value, 0);
    const true_value = try self.operand(instruction_value, 1);
    const lhs = try self.operand(instruction_value, 2);
    const rhs = try self.operand(instruction_value, 3);
    var lane: u32 = 0;
    while (lane < tvalue_lane_count) : (lane += 1) {
        try self.emitVectorPackPrefix(instruction_id, lane);
        try self.emitVectorLaneBits(true_value, lane);
        try self.emitVectorLaneBits(false_value, lane);
        if (lane < vector_lane_count) {
            try self.emitVectorLane(lhs, lane);
            try self.emitVectorLane(rhs, lane);
        } else {
            // Upstream vecOp normalizes the non-semantic W lane to zero even when the source
            // TValue carries a tag in its high word. Preserve the selected raw lane above, but
            // compare the normalized vector operands here.
            try self.body.f32Const(self.allocator, 0.0);
            try self.body.f32Const(self.allocator, 0.0);
        }
        try self.body.opcode(self.allocator, 0x5b); // f32.eq
        try self.body.select(self.allocator);
        try self.emitVectorLaneBitsSet(instruction_id, lane);
    }
}
pub noinline fn emitSelectIfTruthy(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    if (instruction_id >= self.slots.len or self.slots[instruction_id].shape != .tvalue)
        return Error.InvalidInstructionResult;
    const condition = try self.operand(instruction_value, 0);
    const true_value = try self.operand(instruction_value, 1);
    const false_value = try self.operand(instruction_value, 2);
    const destination = self.slots[instruction_id];

    try self.emitTValuePart(true_value, false);
    try self.emitTValuePart(false_value, false);
    try self.emitTValueTruthy(condition);
    try self.body.select(self.allocator);
    try self.body.localSet(self.allocator, destination.first);

    try self.emitTValuePart(true_value, true);
    try self.emitTValuePart(false_value, true);
    try self.emitTValueTruthy(condition);
    try self.body.select(self.allocator);
    try self.body.localSet(self.allocator, destination.second);
}
pub noinline fn emitCopyI32(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    try self.emitI32Value(try self.operand(instruction_value, 0));
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitNotAny(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const tag = try self.operand(instruction_value, 0);
    const value = try self.operand(instruction_value, 1);
    try self.emitI32Value(tag);
    try self.body.i32Const(self.allocator, lua_tag_nil);
    try self.body.i32Eq(self.allocator);
    try self.emitI32Value(tag);
    try self.body.i32Const(self.allocator, lua_tag_boolean);
    try self.body.i32Eq(self.allocator);
    try self.emitI32Value(value);
    try self.body.i32Eqz(self.allocator);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.opcode(self.allocator, 0x72); // i32.or
    try self.emitInstructionResultSet(instruction_id);
}

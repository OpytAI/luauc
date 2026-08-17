const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");
const admission = @import("luauc_backend_admission");

const Error = model.Error;
const IntegerCreatePattern = model.IntegerCreatePattern;
const isBufferBuiltinId = model.isBufferBuiltinId;
const status_internal_error = abi.status_internal_error;
const ir_cmd_check_buffer_len = abi.ir_cmd_check_buffer_len;
const ir_cmd_buffer_readi8 = abi.ir_cmd_buffer_readi8;
const ir_cmd_buffer_readu8 = abi.ir_cmd_buffer_readu8;
const ir_cmd_buffer_writei8 = abi.ir_cmd_buffer_writei8;
const ir_cmd_buffer_readi16 = abi.ir_cmd_buffer_readi16;
const ir_cmd_buffer_readu16 = abi.ir_cmd_buffer_readu16;
const ir_cmd_buffer_writei16 = abi.ir_cmd_buffer_writei16;
const ir_cmd_buffer_readi32 = abi.ir_cmd_buffer_readi32;
const ir_cmd_buffer_writei32 = abi.ir_cmd_buffer_writei32;
const ir_cmd_buffer_readf32 = abi.ir_cmd_buffer_readf32;
const ir_cmd_buffer_writef32 = abi.ir_cmd_buffer_writef32;
const ir_cmd_buffer_readf64 = abi.ir_cmd_buffer_readf64;
const ir_cmd_buffer_writef64 = abi.ir_cmd_buffer_writef64;
const ir_cmd_buffer_readi64 = abi.ir_cmd_buffer_readi64;
const ir_cmd_buffer_writei64 = abi.ir_cmd_buffer_writei64;
const ir_cmd_get_hash_node_addr = abi.ir_cmd_get_hash_node_addr;
const ir_cmd_get_slot_node_addr = abi.ir_cmd_get_slot_node_addr;
const tvalue_size = abi.tvalue_size;
const tvalue_tag_offset = abi.tvalue_tag_offset;
const buffer_len_offset = abi.buffer_len_offset;
const buffer_data_offset = abi.buffer_data_offset;
const userdata_data_offset = abi.userdata_data_offset;
const lua_tag_nil = abi.lua_tag_nil;
const lua_tag_boolean = abi.lua_tag_boolean;
const lua_tag_number = abi.lua_tag_number;
const lua_tag_integer = abi.lua_tag_integer;
const lua_tag_string = abi.lua_tag_string;
const lua_tag_table = abi.lua_tag_table;
const lua_tag_userdata = abi.lua_tag_userdata;
const lua_tag_buffer = abi.lua_tag_buffer;
const lua_utag_limit = abi.lua_utag_limit;
const lop_fornprep = abi.lop_fornprep;

pub noinline fn emitCheckDivInt64(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    const lhs = try self.operand(instruction_value, 0);
    const rhs = try self.operand(instruction_value, 1);
    const failure = try self.operand(instruction_value, 2);

    // Reject b == 0 and INT64_MIN / -1, exactly the two cases guarded by the pinned native
    // lowerers before their signed division instructions.
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
    switch (failure.kind) {
        .block => {
            const target_block = try self.snapshot.irBlock(self.function, failure.value);
            if (target_block.kind == .fallback and !try admission.supportsFallback(self, target_block))
                return Error.UnsupportedControlFlow;
            const target = if (target_block.kind == .fallback)
                failure.value
            else
                try self.requireCompiledTarget(failure);
            try self.body.i32Const(self.allocator, @intCast(target));
            try self.body.localSet(self.allocator, self.dispatch_local);
            try self.body.branch(self.allocator, 2);
        },
        .vm_exit => return Error.UnsupportedControlFlow,
        .undef => try self.emitStatusReturn(status_internal_error),
        else => return Error.InvalidOperandType,
    }
    try self.body.end(self.allocator);
}
pub noinline fn emitBuiltinTypeError(
    self: anytype,
    instruction_value: snapshot_v1.IrInstruction,
    pc: u32,
) Error!bool {
    const fallback = (try self.builtinFallback(pc)) orelse return false;
    const checked = try self.operand(instruction_value, 0);
    const expected = try self.operand(instruction_value, 1);
    if (checked.kind != .instruction or expected.kind != .constant)
        return false;
    const load = try self.instruction(checked.value);
    if (load.command != .load_tag or load.operand_count != 1)
        return false;
    const source_register = try self.vmRegisterIndex(try self.operand(load, 0));
    var argument: ?u32 = null;
    var index: u32 = 0;
    while (index < fallback.argument_count) : (index += 1) {
        if (fallback.argument_registers[index] == source_register) {
            if (argument != null)
                return false;
            argument = index + 1;
        }
    }
    const expected_tag = (try self.constant(expected.value)).tagValue() orelse return false;
    const name = try self.string_keys.intern(self.allocator, fallback.name);
    try self.emitPcLocation(fallback.pc);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(name.offset));
    try self.body.i32Const(self.allocator, @intCast(name.length));
    try self.body.i32Const(self.allocator, @intCast(argument orelse return false));
    try self.body.i32Const(self.allocator, @intCast(expected_tag));
    try self.body.i32Const(self.allocator, @intCast(source_register));
    try self.body.call(self.allocator, self.builtin_type_error orelse return Error.UnsupportedCommand);
    try self.body.i32Const(self.allocator, 1);
    try self.body.i32Ne(self.allocator);
    try self.emitInternalErrorIf();
    return true;
}
pub noinline fn emitFornPreparation(
    self: anytype,
    instruction_value: snapshot_v1.IrInstruction,
    pc: u32,
) Error!bool {
    if (pc >= self.proto.code_count)
        return false;
    const word = try self.snapshot.bytecodeWord(self.proto, pc);
    if (@as(u8, @truncate(word)) != lop_fornprep)
        return false;

    const checked = try self.operand(instruction_value, 0);
    const expected = try self.operand(instruction_value, 1);
    if (checked.kind != .instruction or expected.kind != .constant or
        (try self.constant(expected.value)).tagValue() != lua_tag_number)
        return false;
    const load = try self.instruction(checked.value);
    if (load.command != .load_tag or load.operand_count != 1)
        return false;
    const source_register = try self.vmRegisterIndex(try self.operand(load, 0));
    const base_register = (word >> 8) & 0xff;
    if (base_register > self.proto.max_stack_size or self.proto.max_stack_size - base_register < 3 or
        source_register < base_register or source_register - base_register >= 3)
        return false;

    try self.emitPcLocation(pc);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(base_register));
    try self.body.call(self.allocator, self.forn_prepare orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
    return true;
}
pub noinline fn emitCheckTag(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    try self.emitI32Value(try self.operand(instruction_value, 0));
    try self.emitI32Value(try self.operand(instruction_value, 1));
    const failure = try self.operand(instruction_value, 2);
    try self.body.i32Ne(self.allocator);
    try self.body.ifVoid(self.allocator);
    switch (failure.kind) {
        .block => {
            const target_block = try self.snapshot.irBlock(self.function, failure.value);
            if (target_block.kind == .fallback and !try admission.supportsFallback(self, target_block))
                return Error.UnsupportedControlFlow;
            const target = if (target_block.kind == .fallback)
                failure.value
            else
                try self.requireCompiledTarget(failure);
            try self.body.i32Const(self.allocator, @intCast(target));
            try self.body.localSet(self.allocator, self.dispatch_local);
            // CHECK_TAG's conditional is nested inside the selected-block conditional.
            try self.body.branch(self.allocator, 2);
        },
        .vm_exit => blk: {
            if (failure.value < self.proto.code_count) {
                if (try self.emitFornPreparation(instruction_value, failure.value) or
                    try self.emitBuiltinTypeError(instruction_value, failure.value))
                    break :blk;
            }
            const expected = try self.operand(instruction_value, 1);
            if (expected.kind == .constant and
                (try self.constant(expected.value)).tagValue() == lua_tag_userdata)
                try self.emitStatusReturn(status_internal_error)
            else
                return Error.UnsupportedControlFlow;
        },
        .undef => try self.emitStatusReturn(status_internal_error),
        else => return Error.InvalidOperandType,
    }
    try self.body.end(self.allocator);
}
pub noinline fn emitInvalidSignedConversion(self: anytype, source: snapshot_v1.IrOperand, lower: f64, upper: f64) Error!void {
    try self.emitF64Value(source);
    try self.emitF64Value(source);
    try self.body.f64Ne(self.allocator); // NaN
    try self.emitF64Value(source);
    try self.body.f64Const(self.allocator, lower);
    try self.body.f64Lt(self.allocator);
    try self.body.opcode(self.allocator, 0x72); // i32.or
    try self.emitF64Value(source);
    try self.body.f64Const(self.allocator, upper);
    try self.body.f64Ge(self.allocator);
    try self.body.opcode(self.allocator, 0x72); // i32.or
}
pub noinline fn emitNumToInt(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const source = try self.operand(instruction_value, 0);
    try self.emitInvalidSignedConversion(source, -2147483648.0, 2147483648.0);
    try self.body.ifVoid(self.allocator);
    // Match the pinned x86 cvttsd2si invalid result instead of exposing a trapping Wasm cast.
    try self.body.i32Const(self.allocator, std.math.minInt(i32));
    try self.emitInstructionResultSet(instruction_id);
    try self.body.else_(self.allocator);
    try self.emitF64Value(source);
    try self.body.opcode(self.allocator, 0xaa); // i32.trunc_f64_s
    try self.emitInstructionResultSet(instruction_id);
    try self.body.end(self.allocator);
}
pub noinline fn emitNumToInt64(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const source = try self.operand(instruction_value, 0);
    try self.emitInvalidSignedConversion(source, -9223372036854775808.0, 9223372036854775808.0);
    try self.body.ifVoid(self.allocator);
    try self.body.i64Const(self.allocator, std.math.minInt(i64));
    try self.emitInstructionResultSet(instruction_id);
    try self.body.else_(self.allocator);
    try self.emitF64Value(source);
    try self.body.opcode(self.allocator, 0xb0); // i64.trunc_f64_s
    try self.emitInstructionResultSet(instruction_id);
    try self.body.end(self.allocator);
}
pub noinline fn emitNumToUint(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const source = try self.operand(instruction_value, 0);
    // Pinned NUM_TO_UINT is `(unsigned)(long long)n`: perform the signed i64 conversion first,
    // then keep the low 32 bits, including the pinned invalid-conversion result.
    try self.emitInvalidSignedConversion(source, -9223372036854775808.0, 9223372036854775808.0);
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, 0); // low bits of INT64_MIN
    try self.emitInstructionResultSet(instruction_id);
    try self.body.else_(self.allocator);
    try self.emitF64Value(source);
    try self.body.opcode(self.allocator, 0xb0); // i64.trunc_f64_s
    try self.body.opcode(self.allocator, 0xa7); // i32.wrap_i64
    try self.emitInstructionResultSet(instruction_id);
    try self.body.end(self.allocator);
}
pub noinline fn emitBufferLengthCheck(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    _ = instruction_id;
    try self.requireOperandCount(instruction_value, 6);
    const pointer = try self.operand(instruction_value, 0);
    const index = try self.operand(instruction_value, 1);
    const original = try self.operand(instruction_value, 4);
    const failure = try self.operand(instruction_value, 5);
    const min_offset = try self.intConstant(try self.operand(instruction_value, 2));
    const max_offset = try self.intConstant(try self.operand(instruction_value, 3));
    if (min_offset >= max_offset or min_offset < -4095 or max_offset > 4095 or
        try self.loadedPointerRegister(pointer) == null or
        (index.kind != .instruction and index.kind != .constant) or
        (original.kind != .undef and original.kind != .instruction))
        return Error.UnsupportedControlFlow;
    if (failure.kind == .vm_exit) {
        const fallback = (try self.builtinFallback(failure.value)) orelse
            return Error.UnsupportedControlFlow;
        if (!isBufferBuiltinId(fallback.id))
            return Error.UnsupportedControlFlow;
    }

    // The native guard's original-number roundtrip is an optimization exit, not a language
    // rejection: the pinned C fallback truncates fractional numeric offsets. Generated code
    // therefore uses NUM_TO_INT's pinned result and applies only the actual buffer bound.
    if (min_offset >= 0) {
        try self.emitI32Value(index);
        try self.body.opcode(self.allocator, 0xad); // i64.extend_i32_u
        try self.body.i64Const(self.allocator, max_offset);
    } else {
        try self.emitI32Value(index);
        try self.body.i32Const(self.allocator, min_offset);
        try self.body.opcode(self.allocator, 0x6a); // i32.add
        try self.body.opcode(self.allocator, 0xad); // i64.extend_i32_u
        try self.body.i64Const(self.allocator, max_offset - min_offset);
    }
    try self.body.opcode(self.allocator, 0x7c); // i64.add
    try self.emitPointerValue(pointer);
    try self.body.i32Load(self.allocator, 2, buffer_len_offset);
    try self.body.opcode(self.allocator, 0xad); // i64.extend_i32_u
    try self.body.opcode(self.allocator, 0x56); // i64.gt_u
    if (failure.kind != .vm_exit) {
        try self.emitGuardFailure(failure);
        return;
    }

    try self.body.ifVoid(self.allocator);
    try self.emitPcLocation(failure.value);
    try self.body.localGet(self.allocator, 0);
    try self.body.call(self.allocator, self.buffer_bounds_error orelse return Error.UnsupportedCommand);
    try self.emitStatusReturn(status_internal_error);
    try self.body.end(self.allocator);
}
pub noinline fn emitBufferAddress(self: anytype, pointer: snapshot_v1.IrOperand, index: snapshot_v1.IrOperand) Error!void {
    try self.emitPointerValue(pointer);
    try self.emitI32Value(index);
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.i32Const(self.allocator, @intCast(buffer_data_offset));
    try self.body.opcode(self.allocator, 0x6a); // i32.add
}
pub noinline fn emitUnalignedMemoryOp(self: anytype, opcode: u8) Error!void {
    try self.body.opcode(self.allocator, opcode);
    try self.body.opcode(self.allocator, 0); // alignment exponent
    try self.body.opcode(self.allocator, 0); // offset
}
pub noinline fn emitBufferRead(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    const tag = try self.operand(instruction_value, 2);
    if (tag.kind == .constant and (try self.constant(tag.value)).tagValue() == lua_tag_userdata) {
        const pointer = try self.operand(instruction_value, 0);
        const offset = try self.uintConstant(try self.operand(instruction_value, 1));
        try self.emitPointerValue(pointer);
        const data_offset = std.math.add(u32, userdata_data_offset, offset) catch return Error.ResourceLimit;
        try self.body.i32Const(self.allocator, @intCast(data_offset));
        try self.body.opcode(self.allocator, 0x6a); // i32.add
    } else {
        if (!try self.bufferOperationOwnedByRange(instruction_id, instruction_value))
            return Error.UnsupportedControlFlow;
        try self.emitBufferAddress(try self.operand(instruction_value, 0), try self.operand(instruction_value, 1));
    }
    switch (instruction_value.command) {
        ir_cmd_buffer_readi8 => try self.emitUnalignedMemoryOp(0x2c), // i32.load8_s
        ir_cmd_buffer_readu8 => try self.emitUnalignedMemoryOp(0x2d), // i32.load8_u
        ir_cmd_buffer_readi16 => try self.emitUnalignedMemoryOp(0x2e), // i32.load16_s
        ir_cmd_buffer_readu16 => try self.emitUnalignedMemoryOp(0x2f), // i32.load16_u
        ir_cmd_buffer_readi32 => try self.body.i32Load(self.allocator, 0, 0),
        ir_cmd_buffer_readf32 => try self.body.f32Load(self.allocator, 0, 0),
        ir_cmd_buffer_readf64 => try self.body.f64Load(self.allocator, 0, 0),
        ir_cmd_buffer_readi64 => try self.body.i64Load(self.allocator, 0, 0),
        else => return Error.UnsupportedCommand,
    }
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitBufferWrite(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    if (!try self.bufferOperationOwnedByRange(instruction_id, instruction_value))
        return Error.UnsupportedControlFlow;
    try self.requireOperandCount(instruction_value, 4);
    try self.emitBufferAddress(try self.operand(instruction_value, 0), try self.operand(instruction_value, 1));
    const value = try self.operand(instruction_value, 2);
    switch (instruction_value.command) {
        ir_cmd_buffer_writei8 => {
            try self.emitI32Value(value);
            try self.emitUnalignedMemoryOp(0x3a); // i32.store8
        },
        ir_cmd_buffer_writei16 => {
            try self.emitI32Value(value);
            try self.emitUnalignedMemoryOp(0x3b); // i32.store16
        },
        ir_cmd_buffer_writei32 => {
            try self.emitI32Value(value);
            try self.body.i32Store(self.allocator, 0, 0);
        },
        ir_cmd_buffer_writef32 => {
            try self.emitF32Value(value);
            try self.body.f32Store(self.allocator, 0, 0);
        },
        ir_cmd_buffer_writef64 => {
            try self.emitF64Value(value);
            try self.body.f64Store(self.allocator, 0, 0);
        },
        ir_cmd_buffer_writei64 => {
            try self.emitI64Value(value);
            try self.body.i64Store(self.allocator, 0, 0);
        },
        else => return Error.UnsupportedCommand,
    }
}
pub noinline fn emitUserdataWrite(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 4);
    const pointer = try self.operand(instruction_value, 0);
    const offset = try self.uintConstant(try self.operand(instruction_value, 1));
    try self.emitPointerValue(pointer);
    const data_offset = std.math.add(u32, userdata_data_offset, offset) catch return Error.ResourceLimit;
    try self.body.i32Const(self.allocator, @intCast(data_offset));
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    const value = try self.operand(instruction_value, 2);
    switch (instruction_value.command) {
        ir_cmd_buffer_writei8 => {
            try self.emitI32Value(value);
            try self.emitUnalignedMemoryOp(0x3a); // i32.store8
        },
        ir_cmd_buffer_writei16 => {
            try self.emitI32Value(value);
            try self.emitUnalignedMemoryOp(0x3b); // i32.store16
        },
        ir_cmd_buffer_writei32 => {
            try self.emitI32Value(value);
            try self.body.i32Store(self.allocator, 0, 0);
        },
        ir_cmd_buffer_writef32 => {
            try self.emitF32Value(value);
            try self.body.f32Store(self.allocator, 0, 0);
        },
        ir_cmd_buffer_writef64 => {
            try self.emitF64Value(value);
            try self.body.f64Store(self.allocator, 0, 0);
        },
        ir_cmd_buffer_writei64 => {
            try self.emitI64Value(value);
            try self.body.i64Store(self.allocator, 0, 0);
        },
        else => return Error.UnsupportedCommand,
    }
}
pub fn loadedPointerRegister(self: anytype, pointer: snapshot_v1.IrOperand) Error!?u32 {
    if (pointer.kind != .instruction or pointer.value >= self.function.instruction_count)
        return null;
    const load = try self.instruction(pointer.value);
    if (load.command != .load_pointer or load.operand_count != 1)
        return null;
    const source = try self.operand(load, 0);
    if (source.kind != .vm_reg or source.value >= self.proto.max_stack_size)
        return null;
    return source.value;
}
pub fn rootedTablePointerRegister(self: anytype, pointer: snapshot_v1.IrOperand) Error!?u32 {
    if (try self.loadedPointerRegister(pointer)) |register|
        return register;
    if (pointer.kind != .instruction or pointer.value >= self.function.instruction_count)
        return null;
    if (try self.tableAllocationPatternAt(pointer.value)) |pattern|
        return pattern.destination;
    if (pointer.value != 0)
        if (try self.dupTablePatternAt(pointer.value - 1)) |pattern|
            if (pattern.start + 1 == pointer.value) return pattern.destination;
    return null;
}
pub noinline fn emitRegisterTagMismatch(self: anytype, register: u32, expected: i32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, register * tvalue_size + tvalue_tag_offset);
    try self.body.i32Const(self.allocator, expected);
    try self.body.i32Ne(self.allocator);
}
pub noinline fn emitCheckUserdataTag(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    const pointer = try self.operand(instruction_value, 0);
    const expected = try self.uintConstant(try self.operand(instruction_value, 1));
    if (expected >= lua_utag_limit)
        return Error.InvalidOperandType;
    const failure = try self.operand(instruction_value, 2);
    if (try self.loadedPointerRegister(pointer)) |register| {
        try self.emitRegisterTagMismatch(register, lua_tag_userdata);
        try self.emitGuardFailure(failure);
    } else if (pointer.kind != .instruction or
        (self.plan.clusterAt(pointer.value) orelse return Error.UnsupportedControlFlow).kind != .userdata_alloc)
        return Error.UnsupportedControlFlow;

    try self.body.localGet(self.allocator, 0);
    try self.emitPointerValue(pointer);
    try self.body.i32Const(self.allocator, @intCast(expected));
    try self.body.call(self.allocator, self.check_userdata_tag orelse return Error.UnsupportedCommand);
    try self.body.i32Eqz(self.allocator);
    try self.emitGuardFailure(failure);
}
pub noinline fn emitInternalErrorIf(self: anytype) Error!void {
    try self.body.ifVoid(self.allocator);
    try self.emitStatusReturn(status_internal_error);
    try self.body.end(self.allocator);
}
pub noinline fn emitBarrierObject(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    const owner = try self.operand(instruction_value, 0);
    const source = try self.operand(instruction_value, 1);
    const static_tag = try self.operand(instruction_value, 2);
    if (source.kind != .vm_reg or source.value >= self.proto.max_stack_size or
        (static_tag.kind != .undef and static_tag.kind != .constant))
        return Error.InvalidOperandType;
    if (static_tag.kind == .constant and (try self.constant(static_tag.value)).tagValue() == null)
        return Error.InvalidOperandType;

    if (try self.loadedPointerRegister(owner)) |register| {
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Load(self.allocator, 2, register * tvalue_size + tvalue_tag_offset);
        try self.body.i32Const(self.allocator, lua_tag_string);
        try self.body.opcode(self.allocator, 0x48); // i32.lt_s
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Load(self.allocator, 2, register * tvalue_size + tvalue_tag_offset);
        try self.body.i32Const(self.allocator, 13);
        try self.body.opcode(self.allocator, 0x4a); // i32.gt_s
        try self.body.opcode(self.allocator, 0x72); // i32.or
        try self.emitInternalErrorIf();
    } else if (owner.kind != .instruction or
        (self.plan.clusterAt(owner.value) orelse return Error.UnsupportedControlFlow).kind != .userdata_alloc)
        return Error.UnsupportedControlFlow;

    try self.body.localGet(self.allocator, 0);
    try self.emitPointerValue(owner);
    try self.body.i32Const(self.allocator, @intCast(source.value));
    try self.body.call(self.allocator, self.barrier_object orelse return Error.UnsupportedCommand);
}
pub noinline fn emitBarrierTableBack(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const table = try self.operand(instruction_value, 0);
    if (try self.loadedPointerRegister(table)) |register| {
        try self.emitRegisterTagMismatch(register, lua_tag_table);
        try self.emitInternalErrorIf();
        try self.body.localGet(self.allocator, 0);
        try self.emitPointerValue(table);
    } else if (table.kind == .instruction) {
        const dest_reg = if (try self.tableAllocationPatternAt(table.value)) |pattern|
            pattern.destination
        else if (table.value != 0) blk: {
            const pattern = (try self.dupTablePatternAt(table.value - 1)) orelse
                return Error.UnsupportedControlFlow;
            break :blk pattern.destination;
        } else return Error.UnsupportedControlFlow;
        try self.body.localGet(self.allocator, 0);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Load(self.allocator, 2, dest_reg * tvalue_size);
    } else return Error.UnsupportedControlFlow;
    try self.body.call(self.allocator, self.barrier_table_back orelse return Error.UnsupportedCommand);
}
pub fn requireLiveNode(
    self: anytype,
    consumer_id: u32,
    node: snapshot_v1.IrOperand,
) Error!void {
    if (node.kind != .instruction or
        !try self.plan.validateNodeUse(self.snapshot, self.function, node.value, consumer_id))
        return Error.UnsupportedControlFlow;
}
pub noinline fn emitGetHashNodeAddr(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const owner_block_id = self.plan.instructionBlock(instruction_id) orelse
        return Error.UnsupportedControlFlow;
    const owner_block = try self.snapshot.irBlock(self.function, owner_block_id);
    const family = (try self.plainTableNamecallPattern(owner_block)) orelse
        return Error.UnsupportedControlFlow;
    if (instruction_id != family.start + 3)
        return Error.UnsupportedControlFlow;
    const table = try self.operand(instruction_value, 0);
    if (table.kind != .instruction or table.value >= self.slots.len or
        self.slots[table.value].shape != .pointer)
        return Error.InvalidOperandType;
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(family.source));
    try self.emitI32Value(try self.operand(instruction_value, 1));
    try self.body.call(self.allocator, self.hash_node_addr orelse return Error.UnsupportedCommand);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitGetSlotNodeAddr(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    const table = try self.operand(instruction_value, 0);
    const pc = try self.operand(instruction_value, 1);
    const key = try self.operand(instruction_value, 2);
    if (table.kind != .instruction or table.value >= self.slots.len or
        self.slots[table.value].shape != .pointer or pc.kind != .constant or
        (try self.constant(pc.value)).uintValue() == null or key.kind != .vm_const or
        key.value >= self.proto.vm_constant_count)
        return Error.InvalidOperandType;
    const table_producer = try self.instruction(table.value);
    if (table_producer.command != .load_env and !self.plan.isProvenTablePointer(table.value))
        return Error.UnsupportedControlFlow;
    try self.body.localGet(self.allocator, 0);
    try self.emitPointerValue(table);
    try self.body.i32Const(self.allocator, @intCast(key.value));
    try self.body.call(self.allocator, self.slot_node_addr orelse return Error.UnsupportedCommand);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitJumpSlotMatch(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    try self.requireOperandCount(instruction_value, 4);
    const node = try self.operand(instruction_value, 0);
    const key = try self.operand(instruction_value, 1);
    if (key.kind != .vm_const or key.value >= self.proto.vm_constant_count)
        return Error.InvalidOperandType;
    try self.requireLiveNode(instruction_id, node);
    const match_target = try self.requireCompiledTarget(try self.operand(instruction_value, 2));
    const mismatch_target = try self.requireCompiledTarget(try self.operand(instruction_value, 3));
    try self.body.localGet(self.allocator, 0);
    try self.emitPointerValue(node);
    try self.body.i32Const(self.allocator, @intCast(key.value));
    try self.body.call(self.allocator, self.node_slot_match orelse return Error.UnsupportedCommand);
    try self.emitConditionalDispatch(match_target, mismatch_target);
}
pub noinline fn emitCheckSlotMatch(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    const node = try self.operand(instruction_value, 0);
    const key = try self.operand(instruction_value, 1);
    if (key.kind != .vm_const or key.value >= self.proto.vm_constant_count)
        return Error.InvalidOperandType;
    try self.requireLiveNode(instruction_id, node);
    try self.body.localGet(self.allocator, 0);
    try self.emitPointerValue(node);
    try self.body.i32Const(self.allocator, @intCast(key.value));
    try self.body.call(self.allocator, self.node_slot_match orelse return Error.UnsupportedCommand);
    try self.body.i32Eqz(self.allocator);
    try self.emitGuardFailure(try self.operand(instruction_value, 2));
}
pub noinline fn emitTryCallFastGetTm(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    const table = try self.operand(instruction_value, 0);
    if (table.kind != .instruction or table.value >= self.slots.len or
        self.slots[table.value].shape != .pointer)
        return Error.InvalidOperandType;
    try self.body.localGet(self.allocator, 0);
    try self.emitPointerValue(table);
    try self.emitI32Value(try self.operand(instruction_value, 1));
    try self.body.call(self.allocator, self.try_get_tm orelse return Error.UnsupportedCommand);
    try self.body.localTee(self.allocator, self.slots[instruction_id].first);
    try self.body.i32Eqz(self.allocator);
    try self.emitGuardFailure(try self.operand(instruction_value, 2));
}
pub noinline fn emitCheckNodeNoNext(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const node = try self.operand(instruction_value, 0);
    try self.requireLiveNode(instruction_id, node);
    try self.body.localGet(self.allocator, 0);
    try self.emitPointerValue(node);
    try self.body.call(self.allocator, self.check_node_no_next orelse return Error.UnsupportedCommand);
    try self.emitGuardFailure(try self.operand(instruction_value, 1));
}
pub noinline fn emitCheckNodeValue(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const node = try self.operand(instruction_value, 0);
    try self.requireLiveNode(instruction_id, node);
    try self.body.localGet(self.allocator, 0);
    try self.emitPointerValue(node);
    try self.body.call(self.allocator, self.check_node_value orelse return Error.UnsupportedCommand);
    try self.emitGuardFailure(try self.operand(instruction_value, 1));
}
pub noinline fn emitCheckReadonly(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    const table = try self.operand(instruction_value, 0);
    const failure = try self.operand(instruction_value, 1);
    if (table.kind != .instruction or table.value >= self.slots.len or
        self.slots[table.value].shape != .pointer or try self.loadedPointerRegister(table) == null)
        return Error.InvalidOperandType;

    if (failure.kind == .vm_exit)
        try self.emitPcLocation(failure.value)
    else if (failure.kind != .block)
        return Error.InvalidOperandType;
    try self.body.localGet(self.allocator, 0);
    try self.emitPointerValue(table);
    try self.body.i32Const(self.allocator, @intFromBool(failure.kind == .vm_exit));
    try self.body.call(self.allocator, self.check_readonly orelse return Error.UnsupportedCommand);
    if (failure.kind == .vm_exit)
        try self.body.opcode(self.allocator, 0x1a)
    else
        try self.emitGuardFailure(failure);
}
pub noinline fn emitBufferAdjustStack(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    _ = instruction_id;
    try self.requireOperandCount(instruction_value, 2);
    const count = try self.intConstant(try self.operand(instruction_value, 1));
    if (count < 0)
        return Error.InvalidOperandType;
    try self.emitAdjustStackConstant(
        try self.vmRegisterIndex(try self.operand(instruction_value, 0)),
        @intCast(count),
    );
}
pub noinline fn emitGuardFailure(self: anytype, failure: snapshot_v1.IrOperand) Error!void {
    try self.body.ifVoid(self.allocator);
    switch (failure.kind) {
        .block => {
            const target_block = try self.snapshot.irBlock(self.function, failure.value);
            if (target_block.kind == .fallback and !try admission.supportsFallback(self, target_block))
                return Error.UnsupportedControlFlow;
            const target = if (target_block.kind == .fallback)
                failure.value
            else
                try self.requireCompiledTarget(failure);
            try self.body.i32Const(self.allocator, @intCast(target));
            try self.body.localSet(self.allocator, self.dispatch_local);
            // The guard conditional is nested inside the selected-block conditional.
            try self.body.branch(self.allocator, 2);
        },
        .vm_exit => return Error.UnsupportedControlFlow,
        .undef => try self.emitStatusReturn(status_internal_error),
        else => return Error.InvalidOperandType,
    }
    try self.body.end(self.allocator);
}
pub noinline fn emitCheckTruthy(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    const tag = try self.operand(instruction_value, 0);
    const value = try self.operand(instruction_value, 1);

    // Fail for nil, or for a boolean whose payload is zero. Every other tag is truthy.
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
    try self.emitGuardFailure(try self.operand(instruction_value, 2));
}
pub noinline fn emitCheckCompareNumber(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 4);
    try self.emitF64Value(try self.operand(instruction_value, 0));
    try self.emitF64Value(try self.operand(instruction_value, 1));
    try self.emitNumericCondition(try self.conditionOperand(instruction_value, 2));
    try self.body.i32Eqz(self.allocator);
    try self.emitGuardFailure(try self.operand(instruction_value, 3));
}
pub noinline fn emitCheckCompareInteger(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 4);
    try self.emitI32Value(try self.operand(instruction_value, 0));
    try self.emitI32Value(try self.operand(instruction_value, 1));
    try self.emitIntegerCondition(try self.conditionOperand(instruction_value, 2));
    try self.body.i32Eqz(self.allocator);
    try self.emitGuardFailure(try self.operand(instruction_value, 3));
}
pub noinline fn emitCheckCompareInt64(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 4);
    try self.emitI64Value(try self.operand(instruction_value, 0));
    try self.emitI64Value(try self.operand(instruction_value, 1));
    try self.emitInt64Condition(try self.conditionOperand(instruction_value, 2));
    try self.body.i32Eqz(self.allocator);
    try self.emitGuardFailure(try self.operand(instruction_value, 3));
}
pub fn savedPc(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!u32 {
    try self.requireOperandCount(instruction_value, 1);
    const operand_value = try self.operand(instruction_value, 0);
    if (operand_value.kind != .constant)
        return Error.InvalidOperandType;
    return (try self.constant(operand_value.value)).uintValue() orelse Error.InvalidOperandType;
}
pub fn uintConstant(self: anytype, operand_value: snapshot_v1.IrOperand) Error!u32 {
    if (operand_value.kind != .constant)
        return Error.InvalidOperandType;
    return (try self.constant(operand_value.value)).uintValue() orelse Error.InvalidOperandType;
}
pub fn intConstant(self: anytype, operand_value: snapshot_v1.IrOperand) Error!i32 {
    if (operand_value.kind != .constant)
        return Error.InvalidOperandType;
    return (try self.constant(operand_value.value)).intValue() orelse Error.InvalidOperandType;
}
pub fn nonnegativeConstant(self: anytype, operand_value: snapshot_v1.IrOperand) Error!u32 {
    if (operand_value.kind != .constant)
        return Error.InvalidOperandType;
    const value = try self.constant(operand_value.value);
    if (value.uintValue()) |result|
        return result;
    const signed = value.intValue() orelse return Error.InvalidOperandType;
    if (signed < 0)
        return Error.InvalidOperandType;
    return @intCast(signed);
}
pub fn genericIterationAux(self: anytype, operand_value: snapshot_v1.IrOperand) Error!u32 {
    const encoded: u32 = @bitCast(try self.intConstant(operand_value));
    if (encoded & 0x7fff_ff00 != 0)
        return Error.InvalidOperandType;
    const count = encoded & 0xff;
    if (count == 0 or (encoded & 0x8000_0000 != 0 and count != 2))
        return Error.InvalidOperandType;
    return encoded;
}
pub fn sameOperand(_: anytype, lhs: snapshot_v1.IrOperand, rhs: snapshot_v1.IrOperand) bool {
    return lhs.kind == rhs.kind and lhs.value == rhs.value;
}
pub fn bufferAccessWidth(_: anytype, command: snapshot_v1.IrCommand) ?u32 {
    return switch (command) {
        ir_cmd_buffer_readi8, ir_cmd_buffer_readu8, ir_cmd_buffer_writei8 => 1,
        ir_cmd_buffer_readi16, ir_cmd_buffer_readu16, ir_cmd_buffer_writei16 => 2,
        ir_cmd_buffer_readi32,
        ir_cmd_buffer_readf32,
        ir_cmd_buffer_writei32,
        ir_cmd_buffer_writef32,
        => 4,
        ir_cmd_buffer_readf64,
        ir_cmd_buffer_readi64,
        ir_cmd_buffer_writef64,
        ir_cmd_buffer_writei64,
        => 8,
        else => null,
    };
}
pub fn bufferOperationOwnedByRange(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
) Error!bool {
    _ = self.bufferAccessWidth(instruction_value.command) orelse return false;
    if (instruction_value.operand_count < 3)
        return false;
    const pointer = try self.operand(instruction_value, 0);
    const tag = try self.operand(instruction_value, instruction_value.operand_count - 1);
    if (tag.kind != .constant or (try self.constant(tag.value)).tagValue() != lua_tag_buffer or
        try self.loadedPointerRegister(pointer) == null)
        return false;
    return self.plan.isGuardedBufferOperation(instruction_id);
}
pub noinline fn integerCreatePatternAt(self: anytype, check_id: u32) Error!?IntegerCreatePattern {
    if (check_id < 5 or check_id + 2 >= self.function.instruction_count)
        return null;
    const load_tag = try self.instruction(check_id - 5);
    const type_check = try self.instruction(check_id - 4);
    const load_number = try self.instruction(check_id - 3);
    const convert = try self.instruction(check_id - 2);
    const roundtrip = try self.instruction(check_id - 1);
    const check = try self.instruction(check_id);
    const store = try self.instruction(check_id + 1);
    const store_tag = try self.instruction(check_id + 2);
    if (load_tag.command != .load_tag or load_tag.operand_count != 1 or
        type_check.command != .check_tag or type_check.operand_count != 3 or
        load_number.command != .load_double or load_number.operand_count != 1 or
        convert.command != .num_to_int64 or convert.operand_count != 1 or
        roundtrip.command != .int64_to_num or roundtrip.operand_count != 1 or
        check.command != .check_cmp_num or check.operand_count != 4 or
        store.command != .store_int64 or store.operand_count != 2 or
        store_tag.command != .store_tag or store_tag.operand_count != 2)
        return null;

    const source = try self.operand(load_tag, 0);
    const checked = try self.operand(type_check, 0);
    const expected = try self.operand(type_check, 1);
    const type_exit = try self.operand(type_check, 2);
    const loaded = try self.operand(load_number, 0);
    const converted = try self.operand(convert, 0);
    const rounded = try self.operand(roundtrip, 0);
    const lhs = try self.operand(check, 0);
    const rhs = try self.operand(check, 1);
    const condition = try self.operand(check, 2);
    const range_exit = try self.operand(check, 3);
    const destination = try self.operand(store, 0);
    const stored = try self.operand(store, 1);
    const tag_destination = try self.operand(store_tag, 0);
    const tag = try self.operand(store_tag, 1);
    if (source.kind != .vm_reg or !self.sameOperand(source, loaded) or
        checked.kind != .instruction or checked.value != check_id - 5 or
        expected.kind != .constant or (try self.constant(expected.value)).tagValue() != lua_tag_number or
        converted.kind != .instruction or converted.value != check_id - 3 or
        rounded.kind != .instruction or rounded.value != check_id - 2 or
        lhs.kind != .instruction or lhs.value != check_id - 1 or
        rhs.kind != .instruction or rhs.value != check_id - 3 or
        condition.kind != .condition or condition.value != @intFromEnum(snapshot_v1.IrCondition.equal) or
        destination.kind != .vm_reg or !self.sameOperand(destination, tag_destination) or
        stored.kind != .instruction or stored.value != check_id - 2 or
        tag.kind != .constant or (try self.constant(tag.value)).tagValue() != lua_tag_integer)
        return null;
    if (!self.sameOperand(type_exit, range_exit) or
        !try self.guardFailureIsBuiltin(type_exit, "integer", "create"))
        return null;
    return .{
        .check = check_id,
        .finish = check_id + 2,
        .destination = destination.value,
    };
}
pub noinline fn emitIntegerCreate(self: anytype, pattern: IntegerCreatePattern) Error!void {
    const check = try self.instruction(pattern.check);
    try self.emitF64Value(try self.operand(check, 0));
    try self.emitF64Value(try self.operand(check, 1));
    try self.body.f64Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.emitStoreI64(try self.instruction(pattern.check + 1));
    try self.emitStoreTag(pattern.check + 2, try self.instruction(pattern.check + 2));
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, lua_tag_nil);
    try self.body.i32Store(
        self.allocator,
        2,
        pattern.destination * tvalue_size + tvalue_tag_offset,
    );
    try self.body.end(self.allocator);
}

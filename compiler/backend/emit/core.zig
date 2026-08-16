const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");

const Error = model.Error;
const ValueSlot = model.ValueSlot;
const Capture = model.Capture;
const NewClosurePattern = model.NewClosurePattern;
const SetUpvaluePattern = model.SetUpvaluePattern;
const markerCapture = model.markerCapture;
const requireSingleBytecodeBlockRangeFor = model.requireSingleBytecodeBlockRangeFor;
const dupClosurePattern = model.dupClosurePattern;
const lua_state_base_offset = abi.lua_state_base_offset;
const tvalue_size = abi.tvalue_size;
const tvalue_tag_offset = abi.tvalue_tag_offset;
const lua_tag_nil = abi.lua_tag_nil;
const lua_tag_boolean = abi.lua_tag_boolean;
const lua_tag_number = abi.lua_tag_number;
const lua_tag_integer = abi.lua_tag_integer;
const lua_tag_vector = abi.lua_tag_vector;
const lua_tag_string = abi.lua_tag_string;

pub fn instruction(self: anytype, id: u32) Error!snapshot_v1.IrInstruction {
    return self.snapshot.irInstruction(self.function, id);
}
pub fn operand(self: anytype, instruction_value: snapshot_v1.IrInstruction, id: u32) Error!snapshot_v1.IrOperand {
    return self.snapshot.irOperand(instruction_value, id);
}
pub fn constant(self: anytype, id: u32) Error!snapshot_v1.IrConstant {
    return self.snapshot.irConstant(self.function, id);
}
pub fn requireOperandCount(_: anytype, instruction_value: snapshot_v1.IrInstruction, expected: u32) Error!void {
    if (instruction_value.operand_count != expected)
        return Error.InvalidOperandCount;
}
pub fn vmRegisterOffset(self: anytype, operand_value: snapshot_v1.IrOperand, field_offset: u32) Error!u32 {
    return (try self.vmRegisterIndex(operand_value)) * tvalue_size + field_offset;
}
pub fn vmRegisterIndex(self: anytype, operand_value: snapshot_v1.IrOperand) Error!u32 {
    if (operand_value.kind != .vm_reg or operand_value.value >= self.proto.max_stack_size)
        return Error.InvalidOperandType;
    return operand_value.value;
}
pub fn valueOperandEncoding(self: anytype, operand_value: snapshot_v1.IrOperand) Error!u32 {
    if (operand_value.kind == .vm_reg)
        return self.vmRegisterIndex(operand_value);
    if (operand_value.kind != .vm_const or operand_value.value >= self.proto.vm_constant_count or
        operand_value.value >= 0x80000000)
        return Error.InvalidOperandType;
    const value = try self.snapshot.vmConstant(self.proto, operand_value.value);
    switch (value.kind) {
        .nil, .boolean, .number, .integer, .vector, .string => {},
        .table, .closure, .class_shape, .import => return Error.InvalidOperandType,
    }
    return 0x80000000 | operand_value.value;
}
pub noinline fn emitReloadBase(self: anytype) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, lua_state_base_offset);
    try self.body.localSet(self.allocator, self.base_local);
}
pub fn requireSingleBytecodeBlockRange(self: anytype, start: u32, finish: u32) Error!void {
    return requireSingleBytecodeBlockRangeFor(self.snapshot, self.function, start, finish);
}
pub fn requireSingleCompilableBlockRange(self: anytype, start: u32, finish: u32) Error!void {
    var owner: ?u32 = null;
    var block_id: u32 = 0;
    while (block_id < self.function.block_count) : (block_id += 1) {
        const block = try self.snapshot.irBlock(self.function, block_id);
        if (block.isEmpty() or block.finish < start or block.start > finish)
            continue;
        if (owner != null or !block.kind.isCompilable() or block.start > start or block.finish < finish)
            return Error.UnsupportedControlFlow;
        owner = block_id;
    }
    if (owner == null)
        return Error.UnsupportedControlFlow;
}
pub fn requireSingleCallBlockRange(self: anytype, start: u32, finish: u32) Error!void {
    var owner: ?u32 = null;
    var block_id: u32 = 0;
    while (block_id < self.function.block_count) : (block_id += 1) {
        const block = try self.snapshot.irBlock(self.function, block_id);
        if (block.isEmpty() or block.finish < start or block.start > finish)
            continue;
        const supported = block.kind.isCompilable() or
            (block.kind == .fallback and
                ((try self.isFastcallFallbackBlock(block)) or (try self.supportsOrdinaryCallFallback(block))));
        if (owner != null or !supported or block.start > start or block.finish < finish)
            return Error.UnsupportedControlFlow;
        owner = block_id;
    }
    if (owner == null)
        return Error.UnsupportedControlFlow;
}
pub fn loadedTValueRegister(self: anytype, instruction_id: u32) Error!?u32 {
    if (instruction_id >= self.function.instruction_count)
        return Error.InvalidInstructionResult;
    const load = try self.instruction(instruction_id);
    if (load.command != .load_tvalue)
        return null;
    if (load.operand_count != 1 and load.operand_count != 3)
        return Error.InvalidOperandCount;
    const source = try self.vmRegisterIndex(try self.operand(load, 0));
    if (load.operand_count == 3) {
        if (try self.tvalueByteOffset(load, 1) != 0)
            return Error.InvalidOperandType;
        const tag = try self.operand(load, 2);
        if (tag.kind != .constant or (try self.constant(tag.value)).tagValue() == null)
            return Error.InvalidOperandType;
    }
    return source;
}
pub fn initializedClosureValueCapture(self: anytype, address_id: u32, store_id: u32, newclosure_id: u32) Error!?Capture {
    const store = try self.instruction(store_id);
    if (store.command == .store_tvalue) {
        try self.requireOperandCount(store, 2);
        const destination = try self.operand(store, 0);
        const source = try self.operand(store, 1);
        if (destination.kind != .instruction or destination.value != address_id or source.kind != .instruction)
            return Error.InvalidOperandType;
        if (try self.concatPatternContaining(source.value)) |concat| {
            if (source.value != concat.start + 2)
                return Error.InvalidOperandType;
            return .{ .kind = .value, .source = concat.destination };
        }
        if (try self.loadedTValueRegister(source.value)) |source_register|
            return .{ .kind = .value, .source = source_register };
        return null;
    }
    if (store.command != .store_split_tvalue)
        return null;
    try self.requireOperandCount(store, 3);
    const destination = try self.operand(store, 0);
    const tag = try self.operand(store, 1);
    const source = try self.operand(store, 2);
    if (destination.kind != .instruction or destination.value != address_id or
        tag.kind != .constant or (try self.constant(tag.value)).tagValue() != 8 or
        source.kind != .instruction or source.value >= newclosure_id)
        return Error.InvalidOperandType;
    const source_instruction = try self.instruction(source.value);
    if (source_instruction.command != .newclosure)
        return Error.UnsupportedControlFlow;
    const source_pattern = try self.newClosurePattern(source.value);
    if (source_pattern.finish >= newclosure_id - 2)
        return Error.UnsupportedControlFlow;
    return .{ .kind = .value, .source = source_pattern.destination };
}
pub noinline fn newClosurePattern(self: anytype, newclosure_id: u32) Error!NewClosurePattern {
    if (newclosure_id < 2)
        return Error.UnsupportedControlFlow;
    const marker = try self.instruction(newclosure_id - 2);
    const load_env = try self.instruction(newclosure_id - 1);
    const newclosure = try self.instruction(newclosure_id);
    const store_pointer = try self.instruction(newclosure_id + 1);
    const store_tag = try self.instruction(newclosure_id + 2);
    if (marker.command != .set_savedpc or load_env.command != .load_env or
        newclosure.command != .newclosure or store_pointer.command != .store_pointer or
        store_tag.command != .store_tag)
        return Error.UnsupportedControlFlow;
    _ = try self.savedPc(marker);
    try self.requireOperandCount(load_env, 0);
    try self.requireOperandCount(newclosure, 3);
    try self.requireOperandCount(store_pointer, 2);
    try self.requireOperandCount(store_tag, 2);

    const nups_operand = try self.operand(newclosure, 0);
    const env_operand = try self.operand(newclosure, 1);
    const child_index_operand = try self.operand(newclosure, 2);
    if (nups_operand.kind != .constant or env_operand.kind != .instruction or
        env_operand.value != newclosure_id - 1 or child_index_operand.kind != .constant)
        return Error.InvalidOperandType;
    const capture_count = (try self.constant(nups_operand.value)).uintValue() orelse return Error.InvalidOperandType;
    if (capture_count == 0)
        return Error.UnsupportedControlFlow;
    const child_index = (try self.constant(child_index_operand.value)).uintValue() orelse
        return Error.InvalidOperandType;
    const child_proto_id = try self.snapshot.protoChild(self.proto, child_index);
    const child = try self.snapshot.proto(child_proto_id);
    if (child.parent_id != self.proto.id or child.nups != capture_count)
        return Error.UnsupportedControlFlow;

    const pointer_destination = try self.operand(store_pointer, 0);
    const pointer_source = try self.operand(store_pointer, 1);
    const tag_destination = try self.operand(store_tag, 0);
    const tag_source = try self.operand(store_tag, 1);
    if (pointer_source.kind != .instruction or pointer_source.value != newclosure_id or
        tag_destination.kind != .vm_reg or tag_destination.value != pointer_destination.value or
        tag_source.kind != .constant or (try self.constant(tag_source.value)).tagValue() != 8)
        return Error.InvalidOperandType;
    const destination = try self.vmRegisterIndex(pointer_destination);

    var cursor = std.math.add(u32, newclosure_id, 3) catch return Error.ResourceLimit;
    const leading_marker = try self.instruction(cursor);
    if (leading_marker.command == .nop) {
        try self.requireOperandCount(leading_marker, 0);
        cursor = std.math.add(u32, cursor, 1) catch return Error.ResourceLimit;
    }
    const capture_ir_start = cursor;
    var capture_index: u32 = 0;
    while (capture_index < capture_count) : (capture_index += 1) {
        var first = try self.instruction(cursor);
        while (first.command == .nop) {
            try self.requireOperandCount(first, 0);
            cursor = std.math.add(u32, cursor, 1) catch return Error.ResourceLimit;
            first = try self.instruction(cursor);
        }
        if (first.command == .load_tvalue) {
            if (first.operand_count != 1 and first.operand_count != 3)
                return Error.InvalidOperandCount;
            _ = try self.vmRegisterIndex(try self.operand(first, 0));
            if (first.operand_count == 3) {
                if (try self.tvalueByteOffset(first, 1) != 0)
                    return Error.InvalidOperandType;
                const load_tag = try self.operand(first, 2);
                if (load_tag.kind != .constant or (try self.constant(load_tag.value)).tagValue() == null)
                    return Error.InvalidOperandType;
            }
            const address_id = cursor + 1;
            const store_id = cursor + 2;
            const address = try self.instruction(address_id);
            const store = try self.instruction(store_id);
            if (address.command != .get_closure_upval_addr or store.command != .store_tvalue)
                return Error.UnsupportedControlFlow;
            try self.requireOperandCount(address, 2);
            try self.requireOperandCount(store, 2);
            try self.requireClosureCaptureAddress(address, newclosure_id, capture_index);
            try self.requireTValueStore(store, address_id, cursor);
            cursor = store_id + 1;
        } else if (first.command == .findupval) {
            try self.requireOperandCount(first, 1);
            _ = try self.vmRegisterIndex(try self.operand(first, 0));
            const address_id = cursor + 1;
            const pointer_id = cursor + 2;
            const tag_id = cursor + 3;
            const address = try self.instruction(address_id);
            const pointer_store = try self.instruction(pointer_id);
            const tag_store = try self.instruction(tag_id);
            if (address.command != .get_closure_upval_addr or pointer_store.command != .store_pointer or
                tag_store.command != .store_tag)
                return Error.UnsupportedControlFlow;
            try self.requireOperandCount(address, 2);
            try self.requireOperandCount(pointer_store, 2);
            try self.requireOperandCount(tag_store, 2);
            try self.requireClosureCaptureAddress(address, newclosure_id, capture_index);
            try self.requireInstructionStore(pointer_store, address_id, cursor);
            const capture_tag_destination = try self.operand(tag_store, 0);
            const capture_tag_source = try self.operand(tag_store, 1);
            if (capture_tag_destination.kind != .instruction or capture_tag_destination.value != address_id or
                capture_tag_source.kind != .constant or (try self.constant(capture_tag_source.value)).tagValue() != 16)
                return Error.InvalidOperandType;
            cursor = tag_id + 1;
        } else if (first.command == .get_closure_upval_addr) {
            try self.requireOperandCount(first, 2);
            const source_closure = try self.operand(first, 0);
            const source_slot = try self.operand(first, 1);
            if (source_closure.kind == .instruction and source_closure.value == newclosure_id) {
                try self.requireClosureCaptureAddress(first, newclosure_id, capture_index);
                const store_id = cursor + 1;
                if (try self.initializedClosureValueCapture(cursor, store_id, newclosure_id) == null)
                    return Error.UnsupportedControlFlow;
                cursor = store_id + 1;
                continue;
            }
            if (source_closure.kind != .undef or source_closure.value != 0 or
                source_slot.kind != .vm_upvalue or source_slot.value >= self.proto.nups)
                return Error.InvalidOperandType;
            const address_id = cursor + 1;
            const load_id = cursor + 2;
            const store_id = cursor + 3;
            const address = try self.instruction(address_id);
            const load = try self.instruction(load_id);
            const store = try self.instruction(store_id);
            if (address.command != .get_closure_upval_addr or load.command != .load_tvalue or
                store.command != .store_tvalue)
                return Error.UnsupportedControlFlow;
            try self.requireOperandCount(address, 2);
            try self.requireOperandCount(load, 1);
            try self.requireOperandCount(store, 2);
            try self.requireClosureCaptureAddress(address, newclosure_id, capture_index);
            const load_source = try self.operand(load, 0);
            if (load_source.kind != .instruction or load_source.value != cursor)
                return Error.InvalidOperandType;
            try self.requireTValueStore(store, address_id, load_id);
            cursor = store_id + 1;
        } else return Error.UnsupportedControlFlow;
    }

    const possible_gc_marker = try self.instruction(cursor);
    const has_gc_marker = possible_gc_marker.command == .check_gc or possible_gc_marker.command == .nop;
    if (has_gc_marker)
        try self.requireOperandCount(possible_gc_marker, 0)
    else if (possible_gc_marker.command != .capture)
        return Error.UnsupportedControlFlow;
    const marker_start = cursor + @as(u32, @intFromBool(has_gc_marker));
    capture_index = 0;
    while (capture_index < capture_count) : (capture_index += 1) {
        const initialized = try self.initializedCapture(capture_index, capture_ir_start);
        const captured = try markerCapture(self.snapshot, self.function, self.proto, marker_start + capture_index, true);
        if (captured.kind != initialized.kind or captured.source != initialized.source)
            return Error.InvalidOperandType;
    }
    const finish = marker_start + capture_count - 1;
    if (finish >= self.function.instruction_count)
        return Error.UnsupportedControlFlow;
    try self.requireSingleCompilableBlockRange(newclosure_id - 2, finish);
    return .{
        .start = newclosure_id - 2,
        .finish = finish,
        .destination = destination,
        .child_proto_id = child_proto_id,
        .capture_count = capture_count,
        .capture_ir_start = capture_ir_start,
        .marker_start = marker_start,
        .check_gc = possible_gc_marker.command == .check_gc,
    };
}
pub fn requireClosureCaptureAddress(self: anytype, instruction_value: snapshot_v1.IrInstruction, newclosure_id: u32, capture_index: u32) Error!void {
    const closure = try self.operand(instruction_value, 0);
    const slot = try self.operand(instruction_value, 1);
    if (closure.kind != .instruction or closure.value != newclosure_id or
        slot.kind != .vm_upvalue or slot.value != capture_index)
        return Error.InvalidOperandType;
}
pub fn requireInstructionStore(self: anytype, instruction_value: snapshot_v1.IrInstruction, destination_id: u32, source_id: u32) Error!void {
    const destination = try self.operand(instruction_value, 0);
    const source = try self.operand(instruction_value, 1);
    if (destination.kind != .instruction or destination.value != destination_id or
        source.kind != .instruction or source.value != source_id)
        return Error.InvalidOperandType;
}
pub fn requireTValueStore(self: anytype, instruction_value: snapshot_v1.IrInstruction, destination_id: u32, source_id: u32) Error!void {
    return self.requireInstructionStore(instruction_value, destination_id, source_id);
}
pub fn initializedCapture(self: anytype, wanted: u32, capture_ir_start: u32) Error!Capture {
    var cursor = capture_ir_start;
    var index: u32 = 0;
    while (index <= wanted) : (index += 1) {
        var first = try self.instruction(cursor);
        while (first.command == .nop) {
            try self.requireOperandCount(first, 0);
            cursor = std.math.add(u32, cursor, 1) catch return Error.ResourceLimit;
            first = try self.instruction(cursor);
        }
        if (first.command == .get_closure_upval_addr) {
            try self.requireOperandCount(first, 2);
            const closure = try self.operand(first, 0);
            if (closure.kind == .instruction) {
                const capture = (try self.initializedClosureValueCapture(cursor, cursor + 1, closure.value)) orelse
                    return Error.UnsupportedControlFlow;
                if (index == wanted)
                    return capture;
                cursor += 2;
                continue;
            }
        }
        const capture: Capture = if (first.command == .load_tvalue)
            .{ .kind = .value, .source = (try self.operand(first, 0)).value }
        else if (first.command == .findupval)
            .{ .kind = .reference, .source = (try self.operand(first, 0)).value }
        else if (first.command == .get_closure_upval_addr)
            .{ .kind = .upvalue, .source = (try self.operand(first, 1)).value }
        else
            return Error.UnsupportedControlFlow;
        if (index == wanted)
            return capture;
        cursor += if (capture.kind == .value) 3 else 4;
    }
    unreachable;
}
pub noinline fn newClosurePatternContaining(self: anytype, instruction_id: u32) Error!?NewClosurePattern {
    var candidate: u32 = 0;
    while (candidate < self.function.instruction_count) : (candidate += 1) {
        if ((try self.instruction(candidate)).command != .newclosure)
            continue;
        const pattern = self.newClosurePattern(candidate) catch |err| switch (err) {
            Error.UnsupportedControlFlow,
            Error.InvalidOperandCount,
            Error.InvalidOperandType,
            Error.InvalidInstructionResult,
            Error.InvalidBlockTermination,
            => continue,
            else => return err,
        };
        if (instruction_id >= pattern.start and instruction_id <= pattern.finish)
            return pattern;
    }
    return null;
}
pub fn isDupClosureCapture(self: anytype, instruction_id: u32) Error!bool {
    var candidate: u32 = 0;
    while (candidate < instruction_id) : (candidate += 1) {
        if ((try self.instruction(candidate)).command != .fallback_dupclosure)
            continue;
        const pattern = dupClosurePattern(self.snapshot, self.function, self.proto, candidate) catch |err| switch (err) {
            Error.UnsupportedControlFlow,
            Error.InvalidOperandCount,
            Error.InvalidOperandType,
            Error.InvalidInstructionResult,
            Error.InvalidBlockTermination,
            => continue,
            else => return err,
        };
        switch (pattern) {
            .closed => {},
            .captured => |captured| {
                const finish = std.math.add(u32, captured.marker_start, captured.capture_count) catch
                    return Error.ResourceLimit;
                if (instruction_id >= captured.marker_start and instruction_id < finish)
                    return true;
            },
        }
    }
    return false;
}
pub noinline fn setUpvaluePattern(self: anytype, instruction_id: u32) Error!SetUpvaluePattern {
    if (instruction_id == 0)
        return Error.UnsupportedControlFlow;
    try self.requireSingleCompilableBlockRange(instruction_id - 1, instruction_id);
    const load = try self.instruction(instruction_id - 1);
    const set = try self.instruction(instruction_id);
    if (load.command != .load_tvalue or set.command != .set_upvalue)
        return Error.UnsupportedControlFlow;
    if (load.operand_count != 1 and load.operand_count != 3)
        return Error.InvalidOperandCount;
    try self.requireOperandCount(set, 3);
    const source_register = try self.vmRegisterIndex(try self.operand(load, 0));
    if (load.operand_count == 3) {
        if (try self.tvalueByteOffset(load, 1) != 0)
            return Error.InvalidOperandType;
        const load_tag = try self.operand(load, 2);
        if (load_tag.kind != .constant or (try self.constant(load_tag.value)).tagValue() == null)
            return Error.InvalidOperandType;
    }
    const upvalue = try self.operand(set, 0);
    const value = try self.operand(set, 1);
    const tag = try self.operand(set, 2);
    if (upvalue.kind != .vm_upvalue or upvalue.value >= self.proto.nups or
        value.kind != .instruction or value.value != instruction_id - 1)
        return Error.InvalidOperandType;
    if (tag.kind == .constant) {
        if ((try self.constant(tag.value)).tagValue() == null)
            return Error.InvalidOperandType;
    } else if (tag.kind != .undef or tag.value != 0)
        return Error.InvalidOperandType;
    return .{ .upvalue_index = upvalue.value, .source_register = source_register };
}
pub noinline fn emitCopyTValueRegisters(self: anytype, destination: u32, source: u32) Error!void {
    try self.emitCopyTValueRegisterToAddress(destination, 0, source);
}
pub noinline fn emitStoreTValueOperand(self: anytype, destination: u32, source: snapshot_v1.IrOperand) Error!void {
    if (destination >= self.proto.max_stack_size)
        return Error.InvalidOperandType;
    const destination_offset = destination * tvalue_size;
    try self.body.localGet(self.allocator, self.base_local);
    try self.emitTValuePart(source, false);
    try self.body.i64Store(self.allocator, 3, destination_offset);
    try self.body.localGet(self.allocator, self.base_local);
    try self.emitTValuePart(source, true);
    try self.body.i64Store(self.allocator, 3, destination_offset + 8);
}
pub noinline fn emitCopyTValueRegisterToAddress(
    self: anytype,
    destination: u32,
    destination_byte_offset: u32,
    source: u32,
) Error!void {
    const destination_offset = destination * tvalue_size;
    const source_offset = source * tvalue_size;
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i64Load(self.allocator, 3, source_offset);
    try self.body.i64Store(self.allocator, 3, destination_offset + destination_byte_offset);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i64Load(self.allocator, 3, source_offset + 8);
    try self.body.i64Store(self.allocator, 3, destination_offset + destination_byte_offset + 8);
}
pub noinline fn emitStoreSplitTValue(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    if (instruction_value.operand_count != 3 and instruction_value.operand_count != 4)
        return Error.InvalidOperandCount;
    const destination_operand = try self.operand(instruction_value, 0);
    const destination = if (destination_operand.kind == .vm_reg)
        try self.vmRegisterIndex(destination_operand)
    else
        null;
    const tag = try self.operand(instruction_value, 1);
    const source = try self.operand(instruction_value, 2);
    if (tag.kind != .constant)
        return Error.InvalidOperandType;
    const tag_value = (try self.constant(tag.value)).tagValue() orelse return Error.InvalidOperandType;

    if (source.kind == .instruction and source.value < self.function.instruction_count and
        (try self.instruction(source.value)).command == .newclosure)
    {
        if (destination == null or instruction_value.operand_count != 3 or tag_value != 8)
            return Error.UnsupportedControlFlow;
        const pattern = try self.newClosurePattern(source.value);
        try self.emitCopyTValueRegisters(destination.?, pattern.destination);
        return;
    }

    const address_offset = if (instruction_value.operand_count == 4)
        try self.tvalueByteOffset(instruction_value, 3)
    else
        0;

    // A numeric-string builtin argument enters the optimized numeric arm through an
    // AOT-owned coercion.  Numeric consumers use the converted instruction result,
    // while TValue materialization must preserve the untouched source value.
    if (tag_value == lua_tag_number and source.kind == .instruction and
        source.value < self.builtin_number_sources.len and destination != null)
    {
        const source_register = self.builtin_number_sources[source.value];
        if (source_register != std.math.maxInt(u32)) {
            try self.emitCopyTValueRegisterToAddress(destination.?, address_offset, source_register);
            return;
        }
    }

    if (destination_operand.kind == .instruction) {
        if (destination_operand.value >= self.function.instruction_count)
            return Error.UnsupportedControlFlow;
        const producer = try self.instruction(destination_operand.value);
        if (producer.command == abi.ir_cmd_get_arr_addr) {
            if (!try self.plan.validateArrayAddressUse(
                self.snapshot,
                self.function,
                destination_operand.value,
                instruction_id,
            ))
                return Error.UnsupportedControlFlow;
        } else if (producer.command == abi.ir_cmd_get_hash_node_addr or
            producer.command == abi.ir_cmd_get_slot_node_addr)
        {
            if (address_offset != 0 or
                !try self.plan.validateNodeUse(
                    self.snapshot,
                    self.function,
                    destination_operand.value,
                    instruction_id,
                ))
                return Error.UnsupportedControlFlow;
        } else {
            return Error.UnsupportedControlFlow;
        }
    } else if (destination_operand.kind != .vm_reg) return Error.InvalidOperandType;
    const value_offset = if (destination != null)
        try self.vmRegisterOffset(destination_operand, address_offset)
    else
        address_offset;
    const tag_offset = if (destination != null)
        try self.vmRegisterOffset(destination_operand, address_offset + tvalue_tag_offset)
    else
        address_offset + tvalue_tag_offset;

    try self.emitTValueAddress(destination_operand);
    try self.emitI32Value(tag);
    try self.body.i32Store(self.allocator, 2, tag_offset);

    switch (tag_value) {
        lua_tag_nil => {},
        lua_tag_boolean => {
            try self.emitTValueAddress(destination_operand);
            try self.emitI32Value(source);
            try self.body.i32Store(self.allocator, 2, value_offset);
        },
        lua_tag_number => {
            try self.emitTValueAddress(destination_operand);
            try self.emitF64Value(source);
            try self.body.f64Store(self.allocator, 3, value_offset);
        },
        lua_tag_integer => {
            try self.emitTValueAddress(destination_operand);
            try self.emitI64Value(source);
            try self.body.i64Store(self.allocator, 3, value_offset);
        },
        lua_tag_string, 7, 8, 9, 10, 11, 12 => {
            try self.emitTValueAddress(destination_operand);
            try self.emitPointerValue(source);
            try self.body.i32Store(self.allocator, 2, value_offset);
        },
        else => return Error.UnsupportedOperand,
    }
}
pub noinline fn emitI32Value(self: anytype, operand_value: snapshot_v1.IrOperand) Error!void {
    switch (operand_value.kind) {
        .constant => {
            const value = try self.constant(operand_value.value);
            const integer: i32 = switch (value.kind) {
                .int => value.intValue().?,
                .uint => @bitCast(value.uintValue().?),
                .tag => value.tagValue().?,
                else => return Error.InvalidOperandType,
            };
            try self.body.i32Const(self.allocator, integer);
        },
        .instruction => {
            if (operand_value.value >= self.slots.len)
                return Error.InvalidInstructionResult;
            const slot = self.slots[operand_value.value];
            if (slot.shape != .i32)
                return Error.InvalidInstructionResult;
            try self.body.localGet(self.allocator, slot.first);
        },
        else => return Error.UnsupportedOperand,
    }
}
pub noinline fn emitPointerValue(self: anytype, operand_value: snapshot_v1.IrOperand) Error!void {
    switch (operand_value.kind) {
        .constant => {
            const value = try self.constant(operand_value.value);
            const integer = value.intValue() orelse return Error.InvalidOperandType;
            if (integer != 0)
                return Error.InvalidOperandType;
            try self.body.i32Const(self.allocator, 0);
        },
        .instruction => {
            if (operand_value.value >= self.slots.len)
                return Error.InvalidInstructionResult;
            const slot = self.slots[operand_value.value];
            if (slot.shape != .pointer)
                return Error.InvalidInstructionResult;
            try self.body.localGet(self.allocator, slot.first);
        },
        else => return Error.UnsupportedOperand,
    }
}
pub fn vmConstantTag(self: anytype, operand_value: snapshot_v1.IrOperand) Error!i32 {
    if (operand_value.kind != .vm_const)
        return Error.InvalidOperandType;
    const value = try self.snapshot.vmConstant(self.proto, operand_value.value);
    return switch (value.kind) {
        .nil => lua_tag_nil,
        .boolean => lua_tag_boolean,
        .number => lua_tag_number,
        .integer => lua_tag_integer,
        .vector => @intCast(lua_tag_vector),
        .string => lua_tag_string,
        .table => 7,
        .import, .closure, .class_shape => return Error.UnsupportedOperand,
    };
}

const VmConstantParts = struct {
    low: u64,
    high: u64,
};
pub fn vmConstantParts(self: anytype, operand_value: snapshot_v1.IrOperand) Error!VmConstantParts {
    if (operand_value.kind != .vm_const)
        return Error.InvalidOperandType;
    const value = try self.snapshot.vmConstant(self.proto, operand_value.value);
    const tag: u64 = @intCast(try self.vmConstantTag(operand_value));
    const low: u64 = switch (value.kind) {
        .nil => 0,
        .boolean => value.payload0,
        .number, .integer => value.bits0,
        .vector => @as(u64, value.payload0) | (@as(u64, value.payload1) << 32),
        // The snapshot deliberately contains stable IDs instead of runtime GC pointers.
        .string, .import, .table, .closure, .class_shape => return Error.UnsupportedOperand,
    };
    const extra: u64 = switch (value.kind) {
        .vector => value.payload2,
        else => 0,
    };
    return .{ .low = low, .high = extra | (tag << 32) };
}
pub noinline fn emitTValueAddress(self: anytype, operand_value: snapshot_v1.IrOperand) Error!void {
    switch (operand_value.kind) {
        .vm_reg => {
            _ = try self.vmRegisterIndex(operand_value);
            try self.body.localGet(self.allocator, self.base_local);
        },
        .vm_const => try self.emitVmConstantAddress(operand_value),
        .instruction => try self.emitPointerValue(operand_value),
        else => return Error.UnsupportedOperand,
    }
}
pub noinline fn emitVmConstantAddress(self: anytype, operand_value: snapshot_v1.IrOperand) Error!void {
    if (operand_value.kind != .vm_const or operand_value.value >= self.proto.vm_constant_count)
        return Error.InvalidOperandType;
    const value = try self.snapshot.vmConstant(self.proto, operand_value.value);
    switch (value.kind) {
        .nil, .boolean, .number, .vector, .string, .integer, .table => {},
        .import, .closure, .class_shape => return Error.UnsupportedOperand,
    }

    // The pinned layout digest makes the active Proto constant array part of the AOT ABI.
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_func_offset);
    try self.body.i32Load(self.allocator, 2, 0);
    try self.body.i32Load(self.allocator, 2, abi.closure_l_proto_offset);
    try self.body.i32Load(self.allocator, 2, abi.proto_constants_offset);
    const byte_offset = std.math.mul(u32, operand_value.value, tvalue_size) catch
        return Error.ResourceLimit;
    try self.body.i32Const(self.allocator, @intCast(byte_offset));
    try self.body.opcode(self.allocator, 0x6a); // i32.add
}
pub fn tvalueByteOffset(self: anytype, instruction_value: snapshot_v1.IrInstruction, operand_index: u32) Error!u32 {
    const offset_operand = try self.operand(instruction_value, operand_index);
    if (offset_operand.kind != .constant)
        return Error.InvalidOperandType;
    const offset = (try self.constant(offset_operand.value)).intValue() orelse return Error.InvalidOperandType;
    if (offset < 0 or @mod(offset, 4) != 0 or offset > 4092)
        return Error.InvalidOperandType;
    return @intCast(offset);
}
pub noinline fn emitI64Value(self: anytype, operand_value: snapshot_v1.IrOperand) Error!void {
    switch (operand_value.kind) {
        .constant => {
            const value = try self.constant(operand_value.value);
            try self.body.i64Const(self.allocator, value.int64Value() orelse return Error.InvalidOperandType);
        },
        .instruction => {
            if (operand_value.value >= self.slots.len)
                return Error.InvalidInstructionResult;
            const slot = self.slots[operand_value.value];
            if (slot.shape != .i64)
                return Error.InvalidInstructionResult;
            try self.body.localGet(self.allocator, slot.first);
        },
        else => return Error.UnsupportedOperand,
    }
}
pub noinline fn emitF32Value(self: anytype, operand_value: snapshot_v1.IrOperand) Error!void {
    switch (operand_value.kind) {
        .constant => {
            const value = try self.constant(operand_value.value);
            try self.body.f32Const(self.allocator, @floatCast(value.doubleValue() orelse return Error.InvalidOperandType));
        },
        .instruction => {
            if (operand_value.value >= self.slots.len)
                return Error.InvalidInstructionResult;
            const slot = self.slots[operand_value.value];
            if (slot.shape != .f32)
                return Error.InvalidInstructionResult;
            try self.body.localGet(self.allocator, slot.first);
        },
        else => return Error.UnsupportedOperand,
    }
}
pub noinline fn emitF64Value(self: anytype, operand_value: snapshot_v1.IrOperand) Error!void {
    switch (operand_value.kind) {
        .constant => {
            const value = try self.constant(operand_value.value);
            try self.body.f64Const(self.allocator, value.doubleValue() orelse return Error.InvalidOperandType);
        },
        .instruction => {
            if (operand_value.value >= self.slots.len)
                return Error.InvalidInstructionResult;
            const slot = self.slots[operand_value.value];
            if (slot.shape != .f64)
                return Error.InvalidInstructionResult;
            try self.body.localGet(self.allocator, slot.first);
        },
        else => return Error.UnsupportedOperand,
    }
}
pub noinline fn emitTagValue(self: anytype, operand_value: snapshot_v1.IrOperand) Error!void {
    if (operand_value.kind == .vm_reg) {
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Load(self.allocator, 2, try self.vmRegisterOffset(operand_value, tvalue_tag_offset));
    } else {
        try self.emitI32Value(operand_value);
    }
}
pub fn tvalueSlot(self: anytype, operand_value: snapshot_v1.IrOperand) Error!ValueSlot {
    if (operand_value.kind != .instruction or operand_value.value >= self.slots.len)
        return Error.InvalidOperandType;
    const slot = self.slots[operand_value.value];
    if (slot.shape != .tvalue)
        return Error.InvalidInstructionResult;
    return slot;
}
pub noinline fn emitTValuePart(self: anytype, operand_value: snapshot_v1.IrOperand, high: bool) Error!void {
    switch (operand_value.kind) {
        .vm_reg => {
            try self.body.localGet(self.allocator, self.base_local);
            const offset = try self.vmRegisterOffset(operand_value, if (high) 8 else 0);
            try self.body.i64Load(self.allocator, 3, offset);
        },
        .instruction => {
            const slot = try self.tvalueSlot(operand_value);
            try self.body.localGet(self.allocator, if (high) slot.second else slot.first);
        },
        else => return Error.UnsupportedOperand,
    }
}
pub noinline fn emitTValueTag(self: anytype, operand_value: snapshot_v1.IrOperand) Error!void {
    if (operand_value.kind == .vm_reg) {
        try self.emitTagValue(operand_value);
        return;
    }

    try self.emitTValuePart(operand_value, true);
    try self.body.i64Const(self.allocator, 32);
    try self.body.opcode(self.allocator, 0x88); // i64.shr_u
    try self.body.opcode(self.allocator, 0xa7); // i32.wrap_i64
}
pub noinline fn emitTValuePayloadI32(self: anytype, operand_value: snapshot_v1.IrOperand) Error!void {
    if (operand_value.kind == .vm_reg) {
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Load(self.allocator, 2, try self.vmRegisterOffset(operand_value, 0));
        return;
    }

    try self.emitTValuePart(operand_value, false);
    try self.body.opcode(self.allocator, 0xa7); // i32.wrap_i64
}
pub noinline fn emitTValueTruthy(self: anytype, operand_value: snapshot_v1.IrOperand) Error!void {
    try self.emitTValueTag(operand_value);
    try self.body.i32Const(self.allocator, lua_tag_nil);
    try self.body.i32Ne(self.allocator);

    try self.emitTValueTag(operand_value);
    try self.body.i32Const(self.allocator, lua_tag_boolean);
    try self.body.i32Ne(self.allocator);
    try self.emitTValuePayloadI32(operand_value);
    try self.body.i32Eqz(self.allocator);
    try self.body.i32Eqz(self.allocator);
    try self.body.opcode(self.allocator, 0x72); // i32.or
    try self.body.opcode(self.allocator, 0x71); // i32.and
}
pub fn requireCompiledTarget(self: anytype, operand_value: snapshot_v1.IrOperand) Error!u32 {
    if (operand_value.kind != .block)
        return Error.InvalidOperandType;
    const target = try self.snapshot.irBlock(self.function, operand_value.value);
    if (!target.kind.isCompilable() or target.isEmpty())
        return Error.UnsupportedControlFlow;
    return operand_value.value;
}
pub fn requireDispatchTarget(self: anytype, operand_value: snapshot_v1.IrOperand) Error!u32 {
    if (operand_value.kind != .block)
        return Error.InvalidOperandType;
    const target = try self.snapshot.irBlock(self.function, operand_value.value);
    if (target.isEmpty() or
        (!target.kind.isCompilable() and
            (target.kind != .fallback or !try self.supportsFallback(target))))
        return Error.UnsupportedControlFlow;
    return operand_value.value;
}

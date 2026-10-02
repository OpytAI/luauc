const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");
const admission = @import("luauc_backend_admission");
const diagnostics = @import("luauc_backend_diagnostics");

const Error = model.Error;
const ValueSlot = model.ValueSlot;
const Capture = model.Capture;
const NewClosurePattern = model.NewClosurePattern;
const SetUpvaluePattern = model.SetUpvaluePattern;
const markerCapture = model.markerCapture;
const requireSingleBytecodeBlockRangeFor = model.requireSingleBytecodeBlockRangeFor;
const lua_state_base_offset = abi.lua_state_base_offset;
const tvalue_size = abi.tvalue_size;
const tvalue_tag_offset = abi.tvalue_tag_offset;
const lua_tag_nil = abi.lua_tag_nil;
const lua_tag_boolean = abi.lua_tag_boolean;
const lua_tag_number = abi.lua_tag_number;
const lua_tag_integer = abi.lua_tag_integer;
const lua_tag_vector = abi.lua_tag_vector;
const lua_tag_string = abi.lua_tag_string;
const lua_tag_table = abi.lua_tag_table;

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
pub noinline fn emitCacheConstantArray(self: anytype) Error!void {
    // Proto.k is stable for this activation. One walk serves every constant slot.
    // A mismatched frame leaves the local zero and constant users take their helper.
    const count = self.proto.vm_constant_count;
    if (count == 0)
        return;
    const count_i32 = std.math.cast(i32, count) orelse return Error.ResourceLimit;
    const function_id = std.math.cast(i32, self.planned_function_id) orelse return Error.ResourceLimit;
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_func_offset);
    try self.body.i32Load(self.allocator, 2, 0);
    try self.body.localTee(self.allocator, self.call_meta_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load8U(self.allocator, 0, abi.closure_is_c_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.closure_l_proto_offset);
    try self.body.localTee(self.allocator, self.call_meta_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.proto_execdata_offset);
    try self.body.localTee(self.allocator, self.call_aux_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Load(self.allocator, 2, abi.proto_function_id_offset);
    try self.body.i32Const(self.allocator, function_id);
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.proto_sizek_offset);
    try self.body.i32Const(self.allocator, count_i32);
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.proto_constants_offset);
    try self.body.localSet(self.allocator, self.constant_array_local);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}
pub fn requireSingleBytecodeBlockRange(self: anytype, start: u32, finish: u32) Error!void {
    return requireSingleBytecodeBlockRangeFor(self.snapshot, self.function, start, finish);
}
pub fn requireSingleCompilableBlockRange(self: anytype, start: u32, finish: u32) Error!void {
    const start_block = self.plan.instructionBlock(start) orelse return Error.UnsupportedControlFlow;
    const finish_block = self.plan.instructionBlock(finish) orelse return Error.UnsupportedControlFlow;
    if (start_block != finish_block)
        return Error.UnsupportedControlFlow;
    const block = try self.snapshot.irBlock(self.function, start_block);
    if (block.isEmpty() or !block.kind.isCompilable() or block.start > start or block.finish < finish)
        return Error.UnsupportedControlFlow;
}
pub fn requireSingleCallBlockRange(self: anytype, start: u32, finish: u32) Error!void {
    const owner_id = self.plan.instructionBlock(start) orelse return Error.UnsupportedControlFlow;
    const finish_id = self.plan.instructionBlock(finish) orelse return Error.UnsupportedControlFlow;
    if (owner_id != finish_id)
        return Error.UnsupportedControlFlow;
    const block = try self.snapshot.irBlock(self.function, owner_id);
    const supported = block.kind.isCompilable() or
        (block.kind == .fallback and
            ((try self.isFastcallFallbackBlock(block)) or (try self.supportsOrdinaryCallFallback(block))));
    if (block.isEmpty() or !supported or block.start > start or block.finish < finish)
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
fn liveCapturedRegister(self: anytype, source: snapshot_v1.IrOperand, store_id: u32) Error!?u32 {
    if (source.kind != .instruction or source.value >= store_id)
        return null;
    const produced = try self.instruction(source.value);
    const double_register: ?u32 = if (produced.command == .load_double and produced.operand_count == 1) blk: {
        const reg_operand = try self.operand(produced, 0);
        if (reg_operand.kind != .vm_reg)
            break :blk null;
        break :blk self.vmRegisterIndex(reg_operand) catch null;
    } else null;
    const register: ?u32 = if (try self.tableRegisterForPointer(source.value)) |found|
        found
    else if (produced.command == .load_tvalue)
        try self.loadedTValueRegister(source.value)
    else if (double_register) |found|
        found
    else if (produced.command == abi.ir_cmd_new_table)
        if (try self.tableAllocationPatternAt(source.value)) |allocation|
            if (allocation.start == source.value) allocation.destination else null
        else
            null
    else
        null;
    const held = register orelse return null;
    var gap = source.value + 1;
    if (produced.command == abi.ir_cmd_new_table) {
        const allocation = (try self.tableAllocationPatternAt(source.value)) orelse return null;
        gap = allocation.finish + 1;
    } else if (produced.command == abi.ir_cmd_dup_table and source.value != 0) {
        if (try self.dupTablePatternAt(source.value - 1)) |clone|
            gap = clone.finish + 1;
    }
    if (gap > store_id)
        return null;
    while (gap < store_id) : (gap += 1) {
        if (try self.instructionWritesRegister(gap, held))
            return null;
    }
    return held;
}
fn publishedRegisterOf(self: anytype, store: snapshot_v1.IrInstruction, source_id: u32) Error!?u32 {
    const stored_index: u32 = if (store.command == .store_tvalue and store.operand_count == 2)
        1
    else if (store.command == .store_split_tvalue and (store.operand_count == 3 or store.operand_count == 4))
        2
    else
        return null;
    const destination = try self.operand(store, 0);
    const stored = try self.operand(store, stored_index);
    if (destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
        stored.kind != .instruction or stored.value != source_id)
        return null;
    return self.vmRegisterIndex(destination) catch null;
}
fn publishedCapturedRegister(self: anytype, source_id: u32, consumer_id: u32) Error!?u32 {
    const owner = (try self.compilableOwnerBlock(consumer_id)) orelse return null;
    if (source_id < owner.start or source_id >= consumer_id or consumer_id > owner.finish)
        return null;
    var publication: ?struct { at: u32, register: u32 } = null;
    var instruction_id = source_id + 1;
    while (instruction_id < consumer_id) : (instruction_id += 1) {
        const register = (try publishedRegisterOf(self, try self.instruction(instruction_id), source_id)) orelse continue;
        publication = .{ .at = instruction_id, .register = register };
    }
    const published = publication orelse return null;
    var cursor = published.at + 1;
    while (cursor < consumer_id) : (cursor += 1)
        if (try self.instructionWritesRegister(cursor, published.register))
            return null;
    return published.register;
}
pub fn initializedClosureValueCapture(self: anytype, address_id: u32, store_id: u32, newclosure_id: u32) Error!?Capture {
    const store = try self.instruction(store_id);
    if (store.command == .store_tvalue) {
        try self.requireOperandCount(store, 2);
        const destination = try self.operand(store, 0);
        const source = try self.operand(store, 1);
        if (destination.kind != .instruction or destination.value != address_id or source.kind != .instruction) {
            var text: [64]u8 = undefined;
            const rendered = std.fmt.bufPrint(&text, "ncl stv {d} {d}", .{
                @intFromEnum(destination.kind),
                @intFromEnum(source.kind),
            }) catch "ncl stv";
            diagnostics.trace(rendered);
            return Error.InvalidOperandType;
        }
        if (self.plan.clusterAt(source.value)) |cluster| {
            if (cluster.kind == .concat) {
                const concat = (try self.concatPatternAt(cluster.at)) orelse return Error.InvalidOperandType;
                if (source.value != concat.start + 2)
                    return Error.InvalidOperandType;
                return .{ .kind = .value, .source = concat.destination };
            }
        }
        if (try self.loadedTValueRegister(source.value)) |source_register|
            return .{ .kind = .value, .source = source_register };
        const source_instruction = try self.instruction(source.value);
        if (source_instruction.command == .get_upvalue and source.value + 1 < store_id) {
            const published = try self.instruction(source.value + 1);
            if (published.command == .store_tvalue and published.operand_count == 2) {
                const published_dest = try self.operand(published, 0);
                const published_source = try self.operand(published, 1);
                if (published_dest.kind == .vm_reg and published_dest.value < self.proto.max_stack_size and
                    published_source.kind == .instruction and published_source.value == source.value)
                    return .{ .kind = .value, .source = published_dest.value };
            }
        }
        // Const-prop forwards the capture onto the value that was stored into the local.
        if (try publishedCapturedRegister(self, source.value, store_id)) |register|
            return .{ .kind = .value, .source = register };
        const produced_cmd: u32 = @intFromEnum(source_instruction.command);
        var detail: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&detail, "ncl stv nil c{d}", .{produced_cmd}) catch "ncl stv nil";
        diagnostics.trace(text);
        return null;
    }
    if (store.command != .store_split_tvalue)
        return null;
    try self.requireOperandCount(store, 3);
    const destination = try self.operand(store, 0);
    const tag = try self.operand(store, 1);
    const source = try self.operand(store, 2);
    if (destination.kind != .instruction or tag.kind != .constant or source.kind != .instruction) {
        var text: [72]u8 = undefined;
        const rendered = std.fmt.bufPrint(&text, "ncl spl {d} {d} {d}", .{
            @intFromEnum(destination.kind),
            @intFromEnum(tag.kind),
            @intFromEnum(source.kind),
        }) catch "ncl spl";
        diagnostics.trace(rendered);
        return Error.InvalidOperandType;
    }
    // The capture's own LOAD_TVALUE is after NEWCLOSURE. It still names the source register.
    if (destination.value != address_id or source.value >= newclosure_id) {
        const produced = try self.instruction(source.value);
        if (destination.value == address_id and produced.command == .load_tvalue) {
            const reg = self.vmRegisterIndex(try self.operand(produced, 0)) catch {
                diagnostics.trace("ncl late");
                return Error.InvalidOperandType;
            };
            if ((try self.constant(tag.value)).tagValue() == null) {
                diagnostics.trace("ncl spl tag");
                return Error.InvalidOperandType;
            }
            return .{ .kind = .value, .source = reg };
        }
        // Const-prop forwards a value capture of this closure to the NEWCLOSURE
        // instruction. The helper publishes that register before it reads the capture.
        if (destination.value == address_id and source.value == newclosure_id and
            produced.command == .newclosure and (try self.constant(tag.value)).tagValue() == 8)
        {
            const published_id = std.math.add(u32, newclosure_id, 1) catch return Error.ResourceLimit;
            if (published_id >= self.function.instruction_count) {
                diagnostics.trace("ncl pub lim");
                return Error.UnsupportedControlFlow;
            }
            const published = try self.instruction(published_id);
            if (published.command != .store_pointer or published.operand_count != 2) {
                diagnostics.trace("ncl self pub");
                return Error.InvalidOperandType;
            }
            const published_value = try self.operand(published, 1);
            if (published_value.kind != .instruction or published_value.value != newclosure_id) {
                diagnostics.trace("ncl self pub");
                return Error.InvalidOperandType;
            }
            const register = self.vmRegisterIndex(try self.operand(published, 0)) catch {
                diagnostics.trace("ncl self reg");
                return Error.InvalidOperandType;
            };
            return .{ .kind = .value, .source = register };
        }
        var text: [80]u8 = undefined;
        const rendered = std.fmt.bufPrint(&text, "ncl spl d{d} a{d} s{d} n{d} c{d}", .{
            destination.value,
            address_id,
            source.value,
            newclosure_id,
            @intFromEnum(produced.command),
        }) catch "ncl spl";
        diagnostics.trace(rendered);
        return Error.InvalidOperandType;
    }
    const tag_value = (try self.constant(tag.value)).tagValue() orelse {
        diagnostics.trace("ncl spl tag");
        return Error.InvalidOperandType;
    };
    if (tag_value == 8) {
        const source_instruction = try self.instruction(source.value);
        if (source_instruction.command == .newclosure) {
            const source_pattern = try self.newClosurePattern(source.value);
            if (source_pattern.finish >= newclosure_id - 2) {
                diagnostics.trace("ncl nest");
                return Error.UnsupportedControlFlow;
            }
            return .{ .kind = .value, .source = source_pattern.destination };
        }
    } else if (tag_value == lua_tag_number) {
        // A published store wins. A plain register load still names that slot.
        if (try self.compilableOwnerBlock(store_id)) |owner| {
            if (try self.publishedNumberPayloadRegister(owner, source, store_id)) |register|
                return .{ .kind = .value, .source = register };
        }
    }
    // Const-prop splits a value capture into the tag and the earlier pointer.
    // The register still holds that TValue when nothing after the load stores it.
    if (try liveCapturedRegister(self, source, store_id)) |register|
        return .{ .kind = .value, .source = register };
    const produced_cmd: u32 = @intFromEnum((try self.instruction(source.value)).command);
    var detail: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&detail, "ncl gco {d} c{d}", .{ tag_value, produced_cmd }) catch "ncl gco";
    diagnostics.trace(text);
    return Error.UnsupportedControlFlow;
}
pub noinline fn newClosurePattern(self: anytype, newclosure_id: u32) Error!NewClosurePattern {
    if (newclosure_id < 2) {
        diagnostics.trace("ncl id");
        return Error.UnsupportedControlFlow;
    }
    const marker = try self.instruction(newclosure_id - 2);
    const load_env = try self.instruction(newclosure_id - 1);
    const newclosure = try self.instruction(newclosure_id);
    const store_pointer = try self.instruction(newclosure_id + 1);
    // Const-prop kills STORE_TAG when the register is already a function.
    const store_tag = try self.instruction(newclosure_id + 2);
    const tag_killed = store_tag.command == .nop;
    if (marker.command != .set_savedpc or load_env.command != .load_env or
        newclosure.command != .newclosure or store_pointer.command != .store_pointer or
        (store_tag.command != .store_tag and !tag_killed))
    {
        var detail: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&detail, "ncl pre {d} {d} {d} {d} {d}", .{
            @intFromEnum(marker.command),
            @intFromEnum(load_env.command),
            @intFromEnum(newclosure.command),
            @intFromEnum(store_pointer.command),
            @intFromEnum(store_tag.command),
        }) catch "ncl pre";
        diagnostics.trace(text);
        return Error.UnsupportedControlFlow;
    }
    _ = self.savedPc(marker) catch |err| {
        diagnostics.trace("ncl pc");
        return err;
    };
    try self.requireOperandCount(load_env, 0);
    try self.requireOperandCount(newclosure, 3);
    try self.requireOperandCount(store_pointer, 2);
    if (!tag_killed)
        try self.requireOperandCount(store_tag, 2);

    const nups_operand = try self.operand(newclosure, 0);
    const env_operand = try self.operand(newclosure, 1);
    const child_index_operand = try self.operand(newclosure, 2);
    if (nups_operand.kind != .constant or env_operand.kind != .instruction or
        env_operand.value != newclosure_id - 1 or child_index_operand.kind != .constant)
    {
        var text: [80]u8 = undefined;
        const rendered = std.fmt.bufPrint(&text, "ncl ops {d} {d} {d}", .{
            @intFromEnum(nups_operand.kind),
            @intFromEnum(env_operand.kind),
            @intFromEnum(child_index_operand.kind),
        }) catch "ncl ops";
        diagnostics.trace(rendered);
        return Error.InvalidOperandType;
    }
    const capture_count = (try self.constant(nups_operand.value)).uintValue() orelse {
        diagnostics.trace("ncl nups");
        return Error.InvalidOperandType;
    };
    const child_index = (try self.constant(child_index_operand.value)).uintValue() orelse {
        diagnostics.trace("ncl child");
        return Error.InvalidOperandType;
    };
    const child_proto_id = try self.snapshot.protoChild(self.proto, child_index);
    const child = try self.snapshot.proto(child_proto_id);
    if (child.parent_id != self.proto.id or child.nups != capture_count) {
        var detail: [72]u8 = undefined;
        const text = std.fmt.bufPrint(&detail, "ncl par {d}/{d} n{d}/{d} L{d}", .{
            child.parent_id,
            self.proto.id,
            child.nups,
            capture_count,
            self.proto.line_defined,
        }) catch "ncl par";
        diagnostics.trace(text);
        return Error.UnsupportedControlFlow;
    }

    const pointer_destination = try self.operand(store_pointer, 0);
    const pointer_source = try self.operand(store_pointer, 1);
    if (pointer_source.kind != .instruction or pointer_source.value != newclosure_id or
        pointer_destination.kind != .vm_reg)
    {
        diagnostics.trace("ncl reg");
        return Error.InvalidOperandType;
    }
    if (!tag_killed) {
        const tag_destination = try self.operand(store_tag, 0);
        const tag_source = try self.operand(store_tag, 1);
        if (tag_destination.kind != .vm_reg or tag_destination.value != pointer_destination.value or
            tag_source.kind != .constant or (try self.constant(tag_source.value)).tagValue() != 8)
        {
            var text: [96]u8 = undefined;
            const rendered = std.fmt.bufPrint(&text, "ncl tag {d} {d} {d}", .{
                @intFromEnum(pointer_destination.kind),
                @intFromEnum(tag_destination.kind),
                @intFromEnum(tag_source.kind),
            }) catch "ncl tag";
            diagnostics.trace(rendered);
            return Error.InvalidOperandType;
        }
    }
    const destination = self.vmRegisterIndex(pointer_destination) catch |err| {
        diagnostics.trace("ncl reg");
        return err;
    };

    var cursor = std.math.add(u32, newclosure_id, 3) catch return Error.ResourceLimit;
    if (capture_count == 0) {
        var finish = newclosure_id + 2;
        var check_gc = false;
        if (cursor < self.function.instruction_count) {
            const gc_marker = try self.instruction(cursor);
            if (gc_marker.command == .check_gc or gc_marker.command == .nop) {
                try self.requireOperandCount(gc_marker, 0);
                finish = cursor;
                check_gc = gc_marker.command == .check_gc;
            }
        }
        self.requireSingleCompilableBlockRange(newclosure_id - 2, finish) catch |err| {
            diagnostics.trace("ncl blk0");
            return err;
        };
        return .{
            .start = newclosure_id - 2,
            .finish = finish,
            .destination = destination,
            .child_proto_id = child_proto_id,
            .capture_count = 0,
            .capture_ir_start = finish,
            .marker_start = finish + 1,
            .check_gc = check_gc,
        };
    }
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
            _ = self.vmRegisterIndex(try self.operand(first, 0)) catch |err| {
                diagnostics.trace("ncl val");
                return err;
            };
            if (first.operand_count == 3) {
                const offset = self.tvalueByteOffset(first, 1) catch |err| {
                    diagnostics.trace("ncl off");
                    return err;
                };
                if (offset != 0) {
                    diagnostics.trace("ncl cap off");
                    return Error.InvalidOperandType;
                }
                const load_tag = try self.operand(first, 2);
                if (load_tag.kind != .constant or (try self.constant(load_tag.value)).tagValue() == null) {
                    diagnostics.trace("ncl cap tag");
                    return Error.InvalidOperandType;
                }
            }
            const address_id = cursor + 1;
            const store_id = cursor + 2;
            const address = try self.instruction(address_id);
            const store = try self.instruction(store_id);
            if (address.command != .get_closure_upval_addr) {
                diagnostics.trace("ncl cap addr");
                return Error.UnsupportedControlFlow;
            }
            try self.requireOperandCount(address, 2);
            try self.requireClosureCaptureAddress(address, newclosure_id, capture_index);
            if (store.command == .store_split_tvalue) {
                if (try self.initializedClosureValueCapture(address_id, store_id, newclosure_id) == null) {
                    diagnostics.trace("ncl cap nil");
                    return Error.UnsupportedControlFlow;
                }
                cursor = store_id + 1;
                continue;
            }
            if (store.command != .store_tvalue) {
                var detail: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&detail, "ncl cap st {d}", .{
                    @intFromEnum(store.command),
                }) catch "ncl cap st";
                diagnostics.trace(text);
                return Error.UnsupportedControlFlow;
            }
            try self.requireOperandCount(store, 2);
            try self.requireTValueStore(store, address_id, cursor);
            cursor = store_id + 1;
        } else if (first.command == .findupval) {
            try self.requireOperandCount(first, 1);
            const upval_source = try self.operand(first, 0);
            _ = self.vmRegisterIndex(upval_source) catch |err| {
                var text: [48]u8 = undefined;
                const rendered = std.fmt.bufPrint(&text, "ncl fu {d} {d}", .{
                    @intFromEnum(upval_source.kind),
                    upval_source.value,
                }) catch "ncl fu";
                diagnostics.trace(rendered);
                return err;
            };
            const address_id = cursor + 1;
            const pointer_id = cursor + 2;
            const tag_id = cursor + 3;
            const address = try self.instruction(address_id);
            const pointer_store = try self.instruction(pointer_id);
            const tag_store = try self.instruction(tag_id);
            if (address.command != .get_closure_upval_addr or pointer_store.command != .store_pointer or
                tag_store.command != .store_tag)
            {
                var detail: [48]u8 = undefined;
                const text = std.fmt.bufPrint(&detail, "ncl fu seq {d} {d} {d}", .{
                    @intFromEnum(address.command),
                    @intFromEnum(pointer_store.command),
                    @intFromEnum(tag_store.command),
                }) catch "ncl fu seq";
                diagnostics.trace(text);
                return Error.UnsupportedControlFlow;
            }
            try self.requireOperandCount(address, 2);
            try self.requireOperandCount(pointer_store, 2);
            try self.requireOperandCount(tag_store, 2);
            try self.requireClosureCaptureAddress(address, newclosure_id, capture_index);
            try self.requireInstructionStore(pointer_store, address_id, cursor);
            const capture_tag_destination = try self.operand(tag_store, 0);
            const capture_tag_source = try self.operand(tag_store, 1);
            if (capture_tag_destination.kind != .instruction or capture_tag_destination.value != address_id or
                capture_tag_source.kind != .constant or (try self.constant(capture_tag_source.value)).tagValue() != 16)
            {
                diagnostics.trace("ncl ref tag");
                return Error.InvalidOperandType;
            }
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
            {
                var text: [80]u8 = undefined;
                const rendered = std.fmt.bufPrint(&text, "ncl up {d} {d}", .{
                    @intFromEnum(source_closure.kind),
                    @intFromEnum(source_slot.kind),
                }) catch "ncl up";
                diagnostics.trace(rendered);
                return Error.InvalidOperandType;
            }
            const address_id = cursor + 1;
            const load_id = cursor + 2;
            const store_id = cursor + 3;
            const address = try self.instruction(address_id);
            const load = try self.instruction(load_id);
            const store = try self.instruction(store_id);
            if (address.command != .get_closure_upval_addr or load.command != .load_tvalue or
                (store.command != .store_tvalue and store.command != .store_split_tvalue))
            {
                var detail: [48]u8 = undefined;
                const text = std.fmt.bufPrint(&detail, "ncl up seq {d} {d} {d}", .{
                    @intFromEnum(address.command),
                    @intFromEnum(load.command),
                    @intFromEnum(store.command),
                }) catch "ncl up seq";
                diagnostics.trace(text);
                return Error.UnsupportedControlFlow;
            }
            try self.requireOperandCount(address, 2);
            try self.requireOperandCount(load, 1);
            try self.requireClosureCaptureAddress(address, newclosure_id, capture_index);
            const load_source = try self.operand(load, 0);
            if (load_source.kind != .instruction or load_source.value != cursor) {
                diagnostics.trace("ncl up load");
                return Error.InvalidOperandType;
            }
            if (store.command == .store_split_tvalue) {
                try self.requireOperandCount(store, 3);
                const split_destination = try self.operand(store, 0);
                const split_tag = try self.operand(store, 1);
                const split_source = try self.operand(store, 2);
                if (split_destination.kind != .instruction or split_destination.value != address_id or
                    split_source.kind != .instruction or split_source.value != load_id or
                    split_tag.kind != .constant or (try self.constant(split_tag.value)).tagValue() == null)
                {
                    diagnostics.trace("ncl up split");
                    return Error.InvalidOperandType;
                }
            } else {
                try self.requireOperandCount(store, 2);
                try self.requireTValueStore(store, address_id, load_id);
            }
            cursor = store_id + 1;
        } else {
            var detail: [40]u8 = undefined;
            const text = std.fmt.bufPrint(&detail, "ncl cap {d} c{d}", .{
                capture_index,
                @intFromEnum(first.command),
            }) catch "ncl cap";
            diagnostics.trace(text);
            return Error.UnsupportedControlFlow;
        }
    }

    const possible_gc_marker = try self.instruction(cursor);
    const has_gc_marker = possible_gc_marker.command == .check_gc or possible_gc_marker.command == .nop;
    if (has_gc_marker)
        try self.requireOperandCount(possible_gc_marker, 0)
    else if (possible_gc_marker.command != .capture) {
        var detail: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&detail, "ncl gc {d}", .{
            @intFromEnum(possible_gc_marker.command),
        }) catch "ncl gc";
        diagnostics.trace(text);
        return Error.UnsupportedControlFlow;
    }
    const marker_start = cursor + @as(u32, @intFromBool(has_gc_marker));
    capture_index = 0;
    while (capture_index < capture_count) : (capture_index += 1) {
        const initialized = try self.initializedCapture(capture_index, capture_ir_start);
        const captured = try markerCapture(self.snapshot, self.function, self.proto, marker_start + capture_index, true);
        if (captured.kind != initialized.kind or captured.source != initialized.source) {
            var text: [80]u8 = undefined;
            const rendered = std.fmt.bufPrint(&text, "ncl mark {d}/{d} {d}/{d}", .{
                @intFromEnum(captured.kind),
                @intFromEnum(initialized.kind),
                captured.source,
                initialized.source,
            }) catch "ncl mark";
            diagnostics.trace(rendered);
            return Error.InvalidOperandType;
        }
    }
    const finish = marker_start + capture_count - 1;
    if (finish >= self.function.instruction_count) {
        diagnostics.trace("ncl fin");
        return Error.UnsupportedControlFlow;
    }
    self.requireSingleCompilableBlockRange(newclosure_id - 2, finish) catch |err| {
        diagnostics.trace("ncl blk");
        return err;
    };
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
    {
        diagnostics.trace("ncl addr");
        return Error.InvalidOperandType;
    }
}
pub fn requireInstructionStore(self: anytype, instruction_value: snapshot_v1.IrInstruction, destination_id: u32, source_id: u32) Error!void {
    const destination = try self.operand(instruction_value, 0);
    const source = try self.operand(instruction_value, 1);
    if (destination.kind != .instruction or destination.value != destination_id or
        source.kind != .instruction or source.value != source_id)
    {
        var text: [48]u8 = undefined;
        const rendered = std.fmt.bufPrint(&text, "sto {d} {d}", .{
            @intFromEnum(destination.kind),
            @intFromEnum(source.kind),
        }) catch "sto";
        diagnostics.trace(rendered);
        return Error.InvalidOperandType;
    }
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
                const capture = (try self.initializedClosureValueCapture(cursor, cursor + 1, closure.value)) orelse {
                    diagnostics.trace("ncl ic nil");
                    return Error.UnsupportedControlFlow;
                };
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
        else {
            var detail: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&detail, "ncl ic {d}", .{@intFromEnum(first.command)}) catch "ncl ic";
            diagnostics.trace(text);
            return Error.UnsupportedControlFlow;
        };
        if (index == wanted)
            return capture;
        cursor += if (capture.kind == .value) 3 else 4;
    }
    unreachable;
}
pub fn isDupClosureCapture(self: anytype, instruction_id: u32) Error!bool {
    return self.plan.dupClosureCaptureContaining(instruction_id);
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
fn emitCopyRegisterToPointer(self: anytype, destination: snapshot_v1.IrOperand, source_register: u32) Error!void {
    const source_offset = std.math.mul(u32, source_register, tvalue_size) catch return Error.ResourceLimit;
    try self.emitTValueAddress(destination);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i64Load(self.allocator, 3, source_offset);
    try self.body.i64Store(self.allocator, 3, 0);
    try self.emitTValueAddress(destination);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i64Load(self.allocator, 3, source_offset + 8);
    try self.body.i64Store(self.allocator, 3, 8);
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
        if (tag_value != 8) {
            diagnostics.trace("split cl tag");
            return Error.UnsupportedControlFlow;
        }
        const pattern = try self.newClosurePattern(source.value);
        if (destination != null and instruction_value.operand_count == 3) {
            try self.emitCopyTValueRegisters(destination.?, pattern.destination);
            return;
        }
        // The closure already lives in its destination register. A field write
        // names the node, so the copy uses that register.
        if (destination_operand.kind == .instruction and instruction_value.operand_count == 4) {
            const offset = try self.tvalueByteOffset(instruction_value, 3);
            const producer = try self.instruction(destination_operand.value);
            const slot_node = producer.command == abi.ir_cmd_get_slot_node_addr or
                producer.command == abi.ir_cmd_get_hash_node_addr;
            const live = slot_node and self.plan.validateNodeUse(
                self.snapshot,
                self.function,
                destination_operand.value,
                instruction_id,
            ) catch false;
            if (slot_node and offset == 0 and live) {
                try emitCopyRegisterToPointer(self, destination_operand, pattern.destination);
                return;
            }
        }
        diagnostics.trace("split cl");
        return Error.UnsupportedControlFlow;
    }

    const address_offset = if (instruction_value.operand_count == 4)
        try self.tvalueByteOffset(instruction_value, 3)
    else
        0;
    const reloaded_table_register: ?u32 = if (tag_value == lua_tag_table and source.kind == .instruction and
        self.plan.isProvenTablePointer(source.value))
    reload: {
        const producer_block = self.plan.instructionBlock(source.value) orelse {
            diagnostics.trace("split rb");
            return Error.UnsupportedControlFlow;
        };
        const consumer_block = self.plan.instructionBlock(instruction_id) orelse {
            diagnostics.trace("split cb");
            return Error.UnsupportedControlFlow;
        };
        if (producer_block == consumer_block)
            break :reload null;
        const loaded = try self.loadedPointerRegister(source);
        const fresh = try self.freshTableRegister(source.value);
        const register = loaded orelse fresh orelse {
            diagnostics.trace("split rr");
            return Error.UnsupportedControlFlow;
        };
        var scan_from = source.value + 1;
        if (loaded == null) {
            const producer_cmd = (try self.instruction(source.value)).command;
            if (producer_cmd == abi.ir_cmd_new_table) {
                const allocation = (try self.tableAllocationPatternAt(source.value)) orelse {
                    diagnostics.trace("split ra");
                    return Error.UnsupportedControlFlow;
                };
                scan_from = allocation.finish + 1;
            } else if (producer_cmd == abi.ir_cmd_dup_table and source.value != 0) {
                const clone = (try self.dupTablePatternAt(source.value - 1)) orelse {
                    diagnostics.trace("split rd");
                    return Error.UnsupportedControlFlow;
                };
                scan_from = clone.finish + 1;
            }
        }
        const predecessors = self.plan.predecessorSlice(consumer_block) orelse {
            diagnostics.trace("split rp");
            return Error.UnsupportedControlFlow;
        };
        if (predecessors.len != 1 or predecessors[0] != producer_block) {
            diagnostics.trace("split pred");
            return Error.UnsupportedControlFlow;
        }
        const producer = try self.snapshot.irBlock(self.function, producer_block);
        var cursor = scan_from;
        while (cursor <= producer.finish) : (cursor += 1) {
            if (try self.storesVmRegister(try self.instruction(cursor), register)) {
                diagnostics.trace("split rps");
                return Error.UnsupportedControlFlow;
            }
        }
        const consumer = try self.snapshot.irBlock(self.function, consumer_block);
        cursor = consumer.start;
        while (cursor < instruction_id) : (cursor += 1) {
            if (try self.storesVmRegister(try self.instruction(cursor), register)) {
                diagnostics.trace("split rcs");
                return Error.UnsupportedControlFlow;
            }
        }
        break :reload register;
    } else null;

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
        if (destination_operand.value >= self.function.instruction_count) {
            diagnostics.trace("split dx");
            return Error.UnsupportedControlFlow;
        }
        const producer = try self.instruction(destination_operand.value);
        if (producer.command == abi.ir_cmd_get_arr_addr) {
            if (!try self.plan.validateArrayAddressUse(
                self.snapshot,
                self.function,
                destination_operand.value,
                instruction_id,
            )) {
                const table_op = try self.operand(producer, 0);
                const index_op = try self.operand(producer, 1);
                var index_value: i64 = -1;
                if (index_op.kind == .constant) {
                    const index_constant = try self.constant(index_op.value);
                    if (index_constant.intValue()) |value| index_value = value;
                }
                var array_count: i64 = -1;
                var table_cmd: u32 = 0;
                if (table_op.kind == .instruction) {
                    const allocation = try self.instruction(table_op.value);
                    table_cmd = @intFromEnum(allocation.command);
                    if (allocation.operand_count >= 1) {
                        const count_op = try self.operand(allocation, 0);
                        if (count_op.kind == .constant) {
                            const count_constant = try self.constant(count_op.value);
                            if (count_constant.uintValue()) |value|
                                array_count = value
                            else if (count_constant.intValue()) |value|
                                array_count = value;
                        }
                    }
                }
                var invalid_cmd: u32 = 0;
                var invalid_at: u32 = 0;
                var cursor = destination_operand.value + 1;
                while (cursor < instruction_id) : (cursor += 1) {
                    const command = (try self.instruction(cursor)).command;
                    const raw: u32 = @intFromEnum(command);
                    const invalid = switch (command) {
                        .cmp_any, .do_arith, .get_cached_import, .interrupt, .check_gc, .call, .fallback_prepvarargs, .fallback_getvarargs, .newclosure, .fallback_dupclosure => true,
                        else => switch (raw) {
                            100, 101, 102, 105, 120, 121, 124, 125, 126, 128, 153, 156, 157, 158, 160, 161, 162, 163, 164, 169 => true,
                            else => false,
                        },
                    };
                    if (invalid) {
                        invalid_cmd = raw;
                        invalid_at = cursor;
                        break;
                    }
                }
                var detail: [80]u8 = undefined;
                const text = std.fmt.bufPrint(&detail, "arr off{d} i{d} n{d} t{d} c{d} inv{d}@{d}", .{
                    address_offset,
                    index_value,
                    array_count,
                    @intFromEnum(table_op.kind),
                    table_cmd,
                    invalid_cmd,
                    invalid_at,
                }) catch "split arr";
                diagnostics.trace(text);
                return Error.UnsupportedControlFlow;
            }
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
            {
                diagnostics.trace("split node");
                return Error.UnsupportedControlFlow;
            }
        } else {
            var detail: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&detail, "split p{d}", .{
                @intFromEnum(producer.command),
            }) catch "split p";
            diagnostics.trace(text);
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
            try self.emitNumberPayload(source);
            try self.body.f64Store(self.allocator, 3, value_offset);
        },
        lua_tag_integer => {
            try self.emitTValueAddress(destination_operand);
            try self.emitI64Value(source);
            try self.body.i64Store(self.allocator, 3, value_offset);
        },
        lua_tag_string, 7, 8, 9, 10, 11, 12 => {
            try self.emitTValueAddress(destination_operand);
            if (reloaded_table_register) |register| {
                try self.body.localGet(self.allocator, self.base_local);
                try self.body.i32Load(self.allocator, 2, register * tvalue_size);
            } else if (source.kind == .instruction) {
                // NEW_TABLE and DUP_TABLE publish into a register and have no pointer local.
                var published: ?u32 = null;
                if (self.plan.tableAllocAt(source.value)) |alloc| {
                    published = alloc.destination;
                } else if ((try self.instruction(source.value)).command == abi.ir_cmd_dup_table) {
                    published = try self.dupTableRegisterForPointer(source.value);
                }
                if (published) |register| {
                    try self.body.localGet(self.allocator, self.base_local);
                    try self.body.i32Load(self.allocator, 2, register * tvalue_size);
                } else {
                    try self.emitPointerValue(source);
                }
            } else {
                try self.emitPointerValue(source);
            }
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
            if (operand_value.value >= self.slots.len) {
                diagnostics.trace("i32 len");
                return Error.InvalidInstructionResult;
            }
            const slot = self.slots[operand_value.value];
            if (slot.shape != .i32) {
                const producer = self.instruction(operand_value.value) catch {
                    diagnostics.trace("i32 miss");
                    return Error.InvalidInstructionResult;
                };
                var text: [48]u8 = undefined;
                const rendered = std.fmt.bufPrint(&text, "i32 {s} {d}", .{
                    @tagName(slot.shape),
                    @intFromEnum(producer.command),
                }) catch "i32";
                diagnostics.trace(rendered);
                return Error.InvalidInstructionResult;
            }
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
            if (operand_value.value >= self.slots.len) {
                diagnostics.trace("ptr len");
                return Error.InvalidInstructionResult;
            }
            const slot = self.slots[operand_value.value];
            if (slot.shape != .pointer) {
                const producer = self.instruction(operand_value.value) catch {
                    diagnostics.trace("ptr miss");
                    return Error.InvalidInstructionResult;
                };
                var text: [48]u8 = undefined;
                const rendered = std.fmt.bufPrint(&text, "ptr {s} {d}", .{
                    @tagName(slot.shape),
                    @intFromEnum(producer.command),
                }) catch "ptr";
                diagnostics.trace(rendered);
                return Error.InvalidInstructionResult;
            }
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
pub noinline fn emitLoadEnv(self: anytype, instruction_id: u32) Error!void {
    if (instruction_id >= self.slots.len or self.slots[instruction_id].shape != .pointer)
        return Error.InvalidInstructionResult;
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_func_offset);
    try self.body.i32Load(self.allocator, 2, 0);
    try self.body.i32Load(self.allocator, 2, abi.closure_env_offset);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitVmConstantAddress(self: anytype, operand_value: snapshot_v1.IrOperand) Error!void {
    if (operand_value.kind != .vm_const or operand_value.value >= self.proto.vm_constant_count)
        return Error.InvalidOperandType;
    const value = try self.snapshot.vmConstant(self.proto, operand_value.value);
    switch (value.kind) {
        .nil, .boolean, .number, .vector, .string, .integer, .table => {},
        .import, .closure, .class_shape => return Error.UnsupportedOperand,
    }

    // The entry cache proves this frame's Proto.k. The walk remains if that cache missed.
    const byte_offset = std.math.mul(u32, operand_value.value, tvalue_size) catch
        return Error.ResourceLimit;
    try self.body.localGet(self.allocator, self.constant_array_local);
    try self.body.ifI32(self.allocator);
    try self.body.localGet(self.allocator, self.constant_array_local);
    try self.body.i32Const(self.allocator, @intCast(byte_offset));
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_func_offset);
    try self.body.i32Load(self.allocator, 2, 0);
    try self.body.i32Load(self.allocator, 2, abi.closure_l_proto_offset);
    try self.body.i32Load(self.allocator, 2, abi.proto_constants_offset);
    try self.body.i32Const(self.allocator, @intCast(byte_offset));
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.end(self.allocator);
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
            if (operand_value.value >= self.slots.len) {
                diagnostics.trace("i64 len");
                return Error.InvalidInstructionResult;
            }
            const slot = self.slots[operand_value.value];
            if (slot.shape != .i64) {
                const producer = self.instruction(operand_value.value) catch {
                    diagnostics.trace("i64 miss");
                    return Error.InvalidInstructionResult;
                };
                var text: [48]u8 = undefined;
                const rendered = std.fmt.bufPrint(&text, "i64 {s} {d}", .{
                    @tagName(slot.shape),
                    @intFromEnum(producer.command),
                }) catch "i64";
                diagnostics.trace(rendered);
                return Error.InvalidInstructionResult;
            }
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
// Number-tag stores accept an integer constant or an i32/i64 result and convert it.
// Other f64 consumers keep the strict f64 slot rule.
pub noinline fn emitNumberPayload(self: anytype, operand_value: snapshot_v1.IrOperand) Error!void {
    switch (operand_value.kind) {
        .constant => {
            const value = try self.constant(operand_value.value);
            const number: f64 = switch (value.kind) {
                .double => value.doubleValue() orelse return Error.InvalidOperandType,
                .int => @floatFromInt(value.intValue() orelse return Error.InvalidOperandType),
                .uint => @floatFromInt(value.uintValue() orelse return Error.InvalidOperandType),
                .int64 => @floatFromInt(value.int64Value() orelse return Error.InvalidOperandType),
                else => return Error.InvalidOperandType,
            };
            try self.body.f64Const(self.allocator, number);
        },
        .instruction => {
            if (operand_value.value >= self.slots.len)
                return Error.InvalidInstructionResult;
            const slot = self.slots[operand_value.value];
            switch (slot.shape) {
                .f64 => try self.body.localGet(self.allocator, slot.first),
                .i32 => {
                    try self.body.localGet(self.allocator, slot.first);
                    try self.body.opcode(self.allocator, 0xb7); // f64.convert_i32_s
                },
                .i64 => {
                    try self.body.localGet(self.allocator, slot.first);
                    try self.body.opcode(self.allocator, 0xb9); // f64.convert_i64_s
                },
                else => {
                    const producer = self.instruction(operand_value.value) catch
                        return Error.InvalidInstructionResult;
                    var text: [80]u8 = undefined;
                    const rendered = std.fmt.bufPrint(&text, "pay {s} cmd {d}", .{
                        @tagName(slot.shape),
                        @intFromEnum(producer.command),
                    }) catch "pay";
                    diagnostics.trace(rendered);
                    return Error.InvalidInstructionResult;
                },
            }
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
            if (operand_value.value >= self.slots.len) {
                diagnostics.trace("f64 len");
                return Error.InvalidInstructionResult;
            }
            const slot = self.slots[operand_value.value];
            if (slot.shape != .f64) {
                const producer = self.instruction(operand_value.value) catch
                    return Error.InvalidInstructionResult;
                var text: [80]u8 = undefined;
                const rendered = std.fmt.bufPrint(&text, "f64 {s} cmd {d}", .{
                    @tagName(slot.shape),
                    @intFromEnum(producer.command),
                }) catch "f64";
                diagnostics.trace(rendered);
                return Error.InvalidInstructionResult;
            }
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
            (target.kind != .fallback or !try admission.supportsFallback(self, target))))
        return Error.UnsupportedControlFlow;
    return operand_value.value;
}

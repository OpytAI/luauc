const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");

const Error = model.Error;
const StringTableOperation = model.StringTableOperation;
const FastcallPattern = model.FastcallPattern;
const TypeNamePattern = model.TypeNamePattern;
const StringLengthPattern = model.StringLengthPattern;
const StringTablePattern = model.StringTablePattern;
const InlineStringTablePattern = model.InlineStringTablePattern;
const ir_cmd_get_slot_node_addr = abi.ir_cmd_get_slot_node_addr;
const ir_cmd_check_readonly = abi.ir_cmd_check_readonly;
const ir_cmd_check_slot_match = abi.ir_cmd_check_slot_match;
const ir_cmd_barrier_table_forward = abi.ir_cmd_barrier_table_forward;
const ir_cmd_fallback_gettableks = abi.ir_cmd_fallback_gettableks;
const ir_cmd_fallback_settableks = abi.ir_cmd_fallback_settableks;
const ir_cmd_string_len = abi.ir_cmd_string_len;
const ir_cmd_adjust_stack_to_reg = abi.ir_cmd_adjust_stack_to_reg;
const ir_cmd_adjust_stack_to_top = abi.ir_cmd_adjust_stack_to_top;
const ir_cmd_fastcall = abi.ir_cmd_fastcall;
const ir_cmd_invoke_fastcall = abi.ir_cmd_invoke_fastcall;
const ir_cmd_check_fastcall_res = abi.ir_cmd_check_fastcall_res;
const ir_cmd_get_type = abi.ir_cmd_get_type;
const ir_cmd_get_typeof = abi.ir_cmd_get_typeof;
const lua_tag_number = abi.lua_tag_number;
const lua_tag_string = abi.lua_tag_string;
const lua_tag_table = abi.lua_tag_table;
const lbf_operand_none = abi.lbf_operand_none;
const lop_call = abi.lop_call;
const lop_fastcall3 = abi.lop_fastcall3;
const lop_fastcall = abi.lop_fastcall;
const lop_fastcall1 = abi.lop_fastcall1;
const lop_fastcall2 = abi.lop_fastcall2;
const lop_fastcall2k = abi.lop_fastcall2k;

pub fn uintOperandEquals(self: anytype, operand_value: snapshot_v1.IrOperand, expected: u32) Error!bool {
    return operand_value.kind == .constant and (try self.constant(operand_value.value)).uintValue() == expected;
}
pub fn intOperandEquals(self: anytype, operand_value: snapshot_v1.IrOperand, expected: i32) Error!bool {
    return operand_value.kind == .constant and (try self.constant(operand_value.value)).intValue() == expected;
}
pub fn stringKey(self: anytype, operand_value: snapshot_v1.IrOperand) Error!?[]const u8 {
    if (operand_value.kind != .vm_const)
        return null;
    const constant_value = try self.snapshot.vmConstant(self.proto, operand_value.value);
    if (constant_value.kind != .string)
        return null;
    const key = try self.snapshot.string(constant_value.payload0);
    return key;
}
pub fn stringFallbackRejoin(
    self: anytype,
    fallback_id: u32,
    operation: StringTableOperation,
    pc: u32,
    value: u32,
    table: u32,
    key_id: u32,
) Error!?u32 {
    if (fallback_id >= self.function.block_count)
        return null;
    const block = try self.snapshot.irBlock(self.function, fallback_id);
    if (block.kind != .fallback or block.isEmpty() or block.finish != block.start + 1)
        return null;
    const semantic = try self.instruction(block.start);
    const jump = try self.instruction(block.finish);
    const expected_command = if (operation == .set) ir_cmd_fallback_settableks else ir_cmd_fallback_gettableks;
    if (semantic.command != expected_command or semantic.operand_count != 4 or jump.command != .jump or jump.operand_count != 1)
        return null;
    const semantic_pc = try self.operand(semantic, 0);
    const semantic_value = try self.operand(semantic, 1);
    const semantic_table = try self.operand(semantic, 2);
    const semantic_key = try self.operand(semantic, 3);
    const target = try self.operand(jump, 0);
    if (!try self.uintOperandEquals(semantic_pc, pc) or
        semantic_value.kind != .vm_reg or semantic_value.value != value or
        semantic_table.kind != .vm_reg or semantic_table.value != table or
        semantic_key.kind != .vm_const or semantic_key.value != key_id or target.kind != .block)
        return null;
    return self.requireDispatchTarget(target) catch return null;
}
pub fn fastcallValueOperand(self: anytype, operand_value: snapshot_v1.IrOperand) Error!?u32 {
    if (operand_value.kind == .undef)
        return lbf_operand_none;
    return self.valueOperandEncoding(operand_value) catch return null;
}
pub noinline fn fastcallPatternAt(self: anytype, start: u32, block: snapshot_v1.IrBlock) Error!?FastcallPattern {
    if (!block.kind.isCompilable() or block.isEmpty() or start < block.start or start > block.finish)
        return null;
    var saved_id = start;
    const first = try self.instruction(start);
    if (first.command == .check_safe_env) {
        if (first.operand_count != 1 or (try self.operand(first, 0)).kind != .vm_exit)
            return null;
        saved_id = std.math.add(u32, start, 1) catch return Error.ResourceLimit;
    }
    if (saved_id + 3 > block.finish)
        return null;
    const saved_pc = try self.instruction(saved_id);
    const invoke_id = saved_id + 1;
    const invoke = try self.instruction(invoke_id);
    const check = try self.instruction(invoke_id + 1);
    if (saved_pc.command != .set_savedpc or invoke.command != ir_cmd_invoke_fastcall or
        check.command != ir_cmd_check_fastcall_res or invoke.operand_count != 7 or check.operand_count != 2)
        return null;

    const pc = try self.savedPc(saved_pc);
    if (pc == 0)
        return null;
    var fast_pc = pc - 1;
    var word = try self.snapshot.bytecodeWord(self.proto, fast_pc);
    var opcode: u8 = @truncate(word);
    if (opcode != lop_fastcall and opcode != lop_fastcall1) {
        if (pc < 2)
            return null;
        fast_pc = pc - 2;
        word = try self.snapshot.bytecodeWord(self.proto, fast_pc);
        opcode = @truncate(word);
        if (opcode != lop_fastcall2 and opcode != lop_fastcall2k and opcode != lop_fastcall3)
            return null;
    }
    const builtin_operand = try self.operand(invoke, 0);
    if (builtin_operand.kind != .constant)
        return null;
    const builtin_id = (try self.constant(builtin_operand.value)).uintValue() orelse return null;
    if (builtin_id >= 256 or ((word >> 8) & 0xff) != builtin_id)
        return null;

    const destination = try self.vmRegisterIndex(try self.operand(invoke, 1));
    const source = try self.vmRegisterIndex(try self.operand(invoke, 2));
    if (opcode == lop_fastcall1 and ((word >> 16) & 0xff) != source)
        return null;
    const argument_two_operand = try self.operand(invoke, 3);
    const argument_three_operand = try self.operand(invoke, 4);
    const argument_two = (try self.fastcallValueOperand(argument_two_operand)) orelse return null;
    const argument_three = (try self.fastcallValueOperand(argument_three_operand)) orelse return null;
    const parameter_count = try self.intConstant(try self.operand(invoke, 5));
    const result_count = try self.intConstant(try self.operand(invoke, 6));
    if (parameter_count < -1 or result_count < -1)
        return null;
    if (opcode == lop_fastcall) {
        if (parameter_count != -1 or source != destination + 1 or
            argument_two_operand.kind != .vm_reg or argument_two_operand.value != destination + 2 or
            argument_three != lbf_operand_none)
            return null;
    } else if (opcode == lop_fastcall1) {
        const fixed_one = parameter_count == 1 and argument_two == lbf_operand_none and argument_three == lbf_operand_none;
        const open = parameter_count == -1 and source == destination + 1 and
            argument_two_operand.kind == .vm_reg and argument_two_operand.value == destination + 2 and
            argument_three == lbf_operand_none;
        if (!fixed_one and !open)
            return null;
    }
    if (opcode == lop_fastcall2 and (parameter_count != 2 or argument_two_operand.kind != .vm_reg or argument_three != lbf_operand_none))
        return null;
    if (opcode == lop_fastcall2k and (parameter_count != 2 or argument_two_operand.kind != .vm_const or argument_three != lbf_operand_none))
        return null;
    if (opcode == lop_fastcall3 and (parameter_count != 3 or argument_two_operand.kind != .vm_reg or
        argument_three_operand.kind != .vm_reg))
        return null;
    if (opcode != lop_fastcall and opcode != lop_fastcall1) {
        const aux = try self.snapshot.bytecodeWord(self.proto, fast_pc + 1);
        if (opcode == lop_fastcall2 and (aux & 0xff) != argument_two_operand.value)
            return null;
        if (opcode == lop_fastcall2k and aux != argument_two_operand.value)
            return null;
        if (opcode == lop_fastcall3 and
            ((aux & 0xff) != argument_two_operand.value or ((aux >> 8) & 0xff) != argument_three_operand.value))
            return null;
    }

    const checked_result = try self.operand(check, 0);
    const fallback_operand = try self.operand(check, 1);
    if (checked_result.kind != .instruction or checked_result.value != invoke_id or
        fallback_operand.kind != .block or fallback_operand.value >= self.function.block_count)
        return null;
    const fallback = try self.snapshot.irBlock(self.function, fallback_operand.value);
    if (fallback.kind != .fallback or fallback.isEmpty() or fallback.finish <= fallback.start)
        return null;
    const fallback_call = try self.instruction(fallback.finish - 1);
    const fallback_jump = try self.instruction(fallback.finish);
    const call_pc = std.math.add(u32, fast_pc, ((word >> 24) & 0xff) + 1) catch return Error.ResourceLimit;
    if (call_pc >= self.proto.code_count)
        return null;
    const call_word = try self.snapshot.bytecodeWord(self.proto, call_pc);
    if (@as(u8, @truncate(call_word)) != lop_call)
        return null;
    const call_destination = (call_word >> 8) & 0xff;
    const call_parameter_count = @as(i32, @intCast((call_word >> 16) & 0xff)) - 1;
    const call_result_count = @as(i32, @intCast((call_word >> 24) & 0xff)) - 1;
    if (fallback_call.command != .call or fallback_call.operand_count != 3 or
        fallback_jump.command != .jump or fallback_jump.operand_count != 1 or
        destination != call_destination or
        try self.vmRegisterIndex(try self.operand(fallback_call, 0)) != call_destination or
        try self.intConstant(try self.operand(fallback_call, 1)) != call_parameter_count or
        try self.intConstant(try self.operand(fallback_call, 2)) != call_result_count or
        result_count != call_result_count)
        return null;

    var finish = invoke_id + 2;
    if (result_count == -1) {
        const adjust = try self.instruction(finish);
        if (adjust.command != ir_cmd_adjust_stack_to_reg or adjust.operand_count != 2 or
            try self.vmRegisterIndex(try self.operand(adjust, 0)) != destination or
            (try self.operand(adjust, 1)).kind != .instruction or
            (try self.operand(adjust, 1)).value != invoke_id)
            return null;
        finish += 1;
    } else if ((try self.instruction(finish)).command == ir_cmd_adjust_stack_to_top) {
        if ((try self.instruction(finish)).operand_count != 0)
            return null;
        finish += 1;
    }
    if (finish > block.finish)
        return null;
    const terminal = try self.instruction(finish);
    const fast_target = if (terminal.command == .jump and terminal.operand_count == 1)
        try self.operand(terminal, 0)
    else if (block.kind == .linearized) blk: {
        const canonical_rejoin = try self.operand(fallback_jump, 0);
        if (canonical_rejoin.kind != .block or
            canonical_rejoin.value >= self.function.block_count or
            !(try self.snapshot.irBlock(self.function, canonical_rejoin.value)).kind.isCompilable())
            return null;
        break :blk canonical_rejoin;
    } else return null;
    if (fast_target.kind != .block or fast_target.value >= self.function.block_count)
        return null;
    return .{
        .start = start,
        .finish = finish,
        .builtin_id = builtin_id,
        .destination = destination,
        .source = source,
        .argument_two = argument_two,
        .argument_three = argument_three,
        .parameter_count = parameter_count,
        .result_count = result_count,
        .fallback = fallback_operand.value,
        .fast_target = fast_target.value,
    };
}
pub noinline fn stringLengthPattern(self: anytype, instruction_id: u32) Error!?StringLengthPattern {
    if (instruction_id + 3 >= self.function.instruction_count)
        return null;
    const string_len = try self.instruction(instruction_id);
    const converted = try self.instruction(instruction_id + 1);
    const store = try self.instruction(instruction_id + 2);
    const store_tag = try self.instruction(instruction_id + 3);
    if (string_len.command != ir_cmd_string_len or converted.command != .int_to_num or
        store.command != .store_double or
        (store_tag.command != .store_tag and store_tag.command != .nop))
        return null;
    try self.requireOperandCount(string_len, 1);
    try self.requireOperandCount(converted, 1);
    try self.requireOperandCount(store, 2);
    if (store_tag.command == .store_tag)
        try self.requireOperandCount(store_tag, 2)
    else
        try self.requireOperandCount(store_tag, 0);
    const length_pointer = try self.operand(string_len, 0);
    if (length_pointer.kind != .instruction or length_pointer.value >= self.function.instruction_count)
        return null;
    const load_pointer = try self.instruction(length_pointer.value);
    if (load_pointer.command != .load_pointer)
        return null;
    try self.requireOperandCount(load_pointer, 1);
    const source = try self.vmRegisterIndex(try self.operand(load_pointer, 0));
    if (!try self.hasPreservedStringGuard(source, length_pointer.value) or
        !try self.preservesRegisterToConsumer(source, length_pointer.value, instruction_id))
        return null;
    const converted_length = try self.operand(converted, 0);
    const destination = try self.vmRegisterIndex(try self.operand(store, 0));
    const stored = try self.operand(store, 1);
    if (converted_length.kind != .instruction or
        converted_length.value != instruction_id or stored.kind != .instruction or
        stored.value != instruction_id + 1)
        return null;
    if (store_tag.command == .store_tag) {
        const tag_destination = try self.vmRegisterIndex(try self.operand(store_tag, 0));
        const result_tag = try self.operand(store_tag, 1);
        if (tag_destination != destination or result_tag.kind != .constant or
            (try self.constant(result_tag.value)).tagValue() != lua_tag_number)
            return null;
    }
    if (instruction_id + 4 < self.function.instruction_count and
        (try self.instruction(instruction_id + 4)).command == .mark_dead)
    {
        const mark_dead = try self.instruction(instruction_id + 4);
        if (mark_dead.operand_count != 2 or
            try self.vmRegisterIndex(try self.operand(mark_dead, 0)) != destination + 1 or
            try self.intConstant(try self.operand(mark_dead, 1)) != -1)
            return null;
    }
    return .{ .source = source, .destination = destination, .materialize_tag = store_tag.command == .nop };
}
pub fn hasPreservedStringGuard(self: anytype, source: u32, pointer_id: u32) Error!bool {
    const owner_id = self.plan.instructionBlock(pointer_id) orelse return false;
    const owner = try self.snapshot.irBlock(self.function, owner_id);
    if (try self.rangeHasPreservedStringGuard(source, owner.start, pointer_id))
        return true;
    if (owner.kind != .linearized or owner.use_count != 1)
        return false;

    const predecessors = self.plan.predecessorSlice(owner_id) orelse return false;
    if (predecessors.len != 1)
        return false;
    const predecessor = try self.snapshot.irBlock(self.function, predecessors[0]);
    if (!try self.rangeHasPreservedStringGuard(source, predecessor.start, predecessor.finish))
        return false;
    var instruction_id = owner.start;
    while (instruction_id < pointer_id) : (instruction_id += 1)
        if (try self.instructionWritesRegister(instruction_id, source))
            return false;
    return true;
}
pub fn preservesRegisterToConsumer(self: anytype, source: u32, producer_id: u32, consumer_id: u32) Error!bool {
    if (producer_id >= consumer_id)
        return false;
    const producer_owner_id = self.plan.instructionBlock(producer_id) orelse return false;
    const consumer_owner_id = self.plan.instructionBlock(consumer_id) orelse return false;
    if (producer_owner_id == consumer_owner_id) {
        var instruction_id = producer_id + 1;
        while (instruction_id < consumer_id) : (instruction_id += 1)
            if (try self.instructionWritesRegister(instruction_id, source))
                return false;
        return true;
    }

    const producer_owner = try self.snapshot.irBlock(self.function, producer_owner_id);
    const consumer_owner = try self.snapshot.irBlock(self.function, consumer_owner_id);
    if (!producer_owner.kind.isCompilable() or consumer_owner.kind != .linearized or
        consumer_owner.use_count != 1)
        return false;

    const predecessors = self.plan.predecessorSlice(consumer_owner_id) orelse return false;
    if (predecessors.len != 1 or predecessors[0] != producer_owner_id)
        return false;

    var instruction_id = producer_id + 1;
    while (instruction_id <= producer_owner.finish) : (instruction_id += 1)
        if (try self.instructionWritesRegister(instruction_id, source))
            return false;
    instruction_id = consumer_owner.start;
    while (instruction_id < consumer_id) : (instruction_id += 1)
        if (try self.instructionWritesRegister(instruction_id, source))
            return false;
    return true;
}
pub fn rangeHasPreservedStringGuard(self: anytype, source: u32, start: u32, finish: u32) Error!bool {
    if (start >= finish)
        return false;
    var cursor = finish;
    while (cursor > start) : (cursor -= 1) {
        const check_id = cursor - 1;
        const check = try self.instruction(check_id);
        if (check.command != .check_tag or check.operand_count != 3)
            continue;
        const checked = try self.operand(check, 0);
        const expected = try self.operand(check, 1);
        const failure = try self.operand(check, 2);
        if (checked.kind != .instruction or checked.value + 1 != check_id or
            expected.kind != .constant or (try self.constant(expected.value)).tagValue() != lua_tag_string or
            !try self.isGuardFailure(failure))
            continue;
        const load = try self.instruction(checked.value);
        if (load.command != .load_tag or load.operand_count != 1 or
            (self.vmRegisterIndex(try self.operand(load, 0)) catch continue) != source)
            continue;
        var between = check_id + 1;
        var overwritten = false;
        while (between < finish) : (between += 1)
            if (try self.instructionWritesRegister(between, source)) {
                overwritten = true;
                break;
            };
        if (!overwritten)
            return true;
    }
    return false;
}
pub fn instructionWritesRegister(self: anytype, instruction_id: u32, register: u32) Error!bool {
    const instruction_value = try self.instruction(instruction_id);
    switch (instruction_value.command) {
        .store_pointer,
        .store_int,
        .store_int64,
        .store_double,
        .store_tvalue,
        .store_split_tvalue,
        .store_vector,
        .store_tag,
        .store_extra,
        .get_cached_import,
        => if (instruction_value.operand_count != 0 and
            (try self.operand(instruction_value, 0)).kind == .vm_reg and
            (try self.operand(instruction_value, 0)).value == register)
            return true,
        .call => {
            if (instruction_value.operand_count != 3)
                return true;
            const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
            const result_count = try self.intConstant(try self.operand(instruction_value, 2));
            if (result_count == -1)
                return register >= destination;
            if (result_count > 0)
                return register >= destination and register < destination + @as(u32, @intCast(result_count));
        },
        ir_cmd_fastcall, ir_cmd_invoke_fastcall => {
            if (instruction_value.operand_count < 2)
                return true;
            const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
            const count_operand: u32 = if (instruction_value.command == ir_cmd_fastcall) 3 else 6;
            if (instruction_value.operand_count <= count_operand)
                return true;
            const result_count = try self.intConstant(try self.operand(instruction_value, count_operand));
            if (result_count == -1)
                return register >= destination;
            if (result_count > 0)
                return register >= destination and register < destination + @as(u32, @intCast(result_count));
        },
        .fallback_getvarargs => {
            if (instruction_value.operand_count < 2)
                return true;
            const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
            return register >= destination;
        },
        else => {},
    }
    return false;
}
pub fn hasPublishedTValue(
    self: anytype,
    block: snapshot_v1.IrBlock,
    source: snapshot_v1.IrOperand,
    register: u32,
    consumer_id: u32,
) Error!bool {
    if (source.kind != .instruction or source.value >= consumer_id or register >= self.proto.max_stack_size or
        block.isEmpty() or consumer_id < block.start or consumer_id > block.finish)
        return false;

    var publication: ?u32 = null;
    var instruction_id = block.start;
    while (instruction_id < consumer_id) : (instruction_id += 1) {
        const instruction_value = try self.instruction(instruction_id);
        if (instruction_value.command != .store_tvalue or instruction_value.operand_count != 2)
            continue;
        const destination = try self.operand(instruction_value, 0);
        const stored = try self.operand(instruction_value, 1);
        if (destination.kind == .vm_reg and destination.value == register and
            stored.kind == source.kind and stored.value == source.value)
            publication = instruction_id;
    }
    return if (publication) |producer|
        try self.preservesRegisterToConsumer(register, producer, consumer_id)
    else
        false;
}

pub fn compilableOwnerBlock(self: anytype, instruction_id: u32) Error!?snapshot_v1.IrBlock {
    const block_id = self.plan.instructionBlock(instruction_id) orelse return null;
    const block = try self.snapshot.irBlock(self.function, block_id);
    if (!block.kind.isCompilable() or block.isEmpty() or
        instruction_id < block.start or instruction_id > block.finish)
        return null;
    return block;
}
pub fn publishedNumberPayloadRegister(
    self: anytype,
    block: snapshot_v1.IrBlock,
    source: snapshot_v1.IrOperand,
    consumer_id: u32,
) Error!?u32 {
    if (source.kind != .instruction or source.value >= consumer_id or block.isEmpty() or
        consumer_id < block.start or consumer_id > block.finish)
        return null;

    var publication: ?struct { instruction_id: u32, register: u32 } = null;
    var instruction_id = block.start;
    while (instruction_id < consumer_id) : (instruction_id += 1) {
        const store = try self.instruction(instruction_id);
        if (store.command != .store_double or store.operand_count != 2)
            continue;
        const destination = try self.operand(store, 0);
        const stored = try self.operand(store, 1);
        if (destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
            stored.kind != source.kind or stored.value != source.value)
            continue;
        var publication_id = instruction_id;
        if (instruction_id + 1 < consumer_id) {
            const possible_tag = try self.instruction(instruction_id + 1);
            if (possible_tag.command == .store_tag and possible_tag.operand_count == 2 and
                (try self.operand(possible_tag, 0)).kind == .vm_reg and
                (try self.operand(possible_tag, 0)).value == destination.value and
                (try self.operand(possible_tag, 1)).kind == .constant and
                (try self.constant((try self.operand(possible_tag, 1)).value)).tagValue() == lua_tag_number)
                publication_id = instruction_id + 1;
        }
        publication = .{ .instruction_id = publication_id, .register = destination.value };
    }
    const published = publication orelse return null;
    instruction_id = published.instruction_id + 1;
    while (instruction_id < consumer_id) : (instruction_id += 1)
        if (try self.instructionWritesRegister(instruction_id, published.register))
            return null;
    return published.register;
}
pub noinline fn typeNamePattern(self: anytype, instruction_id: u32, custom: bool) Error!?TypeNamePattern {
    if (instruction_id + 2 >= self.function.instruction_count)
        return null;
    const get = try self.instruction(instruction_id);
    const store_pointer = try self.instruction(instruction_id + 1);
    const store_tag = try self.instruction(instruction_id + 2);
    if (get.command != (if (custom) ir_cmd_get_typeof else ir_cmd_get_type) or
        store_pointer.command != .store_pointer or store_tag.command != .store_tag)
        return null;
    try self.requireOperandCount(get, 1);
    try self.requireOperandCount(store_pointer, 2);
    try self.requireOperandCount(store_tag, 2);
    const input = try self.operand(get, 0);
    const source = if (custom) try self.vmRegisterIndex(input) else blk: {
        if (input.kind != .instruction or input.value + 1 != instruction_id)
            return null;
        const load_tag = try self.instruction(input.value);
        if (load_tag.command != .load_tag or load_tag.operand_count != 1)
            return null;
        break :blk try self.vmRegisterIndex(try self.operand(load_tag, 0));
    };
    const destination = try self.vmRegisterIndex(try self.operand(store_pointer, 0));
    const stored_pointer = try self.operand(store_pointer, 1);
    const tag_destination = try self.vmRegisterIndex(try self.operand(store_tag, 0));
    const tag = try self.operand(store_tag, 1);
    if (stored_pointer.kind != .instruction or stored_pointer.value != instruction_id or
        tag_destination != destination or tag.kind != .constant or
        (try self.constant(tag.value)).tagValue() != lua_tag_string)
        return null;
    var finish = instruction_id + 2;
    if (instruction_id + 3 < self.function.instruction_count and
        (try self.instruction(instruction_id + 3)).command == .mark_dead)
    {
        const mark_dead = try self.instruction(instruction_id + 3);
        if (mark_dead.operand_count != 2 or
            try self.vmRegisterIndex(try self.operand(mark_dead, 0)) != destination + 1 or
            try self.intConstant(try self.operand(mark_dead, 1)) != -1)
            return null;
        finish += 1;
    }
    return .{ .destination = destination, .source = source, .custom = @intFromBool(custom), .finish = finish };
}
pub noinline fn stringSetPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?StringTablePattern {
    if (!block.kind.isCompilable() or block.isEmpty())
        return null;

    const general = [_]snapshot_v1.IrCommand{
        .load_tag,                    .check_tag,            .load_pointer, ir_cmd_get_slot_node_addr,
        ir_cmd_check_slot_match,      ir_cmd_check_readonly, .load_tvalue,  .store_tvalue,
        ir_cmd_barrier_table_forward, .jump,
    };
    const preloaded = [_]snapshot_v1.IrCommand{
        .load_tvalue,  .store_tvalue,             .load_tag,                    .check_tag,
        .load_pointer, ir_cmd_get_slot_node_addr, ir_cmd_check_slot_match,      ir_cmd_check_readonly,
        .nop,          .store_tvalue,             ir_cmd_barrier_table_forward, .jump,
    };
    const published = [_]snapshot_v1.IrCommand{
        .load_tag,                    .check_tag,            .load_pointer, ir_cmd_get_slot_node_addr,
        ir_cmd_check_slot_match,      ir_cmd_check_readonly, .nop,          .store_tvalue,
        ir_cmd_barrier_table_forward, .jump,
    };
    const cloned = [_]snapshot_v1.IrCommand{
        ir_cmd_get_slot_node_addr, ir_cmd_check_slot_match,      ir_cmd_check_readonly, .load_tvalue,
        .store_tvalue,             ir_cmd_barrier_table_forward, .jump,
    };
    const trusted = [_]snapshot_v1.IrCommand{
        ir_cmd_get_slot_node_addr, ir_cmd_check_slot_match,      .nop,  .load_tvalue,
        .store_tvalue,             ir_cmd_barrier_table_forward, .jump,
    };
    const is_general = block.finish >= block.start + general.len - 1 and
        try self.commandRangeMatches(block.finish - @as(u32, @intCast(general.len - 1)), &general);
    const is_preloaded = !is_general and block.finish >= block.start + preloaded.len - 1 and
        try self.commandRangeMatches(block.finish - @as(u32, @intCast(preloaded.len - 1)), &preloaded);
    const is_published = !is_general and !is_preloaded and block.finish >= block.start + published.len - 1 and
        try self.commandRangeMatches(block.finish - @as(u32, @intCast(published.len - 1)), &published);
    const is_cloned = !is_general and !is_preloaded and !is_published and block.finish >= block.start + cloned.len - 1 and
        try self.commandRangeMatches(block.finish - @as(u32, @intCast(cloned.len - 1)), &cloned);
    const is_trusted = !is_general and !is_preloaded and !is_published and !is_cloned and block.finish >= block.start + trusted.len - 1 and
        try self.commandRangeMatches(block.finish - @as(u32, @intCast(trusted.len - 1)), &trusted);
    if (!is_general and !is_preloaded and !is_published and !is_cloned and !is_trusted)
        return null;
    const command_count = if (is_general) general.len else if (is_preloaded) preloaded.len else if (is_published) published.len else if (is_cloned) cloned.len else trusted.len;
    const start = block.finish - @as(u32, @intCast(command_count - 1));
    const semantic_start = start + (if (is_preloaded) @as(u32, 2) else 0);
    const slot_id = start + (if (is_general or is_published) @as(u32, 3) else if (is_preloaded) @as(u32, 5) else @as(u32, 0));
    const match_id = slot_id + 1;
    const load_id = start + (if (is_general) @as(u32, 6) else if (is_preloaded) @as(u32, 0) else @as(u32, 3));
    const store_id = if (is_preloaded) start + 9 else if (is_published) start + 7 else load_id + 1;
    const barrier_id = store_id + 1;
    const slot = try self.instruction(slot_id);
    const match = try self.instruction(match_id);
    const load = try self.instruction(load_id);
    const store = try self.instruction(store_id);
    const barrier = try self.instruction(barrier_id);
    const jump = try self.instruction(block.finish);
    if (slot.operand_count != 3 or match.operand_count != 3 or
        (!is_published and load.operand_count != 1 and load.operand_count != 3) or
        store.operand_count != 3 or barrier.operand_count != 3 or jump.operand_count != 1)
        return null;

    const pointer_operand = try self.operand(slot, 0);
    const pc_operand = try self.operand(slot, 1);
    const key_operand = try self.operand(slot, 2);
    const matched_slot = try self.operand(match, 0);
    const matched_key = try self.operand(match, 1);
    const fallback = try self.operand(match, 2);
    const store_slot = try self.operand(store, 0);
    const store_value = try self.operand(store, 1);
    const store_offset = try self.operand(store, 2);
    const barrier_pointer = try self.operand(barrier, 0);
    const barrier_source = try self.operand(barrier, 1);
    const barrier_tag = try self.operand(barrier, 2);
    const source = if (is_published)
        barrier_source
    else if (is_preloaded)
        try self.operand(try self.instruction(start + 1), 0)
    else
        try self.operand(load, 0);
    const fast_target = try self.operand(jump, 0);
    if (pointer_operand.kind != .instruction or pc_operand.kind != .constant or key_operand.kind != .vm_const or
        matched_slot.kind != .instruction or matched_slot.value != slot_id or
        matched_key.kind != .vm_const or matched_key.value != key_operand.value or fallback.kind != .block or
        source.kind != .vm_reg or source.value >= self.proto.max_stack_size or
        store_slot.kind != .instruction or store_slot.value != slot_id or
        store_value.kind != .instruction or (!is_published and store_value.value != load_id) or
        !try self.intOperandEquals(store_offset, 0) or
        barrier_pointer.kind != .instruction or barrier_pointer.value != pointer_operand.value or
        barrier_source.kind != .vm_reg or barrier_source.value != source.value or
        fast_target.kind != .block)
        return null;
    if (is_published) {
        if ((barrier_tag.kind != .undef and
            (barrier_tag.kind != .constant or (try self.constant(barrier_tag.value)).tagValue() == null)) or
            !try self.hasPublishedTValue(block, store_value, source.value, store_id))
            return null;
    } else if (load.operand_count == 1) {
        if (barrier_tag.kind != .undef)
            return null;
    } else {
        const load_offset = try self.operand(load, 1);
        const load_tag = try self.operand(load, 2);
        if (!try self.intOperandEquals(load_offset, 0) or load_tag.kind != .constant or
            (try self.constant(load_tag.value)).tagValue() == null or barrier_tag.kind != .constant or
            (try self.constant(barrier_tag.value)).tagValue() != (try self.constant(load_tag.value)).tagValue())
            return null;
    }
    if (is_preloaded) {
        const publication = try self.instruction(start + 1);
        if (publication.operand_count != 2 or
            (try self.operand(publication, 1)).kind != .instruction or
            (try self.operand(publication, 1)).value != load_id or
            try self.constantLoadPatternAt(load_id) == null)
            return null;
    }
    const pc = (try self.constant(pc_operand.value)).uintValue() orelse return null;
    const key = (try self.stringKey(key_operand)) orelse return null;

    var table: u32 = undefined;
    if (is_general or is_preloaded or is_published) {
        const load_tag = try self.instruction(semantic_start);
        const check_tag = try self.instruction(semantic_start + 1);
        const load_pointer = try self.instruction(semantic_start + 2);
        const table_operand = try self.operand(load_tag, 0);
        if (load_tag.operand_count != 1 or check_tag.operand_count != 3 or load_pointer.operand_count != 1 or
            table_operand.kind != .vm_reg or table_operand.value >= self.proto.max_stack_size or
            (try self.operand(check_tag, 0)).kind != .instruction or (try self.operand(check_tag, 0)).value != semantic_start or
            (try self.operand(check_tag, 1)).kind != .constant or
            (try self.constant((try self.operand(check_tag, 1)).value)).tagValue() != lua_tag_table or
            (((try self.operand(check_tag, 2)).kind != .vm_exit or (try self.operand(check_tag, 2)).value != pc) and
                ((try self.operand(check_tag, 2)).kind != .block or (try self.operand(check_tag, 2)).value != fallback.value)) or
            (try self.operand(load_pointer, 0)).kind != .vm_reg or (try self.operand(load_pointer, 0)).value != table_operand.value or
            pointer_operand.value != semantic_start + 2)
            return null;
        table = table_operand.value;
        const readonly = try self.instruction(semantic_start + 5);
        if (readonly.operand_count != 2 or
            (try self.operand(readonly, 0)).kind != .instruction or (try self.operand(readonly, 0)).value != semantic_start + 2 or
            (try self.operand(readonly, 1)).kind != .block or (try self.operand(readonly, 1)).value != fallback.value)
            return null;
    } else if (is_cloned) {
        const readonly = try self.instruction(start + 2);
        if (readonly.operand_count != 2 or
            (try self.operand(readonly, 0)).kind != .instruction or
            (try self.operand(readonly, 0)).value != pointer_operand.value or
            (try self.operand(readonly, 1)).kind != .block or
            (try self.operand(readonly, 1)).value != fallback.value)
            return null;
        table = (try self.dupTableRegisterForPointer(pointer_operand.value)) orelse return null;
    } else {
        const covering = self.plan.tableAllocCovering(pointer_operand.value) orelse return null;
        const allocation = (try self.tableAllocationPatternAt(covering.start)) orelse return null;
        if (allocation.start != pointer_operand.value or allocation.node_count != 4)
            return null;
        table = allocation.destination;
    }
    const rejoin = (try self.stringFallbackRejoin(fallback.value, .set, pc, source.value, table, key_operand.value)) orelse return null;
    return .{ .operation = .set, .start = semantic_start, .pc = pc, .table = table, .value = source.value, .key = key, .fallback = fallback.value, .fast_target = fast_target.value, .rejoin = rejoin };
}
pub noinline fn stringGetPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?StringTablePattern {
    const commands = [_]snapshot_v1.IrCommand{
        .load_tag,               .check_tag,   .load_pointer, ir_cmd_get_slot_node_addr,
        ir_cmd_check_slot_match, .load_tvalue, .store_tvalue, .jump,
    };
    if (!block.kind.isCompilable() or block.isEmpty() or block.finish < block.start + commands.len - 1)
        return null;
    const start = block.finish - @as(u32, @intCast(commands.len - 1));
    if (!try self.commandRangeMatches(start, &commands))
        return null;
    const load_tag = try self.instruction(start);
    const check_tag = try self.instruction(start + 1);
    const load_pointer = try self.instruction(start + 2);
    const slot = try self.instruction(start + 3);
    const match = try self.instruction(start + 4);
    const load = try self.instruction(start + 5);
    const store = try self.instruction(start + 6);
    const jump = try self.instruction(start + 7);
    if (load_tag.operand_count != 1 or check_tag.operand_count != 3 or load_pointer.operand_count != 1 or
        slot.operand_count != 3 or match.operand_count != 3 or load.operand_count != 2 or
        store.operand_count != 2 or jump.operand_count != 1)
        return null;
    const table = try self.operand(load_tag, 0);
    const checked = try self.operand(check_tag, 0);
    const tag = try self.operand(check_tag, 1);
    const check_fallback = try self.operand(check_tag, 2);
    const pointer_table = try self.operand(load_pointer, 0);
    const slot_pointer = try self.operand(slot, 0);
    const pc_operand = try self.operand(slot, 1);
    const key_operand = try self.operand(slot, 2);
    const matched_slot = try self.operand(match, 0);
    const matched_key = try self.operand(match, 1);
    const fallback = try self.operand(match, 2);
    const loaded_slot = try self.operand(load, 0);
    const load_offset = try self.operand(load, 1);
    const destination = try self.operand(store, 0);
    const stored = try self.operand(store, 1);
    const fast_target = try self.operand(jump, 0);
    if (table.kind != .vm_reg or table.value >= self.proto.max_stack_size or
        checked.kind != .instruction or checked.value != start or tag.kind != .constant or
        (try self.constant(tag.value)).tagValue() != lua_tag_table or
        ((check_fallback.kind != .block or check_fallback.value != fallback.value) and
            (check_fallback.kind != .vm_exit or check_fallback.value != ((try self.constant(pc_operand.value)).uintValue() orelse return null))) or
        pointer_table.kind != .vm_reg or pointer_table.value != table.value or
        slot_pointer.kind != .instruction or slot_pointer.value != start + 2 or pc_operand.kind != .constant or
        key_operand.kind != .vm_const or matched_slot.kind != .instruction or matched_slot.value != start + 3 or
        matched_key.kind != .vm_const or matched_key.value != key_operand.value or fallback.kind != .block or
        loaded_slot.kind != .instruction or loaded_slot.value != start + 3 or !try self.intOperandEquals(load_offset, 0) or
        destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
        stored.kind != .instruction or stored.value != start + 5 or fast_target.kind != .block)
        return null;
    const pc = (try self.constant(pc_operand.value)).uintValue() orelse return null;
    const key = (try self.stringKey(key_operand)) orelse return null;
    const rejoin = (try self.stringFallbackRejoin(fallback.value, .get, pc, destination.value, table.value, key_operand.value)) orelse return null;
    return .{ .operation = .get, .start = start, .pc = pc, .table = table.value, .value = destination.value, .key = key, .fallback = fallback.value, .fast_target = fast_target.value, .rejoin = rejoin };
}
pub noinline fn inlineStringGetPatternAt(self: anytype, start: u32, block: snapshot_v1.IrBlock) Error!?StringTablePattern {
    const commands = [_]snapshot_v1.IrCommand{
        .load_tag,               .check_tag,   .load_pointer, ir_cmd_get_slot_node_addr,
        ir_cmd_check_slot_match, .load_tvalue, .store_tvalue,
    };
    if (!block.kind.isCompilable() or block.isEmpty() or start < block.start or start > block.finish or
        block.finish - start < commands.len - 1 or !try self.commandRangeMatches(start, &commands))
        return null;

    const load_tag = try self.instruction(start);
    const check_tag = try self.instruction(start + 1);
    const load_pointer = try self.instruction(start + 2);
    const slot = try self.instruction(start + 3);
    const match = try self.instruction(start + 4);
    const load = try self.instruction(start + 5);
    const store = try self.instruction(start + 6);
    if (load_tag.operand_count != 1 or check_tag.operand_count != 3 or load_pointer.operand_count != 1 or
        slot.operand_count != 3 or match.operand_count != 3 or load.operand_count != 2 or store.operand_count != 2)
        return null;

    const table = try self.operand(load_tag, 0);
    const checked = try self.operand(check_tag, 0);
    const tag = try self.operand(check_tag, 1);
    const check_fallback = try self.operand(check_tag, 2);
    const pointer_table = try self.operand(load_pointer, 0);
    const slot_pointer = try self.operand(slot, 0);
    const pc_operand = try self.operand(slot, 1);
    const key_operand = try self.operand(slot, 2);
    const matched_slot = try self.operand(match, 0);
    const matched_key = try self.operand(match, 1);
    const fallback = try self.operand(match, 2);
    const loaded_slot = try self.operand(load, 0);
    const load_offset = try self.operand(load, 1);
    const destination = try self.operand(store, 0);
    const stored = try self.operand(store, 1);
    if (table.kind != .vm_reg or table.value >= self.proto.max_stack_size or
        checked.kind != .instruction or checked.value != start or tag.kind != .constant or
        (try self.constant(tag.value)).tagValue() != lua_tag_table or
        pointer_table.kind != .vm_reg or pointer_table.value != table.value or
        slot_pointer.kind != .instruction or slot_pointer.value != start + 2 or pc_operand.kind != .constant or
        key_operand.kind != .vm_const or matched_slot.kind != .instruction or matched_slot.value != start + 3 or
        matched_key.kind != .vm_const or matched_key.value != key_operand.value or fallback.kind != .block or
        loaded_slot.kind != .instruction or loaded_slot.value != start + 3 or !try self.intOperandEquals(load_offset, 0) or
        destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
        stored.kind != .instruction or stored.value != start + 5)
        return null;

    const pc = (try self.constant(pc_operand.value)).uintValue() orelse return null;
    if ((check_fallback.kind != .block or check_fallback.value != fallback.value) and
        (check_fallback.kind != .vm_exit or check_fallback.value != pc))
        return null;
    const key = (try self.stringKey(key_operand)) orelse return null;
    const rejoin = (try self.stringFallbackRejoin(fallback.value, .get, pc, destination.value, table.value, key_operand.value)) orelse return null;
    return .{ .operation = .get, .start = start, .pc = pc, .table = table.value, .value = destination.value, .key = key, .fallback = fallback.value, .fast_target = rejoin, .rejoin = rejoin };
}
pub noinline fn inlineGeneralStringSetPatternAt(self: anytype, start: u32, block: snapshot_v1.IrBlock) Error!?InlineStringTablePattern {
    const commands = [_]snapshot_v1.IrCommand{
        .load_tag,                 .check_tag,              .load_pointer,
        ir_cmd_get_slot_node_addr, ir_cmd_check_slot_match, ir_cmd_check_readonly,
        .load_tvalue,              .store_tvalue,           ir_cmd_barrier_table_forward,
    };
    if (!block.kind.isCompilable() or block.isEmpty() or start < block.start or start > block.finish or
        block.finish - start < commands.len - 1 or !try self.commandRangeMatches(start, &commands))
        return null;

    const load_tag = try self.instruction(start);
    const check_tag = try self.instruction(start + 1);
    const load_pointer = try self.instruction(start + 2);
    const slot = try self.instruction(start + 3);
    const match = try self.instruction(start + 4);
    const readonly = try self.instruction(start + 5);
    const load = try self.instruction(start + 6);
    const store = try self.instruction(start + 7);
    const barrier = try self.instruction(start + 8);
    if (load_tag.operand_count != 1 or check_tag.operand_count != 3 or load_pointer.operand_count != 1 or
        slot.operand_count != 3 or match.operand_count != 3 or readonly.operand_count != 2 or
        (load.operand_count != 1 and load.operand_count != 3) or store.operand_count != 3 or
        barrier.operand_count != 3)
        return null;

    const table = try self.operand(load_tag, 0);
    const checked = try self.operand(check_tag, 0);
    const tag = try self.operand(check_tag, 1);
    const check_fallback = try self.operand(check_tag, 2);
    const pointer_table = try self.operand(load_pointer, 0);
    const slot_pointer = try self.operand(slot, 0);
    const pc_operand = try self.operand(slot, 1);
    const key_operand = try self.operand(slot, 2);
    const matched_slot = try self.operand(match, 0);
    const matched_key = try self.operand(match, 1);
    const fallback = try self.operand(match, 2);
    const readonly_pointer = try self.operand(readonly, 0);
    const readonly_fallback = try self.operand(readonly, 1);
    const source = try self.operand(load, 0);
    const store_slot = try self.operand(store, 0);
    const store_value = try self.operand(store, 1);
    const store_offset = try self.operand(store, 2);
    const barrier_pointer = try self.operand(barrier, 0);
    const barrier_source = try self.operand(barrier, 1);
    const barrier_tag = try self.operand(barrier, 2);
    if (table.kind != .vm_reg or table.value >= self.proto.max_stack_size or
        checked.kind != .instruction or checked.value != start or tag.kind != .constant or
        (try self.constant(tag.value)).tagValue() != lua_tag_table or
        pointer_table.kind != .vm_reg or pointer_table.value != table.value or
        slot_pointer.kind != .instruction or slot_pointer.value != start + 2 or pc_operand.kind != .constant or
        key_operand.kind != .vm_const or matched_slot.kind != .instruction or matched_slot.value != start + 3 or
        matched_key.kind != .vm_const or matched_key.value != key_operand.value or fallback.kind != .block or
        readonly_pointer.kind != .instruction or readonly_pointer.value != start + 2 or
        readonly_fallback.kind != .block or readonly_fallback.value != fallback.value or
        source.kind != .vm_reg or source.value >= self.proto.max_stack_size or
        store_slot.kind != .instruction or store_slot.value != start + 3 or
        store_value.kind != .instruction or store_value.value != start + 6 or
        !try self.intOperandEquals(store_offset, 0) or
        barrier_pointer.kind != .instruction or barrier_pointer.value != start + 2 or
        barrier_source.kind != .vm_reg or barrier_source.value != source.value)
        return null;

    const pc = (try self.constant(pc_operand.value)).uintValue() orelse return null;
    if ((check_fallback.kind != .block or check_fallback.value != fallback.value) and
        (check_fallback.kind != .vm_exit or check_fallback.value != pc))
        return null;
    if (load.operand_count == 1) {
        if (barrier_tag.kind != .undef)
            return null;
    } else {
        const load_offset = try self.operand(load, 1);
        const load_value_tag = try self.operand(load, 2);
        if (!try self.intOperandEquals(load_offset, 0) or load_value_tag.kind != .constant or
            (try self.constant(load_value_tag.value)).tagValue() == null or barrier_tag.kind != .constant or
            (try self.constant(barrier_tag.value)).tagValue() != (try self.constant(load_value_tag.value)).tagValue())
            return null;
    }
    const key = (try self.stringKey(key_operand)) orelse return null;
    const rejoin = (try self.stringFallbackRejoin(fallback.value, .set, pc, source.value, table.value, key_operand.value)) orelse return null;
    return .{
        .pattern = .{
            .operation = .set,
            .start = start,
            .pc = pc,
            .table = table.value,
            .value = source.value,
            .key = key,
            .fallback = fallback.value,
            .fast_target = rejoin,
            .rejoin = rejoin,
        },
        .finish = start + 8,
    };
}
pub noinline fn inlinePreloadedStringSetPatternAt(self: anytype, start: u32, block: snapshot_v1.IrBlock) Error!?InlineStringTablePattern {
    const commands = [_]snapshot_v1.IrCommand{
        .load_tvalue,              .store_tvalue,           .nop, .nop,          .nop,
        ir_cmd_get_slot_node_addr, ir_cmd_check_slot_match, .nop, .store_tvalue, ir_cmd_barrier_table_forward,
    };
    if (!block.kind.isCompilable() or block.isEmpty() or start < block.start or start > block.finish or
        block.finish - start < commands.len - 1 or !try self.commandRangeMatches(start, &commands))
        return null;
    const publication = (try self.constantLoadPatternAt(start)) orelse return null;

    const slot_id = start + 5;
    const slot = try self.instruction(slot_id);
    const match = try self.instruction(start + 6);
    const store = try self.instruction(start + 8);
    const barrier = try self.instruction(start + 9);
    if (slot.operand_count != 3 or match.operand_count != 3 or store.operand_count != 3 or
        barrier.operand_count != 3)
        return null;

    const pointer_operand = try self.operand(slot, 0);
    const pc_operand = try self.operand(slot, 1);
    const key_operand = try self.operand(slot, 2);
    const matched_slot = try self.operand(match, 0);
    const matched_key = try self.operand(match, 1);
    const fallback = try self.operand(match, 2);
    const store_slot = try self.operand(store, 0);
    const store_value = try self.operand(store, 1);
    const store_offset = try self.operand(store, 2);
    const barrier_pointer = try self.operand(barrier, 0);
    const barrier_source = try self.operand(barrier, 1);
    const barrier_tag = try self.operand(barrier, 2);
    if (pointer_operand.kind != .instruction or pointer_operand.value < block.start or pointer_operand.value >= start or
        pc_operand.kind != .constant or key_operand.kind != .vm_const or
        matched_slot.kind != .instruction or matched_slot.value != slot_id or
        matched_key.kind != .vm_const or matched_key.value != key_operand.value or fallback.kind != .block or
        store_slot.kind != .instruction or store_slot.value != slot_id or
        store_value.kind != .instruction or store_value.value != start or
        !try self.intOperandEquals(store_offset, 0) or
        barrier_pointer.kind != .instruction or barrier_pointer.value != pointer_operand.value or
        barrier_source.kind != .vm_reg or barrier_source.value != publication.destination or
        barrier_tag.kind != .constant)
        return null;

    const pointer = try self.instruction(pointer_operand.value);
    if (pointer.command != .load_pointer or pointer.operand_count != 1)
        return null;
    const table = try self.operand(pointer, 0);
    if (table.kind != .vm_reg or table.value >= self.proto.max_stack_size)
        return null;
    const load = try self.instruction(start);
    const load_tag = try self.operand(load, 2);
    if (load_tag.kind != .constant or
        (try self.constant(load_tag.value)).tagValue() == null or
        (try self.constant(barrier_tag.value)).tagValue() != (try self.constant(load_tag.value)).tagValue())
        return null;

    const pc = (try self.constant(pc_operand.value)).uintValue() orelse return null;
    const key = (try self.stringKey(key_operand)) orelse return null;
    const rejoin = (try self.stringFallbackRejoin(fallback.value, .set, pc, publication.destination, table.value, key_operand.value)) orelse return null;
    return .{
        .pattern = .{
            .operation = .set,
            .start = start,
            .pc = pc,
            .table = table.value,
            .value = publication.destination,
            .key = key,
            .fallback = fallback.value,
            .fast_target = rejoin,
            .rejoin = rejoin,
        },
        .finish = start + 9,
    };
}

pub noinline fn inlineOwnedStringSetPatternAt(self: anytype, start: u32, block: snapshot_v1.IrBlock) Error!?InlineStringTablePattern {
    const cloned_commands = [_]snapshot_v1.IrCommand{
        ir_cmd_get_slot_node_addr, ir_cmd_check_slot_match, ir_cmd_check_readonly,
        .load_tvalue,              .store_tvalue,           ir_cmd_barrier_table_forward,
    };
    const trusted_commands = [_]snapshot_v1.IrCommand{
        ir_cmd_get_slot_node_addr, ir_cmd_check_slot_match, .nop,
        .load_tvalue,              .store_tvalue,           ir_cmd_barrier_table_forward,
    };
    if (!block.kind.isCompilable() or block.isEmpty() or start < block.start or start > block.finish or
        block.finish - start < cloned_commands.len - 1)
        return null;
    const cloned = try self.commandRangeMatches(start, &cloned_commands);
    if (!cloned and !try self.commandRangeMatches(start, &trusted_commands))
        return null;

    const slot = try self.instruction(start);
    const match = try self.instruction(start + 1);
    const ownership = try self.instruction(start + 2);
    const load = try self.instruction(start + 3);
    const store = try self.instruction(start + 4);
    const barrier = try self.instruction(start + 5);
    if (slot.operand_count != 3 or match.operand_count != 3 or
        (load.operand_count != 1 and load.operand_count != 3) or
        store.operand_count != 3 or barrier.operand_count != 3)
        return null;

    const pointer = try self.operand(slot, 0);
    const pc_operand = try self.operand(slot, 1);
    const key_operand = try self.operand(slot, 2);
    const matched_slot = try self.operand(match, 0);
    const matched_key = try self.operand(match, 1);
    const fallback = try self.operand(match, 2);
    const source = try self.operand(load, 0);
    const store_slot = try self.operand(store, 0);
    const store_value = try self.operand(store, 1);
    const store_offset = try self.operand(store, 2);
    const barrier_pointer = try self.operand(barrier, 0);
    const barrier_source = try self.operand(barrier, 1);
    const barrier_tag = try self.operand(barrier, 2);
    if (pointer.kind != .instruction or pc_operand.kind != .constant or key_operand.kind != .vm_const or
        matched_slot.kind != .instruction or matched_slot.value != start or
        matched_key.kind != .vm_const or matched_key.value != key_operand.value or fallback.kind != .block or
        source.kind != .vm_reg or source.value >= self.proto.max_stack_size or
        store_slot.kind != .instruction or store_slot.value != start or
        store_value.kind != .instruction or store_value.value != start + 3 or
        !try self.intOperandEquals(store_offset, 0) or
        barrier_pointer.kind != .instruction or barrier_pointer.value != pointer.value or
        barrier_source.kind != .vm_reg or barrier_source.value != source.value)
        return null;

    if (load.operand_count == 1) {
        if (barrier_tag.kind != .undef)
            return null;
    } else {
        const load_offset = try self.operand(load, 1);
        const load_tag = try self.operand(load, 2);
        if (!try self.intOperandEquals(load_offset, 0) or load_tag.kind != .constant or
            (try self.constant(load_tag.value)).tagValue() == null or barrier_tag.kind != .constant or
            (try self.constant(barrier_tag.value)).tagValue() != (try self.constant(load_tag.value)).tagValue())
            return null;
    }

    const table = if (cloned) blk: {
        if (ownership.operand_count != 2 or
            (try self.operand(ownership, 0)).kind != .instruction or
            (try self.operand(ownership, 0)).value != pointer.value or
            (try self.operand(ownership, 1)).kind != .block or
            (try self.operand(ownership, 1)).value != fallback.value)
            return null;
        break :blk (try self.dupTableRegisterForPointer(pointer.value)) orelse return null;
    } else blk: {
        if (ownership.operand_count != 0)
            return null;
        const covering = self.plan.tableAllocCovering(pointer.value) orelse return null;
        const allocation = (try self.tableAllocationPatternAt(covering.start)) orelse return null;
        if (allocation.start != pointer.value)
            return null;
        break :blk allocation.destination;
    };
    const pc = (try self.constant(pc_operand.value)).uintValue() orelse return null;
    const key = (try self.stringKey(key_operand)) orelse return null;
    const rejoin = (try self.stringFallbackRejoin(fallback.value, .set, pc, source.value, table, key_operand.value)) orelse return null;
    return .{
        .pattern = .{
            .operation = .set,
            .start = start,
            .pc = pc,
            .table = table,
            .value = source.value,
            .key = key,
            .fallback = fallback.value,
            .fast_target = rejoin,
            .rejoin = rejoin,
        },
        .finish = start + 5,
    };
}

pub noinline fn inlineStringSetPatternAt(self: anytype, start: u32, block: snapshot_v1.IrBlock) Error!?InlineStringTablePattern {
    if (try self.inlineGeneralStringSetPatternAt(start, block)) |pattern|
        return pattern;
    if (try self.inlinePreloadedStringSetPatternAt(start, block)) |pattern|
        return pattern;
    return self.inlineOwnedStringSetPatternAt(start, block);
}
pub noinline fn stringTablePattern(self: anytype, block: snapshot_v1.IrBlock) Error!?StringTablePattern {
    if (try self.stringSetPattern(block)) |pattern|
        return pattern;
    return self.stringGetPattern(block);
}

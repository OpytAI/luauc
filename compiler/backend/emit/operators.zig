const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");

const Error = model.Error;
const DynamicLengthPattern = model.DynamicLengthPattern;
const PowPattern = model.PowPattern;
const LinearizedPowPattern = model.LinearizedPowPattern;
const ConstantArithmeticPattern = model.ConstantArithmeticPattern;
const ConstantPowPattern = model.ConstantPowPattern;
const ir_cmd_invoke_libm = abi.ir_cmd_invoke_libm;
const lua_tag_number = abi.lua_tag_number;
const upstream_tm_pow = abi.upstream_tm_pow;
const lbf_math_pow = abi.lbf_math_pow;

pub noinline fn powPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?PowPattern {
    const tagged_commands = [_]snapshot_v1.IrCommand{
        .load_tag,    .check_tag,         .load_tag,     .check_tag, .load_double,
        .load_double, ir_cmd_invoke_libm, .store_double, .store_tag, .jump,
    };
    const established_tag_commands = [_]snapshot_v1.IrCommand{
        .load_tag,    .check_tag,         .load_tag,     .check_tag, .load_double,
        .load_double, ir_cmd_invoke_libm, .store_double, .jump,
    };
    if (!block.kind.isCompilable() or block.isEmpty())
        return null;
    const has_store_tag = block.finish >= block.start + tagged_commands.len - 1 and
        try self.commandRangeMatches(block.finish - @as(u32, @intCast(tagged_commands.len - 1)), &tagged_commands);
    const uses_established_tag = !has_store_tag and block.finish >= block.start + established_tag_commands.len - 1 and
        try self.commandRangeMatches(
            block.finish - @as(u32, @intCast(established_tag_commands.len - 1)),
            &established_tag_commands,
        );
    if (!has_store_tag and !uses_established_tag)
        return null;
    const command_count = if (has_store_tag) tagged_commands.len else established_tag_commands.len;
    const start = block.finish - @as(u32, @intCast(command_count - 1));

    const lhs = try self.vmRegisterIndex(try self.operand(try self.instruction(start), 0));
    const lhs_check = try self.instruction(start + 1);
    const rhs = try self.vmRegisterIndex(try self.operand(try self.instruction(start + 2), 0));
    const rhs_check = try self.instruction(start + 3);
    const lhs_load = try self.instruction(start + 4);
    const rhs_load = try self.instruction(start + 5);
    const invoke = try self.instruction(start + 6);
    const store = try self.instruction(start + 7);
    const store_tag = if (has_store_tag) try self.instruction(start + 8) else null;
    const jump = try self.instruction(start + (if (has_store_tag) @as(u32, 9) else 8));
    if (lhs_check.operand_count != 3 or rhs_check.operand_count != 3 or lhs_load.operand_count != 1 or
        rhs_load.operand_count != 1 or invoke.operand_count != 3 or store.operand_count != 2 or
        (has_store_tag and store_tag.?.operand_count != 2) or jump.operand_count != 1)
        return null;
    const fallback = try self.operand(lhs_check, 2);
    const rhs_fallback = try self.operand(rhs_check, 2);
    const fast_rejoin = try self.operand(jump, 0);
    if ((try self.operand(lhs_check, 0)).kind != .instruction or (try self.operand(lhs_check, 0)).value != start or
        (try self.operand(lhs_check, 1)).kind != .constant or
        (try self.constant((try self.operand(lhs_check, 1)).value)).tagValue() != lua_tag_number or
        fallback.kind != .block or
        (try self.operand(rhs_check, 0)).kind != .instruction or (try self.operand(rhs_check, 0)).value != start + 2 or
        (try self.operand(rhs_check, 1)).kind != .constant or
        (try self.constant((try self.operand(rhs_check, 1)).value)).tagValue() != lua_tag_number or
        rhs_fallback.kind != .block or rhs_fallback.value != fallback.value or
        (try self.operand(lhs_load, 0)).kind != .vm_reg or (try self.operand(lhs_load, 0)).value != lhs or
        (try self.operand(rhs_load, 0)).kind != .vm_reg or (try self.operand(rhs_load, 0)).value != rhs or
        (try self.operand(invoke, 0)).kind != .constant or
        (try self.constant((try self.operand(invoke, 0)).value)).uintValue() != lbf_math_pow or
        (try self.operand(invoke, 1)).kind != .instruction or (try self.operand(invoke, 1)).value != start + 4 or
        (try self.operand(invoke, 2)).kind != .instruction or (try self.operand(invoke, 2)).value != start + 5 or
        (try self.operand(store, 0)).kind != .vm_reg or (try self.operand(store, 1)).kind != .instruction or
        (try self.operand(store, 1)).value != start + 6 or
        fast_rejoin.kind != .block)
        return null;
    const destination = try self.vmRegisterIndex(try self.operand(store, 0));
    if (has_store_tag) {
        if ((try self.operand(store_tag.?, 0)).kind != .vm_reg or
            (try self.operand(store_tag.?, 0)).value != destination or
            (try self.operand(store_tag.?, 1)).kind != .constant or
            (try self.constant((try self.operand(store_tag.?, 1)).value)).tagValue() != lua_tag_number)
            return null;
    } else if (destination != lhs) {
        // The pin omits STORE_TAG only when the successful lhs number guard already proves the
        // overwritten destination register carries the number tag on the direct path.
        return null;
    }

    const fallback_block = try self.snapshot.irBlock(self.function, fallback.value);
    if (!try self.supportsArithmeticFallback(fallback_block))
        return null;
    const marker = try self.instruction(fallback_block.start);
    const arithmetic_id = fallback_block.start + 1;
    const arithmetic = try self.instruction(arithmetic_id);
    const fallback_rejoin = try self.operand(try self.instruction(fallback_block.finish), 0);
    if ((try self.operand(arithmetic, 0)).kind != .vm_reg or (try self.operand(arithmetic, 0)).value != destination or
        (try self.operand(arithmetic, 1)).kind != .vm_reg or (try self.operand(arithmetic, 1)).value != lhs or
        (try self.operand(arithmetic, 2)).kind != .vm_reg or (try self.operand(arithmetic, 2)).value != rhs or
        (try self.operand(arithmetic, 3)).kind != .constant or
        (try self.constant((try self.operand(arithmetic, 3)).value)).intValue() != upstream_tm_pow or
        fallback_rejoin.kind != .block)
        return null;
    return .{
        .start = start,
        .destination = destination,
        .lhs = lhs,
        .rhs = rhs,
        .fast_target = try self.requireCompiledTarget(fast_rejoin),
        .rejoin = try self.requireCompiledTarget(fallback_rejoin),
        .marker = marker,
        .arithmetic_id = arithmetic_id,
    };
}
pub fn powValueRegister(self: anytype, operand_value: snapshot_v1.IrOperand, before: u32) Error!?u32 {
    if (operand_value.kind != .instruction or operand_value.value >= before)
        return null;
    const producer = try self.instruction(operand_value.value);
    if (producer.command == .load_double and producer.operand_count == 1)
        return self.vmRegisterIndex(try self.operand(producer, 0)) catch return null;
    if (producer.command != ir_cmd_invoke_libm or producer.operand_count != 3 or
        operand_value.value + 1 >= before)
        return null;
    const bfid = try self.operand(producer, 0);
    const publication = try self.instruction(operand_value.value + 1);
    if (bfid.kind != .constant or (try self.constant(bfid.value)).uintValue() != lbf_math_pow or
        publication.command != .store_double or publication.operand_count != 2 or
        (try self.operand(publication, 1)).kind != .instruction or
        (try self.operand(publication, 1)).value != operand_value.value)
        return null;
    return self.vmRegisterIndex(try self.operand(publication, 0)) catch return null;
}
pub fn numericCommandMetamethod(_: anytype, command: snapshot_v1.IrCommand) ?i32 {
    return switch (command) {
        .add_num => 8,
        .sub_num => 9,
        .mul_num => 10,
        .div_num => 11,
        .idiv_num => 12,
        .mod_num => 13,
        else => null,
    };
}
pub noinline fn constantArithmeticPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?ConstantArithmeticPattern {
    if (!block.kind.isCompilable() or block.isEmpty() or block.finish < block.start + 5)
        return null;
    const possible_tag = try self.instruction(block.finish - 1);
    const has_store_tag = possible_tag.command == .store_tag;
    if (has_store_tag and block.finish < block.start + 6)
        return null;
    const start = block.finish - (if (has_store_tag) @as(u32, 6) else 5);
    const load_tag = try self.instruction(start);
    const check_tag = try self.instruction(start + 1);
    const load = try self.instruction(start + 2);
    const arithmetic_id = start + 3;
    const arithmetic = try self.instruction(arithmetic_id);
    const store = try self.instruction(start + 4);
    const store_tag = if (has_store_tag) try self.instruction(start + 5) else null;
    const jump = try self.instruction(block.finish);
    const upstream_operation = self.numericCommandMetamethod(arithmetic.command) orelse return null;
    if (load_tag.command != .load_tag or check_tag.command != .check_tag or load.command != .load_double or
        store.command != .store_double or jump.command != .jump or load_tag.operand_count != 1 or
        check_tag.operand_count != 3 or load.operand_count != 1 or arithmetic.operand_count != 2 or
        store.operand_count != 2 or (has_store_tag and store_tag.?.operand_count != 2) or jump.operand_count != 1)
        return null;
    const source = try self.operand(load_tag, 0);
    const checked = try self.operand(check_tag, 0);
    const checked_tag = try self.operand(check_tag, 1);
    const fallback = try self.operand(check_tag, 2);
    const loaded_source = try self.operand(load, 0);
    const lhs_direct = try self.operand(arithmetic, 0);
    const rhs_direct = try self.operand(arithmetic, 1);
    const destination = try self.operand(store, 0);
    const stored = try self.operand(store, 1);
    const fast_target = try self.operand(jump, 0);
    if (source.kind != .vm_reg or source.value >= self.proto.max_stack_size or
        checked.kind != .instruction or checked.value != start or checked_tag.kind != .constant or
        (try self.constant(checked_tag.value)).tagValue() != lua_tag_number or fallback.kind != .block or
        loaded_source.kind != .vm_reg or loaded_source.value != source.value or destination.kind != .vm_reg or
        destination.value >= self.proto.max_stack_size or stored.kind != .instruction or stored.value != arithmetic_id or
        fast_target.kind != .block)
        return null;
    const register_is_lhs = lhs_direct.kind == .instruction and lhs_direct.value == start + 2 and rhs_direct.kind == .constant;
    const register_is_rhs = rhs_direct.kind == .instruction and rhs_direct.value == start + 2 and lhs_direct.kind == .constant;
    if (register_is_lhs == register_is_rhs)
        return null;
    if (has_store_tag) {
        if ((try self.operand(store_tag.?, 0)).kind != .vm_reg or
            (try self.operand(store_tag.?, 0)).value != destination.value or
            (try self.operand(store_tag.?, 1)).kind != .constant or
            (try self.constant((try self.operand(store_tag.?, 1)).value)).tagValue() != lua_tag_number)
            return null;
    } else if (destination.value != source.value) {
        return null;
    }

    const direct_constant = try self.constant((if (register_is_lhs) rhs_direct else lhs_direct).value);
    if (direct_constant.doubleValue() == null)
        return null;
    const fallback_block = try self.snapshot.irBlock(self.function, fallback.value);
    if (!try self.supportsArithmeticFallback(fallback_block))
        return null;
    const marker = try self.instruction(fallback_block.start);
    const fallback_arithmetic_id = fallback_block.start + 1;
    const fallback_arithmetic = try self.instruction(fallback_arithmetic_id);
    const fallback_destination = try self.operand(fallback_arithmetic, 0);
    const fallback_lhs = try self.operand(fallback_arithmetic, 1);
    const fallback_rhs = try self.operand(fallback_arithmetic, 2);
    const fallback_operation = try self.operand(fallback_arithmetic, 3);
    const fallback_rejoin = try self.operand(try self.instruction(fallback_block.finish), 0);
    const constant_operand = if (register_is_lhs) fallback_rhs else fallback_lhs;
    const register_operand = if (register_is_lhs) fallback_lhs else fallback_rhs;
    if (fallback_destination.kind != .vm_reg or fallback_destination.value != destination.value or
        register_operand.kind != .vm_reg or register_operand.value != source.value or
        constant_operand.kind != .vm_const or constant_operand.value >= self.proto.vm_constant_count or
        fallback_operation.kind != .constant or
        (try self.constant(fallback_operation.value)).intValue() != upstream_operation or
        fallback_rejoin.kind != .block)
        return null;
    const vm_constant = try self.snapshot.vmConstant(self.proto, constant_operand.value);
    if (vm_constant.kind != .number or vm_constant.bits0 != direct_constant.bits)
        return null;
    // Preserve the established numeric fast path when both arms already rejoin the same
    // canonical block. This fused helper exists only to replace optimizer-owned divergent
    // linearized copies, whose duplicated middle-of-block commands cannot be emitted safely.
    if (fast_target.value == fallback_rejoin.value)
        return null;
    return .{
        .start = start,
        .fast_target = try self.requireCompiledTarget(fast_target),
        .rejoin = try self.requireCompiledTarget(fallback_rejoin),
        .marker = marker,
        .arithmetic_id = fallback_arithmetic_id,
    };
}
pub fn integerPowExponent(self: anytype, instruction_id: u32, load_id: u32, limit: u32) Error!?u32 {
    if (instruction_id == load_id)
        return 1;
    if (instruction_id <= load_id or instruction_id >= limit)
        return null;
    const instruction_value = try self.instruction(instruction_id);
    if (instruction_value.command != .mul_num or instruction_value.operand_count != 2)
        return null;
    const lhs = try self.operand(instruction_value, 0);
    const rhs = try self.operand(instruction_value, 1);
    if (lhs.kind != .instruction or rhs.kind != .instruction)
        return null;
    const lhs_exponent = (try self.integerPowExponent(lhs.value, load_id, instruction_id)) orelse return null;
    const rhs_exponent = (try self.integerPowExponent(rhs.value, load_id, instruction_id)) orelse return null;
    return std.math.add(u32, lhs_exponent, rhs_exponent) catch null;
}
pub noinline fn constantPowPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?ConstantPowPattern {
    if (!block.kind.isCompilable() or block.isEmpty() or block.finish < block.start + 6)
        return null;
    const possible_tag = try self.instruction(block.finish - 1);
    const has_store_tag = possible_tag.command == .store_tag;
    const store_id = block.finish - (if (has_store_tag) @as(u32, 2) else 1);
    if (store_id < block.start + 4)
        return null;
    const store = try self.instruction(store_id);
    const jump = try self.instruction(block.finish);
    if (store.command != .store_double or store.operand_count != 2 or jump.command != .jump or jump.operand_count != 1)
        return null;
    const destination = try self.operand(store, 0);
    const result = try self.operand(store, 1);
    const fast_target = try self.operand(jump, 0);
    if (destination.kind != .vm_reg or destination.value >= self.proto.max_stack_size or
        result.kind != .instruction or result.value + 1 != store_id or fast_target.kind != .block)
        return null;
    if (has_store_tag) {
        if ((try self.operand(possible_tag, 0)).kind != .vm_reg or
            (try self.operand(possible_tag, 0)).value != destination.value or
            (try self.operand(possible_tag, 1)).kind != .constant or
            (try self.constant((try self.operand(possible_tag, 1)).value)).tagValue() != lua_tag_number)
            return null;
    }

    const direct_result = try self.instruction(result.value);
    if (direct_result.command == ir_cmd_invoke_libm and direct_result.operand_count == 3) {
        const bfid = try self.operand(direct_result, 0);
        const direct_lhs = try self.operand(direct_result, 1);
        const direct_rhs = try self.operand(direct_result, 2);
        if (bfid.kind == .constant and (try self.constant(bfid.value)).uintValue() == lbf_math_pow and
            direct_lhs.kind == .constant and direct_rhs.kind == .instruction)
        constant_left: {
            const direct_constant = try self.constant(direct_lhs.value);
            if (direct_constant.doubleValue() == null)
                break :constant_left;
            const load = try self.instruction(direct_rhs.value);
            if (load.command != .load_double or load.operand_count != 1)
                break :constant_left;
            const loaded = try self.operand(load, 0);
            if (loaded.kind != .vm_reg)
                break :constant_left;
            var guard_start = block.start;
            var guarded = false;
            var fallback_id: u32 = 0;
            while (guard_start + 1 < direct_rhs.value) : (guard_start += 1) {
                const load_tag = try self.instruction(guard_start);
                const check = try self.instruction(guard_start + 1);
                if (load_tag.command != .load_tag or check.command != .check_tag or
                    load_tag.operand_count != 1 or check.operand_count != 3)
                    continue;
                const source = try self.operand(load_tag, 0);
                const checked = try self.operand(check, 0);
                const tag = try self.operand(check, 1);
                const fallback = try self.operand(check, 2);
                if (source.kind == .vm_reg and source.value == loaded.value and checked.kind == .instruction and
                    checked.value == guard_start and tag.kind == .constant and
                    (try self.constant(tag.value)).tagValue() == lua_tag_number and fallback.kind == .block)
                {
                    guarded = true;
                    fallback_id = fallback.value;
                    break;
                }
            }
            if (!guarded)
                break :constant_left;
            const fallback_block = try self.snapshot.irBlock(self.function, fallback_id);
            if (!try self.supportsArithmeticFallback(fallback_block))
                break :constant_left;
            const marker = try self.instruction(fallback_block.start);
            const arithmetic_id = fallback_block.start + 1;
            const arithmetic = try self.instruction(arithmetic_id);
            const fallback_destination = try self.operand(arithmetic, 0);
            const fallback_lhs = try self.operand(arithmetic, 1);
            const fallback_rhs = try self.operand(arithmetic, 2);
            const operation = try self.operand(arithmetic, 3);
            const fallback_rejoin = try self.operand(try self.instruction(fallback_block.finish), 0);
            if (fallback_destination.kind != .vm_reg or fallback_destination.value != destination.value or
                fallback_lhs.kind != .vm_reg or fallback_rhs.kind != .vm_reg or fallback_rhs.value != loaded.value or
                operation.kind != .constant or (try self.constant(operation.value)).intValue() != upstream_tm_pow or
                fallback_rejoin.kind != .block)
                break :constant_left;
            var materialized = false;
            var materialize_id = block.start;
            while (materialize_id + 1 < guard_start) : (materialize_id += 1) {
                const materialize = try self.instruction(materialize_id);
                const materialize_tag = try self.instruction(materialize_id + 1);
                if (materialize.command != .store_double or materialize.operand_count != 2 or
                    materialize_tag.command != .store_tag or materialize_tag.operand_count != 2)
                    continue;
                const materialize_destination = try self.operand(materialize, 0);
                const materialize_value = try self.operand(materialize, 1);
                if (materialize_destination.kind == .vm_reg and materialize_destination.value == fallback_lhs.value and
                    materialize_value.kind == .constant and (try self.constant(materialize_value.value)).bits == direct_constant.bits and
                    (try self.operand(materialize_tag, 0)).kind == .vm_reg and
                    (try self.operand(materialize_tag, 0)).value == fallback_lhs.value and
                    (try self.operand(materialize_tag, 1)).kind == .constant and
                    (try self.constant((try self.operand(materialize_tag, 1)).value)).tagValue() == lua_tag_number)
                {
                    materialized = true;
                    break;
                }
            }
            if (!materialized)
                break :constant_left;
            return .{
                .start = guard_start,
                .fast_target = try self.requireCompiledTarget(fast_target),
                .rejoin = try self.requireCompiledTarget(fallback_rejoin),
                .marker = marker,
                .arithmetic_id = arithmetic_id,
            };
        }
    }

    // The pin strength-reduces a variable raised to a positive integer constant into an exact
    // multiplication DAG rooted in one guarded LOAD_DOUBLE.
    var start = block.start;
    while (start + 3 < store_id) : (start += 1) {
        const load_tag = try self.instruction(start);
        const check = try self.instruction(start + 1);
        const load = try self.instruction(start + 2);
        if (load_tag.command != .load_tag or check.command != .check_tag or load.command != .load_double or
            load_tag.operand_count != 1 or check.operand_count != 3 or load.operand_count != 1)
            continue;
        const source = try self.operand(load_tag, 0);
        const checked = try self.operand(check, 0);
        const tag = try self.operand(check, 1);
        const fallback = try self.operand(check, 2);
        const loaded = try self.operand(load, 0);
        if (source.kind != .vm_reg or source.value >= self.proto.max_stack_size or
            checked.kind != .instruction or checked.value != start or tag.kind != .constant or
            (try self.constant(tag.value)).tagValue() != lua_tag_number or fallback.kind != .block or
            loaded.kind != .vm_reg or loaded.value != source.value)
            continue;
        const exponent = (try self.integerPowExponent(result.value, start + 2, store_id)) orelse continue;
        const fallback_block = try self.snapshot.irBlock(self.function, fallback.value);
        if (!try self.supportsArithmeticFallback(fallback_block))
            continue;
        const marker = try self.instruction(fallback_block.start);
        const arithmetic_id = fallback_block.start + 1;
        const arithmetic = try self.instruction(arithmetic_id);
        const fallback_destination = try self.operand(arithmetic, 0);
        const fallback_lhs = try self.operand(arithmetic, 1);
        const fallback_rhs = try self.operand(arithmetic, 2);
        const operation = try self.operand(arithmetic, 3);
        const fallback_rejoin = try self.operand(try self.instruction(fallback_block.finish), 0);
        if (fallback_destination.kind != .vm_reg or fallback_destination.value != destination.value or
            fallback_lhs.kind != .vm_reg or fallback_lhs.value != source.value or fallback_rhs.kind != .vm_const or
            fallback_rhs.value >= self.proto.vm_constant_count or operation.kind != .constant or
            (try self.constant(operation.value)).intValue() != upstream_tm_pow or fallback_rejoin.kind != .block)
            continue;
        const exponent_constant = try self.snapshot.vmConstant(self.proto, fallback_rhs.value);
        if (exponent_constant.kind != .number or exponent_constant.bits0 != @as(u64, @bitCast(@as(f64, @floatFromInt(exponent)))))
            continue;
        return .{
            .start = start,
            .fast_target = try self.requireCompiledTarget(fast_target),
            .rejoin = try self.requireCompiledTarget(fallback_rejoin),
            .marker = marker,
            .arithmetic_id = arithmetic_id,
        };
    }
    return null;
}
pub noinline fn linearizedPowPattern(self: anytype, instruction_id: u32, block: snapshot_v1.IrBlock) Error!?LinearizedPowPattern {
    if (block.kind != .linearized or instruction_id >= block.finish)
        return null;
    const invoke = try self.instruction(instruction_id);
    const store = try self.instruction(instruction_id + 1);
    if (invoke.command != ir_cmd_invoke_libm or invoke.operand_count != 3 or
        store.command != .store_double or store.operand_count != 2)
        return null;
    const bfid = try self.operand(invoke, 0);
    const destination = try self.vmRegisterIndex(try self.operand(store, 0));
    if (bfid.kind != .constant or (try self.constant(bfid.value)).uintValue() != lbf_math_pow or
        (try self.operand(store, 1)).kind != .instruction or
        (try self.operand(store, 1)).value != instruction_id)
        return null;
    const lhs = (try self.powValueRegister(try self.operand(invoke, 1), instruction_id)) orelse return null;
    const rhs = (try self.powValueRegister(try self.operand(invoke, 2), instruction_id)) orelse return null;

    var finish = instruction_id + 1;
    if (finish < block.finish) {
        const possible_tag = try self.instruction(finish + 1);
        if (possible_tag.command == .store_tag and possible_tag.operand_count == 2 and
            (try self.operand(possible_tag, 0)).kind == .vm_reg and
            (try self.operand(possible_tag, 0)).value == destination and
            (try self.operand(possible_tag, 1)).kind == .constant and
            (try self.constant((try self.operand(possible_tag, 1)).value)).tagValue() == lua_tag_number)
            finish += 1;
    }
    if (finish == instruction_id + 1 and destination != lhs)
        return null;

    // Linearization preserves source order but may reuse the same VM tuple for several pow
    // sites. Select the Nth canonical site for the Nth matching linearized occurrence instead
    // of requiring tuple uniqueness.
    var ordinal: u32 = 0;
    var cursor = block.start;
    while (cursor < instruction_id) : (cursor += 1) {
        const prior = try self.instruction(cursor);
        if (prior.command != ir_cmd_invoke_libm or prior.operand_count != 3 or cursor + 1 > block.finish)
            continue;
        const prior_bfid = try self.operand(prior, 0);
        if (prior_bfid.kind != .constant or (try self.constant(prior_bfid.value)).uintValue() != lbf_math_pow)
            continue;
        const prior_store = try self.instruction(cursor + 1);
        if (prior_store.command != .store_double or prior_store.operand_count != 2)
            continue;
        const prior_destination = self.vmRegisterIndex(try self.operand(prior_store, 0)) catch continue;
        const prior_lhs = (try self.powValueRegister(try self.operand(prior, 1), cursor)) orelse continue;
        const prior_rhs = (try self.powValueRegister(try self.operand(prior, 2), cursor)) orelse continue;
        if (prior_destination == destination and prior_lhs == lhs and prior_rhs == rhs)
            ordinal += 1;
    }

    var selected: ?PowPattern = null;
    var previous_start: ?u32 = null;
    var index: u32 = 0;
    while (index <= ordinal) : (index += 1) {
        var next: ?PowPattern = null;
        for (self.plan.pow_sites) |pattern| {
            if (pattern.destination != destination or pattern.lhs != lhs or pattern.rhs != rhs or
                (previous_start != null and pattern.start <= previous_start.?) or
                (next != null and pattern.start >= next.?.start))
                continue;
            next = pattern;
        }
        selected = next orelse return null;
        previous_start = selected.?.start;
    }
    return .{
        .finish = finish,
        .marker = selected.?.marker,
        .arithmetic_id = selected.?.arithmetic_id,
    };
}
pub noinline fn emitPowBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock, pattern: PowPattern) Error!void {
    _ = block_id;
    if (pattern.start > block.start) {
        if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
            return;
    }
    try self.emitSavedPcLocation(pattern.marker);
    try self.emitDoArith(pattern.arithmetic_id, try self.instruction(pattern.arithmetic_id));
    try self.body.i32Const(self.allocator, @intCast(pattern.rejoin));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.branch(self.allocator, self.loop_branch_depth);
}
pub noinline fn emitConstantArithmeticBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock, pattern: ConstantArithmeticPattern) Error!void {
    _ = block_id;
    if (pattern.start > block.start) {
        if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
            return;
    }
    try self.emitSavedPcLocation(pattern.marker);
    try self.emitDoArith(pattern.arithmetic_id, try self.instruction(pattern.arithmetic_id));
    try self.body.i32Const(self.allocator, @intCast(pattern.rejoin));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.branch(self.allocator, self.loop_branch_depth);
}
pub noinline fn emitDynamicLengthBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock, pattern: DynamicLengthPattern) Error!void {
    _ = block_id;
    if (pattern.start > block.start) {
        if (try self.emitInstructionRange(block.start, pattern.start - 1, block))
            return;
    }
    try self.emitDynamicLength(pattern);
    try self.body.branch(self.allocator, self.loop_branch_depth);
}
pub noinline fn emitDynamicLength(self: anytype, pattern: DynamicLengthPattern) Error!void {
    try self.emitSavedPcLocation(pattern.marker);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(pattern.destination));
    try self.body.i32Const(self.allocator, @intCast(pattern.source));
    try self.body.call(self.allocator, self.do_len orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
    try self.body.i32Const(self.allocator, @intCast(pattern.rejoin));
    try self.body.localSet(self.allocator, self.dispatch_local);
}

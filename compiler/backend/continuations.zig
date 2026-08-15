const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");
const Context = @import("luauc_backend_context").Context;

const Error = model.Error;
const ValueShape = model.ValueShape;
const ContinuationAction = model.ContinuationAction;
const CallContinuation = model.CallContinuation;
const GenericIterationPattern = model.GenericIterationPattern;
const ir_cmd_new_userdata = abi.ir_cmd_new_userdata;
const ir_cmd_forgloop_fallback = abi.ir_cmd_forgloop_fallback;
const ir_cmd_string_len = abi.ir_cmd_string_len;
const ir_cmd_invoke_libm = abi.ir_cmd_invoke_libm;
const ir_cmd_buffer_readi8 = abi.ir_cmd_buffer_readi8;
const ir_cmd_buffer_readu8 = abi.ir_cmd_buffer_readu8;
const ir_cmd_buffer_readi16 = abi.ir_cmd_buffer_readi16;
const ir_cmd_buffer_readu16 = abi.ir_cmd_buffer_readu16;
const ir_cmd_buffer_readi32 = abi.ir_cmd_buffer_readi32;
const ir_cmd_buffer_readf32 = abi.ir_cmd_buffer_readf32;
const ir_cmd_buffer_readf64 = abi.ir_cmd_buffer_readf64;
const ir_cmd_buffer_readi64 = abi.ir_cmd_buffer_readi64;

pub fn validateContinuationRegion(
    allocator: std.mem.Allocator,
    context: Context,
    continuation_block_id: u32,
    suffix_start: u32,
    block_finish: u32,
) Error!bool {
    if (continuation_block_id >= context.function.block_count or
        suffix_start > block_finish or block_finish >= context.function.instruction_count)
        return Error.UnsupportedControlFlow;

    const reachable_blocks = try allocator.alloc(bool, context.function.block_count);
    defer allocator.free(reachable_blocks);
    @memset(reachable_blocks, false);
    const reachable_instructions = try allocator.alloc(bool, context.function.instruction_count);
    defer allocator.free(reachable_instructions);
    @memset(reachable_instructions, false);
    const instruction_blocks = try allocator.alloc(u32, context.function.instruction_count);
    defer allocator.free(instruction_blocks);
    @memset(instruction_blocks, snapshot_v1.no_id);
    const edge_count = std.math.mul(usize, context.function.block_count, context.function.block_count) catch
        return Error.ResourceLimit;
    const edges = try allocator.alloc(bool, edge_count);
    defer allocator.free(edges);
    @memset(edges, false);

    var pending_blocks: std.ArrayList(u32) = .empty;
    defer pending_blocks.deinit(allocator);

    reachable_blocks[continuation_block_id] = true;
    var instruction_id = suffix_start;
    while (instruction_id <= block_finish) : (instruction_id += 1) {
        reachable_instructions[instruction_id] = true;
        instruction_blocks[instruction_id] = continuation_block_id;
        const instruction_value = try context.instruction(instruction_id);
        var operand_id: u32 = 0;
        while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
            const operand_value = try context.operand(instruction_value, operand_id);
            if (operand_value.kind != .block)
                continue;
            if (operand_value.value >= context.function.block_count)
                return false;
            // A loop back to the interrupted block re-enters its ordinary generated dispatch arm
            // from the beginning, where all of that iteration's SSA values are recomputed. It is a
            // safe boundary of the resumed suffix, not a dependency on the pre-suspension locals.
            if (operand_value.value == continuation_block_id)
                continue;
            edges[@as(usize, continuation_block_id) * context.function.block_count + operand_value.value] = true;
            try pending_blocks.append(allocator, operand_value.value);
        }
    }

    while (pending_blocks.items.len != 0) {
        const block_id = pending_blocks.items[pending_blocks.items.len - 1];
        pending_blocks.items.len -= 1;
        if (block_id >= context.function.block_count)
            return Error.UnsupportedControlFlow;
        if (reachable_blocks[block_id])
            continue;
        const block = try context.snapshot.irBlock(context.function, block_id);
        if (block.isEmpty())
            continue;

        // Continuation reachability must describe the CFG that this backend actually emits. A
        // non-compilable block, including a fallback outside the current semantic coverage, has no
        // generated dispatch arm and therefore terminates at the function's fail-closed internal
        // status. Do not follow its raw optimizer edges into blocks that generated code cannot reach.
        if (!block.kind.isCompilable() and
            (block.kind != .fallback or !try context.supportsFallback(block)))
            continue;

        reachable_blocks[block_id] = true;

        instruction_id = block.start;
        while (instruction_id <= block.finish) : (instruction_id += 1) {
            if (instruction_id >= context.function.instruction_count)
                return Error.UnsupportedControlFlow;
            reachable_instructions[instruction_id] = true;
            instruction_blocks[instruction_id] = block_id;
            const instruction_value = try context.instruction(instruction_id);
            var operand_id: u32 = 0;
            while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                const operand_value = try context.operand(instruction_value, operand_id);
                if (operand_value.kind != .block)
                    continue;
                if (operand_value.value >= context.function.block_count)
                    return false;
                if (operand_value.value == continuation_block_id)
                    continue;
                edges[@as(usize, block_id) * context.function.block_count + operand_value.value] = true;
                try pending_blocks.append(allocator, operand_value.value);
            }
        }
    }

    const dominators = try allocator.alloc(bool, edge_count);
    defer allocator.free(dominators);
    @memset(dominators, false);
    var block_id: u32 = 0;
    while (block_id < context.function.block_count) : (block_id += 1) {
        if (!reachable_blocks[block_id])
            continue;
        var candidate: u32 = 0;
        while (candidate < context.function.block_count) : (candidate += 1) {
            if (reachable_blocks[candidate] and
                (block_id != continuation_block_id or candidate == continuation_block_id))
                dominators[@as(usize, block_id) * context.function.block_count + candidate] = true;
        }
    }

    var changed = true;
    while (changed) {
        changed = false;
        block_id = 0;
        while (block_id < context.function.block_count) : (block_id += 1) {
            if (!reachable_blocks[block_id] or block_id == continuation_block_id)
                continue;
            var candidate: u32 = 0;
            while (candidate < context.function.block_count) : (candidate += 1) {
                if (!reachable_blocks[candidate])
                    continue;
                var desired = candidate == block_id;
                if (!desired) {
                    desired = true;
                    var has_predecessor = false;
                    var predecessor: u32 = 0;
                    while (predecessor < context.function.block_count) : (predecessor += 1) {
                        if (!reachable_blocks[predecessor] or
                            !edges[@as(usize, predecessor) * context.function.block_count + block_id])
                            continue;
                        has_predecessor = true;
                        if (!dominators[@as(usize, predecessor) * context.function.block_count + candidate]) {
                            desired = false;
                            break;
                        }
                    }
                    desired = desired and has_predecessor;
                }
                const index = @as(usize, block_id) * context.function.block_count + candidate;
                if (dominators[index] != desired) {
                    dominators[index] = desired;
                    changed = true;
                }
            }
        }
    }

    instruction_id = 0;
    while (instruction_id < context.function.instruction_count) : (instruction_id += 1) {
        if (!reachable_instructions[instruction_id])
            continue;
        const instruction_value = try context.instruction(instruction_id);
        var operand_id: u32 = 0;
        while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
            const operand_value = try context.operand(instruction_value, operand_id);
            if (operand_value.kind != .instruction)
                continue;
            if (operand_value.value >= context.function.instruction_count or
                !reachable_instructions[operand_value.value])
                return false;
            const producer_block = instruction_blocks[operand_value.value];
            const consumer_block = instruction_blocks[instruction_id];
            if (producer_block == consumer_block) {
                if (operand_value.value >= instruction_id)
                    return false;
            } else if (!dominators[@as(usize, consumer_block) * context.function.block_count + producer_block]) {
                return false;
            }
        }
    }
    return true;
}

pub fn validateStringTableContinuationTail(
    allocator: std.mem.Allocator,
    context: Context,
    block: snapshot_v1.IrBlock,
    suffix_start: u32,
) Error!?bool {
    const pattern = (try context.stringTablePattern(block)) orelse return null;
    if (pattern.start < suffix_start)
        return null;

    // The compiler replaces the whole trailing fast/fallback table graph with one real runtime
    // helper and a canonical rejoin. Only the prefix before that graph executes as raw IR after
    // resumption, so validate that prefix rather than unreachable optimizer blocks.
    var instruction_id = suffix_start;
    while (instruction_id < pattern.start) : (instruction_id += 1) {
        const instruction_value = try context.instruction(instruction_id);
        var operand_id: u32 = 0;
        while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
            const operand_value = try context.operand(instruction_value, operand_id);
            if (operand_value.kind == .instruction and
                (operand_value.value < suffix_start or operand_value.value >= instruction_id))
                return false;
            if (operand_value.kind == .block)
                return false;
        }
    }

    const rejoin = try context.snapshot.irBlock(context.function, pattern.rejoin);
    if (rejoin.isEmpty())
        return false;
    return @as(?bool, try validateContinuationRegion(
        allocator,
        context,
        pattern.rejoin,
        rejoin.start,
        rejoin.finish,
    ));
}

pub fn validateNamecallContinuationTail(
    allocator: std.mem.Allocator,
    context: Context,
    block: snapshot_v1.IrBlock,
    suffix_start: u32,
) Error!?bool {
    const pattern = (try context.plainTableNamecallPattern(block)) orelse return null;
    if (pattern.start < suffix_start)
        return null;
    var instruction_id = suffix_start;
    while (instruction_id < pattern.start) : (instruction_id += 1) {
        const instruction_value = try context.instruction(instruction_id);
        var operand_id: u32 = 0;
        while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
            const operand_value = try context.operand(instruction_value, operand_id);
            if (operand_value.kind == .instruction and
                (operand_value.value < suffix_start or operand_value.value >= instruction_id))
                return false;
            if (operand_value.kind == .block)
                return false;
        }
    }
    const rejoin = try context.snapshot.irBlock(context.function, pattern.rejoin);
    if (rejoin.isEmpty())
        return false;
    return @as(?bool, try validateContinuationRegion(
        allocator,
        context,
        pattern.rejoin,
        rejoin.start,
        rejoin.finish,
    ));
}

pub fn validateGenericIterationContinuationRegion(
    allocator: std.mem.Allocator,
    context: Context,
    pattern: GenericIterationPattern,
) Error!bool {
    const reachable_blocks = try allocator.alloc(bool, context.function.block_count);
    defer allocator.free(reachable_blocks);
    @memset(reachable_blocks, false);
    const reachable_instructions = try allocator.alloc(bool, context.function.instruction_count);
    defer allocator.free(reachable_instructions);
    @memset(reachable_instructions, false);
    const instruction_blocks = try allocator.alloc(u32, context.function.instruction_count);
    defer allocator.free(instruction_blocks);
    @memset(instruction_blocks, snapshot_v1.no_id);
    const edge_count = std.math.mul(usize, context.function.block_count, context.function.block_count) catch
        return Error.ResourceLimit;
    const edges = try allocator.alloc(bool, edge_count);
    defer allocator.free(edges);
    @memset(edges, false);

    var pending_blocks: std.ArrayList(u32) = .empty;
    defer pending_blocks.deinit(allocator);
    try pending_blocks.append(allocator, pattern.repeat_target);
    try pending_blocks.append(allocator, pattern.exit_target);

    while (pending_blocks.items.len != 0) {
        const block_id = pending_blocks.items[pending_blocks.items.len - 1];
        pending_blocks.items.len -= 1;
        if (block_id >= context.function.block_count)
            return Error.UnsupportedControlFlow;
        if (reachable_blocks[block_id])
            continue;
        reachable_blocks[block_id] = true;

        const block = try context.snapshot.irBlock(context.function, block_id);
        if (block.isEmpty() or (!block.kind.isCompilable() and block.kind != .fallback))
            return false;
        if (block.kind == .fallback and
            !try context.isBypassedEmissionBlock(block_id, block) and
            !try context.supportsFallback(block))
            return false;

        var instruction_id = block.start;
        while (instruction_id <= block.finish) : (instruction_id += 1) {
            if (instruction_id >= context.function.instruction_count)
                return Error.UnsupportedControlFlow;
            reachable_instructions[instruction_id] = true;
            instruction_blocks[instruction_id] = block_id;
            const instruction_value = try context.instruction(instruction_id);
            var operand_id: u32 = 0;
            while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                const operand_value = try context.operand(instruction_value, operand_id);
                if (operand_value.kind == .block) {
                    if (operand_value.value >= context.function.block_count)
                        return Error.UnsupportedControlFlow;
                    edges[@as(usize, block_id) * context.function.block_count + operand_value.value] = true;
                    try pending_blocks.append(allocator, operand_value.value);
                }
            }
        }
    }

    const dominators = try allocator.alloc(bool, edge_count);
    defer allocator.free(dominators);
    @memset(dominators, false);
    var block_id: u32 = 0;
    while (block_id < context.function.block_count) : (block_id += 1) {
        if (!reachable_blocks[block_id])
            continue;
        const is_root = block_id == pattern.repeat_target or block_id == pattern.exit_target;
        var candidate: u32 = 0;
        while (candidate < context.function.block_count) : (candidate += 1) {
            if (reachable_blocks[candidate] and (!is_root or candidate == block_id))
                dominators[@as(usize, block_id) * context.function.block_count + candidate] = true;
        }
    }

    var changed = true;
    while (changed) {
        changed = false;
        block_id = 0;
        while (block_id < context.function.block_count) : (block_id += 1) {
            if (!reachable_blocks[block_id] or block_id == pattern.repeat_target or block_id == pattern.exit_target)
                continue;
            var candidate: u32 = 0;
            while (candidate < context.function.block_count) : (candidate += 1) {
                if (!reachable_blocks[candidate])
                    continue;
                var desired = candidate == block_id;
                if (!desired) {
                    desired = true;
                    var has_predecessor = false;
                    var predecessor: u32 = 0;
                    while (predecessor < context.function.block_count) : (predecessor += 1) {
                        if (!reachable_blocks[predecessor] or
                            !edges[@as(usize, predecessor) * context.function.block_count + block_id])
                            continue;
                        has_predecessor = true;
                        if (!dominators[@as(usize, predecessor) * context.function.block_count + candidate]) {
                            desired = false;
                            break;
                        }
                    }
                    desired = desired and has_predecessor;
                }
                const index = @as(usize, block_id) * context.function.block_count + candidate;
                if (dominators[index] != desired) {
                    dominators[index] = desired;
                    changed = true;
                }
            }
        }
    }

    var instruction_id: u32 = 0;
    while (instruction_id < context.function.instruction_count) : (instruction_id += 1) {
        if (!reachable_instructions[instruction_id])
            continue;
        const instruction_value = try context.instruction(instruction_id);
        var operand_id: u32 = 0;
        while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
            const operand_value = try context.operand(instruction_value, operand_id);
            if (operand_value.kind == .instruction) {
                if (operand_value.value >= context.function.instruction_count or !reachable_instructions[operand_value.value])
                    return false;
                const producer_block = instruction_blocks[operand_value.value];
                const consumer_block = instruction_blocks[instruction_id];
                if (producer_block == consumer_block) {
                    if (operand_value.value >= instruction_id)
                        return false;
                } else if (!dominators[@as(usize, consumer_block) * context.function.block_count + producer_block])
                    return false;
            }
        }
    }
    return true;
}

pub fn collectCallContinuations(allocator: std.mem.Allocator, context: Context) Error![]CallContinuation {
    var continuations: std.ArrayList(CallContinuation) = .empty;
    errdefer continuations.deinit(allocator);
    var block_id: u32 = 0;
    while (block_id < context.function.block_count) : (block_id += 1) {
        const block = try context.snapshot.irBlock(context.function, block_id);
        if (block.isEmpty() or (!block.kind.isCompilable() and block.kind != .fallback))
            continue;
        if (try context.isBypassedEmissionBlock(block_id, block))
            continue;
        var instruction_id = block.start;
        while (instruction_id <= block.finish) : (instruction_id += 1) {
            if (try context.staticRequireTarget(instruction_id, block)) |require| {
                const suffix_start = std.math.add(u32, require.end, 1) catch return Error.ResourceLimit;
                if (suffix_start > block.finish or
                    !try validateContinuationRegion(allocator, context, block_id, suffix_start, block.finish))
                    return Error.UnsupportedControlFlow;
                const continuation_id = std.math.cast(u32, continuations.items.len + 1) orelse return Error.ResourceLimit;
                if (continuation_id > 4095)
                    return Error.ResourceLimit;
                const dispatch_id = std.math.add(u32, context.function.block_count, continuation_id) catch
                    return Error.ResourceLimit;
                try continuations.append(allocator, .{
                    .instruction_id = require.interrupt_id,
                    .continuation_id = continuation_id,
                    .dispatch_id = dispatch_id,
                    .action = .{ .static_require_interrupt = .{
                        .block_id = block_id,
                        .require = require,
                        .suffix_start = suffix_start,
                        .block_finish = block.finish,
                    } },
                });
                instruction_id = require.end;
                continue;
            }
            const instruction_value = try context.instruction(instruction_id);
            const action: ContinuationAction = if (instruction_value.command == .call) blk: {
                const suffix_start = std.math.add(u32, instruction_id, 1) catch return Error.ResourceLimit;
                if (suffix_start > block.finish)
                    return Error.UnsupportedControlFlow;
                const tail_valid = try validateStringTableContinuationTail(
                    allocator,
                    context,
                    block,
                    suffix_start,
                );
                const namecall_tail_valid = try validateNamecallContinuationTail(allocator, context, block, suffix_start);
                if (!(tail_valid orelse namecall_tail_valid orelse
                    try validateContinuationRegion(allocator, context, block_id, suffix_start, block.finish)))
                    return Error.UnsupportedControlFlow;
                break :blk .{ .call_suffix = .{
                    .block_id = block_id,
                    .suffix_start = suffix_start,
                    .block_finish = block.finish,
                } };
            } else if (instruction_value.command == .interrupt) blk: {
                if (instruction_id == block.start)
                    break :blk .{ .interrupt_block_retry = .{ .block_id = block_id } };
                const suffix_start = std.math.add(u32, instruction_id, 1) catch return Error.ResourceLimit;
                const tail_valid = try validateStringTableContinuationTail(
                    allocator,
                    context,
                    block,
                    suffix_start,
                );
                const namecall_tail_valid = try validateNamecallContinuationTail(allocator, context, block, suffix_start);
                if (suffix_start > block.finish or !(tail_valid orelse namecall_tail_valid orelse
                    try validateContinuationRegion(allocator, context, block_id, suffix_start, block.finish)))
                    return Error.UnsupportedControlFlow;
                break :blk .{ .interrupt_suffix = .{
                    .block_id = block_id,
                    .interrupt_id = instruction_id,
                    .suffix_start = suffix_start,
                    .block_finish = block.finish,
                } };
            } else if (instruction_value.command == ir_cmd_forgloop_fallback) blk: {
                const pattern = (try context.genericIterationFallbackPattern(block)) orelse continue;
                const has_fast_owner = (try context.supportsGenericIterationFallback(block)) or
                    (try context.supportsSpecializedIpairsFallback(block));
                if (!has_fast_owner or
                    !try validateGenericIterationContinuationRegion(allocator, context, pattern))
                    continue;
                break :blk .{ .generic_iteration = pattern };
            } else continue;
            const continuation_id = std.math.cast(u32, continuations.items.len + 1) orelse return Error.ResourceLimit;
            if (continuation_id > 4095)
                return Error.ResourceLimit;
            const dispatch_id = std.math.add(u32, context.function.block_count, continuation_id) catch return Error.ResourceLimit;
            try continuations.append(allocator, .{
                .instruction_id = instruction_id,
                .continuation_id = continuation_id,
                .dispatch_id = dispatch_id,
                .action = action,
            });
        }
    }
    return continuations.toOwnedSlice(allocator);
}

pub fn resultShape(command: snapshot_v1.IrCommand) ValueShape {
    return switch (command) {
        .load_tag,
        .load_int,
        .add_int,
        .sub_int,
        .sexti8_int,
        .sexti16_int,
        .not_any,
        .cmp_any,
        .cmp_int,
        .cmp_int64,
        .cmp_tag,
        .cmp_split_tvalue,
        .num_to_int,
        .num_to_uint,
        .truncate_uint,
        .bitand_uint,
        .bitxor_uint,
        .bitor_uint,
        .bitnot_uint,
        .bitlshift_uint,
        .bitrshift_uint,
        .bitarshift_uint,
        .bitlrotate_uint,
        .bitrrotate_uint,
        .bitcountlz_uint,
        .bitcountrz_uint,
        .byteswap_uint,
        ir_cmd_string_len,
        ir_cmd_buffer_readi8,
        ir_cmd_buffer_readu8,
        ir_cmd_buffer_readi16,
        ir_cmd_buffer_readu16,
        ir_cmd_buffer_readi32,
        => .i32,
        .load_pointer,
        .load_env,
        .get_closure_upval_addr,
        .newclosure,
        .findupval,
        ir_cmd_new_userdata,
        => .pointer,
        .load_int64,
        .add_int64,
        .sub_int64,
        .mul_int64,
        .div_int64,
        .idiv_int64,
        .udiv_int64,
        .rem_int64,
        .urem_int64,
        .mod_int64,
        .select_int64,
        .num_to_int64,
        .bitand_int64,
        .bitxor_int64,
        .bitor_int64,
        .bitnot_int64,
        .bitlshift_int64,
        .bitrshift_int64,
        .bitarshift_int64,
        .bitlrotate_int64,
        .bitrrotate_int64,
        .bitcountlz_int64,
        .bitcountrz_int64,
        .byteswap_int64,
        ir_cmd_buffer_readi64,
        => .i64,
        .load_float,
        .add_float,
        .sub_float,
        .mul_float,
        .div_float,
        .min_float,
        .max_float,
        .unm_float,
        .floor_float,
        .ceil_float,
        .sqrt_float,
        .abs_float,
        .sign_float,
        .dot_vec,
        .extract_vec,
        .uint_to_float,
        .num_to_float,
        ir_cmd_buffer_readf32,
        => .f32,
        .load_double,
        .add_num,
        .sub_num,
        .mul_num,
        .div_num,
        .idiv_num,
        .mod_num,
        .muladd_num,
        .min_num,
        .max_num,
        .unm_num,
        .floor_num,
        .ceil_num,
        .round_num,
        .sqrt_num,
        .abs_num,
        .sign_num,
        .select_num,
        .int_to_num,
        .int64_to_num,
        .uint_to_num,
        .float_to_num,
        ir_cmd_invoke_libm,
        ir_cmd_buffer_readf64,
        => .f64,
        .load_tvalue,
        .select_vec,
        .select_if_truthy,
        .add_vec,
        .sub_vec,
        .mul_vec,
        .div_vec,
        .idiv_vec,
        .muladd_vec,
        .unm_vec,
        .min_vec,
        .max_vec,
        .floor_vec,
        .ceil_vec,
        .abs_vec,
        .float_to_vec,
        .tag_vector,
        => .tvalue,
        else => .none,
    };
}

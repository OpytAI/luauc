const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const model = @import("luauc_backend_model");
const FunctionPlan = @import("luauc_backend_plan").FunctionPlan;
const admission = @import("luauc_backend_admission");
const abi = @import("luauc_backend_runtime_abi");

const Error = model.Error;

/// Record snapshot-visible continuation sites and admit their regions.
/// Does not import emit Context.
pub fn planContinuations(
    allocator: std.mem.Allocator,
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    proto: snapshot_v1.Proto,
    plan: *FunctionPlan,
) Error!void {
    _ = proto;
    _ = admission;
    if (plan.dominators.immediate.len == 0)
        return Error.UnsupportedControlFlow;

    var sites: std.ArrayList(u32) = .empty;
    errdefer sites.deinit(allocator);
    var instruction_id: u32 = 0;
    while (instruction_id < function.instruction_count) : (instruction_id += 1) {
        const command = (try snapshot.irInstruction(function, instruction_id)).command;
        switch (command) {
            .call, .interrupt => try sites.append(allocator, instruction_id),
            else => if (command == abi.ir_cmd_forgloop_fallback)
                try sites.append(allocator, instruction_id),
        }
    }
    if (plan.continuation_sites.len != 0)
        plan.allocator.free(plan.continuation_sites);
    plan.continuation_sites = try sites.toOwnedSlice(allocator);

    var regions: std.ArrayList(FunctionPlan.ContinuationRegion) = .empty;
    errdefer regions.deinit(allocator);
    var block_id: u32 = 0;
    while (block_id < function.block_count) : (block_id += 1) {
        const block = try snapshot.irBlock(function, block_id);
        if (block.isEmpty())
            continue;
        try regions.append(allocator, .{
            .block_id = block_id,
            .suffix_start = block.start,
            .block_finish = block.finish,
            .admitted = try admitRegion(allocator, snapshot, function, plan, block_id, block.start, block.finish),
        });
    }
    for (plan.continuation_sites) |site| {
        const site_block = plan.instructionBlock(site) orelse continue;
        const block = try snapshot.irBlock(function, site_block);
        if (block.isEmpty() or site >= block.finish)
            continue;
        const suffix = site + 1;
        if (suffix > block.finish)
            continue;
        try regions.append(allocator, .{
            .block_id = site_block,
            .suffix_start = suffix,
            .block_finish = block.finish,
            .admitted = try admitRegion(allocator, snapshot, function, plan, site_block, suffix, block.finish),
        });
    }
    if (plan.continuation_regions.len != 0)
        plan.allocator.free(plan.continuation_regions);
    plan.continuation_regions = try regions.toOwnedSlice(allocator);

    var iteration_regions: std.ArrayList(FunctionPlan.IterationRegion) = .empty;
    errdefer iteration_regions.deinit(allocator);
    for (plan.call_facts.iterations) |fact| {
        var already = false;
        for (iteration_regions.items) |region| {
            if (region.repeat_target == fact.repeat_target and region.exit_target == fact.exit_target) {
                already = true;
                break;
            }
        }
        if (already)
            continue;
        try iteration_regions.append(allocator, .{
            .repeat_target = fact.repeat_target,
            .exit_target = fact.exit_target,
            .admitted = try admitIterationRegion(
                allocator,
                snapshot,
                function,
                plan,
                fact.repeat_target,
                fact.exit_target,
            ),
        });
    }
    if (plan.iteration_regions.len != 0)
        plan.allocator.free(plan.iteration_regions);
    plan.iteration_regions = try iteration_regions.toOwnedSlice(allocator);
}

fn admitRegion(
    allocator: std.mem.Allocator,
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    plan: *FunctionPlan,
    continuation_block_id: u32,
    suffix_start: u32,
    block_finish: u32,
) Error!bool {
    if (continuation_block_id >= function.block_count or
        suffix_start > block_finish or block_finish >= function.instruction_count)
        return false;

    const reachable_blocks = try allocator.alloc(bool, function.block_count);
    defer allocator.free(reachable_blocks);
    @memset(reachable_blocks, false);
    const reachable_instructions = try allocator.alloc(bool, function.instruction_count);
    defer allocator.free(reachable_instructions);
    @memset(reachable_instructions, false);

    var pending_blocks: std.ArrayList(u32) = .empty;
    defer pending_blocks.deinit(allocator);

    reachable_blocks[continuation_block_id] = true;
    var instruction_id = suffix_start;
    while (instruction_id <= block_finish) : (instruction_id += 1) {
        reachable_instructions[instruction_id] = true;
        const instruction_value = try snapshot.irInstruction(function, instruction_id);
        var operand_id: u32 = 0;
        while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
            const operand_value = try snapshot.irOperand(instruction_value, operand_id);
            if (operand_value.kind != .block)
                continue;
            if (operand_value.value >= function.block_count)
                return false;
            if (operand_value.value == continuation_block_id)
                continue;
            try pending_blocks.append(allocator, operand_value.value);
        }
    }

    while (pending_blocks.items.len != 0) {
        const block_id = pending_blocks.items[pending_blocks.items.len - 1];
        pending_blocks.items.len -= 1;
        if (block_id >= function.block_count)
            return false;
        if (reachable_blocks[block_id])
            continue;
        const block = try snapshot.irBlock(function, block_id);
        if (block.isEmpty())
            continue;
        if (!block.kind.isCompilable() and
            (block.kind != .fallback or !plan.supportsFallback(block_id)))
            continue;
        reachable_blocks[block_id] = true;
        instruction_id = block.start;
        while (instruction_id <= block.finish) : (instruction_id += 1) {
            if (instruction_id >= function.instruction_count)
                return false;
            reachable_instructions[instruction_id] = true;
        }
        const successors = plan.successorSlice(block_id) orelse return false;
        for (successors) |target| {
            if (target != continuation_block_id)
                try pending_blocks.append(allocator, target);
        }
    }

    var region_dominators = try plan.regionDominators(allocator, reachable_blocks, &.{continuation_block_id});
    defer region_dominators.deinit();

    instruction_id = 0;
    while (instruction_id < function.instruction_count) : (instruction_id += 1) {
        if (!reachable_instructions[instruction_id])
            continue;
        const instruction_value = try snapshot.irInstruction(function, instruction_id);
        var operand_id: u32 = 0;
        while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
            const operand_value = try snapshot.irOperand(instruction_value, operand_id);
            if (operand_value.kind != .instruction)
                continue;
            if (operand_value.value >= function.instruction_count or
                !reachable_instructions[operand_value.value])
                return false;
            const producer_block = plan.instructionBlock(operand_value.value) orelse return false;
            const consumer_block = plan.instructionBlock(instruction_id) orelse return false;
            if (producer_block == consumer_block) {
                if (operand_value.value >= instruction_id)
                    return false;
            } else if (!region_dominators.dominates(producer_block, consumer_block)) {
                return false;
            }
        }
    }
    return true;
}

/// Generic FORGLOOP resume enters at the repeat and exit arms, not the function entry.
fn admitIterationRegion(
    allocator: std.mem.Allocator,
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    plan: *FunctionPlan,
    repeat_target: u32,
    exit_target: u32,
) Error!bool {
    const reachable_blocks = try allocator.alloc(bool, function.block_count);
    defer allocator.free(reachable_blocks);
    @memset(reachable_blocks, false);
    const reachable_instructions = try allocator.alloc(bool, function.instruction_count);
    defer allocator.free(reachable_instructions);
    @memset(reachable_instructions, false);

    var pending_blocks: std.ArrayList(u32) = .empty;
    defer pending_blocks.deinit(allocator);
    try pending_blocks.append(allocator, repeat_target);
    try pending_blocks.append(allocator, exit_target);

    while (pending_blocks.items.len != 0) {
        const block_id = pending_blocks.items[pending_blocks.items.len - 1];
        pending_blocks.items.len -= 1;
        if (block_id >= function.block_count)
            return Error.UnsupportedControlFlow;
        if (reachable_blocks[block_id])
            continue;
        reachable_blocks[block_id] = true;

        const block = try snapshot.irBlock(function, block_id);
        if (block.isEmpty() or (!block.kind.isCompilable() and block.kind != .fallback))
            return false;
        if (block.kind == .fallback and
            !plan.isPlannedBypass(block_id) and
            !plan.supportsFallback(block_id))
            return false;

        var instruction_id = block.start;
        while (instruction_id <= block.finish) : (instruction_id += 1) {
            if (instruction_id >= function.instruction_count)
                return Error.UnsupportedControlFlow;
            reachable_instructions[instruction_id] = true;
        }
        const successors = plan.successorSlice(block_id) orelse return Error.UnsupportedControlFlow;
        for (successors) |target|
            try pending_blocks.append(allocator, target);
    }

    var region_dominators = try plan.regionDominators(
        allocator,
        reachable_blocks,
        &.{ repeat_target, exit_target },
    );
    defer region_dominators.deinit();

    var instruction_id: u32 = 0;
    while (instruction_id < function.instruction_count) : (instruction_id += 1) {
        if (!reachable_instructions[instruction_id])
            continue;
        const instruction_value = try snapshot.irInstruction(function, instruction_id);
        var operand_id: u32 = 0;
        while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
            const operand_value = try snapshot.irOperand(instruction_value, operand_id);
            if (operand_value.kind != .instruction)
                continue;
            if (operand_value.value >= function.instruction_count or
                !reachable_instructions[operand_value.value])
                return false;
            const producer_block = plan.instructionBlock(operand_value.value) orelse return false;
            const consumer_block = plan.instructionBlock(instruction_id) orelse return false;
            if (producer_block == consumer_block) {
                if (operand_value.value >= instruction_id)
                    return false;
            } else if (!region_dominators.dominates(producer_block, consumer_block)) {
                return false;
            }
        }
    }
    return true;
}

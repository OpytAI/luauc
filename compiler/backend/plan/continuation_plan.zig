const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const model = @import("luauc_backend_model");
const FunctionPlan = @import("luauc_backend_plan").FunctionPlan;
const admission = @import("luauc_backend_admission");
const abi = @import("luauc_backend_runtime_abi");

const Error = model.Error;

/// One admitted or rejected cone of a block. A later suffix may reuse it only when
/// its reachable block set is the same and its suffix starts at or after this one.
const ConeMemo = struct {
    next: u32,
    suffix_start: u32,
    outside_min: u32,
    cone_at: u32,
    cone_count: u32,
    admitted: bool,
    /// A failing use whose consumer is outside the entry block. The same cone keeps that consumer.
    sticky: bool,
    /// The latest failing consumer inside the entry block. Instruction 0 is a real id.
    entry_failed: bool,
    entry_consumer: u32,
};

/// Scratch reused across every region of one function.
const AdmitScratch = struct {
    allocator: std.mem.Allocator,
    blocks: []bool,
    cfg_reach: []bool,
    block_start: []u32,
    block_finish: []u32,
    block_kind: []u8,
    pending: std.ArrayList(u32) = .empty,
    memo_head: []u32,
    memos: std.ArrayList(ConeMemo) = .empty,
    cone_ids: std.ArrayList(u32) = .empty,
    edge_offset: []u32 = &.{},
    edge_producer: []u32 = &.{},
    edge_producer_block: []u32 = &.{},
    edge_consumer: []u32 = &.{},
    bop_offset: []u32 = &.{},
    bop_instruction: []u32 = &.{},
    bop_target: []u32 = &.{},
    edges_ready: bool = false,
    rpo_block: []u32,
    rpo_index: []u32,
    idom_rpo: []u32,
    idom_block: []u32,
    dom_frames: std.ArrayList(DomFrame) = .empty,
    reached_ids: std.ArrayList(u32) = .empty,

    fn init(allocator: std.mem.Allocator, function: snapshot_v1.IrFunction) Error!AdmitScratch {
        const blocks = try allocator.alloc(bool, function.block_count);
        errdefer allocator.free(blocks);
        const cfg_reach = try allocator.alloc(bool, function.block_count);
        errdefer allocator.free(cfg_reach);
        const block_start = try allocator.alloc(u32, function.block_count);
        errdefer allocator.free(block_start);
        const block_finish = try allocator.alloc(u32, function.block_count);
        errdefer allocator.free(block_finish);
        const block_kind = try allocator.alloc(u8, function.block_count);
        errdefer allocator.free(block_kind);
        const memo_head = try allocator.alloc(u32, function.block_count);
        errdefer allocator.free(memo_head);
        @memset(memo_head, snapshot_v1.no_id);
        const rpo_block = try allocator.alloc(u32, function.block_count);
        errdefer allocator.free(rpo_block);
        const rpo_index = try allocator.alloc(u32, function.block_count);
        errdefer allocator.free(rpo_index);
        const idom_rpo = try allocator.alloc(u32, function.block_count);
        errdefer allocator.free(idom_rpo);
        const idom_block = try allocator.alloc(u32, function.block_count);
        errdefer allocator.free(idom_block);
        return .{
            .allocator = allocator,
            .blocks = blocks,
            .cfg_reach = cfg_reach,
            .block_start = block_start,
            .block_finish = block_finish,
            .block_kind = block_kind,
            .memo_head = memo_head,
            .rpo_block = rpo_block,
            .rpo_index = rpo_index,
            .idom_rpo = idom_rpo,
            .idom_block = idom_block,
        };
    }

    fn deinit(self: *AdmitScratch) void {
        self.allocator.free(self.blocks);
        self.allocator.free(self.cfg_reach);
        self.allocator.free(self.block_start);
        self.allocator.free(self.block_finish);
        self.allocator.free(self.block_kind);
        self.allocator.free(self.memo_head);
        self.allocator.free(self.rpo_block);
        self.allocator.free(self.rpo_index);
        self.allocator.free(self.idom_rpo);
        self.allocator.free(self.idom_block);
        self.dom_frames.deinit(self.allocator);
        self.reached_ids.deinit(self.allocator);
        self.memos.deinit(self.allocator);
        self.cone_ids.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        if (self.edges_ready) {
            self.allocator.free(self.edge_offset);
            self.allocator.free(self.edge_producer);
            self.allocator.free(self.edge_producer_block);
            self.allocator.free(self.edge_consumer);
            self.allocator.free(self.bop_offset);
            self.allocator.free(self.bop_instruction);
            self.allocator.free(self.bop_target);
        }
    }

    /// Instruction operands grouped by consumer block. Built once per function.
    fn indexUses(
        self: *AdmitScratch,
        snapshot: snapshot_v1.Snapshot,
        function: snapshot_v1.IrFunction,
        plan: *FunctionPlan,
    ) Error!void {
        const counts = try self.allocator.alloc(u32, function.block_count);
        defer self.allocator.free(counts);
        @memset(counts, 0);
        const bop_counts = try self.allocator.alloc(u32, function.block_count);
        defer self.allocator.free(bop_counts);
        @memset(bop_counts, 0);
        var block_id: u32 = 0;
        while (block_id < function.block_count) : (block_id += 1) {
            const block = try snapshot.irBlock(function, block_id);
            if (block.isEmpty()) {
                self.block_start[block_id] = snapshot_v1.no_id;
                self.block_finish[block_id] = snapshot_v1.no_id;
                self.block_kind[block_id] = 0;
                continue;
            }
            self.block_start[block_id] = block.start;
            self.block_finish[block_id] = block.finish;
            self.block_kind[block_id] = @intFromEnum(block.kind);
        }
        var instruction_id: u32 = 0;
        while (instruction_id < function.instruction_count) : (instruction_id += 1) {
            const owner = plan.instructionBlock(instruction_id) orelse continue;
            const instruction_value = try snapshot.irInstruction(function, instruction_id);
            var operand_id: u32 = 0;
            while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                const operand_value = try snapshot.irOperand(instruction_value, operand_id);
                switch (operand_value.kind) {
                    .instruction => counts[owner] += 1,
                    .block => bop_counts[owner] += 1,
                    else => {},
                }
            }
        }

        const offset = try self.allocator.alloc(u32, function.block_count + 1);
        errdefer self.allocator.free(offset);
        offset[0] = 0;
        block_id = 0;
        while (block_id < function.block_count) : (block_id += 1)
            offset[block_id + 1] = std.math.add(u32, offset[block_id], counts[block_id]) catch
                return Error.ResourceLimit;
        const bop_offset = try self.allocator.alloc(u32, function.block_count + 1);
        errdefer self.allocator.free(bop_offset);
        bop_offset[0] = 0;
        block_id = 0;
        while (block_id < function.block_count) : (block_id += 1)
            bop_offset[block_id + 1] = std.math.add(u32, bop_offset[block_id], bop_counts[block_id]) catch
                return Error.ResourceLimit;
        const total: usize = offset[function.block_count];
        const producer = try self.allocator.alloc(u32, total);
        errdefer self.allocator.free(producer);
        const producer_block = try self.allocator.alloc(u32, total);
        errdefer self.allocator.free(producer_block);
        const consumer = try self.allocator.alloc(u32, total);
        errdefer self.allocator.free(consumer);
        const bop_total: usize = bop_offset[function.block_count];
        const bop_instruction = try self.allocator.alloc(u32, bop_total);
        errdefer self.allocator.free(bop_instruction);
        const bop_target = try self.allocator.alloc(u32, bop_total);
        errdefer self.allocator.free(bop_target);
        const cursor = try self.allocator.dupe(u32, offset[0..function.block_count]);
        defer self.allocator.free(cursor);
        const bop_cursor = try self.allocator.dupe(u32, bop_offset[0..function.block_count]);
        defer self.allocator.free(bop_cursor);

        instruction_id = 0;
        while (instruction_id < function.instruction_count) : (instruction_id += 1) {
            const consumer_block = plan.instructionBlock(instruction_id) orelse continue;
            const instruction_value = try snapshot.irInstruction(function, instruction_id);
            var operand_id: u32 = 0;
            while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                const operand_value = try snapshot.irOperand(instruction_value, operand_id);
                switch (operand_value.kind) {
                    .instruction => {
                        const at = cursor[consumer_block];
                        cursor[consumer_block] = at + 1;
                        consumer[at] = instruction_id;
                        producer[at] = operand_value.value;
                        producer_block[at] = if (operand_value.value >= function.instruction_count)
                            snapshot_v1.no_id
                        else
                            plan.instructionBlock(operand_value.value) orelse snapshot_v1.no_id;
                    },
                    .block => {
                        const at = bop_cursor[consumer_block];
                        bop_cursor[consumer_block] = at + 1;
                        bop_instruction[at] = instruction_id;
                        bop_target[at] = operand_value.value;
                    },
                    else => {},
                }
            }
        }

        self.edge_offset = offset;
        self.edge_producer = producer;
        self.edge_producer_block = producer_block;
        self.edge_consumer = consumer;
        self.bop_offset = bop_offset;
        self.bop_instruction = bop_instruction;
        self.bop_target = bop_target;
        self.edges_ready = true;
    }
};

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

    var scratch = try AdmitScratch.init(allocator, function);
    defer scratch.deinit();
    try scratch.indexUses(snapshot, function, plan);

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
            .admitted = try admitRegion(allocator, function, plan, &scratch, block_id, block.start, block.finish),
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
            .admitted = try admitRegion(allocator, function, plan, &scratch, site_block, suffix, block.finish),
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
    function: snapshot_v1.IrFunction,
    plan: *FunctionPlan,
    scratch: *AdmitScratch,
    continuation_block_id: u32,
    suffix_start: u32,
    block_finish: u32,
) Error!bool {
    if (continuation_block_id >= function.block_count or
        suffix_start > block_finish or block_finish >= function.instruction_count)
        return false;
    const entry_start = scratch.block_start[continuation_block_id];
    // No foreign block operand: the reachable set is the suffix itself.
    // A producer has to sit in that suffix and before its consumer.
    const crossed = suffixCrosses(scratch, continuation_block_id, suffix_start, block_finish) orelse return false;
    if (!crossed) {
        return !suffixUseFailed(scratch, continuation_block_id, suffix_start, block_finish);
    }

    const reachable_blocks = scratch.blocks;
    @memset(reachable_blocks, false);
    scratch.pending.clearRetainingCapacity();
    scratch.reached_ids.clearRetainingCapacity();

    reachable_blocks[continuation_block_id] = true;
    try scratch.reached_ids.append(allocator, continuation_block_id);
    var reached_blocks: u32 = 1;
    var seed = scratch.bop_offset[continuation_block_id];
    const seed_end = scratch.bop_offset[continuation_block_id + 1];
    while (seed < seed_end) : (seed += 1) {
        const at = scratch.bop_instruction[seed];
        if (at < suffix_start or at > block_finish)
            continue;
        const target = scratch.bop_target[seed];
        if (target >= function.block_count)
            return false;
        if (target == continuation_block_id)
            continue;
        try scratch.pending.append(allocator, target);
    }

    while (scratch.pending.items.len != 0) {
        const block_id = scratch.pending.items[scratch.pending.items.len - 1];
        scratch.pending.items.len -= 1;
        if (block_id >= function.block_count)
            return false;
        if (reachable_blocks[block_id])
            continue;
        if (!blockEntersRegion(scratch, plan, block_id))
            continue;
        reachable_blocks[block_id] = true;
        try scratch.reached_ids.append(allocator, block_id);
        reached_blocks += 1;
        const successors = plan.successorSlice(block_id) orelse return false;
        for (successors) |target| {
            if (target != continuation_block_id)
                try scratch.pending.append(allocator, target);
        }
    }

    // Block operands that never enter another compilable block leave a single-block region.
    if (reached_blocks == 1)
        return !suffixUseFailed(scratch, continuation_block_id, suffix_start, block_finish);

    try markCfgReach(allocator, plan, scratch, continuation_block_id);
    if (reuseMemo(scratch, continuation_block_id, reachable_blocks, reached_blocks, entry_start, suffix_start, block_finish)) |verdict| {
        return verdict;
    }

    const reached = scratch.reached_ids.items;
    const walk = walkUses(
        plan,
        function,
        scratch,
        reachable_blocks,
        reached,
        continuation_block_id,
        suffix_start,
        block_finish,
    );
    if (walk.failed) {
        try saveMemo(allocator, scratch, continuation_block_id, reached, suffix_start, walk, std.math.maxInt(u32), false);
        return false;
    }
    if (!walk.need_dom) {
        try saveMemo(allocator, scratch, continuation_block_id, reached, suffix_start, walk, walk.outside_min, true);
        return true;
    }
    if (walk.dom_proved) {
        try saveMemo(allocator, scratch, continuation_block_id, reached, suffix_start, walk, walk.outside_min, true);
        return true;
    }
    try computeRegionIdoms(allocator, plan, scratch, continuation_block_id);
    const dominance = dominanceFailure(
        scratch,
        reached,
        scratch.idom_block,
        continuation_block_id,
        suffix_start,
        block_finish,
    );
    const failed = UseWalk{
        .failed = dominance.failed,
        .sticky = walk.sticky or dominance.sticky,
        .entry_failed = walk.entry_failed or dominance.entry_failed,
        .entry_consumer = @max(walk.entry_consumer, dominance.entry_consumer),
        .need_dom = true,
        .outside_min = walk.outside_min,
    };
    if (dominance.failed) {
        try saveMemo(allocator, scratch, continuation_block_id, reached, suffix_start, failed, walk.outside_min, false);
        return false;
    }
    try saveMemo(allocator, scratch, continuation_block_id, reached, suffix_start, failed, walk.outside_min, true);
    return true;
}

const UseWalk = struct {
    failed: bool = false,
    sticky: bool = false,
    entry_failed: bool = false,
    entry_consumer: u32 = 0,
    need_dom: bool = false,
    dom_proved: bool = true,
    outside_min: u32 = std.math.maxInt(u32),
};

fn noteFailure(walk: *UseWalk, consumer: u32, consumer_block: u32, entry: u32) void {
    walk.failed = true;
    if (consumer_block == entry) {
        if (!walk.entry_failed or consumer > walk.entry_consumer)
            walk.entry_consumer = consumer;
        walk.entry_failed = true;
    } else {
        walk.sticky = true;
    }
}

/// Blocks the region CFG can reach from the continuation entry.
/// The virtual root used by regionDominators has that entry as its only child,
/// so the entry dominates exactly this set.
fn markCfgReach(
    allocator: std.mem.Allocator,
    plan: *FunctionPlan,
    scratch: *AdmitScratch,
    entry: u32,
) Error!void {
    @memset(scratch.cfg_reach, false);
    if (entry >= scratch.cfg_reach.len)
        return;
    scratch.cfg_reach[entry] = true;
    scratch.pending.clearRetainingCapacity();
    try scratch.pending.append(allocator, entry);
    while (scratch.pending.items.len != 0) {
        const block_id = scratch.pending.items[scratch.pending.items.len - 1];
        scratch.pending.items.len -= 1;
        const successors = plan.successorSlice(block_id) orelse return Error.UnsupportedControlFlow;
        for (successors) |target| {
            if (target >= scratch.blocks.len or !scratch.blocks[target] or scratch.cfg_reach[target])
                continue;
            scratch.cfg_reach[target] = true;
            try scratch.pending.append(allocator, target);
        }
    }
}

fn suffixCrosses(
    scratch: *const AdmitScratch,
    entry: u32,
    suffix_start: u32,
    block_finish: u32,
) ?bool {
    var crossed = false;
    var index = scratch.bop_offset[entry];
    const end = scratch.bop_offset[entry + 1];
    while (index < end) : (index += 1) {
        const at = scratch.bop_instruction[index];
        if (at < suffix_start or at > block_finish)
            continue;
        const target = scratch.bop_target[index];
        if (target >= scratch.blocks.len)
            return null;
        if (target != entry)
            crossed = true;
    }
    return crossed;
}

fn suffixUseFailed(
    scratch: *const AdmitScratch,
    entry: u32,
    suffix_start: u32,
    block_finish: u32,
) bool {
    var index = scratch.edge_offset[entry];
    const end = scratch.edge_offset[entry + 1];
    while (index < end) : (index += 1) {
        const consumer = scratch.edge_consumer[index];
        if (consumer < suffix_start or consumer > block_finish)
            continue;
        const producer = scratch.edge_producer[index];
        if (producer < suffix_start or producer >= consumer)
            return true;
    }
    return false;
}

fn blockEntersRegion(scratch: *const AdmitScratch, plan: *FunctionPlan, block_id: u32) bool {
    if (scratch.block_start[block_id] == snapshot_v1.no_id)
        return false;
    const kind: snapshot_v1.IrBlockKind = @enumFromInt(scratch.block_kind[block_id]);
    if (kind.isCompilable())
        return true;
    return kind == .fallback and plan.supportsFallback(block_id);
}

fn producerInRegion(
    producer: u32,
    producer_block: u32,
    reachable_blocks: []const bool,
    entry: u32,
    suffix_start: u32,
    block_finish: u32,
) bool {
    if (producer_block == snapshot_v1.no_id or producer_block >= reachable_blocks.len)
        return false;
    if (!reachable_blocks[producer_block])
        return false;
    if (producer_block != entry)
        return true;
    return producer >= suffix_start and producer <= block_finish;
}

fn walkUses(
    plan: *const FunctionPlan,
    function: snapshot_v1.IrFunction,
    scratch: *const AdmitScratch,
    reachable_blocks: []const bool,
    reached: []const u32,
    entry: u32,
    suffix_start: u32,
    block_finish: u32,
) UseWalk {
    var walk = UseWalk{};
    for (reached) |block_id| {
        var index = scratch.edge_offset[block_id];
        const end = scratch.edge_offset[block_id + 1];
        while (index < end) : (index += 1) {
            const consumer = scratch.edge_consumer[index];
            if (block_id == entry and (consumer < suffix_start or consumer > block_finish))
                continue;
            const producer_block = scratch.edge_producer_block[index];
            // A fully included block already proved same-block order at plan init.
            if (producer_block == block_id and block_id != entry)
                continue;
            const producer = scratch.edge_producer[index];
            if (producer >= function.instruction_count or
                !producerInRegion(producer, producer_block, reachable_blocks, entry, suffix_start, block_finish))
            {
                noteFailure(&walk, consumer, block_id, entry);
                continue;
            }
            if (producer_block == block_id) {
                if (producer >= consumer)
                    noteFailure(&walk, consumer, block_id, entry);
                continue;
            }
            if (!scratch.cfg_reach[block_id] or !scratch.cfg_reach[producer_block]) {
                noteFailure(&walk, consumer, block_id, entry);
                continue;
            }
            if (producer_block == entry) {
                if (producer < walk.outside_min)
                    walk.outside_min = producer;
                continue;
            }
            walk.need_dom = true;
            if (!plan.blockDominates(producer_block, block_id) or plan.blockDominates(producer_block, entry))
                walk.dom_proved = false;
        }
    }
    return walk;
}

const DomFrame = struct {
    block: u32,
    next_edge: u32,
};

/// Immediate dominators of the continuation region, rooted at the entry block.
/// The same relation as the virtual-root Lengauer-Tarjan tree for every block the
/// CFG can reach from that entry. Scratch arrays are reused across regions.
fn computeRegionIdoms(
    allocator: std.mem.Allocator,
    plan: *FunctionPlan,
    scratch: *AdmitScratch,
    entry: u32,
) Error!void {
    const block_count = scratch.cfg_reach.len;
    @memset(scratch.idom_rpo, snapshot_v1.no_id);
    @memset(scratch.idom_block, snapshot_v1.no_id);
    @memset(scratch.rpo_index, snapshot_v1.no_id);
    if (entry >= block_count)
        return;

    scratch.idom_rpo[entry] = 0;
    scratch.dom_frames.clearRetainingCapacity();
    try scratch.dom_frames.append(allocator, .{ .block = entry, .next_edge = 0 });
    var post_len: u32 = 0;
    while (scratch.dom_frames.items.len != 0) {
        const last = scratch.dom_frames.items.len - 1;
        const block = scratch.dom_frames.items[last].block;
        const next_edge = scratch.dom_frames.items[last].next_edge;
        const successors = plan.successorSlice(block) orelse return Error.UnsupportedControlFlow;
        if (next_edge < successors.len) {
            const target = successors[next_edge];
            scratch.dom_frames.items[last].next_edge = next_edge + 1;
            if (target >= block_count or !scratch.cfg_reach[target] or scratch.idom_rpo[target] != snapshot_v1.no_id)
                continue;
            scratch.idom_rpo[target] = 0;
            try scratch.dom_frames.append(allocator, .{ .block = target, .next_edge = 0 });
        } else {
            scratch.rpo_block[post_len] = block;
            post_len += 1;
            scratch.dom_frames.items.len -= 1;
        }
    }

    var lo: u32 = 0;
    while (lo < post_len / 2) : (lo += 1) {
        const hi = post_len - 1 - lo;
        const tmp = scratch.rpo_block[lo];
        scratch.rpo_block[lo] = scratch.rpo_block[hi];
        scratch.rpo_block[hi] = tmp;
    }

    @memset(scratch.idom_rpo, snapshot_v1.no_id);
    var index: u32 = 0;
    while (index < post_len) : (index += 1)
        scratch.rpo_index[scratch.rpo_block[index]] = index;
    if (post_len == 0)
        return;
    scratch.idom_rpo[0] = 0;

    var changed = true;
    var rounds: u32 = 0;
    while (changed) {
        changed = false;
        rounds += 1;
        if (rounds > post_len + 2)
            return Error.UnsupportedControlFlow;
        index = 1;
        while (index < post_len) : (index += 1) {
            const block = scratch.rpo_block[index];
            const predecessors = plan.predecessorSlice(block) orelse return Error.UnsupportedControlFlow;
            var new_idom: u32 = snapshot_v1.no_id;
            for (predecessors) |predecessor| {
                if (predecessor >= block_count)
                    continue;
                const pred_rpo = scratch.rpo_index[predecessor];
                if (pred_rpo == snapshot_v1.no_id or scratch.idom_rpo[pred_rpo] == snapshot_v1.no_id)
                    continue;
                if (new_idom == snapshot_v1.no_id)
                    new_idom = pred_rpo
                else
                    new_idom = try intersectIdom(scratch.idom_rpo, new_idom, pred_rpo);
            }
            if (new_idom == snapshot_v1.no_id)
                continue;
            if (scratch.idom_rpo[index] != new_idom) {
                scratch.idom_rpo[index] = new_idom;
                changed = true;
            }
        }
    }

    index = 0;
    while (index < post_len) : (index += 1) {
        const idom_index = scratch.idom_rpo[index];
        if (idom_index == snapshot_v1.no_id or idom_index >= post_len)
            continue;
        scratch.idom_block[scratch.rpo_block[index]] = scratch.rpo_block[idom_index];
    }
}

fn intersectIdom(idom_rpo: []const u32, start_a: u32, start_b: u32) Error!u32 {
    var finger_a = start_a;
    var finger_b = start_b;
    var guard: u32 = 0;
    const limit: u32 = @intCast(idom_rpo.len + 1);
    while (finger_a != finger_b) {
        guard += 1;
        if (guard > limit)
            return Error.UnsupportedControlFlow;
        while (finger_a > finger_b) {
            const next = idom_rpo[finger_a];
            if (next == snapshot_v1.no_id or next >= idom_rpo.len)
                return Error.UnsupportedControlFlow;
            finger_a = next;
        }
        while (finger_b > finger_a) {
            const next = idom_rpo[finger_b];
            if (next == snapshot_v1.no_id or next >= idom_rpo.len)
                return Error.UnsupportedControlFlow;
            finger_b = next;
        }
    }
    return finger_a;
}

fn regionDominates(idom_block: []const u32, dominator: u32, block: u32) bool {
    if (dominator >= idom_block.len or block >= idom_block.len)
        return false;
    if (idom_block[dominator] == snapshot_v1.no_id or idom_block[block] == snapshot_v1.no_id)
        return false;
    var cursor = block;
    var guard = idom_block.len;
    while (cursor != dominator) {
        if (guard == 0)
            return false;
        guard -= 1;
        const parent = idom_block[cursor];
        if (parent == snapshot_v1.no_id or parent == cursor)
            return false;
        cursor = parent;
    }
    return true;
}

fn dominanceFailure(
    scratch: *const AdmitScratch,
    reached: []const u32,
    idom_block: []const u32,
    entry: u32,
    suffix_start: u32,
    block_finish: u32,
) UseWalk {
    var walk = UseWalk{};
    for (reached) |block_id| {
        var index = scratch.edge_offset[block_id];
        const end = scratch.edge_offset[block_id + 1];
        while (index < end) : (index += 1) {
            const producer_block = scratch.edge_producer_block[index];
            if (producer_block == block_id or producer_block == entry or producer_block == snapshot_v1.no_id)
                continue;
            const consumer = scratch.edge_consumer[index];
            if (block_id == entry and (consumer < suffix_start or consumer > block_finish))
                continue;
            if (!scratch.cfg_reach[block_id] or !scratch.cfg_reach[producer_block])
                continue;
            if (!regionDominates(idom_block, producer_block, block_id))
                noteFailure(&walk, consumer, block_id, entry);
        }
    }
    return walk;
}

fn reuseMemo(
    scratch: *const AdmitScratch,
    block_id: u32,
    blocks: []const bool,
    reached_blocks: u32,
    entry_start: u32,
    suffix_start: u32,
    block_finish: u32,
) ?bool {
    var cursor = scratch.memo_head[block_id];
    while (cursor != snapshot_v1.no_id) {
        const memo = scratch.memos.items[cursor];
        cursor = memo.next;
        if (memo.suffix_start > suffix_start or memo.cone_count != reached_blocks)
            continue;
        if (!coneListed(scratch, memo, blocks))
            continue;
        if (memo.admitted) {
            if (memo.outside_min < suffix_start)
                return false;
            if (prefixProducerUsed(scratch, block_id, entry_start, suffix_start, block_finish))
                return false;
            return true;
        }
        if (memo.sticky or (memo.entry_failed and memo.entry_consumer >= suffix_start))
            return false;
    }
    return null;
}

fn coneListed(scratch: *const AdmitScratch, memo: ConeMemo, blocks: []const bool) bool {
    const start = memo.cone_at;
    const count = memo.cone_count;
    if (start + count > scratch.cone_ids.items.len)
        return false;
    for (scratch.cone_ids.items[start..][0..count]) |id| {
        if (id >= blocks.len or !blocks[id])
            return false;
    }
    return true;
}

fn prefixProducerUsed(
    scratch: *const AdmitScratch,
    entry: u32,
    entry_start: u32,
    suffix_start: u32,
    block_finish: u32,
) bool {
    var index = scratch.edge_offset[entry];
    const end = scratch.edge_offset[entry + 1];
    while (index < end) : (index += 1) {
        const consumer = scratch.edge_consumer[index];
        if (consumer < suffix_start or consumer > block_finish)
            continue;
        const producer = scratch.edge_producer[index];
        if (producer >= entry_start and producer < suffix_start)
            return true;
    }
    return false;
}

fn saveMemo(
    allocator: std.mem.Allocator,
    scratch: *AdmitScratch,
    block_id: u32,
    reached: []const u32,
    suffix_start: u32,
    walk: UseWalk,
    outside_min: u32,
    admitted: bool,
) Error!void {
    const start_len = scratch.cone_ids.items.len;
    for (reached) |id|
        try scratch.cone_ids.append(allocator, id);
    const cone_at = std.math.cast(u32, start_len) orelse return Error.ResourceLimit;
    const cone_count = std.math.cast(u32, scratch.cone_ids.items.len - start_len) orelse
        return Error.ResourceLimit;
    const index = std.math.cast(u32, scratch.memos.items.len) orelse return Error.ResourceLimit;
    try scratch.memos.append(allocator, .{
        .next = scratch.memo_head[block_id],
        .suffix_start = suffix_start,
        .outside_min = outside_min,
        .cone_at = cone_at,
        .cone_count = cone_count,
        .admitted = admitted,
        .sticky = walk.sticky,
        .entry_failed = walk.entry_failed,
        .entry_consumer = walk.entry_consumer,
    });
    scratch.memo_head[block_id] = index;
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

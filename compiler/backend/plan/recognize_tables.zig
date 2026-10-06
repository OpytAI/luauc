const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");

const Error = model.Error;

pub const BlockKind = enum {
    none,
    string_equality,
    constant_pow,
    constant_arith,
    pow,
    namecall,
    ordinary_call_fallback,
    fastcall_fallback,
    specialized_ipairs,
    generic_iteration,
    generic_iteration_fallback,
    xnext_fast,
    xnext_prep,
    global,
    generic_table,
    string_table,
    dynamic_length,
    semantic_array,
    dispatch,
};

pub const BlockFact = struct {
    kind: BlockKind = .none,
    fast_target: u32 = snapshot_v1.no_id,
    fallback: u32 = snapshot_v1.no_id,
    extra0: u32 = snapshot_v1.no_id,
    extra1: u32 = snapshot_v1.no_id,
};

pub const BlockIndex = struct {
    allocator: std.mem.Allocator = undefined,
    facts: []BlockFact = &.{},
    bypassed: []bool = &.{},
    fallback_supported: []bool = &.{},
    owns_fallback: []bool = &.{},
    fallback_owner: []u32 = &.{},

    pub fn deinit(self: *BlockIndex) void {
        if (self.facts.len != 0)
            self.allocator.free(self.facts);
        if (self.bypassed.len != 0)
            self.allocator.free(self.bypassed);
        if (self.fallback_supported.len != 0)
            self.allocator.free(self.fallback_supported);
        if (self.owns_fallback.len != 0)
            self.allocator.free(self.owns_fallback);
        if (self.fallback_owner.len != 0)
            self.allocator.free(self.fallback_owner);
        self.* = .{};
    }

    pub fn kind(self: BlockIndex, block_id: u32) BlockKind {
        return if (block_id < self.facts.len) self.facts[block_id].kind else .none;
    }

    pub fn isBypassed(self: BlockIndex, block_id: u32) bool {
        return block_id < self.bypassed.len and self.bypassed[block_id];
    }

    pub fn supportsFallback(self: BlockIndex, block_id: u32) bool {
        return block_id < self.fallback_supported.len and self.fallback_supported[block_id];
    }

    pub fn ownsFallback(self: BlockIndex, block_id: u32) bool {
        return block_id < self.owns_fallback.len and self.owns_fallback[block_id];
    }

    pub fn fallbackOwner(self: BlockIndex, block_id: u32) ?u32 {
        if (block_id >= self.fallback_owner.len)
            return null;
        const owner = self.fallback_owner[block_id];
        return if (owner == snapshot_v1.no_id) null else owner;
    }
};

pub fn indexBlocks(allocator: std.mem.Allocator, ctx: anytype) Error!BlockIndex {
    const block_count: usize = @intCast(ctx.function.block_count);
    const facts = try allocator.alloc(BlockFact, block_count);
    errdefer allocator.free(facts);
    @memset(facts, .{});
    const bypassed = try allocator.alloc(bool, block_count);
    errdefer allocator.free(bypassed);
    @memset(bypassed, false);
    const fallback_supported = try allocator.alloc(bool, block_count);
    errdefer allocator.free(fallback_supported);
    @memset(fallback_supported, false);
    const fastcall_fallbacks = try fastcallFallbackBits(allocator, ctx);
    defer allocator.free(fastcall_fallbacks);

    var block_id: u32 = 0;
    while (block_id < ctx.function.block_count) : (block_id += 1) {
        const block = try ctx.snapshot.irBlock(ctx.function, block_id);
        if (block.isEmpty())
            continue;
        facts[block_id] = try classifyBlock(ctx, block, fastcall_fallbacks[block_id]);
        fallback_supported[block_id] = try classifyFallbackSupport(ctx, facts[block_id], block);
    }

    const instruction_count: usize = @intCast(ctx.function.instruction_count);
    const consumed = try allocator.alloc(bool, instruction_count);
    defer allocator.free(consumed);
    @memset(consumed, false);

    block_id = 0;
    while (block_id < ctx.function.block_count) : (block_id += 1)
        try markOwnedAndInlineFallbacks(ctx, facts, bypassed, consumed, block_id);

    const incoming = try blockOperandIndex(allocator, ctx);
    defer allocator.free(incoming.offsets);
    defer allocator.free(incoming.refs);
    block_id = 0;
    while (block_id < ctx.function.block_count) : (block_id += 1) {
        if (try linearizedOnlyRewritten(ctx, facts, incoming, block_id))
            bypassed[block_id] = true;
        if (try stringEqualityOwned(ctx, facts, incoming, block_id))
            bypassed[block_id] = true;
    }
    // A fused helper owns the miss inside its span. Those guards are not branches.
    // A raw guard outside the span still keeps the fallback arm.
    try retainLiveStringKeyFallbacks(ctx, bypassed, consumed);
    try retainLiveSupportedFallbacks(ctx, bypassed, fallback_supported, consumed);

    const owns_fallback = try allocator.alloc(bool, block_count);
    errdefer allocator.free(owns_fallback);
    @memset(owns_fallback, false);
    const fallback_owner = try allocator.alloc(u32, block_count);
    errdefer allocator.free(fallback_owner);
    @memset(fallback_owner, snapshot_v1.no_id);
    block_id = 0;
    while (block_id < ctx.function.block_count) : (block_id += 1) {
        if (bypassed[block_id])
            owns_fallback[block_id] = true;
        const fact = facts[block_id];
        if (fact.fallback < block_count) {
            owns_fallback[fact.fallback] = true;
            if (fallback_owner[fact.fallback] == snapshot_v1.no_id) {
                fallback_owner[fact.fallback] = block_id;
            } else if (fallback_owner[fact.fallback] != block_id and !fallback_supported[fact.fallback]) {
                return Error.UnsupportedControlFlow;
            }
        }
        if (fact.extra0 < block_count)
            owns_fallback[fact.extra0] = true;
        if (fact.extra1 < block_count)
            owns_fallback[fact.extra1] = true;
    }

    return .{
        .allocator = allocator,
        .facts = facts,
        .bypassed = bypassed,
        .fallback_supported = fallback_supported,
        .owns_fallback = owns_fallback,
        .fallback_owner = fallback_owner,
    };
}

fn classifyFallbackSupport(ctx: anytype, fact: BlockFact, block: snapshot_v1.IrBlock) Error!bool {
    if (block.kind != .fallback or block.isEmpty())
        return false;
    return switch (fact.kind) {
        .ordinary_call_fallback, .fastcall_fallback, .xnext_prep, .generic_iteration_fallback, .namecall => true,
        else => (try ctx.supportsArithmeticFallback(block)) or
            (try ctx.supportsComparisonFallback(block)) or
            (try ctx.supportsMaterializedComparisonFallback(block)) or
            (try ctx.supportsLengthFallback(block)) or
            (try ctx.supportsNamecallFallback(block)) or
            (try ctx.supportsGeneralTableFallback(block)) or
            (try ctx.supportsStringKeyFallback(block)),
    };
}

/// Command gates skip matchers the block cannot satisfy. The first hit still wins.
fn classifyBlock(ctx: anytype, block: snapshot_v1.IrBlock, fastcall_fallback: bool) Error!BlockFact {
    const compilable = block.kind.isCompilable();
    const fallback = block.kind == .fallback;
    const span = block.finish - block.start;
    const head = (try ctx.instruction(block.start)).command;
    const tail = (try ctx.instruction(block.finish)).command;
    const before_tail: snapshot_v1.IrCommand = if (span == 0) head else (try ctx.instruction(block.finish - 1)).command;

    if (compilable and tail == .jump_eq_tag and before_tail == .load_tag) {
        if (try ctx.stringEqualityPattern(block)) |pattern|
            return .{ .kind = .string_equality, .extra0 = pattern.pointer_block };
    }
    if (compilable and tail == .jump and span >= 6 and (before_tail == .store_double or before_tail == .store_tag)) {
        if (try ctx.constantPowPattern(block)) |pattern|
            return .{ .kind = .constant_pow, .fast_target = pattern.fast_target };
    }
    if (compilable and tail == .jump and span >= 5 and
        (before_tail == .store_double or (before_tail == .store_tag and span >= 6)))
    {
        if (try ctx.constantArithmeticPattern(block)) |pattern|
            return .{ .kind = .constant_arith, .fast_target = pattern.fast_target };
    }
    if (compilable and tail == .jump and span >= 8 and (before_tail == .store_double or before_tail == .store_tag)) {
        if (try ctx.powPattern(block)) |pattern|
            return .{ .kind = .pow, .fast_target = pattern.fast_target };
    }
    if (compilable and tail == abi.ir_cmd_jump_slot_match and span >= 4) {
        if (try ctx.plainTableNamecallPattern(block)) |pattern|
            return .{
                .kind = .namecall,
                .fallback = pattern.fallback,
                .extra0 = pattern.first_fast,
                .extra1 = pattern.second_fast,
            };
    }
    if (fallback and tail == .jump and span >= 3 and before_tail == .call) {
        const saved = (try ctx.instruction(block.finish - 2)).command;
        if (saved == .set_savedpc and try ctx.supportsOrdinaryCallFallback(block))
            return .{ .kind = .ordinary_call_fallback };
    }
    if (fallback and fastcall_fallback)
        return .{ .kind = .fastcall_fallback };
    if (compilable and span == 8 and head == .interrupt and tail == .jump_eq_tag) {
        if (try ctx.specializedIpairsPattern(block)) |pattern| {
            const publish = try ipairsPublish(ctx, block);
            return .{
                .kind = .specialized_ipairs,
                .fallback = pattern.fallback_target orelse snapshot_v1.no_id,
                .extra0 = publish,
            };
        }
    }
    if (compilable and span == 3 and head == .interrupt and tail == abi.ir_cmd_forgloop) {
        if (try ctx.genericIterationPattern(block)) |pattern|
            return .{
                .kind = .generic_iteration,
                .fallback = pattern.fallback_target orelse snapshot_v1.no_id,
            };
    }
    if (fallback and span == 1 and head == .set_savedpc and tail == abi.ir_cmd_forgloop_fallback) {
        if (try ctx.genericIterationFallbackPattern(block)) |_|
            return .{ .kind = .generic_iteration_fallback };
    }
    if (compilable and ((tail == .jump and span >= 9) or (tail == .jump_cmp_num and span >= 6))) {
        if (try ctx.xnextFastPreparationPattern(block)) |pattern|
            return .{
                .kind = .xnext_fast,
                .fallback = pattern.fallback,
                .extra0 = pattern.publish orelse snapshot_v1.no_id,
            };
    }
    if (fallback and span == 0 and head == abi.ir_cmd_forgprep_xnext_fallback) {
        if (try ctx.xnextPreparationPattern(block)) |_|
            return .{ .kind = .xnext_prep };
    }
    if (compilable and tail == .jump and
        ((before_tail == .store_tvalue and span >= 5) or
            (before_tail == abi.ir_cmd_barrier_table_forward and span >= 7)))
    {
        if (try ctx.globalPattern(block)) |pattern|
            return .{ .kind = .global, .fast_target = pattern.fast_target };
    }
    if (compilable and tail == .jump and
        ((before_tail == abi.ir_cmd_barrier_table_forward and span >= 13) or
            (before_tail == .store_tvalue and span >= 8)))
    {
        if (try ctx.genericTablePattern(block)) |pattern|
            return .{ .kind = .generic_table, .fast_target = pattern.fast_target, .fallback = pattern.fallback };
    }
    if (compilable and tail == .jump and
        ((before_tail == abi.ir_cmd_barrier_table_forward and span >= 6) or
            (before_tail == .store_tvalue and span >= 7)))
    {
        if (try ctx.stringTablePattern(block)) |pattern|
            return .{ .kind = .string_table, .fast_target = pattern.fast_target, .fallback = pattern.fallback };
    }
    if (tail == .jump and span >= 8 and before_tail == .store_tag) {
        if (try ctx.dynamicLengthPattern(block)) |pattern|
            return .{ .kind = .dynamic_length, .fallback = pattern.fallback };
    }
    if (try semanticArrayBlock(ctx, block, head, tail, before_tail, span))
        return .{ .kind = .semantic_array };
    return .{ .kind = .dispatch };
}

fn semanticArrayBlock(
    ctx: anytype,
    block: snapshot_v1.IrBlock,
    head: snapshot_v1.IrCommand,
    tail: snapshot_v1.IrCommand,
    before_tail: snapshot_v1.IrCommand,
    span: u32,
) Error!bool {
    if (tail != .jump)
        return false;
    if (before_tail == abi.ir_cmd_barrier_table_forward and span == 10 and head == .load_tag) {
        if (try ctx.arraySetPattern(block)) |_|
            return true;
    }
    if (before_tail == .store_tvalue and span >= 8) {
        if (try ctx.arrayGetPattern(block)) |_|
            return true;
    }
    if (before_tail == .store_tvalue and span >= 2) {
        const earlier = (try ctx.instruction(block.finish - 2)).command;
        if (earlier == .load_tvalue and (try ctx.trustedArrayGetPattern(block)) != null)
            return true;
    }
    if (before_tail == .store_tag and span >= 8) {
        if (try ctx.tableLenPattern(block)) |_|
            return true;
    }
    return false;
}

fn ipairsPublish(ctx: anytype, block: snapshot_v1.IrBlock) Error!u32 {
    const branch = try ctx.instruction(block.finish);
    if (branch.operand_count < 4)
        return snapshot_v1.no_id;
    const publish = try ctx.operand(branch, 3);
    return if (publish.kind == .block) publish.value else snapshot_v1.no_id;
}

fn markOwnedAndInlineFallbacks(
    ctx: anytype,
    facts: []BlockFact,
    bypassed: []bool,
    consumed: []bool,
    block_id: u32,
) Error!void {
    const fact = facts[block_id];
    const block = try ctx.snapshot.irBlock(ctx.function, block_id);
    switch (fact.kind) {
        .namecall => {
            markId(bypassed, fact.fallback);
            markId(bypassed, fact.extra0);
            markId(bypassed, fact.extra1);
            // The probe and namecall_plain stay in this block. The fallback block is the same call.
            if (try ctx.plainTableNamecallPattern(block)) |pattern|
                markRange(consumed, pattern.start, block.finish);
        },
        .xnext_fast => {
            markId(bypassed, fact.fallback);
            markId(bypassed, fact.extra0);
            if (try ctx.xnextFastPreparationPattern(block)) |pattern|
                markRange(consumed, pattern.start, block.finish);
        },
        // The guarded ipairs arm still sets dispatch to its fallback. Leave that span live.
        .specialized_ipairs => {
            markId(bypassed, fact.fallback);
            markId(bypassed, fact.extra0);
        },
        .dynamic_length => {
            markId(bypassed, fact.fallback);
            if (try ctx.dynamicLengthPattern(block)) |pattern|
                markRange(consumed, pattern.start, block.finish);
        },
        .string_table => {
            markId(bypassed, fact.fallback);
            if (try ctx.stringTablePattern(block)) |pattern|
                markRange(consumed, pattern.start, block.finish);
        },
        .generic_table => {
            markId(bypassed, fact.fallback);
            if (try ctx.genericTablePattern(block)) |pattern|
                markRange(consumed, pattern.start, block.finish);
        },
        .global => {
            if (try ctx.globalPattern(block)) |pattern| {
                markRange(consumed, pattern.start, block.finish);
                // check_slot_match is the third command. Its miss block is not on GlobalPattern.
                if (pattern.start + 2 <= block.finish) {
                    const match = try ctx.instruction(pattern.start + 2);
                    if (match.operand_count > 2) {
                        const fallback = try ctx.operand(match, 2);
                        if (fallback.kind == .block and fallback.value != pattern.rejoin)
                            markId(bypassed, fallback.value);
                    }
                }
            }
        },
        .semantic_array => {
            if (try ctx.semanticArrayOperation(block)) |operation| {
                markRange(consumed, operation.pattern.start, block.finish);
                try markFallbackOperands(ctx, bypassed, operation.pattern.start, block.finish, operation.pattern.rejoin);
            }
        },
        else => {},
    }

    if (block.isEmpty() or !block.kind.isCompilable())
        return;
    var instruction_id = block.start;
    while (instruction_id <= block.finish) : (instruction_id += 1) {
        if (ctx.plan.clusterAt(instruction_id)) |cluster| {
            if (cluster.kind == .literal_field_set and instruction_id == cluster.at) {
                const match = try ctx.instruction(cluster.at + 1);
                const fallback = try ctx.operand(match, 2);
                if (fallback.kind == .block)
                    markId(bypassed, fallback.value);
            }
            if (cluster.kind == .inline_generic_table_set and instruction_id == cluster.at)
                if (try ctx.inlineGenericTableSetPatternAt(cluster.at)) |pattern|
                    markId(bypassed, pattern.pattern.fallback);
        }
        const clustered = ctx.plan.clusterAt(instruction_id) != null;
        const command = (try ctx.instruction(instruction_id)).command;
        if (command == .load_tag) {
            if (try ctx.inlineGeneralStringSetPatternAt(instruction_id, block)) |operation| {
                markId(bypassed, operation.pattern.fallback);
                if (!clustered)
                    markRange(consumed, instruction_id, operation.finish);
            }
            if (try ctx.inlineStringGetPatternAt(instruction_id, block)) |pattern| {
                markId(bypassed, pattern.fallback);
                // The emitter advances six, then the loop adds one. start+6 is included.
                if (!clustered)
                    markRange(consumed, instruction_id, instruction_id + 6);
            }
        } else if (command == .load_tvalue) {
            if (try ctx.inlinePreloadedStringSetPatternAt(instruction_id, block)) |operation| {
                markId(bypassed, operation.pattern.fallback);
                if (!clustered)
                    markRange(consumed, instruction_id, operation.finish);
            }
        } else if (command == abi.ir_cmd_get_slot_node_addr) {
            if (try ctx.inlineOwnedStringSetPatternAt(instruction_id, block)) |operation| {
                markId(bypassed, operation.pattern.fallback);
                if (!clustered)
                    markRange(consumed, instruction_id, operation.finish);
            }
        }
    }
}

fn markRange(consumed: []bool, start: u32, finish: u32) void {
    if (start > finish or finish >= consumed.len)
        return;
    var id = start;
    while (id <= finish) : (id += 1)
        consumed[id] = true;
}

fn markFallbackOperands(
    ctx: anytype,
    bypassed: []bool,
    start: u32,
    finish: u32,
    keep: u32,
) Error!void {
    if (start > finish or finish >= ctx.function.instruction_count)
        return;
    var id = start;
    while (id <= finish) : (id += 1) {
        const instruction_value = try ctx.instruction(id);
        var operand_id: u32 = 0;
        while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
            const operand_value = try ctx.operand(instruction_value, operand_id);
            if (operand_value.kind != .block or operand_value.value == keep or
                operand_value.value >= ctx.function.block_count)
                continue;
            const target = try ctx.snapshot.irBlock(ctx.function, operand_value.value);
            if (target.kind == .fallback)
                markId(bypassed, operand_value.value);
        }
    }
}

fn markId(bypassed: []bool, id: u32) void {
    if (id != snapshot_v1.no_id and id < bypassed.len)
        bypassed[id] = true;
}

fn retainLiveSupportedFallbacks(
    ctx: anytype,
    bypassed: []bool,
    fallback_supported: []const bool,
    consumed: []const bool,
) Error!void {
    var block_id: u32 = 0;
    while (block_id < ctx.function.block_count) : (block_id += 1) {
        if (bypassed[block_id])
            continue;
        const block = try ctx.snapshot.irBlock(ctx.function, block_id);
        if (block.isEmpty() or !block.kind.isCompilable())
            continue;
        var instruction_id = block.start;
        while (instruction_id <= block.finish) : (instruction_id += 1) {
            if (ctx.plan.clusterAt(instruction_id) != null)
                continue;
            if (instruction_id < consumed.len and consumed[instruction_id])
                continue;
            const instruction_value = try ctx.instruction(instruction_id);
            var operand_id: u32 = 0;
            while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                const operand_value = try ctx.operand(instruction_value, operand_id);
                if (operand_value.kind != .block or operand_value.value >= bypassed.len or
                    operand_value.value >= fallback_supported.len or !bypassed[operand_value.value] or
                    !fallback_supported[operand_value.value])
                    continue;
                bypassed[operand_value.value] = false;
            }
        }
    }
}

fn retainLiveStringKeyFallbacks(ctx: anytype, bypassed: []bool, consumed: []const bool) Error!void {
    var block_id: u32 = 0;
    while (block_id < ctx.function.block_count) : (block_id += 1) {
        if (bypassed[block_id])
            continue;
        const block = try ctx.snapshot.irBlock(ctx.function, block_id);
        if (block.isEmpty() or !block.kind.isCompilable())
            continue;
        var instruction_id = block.start;
        while (instruction_id <= block.finish) : (instruction_id += 1) {
            // Cluster emission replaces the instruction. A consumed span is the fused helper.
            if (ctx.plan.clusterAt(instruction_id) != null)
                continue;
            if (instruction_id < consumed.len and consumed[instruction_id])
                continue;
            const instruction_value = try ctx.instruction(instruction_id);
            var operand_id: u32 = 0;
            while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                const operand_value = try ctx.operand(instruction_value, operand_id);
                if (operand_value.kind != .block or operand_value.value >= bypassed.len or
                    !bypassed[operand_value.value])
                    continue;
                const target = try ctx.snapshot.irBlock(ctx.function, operand_value.value);
                if (try ctx.supportsStringKeyFallback(target))
                    bypassed[operand_value.value] = false;
            }
        }
    }
}

const BlockOperandRef = struct {
    source: u32,
    instruction: u32,
};

const BlockOperandIndex = struct {
    offsets: []u32,
    refs: []BlockOperandRef,
};

fn blockOperandIndex(allocator: std.mem.Allocator, ctx: anytype) Error!BlockOperandIndex {
    const block_count: usize = @intCast(ctx.function.block_count);
    const counts = try allocator.alloc(u32, block_count);
    defer allocator.free(counts);
    @memset(counts, 0);

    var block_id: u32 = 0;
    while (block_id < ctx.function.block_count) : (block_id += 1) {
        const block = try ctx.snapshot.irBlock(ctx.function, block_id);
        if (block.isEmpty())
            continue;
        var instruction_id = block.start;
        while (instruction_id <= block.finish) : (instruction_id += 1) {
            const instruction_value = try ctx.instruction(instruction_id);
            var operand_id: u32 = 0;
            while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                const operand_value = try ctx.operand(instruction_value, operand_id);
                if (operand_value.kind == .block and operand_value.value < ctx.function.block_count)
                    counts[operand_value.value] += 1;
            }
        }
    }

    const offsets = try allocator.alloc(u32, block_count + 1);
    errdefer allocator.free(offsets);
    var total: u32 = 0;
    offsets[0] = 0;
    var index: usize = 0;
    while (index < counts.len) : (index += 1) {
        total = std.math.add(u32, total, counts[index]) catch return Error.ResourceLimit;
        offsets[index + 1] = total;
    }
    const refs = try allocator.alloc(BlockOperandRef, total);
    errdefer allocator.free(refs);
    const cursor = try allocator.alloc(u32, block_count);
    defer allocator.free(cursor);
    @memcpy(cursor, offsets[0..block_count]);

    block_id = 0;
    while (block_id < ctx.function.block_count) : (block_id += 1) {
        const block = try ctx.snapshot.irBlock(ctx.function, block_id);
        if (block.isEmpty())
            continue;
        var instruction_id = block.start;
        while (instruction_id <= block.finish) : (instruction_id += 1) {
            const instruction_value = try ctx.instruction(instruction_id);
            var operand_id: u32 = 0;
            while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                const operand_value = try ctx.operand(instruction_value, operand_id);
                if (operand_value.kind != .block or operand_value.value >= ctx.function.block_count)
                    continue;
                const slot = cursor[operand_value.value];
                refs[slot] = .{ .source = block_id, .instruction = instruction_id };
                cursor[operand_value.value] = slot + 1;
            }
        }
    }
    return .{ .offsets = offsets, .refs = refs };
}

fn linearizedOnlyRewritten(
    ctx: anytype,
    facts: []const BlockFact,
    incoming: BlockOperandIndex,
    block_id: u32,
) Error!bool {
    if (block_id == ctx.function.entry_block)
        return false;
    const block = try ctx.snapshot.irBlock(ctx.function, block_id);
    if (block.kind != .linearized)
        return false;

    var has_rewritten_incoming = false;
    const refs = incoming.refs[incoming.offsets[block_id]..incoming.offsets[block_id + 1]];
    for (refs) |ref| {
        if (ref.source == block_id)
            continue;
        const source_block = try ctx.snapshot.irBlock(ctx.function, ref.source);
        const source = facts[ref.source];
        const instruction_value = try ctx.instruction(ref.instruction);
        const rewritten = source.fast_target == block_id and
            ref.instruction == source_block.finish and
            instruction_value.command == .jump and
            (source.kind == .string_table or source.kind == .generic_table or
                source.kind == .global or source.kind == .pow or
                source.kind == .constant_arith or source.kind == .constant_pow);
        if (!rewritten)
            return false;
        has_rewritten_incoming = true;
    }
    return has_rewritten_incoming;
}

fn stringEqualityOwned(
    ctx: anytype,
    facts: []const BlockFact,
    incoming: BlockOperandIndex,
    block_id: u32,
) Error!bool {
    if (block_id == ctx.function.entry_block)
        return false;
    var owner: ?u32 = null;
    var source_block_id: u32 = 0;
    while (source_block_id < facts.len) : (source_block_id += 1) {
        if (source_block_id == block_id)
            continue;
        if (facts[source_block_id].kind == .string_equality and
            facts[source_block_id].extra0 == block_id)
        {
            if (owner != null)
                return false;
            owner = source_block_id;
        }
    }
    if (owner == null)
        return false;
    var incoming_count: u32 = 0;
    const refs = incoming.refs[incoming.offsets[block_id]..incoming.offsets[block_id + 1]];
    for (refs) |ref| {
        if (ref.source == block_id)
            continue;
        if (ref.source != owner.?)
            return false;
        incoming_count += 1;
    }
    return incoming_count == 1;
}

fn fastcallFallbackBits(allocator: std.mem.Allocator, ctx: anytype) Error![]bool {
    const block_count: usize = @intCast(ctx.function.block_count);
    const bits = try allocator.alloc(bool, block_count);
    errdefer allocator.free(bits);
    @memset(bits, false);
    var source_id: u32 = 0;
    while (source_id < ctx.function.block_count) : (source_id += 1) {
        const source = try ctx.snapshot.irBlock(ctx.function, source_id);
        if (!source.kind.isCompilable() or source.isEmpty())
            continue;
        var instruction_id = source.start;
        while (instruction_id <= source.finish) : (instruction_id += 1) {
            const fastcall_pattern = if (try ctx.fastcallPatternAt(instruction_id, source)) |found|
                found
            else
                try ctx.fixedContiguousFastcallPatternAt(instruction_id, source);
            if (fastcall_pattern) |pattern| {
                if (pattern.fallback < ctx.function.block_count)
                    bits[pattern.fallback] = true;
            }
        }
    }
    return bits;
}

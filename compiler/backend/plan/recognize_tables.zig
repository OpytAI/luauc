const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const model = @import("luauc_backend_model");

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

    pub fn deinit(self: *BlockIndex) void {
        if (self.facts.len != 0)
            self.allocator.free(self.facts);
        if (self.bypassed.len != 0)
            self.allocator.free(self.bypassed);
        self.* = .{};
    }

    pub fn kind(self: BlockIndex, block_id: u32) BlockKind {
        return if (block_id < self.facts.len) self.facts[block_id].kind else .none;
    }

    pub fn isBypassed(self: BlockIndex, block_id: u32) bool {
        return block_id < self.bypassed.len and self.bypassed[block_id];
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

    var block_id: u32 = 0;
    while (block_id < ctx.function.block_count) : (block_id += 1) {
        const block = try ctx.snapshot.irBlock(ctx.function, block_id);
        if (block.isEmpty())
            continue;
        facts[block_id] = try classifyBlock(ctx, block_id, block);
    }

    block_id = 0;
    while (block_id < ctx.function.block_count) : (block_id += 1)
        try markOwnedAndInlineFallbacks(ctx, facts, bypassed, block_id);

    block_id = 0;
    while (block_id < ctx.function.block_count) : (block_id += 1) {
        if (try linearizedOnlyRewritten(ctx, facts, block_id))
            bypassed[block_id] = true;
        if (try stringEqualityOwned(ctx, facts, block_id))
            bypassed[block_id] = true;
    }

    return .{
        .allocator = allocator,
        .facts = facts,
        .bypassed = bypassed,
    };
}

fn classifyBlock(ctx: anytype, block_id: u32, block: snapshot_v1.IrBlock) Error!BlockFact {
    if (try ctx.stringEqualityPattern(block)) |pattern|
        return .{ .kind = .string_equality, .extra0 = pattern.pointer_block };
    if (try ctx.constantPowPattern(block)) |pattern|
        return .{ .kind = .constant_pow, .fast_target = pattern.fast_target };
    if (try ctx.constantArithmeticPattern(block)) |pattern|
        return .{ .kind = .constant_arith, .fast_target = pattern.fast_target };
    if (try ctx.powPattern(block)) |pattern|
        return .{ .kind = .pow, .fast_target = pattern.fast_target };
    if (try ctx.plainTableNamecallPattern(block)) |pattern|
        return .{
            .kind = .namecall,
            .fallback = pattern.fallback,
            .extra0 = pattern.first_fast,
            .extra1 = pattern.second_fast,
        };
    if (try ctx.supportsOrdinaryCallFallback(block))
        return .{ .kind = .ordinary_call_fallback };
    if (try ctx.isFastcallFallback(block_id, block))
        return .{ .kind = .fastcall_fallback };
    if (try ctx.specializedIpairsPattern(block)) |pattern| {
        const publish = try ipairsPublish(ctx, block);
        return .{
            .kind = .specialized_ipairs,
            .fallback = pattern.fallback_target orelse snapshot_v1.no_id,
            .extra0 = publish,
        };
    }
    if (try ctx.genericIterationPattern(block)) |pattern|
        return .{
            .kind = .generic_iteration,
            .fallback = pattern.fallback_target orelse snapshot_v1.no_id,
        };
    if (try ctx.genericIterationFallbackPattern(block)) |_|
        return .{ .kind = .generic_iteration_fallback };
    if (try ctx.xnextFastPreparationPattern(block)) |pattern|
        return .{
            .kind = .xnext_fast,
            .fallback = pattern.fallback,
            .extra0 = pattern.publish orelse snapshot_v1.no_id,
        };
    if (try ctx.xnextPreparationPattern(block)) |_|
        return .{ .kind = .xnext_prep };
    if (try ctx.globalPattern(block)) |pattern|
        return .{ .kind = .global, .fast_target = pattern.fast_target };
    if (try ctx.genericTablePattern(block)) |pattern|
        return .{ .kind = .generic_table, .fast_target = pattern.fast_target, .fallback = pattern.fallback };
    if (try ctx.stringTablePattern(block)) |pattern|
        return .{ .kind = .string_table, .fast_target = pattern.fast_target, .fallback = pattern.fallback };
    if (try ctx.dynamicLengthPattern(block)) |pattern|
        return .{ .kind = .dynamic_length, .fallback = pattern.fallback };
    if (try ctx.semanticArrayOperation(block)) |_|
        return .{ .kind = .semantic_array };
    return .{ .kind = .dispatch };
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
    block_id: u32,
) Error!void {
    const fact = facts[block_id];
    switch (fact.kind) {
        .namecall => {
            markId(bypassed, fact.fallback);
            markId(bypassed, fact.extra0);
            markId(bypassed, fact.extra1);
        },
        .xnext_fast, .specialized_ipairs => {
            markId(bypassed, fact.fallback);
            markId(bypassed, fact.extra0);
        },
        .dynamic_length, .string_table, .generic_table => markId(bypassed, fact.fallback),
        else => {},
    }

    const block = try ctx.snapshot.irBlock(ctx.function, block_id);
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
        if (try ctx.inlineStringSetPatternAt(instruction_id, block)) |operation|
            markId(bypassed, operation.pattern.fallback);
        if (try ctx.inlineStringGetPatternAt(instruction_id, block)) |pattern|
            markId(bypassed, pattern.fallback);
    }
}

fn markId(bypassed: []bool, id: u32) void {
    if (id != snapshot_v1.no_id and id < bypassed.len)
        bypassed[id] = true;
}

fn linearizedOnlyRewritten(ctx: anytype, facts: []const BlockFact, block_id: u32) Error!bool {
    if (block_id == ctx.function.entry_block)
        return false;
    const block = try ctx.snapshot.irBlock(ctx.function, block_id);
    if (block.kind != .linearized)
        return false;

    var has_rewritten_incoming = false;
    var source_block_id: u32 = 0;
    while (source_block_id < ctx.function.block_count) : (source_block_id += 1) {
        if (source_block_id == block_id)
            continue;
        const source_block = try ctx.snapshot.irBlock(ctx.function, source_block_id);
        if (source_block.isEmpty())
            continue;
        const source = facts[source_block_id];
        var instruction_id = source_block.start;
        while (instruction_id <= source_block.finish) : (instruction_id += 1) {
            const instruction_value = try ctx.instruction(instruction_id);
            var operand_id: u32 = 0;
            while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                const operand_value = try ctx.operand(instruction_value, operand_id);
                if (operand_value.kind != .block or operand_value.value != block_id)
                    continue;
                const rewritten = source.fast_target == block_id and
                    instruction_id == source_block.finish and
                    instruction_value.command == .jump and
                    (source.kind == .string_table or source.kind == .generic_table or
                        source.kind == .global or source.kind == .pow or
                        source.kind == .constant_arith or source.kind == .constant_pow);
                if (!rewritten)
                    return false;
                has_rewritten_incoming = true;
            }
        }
    }
    return has_rewritten_incoming;
}

fn stringEqualityOwned(ctx: anytype, facts: []const BlockFact, block_id: u32) Error!bool {
    if (block_id == ctx.function.entry_block)
        return false;
    var owner: ?u32 = null;
    var source_block_id: u32 = 0;
    while (source_block_id < ctx.function.block_count) : (source_block_id += 1) {
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
    source_block_id = 0;
    while (source_block_id < ctx.function.block_count) : (source_block_id += 1) {
        if (source_block_id == block_id)
            continue;
        const source_block = try ctx.snapshot.irBlock(ctx.function, source_block_id);
        if (source_block.isEmpty())
            continue;
        var instruction_id = source_block.start;
        while (instruction_id <= source_block.finish) : (instruction_id += 1) {
            const instruction_value = try ctx.instruction(instruction_id);
            var operand_id: u32 = 0;
            while (operand_id < instruction_value.operand_count) : (operand_id += 1) {
                const operand_value = try ctx.operand(instruction_value, operand_id);
                if (operand_value.kind == .block and operand_value.value == block_id) {
                    if (source_block_id != owner.?)
                        return false;
                    incoming_count += 1;
                }
            }
        }
    }
    return incoming_count == 1;
}

const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const model = @import("luauc_backend_model");

const Error = model.Error;

pub const IterationFact = struct {
    block_id: u32,
    base: u32,
    aux: u32,
    repeat_target: u32,
    exit_target: u32,
    fallback_target: u32,
};

pub const FastcallFact = struct {
    block_id: u32,
    start: u32,
    finish: u32,
    fallback: u32,
    fast_target: u32,
};

pub const CallFacts = struct {
    allocator: std.mem.Allocator = undefined,
    iterations: []IterationFact = &.{},
    fastcalls: []FastcallFact = &.{},

    pub fn deinit(self: *CallFacts) void {
        if (self.iterations.len != 0)
            self.allocator.free(self.iterations);
        if (self.fastcalls.len != 0)
            self.allocator.free(self.fastcalls);
        self.* = .{};
    }
};

pub fn collectCallFacts(allocator: std.mem.Allocator, ctx: anytype) Error!CallFacts {
    var iterations: std.ArrayList(IterationFact) = .empty;
    errdefer iterations.deinit(allocator);
    var fastcalls: std.ArrayList(FastcallFact) = .empty;
    errdefer fastcalls.deinit(allocator);

    var block_id: u32 = 0;
    while (block_id < ctx.function.block_count) : (block_id += 1) {
        const block = try ctx.snapshot.irBlock(ctx.function, block_id);
        if (block.isEmpty())
            continue;
        if (try ctx.genericIterationPattern(block)) |pattern|
            try iterations.append(allocator, .{
                .block_id = block_id,
                .base = pattern.base,
                .aux = pattern.aux,
                .repeat_target = pattern.repeat_target,
                .exit_target = pattern.exit_target,
                .fallback_target = pattern.fallback_target orelse snapshot_v1.no_id,
            });
        if (try ctx.genericIterationFallbackPattern(block)) |pattern|
            try iterations.append(allocator, .{
                .block_id = block_id,
                .base = pattern.base,
                .aux = pattern.aux,
                .repeat_target = pattern.repeat_target,
                .exit_target = pattern.exit_target,
                .fallback_target = snapshot_v1.no_id,
            });
        if (try ctx.specializedIpairsPattern(block)) |pattern|
            try iterations.append(allocator, .{
                .block_id = block_id,
                .base = pattern.base,
                .aux = pattern.aux,
                .repeat_target = pattern.repeat_target,
                .exit_target = pattern.exit_target,
                .fallback_target = pattern.fallback_target orelse snapshot_v1.no_id,
            });
        if (try ctx.fastcallPatternAt(block.start, block)) |pattern|
            try fastcalls.append(allocator, .{
                .block_id = block_id,
                .start = pattern.start,
                .finish = pattern.finish,
                .fallback = pattern.fallback,
                .fast_target = pattern.fast_target,
            });
    }

    return .{
        .allocator = allocator,
        .iterations = try iterations.toOwnedSlice(allocator),
        .fastcalls = try fastcalls.toOwnedSlice(allocator),
    };
}

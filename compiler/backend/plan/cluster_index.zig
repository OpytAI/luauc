const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");
const recognize = @import("luauc_backend_recognize");

const Error = model.Error;

pub const ClusterKind = enum {
    constant_truthy,
    inline_const_table_get,
    inline_array_get,
    semantic_table_reload,
    inline_generic_table_set,
    userdata_alloc,
    literal_field_set,
    constant_load,
    dup_table,
    table_insert_append,
    plain_len,
    concat,
    table_alloc,
    integer_create,
    linearized_pow,
    type_name,
};

pub const Cluster = struct {
    kind: ClusterKind,
    start: u32,
    at: u32,
    finish: u32,
};

pub fn stampUserdataClusters(
    allocator: std.mem.Allocator,
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    proto: snapshot_v1.Proto,
    instruction_blocks: []const u32,
    cluster_index: []u32,
) Error![]Cluster {
    var clusters: std.ArrayList(Cluster) = .empty;
    errdefer clusters.deinit(allocator);
    var instruction_id: u32 = 0;
    while (instruction_id < function.instruction_count) : (instruction_id += 1) {
        if ((try snapshot.irInstruction(function, instruction_id)).command != .check_gc)
            continue;
        const pattern = (try recognize.userdataAllocationAt(
            snapshot,
            function,
            proto,
            instruction_blocks,
            instruction_id,
        )) orelse continue;
        const cluster = Cluster{
            .kind = .userdata_alloc,
            .start = pattern.start,
            .at = pattern.start,
            .finish = pattern.finish,
        };
        const index: u32 = @intCast(clusters.items.len);
        try clusters.append(allocator, cluster);
        var covered = pattern.start;
        while (covered <= pattern.finish) : (covered += 1)
            cluster_index[covered] = index;
        instruction_id = pattern.finish;
    }
    return clusters.toOwnedSlice(allocator);
}

/// First covering matcher wins; later families must not overwrite a hit.
pub fn matchInstructionCluster(ctx: anytype, instruction_id: u32) Error!?Cluster {
    {
        var distance: u32 = 0;
        while (distance < 3 and distance <= instruction_id) : (distance += 1) {
            if (try ctx.constantTruthyFallbackPatternAt(instruction_id - distance)) |pattern| {
                if (instruction_id <= pattern.finish)
                    return .{
                        .kind = .constant_truthy,
                        .start = pattern.start,
                        .at = pattern.start,
                        .finish = pattern.finish,
                    };
            }
        }
    }
    {
        var distance: u32 = 0;
        while (distance < 8 and distance <= instruction_id) : (distance += 1) {
            const start = instruction_id - distance;
            if ((try ctx.instruction(start)).command == .load_tag)
                if (try ctx.inlineConstantTableGetPatternAt(start)) |pattern|
                    if (instruction_id <= pattern.finish)
                        return .{
                            .kind = .inline_const_table_get,
                            .start = pattern.pattern.start,
                            .at = pattern.pattern.start,
                            .finish = pattern.finish,
                        };
        }
    }
    {
        var distance: u32 = 0;
        while (distance < 3 and distance <= instruction_id) : (distance += 1) {
            if (try ctx.inlineArrayGetPatternAt(instruction_id - distance)) |pattern|
                if (instruction_id <= pattern.finish)
                    return .{
                        .kind = .inline_array_get,
                        .start = pattern.start,
                        .at = pattern.start,
                        .finish = pattern.finish,
                    };
        }
    }
    if (try ctx.semanticTableReloadPatternAt(instruction_id)) |pattern|
        return .{
            .kind = .semantic_table_reload,
            .start = pattern.start,
            .at = pattern.start,
            .finish = pattern.finish,
        };
    if (instruction_id != 0)
        if (try ctx.semanticTableReloadPatternAt(instruction_id - 1)) |pattern|
            if (pattern.finish == instruction_id)
                return .{
                    .kind = .semantic_table_reload,
                    .start = pattern.start,
                    .at = pattern.start,
                    .finish = pattern.finish,
                };
    {
        var distance: u32 = 0;
        while (distance < 15 and distance <= instruction_id) : (distance += 1) {
            const start = instruction_id - distance;
            if ((try ctx.instruction(start)).command == .load_tag)
                if (try ctx.inlineGenericTableSetPatternAt(start)) |pattern|
                    if (instruction_id <= pattern.finish)
                        return .{
                            .kind = .inline_generic_table_set,
                            .start = pattern.pattern.start,
                            .at = pattern.pattern.start,
                            .finish = pattern.finish,
                        };
        }
    }
    if ((try ctx.instruction(instruction_id)).command == .check_gc) {
        if (try ctx.userdataAllocationPatternAt(instruction_id)) |pattern|
            if (instruction_id <= pattern.finish)
                return .{
                    .kind = .userdata_alloc,
                    .start = pattern.start,
                    .at = pattern.start,
                    .finish = pattern.finish,
                };
    }
    {
        var distance: u32 = 0;
        while (distance < 7 and distance <= instruction_id) : (distance += 1) {
            const start = instruction_id - distance;
            if ((try ctx.instruction(start)).command == abi.ir_cmd_get_slot_node_addr)
                if (try ctx.literalFieldSetPatternAt(start)) |pattern|
                    if (instruction_id <= pattern.finish)
                        return .{
                            .kind = .literal_field_set,
                            .start = pattern.start,
                            .at = pattern.start,
                            .finish = pattern.finish,
                        };
        }
    }
    if (try ctx.constantLoadPatternAt(instruction_id)) |pattern|
        return .{
            .kind = .constant_load,
            .start = pattern.start,
            .at = pattern.start,
            .finish = pattern.finish,
        };
    if (instruction_id != 0)
        if (try ctx.constantLoadPatternAt(instruction_id - 1)) |pattern|
            if (pattern.finish == instruction_id)
                return .{
                    .kind = .constant_load,
                    .start = pattern.start,
                    .at = pattern.start,
                    .finish = pattern.finish,
                };
    {
        var distance: u32 = 0;
        while (distance < 5 and distance <= instruction_id) : (distance += 1) {
            if (try ctx.dupTablePatternAt(instruction_id - distance)) |pattern|
                if (instruction_id <= pattern.finish)
                    return .{
                        .kind = .dup_table,
                        .start = pattern.start,
                        .at = pattern.start,
                        .finish = pattern.finish,
                    };
        }
    }
    if ((try ctx.instruction(instruction_id)).command == abi.ir_cmd_check_readonly and
        instruction_id + 1 < ctx.function.instruction_count)
    {
        if (try ctx.tableInsertAppendPatternAt(instruction_id + 1)) |pattern|
            if (pattern.start == instruction_id)
                return .{
                    .kind = .table_insert_append,
                    .start = pattern.start,
                    .at = instruction_id + 1,
                    .finish = pattern.finish,
                };
    }
    {
        var distance: u32 = 0;
        while (distance < 7 and distance <= instruction_id) : (distance += 1) {
            const candidate = instruction_id - distance;
            if ((try ctx.instruction(candidate)).command == abi.ir_cmd_table_len)
                if (try ctx.tableInsertAppendPatternAt(candidate)) |pattern|
                    if (instruction_id <= pattern.finish)
                        return .{
                            .kind = .table_insert_append,
                            .start = pattern.start,
                            .at = candidate,
                            .finish = pattern.finish,
                        };
        }
    }
    if (ctx.plan.plainLenContaining(instruction_id)) |pattern|
        return .{
            .kind = .plain_len,
            .start = pattern.table_len_id,
            .at = pattern.table_len_id,
            .finish = pattern.finish,
        };
    {
        var distance: u32 = 0;
        while (distance < 5 and distance <= instruction_id) : (distance += 1) {
            if (try ctx.concatPatternAt(instruction_id - distance)) |pattern| {
                if (instruction_id <= pattern.finish)
                    return .{
                        .kind = .concat,
                        .start = pattern.start,
                        .at = pattern.start,
                        .finish = pattern.finish,
                    };
            }
        }
    }
    {
        var back: u32 = 0;
        while (back <= 3 and back <= instruction_id) : (back += 1) {
            if (try ctx.tableAllocationPatternAt(instruction_id - back)) |pattern| {
                if (instruction_id <= pattern.finish)
                    return .{
                        .kind = .table_alloc,
                        .start = pattern.start,
                        .at = pattern.start,
                        .finish = pattern.finish,
                    };
            }
        }
    }
    {
        var distance: u32 = 0;
        while (distance <= 6 and distance <= instruction_id) : (distance += 1) {
            if (try ctx.integerCreatePatternAt(instruction_id - distance)) |pattern| {
                if (instruction_id <= pattern.finish)
                    return .{
                        .kind = .integer_create,
                        .start = if (pattern.check >= 5) pattern.check - 5 else pattern.check,
                        .at = pattern.check,
                        .finish = pattern.finish,
                    };
            }
        }
    }
    if (ctx.plan.instructionBlock(instruction_id)) |block_id| {
        if (@hasField(@TypeOf(ctx), "snapshot")) {
            const block = try ctx.snapshot.irBlock(ctx.function, block_id);
            if (try ctx.linearizedPowPattern(instruction_id, block)) |pattern|
                return .{
                    .kind = .linearized_pow,
                    .start = instruction_id,
                    .at = instruction_id,
                    .finish = pattern.finish,
                };
        }
    }
    {
        const command = (try ctx.instruction(instruction_id)).command;
        if (command == abi.ir_cmd_get_type or command == abi.ir_cmd_get_typeof) {
            if (try ctx.typeNamePattern(instruction_id, command == abi.ir_cmd_get_typeof)) |pattern|
                return .{
                    .kind = .type_name,
                    .start = instruction_id,
                    .at = instruction_id,
                    .finish = pattern.finish,
                };
        }
        var distance: u32 = 1;
        while (distance <= 4 and distance <= instruction_id) : (distance += 1) {
            const start = instruction_id - distance;
            const start_command = (try ctx.instruction(start)).command;
            if (start_command == abi.ir_cmd_get_type or start_command == abi.ir_cmd_get_typeof) {
                if (try ctx.typeNamePattern(start, start_command == abi.ir_cmd_get_typeof)) |pattern| {
                    if (instruction_id <= pattern.finish)
                        return .{
                            .kind = .type_name,
                            .start = start,
                            .at = start,
                            .finish = pattern.finish,
                        };
                }
            }
        }
    }
    return null;
}

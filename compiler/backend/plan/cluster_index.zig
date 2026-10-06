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

fn hit(kind: ClusterKind, start: u32, at: u32, finish: u32) Cluster {
    return .{ .kind = kind, .start = start, .at = at, .finish = finish };
}

/// `distance` is this command's offset inside a fixed sequence. The anchor is that sequence's first command.
fn sequenceStart(
    ctx: anytype,
    instruction_id: u32,
    distance: u32,
    command: snapshot_v1.IrCommand,
    anchor: snapshot_v1.IrCommand,
    second: snapshot_v1.IrCommand,
) Error!?u32 {
    if (distance > instruction_id)
        return null;
    const start = instruction_id - distance;
    const start_command = if (distance == 0) command else (try ctx.instruction(start)).command;
    if (start_command != anchor)
        return null;
    const next = start + 1;
    if (next >= ctx.function.instruction_count)
        return null;
    if ((try ctx.instruction(next)).command != second)
        return null;
    return start;
}

pub fn matchInstructionCluster(ctx: anytype, instruction_id: u32) Error!?Cluster {
    // One command load decides which sequences can own this instruction.
    // A command outside every sequence still consults the plain-length and table-allocation indexes.
    const command = (try ctx.instruction(instruction_id)).command;

    const truthy_distance: ?u32 = switch (command) {
        .load_tvalue => 0,
        .select_if_truthy => 1,
        .store_tvalue => 2,
        else => null,
    };
    if (truthy_distance) |distance| {
        if (try sequenceStart(ctx, instruction_id, distance, command, .load_tvalue, .select_if_truthy)) |start| {
            if (try ctx.constantTruthyFallbackPatternAt(start)) |pattern| {
                if (instruction_id <= pattern.finish)
                    return hit(.constant_truthy, pattern.start, pattern.start, pattern.finish);
            }
        }
    }

    const const_get_distance: ?u32 = switch (command) {
        .load_tag => 0,
        .check_tag => 1,
        .load_pointer => 2,
        abi.ir_cmd_check_array_size => 3,
        abi.ir_cmd_check_no_metatable => 4,
        abi.ir_cmd_get_arr_addr => 5,
        .load_tvalue => 6,
        .store_tvalue => 7,
        else => null,
    };
    if (const_get_distance) |distance| {
        if (try sequenceStart(ctx, instruction_id, distance, command, .load_tag, .check_tag)) |start| {
            if (try ctx.inlineConstantTableGetPatternAt(start)) |pattern| {
                if (instruction_id <= pattern.finish)
                    return hit(.inline_const_table_get, pattern.pattern.start, pattern.pattern.start, pattern.finish);
            }
        }
    }

    const array_get_distance: ?u32 = switch (command) {
        abi.ir_cmd_get_arr_addr => 0,
        .load_tvalue => 1,
        .store_tvalue => 2,
        else => null,
    };
    if (array_get_distance) |distance| {
        if (try sequenceStart(ctx, instruction_id, distance, command, abi.ir_cmd_get_arr_addr, .load_tvalue)) |start| {
            if (try ctx.inlineArrayGetPatternAt(start)) |pattern| {
                if (instruction_id <= pattern.finish)
                    return hit(.inline_array_get, pattern.start, pattern.start, pattern.finish);
            }
        }
    }

    if (command == .load_tvalue) {
        if (try sequenceStart(ctx, instruction_id, 0, command, .load_tvalue, .store_tvalue)) |start| {
            if (try ctx.semanticTableReloadPatternAt(start)) |pattern|
                return hit(.semantic_table_reload, pattern.start, pattern.start, pattern.finish);
        }
    } else if (command == .store_tvalue) {
        if (try sequenceStart(ctx, instruction_id, 1, command, .load_tvalue, .store_tvalue)) |start| {
            if (try ctx.semanticTableReloadPatternAt(start)) |pattern| {
                if (pattern.finish == instruction_id)
                    return hit(.semantic_table_reload, pattern.start, pattern.start, pattern.finish);
            }
        }
    }

    const generic_distances: []const u32 = switch (command) {
        .load_tag => &.{0},
        .check_tag => &.{1},
        .nop => &.{ 2, 3, 5, 12 },
        .load_pointer => &.{4},
        abi.ir_cmd_try_num_to_index => &.{6},
        .sub_int => &.{7},
        abi.ir_cmd_check_array_size => &.{8},
        abi.ir_cmd_check_no_metatable => &.{9},
        abi.ir_cmd_check_readonly => &.{10},
        abi.ir_cmd_get_arr_addr => &.{11},
        .store_split_tvalue => &.{13},
        abi.ir_cmd_barrier_table_forward => &.{14},
        else => &.{},
    };
    for (generic_distances) |distance| {
        const start = (try sequenceStart(ctx, instruction_id, distance, command, .load_tag, .check_tag)) orelse continue;
        if (try ctx.inlineGenericTableSetPatternAt(start)) |pattern| {
            if (instruction_id <= pattern.finish)
                return hit(.inline_generic_table_set, pattern.pattern.start, pattern.pattern.start, pattern.finish);
        }
    }

    if (command == .check_gc) {
        if (try sequenceStart(ctx, instruction_id, 0, command, .check_gc, abi.ir_cmd_new_userdata)) |start| {
            if (try ctx.userdataAllocationPatternAt(start)) |pattern| {
                if (instruction_id <= pattern.finish)
                    return hit(.userdata_alloc, pattern.start, pattern.start, pattern.finish);
            }
        }
    }

    const literal_distances: []const u32 = switch (command) {
        abi.ir_cmd_get_slot_node_addr => &.{0},
        abi.ir_cmd_check_slot_match => &.{1},
        abi.ir_cmd_check_readonly => &.{2},
        .nop => &.{ 2, 3, 4, 5, 6 },
        .load_tvalue => &.{ 3, 4 },
        .store_tvalue, .store_split_tvalue => &.{ 3, 4, 5 },
        abi.ir_cmd_barrier_table_forward => &.{ 4, 5, 6 },
        else => &.{},
    };
    for (literal_distances) |distance| {
        const start = (try sequenceStart(ctx, instruction_id, distance, command, abi.ir_cmd_get_slot_node_addr, abi.ir_cmd_check_slot_match)) orelse continue;
        if (try ctx.literalFieldSetPatternAt(start)) |pattern| {
            if (instruction_id <= pattern.finish)
                return hit(.literal_field_set, pattern.start, pattern.start, pattern.finish);
        }
    }

    if (command == .load_tvalue) {
        if (try sequenceStart(ctx, instruction_id, 0, command, .load_tvalue, .store_tvalue)) |start| {
            if (try ctx.constantLoadPatternAt(start)) |pattern|
                return hit(.constant_load, pattern.start, pattern.start, pattern.finish);
        }
    } else if (command == .store_tvalue) {
        if (try sequenceStart(ctx, instruction_id, 1, command, .load_tvalue, .store_tvalue)) |start| {
            if (try ctx.constantLoadPatternAt(start)) |pattern| {
                if (pattern.finish == instruction_id)
                    return hit(.constant_load, pattern.start, pattern.start, pattern.finish);
            }
        }
    }

    const dup_distances: []const u32 = switch (command) {
        .load_pointer => &.{0},
        abi.ir_cmd_dup_table => &.{1},
        .store_pointer => &.{2},
        .store_tag => &.{3},
        .check_gc, .nop => &.{ 3, 4 },
        else => &.{},
    };
    for (dup_distances) |distance| {
        if (distance > instruction_id)
            continue;
        if (try ctx.dupTablePatternAt(instruction_id - distance)) |pattern| {
            if (instruction_id <= pattern.finish)
                return hit(.dup_table, pattern.start, pattern.start, pattern.finish);
        }
    }

    if (command == abi.ir_cmd_check_readonly) {
        if (try sequenceStart(ctx, instruction_id, 0, command, abi.ir_cmd_check_readonly, abi.ir_cmd_table_len)) |_| {
            if (try ctx.tableInsertAppendPatternAt(instruction_id + 1)) |pattern| {
                if (pattern.start == instruction_id)
                    return hit(.table_insert_append, pattern.start, instruction_id + 1, pattern.finish);
            }
        }
    }
    const insert_distances: []const u32 = switch (command) {
        abi.ir_cmd_table_len => &.{0},
        .add_int => &.{1},
        abi.ir_cmd_table_setnum => &.{2},
        .load_tvalue, .store_double => &.{3},
        .store_tvalue, .store_tag => &.{4},
        .nop, abi.ir_cmd_barrier_table_forward => &.{ 3, 4, 5 },
        .store_split_tvalue => &.{ 3, 4, 5, 6 },
        else => &.{},
    };
    for (insert_distances) |distance| {
        const candidate = (try sequenceStart(ctx, instruction_id, distance, command, abi.ir_cmd_table_len, .add_int)) orelse continue;
        if (try ctx.tableInsertAppendPatternAt(candidate)) |pattern| {
            if (instruction_id <= pattern.finish)
                return hit(.table_insert_append, pattern.start, candidate, pattern.finish);
        }
    }

    if (ctx.plan.plainLenContaining(instruction_id)) |pattern|
        return hit(.plain_len, pattern.table_len_id, pattern.table_len_id, pattern.finish);

    const concat_distance: ?u32 = switch (command) {
        .set_savedpc => 0,
        abi.ir_cmd_concat => 1,
        .load_tvalue => 2,
        .store_tvalue => 3,
        .check_gc => 4,
        else => null,
    };
    if (concat_distance) |distance| {
        if (try sequenceStart(ctx, instruction_id, distance, command, .set_savedpc, abi.ir_cmd_concat)) |start| {
            if (try ctx.concatPatternAt(start)) |pattern| {
                if (instruction_id <= pattern.finish)
                    return hit(.concat, pattern.start, pattern.start, pattern.finish);
            }
        }
    }

    {
        var back: u32 = 0;
        while (back <= 3 and back <= instruction_id) : (back += 1) {
            if (try ctx.tableAllocationPatternAt(instruction_id - back)) |pattern| {
                if (instruction_id <= pattern.finish)
                    return hit(.table_alloc, pattern.start, pattern.start, pattern.finish);
            }
        }
    }

    const integer_distance: ?u32 = switch (command) {
        .check_cmp_num => 0,
        .store_int64 => 1,
        .store_tag => 2,
        else => null,
    };
    if (integer_distance) |distance| {
        if (try sequenceStart(ctx, instruction_id, distance, command, .check_cmp_num, .store_int64)) |start| {
            if (try ctx.integerCreatePatternAt(start)) |pattern| {
                if (instruction_id <= pattern.finish)
                    return hit(
                        .integer_create,
                        if (pattern.check >= 5) pattern.check - 5 else pattern.check,
                        pattern.check,
                        pattern.finish,
                    );
            }
        }
    }

    if (command == abi.ir_cmd_invoke_libm) {
        if (ctx.plan.instructionBlock(instruction_id)) |block_id| {
            if (@hasField(@TypeOf(ctx), "snapshot")) {
                const block = try ctx.snapshot.irBlock(ctx.function, block_id);
                if (try ctx.linearizedPowPattern(instruction_id, block)) |pattern|
                    return hit(.linearized_pow, instruction_id, instruction_id, pattern.finish);
            }
        }
    }

    const type_distance: ?u32 = switch (command) {
        abi.ir_cmd_get_type, abi.ir_cmd_get_typeof => 0,
        .store_pointer => 1,
        .store_tag => 2,
        .mark_dead => 3,
        else => null,
    };
    if (type_distance) |distance| {
        if (distance <= instruction_id) {
            const start = instruction_id - distance;
            const start_command = if (distance == 0) command else (try ctx.instruction(start)).command;
            if ((start_command == abi.ir_cmd_get_type or start_command == abi.ir_cmd_get_typeof) and
                try sequenceStart(ctx, instruction_id, distance, command, start_command, .store_pointer) != null)
            {
                if (try ctx.typeNamePattern(start, start_command == abi.ir_cmd_get_typeof)) |pattern| {
                    if (instruction_id <= pattern.finish)
                        return hit(.type_name, start, start, pattern.finish);
                }
            }
        }
    }
    return null;
}

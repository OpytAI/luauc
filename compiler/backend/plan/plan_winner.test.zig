const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const plan_mod = @import("luauc_backend_plan");
const abi = @import("luauc_backend_runtime_abi");

const Range = struct {
    start: u32,
    finish: u32,
};

const Nested = struct {
    pattern: Range,
    finish: u32,
};

const Mock = struct {
    function: struct { instruction_count: u32 },
    commands: []const snapshot_v1.IrCommand,
    truthy: ?Range = null,
    const_get: ?Nested = null,
    array_get: ?Range = null,
    reload: ?Range = null,
    generic_set: ?Nested = null,
    userdata: ?Range = null,
    literal_set: ?Range = null,
    constant_load: ?Range = null,
    dup_table: ?Range = null,
    insert_append: ?Range = null,
    concat: ?Range = null,
    table_alloc: ?Range = null,
    plain_len: ?Range = null,
    plan: struct {
        owner: ?*const Mock = null,
        pub fn plainLenContaining(self: @This(), id: u32) ?struct { table_len_id: u32, finish: u32 } {
            const owner = self.owner orelse return null;
            const pattern = owner.plain_len orelse return null;
            return if (id >= pattern.start and id <= pattern.finish)
                .{ .table_len_id = pattern.start, .finish = pattern.finish }
            else
                null;
        }
        pub fn instructionBlock(_: @This(), _: u32) ?u32 {
            return null;
        }
    } = .{},

    pub fn instruction(self: Mock, id: u32) error{}!struct { command: snapshot_v1.IrCommand } {
        return .{ .command = self.commands[id] };
    }

    pub fn constantTruthyFallbackPatternAt(self: Mock, start: u32) error{}!?Range {
        return matchRange(self.truthy, start);
    }
    pub fn inlineConstantTableGetPatternAt(self: Mock, start: u32) error{}!?Nested {
        const pattern = self.const_get orelse return null;
        return if (start == pattern.pattern.start) pattern else null;
    }
    pub fn inlineArrayGetPatternAt(self: Mock, start: u32) error{}!?Range {
        return matchRange(self.array_get, start);
    }
    pub fn semanticTableReloadPatternAt(self: Mock, start: u32) error{}!?Range {
        return matchRange(self.reload, start);
    }
    pub fn inlineGenericTableSetPatternAt(self: Mock, start: u32) error{}!?Nested {
        const pattern = self.generic_set orelse return null;
        return if (start == pattern.pattern.start) pattern else null;
    }
    pub fn userdataAllocationPatternAt(self: Mock, start: u32) error{}!?Range {
        return matchRange(self.userdata, start);
    }
    pub fn literalFieldSetPatternAt(self: Mock, start: u32) error{}!?Range {
        return matchRange(self.literal_set, start);
    }
    pub fn constantLoadPatternAt(self: Mock, start: u32) error{}!?Range {
        return matchRange(self.constant_load, start);
    }
    pub fn dupTablePatternAt(self: Mock, start: u32) error{}!?Range {
        return matchRange(self.dup_table, start);
    }
    pub fn tableInsertAppendPatternAt(self: Mock, start: u32) error{}!?Range {
        const pattern = self.insert_append orelse return null;
        const table_len = if (self.commands[pattern.start] == abi.ir_cmd_check_readonly)
            pattern.start + 1
        else
            pattern.start;
        return if (start == table_len) pattern else null;
    }
    pub fn concatPatternAt(self: Mock, start: u32) error{}!?Range {
        return matchRange(self.concat, start);
    }
    pub fn tableAllocationPatternAt(self: Mock, start: u32) error{}!?Range {
        return matchRange(self.table_alloc, start);
    }
    pub fn integerCreatePatternAt(_: Mock, _: u32) error{}!?struct { check: u32, finish: u32 } {
        return null;
    }
    pub fn linearizedPowPattern(_: Mock, _: u32, _: anytype) error{}!?struct { finish: u32 } {
        return null;
    }
    pub fn typeNamePattern(_: Mock, _: u32, _: bool) error{}!?struct { finish: u32 } {
        return null;
    }
};

fn matchRange(pattern: ?Range, start: u32) ?Range {
    const value = pattern orelse return null;
    return if (start == value.start) value else null;
}

fn nopCommands(comptime n: usize) [n]snapshot_v1.IrCommand {
    return [_]snapshot_v1.IrCommand{.nop} ** n;
}

test "overlapping clusters prefer constant_truthy over table_alloc" {
    var commands = nopCommands(6);
    const ctx = Mock{
        .function = .{ .instruction_count = commands.len },
        .commands = &commands,
        .truthy = .{ .start = 2, .finish = 4 },
        .table_alloc = .{ .start = 2, .finish = 5 },
    };
    const winner = (try plan_mod.matchInstructionCluster(ctx, 3)).?;
    try std.testing.expectEqual(plan_mod.FunctionPlan.ClusterKind.constant_truthy, winner.kind);
    try std.testing.expectEqual(@as(u32, 2), winner.at);
}

test "later family wins when the higher-priority range does not cover the id" {
    var commands = nopCommands(6);
    const ctx = Mock{
        .function = .{ .instruction_count = commands.len },
        .commands = &commands,
        .truthy = .{ .start = 0, .finish = 1 },
        .table_alloc = .{ .start = 2, .finish = 5 },
    };
    const winner = (try plan_mod.matchInstructionCluster(ctx, 4)).?;
    try std.testing.expectEqual(plan_mod.FunctionPlan.ClusterKind.table_alloc, winner.kind);
    try std.testing.expectEqual(@as(u32, 2), winner.at);
}

test "each cluster priority wins when earlier families miss" {
    const kinds = [_]plan_mod.FunctionPlan.ClusterKind{
        .constant_truthy,
        .inline_const_table_get,
        .inline_array_get,
        .semantic_table_reload,
        .inline_generic_table_set,
        .userdata_alloc,
        .literal_field_set,
        .constant_load,
        .dup_table,
        .table_insert_append,
        .plain_len,
        .concat,
        .table_alloc,
    };
    try std.testing.expectEqual(@as(usize, 13), kinds.len);
    const start_commands = [_]snapshot_v1.IrCommand{
        .nop,
        .load_tag,
        .nop,
        .nop,
        .load_tag,
        .check_gc,
        abi.ir_cmd_get_slot_node_addr,
        .nop,
        .nop,
        abi.ir_cmd_check_readonly,
        abi.ir_cmd_table_len,
        .nop,
        .nop,
    };
    const covered = Range{ .start = 0, .finish = 3 };
    const nested = Nested{ .pattern = covered, .finish = 3 };
    var priority: usize = 0;
    while (priority < kinds.len) : (priority += 1) {
        var commands = nopCommands(4);
        commands[0] = start_commands[priority];
        commands[1] = abi.ir_cmd_table_len;
        var ctx = Mock{
            .function = .{ .instruction_count = commands.len },
            .commands = &commands,
            .truthy = if (priority <= 0) covered else null,
            .const_get = if (priority <= 1) nested else null,
            .array_get = if (priority <= 2) covered else null,
            .reload = if (priority <= 3) covered else null,
            .generic_set = if (priority <= 4) nested else null,
            .userdata = if (priority <= 5) covered else null,
            .literal_set = if (priority <= 6) covered else null,
            .constant_load = if (priority <= 7) covered else null,
            .dup_table = if (priority <= 8) covered else null,
            .insert_append = if (priority <= 9) covered else null,
            .plain_len = if (priority <= 10) covered else null,
            .concat = if (priority <= 11) covered else null,
            .table_alloc = if (priority <= 12) covered else null,
        };
        ctx.plan.owner = &ctx;
        const winner = (try plan_mod.matchInstructionCluster(ctx, 0)).?;
        try std.testing.expectEqual(kinds[priority], winner.kind);
    }
}

test "table insert-append records the TABLE_LEN decoder cursor" {
    var commands = nopCommands(6);
    commands[0] = abi.ir_cmd_check_readonly;
    commands[1] = abi.ir_cmd_table_len;
    const ctx = Mock{
        .function = .{ .instruction_count = commands.len },
        .commands = &commands,
        .insert_append = .{ .start = 0, .finish = 5 },
    };
    const winner = (try plan_mod.matchInstructionCluster(ctx, 0)).?;
    try std.testing.expectEqual(plan_mod.FunctionPlan.ClusterKind.table_insert_append, winner.kind);
    try std.testing.expectEqual(@as(u32, 0), winner.start);
    try std.testing.expectEqual(@as(u32, 1), winner.at);
    const interior = (try plan_mod.matchInstructionCluster(ctx, 5)).?;
    try std.testing.expectEqual(@as(u32, 1), interior.at);
}

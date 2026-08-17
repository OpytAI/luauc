const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");

const Error = model.Error;
const TableAllocationPattern = model.TableAllocationPattern;
const DupTablePattern = model.DupTablePattern;
const ir_cmd_new_table = abi.ir_cmd_new_table;
const ir_cmd_dup_table = abi.ir_cmd_dup_table;
const ir_cmd_table_len = abi.ir_cmd_table_len;
const ir_cmd_check_no_metatable = abi.ir_cmd_check_no_metatable;
const ir_cmd_setlist = abi.ir_cmd_setlist;
const ir_cmd_get_slot_node_addr = abi.ir_cmd_get_slot_node_addr;
const ir_cmd_check_slot_match = abi.ir_cmd_check_slot_match;
const ir_cmd_check_readonly = abi.ir_cmd_check_readonly;
const ir_cmd_barrier_table_forward = abi.ir_cmd_barrier_table_forward;
const lua_tag_table = abi.lua_tag_table;

pub const PlanSlices = struct {
    table_pointer_provenance: []const bool,
    instruction_blocks: []const u32,
    transient_address_invalidator_prefix: []const u32,
};

pub const TableAlloc = struct {
    start: u32,
    finish: u32,
    dest_reg: u32,
    array_count: u32,
    node_count: u32,
    deferred_to_later_gc: bool,
    check_gc_id: ?u32,
};

pub const SetList = struct {
    instruction_id: u32,
    table_reg: u32,
    source_start: u32,
    count: u32,
    start_index: u32,
    known_size: ?u32,
};

pub const PlainLen = struct {
    table_len_id: u32,
    finish: u32,
    dest_reg: u32,
    table_reg: u32,
    pointer_id: u32,
};

pub const Closure = struct {
    newclosure_id: u32,
    start: u32,
    finish: u32,
};

pub const DupClosure = struct {
    id: u32,
    marker_start: u32,
    finish: u32,
};

pub const Facts = struct {
    allocator: std.mem.Allocator,
    plain_lens: []PlainLen,
    plain_len_index: []u32,
    closures: []Closure,
    dupclosures: []DupClosure,
    closure_index: []u32,
    dup_capture_index: []u32,
    table_allocs: []TableAlloc,
    dup_tables: []DupTablePattern,
    setlists: []SetList,

    pub fn deinit(self: *Facts) void {
        self.allocator.free(self.plain_lens);
        self.allocator.free(self.plain_len_index);
        self.allocator.free(self.closures);
        self.allocator.free(self.dupclosures);
        self.allocator.free(self.closure_index);
        self.allocator.free(self.dup_capture_index);
        self.allocator.free(self.table_allocs);
        self.allocator.free(self.dup_tables);
        self.allocator.free(self.setlists);
        self.* = undefined;
    }

    pub fn plainLenAt(self: Facts, instruction_id: u32) ?PlainLen {
        const fact = self.plainLenContaining(instruction_id) orelse return null;
        return if (fact.table_len_id == instruction_id) fact else null;
    }

    pub fn plainLenContaining(self: Facts, instruction_id: u32) ?PlainLen {
        if (instruction_id >= self.plain_len_index.len)
            return null;
        const index = self.plain_len_index[instruction_id];
        if (index == snapshot_v1.no_id)
            return null;
        return self.plain_lens[index];
    }

    pub fn closureContaining(self: Facts, instruction_id: u32) ?Closure {
        if (instruction_id >= self.closure_index.len)
            return null;
        const index = self.closure_index[instruction_id];
        if (index == snapshot_v1.no_id)
            return null;
        return self.closures[index];
    }

    pub fn dupClosureCaptureContaining(self: Facts, instruction_id: u32) bool {
        return instruction_id < self.dup_capture_index.len and
            self.dup_capture_index[instruction_id] != snapshot_v1.no_id;
    }

};

pub fn recognize(
    allocator: std.mem.Allocator,
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    proto: snapshot_v1.Proto,
    slices: PlanSlices,
) Error!Facts {
    var plain_lens: std.ArrayList(PlainLen) = .empty;
    defer plain_lens.deinit(allocator);
    var closures: std.ArrayList(Closure) = .empty;
    defer closures.deinit(allocator);
    var dupclosures: std.ArrayList(DupClosure) = .empty;
    defer dupclosures.deinit(allocator);
    var table_allocs: std.ArrayList(TableAlloc) = .empty;
    defer table_allocs.deinit(allocator);
    var dup_tables: std.ArrayList(DupTablePattern) = .empty;
    defer dup_tables.deinit(allocator);
    var setlists: std.ArrayList(SetList) = .empty;
    defer setlists.deinit(allocator);

    var instruction_id: u32 = 0;
    while (instruction_id < function.instruction_count) : (instruction_id += 1) {
        if (try tableAllocationAt(snapshot, function, proto, slices.instruction_blocks, instruction_id)) |pattern| {
            var alloc = TableAlloc{
                .start = pattern.start,
                .finish = pattern.finish,
                .dest_reg = pattern.destination,
                .array_count = pattern.array_count,
                .node_count = pattern.node_count,
                .deferred_to_later_gc = pattern.deferred_to_later_gc,
                .check_gc_id = null,
            };
            try attachDeferredGc(snapshot, function, slices.instruction_blocks, &alloc);
            try table_allocs.append(allocator, alloc);
            instruction_id = pattern.finish;
            continue;
        }

        const instruction = try snapshot.irInstruction(function, instruction_id);
        if (instruction.command == ir_cmd_new_table) {
            if (instruction.operand_count != 2)
                return Error.UnsupportedControlFlow;
            const array_count = try uintOperand(snapshot, function, try snapshot.irOperand(instruction, 0));
            const node_count = try uintOperand(snapshot, function, try snapshot.irOperand(instruction, 1));
            var alloc = TableAlloc{
                .start = instruction_id,
                .finish = instruction_id,
                .dest_reg = snapshot_v1.no_id,
                .array_count = array_count,
                .node_count = node_count,
                .deferred_to_later_gc = true,
                .check_gc_id = null,
            };
            try attachDeferredGc(snapshot, function, slices.instruction_blocks, &alloc);
            try table_allocs.append(allocator, alloc);
            continue;
        }

        if (try dupTableAt(snapshot, function, proto, slices.instruction_blocks, instruction_id)) |pattern| {
            try dup_tables.append(allocator, pattern);
            instruction_id = pattern.finish;
            continue;
        }

        if (instruction.command == ir_cmd_setlist)
            if (try setListAt(snapshot, function, proto, slices.instruction_blocks, instruction_id, instruction)) |decoded|
                try setlists.append(allocator, decoded);

        if (instruction.command == ir_cmd_table_len)
            if (try plainLenAt(snapshot, function, proto, slices, instruction_id, instruction)) |decoded|
                try plain_lens.append(allocator, decoded);

        if (instruction.command == .newclosure)
            if (try newClosureRangeAt(snapshot, function, proto, slices.instruction_blocks, instruction_id)) |decoded|
                try closures.append(allocator, decoded);

        if (instruction.command == .fallback_dupclosure) {
            const pattern = model.dupClosurePattern(snapshot, function, proto, instruction_id) catch |err| switch (err) {
                Error.UnsupportedControlFlow, Error.InvalidOperandCount, Error.InvalidOperandType => null,
                else => return err,
            };
            if (pattern) |decoded| {
                switch (decoded) {
                    .closed => try dupclosures.append(allocator, .{
                        .id = instruction_id,
                        .marker_start = instruction_id,
                        .finish = instruction_id,
                    }),
                    .captured => |captured| try dupclosures.append(allocator, .{
                        .id = instruction_id,
                        .marker_start = captured.marker_start,
                        .finish = captured.marker_start + captured.capture_count - 1,
                    }),
                }
            }
        }
    }

    const plain_len_slice = try plain_lens.toOwnedSlice(allocator);
    errdefer allocator.free(plain_len_slice);
    const closure_slice = try closures.toOwnedSlice(allocator);
    errdefer allocator.free(closure_slice);
    const dupclosure_slice = try dupclosures.toOwnedSlice(allocator);
    errdefer allocator.free(dupclosure_slice);
    const table_alloc_slice = try table_allocs.toOwnedSlice(allocator);
    errdefer allocator.free(table_alloc_slice);
    const dup_table_slice = try dup_tables.toOwnedSlice(allocator);
    errdefer allocator.free(dup_table_slice);
    const setlist_slice = try setlists.toOwnedSlice(allocator);
    errdefer allocator.free(setlist_slice);

    const plain_len_index = try allocator.alloc(u32, function.instruction_count);
    errdefer allocator.free(plain_len_index);
    @memset(plain_len_index, snapshot_v1.no_id);
    for (plain_len_slice, 0..) |fact, index| {
        var cursor = fact.table_len_id;
        while (cursor <= fact.finish) : (cursor += 1)
            plain_len_index[cursor] = @intCast(index);
    }

    const closure_index = try allocator.alloc(u32, function.instruction_count);
    errdefer allocator.free(closure_index);
    @memset(closure_index, snapshot_v1.no_id);
    for (closure_slice, 0..) |fact, index| {
        var cursor = fact.start;
        while (cursor <= fact.finish) : (cursor += 1)
            closure_index[cursor] = @intCast(index);
    }

    const dup_capture_index = try allocator.alloc(u32, function.instruction_count);
    errdefer allocator.free(dup_capture_index);
    @memset(dup_capture_index, snapshot_v1.no_id);
    for (dupclosure_slice, 0..) |fact, index| {
        var cursor = fact.marker_start;
        while (cursor <= fact.finish) : (cursor += 1)
            dup_capture_index[cursor] = @intCast(index);
    }

    return .{
        .allocator = allocator,
        .plain_lens = plain_len_slice,
        .plain_len_index = plain_len_index,
        .closures = closure_slice,
        .dupclosures = dupclosure_slice,
        .closure_index = closure_index,
        .dup_capture_index = dup_capture_index,
        .table_allocs = table_alloc_slice,
        .dup_tables = dup_table_slice,
        .setlists = setlist_slice,
    };
}

fn newClosureRangeAt(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    proto: snapshot_v1.Proto,
    instruction_blocks: []const u32,
    newclosure_id: u32,
) Error!?Closure {
    if (newclosure_id < 2 or newclosure_id + 2 >= function.instruction_count)
        return null;
    const marker = try snapshot.irInstruction(function, newclosure_id - 2);
    const load_env = try snapshot.irInstruction(function, newclosure_id - 1);
    const newclosure = try snapshot.irInstruction(function, newclosure_id);
    const store_pointer = try snapshot.irInstruction(function, newclosure_id + 1);
    const store_tag = try snapshot.irInstruction(function, newclosure_id + 2);
    if (marker.command != .set_savedpc or load_env.command != .load_env or
        newclosure.command != .newclosure or store_pointer.command != .store_pointer or
        store_tag.command != .store_tag)
        return null;
    if (newclosure.operand_count != 3)
        return null;
    const nups_operand = try snapshot.irOperand(newclosure, 0);
    if (nups_operand.kind != .constant)
        return null;
    const capture_count = (try snapshot.irConstant(function, nups_operand.value)).uintValue() orelse
        return null;
    _ = proto;
    var finish = newclosure_id + 2;
    var cursor = newclosure_id + 3;
    if (capture_count == 0) {
        if (cursor < function.instruction_count) {
            const gc_marker = try snapshot.irInstruction(function, cursor);
            if ((gc_marker.command == .check_gc or gc_marker.command == .nop) and gc_marker.operand_count == 0)
                finish = cursor;
        }
        requireSingleCompilableBlockRange(snapshot, function, instruction_blocks, newclosure_id - 2, finish) catch return null;
        return .{ .newclosure_id = newclosure_id, .start = newclosure_id - 2, .finish = finish };
    }
    var remaining = capture_count;
    while (remaining != 0 and cursor < function.instruction_count) {
        cursor = (try skipInitializedCapture(snapshot, function, cursor)) orelse return null;
        remaining -= 1;
    }
    if (remaining != 0)
        return null;
    if (cursor < function.instruction_count) {
        const gc_marker = try snapshot.irInstruction(function, cursor);
        if ((gc_marker.command == .check_gc or gc_marker.command == .nop) and gc_marker.operand_count == 0)
            cursor += 1;
    }
    var marker_index: u32 = 0;
    while (marker_index < capture_count) : (marker_index += 1) {
        if (cursor >= function.instruction_count)
            return null;
        const marker_insn = try snapshot.irInstruction(function, cursor);
        if (marker_insn.command != .capture)
            return null;
        cursor += 1;
    }
    if (cursor == 0)
        return null;
    finish = cursor - 1;
    requireSingleCompilableBlockRange(snapshot, function, instruction_blocks, newclosure_id - 2, finish) catch return null;
    return .{ .newclosure_id = newclosure_id, .start = newclosure_id - 2, .finish = finish };
}

fn skipInitializedCapture(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    start: u32,
) Error!?u32 {
    if (start >= function.instruction_count)
        return null;
    var cursor = start;
    var first = try snapshot.irInstruction(function, cursor);
    while (first.command == .nop) {
        if (cursor + 1 >= function.instruction_count)
            return null;
        cursor += 1;
        first = try snapshot.irInstruction(function, cursor);
    }
    if (first.command == .load_tvalue) {
        if (cursor + 2 >= function.instruction_count)
            return null;
        const address = try snapshot.irInstruction(function, cursor + 1);
        const store = try snapshot.irInstruction(function, cursor + 2);
        if (address.command != .get_closure_upval_addr or store.command != .store_tvalue)
            return null;
        return cursor + 3;
    }
    if (first.command == .findupval) {
        if (cursor + 3 >= function.instruction_count)
            return null;
        const address = try snapshot.irInstruction(function, cursor + 1);
        const pointer_store = try snapshot.irInstruction(function, cursor + 2);
        const tag_store = try snapshot.irInstruction(function, cursor + 3);
        if (address.command != .get_closure_upval_addr or pointer_store.command != .store_pointer or
            tag_store.command != .store_tag)
            return null;
        return cursor + 4;
    }
    if (first.command != .get_closure_upval_addr)
        return null;
    const closure = try snapshot.irOperand(first, 0);
    if (closure.kind == .instruction) {
        if (cursor + 1 >= function.instruction_count)
            return null;
        const store = try snapshot.irInstruction(function, cursor + 1);
        if (store.command != .store_tvalue and store.command != .store_pointer and
            store.command != .store_split_tvalue)
            return null;
        return cursor + 2;
    }
    if (cursor + 3 >= function.instruction_count)
        return null;
    const address = try snapshot.irInstruction(function, cursor + 1);
    const load = try snapshot.irInstruction(function, cursor + 2);
    const store = try snapshot.irInstruction(function, cursor + 3);
    if (address.command != .get_closure_upval_addr or load.command != .load_tvalue or
        store.command != .store_tvalue)
        return null;
    return cursor + 4;
}

pub fn tableAllocationAt(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    proto: snapshot_v1.Proto,
    instruction_blocks: []const u32,
    start: u32,
) Error!?TableAllocationPattern {
    if (function.instruction_count < 3 or start > function.instruction_count - 3)
        return null;
    const allocation = try snapshot.irInstruction(function, start);
    const store_pointer = try snapshot.irInstruction(function, start + 1);
    const store_tag = try snapshot.irInstruction(function, start + 2);
    if (allocation.command != ir_cmd_new_table or allocation.operand_count != 2 or
        store_pointer.command != .store_pointer or store_pointer.operand_count != 2 or
        store_tag.command != .store_tag or store_tag.operand_count != 2)
        return null;
    var finish = start + 2;
    var assist = false;
    if (start + 3 < function.instruction_count) {
        const possible_check = try snapshot.irInstruction(function, start + 3);
        if (possible_check.command == .check_gc and possible_check.operand_count == 0) {
            finish = start + 3;
            assist = true;
        } else if (possible_check.command == .nop and possible_check.operand_count == 0) {
            finish = start + 3;
        }
    }
    requireSingleCompilableBlockRange(snapshot, function, instruction_blocks, start, finish) catch return null;
    const destination = try snapshot.irOperand(store_pointer, 0);
    const pointer = try snapshot.irOperand(store_pointer, 1);
    const tag_destination = try snapshot.irOperand(store_tag, 0);
    const tag = try snapshot.irOperand(store_tag, 1);
    if (destination.kind != .vm_reg or destination.value >= proto.max_stack_size or
        pointer.kind != .instruction or pointer.value != start or
        tag_destination.kind != .vm_reg or tag_destination.value != destination.value or
        tag.kind != .constant or (try snapshot.irConstant(function, tag.value)).tagValue() != lua_tag_table)
        return null;
    return .{
        .start = start,
        .finish = finish,
        .assist = assist,
        .deferred_to_later_gc = finish == start + 2,
        .destination = destination.value,
        .array_count = try uintOperand(snapshot, function, try snapshot.irOperand(allocation, 0)),
        .node_count = try uintOperand(snapshot, function, try snapshot.irOperand(allocation, 1)),
    };
}

pub fn dupTableAt(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    proto: snapshot_v1.Proto,
    instruction_blocks: []const u32,
    start: u32,
) Error!?DupTablePattern {
    const prefix = [_]snapshot_v1.IrCommand{
        .load_pointer, ir_cmd_dup_table, .store_pointer, .store_tag,
    };
    const prefix_len: u32 = @intCast(prefix.len);
    if (!try commandRangeMatches(snapshot, function, start, &prefix))
        return null;
    var finish = start + prefix_len - 1;
    var assist = false;

    const load = try snapshot.irInstruction(function, start);
    const duplicate = try snapshot.irInstruction(function, start + 1);
    const store_pointer = try snapshot.irInstruction(function, start + 2);
    const store_tag = try snapshot.irInstruction(function, start + 3);
    if (start + prefix_len < function.instruction_count) {
        const possible_gc = try snapshot.irInstruction(function, start + prefix_len);
        if (possible_gc.command == .check_gc or possible_gc.command == .nop) {
            if (possible_gc.operand_count != 0)
                return null;
            finish += 1;
            assist = possible_gc.command == .check_gc;
        }
    }
    requireSingleCompilableBlockRange(snapshot, function, instruction_blocks, start, finish) catch return null;
    if (load.operand_count != 1 or duplicate.operand_count != 1 or
        store_pointer.operand_count != 2 or store_tag.operand_count != 2)
        return null;

    const constant_operand = try snapshot.irOperand(load, 0);
    if (constant_operand.kind != .vm_const or constant_operand.value >= proto.vm_constant_count or
        (try snapshot.vmConstant(proto, constant_operand.value)).kind != .table)
        return null;
    const duplicate_source = try snapshot.irOperand(duplicate, 0);
    const destination = try snapshot.irOperand(store_pointer, 0);
    const stored_pointer = try snapshot.irOperand(store_pointer, 1);
    const tag_destination = try snapshot.irOperand(store_tag, 0);
    const tag = try snapshot.irOperand(store_tag, 1);
    if (duplicate_source.kind != .instruction or duplicate_source.value != start or
        stored_pointer.kind != .instruction or stored_pointer.value != start + 1 or
        destination.kind != .vm_reg or destination.value >= proto.max_stack_size or
        tag_destination.kind != .vm_reg or tag_destination.value != destination.value or
        tag.kind != .constant or (try snapshot.irConstant(function, tag.value)).tagValue() != lua_tag_table)
        return null;
    return .{
        .start = start,
        .finish = finish,
        .assist = assist,
        .destination = destination.value,
        .constant_id = constant_operand.value,
    };
}

pub fn isDeferredTableInitializationCommand(command: snapshot_v1.IrCommand) bool {
    return switch (command) {
        ir_cmd_setlist,
        .store_tvalue,
        .store_split_tvalue,
        .store_tag,
        .store_pointer,
        .store_double,
        .store_vector,
        ir_cmd_get_slot_node_addr,
        ir_cmd_check_slot_match,
        ir_cmd_check_readonly,
        ir_cmd_barrier_table_forward,
        => true,
        else => false,
    };
}

fn setListAt(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    proto: snapshot_v1.Proto,
    instruction_blocks: []const u32,
    instruction_id: u32,
    instruction: snapshot_v1.IrInstruction,
) Error!?SetList {
    if (!inCompilableBlock(snapshot, function, instruction_blocks, instruction_id))
        return null;
    if (instruction.operand_count != 6)
        return Error.InvalidOperandCount;
    _ = try uintOperand(snapshot, function, try snapshot.irOperand(instruction, 0));
    const table = try vmReg(proto, try snapshot.irOperand(instruction, 1));
    const source = try vmReg(proto, try snapshot.irOperand(instruction, 2));
    const count = try intOperand(snapshot, function, try snapshot.irOperand(instruction, 3));
    const start_index = try uintOperand(snapshot, function, try snapshot.irOperand(instruction, 4));
    const known_size_operand = try snapshot.irOperand(instruction, 5);
    if (count <= 0 or start_index == 0 or
        (known_size_operand.kind != .constant and known_size_operand.kind != .undef))
        return Error.UnsupportedControlFlow;
    const known_size: ?u32 = if (known_size_operand.kind == .constant)
        try uintOperand(snapshot, function, known_size_operand)
    else
        null;
    const count_u32: u32 = @intCast(count);
    if (count_u32 > @as(u32, proto.max_stack_size) - source or
        (known_size != null and count_u32 > known_size.? -| (start_index - 1)))
        return Error.UnsupportedControlFlow;
    return .{
        .instruction_id = instruction_id,
        .table_reg = table,
        .source_start = source,
        .count = count_u32,
        .start_index = start_index,
        .known_size = known_size,
    };
}

fn plainLenAt(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    proto: snapshot_v1.Proto,
    slices: PlanSlices,
    table_len_id: u32,
    instruction: snapshot_v1.IrInstruction,
) Error!?PlainLen {
    if (!inCompilableBlock(snapshot, function, slices.instruction_blocks, table_len_id))
        return null;
    if (instruction.operand_count != 1)
        return null;
    const pointer = try snapshot.irOperand(instruction, 0);
    if (pointer.kind != .instruction or pointer.value >= table_len_id)
        return null;
    if (pointer.value >= slices.table_pointer_provenance.len or
        !slices.table_pointer_provenance[pointer.value])
        return null;
    if (!checkNoMetatableDominates(snapshot, function, slices, table_len_id, pointer.value))
        return null;
    const table_reg = (try tableRegForPointer(snapshot, function, proto, slices.instruction_blocks, pointer.value)) orelse return null;
    const store = try storeClusterAfterLen(snapshot, function, proto, slices.instruction_blocks, table_len_id) orelse return null;
    return .{
        .table_len_id = table_len_id,
        .finish = store.finish,
        .dest_reg = store.dest_reg,
        .table_reg = table_reg,
        .pointer_id = pointer.value,
    };
}

fn storeClusterAfterLen(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    proto: snapshot_v1.Proto,
    instruction_blocks: []const u32,
    table_len_id: u32,
) Error!?struct { dest_reg: u32, finish: u32 } {
    if (table_len_id + 2 >= function.instruction_count)
        return null;
    const convert = try snapshot.irInstruction(function, table_len_id + 1);
    const store = try snapshot.irInstruction(function, table_len_id + 2);
    if (convert.command != .int_to_num or convert.operand_count != 1 or
        store.command != .store_double or store.operand_count != 2)
        return null;
    const converted = try snapshot.irOperand(convert, 0);
    const destination = try snapshot.irOperand(store, 0);
    const stored = try snapshot.irOperand(store, 1);
    if (converted.kind != .instruction or converted.value != table_len_id or
        stored.kind != .instruction or stored.value != table_len_id + 1)
        return null;
    const dest_reg = vmReg(proto, destination) catch return null;
    var finish = table_len_id + 2;
    if (table_len_id + 3 < function.instruction_count) {
        const store_tag = try snapshot.irInstruction(function, table_len_id + 3);
        if (store_tag.command == .store_tag and store_tag.operand_count == 2) {
            const tag_destination = try snapshot.irOperand(store_tag, 0);
            if (tag_destination.kind == .vm_reg and tag_destination.value == dest_reg)
                finish = table_len_id + 3;
        }
    }
    requireSingleCompilableBlockRange(snapshot, function, instruction_blocks, table_len_id, finish) catch return null;
    return .{ .dest_reg = dest_reg, .finish = finish };
}

fn tableRegForPointer(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    proto: snapshot_v1.Proto,
    instruction_blocks: []const u32,
    pointer_id: u32,
) Error!?u32 {
    const pointer = try snapshot.irInstruction(function, pointer_id);
    if (pointer.command == .load_pointer and pointer.operand_count == 1) {
        const source = try snapshot.irOperand(pointer, 0);
        if (source.kind != .vm_reg or source.value >= proto.max_stack_size)
            return null;
        return source.value;
    }
    if (pointer.command == ir_cmd_new_table) {
        if (try tableAllocationAt(snapshot, function, proto, instruction_blocks, pointer_id)) |pattern|
            return pattern.destination;
        return null;
    }
    if (pointer.command == ir_cmd_dup_table and pointer_id != 0) {
        if (try dupTableAt(snapshot, function, proto, instruction_blocks, pointer_id - 1)) |pattern| {
            if (pattern.start + 1 == pointer_id)
                return pattern.destination;
        }
    }
    return null;
}

fn checkNoMetatableDominates(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    slices: PlanSlices,
    table_len_id: u32,
    pointer_id: u32,
) bool {
    const block_id = if (table_len_id < slices.instruction_blocks.len)
        slices.instruction_blocks[table_len_id]
    else
        return false;
    if (block_id == snapshot_v1.no_id)
        return false;
    const block = snapshot.irBlock(function, block_id) catch return false;
    if (block.isEmpty() or table_len_id < block.start or table_len_id > block.finish)
        return false;
    var cursor = table_len_id;
    while (cursor > block.start) {
        cursor -= 1;
        const candidate = snapshot.irInstruction(function, cursor) catch return false;
        if (candidate.command != ir_cmd_check_no_metatable or candidate.operand_count != 2)
            continue;
        const checked = snapshot.irOperand(candidate, 0) catch return false;
        if (checked.kind != .instruction or checked.value != pointer_id)
            continue;
        return !hasInvalidator(slices.transient_address_invalidator_prefix, cursor + 1, table_len_id);
    }
    return false;
}

fn attachDeferredGc(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    instruction_blocks: []const u32,
    alloc: *TableAlloc,
) Error!void {
    if (!alloc.deferred_to_later_gc)
        return;
    if (alloc.start >= instruction_blocks.len)
        return;
    const block_id = instruction_blocks[alloc.start];
    if (block_id == snapshot_v1.no_id)
        return;
    const block = try snapshot.irBlock(function, block_id);
    if (block.isEmpty() or alloc.finish > block.finish)
        return;
    var cursor = alloc.finish + 1;
    var saw_initializer = false;
    while (cursor <= block.finish) : (cursor += 1) {
        const command = (try snapshot.irInstruction(function, cursor)).command;
        if (command == .check_gc) {
            alloc.check_gc_id = cursor;
            return;
        }
        if (command == ir_cmd_new_table or command == ir_cmd_dup_table)
            break;
        if (isDeferredTableInitializationCommand(command))
            saw_initializer = true;
    }
    if (!saw_initializer)
        return;
    while (cursor < function.instruction_count) : (cursor += 1) {
        if ((try snapshot.irInstruction(function, cursor)).command == .check_gc)
            return;
    }
    return Error.UnsupportedControlFlow;
}

fn inCompilableBlock(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    instruction_blocks: []const u32,
    instruction_id: u32,
) bool {
    if (instruction_id >= instruction_blocks.len)
        return false;
    const block_id = instruction_blocks[instruction_id];
    if (block_id == snapshot_v1.no_id)
        return false;
    const block = snapshot.irBlock(function, block_id) catch return false;
    return !block.isEmpty() and block.kind.isCompilable();
}

fn requireSingleCompilableBlockRange(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    instruction_blocks: []const u32,
    start: u32,
    finish: u32,
) Error!void {
    if (start > finish or start >= instruction_blocks.len or finish >= instruction_blocks.len)
        return Error.UnsupportedControlFlow;
    const start_block = instruction_blocks[start];
    const finish_block = instruction_blocks[finish];
    if (start_block == snapshot_v1.no_id or start_block != finish_block)
        return Error.UnsupportedControlFlow;
    const block = try snapshot.irBlock(function, start_block);
    if (block.isEmpty() or !block.kind.isCompilable() or block.start > start or block.finish < finish)
        return Error.UnsupportedControlFlow;
}

fn commandRangeMatches(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    start: u32,
    commands: []const snapshot_v1.IrCommand,
) Error!bool {
    if (start > function.instruction_count -| @as(u32, @intCast(commands.len)))
        return false;
    for (commands, 0..) |command, offset| {
        if ((try snapshot.irInstruction(function, start + @as(u32, @intCast(offset)))).command != command)
            return false;
    }
    return true;
}

fn uintOperand(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    operand: snapshot_v1.IrOperand,
) Error!u32 {
    if (operand.kind != .constant)
        return Error.InvalidOperandType;
    return (try snapshot.irConstant(function, operand.value)).uintValue() orelse Error.InvalidOperandType;
}

fn intOperand(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    operand: snapshot_v1.IrOperand,
) Error!i32 {
    if (operand.kind != .constant)
        return Error.InvalidOperandType;
    return (try snapshot.irConstant(function, operand.value)).intValue() orelse Error.InvalidOperandType;
}

fn vmReg(proto: snapshot_v1.Proto, operand: snapshot_v1.IrOperand) Error!u32 {
    if (operand.kind != .vm_reg or operand.value >= proto.max_stack_size)
        return Error.InvalidOperandType;
    return operand.value;
}

fn hasInvalidator(prefix: []const u32, start: u32, finish_exclusive: u32) bool {
    if (start > finish_exclusive or finish_exclusive >= prefix.len)
        return true;
    return prefix[finish_exclusive] != prefix[start];
}

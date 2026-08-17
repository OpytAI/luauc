const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");
const recognize = @import("luauc_backend_recognize");
const recognize_tables = @import("luauc_backend_recognize_tables");
const recognize_calls = @import("luauc_backend_recognize_calls");
const cluster_index_mod = @import("luauc_backend_cluster_index");

const Error = model.Error;
pub const matchInstructionCluster = cluster_index_mod.matchInstructionCluster;

const Edge = struct {
    source: u32,
    target: u32,
};

const DfsFrame = struct {
    block: u32,
    next_edge: u32,
};

const TreeFrame = struct {
    block: u32,
    next_child: u32,
    entered: bool,
};

const ArrayGuard = struct {
    table_kind: snapshot_v1.IrOperandKind,
    table_value: u32,
    index_kind: snapshot_v1.IrOperandKind,
    index_value: u32,
};

const BufferPointer = struct {
    kind: snapshot_v1.IrOperandKind,
    value: u32,
};

const BlockBufferPointer = struct {
    block: u32,
    pointer: BufferPointer,
};

const BufferGuard = struct {
    base_kind: snapshot_v1.IrOperandKind,
    base_value: u32,
    min_offset: i32,
    max_offset: i32,
    failure_block: ?u32,
};

pub const FunctionPlan = struct {
    allocator: std.mem.Allocator,
    instruction_blocks: []u32,
    instruction_use_counts: []u32,
    block_reference_counts: []u32,
    successor_offsets: []u32,
    successors: []u32,
    predecessor_offsets: []u32,
    predecessors: []u32,
    transient_address_invalidator_prefix: []u32,
    table_pointer_provenance: []bool,
    guarded_array_addresses: []bool,
    array_address_guards: []?ArrayGuard,
    guarded_buffer_operations: []bool,
    resume_safe_blocks: []bool,
    facts: recognize.Facts,
    dominators: Dominators,
    cluster_index: []u32,
    clusters: []Cluster,
    continuation_sites: []u32,
    continuation_regions: []ContinuationRegion,
    iteration_regions: []IterationRegion,
    block_index: recognize_tables.BlockIndex,
    pow_sites: []model.PowPattern,
    call_facts: recognize_calls.CallFacts,
    import_needs: model.ImportNeeds,
    lowered_commands: std.StaticBitSet(256),

    pub const ClusterKind = cluster_index_mod.ClusterKind;
    pub const Cluster = cluster_index_mod.Cluster;

    pub const ContinuationRegion = struct {
        block_id: u32,
        suffix_start: u32,
        block_finish: u32,
        admitted: bool,
    };

    pub const IterationRegion = struct {
        repeat_target: u32,
        exit_target: u32,
        admitted: bool,
    };

    pub const RegionDominators = struct {
        allocator: std.mem.Allocator,
        immediate: []u32,
        enter: []u32,
        exit: []u32,

        pub fn deinit(self: *RegionDominators) void {
            self.allocator.free(self.immediate);
            self.allocator.free(self.enter);
            self.allocator.free(self.exit);
            self.* = undefined;
        }

        pub fn dominates(self: RegionDominators, dominator: u32, block: u32) bool {
            if (dominator >= self.enter.len or block >= self.enter.len or
                self.immediate[dominator] == snapshot_v1.no_id or
                self.immediate[block] == snapshot_v1.no_id)
                return false;
            return self.enter[dominator] <= self.enter[block] and
                self.exit[block] <= self.exit[dominator];
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        snapshot: snapshot_v1.Snapshot,
        function: snapshot_v1.IrFunction,
        static_package: bool,
    ) Error!FunctionPlan {
        const block_count: usize = @intCast(function.block_count);
        const instruction_count: usize = @intCast(function.instruction_count);

        const instruction_blocks = try allocator.alloc(u32, instruction_count);
        errdefer allocator.free(instruction_blocks);
        @memset(instruction_blocks, snapshot_v1.no_id);

        const instruction_use_counts = try allocator.alloc(u32, instruction_count);
        errdefer allocator.free(instruction_use_counts);
        @memset(instruction_use_counts, 0);

        const block_reference_counts = try allocator.alloc(u32, block_count);
        errdefer allocator.free(block_reference_counts);
        @memset(block_reference_counts, 0);

        const transient_address_invalidator_prefix = try allocator.alloc(u32, instruction_count + 1);
        errdefer allocator.free(transient_address_invalidator_prefix);
        @memset(transient_address_invalidator_prefix, 0);

        const table_pointer_provenance = try allocator.alloc(bool, instruction_count);
        errdefer allocator.free(table_pointer_provenance);
        @memset(table_pointer_provenance, false);

        const guarded_array_addresses = try allocator.alloc(bool, instruction_count);
        errdefer allocator.free(guarded_array_addresses);
        @memset(guarded_array_addresses, false);

        const array_address_guards = try allocator.alloc(?ArrayGuard, instruction_count);
        errdefer allocator.free(array_address_guards);
        @memset(array_address_guards, null);

        var edges: std.ArrayList(Edge) = .empty;
        defer edges.deinit(allocator);

        var block_id: u32 = 0;
        while (block_id < function.block_count) : (block_id += 1) {
            const block = try snapshot.irBlock(function, block_id);
            if (block.isEmpty())
                continue;
            if (block.start > block.finish or block.finish >= function.instruction_count)
                return Error.UnsupportedControlFlow;

            var instruction_id = block.start;
            while (instruction_id <= block.finish) : (instruction_id += 1) {
                if (instruction_blocks[instruction_id] != snapshot_v1.no_id)
                    return Error.UnsupportedControlFlow;
                instruction_blocks[instruction_id] = block_id;

                const instruction = try snapshot.irInstruction(function, instruction_id);
                var operand_id: u32 = 0;
                while (operand_id < instruction.operand_count) : (operand_id += 1) {
                    const operand = try snapshot.irOperand(instruction, operand_id);
                    switch (operand.kind) {
                        .instruction => {
                            if (operand.value >= function.instruction_count)
                                return Error.UnsupportedControlFlow;
                            instruction_use_counts[operand.value] = std.math.add(
                                u32,
                                instruction_use_counts[operand.value],
                                1,
                            ) catch return Error.ResourceLimit;
                        },
                        .block => {
                            if (operand.value >= function.block_count)
                                return Error.UnsupportedControlFlow;
                            block_reference_counts[operand.value] = std.math.add(
                                u32,
                                block_reference_counts[operand.value],
                                1,
                            ) catch return Error.ResourceLimit;
                            try edges.append(allocator, .{ .source = block_id, .target = operand.value });
                        },
                        else => {},
                    }
                }
            }
        }

        var instruction_id: u32 = 0;
        while (instruction_id < function.instruction_count) : (instruction_id += 1) {
            const instruction = try snapshot.irInstruction(function, instruction_id);
            transient_address_invalidator_prefix[instruction_id + 1] =
                transient_address_invalidator_prefix[instruction_id] +
                @intFromBool(invalidatesTransientAddress(instruction.command));
        }

        const proto = try snapshot.proto(function.proto_id);
        const guarded_table_registers = try allocator.alloc(bool, proto.max_stack_size);
        defer allocator.free(guarded_table_registers);
        const pending_table_registers = try allocator.alloc(bool, proto.max_stack_size);
        defer allocator.free(pending_table_registers);
        var array_guards = std.AutoHashMap(ArrayGuard, void).init(allocator);
        defer array_guards.deinit();

        block_id = 0;
        while (block_id < function.block_count) : (block_id += 1) {
            const block = try snapshot.irBlock(function, block_id);
            if (block.isEmpty())
                continue;
            @memset(guarded_table_registers, false);
            @memset(pending_table_registers, false);
            array_guards.clearRetainingCapacity();
            var last_array_guard: ?ArrayGuard = null;

            instruction_id = block.start;
            while (instruction_id <= block.finish) : (instruction_id += 1) {
                const instruction = try snapshot.irInstruction(function, instruction_id);
                if (invalidatesTransientAddress(instruction.command)) {
                    array_guards.clearRetainingCapacity();
                    last_array_guard = null;
                    @memset(guarded_table_registers, false);
                    @memset(pending_table_registers, false);
                }

                if (try writtenVmRegister(snapshot, instruction)) |destination| {
                    if (destination < guarded_table_registers.len) {
                        guarded_table_registers[destination] = false;
                        if (instruction.command != .store_tag)
                            pending_table_registers[destination] = false;
                    }
                }

                switch (instruction.command) {
                    .check_tag => if (instruction.operand_count == 3) {
                        const checked = try snapshot.irOperand(instruction, 0);
                        const expected = try snapshot.irOperand(instruction, 1);
                        if (checked.kind == .instruction and checked.value < instruction_count and
                            expected.kind == .constant and
                            (try snapshot.irConstant(function, expected.value)).tagValue() == 7)
                        {
                            const load = try snapshot.irInstruction(function, checked.value);
                            if (load.command == .load_tag and load.operand_count == 1) {
                                const source = try snapshot.irOperand(load, 0);
                                if (source.kind == .vm_reg and source.value < guarded_table_registers.len)
                                    guarded_table_registers[source.value] = true;
                            }
                        }
                    },
                    .store_pointer => if (instruction.operand_count == 2) {
                        const destination = try snapshot.irOperand(instruction, 0);
                        const source = try snapshot.irOperand(instruction, 1);
                        if (destination.kind == .vm_reg and destination.value < pending_table_registers.len and
                            source.kind == .instruction and source.value < instruction_count)
                        {
                            const producer = try snapshot.irInstruction(function, source.value);
                            pending_table_registers[destination.value] =
                                producer.command == abi.ir_cmd_new_table or producer.command == abi.ir_cmd_dup_table;
                        }
                    },
                    .store_tag => if (instruction.operand_count == 2) {
                        const destination = try snapshot.irOperand(instruction, 0);
                        const tag = try snapshot.irOperand(instruction, 1);
                        if (destination.kind == .vm_reg and destination.value < guarded_table_registers.len and
                            pending_table_registers[destination.value] and tag.kind == .constant and
                            (try snapshot.irConstant(function, tag.value)).tagValue() == 7)
                            guarded_table_registers[destination.value] = true;
                        if (destination.kind == .vm_reg and destination.value < pending_table_registers.len)
                            pending_table_registers[destination.value] = false;
                    },
                    .load_pointer => if (instruction.operand_count == 1) {
                        const source = try snapshot.irOperand(instruction, 0);
                        if (source.kind == .vm_reg and source.value < guarded_table_registers.len)
                            table_pointer_provenance[instruction_id] = guarded_table_registers[source.value]
                        else if (source.kind == .vm_const and source.value < proto.vm_constant_count)
                            table_pointer_provenance[instruction_id] =
                                (try snapshot.vmConstant(proto, source.value)).kind == .table;
                    },
                    else => switch (@intFromEnum(instruction.command)) {
                        100, 101 => table_pointer_provenance[instruction_id] = true,
                        136 => if (instruction.operand_count == 3) {
                            const table = try snapshot.irOperand(instruction, 0);
                            const index = try snapshot.irOperand(instruction, 1);
                            if (hasTablePointerProvenance(table_pointer_provenance, table) and
                                (index.kind == .instruction or index.kind == .constant))
                            {
                                const guard = arrayGuard(table, index);
                                try array_guards.put(guard, {});
                                last_array_guard = guard;
                            }
                        },
                        9 => if (instruction.operand_count == 2) {
                            const table = try snapshot.irOperand(instruction, 0);
                            const index = try snapshot.irOperand(instruction, 1);
                            if (hasTablePointerProvenance(table_pointer_provenance, table)) {
                                const address = arrayGuard(table, index);
                                if (array_guards.contains(address)) {
                                    guarded_array_addresses[instruction_id] = true;
                                    array_address_guards[instruction_id] = address;
                                } else if (last_array_guard) |guard| {
                                    if (sameOperandKey(guard.table_kind, guard.table_value, table) and
                                        try constantIndexAtMost(snapshot, function, index, guard))
                                    {
                                        guarded_array_addresses[instruction_id] = true;
                                        array_address_guards[instruction_id] = guard;
                                    }
                                }
                            }
                        },
                        else => {},
                    },
                }
            }
        }

        const successor_offsets = try buildOffsets(allocator, block_count, edges.items, true);
        errdefer allocator.free(successor_offsets);
        const successors = try fillEdges(allocator, successor_offsets, edges.items, true);
        errdefer allocator.free(successors);

        const predecessor_offsets = try buildOffsets(allocator, block_count, edges.items, false);
        errdefer allocator.free(predecessor_offsets);
        const predecessors = try fillEdges(allocator, predecessor_offsets, edges.items, false);
        errdefer allocator.free(predecessors);

        const guarded_buffer_operations = try buildGuardedBufferOperations(
            allocator,
            snapshot,
            function,
            instruction_blocks,
            predecessor_offsets,
            predecessors,
        );
        errdefer allocator.free(guarded_buffer_operations);

        // Runtime suspension discards Wasm locals. A continuation cannot re-enter below an SSA
        // producer that dominates the rejoin: doing so would skip the producer while retaining a
        // downstream use. Mark all such dominator subtrees in one interval pass rather than
        // rebuilding reachability and dominance for every CALL.
        const dominators = try buildDominators(
            allocator,
            function.entry_block,
            successor_offsets,
            successors,
            predecessor_offsets,
            predecessors,
        );
        errdefer {
            allocator.free(dominators.immediate);
            allocator.free(dominators.enter);
            allocator.free(dominators.exit);
        }
        const resume_safe_blocks = try allocator.alloc(bool, block_count);
        errdefer allocator.free(resume_safe_blocks);
        @memset(resume_safe_blocks, true);
        const dominance_events = try allocator.alloc(i32, block_count * 2 + 2);
        defer allocator.free(dominance_events);
        @memset(dominance_events, 0);
        instruction_id = 0;
        while (instruction_id < function.instruction_count) : (instruction_id += 1) {
            const consumer_block = instruction_blocks[instruction_id];
            if (consumer_block == snapshot_v1.no_id)
                continue;
            const instruction = try snapshot.irInstruction(function, instruction_id);
            var operand_id: u32 = 0;
            while (operand_id < instruction.operand_count) : (operand_id += 1) {
                const operand = try snapshot.irOperand(instruction, operand_id);
                if (operand.kind != .instruction)
                    continue;
                if (operand.value >= function.instruction_count)
                    return Error.UnsupportedControlFlow;
                const producer_block = instruction_blocks[operand.value];
                if (producer_block == snapshot_v1.no_id) {
                    resume_safe_blocks[consumer_block] = false;
                    continue;
                }
                if (producer_block == consumer_block) {
                    if (operand.value >= instruction_id)
                        return Error.UnsupportedControlFlow;
                    continue;
                }
                if (dominators.immediate[producer_block] == snapshot_v1.no_id or
                    dominators.immediate[consumer_block] == snapshot_v1.no_id or
                    dominators.enter[producer_block] > dominators.enter[consumer_block] or
                    dominators.exit[consumer_block] > dominators.exit[producer_block])
                {
                    resume_safe_blocks[consumer_block] = false;
                    continue;
                }
                const start: usize = dominators.enter[producer_block];
                const finish: usize = dominators.exit[producer_block] + 1;
                dominance_events[start] = std.math.add(i32, dominance_events[start], 1) catch
                    return Error.ResourceLimit;
                dominance_events[finish] = std.math.sub(i32, dominance_events[finish], 1) catch
                    return Error.ResourceLimit;
            }
        }
        var active_events: i32 = 0;
        var event_index: usize = 0;
        while (event_index < dominance_events.len) : (event_index += 1) {
            active_events = std.math.add(i32, active_events, dominance_events[event_index]) catch
                return Error.ResourceLimit;
            dominance_events[event_index] = active_events;
        }
        block_id = 0;
        while (block_id < function.block_count) : (block_id += 1) {
            if (dominators.immediate[block_id] == snapshot_v1.no_id or
                dominance_events[dominators.enter[block_id]] != 0)
                resume_safe_blocks[block_id] = false;
        }

        var facts = try recognize.recognize(
            allocator,
            snapshot,
            function,
            proto,
            .{
                .table_pointer_provenance = table_pointer_provenance,
                .instruction_blocks = instruction_blocks,
                .transient_address_invalidator_prefix = transient_address_invalidator_prefix,
            },
        );
        errdefer facts.deinit();

        const cluster_index = try allocator.alloc(u32, instruction_count);
        errdefer allocator.free(cluster_index);
        @memset(cluster_index, snapshot_v1.no_id);
        const userdata_clusters = try cluster_index_mod.stampUserdataClusters(
            allocator,
            snapshot,
            function,
            proto,
            instruction_blocks,
            cluster_index,
        );
        errdefer if (userdata_clusters.len != 0) allocator.free(userdata_clusters);

        var import_needs = model.ImportNeeds{};
        try model.scanImportNeedsFor(snapshot, function, static_package, &import_needs);

        return .{
            .allocator = allocator,
            .instruction_blocks = instruction_blocks,
            .instruction_use_counts = instruction_use_counts,
            .block_reference_counts = block_reference_counts,
            .successor_offsets = successor_offsets,
            .successors = successors,
            .predecessor_offsets = predecessor_offsets,
            .predecessors = predecessors,
            .transient_address_invalidator_prefix = transient_address_invalidator_prefix,
            .table_pointer_provenance = table_pointer_provenance,
            .guarded_array_addresses = guarded_array_addresses,
            .array_address_guards = array_address_guards,
            .guarded_buffer_operations = guarded_buffer_operations,
            .resume_safe_blocks = resume_safe_blocks,
            .facts = facts,
            .dominators = dominators,
            .cluster_index = cluster_index,
            .clusters = userdata_clusters,
            .continuation_sites = &.{},
            .continuation_regions = &.{},
            .iteration_regions = &.{},
            .block_index = .{},
            .pow_sites = &.{},
            .call_facts = .{},
            .import_needs = import_needs,
            .lowered_commands = std.StaticBitSet(256).initEmpty(),
        };
    }

    pub fn deinit(self: *FunctionPlan) void {
        self.allocator.free(self.instruction_blocks);
        self.allocator.free(self.instruction_use_counts);
        self.allocator.free(self.block_reference_counts);
        self.allocator.free(self.successor_offsets);
        self.allocator.free(self.successors);
        self.allocator.free(self.predecessor_offsets);
        self.allocator.free(self.predecessors);
        self.allocator.free(self.transient_address_invalidator_prefix);
        self.allocator.free(self.table_pointer_provenance);
        self.allocator.free(self.guarded_array_addresses);
        self.allocator.free(self.array_address_guards);
        self.allocator.free(self.guarded_buffer_operations);
        self.allocator.free(self.resume_safe_blocks);
        self.allocator.free(self.dominators.immediate);
        self.allocator.free(self.dominators.enter);
        self.allocator.free(self.dominators.exit);
        self.allocator.free(self.cluster_index);
        if (self.clusters.len != 0)
            self.allocator.free(self.clusters);
        if (self.continuation_sites.len != 0)
            self.allocator.free(self.continuation_sites);
        if (self.continuation_regions.len != 0)
            self.allocator.free(self.continuation_regions);
        if (self.iteration_regions.len != 0)
            self.allocator.free(self.iteration_regions);
        self.block_index.deinit();
        if (self.pow_sites.len != 0)
            self.allocator.free(self.pow_sites);
        self.call_facts.deinit();
        self.facts.deinit();
        self.* = undefined;
    }

    pub fn dupTableAt(self: FunctionPlan, start: u32) ?model.DupTablePattern {
        return self.facts.dupTableAt(start);
    }

    pub fn tableAllocAt(self: FunctionPlan, start: u32) ?model.TableAllocationPattern {
        const alloc = self.facts.tableAllocAt(start) orelse return null;
        if (alloc.dest_reg == snapshot_v1.no_id)
            return null;
        return .{
            .start = alloc.start,
            .finish = alloc.finish,
            .assist = alloc.assist,
            .deferred_to_later_gc = alloc.deferred_to_later_gc,
            .destination = alloc.dest_reg,
            .array_count = alloc.array_count,
            .node_count = alloc.node_count,
        };
    }

    pub fn tableAllocCovering(self: FunctionPlan, instruction_id: u32) ?recognize.TableAlloc {
        return self.facts.tableAllocCovering(instruction_id);
    }

    pub fn tableAllocHasDest(self: FunctionPlan, dest_reg: u32) bool {
        for (self.facts.table_allocs) |alloc| {
            if (alloc.dest_reg == dest_reg)
                return true;
        }
        return false;
    }

    pub fn clusterAt(self: FunctionPlan, instruction_id: u32) ?Cluster {
        if (instruction_id >= self.cluster_index.len)
            return null;
        const index = self.cluster_index[instruction_id];
        if (index == snapshot_v1.no_id)
            return null;
        return self.clusters[index];
    }

    pub fn indexClusters(self: *FunctionPlan, ctx: anytype) Error!void {
        try self.collectPowSites(ctx);
        var clusters: std.ArrayList(Cluster) = .empty;
        errdefer clusters.deinit(self.allocator);
        try clusters.appendSlice(self.allocator, self.clusters);
        var instruction_id: u32 = 0;
        while (instruction_id < self.cluster_index.len) : (instruction_id += 1) {
            if (self.cluster_index[instruction_id] != snapshot_v1.no_id)
                continue;
            const matched = (try matchInstructionCluster(ctx, instruction_id)) orelse continue;
            if (clusters.items.len != 0) {
                const last = clusters.items[clusters.items.len - 1];
                if (last.kind == matched.kind and last.start == matched.start and
                    last.at == matched.at and last.finish == matched.finish)
                {
                    self.cluster_index[instruction_id] = @intCast(clusters.items.len - 1);
                    continue;
                }
            }
            self.cluster_index[instruction_id] = @intCast(clusters.items.len);
            try clusters.append(self.allocator, matched);
        }
        const previous = self.clusters;
        self.clusters = try clusters.toOwnedSlice(self.allocator);
        if (previous.len != 0)
            self.allocator.free(previous);
    }

    pub fn indexBlocks(self: *FunctionPlan, ctx: anytype) Error!void {
        self.block_index.deinit();
        self.call_facts.deinit();
        self.block_index = try recognize_tables.indexBlocks(self.allocator, ctx);
        self.call_facts = try recognize_calls.collectCallFacts(self.allocator, ctx);
    }

    pub fn blockKind(self: FunctionPlan, block_id: u32) recognize_tables.BlockKind {
        return self.block_index.kind(block_id);
    }

    pub fn isPlannedBypass(self: FunctionPlan, block_id: u32) bool {
        return self.block_index.isBypassed(block_id);
    }

    pub fn ownsFallback(self: FunctionPlan, block_id: u32) bool {
        return self.block_index.ownsFallback(block_id);
    }

    pub fn fallbackOwner(self: FunctionPlan, block_id: u32) ?u32 {
        return self.block_index.fallbackOwner(block_id);
    }

    fn collectPowSites(self: *FunctionPlan, ctx: anytype) Error!void {
        if (self.pow_sites.len != 0) {
            self.allocator.free(self.pow_sites);
            self.pow_sites = &.{};
        }
        var sites: std.ArrayList(model.PowPattern) = .empty;
        errdefer sites.deinit(self.allocator);
        var block_id: u32 = 0;
        while (block_id < ctx.function.block_count) : (block_id += 1) {
            const block = try ctx.snapshot.irBlock(ctx.function, block_id);
            if (try ctx.powPattern(block)) |pattern|
                try sites.append(self.allocator, pattern);
        }
        self.pow_sites = try sites.toOwnedSlice(self.allocator);
    }

    pub fn supportsFallback(self: FunctionPlan, block_id: u32) bool {
        return self.block_index.supportsFallback(block_id);
    }

    pub fn blockDominates(self: FunctionPlan, dominator: u32, block: u32) bool {
        if (dominator >= self.dominators.enter.len or block >= self.dominators.enter.len or
            self.dominators.immediate[dominator] == snapshot_v1.no_id or
            self.dominators.immediate[block] == snapshot_v1.no_id)
            return false;
        return self.dominators.enter[dominator] <= self.dominators.enter[block] and
            self.dominators.exit[block] <= self.dominators.exit[dominator];
    }

    pub fn checkDominatesRead(self: FunctionPlan, check_id: u32, read_id: u32) bool {
        const check_block = self.instructionBlock(check_id) orelse return false;
        const read_block = self.instructionBlock(read_id) orelse return false;
        if (check_block == read_block)
            return check_id < read_id;
        return self.blockDominates(check_block, read_block);
    }

    pub fn noteLowered(self: *FunctionPlan, command: snapshot_v1.IrCommand) void {
        self.lowered_commands.set(@intFromEnum(command));
    }

    pub fn noteLoweredRange(
        self: *FunctionPlan,
        snapshot: snapshot_v1.Snapshot,
        function: snapshot_v1.IrFunction,
        start: u32,
        finish: u32,
    ) void {
        var instruction_id = start;
        while (instruction_id <= finish and instruction_id < function.instruction_count) : (instruction_id += 1) {
            const instruction = snapshot.irInstruction(function, instruction_id) catch continue;
            self.noteLowered(instruction.command);
        }
    }

    pub fn continuationAdmitted(self: FunctionPlan, block_id: u32, suffix_start: u32, finish: u32) ?bool {
        for (self.continuation_regions) |region| {
            if (region.block_id == block_id and region.suffix_start == suffix_start and
                region.block_finish == finish)
                return region.admitted;
        }
        return null;
    }

    pub fn iterationAdmitted(self: FunctionPlan, repeat_target: u32, exit_target: u32) ?bool {
        for (self.iteration_regions) |region| {
            if (region.repeat_target == repeat_target and region.exit_target == exit_target)
                return region.admitted;
        }
        return null;
    }

    pub fn plainLenAt(self: FunctionPlan, instruction_id: u32) ?recognize.PlainLen {
        return self.facts.plainLenAt(instruction_id);
    }

    pub fn plainLenContaining(self: FunctionPlan, instruction_id: u32) ?recognize.PlainLen {
        return self.facts.plainLenContaining(instruction_id);
    }

    pub fn closureContaining(self: FunctionPlan, instruction_id: u32) ?recognize.Closure {
        return self.facts.closureContaining(instruction_id);
    }

    pub fn dupClosureCaptureContaining(self: FunctionPlan, instruction_id: u32) bool {
        return self.facts.dupClosureCaptureContaining(instruction_id);
    }

    pub fn instructionBlock(self: FunctionPlan, instruction_id: u32) ?u32 {
        if (instruction_id >= self.instruction_blocks.len)
            return null;
        const block = self.instruction_blocks[instruction_id];
        return if (block == snapshot_v1.no_id) null else block;
    }

    pub fn blockReferences(self: FunctionPlan, block_id: u32) ?u32 {
        if (block_id >= self.block_reference_counts.len)
            return null;
        return self.block_reference_counts[block_id];
    }

    pub fn instructionUses(self: FunctionPlan, instruction_id: u32) ?u32 {
        if (instruction_id >= self.instruction_use_counts.len)
            return null;
        return self.instruction_use_counts[instruction_id];
    }

    pub fn isProvenTablePointer(self: FunctionPlan, instruction_id: u32) bool {
        return instruction_id < self.table_pointer_provenance.len and
            self.table_pointer_provenance[instruction_id];
    }

    pub fn isGuardedArrayAddress(self: FunctionPlan, instruction_id: u32) bool {
        return instruction_id < self.guarded_array_addresses.len and
            self.guarded_array_addresses[instruction_id];
    }

    pub fn isGuardedBufferOperation(self: FunctionPlan, instruction_id: u32) bool {
        return instruction_id < self.guarded_buffer_operations.len and
            self.guarded_buffer_operations[instruction_id];
    }

    pub fn isResumeSafeBlock(self: FunctionPlan, block_id: u32) bool {
        return block_id < self.resume_safe_blocks.len and self.resume_safe_blocks[block_id];
    }

    pub fn successorSlice(self: FunctionPlan, block_id: u32) ?[]const u32 {
        if (block_id + 1 >= self.successor_offsets.len)
            return null;
        return self.successors[self.successor_offsets[block_id]..self.successor_offsets[block_id + 1]];
    }

    pub fn predecessorSlice(self: FunctionPlan, block_id: u32) ?[]const u32 {
        if (block_id + 1 >= self.predecessor_offsets.len)
            return null;
        return self.predecessors[self.predecessor_offsets[block_id]..self.predecessor_offsets[block_id + 1]];
    }

    /// Build exact dominance for a resumable subgraph. Generated continuations enter at their
    /// rejoin roots, not at the Luau function entry, so ordinary function dominance is not valid
    /// for values live after suspension. A virtual root connects every resume arm and the same
    /// linear Lengauer-Tarjan implementation analyzes only the admitted region.
    pub fn regionDominators(
        self: FunctionPlan,
        allocator: std.mem.Allocator,
        included: []const bool,
        roots: []const u32,
    ) Error!RegionDominators {
        const block_count = self.successor_offsets.len - 1;
        if (included.len != block_count or roots.len == 0)
            return Error.UnsupportedControlFlow;
        const virtual_root = std.math.cast(u32, block_count) orelse return Error.ResourceLimit;

        var edges: std.ArrayList(Edge) = .empty;
        defer edges.deinit(allocator);
        for (roots) |root| {
            if (root >= block_count or !included[root])
                return Error.UnsupportedControlFlow;
            try edges.append(allocator, .{ .source = virtual_root, .target = root });
        }
        var source: u32 = 0;
        while (source < block_count) : (source += 1) {
            if (!included[source])
                continue;
            const outgoing = self.successorSlice(source) orelse return Error.UnsupportedControlFlow;
            for (outgoing) |target| {
                if (included[target])
                    try edges.append(allocator, .{ .source = source, .target = target });
            }
        }

        const region_block_count = std.math.add(usize, block_count, 1) catch return Error.ResourceLimit;
        const successor_offsets = try buildOffsets(allocator, region_block_count, edges.items, true);
        defer allocator.free(successor_offsets);
        const successors = try fillEdges(allocator, successor_offsets, edges.items, true);
        defer allocator.free(successors);
        const predecessor_offsets = try buildOffsets(allocator, region_block_count, edges.items, false);
        defer allocator.free(predecessor_offsets);
        const predecessors = try fillEdges(allocator, predecessor_offsets, edges.items, false);
        defer allocator.free(predecessors);

        const dominators = try buildDominators(
            allocator,
            virtual_root,
            successor_offsets,
            successors,
            predecessor_offsets,
            predecessors,
        );
        return .{
            .allocator = allocator,
            .immediate = dominators.immediate,
            .enter = dominators.enter,
            .exit = dominators.exit,
        };
    }

    pub fn validateNodeUse(
        self: FunctionPlan,
        snapshot: snapshot_v1.Snapshot,
        function: snapshot_v1.IrFunction,
        producer_id: u32,
        consumer_id: u32,
    ) Error!bool {
        if (producer_id >= function.instruction_count or consumer_id >= function.instruction_count)
            return false;
        const producer = try snapshot.irInstruction(function, producer_id);
        if (producer.command != abi.ir_cmd_get_hash_node_addr and
            producer.command != abi.ir_cmd_get_slot_node_addr)
            return false;

        const producer_block = self.instructionBlock(producer_id) orelse return false;
        const consumer_block = self.instructionBlock(consumer_id) orelse return false;
        if (producer_block == consumer_block) {
            return producer_id < consumer_id and !self.hasTransientAddressInvalidator(producer_id + 1, consumer_id);
        }

        if (!self.hasDirectEdge(producer_block, consumer_block) or
            !self.hasOnlyPredecessor(consumer_block, producer_block))
            return false;

        const source_block = try snapshot.irBlock(function, producer_block);
        const target_block = try snapshot.irBlock(function, consumer_block);
        return !self.hasTransientAddressInvalidator(producer_id + 1, source_block.finish + 1) and
            !self.hasTransientAddressInvalidator(target_block.start, consumer_id);
    }

    pub fn validateArrayAddressUse(
        self: FunctionPlan,
        snapshot: snapshot_v1.Snapshot,
        function: snapshot_v1.IrFunction,
        producer_id: u32,
        consumer_id: u32,
    ) Error!bool {
        if (!self.isGuardedArrayAddress(producer_id))
            return false;
        const producer = try snapshot.irInstruction(function, producer_id);
        if (producer.command != abi.ir_cmd_get_arr_addr)
            return false;
        const producer_block = self.instructionBlock(producer_id) orelse return false;
        const consumer_block = self.instructionBlock(consumer_id) orelse return false;
        if (producer_block != consumer_block or producer_id >= consumer_id or
            self.hasTransientAddressInvalidator(producer_id + 1, consumer_id))
            return false;

        const guard = self.array_address_guards[producer_id] orelse return false;
        const address_index = try snapshot.irOperand(producer, 1);
        const consumer = try snapshot.irInstruction(function, consumer_id);
        const byte_offset: u32 = switch (consumer.command) {
            .load_tvalue => if (consumer.operand_count >= 2)
                try nonnegativeByteOffset(snapshot, function, try snapshot.irOperand(consumer, 1))
            else
                0,
            .store_split_tvalue => if (consumer.operand_count == 4)
                try nonnegativeByteOffset(snapshot, function, try snapshot.irOperand(consumer, 3))
            else
                0,
            .store_tvalue => if (consumer.operand_count == 3)
                try nonnegativeByteOffset(snapshot, function, try snapshot.irOperand(consumer, 2))
            else
                0,
            .load_tag, .load_pointer => 0,
            else => return false,
        };
        if (byte_offset % abi.tvalue_size != 0)
            return false;
        if (sameOperandKey(guard.index_kind, guard.index_value, address_index))
            return byte_offset == 0;
        const base = try constantIndex(snapshot, function, address_index) orelse return false;
        const limit = try constantIndexFromGuard(snapshot, function, guard) orelse return false;
        const effective = std.math.add(u32, base, byte_offset / abi.tvalue_size) catch return false;
        return effective <= limit;
    }

    fn hasTransientAddressInvalidator(self: FunctionPlan, start: u32, finish_exclusive: u32) bool {
        if (start > finish_exclusive or finish_exclusive >= self.transient_address_invalidator_prefix.len)
            return true;
        return self.transient_address_invalidator_prefix[finish_exclusive] !=
            self.transient_address_invalidator_prefix[start];
    }

    fn hasDirectEdge(self: FunctionPlan, source: u32, target: u32) bool {
        const successors = self.successorSlice(source) orelse return false;
        for (successors) |candidate|
            if (candidate == target)
                return true;
        return false;
    }

    fn hasOnlyPredecessor(self: FunctionPlan, block: u32, expected: u32) bool {
        const predecessors = self.predecessorSlice(block) orelse return false;
        var saw_expected = false;
        for (predecessors) |candidate| {
            if (candidate == expected) {
                saw_expected = true;
            } else return false;
        }
        return saw_expected;
    }
};

fn invalidatesTransientAddress(command: snapshot_v1.IrCommand) bool {
    return switch (command) {
        .cmp_any,
        .do_arith,
        .get_cached_import,
        .interrupt,
        .check_gc,
        .call,
        .fallback_prepvarargs,
        .fallback_getvarargs,
        .newclosure,
        .fallback_dupclosure,
        => true,
        else => switch (@intFromEnum(command)) {
            100,
            101,
            102,
            105,
            120,
            121,
            124,
            125,
            126,
            128,
            153,
            156,
            157,
            158,
            160,
            161,
            162,
            163,
            164,
            169,
            => true,
            else => false,
        },
    };
}

fn arrayGuard(table: snapshot_v1.IrOperand, index: snapshot_v1.IrOperand) ArrayGuard {
    return .{
        .table_kind = table.kind,
        .table_value = table.value,
        .index_kind = index.kind,
        .index_value = index.value,
    };
}

fn hasTablePointerProvenance(provenance: []const bool, operand: snapshot_v1.IrOperand) bool {
    return operand.kind == .instruction and operand.value < provenance.len and provenance[operand.value];
}

fn sameOperandKey(kind: snapshot_v1.IrOperandKind, value: u32, operand: snapshot_v1.IrOperand) bool {
    return kind == operand.kind and value == operand.value;
}

fn constantIndexAtMost(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    index: snapshot_v1.IrOperand,
    guard: ArrayGuard,
) Error!bool {
    const value = try constantIndex(snapshot, function, index) orelse return false;
    const limit = try constantIndexFromGuard(snapshot, function, guard) orelse return false;
    return value <= limit;
}

fn constantIndexFromGuard(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    guard: ArrayGuard,
) Error!?u32 {
    return constantIndex(snapshot, function, .{ .kind = guard.index_kind, .value = guard.index_value });
}

fn constantIndex(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    operand: snapshot_v1.IrOperand,
) Error!?u32 {
    if (operand.kind != .constant)
        return null;
    const value = try snapshot.irConstant(function, operand.value);
    const integer = value.intValue() orelse return null;
    if (integer < 0)
        return null;
    return std.math.cast(u32, integer);
}

fn nonnegativeByteOffset(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    operand: snapshot_v1.IrOperand,
) Error!u32 {
    return (try constantIndex(snapshot, function, operand)) orelse return Error.InvalidOperandType;
}

fn writtenVmRegister(
    snapshot: snapshot_v1.Snapshot,
    instruction: snapshot_v1.IrInstruction,
) Error!?u32 {
    switch (instruction.command) {
        .store_tag,
        .store_extra,
        .store_pointer,
        .store_double,
        .store_int,
        .store_int64,
        .store_vector,
        .store_tvalue,
        .store_split_tvalue,
        => {},
        else => return null,
    }
    if (instruction.operand_count == 0)
        return null;
    const destination = try snapshot.irOperand(instruction, 0);
    return if (destination.kind == .vm_reg) destination.value else null;
}

fn buildGuardedBufferOperations(
    allocator: std.mem.Allocator,
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    instruction_blocks: []const u32,
    predecessor_offsets: []const u32,
    predecessors: []const u32,
) Error![]bool {
    const guarded = try allocator.alloc(bool, function.instruction_count);
    errdefer allocator.free(guarded);
    @memset(guarded, false);

    var block_guards = std.AutoHashMap(BlockBufferPointer, BufferGuard).init(allocator);
    defer block_guards.deinit();

    var instruction_id: u32 = 0;
    while (instruction_id < function.instruction_count) : (instruction_id += 1) {
        const instruction = try snapshot.irInstruction(function, instruction_id);
        const guard = (try bufferGuard(snapshot, function, instruction)) orelse continue;
        const block = instruction_blocks[instruction_id];
        if (block == snapshot_v1.no_id)
            continue;
        const pointer = try snapshot.irOperand(instruction, 0);
        try block_guards.put(.{
            .block = block,
            .pointer = .{ .kind = pointer.kind, .value = pointer.value },
        }, guard);
    }

    var local_guards = std.AutoHashMap(BufferPointer, BufferGuard).init(allocator);
    defer local_guards.deinit();
    var block_id: u32 = 0;
    while (block_id < function.block_count) : (block_id += 1) {
        local_guards.clearRetainingCapacity();
        const block = try snapshot.irBlock(function, block_id);
        if (block.isEmpty())
            continue;

        instruction_id = block.start;
        while (instruction_id <= block.finish) : (instruction_id += 1) {
            const instruction = try snapshot.irInstruction(function, instruction_id);
            if (try bufferGuard(snapshot, function, instruction)) |guard| {
                const pointer = try snapshot.irOperand(instruction, 0);
                try local_guards.put(.{ .kind = pointer.kind, .value = pointer.value }, guard);
                continue;
            }

            const width = bufferAccessWidth(instruction.command) orelse continue;
            if (instruction.operand_count < 2)
                continue;
            const pointer = try snapshot.irOperand(instruction, 0);
            const index = try snapshot.irOperand(instruction, 1);
            const pointer_key: BufferPointer = .{ .kind = pointer.kind, .value = pointer.value };
            if (local_guards.get(pointer_key)) |guard| {
                if (try bufferGuardCovers(snapshot, function, guard, index, width))
                    guarded[instruction_id] = true;
                continue;
            }

            const predecessor_start = predecessor_offsets[block_id];
            const predecessor_finish = predecessor_offsets[block_id + 1];
            if (predecessor_finish - predecessor_start != 1)
                continue;
            const predecessor = predecessors[predecessor_start];
            const guard = block_guards.get(.{ .block = predecessor, .pointer = pointer_key }) orelse continue;
            if (guard.failure_block != null and guard.failure_block.? == block_id)
                continue;
            if (try bufferGuardCovers(snapshot, function, guard, index, width))
                guarded[instruction_id] = true;
        }
    }

    return guarded;
}

fn bufferGuard(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    instruction: snapshot_v1.IrInstruction,
) Error!?BufferGuard {
    if (instruction.command != abi.ir_cmd_check_buffer_len or instruction.operand_count != 6)
        return null;
    const base = try snapshot.irOperand(instruction, 1);
    const min = try operandIntConstant(snapshot, function, try snapshot.irOperand(instruction, 2)) orelse return null;
    const max = try operandIntConstant(snapshot, function, try snapshot.irOperand(instruction, 3)) orelse return null;
    const failure = try snapshot.irOperand(instruction, 5);
    if (min >= max or (base.kind != .instruction and base.kind != .constant))
        return null;
    return .{
        .base_kind = base.kind,
        .base_value = base.value,
        .min_offset = min,
        .max_offset = max,
        .failure_block = if (failure.kind == .block) failure.value else null,
    };
}

fn bufferGuardCovers(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    guard: BufferGuard,
    index: snapshot_v1.IrOperand,
    width: u32,
) Error!bool {
    const offset = (try bufferIndexOffset(
        snapshot,
        function,
        .{ .kind = guard.base_kind, .value = guard.base_value },
        index,
    )) orelse return false;
    const finish = std.math.add(i64, @as(i64, offset), @as(i64, width)) catch return false;
    return offset >= guard.min_offset and finish <= guard.max_offset;
}

fn bufferIndexOffset(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    base: snapshot_v1.IrOperand,
    index: snapshot_v1.IrOperand,
) Error!?i32 {
    if (sameOperandKey(base.kind, base.value, index))
        return 0;
    if (try operandIntConstant(snapshot, function, base)) |base_value| {
        if (try operandIntConstant(snapshot, function, index)) |index_value|
            return std.math.sub(i32, index_value, base_value) catch null;
    }
    if (index.kind != .instruction or index.value >= function.instruction_count)
        return null;
    const arithmetic = try snapshot.irInstruction(function, index.value);
    if (arithmetic.operand_count != 2 or
        (arithmetic.command != .add_int and arithmetic.command != .sub_int))
        return null;
    const lhs = try snapshot.irOperand(arithmetic, 0);
    const rhs = try snapshot.irOperand(arithmetic, 1);
    if (sameOperandKey(lhs.kind, lhs.value, base)) {
        const displacement = (try operandIntConstant(snapshot, function, rhs)) orelse return null;
        return if (arithmetic.command == .add_int)
            displacement
        else
            std.math.sub(i32, 0, displacement) catch null;
    }
    if (arithmetic.command == .add_int and sameOperandKey(rhs.kind, rhs.value, base))
        return (try operandIntConstant(snapshot, function, lhs)) orelse null;
    return null;
}

fn operandIntConstant(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    operand: snapshot_v1.IrOperand,
) Error!?i32 {
    if (operand.kind != .constant)
        return null;
    return (try snapshot.irConstant(function, operand.value)).intValue();
}

fn bufferAccessWidth(command: snapshot_v1.IrCommand) ?u32 {
    return switch (command) {
        abi.ir_cmd_buffer_readi8, abi.ir_cmd_buffer_readu8, abi.ir_cmd_buffer_writei8 => 1,
        abi.ir_cmd_buffer_readi16, abi.ir_cmd_buffer_readu16, abi.ir_cmd_buffer_writei16 => 2,
        abi.ir_cmd_buffer_readi32,
        abi.ir_cmd_buffer_readf32,
        abi.ir_cmd_buffer_writei32,
        abi.ir_cmd_buffer_writef32,
        => 4,
        abi.ir_cmd_buffer_readf64,
        abi.ir_cmd_buffer_readi64,
        abi.ir_cmd_buffer_writef64,
        abi.ir_cmd_buffer_writei64,
        => 8,
        else => null,
    };
}

fn buildOffsets(
    allocator: std.mem.Allocator,
    block_count: usize,
    edges: []const Edge,
    successors: bool,
) Error![]u32 {
    const offsets = try allocator.alloc(u32, block_count + 1);
    @memset(offsets, 0);
    for (edges) |edge| {
        const block = if (successors) edge.source else edge.target;
        offsets[block + 1] = std.math.add(u32, offsets[block + 1], 1) catch return Error.ResourceLimit;
    }
    var index: usize = 1;
    while (index < offsets.len) : (index += 1)
        offsets[index] = std.math.add(u32, offsets[index], offsets[index - 1]) catch return Error.ResourceLimit;
    return offsets;
}

fn fillEdges(
    allocator: std.mem.Allocator,
    offsets: []const u32,
    edges: []const Edge,
    successors: bool,
) Error![]u32 {
    const values = try allocator.alloc(u32, edges.len);
    const cursors = try allocator.dupe(u32, offsets[0 .. offsets.len - 1]);
    defer allocator.free(cursors);
    for (edges) |edge| {
        const source = if (successors) edge.source else edge.target;
        const target = if (successors) edge.target else edge.source;
        values[cursors[source]] = target;
        cursors[source] += 1;
    }
    return values;
}

const Dominators = struct {
    immediate: []u32,
    enter: []u32,
    exit: []u32,
};

fn buildDominators(
    allocator: std.mem.Allocator,
    entry_block: u32,
    successor_offsets: []const u32,
    successors: []const u32,
    predecessor_offsets: []const u32,
    predecessors: []const u32,
) Error!Dominators {
    const block_count = successor_offsets.len - 1;
    if (entry_block >= block_count)
        return Error.UnsupportedControlFlow;

    const dfs_index = try allocator.alloc(u32, block_count);
    defer allocator.free(dfs_index);
    @memset(dfs_index, snapshot_v1.no_id);
    const vertex = try allocator.alloc(u32, block_count + 1);
    defer allocator.free(vertex);
    @memset(vertex, snapshot_v1.no_id);
    const parent = try allocator.alloc(u32, block_count + 1);
    defer allocator.free(parent);
    @memset(parent, 0);

    var frames: std.ArrayList(DfsFrame) = .empty;
    defer frames.deinit(allocator);
    var dfs_count: u32 = 1;
    dfs_index[entry_block] = dfs_count;
    vertex[dfs_count] = entry_block;
    try frames.append(allocator, .{ .block = entry_block, .next_edge = successor_offsets[entry_block] });
    while (frames.items.len != 0) {
        const frame = &frames.items[frames.items.len - 1];
        const edge_end = successor_offsets[frame.block + 1];
        if (frame.next_edge >= edge_end) {
            frames.items.len -= 1;
            continue;
        }
        const target = successors[frame.next_edge];
        frame.next_edge += 1;
        if (dfs_index[target] != snapshot_v1.no_id)
            continue;
        dfs_count = std.math.add(u32, dfs_count, 1) catch return Error.ResourceLimit;
        dfs_index[target] = dfs_count;
        vertex[dfs_count] = target;
        parent[dfs_count] = dfs_index[frame.block];
        try frames.append(allocator, .{ .block = target, .next_edge = successor_offsets[target] });
    }

    const count: usize = @intCast(dfs_count + 1);
    const semi = try allocator.alloc(u32, count);
    defer allocator.free(semi);
    const idom = try allocator.alloc(u32, count);
    defer allocator.free(idom);
    const ancestor = try allocator.alloc(u32, count);
    defer allocator.free(ancestor);
    const label = try allocator.alloc(u32, count);
    defer allocator.free(label);
    @memset(idom, 0);
    @memset(ancestor, 0);
    var index: u32 = 0;
    while (index <= dfs_count) : (index += 1) {
        semi[index] = index;
        label[index] = index;
    }

    const buckets = try allocator.alloc(std.ArrayList(u32), count);
    defer allocator.free(buckets);
    for (buckets) |*bucket|
        bucket.* = .empty;
    defer for (buckets) |*bucket| bucket.deinit(allocator);

    var current = dfs_count;
    while (current > 1) : (current -= 1) {
        const block = vertex[current];
        const pred_start = predecessor_offsets[block];
        const pred_end = predecessor_offsets[block + 1];
        var pred_index = pred_start;
        while (pred_index < pred_end) : (pred_index += 1) {
            const predecessor = dfs_index[predecessors[pred_index]];
            if (predecessor == snapshot_v1.no_id)
                continue;
            const evaluated = evalDominator(predecessor, ancestor, label, semi);
            if (semi[evaluated] < semi[current])
                semi[current] = semi[evaluated];
        }
        try buckets[semi[current]].append(allocator, current);
        ancestor[current] = parent[current];
        for (buckets[parent[current]].items) |candidate| {
            const evaluated = evalDominator(candidate, ancestor, label, semi);
            idom[candidate] = if (semi[evaluated] < semi[candidate]) evaluated else parent[current];
        }
        buckets[parent[current]].items.len = 0;
    }

    index = 2;
    while (index <= dfs_count) : (index += 1) {
        if (idom[index] != semi[index])
            idom[index] = idom[idom[index]];
    }
    idom[1] = 1;

    const immediate = try allocator.alloc(u32, block_count);
    errdefer allocator.free(immediate);
    @memset(immediate, snapshot_v1.no_id);
    index = 1;
    while (index <= dfs_count) : (index += 1) {
        immediate[vertex[index]] = vertex[idom[index]];
    }

    const child_offsets = try allocator.alloc(u32, block_count + 1);
    defer allocator.free(child_offsets);
    @memset(child_offsets, 0);
    var block: u32 = 0;
    while (block < block_count) : (block += 1) {
        const dominator = immediate[block];
        if (dominator != snapshot_v1.no_id and dominator != block)
            child_offsets[dominator + 1] += 1;
    }
    var child_index: usize = 1;
    while (child_index < child_offsets.len) : (child_index += 1)
        child_offsets[child_index] += child_offsets[child_index - 1];
    const children = try allocator.alloc(u32, dfs_count - 1);
    defer allocator.free(children);
    const child_cursors = try allocator.dupe(u32, child_offsets[0 .. child_offsets.len - 1]);
    defer allocator.free(child_cursors);
    block = 0;
    while (block < block_count) : (block += 1) {
        const dominator = immediate[block];
        if (dominator == snapshot_v1.no_id or dominator == block)
            continue;
        children[child_cursors[dominator]] = block;
        child_cursors[dominator] += 1;
    }

    const enter = try allocator.alloc(u32, block_count);
    errdefer allocator.free(enter);
    const exit = try allocator.alloc(u32, block_count);
    errdefer allocator.free(exit);
    @memset(enter, 0);
    @memset(exit, 0);
    var tree: std.ArrayList(TreeFrame) = .empty;
    defer tree.deinit(allocator);
    try tree.append(allocator, .{ .block = entry_block, .next_child = child_offsets[entry_block], .entered = false });
    var clock: u32 = 1;
    while (tree.items.len != 0) {
        const frame = &tree.items[tree.items.len - 1];
        if (!frame.entered) {
            frame.entered = true;
            enter[frame.block] = clock;
            clock = std.math.add(u32, clock, 1) catch return Error.ResourceLimit;
        }
        if (frame.next_child < child_offsets[frame.block + 1]) {
            const child = children[frame.next_child];
            frame.next_child += 1;
            try tree.append(allocator, .{ .block = child, .next_child = child_offsets[child], .entered = false });
        } else {
            exit[frame.block] = clock;
            clock = std.math.add(u32, clock, 1) catch return Error.ResourceLimit;
            tree.items.len -= 1;
        }
    }

    return .{ .immediate = immediate, .enter = enter, .exit = exit };
}

fn evalDominator(v: u32, ancestor: []u32, label: []u32, semi: []const u32) u32 {
    if (ancestor[v] == 0)
        return label[v];
    compressDominator(v, ancestor, label, semi);
    return label[v];
}

fn compressDominator(v: u32, ancestor: []u32, label: []u32, semi: []const u32) void {
    const parent = ancestor[v];
    if (parent == 0 or ancestor[parent] == 0)
        return;
    compressDominator(parent, ancestor, label, semi);
    if (semi[label[parent]] < semi[label[v]])
        label[v] = label[parent];
    ancestor[v] = ancestor[parent];
}

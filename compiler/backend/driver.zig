const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const static_package_v1 = @import("luauc_backend_static_package_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const FunctionPlan = @import("luauc_backend_plan").FunctionPlan;
const abi = @import("luauc_backend_runtime_abi");
const Context = @import("luauc_backend_context").Context;
const continuations = @import("luauc_backend_continuations");
const runtime_imports = @import("luauc_backend_imports");
const diagnostics = @import("luauc_backend_diagnostics");

const StringKeyPool = model.StringKeyPool;
const Error = model.Error;
const ValueSlot = model.ValueSlot;
const generated_symbol = abi.generated_symbol;
const generated_protos_symbol = abi.generated_protos_symbol;
const generated_modules_symbol = abi.generated_modules_symbol;
const generated_program_symbol = abi.generated_program_symbol;
const generated_string_keys_symbol = abi.generated_string_keys_symbol;
const aot_abi_version = abi.aot_abi_version;
const aot_proto_size = abi.aot_proto_size;
const aot_coverage_site_size = abi.aot_coverage_site_size;
const aot_constant_size = abi.aot_constant_size;
const aot_constant_item_size = abi.aot_constant_item_size;
const aot_module_size = abi.aot_module_size;
const aot_program_size = abi.aot_program_size;
const aot_proto_root_flag = abi.aot_proto_root_flag;
const aot_layout_sha256 = abi.aot_layout_sha256;
const status_internal_error = abi.status_internal_error;
const max_lowered_locals = abi.max_lowered_locals;

fn lowerFunction(
    allocator: std.mem.Allocator,
    snapshot: snapshot_v1.Snapshot,
    function_id: u32,
    object: *wasm.Object,
    imports: runtime_imports.RuntimeImports,
    symbol_name: []const u8,
    static_package: ?static_package_v1.Package,
    function_id_base: u32,
    proto_id_by_bytecode_id: []const u32,
    string_keys: *StringKeyPool,
) Error!wasm.FunctionRef {
    diagnostics.enterFunction(function_id);
    const function = try snapshot.irFunction(function_id);
    const proto = try snapshot.proto(function.proto_id);
    if (function.variadic != proto.is_vararg)
        return Error.UnsupportedVariadicFunction;

    const entry_block = try snapshot.irBlock(function, function.entry_block);
    if (!entry_block.kind.isCompilable() or entry_block.isEmpty())
        return Error.UnsupportedControlFlow;

    var plan = FunctionPlan.init(allocator, snapshot, function) catch |err| {
        diagnostics.recordPhase(@errorName(err), "function planning");
        return err;
    };
    defer plan.deinit();

    const slots = try allocator.alloc(ValueSlot, function.instruction_count);
    defer allocator.free(slots);
    @memset(slots, .{});
    const builtin_number_sources = try allocator.alloc(u32, function.instruction_count);
    defer allocator.free(builtin_number_sources);
    @memset(builtin_number_sources, std.math.maxInt(u32));
    const coverage_site_ids = try allocator.alloc(u32, function.instruction_count);
    defer allocator.free(coverage_site_ids);
    @memset(coverage_site_ids, snapshot_v1.no_id);
    var coverage_site_count: u32 = 0;
    var coverage_instruction_id: u32 = 0;
    while (coverage_instruction_id < function.instruction_count) : (coverage_instruction_id += 1) {
        const instruction_value = try snapshot.irInstruction(function, coverage_instruction_id);
        if (instruction_value.command == .coverage) {
            coverage_site_ids[coverage_instruction_id] = coverage_site_count;
            coverage_site_count = std.math.add(u32, coverage_site_count, 1) catch return Error.ResourceLimit;
        }
    }

    var locals: std.ArrayList(wasm.Local) = .empty;
    defer locals.deinit(allocator);
    try locals.append(allocator, .{ .count = 5, .value_type = .i32 });
    var next_local: u32 = 7; // parameters 0/1; base, dispatcher, helper status, continuation, table index are 2..6.

    var instruction_id: u32 = 0;
    while (instruction_id < function.instruction_count) : (instruction_id += 1) {
        const instruction_value = try snapshot.irInstruction(function, instruction_id);
        const shape = continuations.resultShape(instruction_value.command);
        slots[instruction_id].shape = shape;
        switch (shape) {
            .none => {},
            .i32 => {
                if (next_local >= max_lowered_locals)
                    return Error.ResourceLimit;
                slots[instruction_id].first = next_local;
                next_local += 1;
                try locals.append(allocator, .{ .count = 1, .value_type = .i32 });
            },
            .pointer => {
                if (next_local >= max_lowered_locals)
                    return Error.ResourceLimit;
                slots[instruction_id].first = next_local;
                next_local += 1;
                try locals.append(allocator, .{ .count = 1, .value_type = .i32 });
            },
            .i64 => {
                if (next_local >= max_lowered_locals)
                    return Error.ResourceLimit;
                slots[instruction_id].first = next_local;
                next_local += 1;
                try locals.append(allocator, .{ .count = 1, .value_type = .i64 });
            },
            .f32 => {
                if (next_local >= max_lowered_locals)
                    return Error.ResourceLimit;
                slots[instruction_id].first = next_local;
                next_local += 1;
                try locals.append(allocator, .{ .count = 1, .value_type = .f32 });
            },
            .f64 => {
                if (next_local >= max_lowered_locals)
                    return Error.ResourceLimit;
                slots[instruction_id].first = next_local;
                next_local += 1;
                try locals.append(allocator, .{ .count = 1, .value_type = .f64 });
            },
            .tvalue => {
                if (next_local > max_lowered_locals - 2)
                    return Error.ResourceLimit;
                slots[instruction_id].first = next_local;
                slots[instruction_id].second = next_local + 1;
                next_local += 2;
                try locals.append(allocator, .{ .count = 2, .value_type = .i64 });
            },
        }
    }

    var body = try wasm.Body.init(allocator, locals.items);
    defer body.deinit(allocator);
    var context = Context{
        .allocator = allocator,
        .snapshot = snapshot,
        .proto = proto,
        .function = function,
        .plan = &plan,
        .slots = slots,
        .builtin_number_sources = builtin_number_sources,
        .coverage_site_ids = coverage_site_ids,
        .body = &body,
        .return_ = imports.return_,
        .interrupt = imports.interrupt,
        .coverage_hit = imports.coverage_hit,
        .do_arith = imports.do_arith,
        .compare_any = imports.compare_any,
        .dupclosure = imports.dupclosure,
        .dupclosure_capture = imports.dupclosure_capture,
        .newclosure_empty = imports.newclosure_empty,
        .newclosure_capture = imports.newclosure_capture,
        .get_upvalue = imports.get_upvalue,
        .set_upvalue = imports.set_upvalue,
        .close_upvalues = imports.close_upvalues,
        .call = imports.call,
        .exchange_continuation = imports.exchange_continuation,
        .set_location = imports.set_location,
        .new_table = imports.new_table,
        .new_table_deferred = imports.new_table_deferred,
        .check_gc = imports.check_gc,
        .new_userdata = imports.new_userdata,
        .check_userdata_tag = imports.check_userdata_tag,
        .barrier_object = imports.barrier_object,
        .barrier_table_back = imports.barrier_table_back,
        .barrier_table_forward = imports.barrier_table_forward,
        .hash_node_addr = imports.hash_node_addr,
        .slot_node_addr = imports.slot_node_addr,
        .node_slot_match = imports.node_slot_match,
        .try_get_tm = imports.try_get_tm,
        .check_node_no_next = imports.check_node_no_next,
        .check_node_value = imports.check_node_value,
        .closure_matches_proto_id = imports.closure_matches_proto_id,
        .check_readonly = imports.check_readonly,
        .load_constant = imports.load_constant,
        .dup_table = imports.dup_table,
        .table_insert_append = imports.table_insert_append,
        .namecall_plain = imports.namecall_plain,
        .set_list = imports.set_list,
        .array_set = imports.array_set,
        .array_get = imports.array_get,
        .table_len = imports.table_len,
        .concat = imports.concat,
        .do_len = imports.do_len,
        .forg_prep = imports.forg_prep,
        .forg_loop = imports.forg_loop,
        .forg_loop_call = imports.forg_loop_call,
        .forg_loop_finish = imports.forg_loop_finish,
        .forgprep_xnext_fallback = imports.forgprep_xnext_fallback,
        .table_set_string = imports.table_set_string,
        .table_get_string = imports.table_get_string,
        .table_set = imports.table_set,
        .table_get = imports.table_get,
        .table_set_number = imports.table_set_number,
        .table_get_number = imports.table_get_number,
        .table_array_set = imports.table_array_set,
        .table_array_get = imports.table_array_get,
        .get_global = imports.get_global,
        .set_global = imports.set_global,
        .check_safe_env = imports.check_safe_env,
        .fastcall = imports.fastcall,
        .type_name = imports.type_name,
        .builtin_type_error = imports.builtin_type_error,
        .builtin_number = imports.builtin_number,
        .forn_prepare = imports.forn_prepare,
        .buffer_bounds_error = imports.buffer_bounds_error,
        .libm = imports.libm,
        .prep_varargs = imports.prep_varargs,
        .get_varargs_fixed = imports.get_varargs_fixed,
        .get_varargs_multret = imports.get_varargs_multret,
        .require_static = imports.require_static,
        .static_package = static_package,
        .function_id_base = function_id_base,
        .proto_id_by_bytecode_id = proto_id_by_bytecode_id,
        .base_local = 2,
        .dispatch_local = 3,
        .status_local = 4,
        .continuation_local = 5,
        .table_index_local = 6,
        .call_continuations = &.{},
        .continuation_indices = &.{},
        .string_keys = string_keys,
    };
    context.classifyBuiltinNumberLoads() catch |err| {
        diagnostics.recordPhase(@errorName(err), "value classification");
        return err;
    };
    const call_continuations = continuations.collectCallContinuations(allocator, context) catch |err| {
        diagnostics.recordPhase(@errorName(err), "continuation planning");
        return err;
    };
    defer allocator.free(call_continuations);
    context.call_continuations = call_continuations;
    const continuation_indices = try allocator.alloc(u32, function.instruction_count);
    defer allocator.free(continuation_indices);
    @memset(continuation_indices, snapshot_v1.no_id);
    for (call_continuations, 0..) |continuation, index| {
        if (continuation.instruction_id >= continuation_indices.len or
            continuation_indices[continuation.instruction_id] != snapshot_v1.no_id)
            return Error.UnsupportedControlFlow;
        continuation_indices[continuation.instruction_id] = std.math.cast(u32, index) orelse
            return Error.ResourceLimit;
    }
    context.continuation_indices = continuation_indices;
    if (call_continuations.len == 0 and context.exchange_continuation != null)
        context.exchange_continuation = null;
    if (call_continuations.len != 0 and context.exchange_continuation == null)
        return Error.UnsupportedCommand;

    var block_id: u32 = 0;
    while (block_id < function.block_count) : (block_id += 1) {
        const block = try snapshot.irBlock(function, block_id);
        if (block.kind == .fallback and try context.supportsArithmeticFallback(block)) {
            if (context.do_arith == null)
                return Error.UnsupportedCommand;
        } else if (block.kind == .fallback and
            ((try context.supportsComparisonFallback(block)) or (try context.supportsMaterializedComparisonFallback(block))))
        {
            if (context.compare_any == null)
                return Error.UnsupportedCommand;
        }
    }

    try context.emitReloadBase();
    if (call_continuations.len == 0) {
        try body.i32Const(allocator, @intCast(function.entry_block));
        try body.localSet(allocator, context.dispatch_local);
    } else {
        try context.emitExchangeContinuation(0);
        try body.localTee(allocator, context.continuation_local);
        try body.i32Eqz(allocator);
        try body.ifVoid(allocator);
        try body.i32Const(allocator, @intCast(function.entry_block));
        try body.localSet(allocator, context.dispatch_local);
        try body.else_(allocator);
        try body.localGet(allocator, context.continuation_local);
        try body.i32Const(allocator, @intCast(function.block_count));
        try body.opcode(allocator, 0x6a); // i32.add
        try body.localSet(allocator, context.dispatch_local);
        try body.end(allocator);
    }
    try body.loop(allocator);

    block_id = 0;
    while (block_id < function.block_count) : (block_id += 1) {
        const block = try snapshot.irBlock(function, block_id);
        const bypassed = if (block.kind == .fallback and try context.supportsOrdinaryCallFallback(block))
            false
        else
            context.isBypassedEmissionBlock(block_id, block) catch |err| {
                diagnostics.recordBlock(@errorName(err), block_id);
                return err;
            };
        if (block.kind.isCompilable() and !block.isEmpty() and !bypassed)
            context.emitBlock(block_id, block) catch |err| {
                diagnostics.recordBlock(@errorName(err), block_id);
                return err;
            }
        else if (block.kind == .fallback and !bypassed and try context.supportsFallback(block))
            context.emitBlock(block_id, block) catch |err| {
                diagnostics.recordBlock(@errorName(err), block_id);
                return err;
            };
    }
    for (call_continuations) |continuation|
        try context.emitCallContinuation(continuation);

    // Reaching the bottom means a malformed/generated dispatch target escaped static validation.
    try context.emitStatusReturn(status_internal_error);
    try body.end(allocator);
    try body.i32Const(allocator, status_internal_error);
    try body.finish(allocator);

    return object.defineFunction(symbol_name, imports.generated_type, wasm.symbol.visibility_hidden, body);
}

fn buildProtoIdentityMap(allocator: std.mem.Allocator, snapshot: snapshot_v1.Snapshot) Error![]u32 {
    const map = try allocator.alloc(u32, snapshot.header.proto_count);
    errdefer allocator.free(map);
    @memset(map, snapshot_v1.no_id);

    var proto_id: u32 = 0;
    while (proto_id < snapshot.header.proto_count) : (proto_id += 1) {
        const proto = try snapshot.proto(proto_id);
        if (proto.bytecode_id >= snapshot.header.proto_count or
            proto.fun_id != proto.bytecode_id + 1 or
            map[proto.bytecode_id] != snapshot_v1.no_id)
            return Error.InvalidProto;
        map[proto.bytecode_id] = proto_id;
    }
    for (map) |mapped_proto_id|
        if (mapped_proto_id == snapshot_v1.no_id)
            return Error.InvalidProto;
    return map;
}

pub fn build(allocator: std.mem.Allocator, snapshot_bytes: []const u8, function_id: u32) Error![]u8 {
    diagnostics.reset();
    diagnostics.enterFunction(function_id);
    const snapshot = try snapshot_v1.parse(snapshot_bytes, snapshot_v1.production_identity);
    try snapshot_v1.validateModel(snapshot);
    if (function_id >= snapshot.header.ir_function_count)
        return Error.FunctionOutOfBounds;
    const proto_id_by_bytecode_id = try buildProtoIdentityMap(allocator, snapshot);
    defer allocator.free(proto_id_by_bytecode_id);

    var needs = runtime_imports.ImportNeeds{};
    runtime_imports.scanImportNeeds(snapshot, function_id, false, &needs) catch |err| {
        diagnostics.recordPhase(@errorName(err), "runtime import planning");
        return err;
    };
    var object = wasm.Object.init(allocator);
    defer object.deinit();
    var string_keys = StringKeyPool{};
    defer string_keys.deinit(allocator);
    const imports = try runtime_imports.addRuntimeImports(&object, needs);
    _ = try lowerFunction(allocator, snapshot, function_id, &object, imports, generated_symbol, null, 0, proto_id_by_bytecode_id, &string_keys);
    try emitStringKeyData(&object, string_keys);
    return object.emit();
}

pub fn buildPackage(allocator: std.mem.Allocator, snapshot_bytes: []const u8) Error![]u8 {
    diagnostics.reset();
    const snapshot = try snapshot_v1.parse(snapshot_bytes, snapshot_v1.production_identity);
    try snapshot_v1.validateModel(snapshot);
    const proto_id_by_bytecode_id = try buildProtoIdentityMap(allocator, snapshot);
    defer allocator.free(proto_id_by_bytecode_id);

    var needs = runtime_imports.ImportNeeds{};
    var function_id: u32 = 0;
    while (function_id < snapshot.header.ir_function_count) : (function_id += 1)
        try runtime_imports.scanImportNeeds(snapshot, function_id, false, &needs);

    var object = wasm.Object.init(allocator);
    defer object.deinit();
    var string_keys = StringKeyPool{};
    defer string_keys.deinit(allocator);
    const imports = try runtime_imports.addRuntimeImports(&object, needs);

    function_id = 0;
    while (function_id < snapshot.header.ir_function_count) : (function_id += 1) {
        const symbol_name = try std.fmt.allocPrint(allocator, "luauc_runtime_v1_function_{d:0>8}", .{function_id});
        defer allocator.free(symbol_name);
        _ = try lowerFunction(allocator, snapshot, function_id, &object, imports, symbol_name, null, 0, proto_id_by_bytecode_id, &string_keys);
    }
    try emitStringKeyData(&object, string_keys);
    return object.emit();
}

fn emitStringKeyData(object: *wasm.Object, string_keys: StringKeyPool) Error!void {
    if (string_keys.entries.items.len == 0)
        return;
    const data = try object.defineData(
        ".rodata.luauc_runtime_v1_string_keys",
        generated_string_keys_symbol,
        wasm.symbol.visibility_hidden,
        0,
        string_keys.bytes.items,
    );
    if (data.segment_index != 0)
        return Error.UnsupportedControlFlow;
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

const ProtoConstantSpan = struct {
    constant_offset: u32 = 0,
    constant_count: u32 = 0,
    item_offset: u32 = 0,
    item_count: u32 = 0,
};

const ProtoCoverageSpan = struct {
    byte_offset: u32 = 0,
    site_count: u32 = 0,
    line_count: u32 = 0,
};

const ConstantStringRelocation = struct {
    descriptor_offset: u32,
    string_offset: u32,
};

fn appendProtoConstantMetadata(
    allocator: std.mem.Allocator,
    snapshot: snapshot_v1.Snapshot,
    proto: snapshot_v1.Proto,
    function_id_base: u32,
    constant_bytes: *std.ArrayList(u8),
    item_bytes: *std.ArrayList(u8),
    constant_strings: *StringKeyPool,
    string_relocations: *std.ArrayList(ConstantStringRelocation),
) Error!ProtoConstantSpan {
    if (constant_bytes.items.len > std.math.maxInt(u32) or item_bytes.items.len > std.math.maxInt(u32))
        return Error.ResourceLimit;
    const constant_offset: u32 = @intCast(constant_bytes.items.len);
    const item_offset: u32 = @intCast(item_bytes.items.len);
    var local_item_count: u32 = 0;

    var constant_id: u32 = 0;
    while (constant_id < proto.vm_constant_count) : (constant_id += 1) {
        const constant = try snapshot.vmConstant(proto, constant_id);
        const descriptor_offset_usize = constant_bytes.items.len;
        try constant_bytes.appendNTimes(allocator, 0, aot_constant_size);
        const descriptor = constant_bytes.items[descriptor_offset_usize..][0..aot_constant_size];
        descriptor[0] = @intFromEnum(constant.kind);
        switch (constant.kind) {
            .nil => {},
            .boolean => writeU32(descriptor, 4, constant.payload0),
            .number, .integer => {
                writeU32(descriptor, 4, @truncate(constant.bits0));
                writeU32(descriptor, 8, @truncate(constant.bits0 >> 32));
            },
            .vector => {
                writeU32(descriptor, 4, constant.payload0);
                writeU32(descriptor, 8, constant.payload1);
                writeU32(descriptor, 12, constant.payload2);
            },
            .string => {
                const value = try snapshot.string(constant.payload0);
                const entry = try constant_strings.intern(allocator, value);
                writeU32(descriptor, 8, entry.length);
                try string_relocations.append(allocator, .{
                    .descriptor_offset = @intCast(descriptor_offset_usize + 4),
                    .string_offset = entry.offset,
                });
            },
            .table => {
                writeU32(descriptor, 4, local_item_count);
                writeU32(descriptor, 8, constant.payload1);
                var item_id: u32 = 0;
                while (item_id < constant.payload1) : (item_id += 1) {
                    const item = try snapshot.vmConstantItem(std.math.add(u32, constant.payload0, item_id) catch
                        return Error.ResourceLimit);
                    const item_record_offset = item_bytes.items.len;
                    try item_bytes.appendNTimes(allocator, 0, aot_constant_item_size);
                    const item_record = item_bytes.items[item_record_offset..][0..aot_constant_item_size];
                    writeU32(item_record, 0, item.key);
                    writeU32(item_record, 4, item.value);
                }
                local_item_count = std.math.add(u32, local_item_count, constant.payload1) catch return Error.ResourceLimit;
            },
            .closure => {
                const child_proto_id = constant.closureProtoId() orelse return Error.InvalidOperandType;
                const function_id = std.math.add(u32, function_id_base, child_proto_id) catch
                    return Error.ResourceLimit;
                writeU32(descriptor, 4, function_id);
            },
            .import, .class_shape => {},
        }
    }

    return .{
        .constant_offset = constant_offset,
        .constant_count = proto.vm_constant_count,
        .item_offset = item_offset,
        .item_count = local_item_count,
    };
}

fn appendProtoCoverageMetadata(
    allocator: std.mem.Allocator,
    snapshot: snapshot_v1.Snapshot,
    proto: snapshot_v1.Proto,
    bytes: *std.ArrayList(u8),
) Error!ProtoCoverageSpan {
    if (bytes.items.len > std.math.maxInt(u32))
        return Error.ResourceLimit;
    const byte_offset: u32 = @intCast(bytes.items.len);
    const function = try snapshot.irFunction(proto.id);
    if (function.proto_id != proto.id)
        return Error.UnsupportedControlFlow;
    var site_count: u32 = 0;
    var line_count: u32 = 0;
    var instruction_id: u32 = 0;
    while (instruction_id < function.instruction_count) : (instruction_id += 1) {
        const instruction_value = try snapshot.irInstruction(function, instruction_id);
        if (instruction_value.command != .coverage)
            continue;
        if (instruction_value.operand_count != 1)
            return Error.InvalidOperandCount;
        const pc_operand = try snapshot.irOperand(instruction_value, 0);
        if (pc_operand.kind != .constant)
            return Error.InvalidOperandType;
        const pc = (try snapshot.irConstant(function, pc_operand.value)).uintValue() orelse
            return Error.InvalidOperandType;
        if (pc >= proto.code_count)
            return Error.UnsupportedControlFlow;
        const line = try snapshot.sourceLine(proto, pc);
        const offset = bytes.items.len;
        try bytes.appendNTimes(allocator, 0, aot_coverage_site_size);
        writeU32(bytes.items[offset..][0..aot_coverage_site_size], 0, line);
        line_count = @max(line_count, std.math.add(u32, line, 1) catch return Error.ResourceLimit);
        site_count = std.math.add(u32, site_count, 1) catch return Error.ResourceLimit;
    }
    return .{ .byte_offset = byte_offset, .site_count = site_count, .line_count = line_count };
}

fn emitStaticPackageMetadata(
    allocator: std.mem.Allocator,
    object: *wasm.Object,
    package: static_package_v1.Package,
    function_bases: []const u32,
    function_refs: []const wasm.FunctionRef,
) Error!void {
    const proto_bytes_size = std.math.mul(usize, function_refs.len, aot_proto_size) catch return Error.ResourceLimit;
    var proto_bytes = try allocator.alloc(u8, proto_bytes_size);
    defer allocator.free(proto_bytes);
    @memset(proto_bytes, 0);

    const proto_spans = try allocator.alloc(ProtoConstantSpan, function_refs.len);
    defer allocator.free(proto_spans);
    @memset(proto_spans, .{});
    const coverage_spans = try allocator.alloc(ProtoCoverageSpan, function_refs.len);
    defer allocator.free(coverage_spans);
    @memset(coverage_spans, .{});
    var constant_bytes: std.ArrayList(u8) = .empty;
    defer constant_bytes.deinit(allocator);
    var item_bytes: std.ArrayList(u8) = .empty;
    defer item_bytes.deinit(allocator);
    var coverage_bytes: std.ArrayList(u8) = .empty;
    defer coverage_bytes.deinit(allocator);
    var constant_strings = StringKeyPool{};
    defer constant_strings.deinit(allocator);
    var string_relocations: std.ArrayList(ConstantStringRelocation) = .empty;
    defer string_relocations.deinit(allocator);
    var module_sources = StringKeyPool{};
    defer module_sources.deinit(allocator);
    const module_source_offsets = try allocator.alloc(u32, @intCast(package.module_count));
    defer allocator.free(module_source_offsets);

    const module_bytes_size = std.math.mul(usize, @as(usize, @intCast(package.module_count)), aot_module_size) catch return Error.ResourceLimit;
    var module_bytes = try allocator.alloc(u8, module_bytes_size);
    defer allocator.free(module_bytes);
    @memset(module_bytes, 0);

    var module_id: u32 = 0;
    while (module_id < package.module_count) : (module_id += 1) {
        const module = try package.module(module_id);
        const snapshot = try snapshot_v1.parse(module.snapshot, snapshot_v1.production_identity);
        const function_base = function_bases[@intCast(module_id)];

        var local_id: u32 = 0;
        while (local_id < snapshot.header.proto_count) : (local_id += 1) {
            const proto = try snapshot.proto(local_id);
            const global_id = std.math.add(u32, function_base, local_id) catch return Error.ResourceLimit;
            const record_offset = std.math.mul(usize, @as(usize, @intCast(global_id)), aot_proto_size) catch return Error.ResourceLimit;
            const record = proto_bytes[record_offset..][0..aot_proto_size];
            writeU32(record, 0, aot_abi_version);
            writeU32(record, 4, aot_proto_size);
            @memcpy(record[8..40], &aot_layout_sha256);
            writeU32(record, 40, std.math.add(u32, global_id, 1) catch return Error.ResourceLimit);
            writeU32(record, 44, global_id);
            writeU32(record, 48, if (proto.parent_id == snapshot_v1.no_id)
                snapshot_v1.no_id
            else
                std.math.add(u32, function_base, proto.parent_id) catch return Error.ResourceLimit);
            writeU32(record, 52, if (proto.parent_id == snapshot_v1.no_id) aot_proto_root_flag else 0);
            record[56] = proto.num_params;
            record[57] = proto.nups;
            record[58] = @intFromBool(proto.is_vararg);
            record[59] = proto.max_stack_size;
            proto_spans[@intCast(global_id)] = try appendProtoConstantMetadata(
                allocator,
                snapshot,
                proto,
                function_base,
                &constant_bytes,
                &item_bytes,
                &constant_strings,
                &string_relocations,
            );
            writeU32(record, 64, proto.vm_constant_count);
            writeU32(record, 72, proto_spans[@intCast(global_id)].item_count);
            coverage_spans[@intCast(global_id)] = try appendProtoCoverageMetadata(
                allocator,
                snapshot,
                proto,
                &coverage_bytes,
            );
            writeU32(record, 80, coverage_spans[@intCast(global_id)].site_count);
            writeU32(record, 84, coverage_spans[@intCast(global_id)].line_count);
        }

        const module_record_offset = std.math.mul(usize, @as(usize, @intCast(module_id)), aot_module_size) catch return Error.ResourceLimit;
        const module_record = module_bytes[module_record_offset..][0..aot_module_size];
        writeU32(module_record, 0, aot_abi_version);
        writeU32(module_record, 4, aot_module_size);
        @memcpy(module_record[8..40], &aot_layout_sha256);
        writeU32(module_record, 40, module_id);
        writeU32(module_record, 44, std.math.add(u32, function_base, snapshot.header.root_proto_id) catch return Error.ResourceLimit);
        const source = try module_sources.intern(allocator, module.source_name);
        module_source_offsets[@intCast(module_id)] = source.offset;
        writeU32(module_record, 52, source.length);
    }

    const data_flags = wasm.symbol.visibility_hidden;
    const constant_strings_data = if (constant_strings.entries.items.len != 0)
        try object.defineData(
            ".rodata.luauc_runtime_v1_constant_strings",
            "luauc_runtime_v1_constant_strings",
            data_flags,
            0,
            constant_strings.bytes.items,
        )
    else
        null;
    const constants_data = if (constant_bytes.items.len != 0)
        try object.defineData(
            ".rodata.luauc_runtime_v1_constants",
            "luauc_runtime_v1_constants",
            data_flags,
            2,
            constant_bytes.items,
        )
    else
        null;
    const items_data = if (item_bytes.items.len != 0)
        try object.defineData(
            ".rodata.luauc_runtime_v1_constant_items",
            "luauc_runtime_v1_constant_items",
            data_flags,
            2,
            item_bytes.items,
        )
    else
        null;
    const coverage_data = if (coverage_bytes.items.len != 0)
        try object.defineData(
            ".rodata.luauc_runtime_v1_coverage_sites",
            "luauc_runtime_v1_coverage_sites",
            data_flags,
            2,
            coverage_bytes.items,
        )
    else
        null;
    const protos = try object.defineData(
        ".rodata.luauc_runtime_v1_protos",
        generated_protos_symbol,
        data_flags,
        2,
        proto_bytes,
    );
    const module_source_data = try object.defineData(
        ".rodata.luauc_runtime_v1_module_sources",
        "luauc_runtime_v1_module_sources",
        data_flags,
        0,
        module_sources.bytes.items,
    );
    const modules = try object.defineData(
        ".rodata.luauc_runtime_v1_modules",
        generated_modules_symbol,
        data_flags,
        2,
        module_bytes,
    );

    var program_bytes = [_]u8{0} ** aot_program_size;
    writeU32(&program_bytes, 0, aot_abi_version);
    writeU32(&program_bytes, 4, aot_program_size);
    @memcpy(program_bytes[8..40], &aot_layout_sha256);
    writeU32(&program_bytes, 40, protos.memory_offset);
    writeU32(&program_bytes, 44, @intCast(function_refs.len));
    const entry_module = try package.module(package.entry_module_id);
    const entry_snapshot = try snapshot_v1.parse(entry_module.snapshot, snapshot_v1.production_identity);
    writeU32(
        &program_bytes,
        48,
        std.math.add(u32, function_bases[@intCast(package.entry_module_id)], entry_snapshot.header.root_proto_id) catch return Error.ResourceLimit,
    );
    writeU32(&program_bytes, 56, modules.memory_offset);
    writeU32(&program_bytes, 60, package.module_count);
    writeU32(&program_bytes, 64, package.entry_module_id);
    const program = try object.defineData(
        ".rodata.luauc_runtime_v1_program",
        generated_program_symbol,
        0,
        2,
        &program_bytes,
    );

    for (function_refs, 0..) |function_ref, global_id| {
        const record_offset = std.math.mul(u32, @intCast(global_id), aot_proto_size) catch return Error.ResourceLimit;
        try object.relocateDataTableIndex(protos, record_offset + 40, function_ref);
        const span = proto_spans[global_id];
        if (span.constant_count != 0)
            try object.relocateDataMemoryAddress(
                protos,
                record_offset + 60,
                constants_data.?,
                std.math.cast(i32, span.constant_offset) orelse return Error.ResourceLimit,
            );
        if (span.item_count != 0)
            try object.relocateDataMemoryAddress(
                protos,
                record_offset + 68,
                items_data.?,
                std.math.cast(i32, span.item_offset) orelse return Error.ResourceLimit,
            );
        const coverage = coverage_spans[global_id];
        if (coverage.site_count != 0)
            try object.relocateDataMemoryAddress(
                protos,
                record_offset + 76,
                coverage_data.?,
                std.math.cast(i32, coverage.byte_offset) orelse return Error.ResourceLimit,
            );
    }
    if (constants_data) |data|
        for (string_relocations.items) |relocation|
            try object.relocateDataMemoryAddress(
                data,
                relocation.descriptor_offset,
                constant_strings_data orelse return Error.UnsupportedControlFlow,
                std.math.cast(i32, relocation.string_offset) orelse return Error.ResourceLimit,
            );
    module_id = 0;
    while (module_id < package.module_count) : (module_id += 1) {
        const record_offset = std.math.mul(u32, module_id, aot_module_size) catch return Error.ResourceLimit;
        try object.relocateDataMemoryAddress(
            modules,
            record_offset + 48,
            module_source_data,
            std.math.cast(i32, module_source_offsets[@intCast(module_id)]) orelse return Error.ResourceLimit,
        );
    }
    try object.relocateDataMemoryAddress(program, 40, protos, 0);
    try object.relocateDataMemoryAddress(program, 56, modules, 0);
}

pub fn buildStaticPackage(allocator: std.mem.Allocator, package_bytes: []const u8) Error![]u8 {
    diagnostics.reset();
    const package = try static_package_v1.parse(package_bytes);
    const function_bases = try allocator.alloc(u32, @intCast(package.module_count));
    defer allocator.free(function_bases);

    var needs = runtime_imports.ImportNeeds{};
    var total_functions: u32 = 0;
    var module_id: u32 = 0;
    while (module_id < package.module_count) : (module_id += 1) {
        const module = try package.module(module_id);
        const snapshot = try snapshot_v1.parse(module.snapshot, snapshot_v1.production_identity);
        try snapshot_v1.validateModel(snapshot);
        function_bases[@intCast(module_id)] = total_functions;
        total_functions = std.math.add(u32, total_functions, snapshot.header.ir_function_count) catch return Error.ResourceLimit;

        var function_id: u32 = 0;
        while (function_id < snapshot.header.ir_function_count) : (function_id += 1) {
            try runtime_imports.scanImportNeeds(snapshot, function_id, true, &needs);
        }
    }
    if (total_functions == 0)
        return Error.UnsupportedControlFlow;

    var object = wasm.Object.init(allocator);
    defer object.deinit();
    var string_keys = StringKeyPool{};
    defer string_keys.deinit(allocator);
    const imports = try runtime_imports.addRuntimeImports(&object, needs);
    const function_refs = try allocator.alloc(wasm.FunctionRef, @intCast(total_functions));
    defer allocator.free(function_refs);

    module_id = 0;
    while (module_id < package.module_count) : (module_id += 1) {
        const module = try package.module(module_id);
        const snapshot = try snapshot_v1.parse(module.snapshot, snapshot_v1.production_identity);
        const function_base = function_bases[@intCast(module_id)];
        const proto_id_by_bytecode_id = try buildProtoIdentityMap(allocator, snapshot);
        defer allocator.free(proto_id_by_bytecode_id);
        var function_id: u32 = 0;
        while (function_id < snapshot.header.ir_function_count) : (function_id += 1) {
            const global_function_id = std.math.add(u32, function_base, function_id) catch return Error.ResourceLimit;
            const symbol_name = try std.fmt.allocPrint(allocator, "luauc_runtime_v1_function_{d:0>8}", .{global_function_id});
            defer allocator.free(symbol_name);
            function_refs[@intCast(global_function_id)] = try lowerFunction(
                allocator,
                snapshot,
                function_id,
                &object,
                imports,
                symbol_name,
                package,
                function_base,
                proto_id_by_bytecode_id,
                &string_keys,
            );
        }
    }
    try emitStringKeyData(&object, string_keys);
    try emitStaticPackageMetadata(allocator, &object, package, function_bases, function_refs);
    return object.emit();
}

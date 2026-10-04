const std = @import("std");
const builtin = @import("builtin");
const lower = @import("luauc_backend");
const linker = @import("luauc_linker");
const runtime_profile = @import("luauc_runtime_profile_v1");
const source_package = @import("luauc_source_package_v1");
const compiler_result = @import("luauc_compiler_result_v1");
const snapshot_v1 = @import("frontend_snapshot_v1");
const compiler_build = @import("compiler_build_digest.zig");

const FrontendResult = extern struct {
    data: ?[*]u8 = null,
    size: usize = 0,
    diagnostic: ?[*]u8 = null,
    diagnostic_size: usize = 0,
    status: u32 = 0,
};

extern fn luauc_frontend_snapshot_v1_compile(source: [*]const u8, source_size: usize, chunk_name: [*]const u8, chunk_name_size: usize, coverage_level: u32, result: *FrontendResult) u32;
extern fn luauc_frontend_snapshot_v1_compile_inlined(source: [*]const u8, source_size: usize, chunk_name: [*]const u8, chunk_name_size: usize, coverage_level: u32, plans: [*]const source_package.InlinePlan, plan_count: u32, result: *FrontendResult) u32;
extern fn luauc_frontend_snapshot_v1_free(result: *FrontendResult) void;

const ContextResult = extern struct {
    handle: u32 = 0,
    status: u32 = 0,
    runtime_profile_sha256: [32]u8 = .{0} ** 32,
    runtime_pack_sha256: [32]u8 = .{0} ** 32,
};

const CompileResult = compiler_result.CompileResultV1;

const Description = extern struct {
    abi_version: u32 = 1,
    description_size: u32 = @sizeOf(Description),
    context_result_size: u32 = @sizeOf(ContextResult),
    compile_result_size: u32 = @sizeOf(CompileResult),
    max_contexts: u32 = max_contexts,
    max_profile_bytes: u32 = max_profile_bytes,
    max_pack_bytes: u32 = max_pack_bytes,
    reserved: u32 = 0,
};

comptime {
    // FrontendResult matches LuaucFrontendSnapshotV1Result: pointers and size_t follow the target.
    const frontend_result_size: comptime_int = if (builtin.cpu.arch == .wasm32) 20 else 40;
    if (@sizeOf(FrontendResult) != frontend_result_size or @sizeOf(ContextResult) != 72 or @sizeOf(CompileResult) != 320 or @sizeOf(Description) != 32)
        @compileError("luauc compiler ABI layout drift");
}

const allocator = if (builtin.cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.c_allocator;
const status_ok: u32 = 0;
const status_invalid_argument: u32 = 1;
const status_invalid_request: u32 = 2;
const status_frontend_failure: u32 = 3;
const status_backend_failure: u32 = 4;
const status_link_failure: u32 = 5;
const status_resource_limit: u32 = 6;
const status_invalid_context: u32 = 7;
const max_contexts: u32 = 8;
const max_profile_bytes: u32 = 256 * 1024;
const max_pack_bytes: u32 = 32 * 1024 * 1024;

const ContextSlot = struct {
    generation: u16 = 1,
    profile: ?[]u8 = null,
    pack: ?[]u8 = null,
    profile_sha256: [32]u8 = .{0} ** 32,
    pack_sha256: [32]u8 = .{0} ** 32,
};

pub const ContextSession = struct {
    status: u32,
    handle: u32 = 0,
    profile_sha256: [32]u8 = .{0} ** 32,
    pack_sha256: [32]u8 = .{0} ** 32,
};

pub const Guest = struct {
    status: u32 = status_ok,
    diagnostic: []u8 = &.{},
    artifact: []u8 = &.{},
    records: []compiler_result.DiagnosticRecord = &.{},
    request_id: [16]u8 = .{0} ** 16,
    compiler_build_sha256: [32]u8 = .{0} ** 32,
    luau_pin_sha256: [32]u8 = .{0} ** 32,
    runtime_profile_sha256: [32]u8 = .{0} ** 32,
    runtime_pack_sha256: [32]u8 = .{0} ** 32,
    manifest_sha256: [32]u8 = .{0} ** 32,
    generated_object_sha256: [32]u8 = .{0} ** 32,
    artifact_sha256: [32]u8 = .{0} ** 32,
    generated_function_count: u32 = 0,
    generated_data_bytes: u32 = 0,
    import_count: u32 = 0,
    export_count: u32 = 0,
    resource_usage_arena_used: u32 = 0,
    resource_usage_table_entries: u32 = 0,
    resource_usage_output_bytes: u32 = 0,
    resource_usage_compile_instructions: u32 = 0,
    resource_usage_compile_functions: u32 = 0,
    resource_usage_compile_bytes: u32 = 0,
};

pub const buildStaticPackage = lower.buildStaticPackage;

var contexts = [_]ContextSlot{.{}} ** max_contexts;
var constructors_ran = false;

fn ensureConstructors() void {
    if (comptime builtin.cpu.arch != .wasm32) return;
    if (!constructors_ran) {
        constructors_ran = true;
        const call: *const fn () callconv(.c) void = @extern(*const fn () callconv(.c) void, .{ .name = "__wasm_call_ctors" });
        call();
    }
}

pub export fn luauc_v1_describe(result_pointer: u32) u32 {
    ensureConstructors();
    if (result_pointer == 0) return status_invalid_argument;
    const result: *Description = @ptrFromInt(result_pointer);
    result.* = .{};
    return status_ok;
}

pub export fn luauc_v1_alloc(size: u32) u32 {
    ensureConstructors();
    if (size == 0) return 0;
    const allocation = allocator.alloc(u8, size) catch return 0;
    return @intCast(@intFromPtr(allocation.ptr));
}

pub export fn luauc_v1_dealloc(pointer: u32, size: u32) void {
    if (pointer == 0 or size == 0) return;
    const bytes: [*]u8 = @ptrFromInt(pointer);
    allocator.free(bytes[0..size]);
}

fn rangesOverlap(lhs_pointer: u32, lhs_size: u32, rhs_pointer: u32, rhs_size: u32) bool {
    const lhs_end = @as(u64, lhs_pointer) + lhs_size;
    const rhs_end = @as(u64, rhs_pointer) + rhs_size;
    return lhs_pointer < rhs_end and rhs_pointer < lhs_end;
}

fn contextHandle(index: usize, generation: u16) u32 {
    return (@as(u32, generation) << 8) | @as(u32, @intCast(index + 1));
}

fn contextFor(handle: u32) ?*ContextSlot {
    const low = handle & 0xff;
    if (low == 0 or low > max_contexts) return null;
    const slot = &contexts[low - 1];
    if (slot.profile == null or slot.pack == null or slot.generation != @as(u16, @truncate(handle >> 8))) return null;
    return slot;
}

pub fn contextCreate(profile_bytes: []const u8, pack_bytes: []const u8) ContextSession {
    if (profile_bytes.len == 0 or profile_bytes.len > max_profile_bytes or pack_bytes.len == 0 or pack_bytes.len > max_pack_bytes)
        return .{ .status = status_invalid_argument };
    const profile = runtime_profile.parse(profile_bytes) catch return .{ .status = status_invalid_request };
    runtime_profile.validatePackManifest(pack_bytes, profile_bytes) catch return .{ .status = status_invalid_request };
    linker.validateRuntimePack(allocator, pack_bytes, profile, .{}) catch return .{ .status = status_invalid_request };

    var slot_index: ?usize = null;
    for (&contexts, 0..) |*slot, index| if (slot.profile == null) {
        slot_index = index;
        break;
    };
    const index = slot_index orelse return .{ .status = status_resource_limit };
    const owned_profile = allocator.dupe(u8, profile_bytes) catch return .{ .status = status_resource_limit };
    const owned_pack = allocator.dupe(u8, pack_bytes) catch {
        allocator.free(owned_profile);
        return .{ .status = status_resource_limit };
    };
    const slot = &contexts[index];
    slot.profile = owned_profile;
    slot.pack = owned_pack;
    std.crypto.hash.sha2.Sha256.hash(owned_profile, &slot.profile_sha256, .{});
    std.crypto.hash.sha2.Sha256.hash(owned_pack, &slot.pack_sha256, .{});
    return .{
        .status = status_ok,
        .handle = contextHandle(index, slot.generation),
        .profile_sha256 = slot.profile_sha256,
        .pack_sha256 = slot.pack_sha256,
    };
}

pub export fn luauc_v1_context_create(profile_pointer: u32, profile_size: u32, pack_pointer: u32, pack_size: u32, result_pointer: u32) u32 {
    ensureConstructors();
    if (profile_pointer == 0 or profile_size == 0 or profile_size > max_profile_bytes or pack_pointer == 0 or pack_size == 0 or pack_size > max_pack_bytes or result_pointer == 0 or
        rangesOverlap(profile_pointer, profile_size, result_pointer, @sizeOf(ContextResult)) or rangesOverlap(pack_pointer, pack_size, result_pointer, @sizeOf(ContextResult)))
        return status_invalid_argument;
    const result: *ContextResult = @ptrFromInt(result_pointer);
    const profile_input: [*]const u8 = @ptrFromInt(profile_pointer);
    const pack_input: [*]const u8 = @ptrFromInt(pack_pointer);
    const created = contextCreate(profile_input[0..profile_size], pack_input[0..pack_size]);
    result.* = .{
        .handle = created.handle,
        .status = created.status,
        .runtime_profile_sha256 = created.profile_sha256,
        .runtime_pack_sha256 = created.pack_sha256,
    };
    return created.status;
}

pub fn contextDestroy(handle: u32) u32 {
    const slot = contextFor(handle) orelse return status_invalid_context;
    allocator.free(slot.profile.?);
    allocator.free(slot.pack.?);
    slot.profile = null;
    slot.pack = null;
    slot.profile_sha256 = .{0} ** 32;
    slot.pack_sha256 = .{0} ** 32;
    slot.generation +%= 1;
    if (slot.generation == 0) slot.generation = 1;
    return status_ok;
}

pub export fn luauc_v1_context_destroy(handle: u32) u32 {
    return contextDestroy(handle);
}

fn publishDiagnosticRecord(guest: *Guest, status: u32, module_id: u32, ir_command: u32) void {
    if (guest.records.len != 0) {
        allocator.free(guest.records);
        guest.records = &.{};
    }
    const records = allocator.alloc(compiler_result.DiagnosticRecord, 1) catch return;
    records[0] = .{
        .code = status,
        .module_id = module_id,
        .source_start = 0,
        .source_end = 0,
        .ir_command = ir_command,
        .reserved = 0,
    };
    guest.records = records;
}

fn publishDiagnostic(guest: *Guest, status: u32, message: []const u8) void {
    publishDiagnosticFor(guest, status, compiler_result.no_module, 0, message);
}

fn publishDiagnosticFor(guest: *Guest, status: u32, module_id: u32, ir_command: u32, message: []const u8) void {
    guest.status = status;
    publishDiagnosticRecord(guest, status, module_id, ir_command);
    if (message.len == 0 or message.len > std.math.maxInt(u32)) return;
    const owned = allocator.dupe(u8, message) catch {
        guest.status = status_resource_limit;
        return;
    };
    if (guest.diagnostic.len != 0) allocator.free(guest.diagnostic);
    guest.diagnostic = owned;
}

fn featureCount(mask: u32) u32 {
    return @popCount(mask);
}

fn linkLimits(budget_bytes: u32) linker.Limits {
    var limits: linker.Limits = .{};
    const budget: usize = budget_bytes;
    if (budget > limits.max_input_bytes) limits.max_input_bytes = budget;
    if (budget > limits.max_output_bytes) limits.max_output_bytes = budget;
    return limits;
}

fn snapshotCompileUsage(bytes: []const u8) !struct { functions: u32, instructions: u32 } {
    const snapshot = try snapshot_v1.parse(bytes, snapshot_v1.production_identity);
    var instructions: u32 = 0;
    var function_id: u32 = 0;
    while (function_id < snapshot.header.ir_function_count) : (function_id += 1) {
        const function = try snapshot.irFunction(function_id);
        instructions = std.math.add(u32, instructions, function.instruction_count) catch return error.ResourceLimit;
    }
    return .{ .functions = snapshot.header.ir_function_count, .instructions = instructions };
}

fn publishError(guest: *Guest, status: u32, err: anyerror) void {
    publishDiagnostic(guest, status, @errorName(err));
}
fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}
fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}

fn buildSnapshotPackage(package: source_package.Package, frontend_results: []FrontendResult) ![]u8 {
    const header: u32 = 24;
    const record_size: u32 = 24;
    var total = std.math.add(u32, header, std.math.mul(u32, package.module_count, record_size) catch return error.ResourceLimit) catch return error.ResourceLimit;
    for (0..package.module_count) |index| {
        const module = try package.module(@intCast(index));
        const snapshot = frontend_results[index];
        total = std.math.add(u32, total, @intCast(module.name.len)) catch return error.ResourceLimit;
        total = std.math.add(u32, total, @intCast(module.source_name.len)) catch return error.ResourceLimit;
        total = std.math.add(u32, total, @intCast(snapshot.size)) catch return error.ResourceLimit;
    }
    const frame = try allocator.alloc(u8, total);
    errdefer allocator.free(frame);
    @memset(frame, 0);
    @memcpy(frame[0..8], "LUAUCP1\x00");
    writeU16(frame, 8, 1);
    writeU16(frame, 10, @intCast(header));
    writeU32(frame, 12, package.module_count);
    writeU32(frame, 16, package.entry_module_id);
    writeU32(frame, 20, record_size);
    var cursor = header + package.module_count * record_size;
    for (0..package.module_count) |index| {
        const module = try package.module(@intCast(index));
        const snapshot = frontend_results[index];
        const record = header + @as(u32, @intCast(index)) * record_size;
        writeU32(frame, record, cursor);
        writeU32(frame, record + 4, @intCast(module.name.len));
        @memcpy(frame[cursor..][0..module.name.len], module.name);
        cursor += @intCast(module.name.len);
        writeU32(frame, record + 16, cursor);
        writeU32(frame, record + 20, @intCast(module.source_name.len));
        @memcpy(frame[cursor..][0..module.source_name.len], module.source_name);
        cursor += @intCast(module.source_name.len);
        writeU32(frame, record + 8, cursor);
        writeU32(frame, record + 12, @intCast(snapshot.size));
        @memcpy(frame[cursor..][0..snapshot.size], snapshot.data.?[0..snapshot.size]);
        cursor += @intCast(snapshot.size);
    }
    if (cursor != frame.len) return error.InternalLayoutMismatch;
    return frame;
}

fn encodeHostModuleList(profile: runtime_profile.Profile) ![]u8 {
    var size: usize = 16;
    var index: u32 = 0;
    while (index < profile.host_module_count) : (index += 1) {
        const name = try profile.hostModule(index);
        size = std.math.add(usize, size, 4 + name.len) catch return error.OutOfMemory;
    }
    const blob = try allocator.alloc(u8, size);
    @memcpy(blob[0..8], "LUAHC1\x00\x00");
    std.mem.writeInt(u16, blob[8..10], 1, .little);
    std.mem.writeInt(u16, blob[10..12], 16, .little);
    std.mem.writeInt(u32, blob[12..16], profile.host_module_count, .little);
    var cursor: usize = 16;
    index = 0;
    while (index < profile.host_module_count) : (index += 1) {
        const name = try profile.hostModule(index);
        std.mem.writeInt(u32, blob[cursor..][0..4], @intCast(name.len), .little);
        cursor += 4;
        @memcpy(blob[cursor..][0..name.len], name);
        cursor += name.len;
    }
    return blob;
}

fn rejected(guest: *Guest, status: u32, message: []const u8) Guest {
    publishDiagnostic(guest, status, message);
    return guest.*;
}

fn rejectedFor(guest: *Guest, status: u32, module_id: u32, message: []const u8) Guest {
    publishDiagnosticFor(guest, status, module_id, 0, message);
    return guest.*;
}

fn rejectedError(guest: *Guest, status: u32, err: anyerror) Guest {
    publishError(guest, status, err);
    return guest.*;
}

pub fn compile(handle: u32, request: []const u8) Guest {
    var guest: Guest = .{};
    if (request.len == 0) return rejected(&guest, status_invalid_argument, "InvalidArgument");
    const slot = contextFor(handle) orelse return rejected(&guest, status_invalid_context, "InvalidContext");
    const profile = runtime_profile.parse(slot.profile.?) catch return rejected(&guest, status_invalid_context, "InvalidStoredProfile");
    const package = source_package.parse(
        request,
        snapshot_v1.production_identity.frontend_build.?,
        slot.profile_sha256,
        slot.pack_sha256,
    ) catch |err| return rejectedError(&guest, if (err == error.ResourceLimit) status_resource_limit else status_invalid_request, err);
    guest.request_id = package.request_id;
    guest.compiler_build_sha256 = compiler_build.compiler_build_sha256;
    guest.luau_pin_sha256 = snapshot_v1.production_identity.luau_pin.?;
    guest.runtime_profile_sha256 = slot.profile_sha256;
    guest.runtime_pack_sha256 = slot.pack_sha256;
    guest.manifest_sha256 = package.manifest_sha256;

    if (profile.import_count > package.allowed_import_ceiling)
        return rejected(&guest, status_resource_limit, "ResourceLimit");
    if (featureCount(profile.feature_mask) > package.feature_ceiling)
        return rejected(&guest, status_resource_limit, "ResourceLimit");

    const frontend_results = allocator.alloc(FrontendResult, package.module_count) catch return rejected(&guest, status_resource_limit, "frontend result allocation failed");
    defer allocator.free(frontend_results);
    @memset(frontend_results, .{});
    var compiled_count: usize = 0;
    var compile_functions: u32 = 0;
    var compile_instructions: u32 = 0;
    defer for (frontend_results[0..compiled_count]) |*frontend_result| luauc_frontend_snapshot_v1_free(frontend_result);
    for (0..package.module_count) |index| {
        const module = package.module(@intCast(index)) catch |err| return rejectedError(&guest, status_invalid_request, err);
        const frontend_result = &frontend_results[index];
        var inline_plans: ?[]source_package.InlinePlan = null;
        defer if (inline_plans) |plans| allocator.free(plans);
        const frontend_status = if (module.inline_plan_count == 0)
            luauc_frontend_snapshot_v1_compile(module.content.ptr, module.content.len, module.source_name.ptr, module.source_name.len, package.coverage_level, frontend_result)
        else inlined: {
            const plans = allocator.alloc(source_package.InlinePlan, module.inline_plan_count) catch return rejected(&guest, status_resource_limit, "inline plan allocation failed");
            inline_plans = plans;
            for (plans, 0..) |*plan, plan_id|
                plan.* = module.inlinePlan(@intCast(plan_id)) catch |err| return rejectedError(&guest, status_invalid_request, err);
            break :inlined luauc_frontend_snapshot_v1_compile_inlined(module.content.ptr, module.content.len, module.source_name.ptr, module.source_name.len, package.coverage_level, plans.ptr, module.inline_plan_count, frontend_result);
        };
        compiled_count += 1;
        if (frontend_result.size > package.compile_budget_bytes)
            return rejectedFor(&guest, status_resource_limit, @intCast(index), "ResourceLimit");
        if (frontend_status != 0 or frontend_result.status != 0 or frontend_result.data == null or frontend_result.size == 0) {
            const diagnostic = if (frontend_result.diagnostic) |pointer| pointer[0..frontend_result.diagnostic_size] else "frontend compilation failed";
            return rejectedFor(&guest, status_frontend_failure, @intCast(index), diagnostic);
        }
        const usage = snapshotCompileUsage(frontend_result.data.?[0..frontend_result.size]) catch
            return rejectedFor(&guest, status_frontend_failure, @intCast(index), "invalid frontend snapshot");
        compile_functions = std.math.add(u32, compile_functions, usage.functions) catch
            return rejected(&guest, status_resource_limit, "ResourceLimit");
        compile_instructions = std.math.add(u32, compile_instructions, usage.instructions) catch
            return rejected(&guest, status_resource_limit, "ResourceLimit");
        if (compile_functions > package.compile_budget_functions or
            compile_instructions > package.compile_budget_instructions)
            return rejectedFor(&guest, status_resource_limit, @intCast(index), "ResourceLimit");
    }
    const snapshot_package = buildSnapshotPackage(package, frontend_results) catch |err| return rejectedError(&guest, status_resource_limit, err);
    defer allocator.free(snapshot_package);
    const host_module_blob = encodeHostModuleList(profile) catch |err| return rejectedError(&guest, status_resource_limit, err);
    defer allocator.free(host_module_blob);
    const object = buildStaticPackage(allocator, snapshot_package, host_module_blob) catch |err| {
        const diagnostic = lower.diagnostics.published(@errorName(err));
        const failure = if (err == error.OutOfMemory or err == error.ResourceLimit)
            status_resource_limit
        else if (std.mem.startsWith(u8, diagnostic, "InvalidHostModuleList"))
            status_invalid_request
        else
            status_backend_failure;
        return rejected(&guest, failure, diagnostic);
    };
    defer allocator.free(object);
    // The source-package budget is the caller's ceiling. The linker defaults stay
    // in force when that budget is smaller.
    const linked = linker.link(allocator, slot.pack.?, object, profile, linkLimits(package.compile_budget_bytes), .{
        .compiler_build_sha256 = compiler_build.compiler_build_sha256,
        .package_manifest_sha256 = package.manifest_sha256,
    }) catch |err| return rejectedError(&guest, switch (err) {
        error.OutOfMemory, error.ResourceLimit, error.ArenaOverflow, error.TableOverflow => status_resource_limit,
        else => status_link_failure,
    }, err);
    if (linked.bytes.len > std.math.maxInt(u32) or linked.bytes.len > package.compile_budget_bytes) {
        allocator.free(linked.bytes);
        return rejected(&guest, status_resource_limit, "artifact exceeds compile budget");
    }
    if (linked.report.generated_function_count > package.compile_budget_functions) {
        allocator.free(linked.bytes);
        return rejected(&guest, status_resource_limit, "ResourceLimit");
    }
    guest.artifact = linked.bytes;
    guest.generated_object_sha256 = linked.report.package_object_sha256;
    guest.artifact_sha256 = linked.report.output_sha256;
    guest.generated_function_count = linked.report.generated_function_count;
    guest.generated_data_bytes = linked.report.generated_data_bytes;
    guest.import_count = profile.import_count;
    guest.export_count = profile.export_count;
    guest.resource_usage_arena_used = linked.report.generated_data_bytes;
    guest.resource_usage_table_entries = linked.report.final_table_size;
    guest.resource_usage_output_bytes = @intCast(linked.bytes.len);
    guest.resource_usage_compile_instructions = compile_instructions;
    guest.resource_usage_compile_functions = compile_functions;
    guest.resource_usage_compile_bytes = @intCast(request.len);
    guest.status = status_ok;
    return guest;
}

fn storeSlice(bytes: []const u8) struct { pointer: u32, size: u32 } {
    if (bytes.len == 0) return .{ .pointer = 0, .size = 0 };
    return .{
        .pointer = @intCast(@intFromPtr(bytes.ptr)),
        .size = @intCast(bytes.len),
    };
}

pub export fn luauc_v1_compile(handle: u32, request_pointer: u32, request_size: u32, result_pointer: u32) u32 {
    ensureConstructors();
    if (request_pointer == 0 or request_size == 0 or result_pointer == 0 or rangesOverlap(request_pointer, request_size, result_pointer, @sizeOf(CompileResult))) return status_invalid_argument;
    const result: *CompileResult = @ptrFromInt(result_pointer);
    const request_bytes: [*]const u8 = @ptrFromInt(request_pointer);
    const guest = compile(handle, request_bytes[0..request_size]);
    const artifact = storeSlice(guest.artifact);
    const diagnostic = storeSlice(guest.diagnostic);
    const records = storeSlice(std.mem.sliceAsBytes(guest.records));
    result.* = .{
        .data = artifact.pointer,
        .size = artifact.size,
        .diagnostic = diagnostic.pointer,
        .diagnostic_size = diagnostic.size,
        .status = guest.status,
        .request_id = guest.request_id,
        .compiler_build_sha256 = guest.compiler_build_sha256,
        .luau_pin_sha256 = guest.luau_pin_sha256,
        .runtime_profile_sha256 = guest.runtime_profile_sha256,
        .runtime_pack_sha256 = guest.runtime_pack_sha256,
        .manifest_sha256 = guest.manifest_sha256,
        .generated_object_sha256 = guest.generated_object_sha256,
        .artifact_sha256 = guest.artifact_sha256,
        .generated_function_count = guest.generated_function_count,
        .generated_data_bytes = guest.generated_data_bytes,
        .diagnostic_records_ptr = records.pointer,
        .diagnostic_records_count = if (guest.records.len == 0) 0 else @intCast(guest.records.len),
        .diagnostic_records_bytes = if (guest.records.len == 0) 0 else compiler_result.diagnostic_record_size,
        .import_count = guest.import_count,
        .export_count = guest.export_count,
        .resource_usage_arena_used = guest.resource_usage_arena_used,
        .resource_usage_table_entries = guest.resource_usage_table_entries,
        .resource_usage_output_bytes = guest.resource_usage_output_bytes,
        .resource_usage_compile_instructions = guest.resource_usage_compile_instructions,
        .resource_usage_compile_functions = guest.resource_usage_compile_functions,
        .resource_usage_compile_bytes = guest.resource_usage_compile_bytes,
    };
    return guest.status;
}

pub fn freeGuest(guest: *Guest) void {
    if (guest.artifact.len != 0) allocator.free(guest.artifact);
    if (guest.diagnostic.len != 0) allocator.free(guest.diagnostic);
    if (guest.records.len != 0) allocator.free(guest.records);
    guest.* = .{};
}

pub export fn luauc_v1_result_free(result_pointer: u32) void {
    if (result_pointer == 0) return;
    const result: *CompileResult = @ptrFromInt(result_pointer);
    if (result.data != 0 and result.size != 0) {
        const bytes: [*]u8 = @ptrFromInt(result.data);
        allocator.free(bytes[0..result.size]);
    }
    if (result.diagnostic != 0 and result.diagnostic_size != 0) {
        const bytes: [*]u8 = @ptrFromInt(result.diagnostic);
        allocator.free(bytes[0..result.diagnostic_size]);
    }
    if (result.diagnostic_records_ptr != 0 and result.diagnostic_records_count != 0) {
        const records: [*]compiler_result.DiagnosticRecord = @ptrFromInt(result.diagnostic_records_ptr);
        allocator.free(records[0..result.diagnostic_records_count]);
    }
    result.* = .{};
}

const std = @import("std");
const linker = @import("luauc_linker");
const lower = @import("luauc_backend");
const runtime_profile = @import("luauc_runtime_profile_v1");
const source_package = @import("luauc_source_package_v1");

extern fn __wasm_call_ctors() void;

const FrontendResult = extern struct {
    data: ?[*]u8 = null,
    size: usize = 0,
    diagnostic: ?[*]u8 = null,
    diagnostic_size: usize = 0,
    status: u32 = 0,
};

extern fn luauc_frontend_snapshot_v1_compile(source: [*]const u8, source_size: usize, chunk_name: [*]const u8, chunk_name_size: usize, coverage_level: u32, result: *FrontendResult) u32;
extern fn luauc_frontend_snapshot_v1_free(result: *FrontendResult) void;

const ContextResult = extern struct {
    handle: u32 = 0,
    status: u32 = 0,
    runtime_profile_sha256: [32]u8 = .{0} ** 32,
    runtime_pack_sha256: [32]u8 = .{0} ** 32,
};

const CompileResult = extern struct {
    data: u32 = 0,
    size: u32 = 0,
    diagnostic: u32 = 0,
    diagnostic_size: u32 = 0,
    status: u32 = 0,
    reserved: u32 = 0,
    request_id: [16]u8 = .{0} ** 16,
    runtime_profile_sha256: [32]u8 = .{0} ** 32,
    runtime_pack_sha256: [32]u8 = .{0} ** 32,
    manifest_sha256: [32]u8 = .{0} ** 32,
    generated_object_sha256: [32]u8 = .{0} ** 32,
    artifact_sha256: [32]u8 = .{0} ** 32,
    generated_function_count: u32 = 0,
    generated_data_bytes: u32 = 0,
};

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
    if (@sizeOf(FrontendResult) != 20 or @sizeOf(ContextResult) != 72 or @sizeOf(CompileResult) != 208 or @sizeOf(Description) != 32)
        @compileError("luauc compiler ABI layout drift");
}

const allocator = std.heap.wasm_allocator;
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

var contexts = [_]ContextSlot{.{}} ** max_contexts;
var constructors_ran = false;

fn ensureConstructors() void {
    if (!constructors_ran) {
        constructors_ran = true;
        __wasm_call_ctors();
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

pub export fn luauc_v1_context_create(profile_pointer: u32, profile_size: u32, pack_pointer: u32, pack_size: u32, result_pointer: u32) u32 {
    ensureConstructors();
    if (profile_pointer == 0 or profile_size == 0 or profile_size > max_profile_bytes or pack_pointer == 0 or pack_size == 0 or pack_size > max_pack_bytes or result_pointer == 0 or
        rangesOverlap(profile_pointer, profile_size, result_pointer, @sizeOf(ContextResult)) or rangesOverlap(pack_pointer, pack_size, result_pointer, @sizeOf(ContextResult)))
        return status_invalid_argument;
    const result: *ContextResult = @ptrFromInt(result_pointer);
    result.* = .{};
    const profile_input: [*]const u8 = @ptrFromInt(profile_pointer);
    const pack_input: [*]const u8 = @ptrFromInt(pack_pointer);
    const profile_bytes = profile_input[0..profile_size];
    const pack_bytes = pack_input[0..pack_size];
    const profile = runtime_profile.parse(profile_bytes) catch {
        result.status = status_invalid_request;
        return status_invalid_request;
    };
    runtime_profile.validatePackManifest(pack_bytes, profile_bytes) catch {
        result.status = status_invalid_request;
        return status_invalid_request;
    };
    linker.validateRuntimePack(allocator, pack_bytes, profile, .{}) catch {
        result.status = status_invalid_request;
        return status_invalid_request;
    };

    var slot_index: ?usize = null;
    for (&contexts, 0..) |*slot, index| if (slot.profile == null) {
        slot_index = index;
        break;
    };
    const index = slot_index orelse {
        result.status = status_resource_limit;
        return status_resource_limit;
    };
    const owned_profile = allocator.dupe(u8, profile_bytes) catch {
        result.status = status_resource_limit;
        return status_resource_limit;
    };
    const owned_pack = allocator.dupe(u8, pack_bytes) catch {
        allocator.free(owned_profile);
        result.status = status_resource_limit;
        return status_resource_limit;
    };
    const slot = &contexts[index];
    slot.profile = owned_profile;
    slot.pack = owned_pack;
    std.crypto.hash.sha2.Sha256.hash(owned_profile, &slot.profile_sha256, .{});
    std.crypto.hash.sha2.Sha256.hash(owned_pack, &slot.pack_sha256, .{});
    result.handle = contextHandle(index, slot.generation);
    result.runtime_profile_sha256 = slot.profile_sha256;
    result.runtime_pack_sha256 = slot.pack_sha256;
    result.status = status_ok;
    return status_ok;
}

pub export fn luauc_v1_context_destroy(handle: u32) u32 {
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

fn clearResult(result: *CompileResult) void {
    result.* = .{};
}

fn publishDiagnostic(result: *CompileResult, status: u32, message: []const u8) u32 {
    result.status = status;
    if (message.len == 0 or message.len > std.math.maxInt(u32)) return status;
    const owned = allocator.dupe(u8, message) catch {
        result.status = status_resource_limit;
        return status_resource_limit;
    };
    result.diagnostic = @intCast(@intFromPtr(owned.ptr));
    result.diagnostic_size = @intCast(owned.len);
    return status;
}

fn publishError(result: *CompileResult, status: u32, err: anyerror) u32 {
    return publishDiagnostic(result, status, @errorName(err));
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

pub export fn luauc_v1_compile(handle: u32, request_pointer: u32, request_size: u32, result_pointer: u32) u32 {
    ensureConstructors();
    if (request_pointer == 0 or request_size == 0 or result_pointer == 0 or rangesOverlap(request_pointer, request_size, result_pointer, @sizeOf(CompileResult))) return status_invalid_argument;
    const result: *CompileResult = @ptrFromInt(result_pointer);
    clearResult(result);
    const slot = contextFor(handle) orelse return publishDiagnostic(result, status_invalid_context, "InvalidContext");
    const profile = runtime_profile.parse(slot.profile.?) catch return publishDiagnostic(result, status_invalid_context, "InvalidStoredProfile");
    const request_bytes: [*]const u8 = @ptrFromInt(request_pointer);
    const package = source_package.parse(request_bytes[0..request_size], slot.profile_sha256, slot.pack_sha256) catch |err| return publishError(result, if (err == error.ResourceLimit) status_resource_limit else status_invalid_request, err);
    result.request_id = package.request_id;
    result.runtime_profile_sha256 = slot.profile_sha256;
    result.runtime_pack_sha256 = slot.pack_sha256;
    result.manifest_sha256 = package.manifest_sha256;

    const frontend_results = allocator.alloc(FrontendResult, package.module_count) catch return publishDiagnostic(result, status_resource_limit, "frontend result allocation failed");
    defer allocator.free(frontend_results);
    @memset(frontend_results, .{});
    var compiled_count: usize = 0;
    defer for (frontend_results[0..compiled_count]) |*frontend_result| luauc_frontend_snapshot_v1_free(frontend_result);
    for (0..package.module_count) |index| {
        const module = package.module(@intCast(index)) catch |err| return publishError(result, status_invalid_request, err);
        const frontend_result = &frontend_results[index];
        const frontend_status = luauc_frontend_snapshot_v1_compile(module.content.ptr, module.content.len, module.source_name.ptr, module.source_name.len, package.coverage_level, frontend_result);
        compiled_count += 1;
        if (frontend_status != 0 or frontend_result.status != 0 or frontend_result.data == null or frontend_result.size == 0) {
            const diagnostic = if (frontend_result.diagnostic) |pointer| pointer[0..frontend_result.diagnostic_size] else "frontend compilation failed";
            return publishDiagnostic(result, status_frontend_failure, diagnostic);
        }
    }
    const snapshot_package = buildSnapshotPackage(package, frontend_results) catch |err| return publishError(result, status_resource_limit, err);
    defer allocator.free(snapshot_package);
    const object = lower.buildStaticPackage(allocator, snapshot_package) catch |err| return publishError(result, switch (err) {
        error.OutOfMemory, error.ResourceLimit => status_resource_limit,
        else => status_backend_failure,
    }, err);
    defer allocator.free(object);
    const linked = linker.link(allocator, slot.pack.?, object, profile, .{}) catch |err| return publishError(result, switch (err) {
        error.OutOfMemory, error.ResourceLimit, error.ArenaOverflow, error.TableOverflow => status_resource_limit,
        else => status_link_failure,
    }, err);
    if (linked.bytes.len > std.math.maxInt(u32)) {
        allocator.free(linked.bytes);
        return publishDiagnostic(result, status_resource_limit, "artifact exceeds wasm32 result limits");
    }
    result.data = @intCast(@intFromPtr(linked.bytes.ptr));
    result.size = @intCast(linked.bytes.len);
    result.generated_object_sha256 = linked.report.package_object_sha256;
    result.artifact_sha256 = linked.report.output_sha256;
    result.generated_function_count = linked.report.generated_function_count;
    result.generated_data_bytes = linked.report.generated_data_bytes;
    return status_ok;
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
    clearResult(result);
}

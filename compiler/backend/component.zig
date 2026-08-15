const std = @import("std");
const api = @import("luauc_backend_component_api");
const lower = @import("luauc_backend");

const allocator = std.heap.wasm_allocator;

fn publishObject(result: *api.Result, object_result: lower.Error![]u8) u32 {
    result.* = .{};
    const object = object_result catch |err| {
        const diagnostic = @errorName(err);
        result.status = switch (err) {
            error.OutOfMemory, error.ResourceLimit => api.status_resource_limit,
            else => api.status_compile_failure,
        };
        result.diagnostic = @intCast(@intFromPtr(diagnostic.ptr));
        result.diagnostic_size = @intCast(diagnostic.len);
        return result.status;
    };
    if (object.len > std.math.maxInt(u32)) {
        allocator.free(object);
        result.status = api.status_resource_limit;
        const diagnostic = "ResourceLimit";
        result.diagnostic = @intCast(@intFromPtr(diagnostic.ptr));
        result.diagnostic_size = @intCast(diagnostic.len);
        return result.status;
    }

    result.data = @intCast(@intFromPtr(object.ptr));
    result.size = @intCast(object.len);
    result.status = api.status_ok;
    return api.status_ok;
}

export fn luauc_backend_component_v1_compile(
    snapshot_pointer: u32,
    snapshot_size: u32,
    function_id: u32,
    result_pointer: u32,
) u32 {
    if (snapshot_pointer == 0 or snapshot_size == 0 or result_pointer == 0)
        return api.status_invalid_argument;

    const result: *api.Result = @ptrFromInt(result_pointer);
    const snapshot_bytes: [*]const u8 = @ptrFromInt(snapshot_pointer);
    return publishObject(result, lower.build(allocator, snapshot_bytes[0..snapshot_size], function_id));
}

export fn luauc_backend_component_v1_compile_package(
    snapshot_pointer: u32,
    snapshot_size: u32,
    result_pointer: u32,
) u32 {
    if (snapshot_pointer == 0 or snapshot_size == 0 or result_pointer == 0)
        return api.status_invalid_argument;

    const result: *api.Result = @ptrFromInt(result_pointer);
    const snapshot_bytes: [*]const u8 = @ptrFromInt(snapshot_pointer);
    return publishObject(result, lower.buildPackage(allocator, snapshot_bytes[0..snapshot_size]));
}

export fn luauc_backend_component_v1_compile_static_package(
    package_pointer: u32,
    package_size: u32,
    result_pointer: u32,
) u32 {
    if (package_pointer == 0 or package_size == 0 or result_pointer == 0)
        return api.status_invalid_argument;

    const result: *api.Result = @ptrFromInt(result_pointer);
    const package_bytes: [*]const u8 = @ptrFromInt(package_pointer);
    return publishObject(result, lower.buildStaticPackage(allocator, package_bytes[0..package_size]));
}

export fn luauc_backend_component_v1_free(result_pointer: u32) void {
    if (result_pointer == 0)
        return;
    const result: *api.Result = @ptrFromInt(result_pointer);
    if (result.data != 0 and result.size != 0) {
        const bytes: [*]u8 = @ptrFromInt(result.data);
        allocator.free(bytes[0..result.size]);
    }
    result.* = .{ .status = api.status_ok };
}

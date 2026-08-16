const std = @import("std");
const component = @import("luauc_backend_component_api");

const allocator = std.heap.wasm_allocator;

const CompileResult = extern struct {
    data: u32,
    size: u32,
    status: u32,
    reserved: u32,
    diagnostic: u32,
    diagnostic_size: u32,
};

extern fn luauc_backend_component_v1_compile(snapshot_pointer: u32, snapshot_size: u32, function_id: u32, result_pointer: u32) u32;
extern fn luauc_backend_component_v1_compile_package(snapshot_pointer: u32, snapshot_size: u32, result_pointer: u32) u32;
extern fn luauc_backend_component_v1_compile_static_package(package_pointer: u32, package_size: u32, result_pointer: u32) u32;

export fn luauc_backend_v1_alloc(size: u32) u32 {
    if (size == 0)
        return 0;
    const allocation = allocator.alloc(u8, size) catch return 0;
    return @intCast(@intFromPtr(allocation.ptr));
}

export fn luauc_backend_v1_dealloc(pointer: u32, size: u32) void {
    if (pointer == 0 or size == 0)
        return;
    const bytes: [*]u8 = @ptrFromInt(pointer);
    allocator.free(bytes[0..size]);
}

fn publishComponent(result: *CompileResult, component_result: component.Result, status: u32) u32 {
    result.* = .{
        .data = 0,
        .size = 0,
        .status = status,
        .reserved = 0,
        .diagnostic = component_result.diagnostic,
        .diagnostic_size = component_result.diagnostic_size,
    };
    if (status != component.status_ok)
        return status;
    result.data = component_result.data;
    result.size = component_result.size;
    result.status = component.status_ok;
    return component.status_ok;
}

export fn luauc_backend_v1_compile(snapshot_pointer: u32, snapshot_size: u32, function_id: u32, result_pointer: u32) u32 {
    if (snapshot_pointer == 0 or snapshot_size == 0 or result_pointer == 0)
        return component.status_invalid_argument;

    const result: *CompileResult = @ptrFromInt(result_pointer);
    var component_result: component.Result = .{};
    const status = luauc_backend_component_v1_compile(snapshot_pointer, snapshot_size, function_id, @intCast(@intFromPtr(&component_result)));
    return publishComponent(result, component_result, status);
}

export fn luauc_backend_v1_compile_package(snapshot_pointer: u32, snapshot_size: u32, result_pointer: u32) u32 {
    if (snapshot_pointer == 0 or snapshot_size == 0 or result_pointer == 0)
        return component.status_invalid_argument;

    const result: *CompileResult = @ptrFromInt(result_pointer);
    var component_result: component.Result = .{};
    const status = luauc_backend_component_v1_compile_package(snapshot_pointer, snapshot_size, @intCast(@intFromPtr(&component_result)));
    return publishComponent(result, component_result, status);
}

export fn luauc_backend_v1_compile_static_package(package_pointer: u32, package_size: u32, result_pointer: u32) u32 {
    if (package_pointer == 0 or package_size == 0 or result_pointer == 0)
        return component.status_invalid_argument;

    const result: *CompileResult = @ptrFromInt(result_pointer);
    var component_result: component.Result = .{};
    const status = luauc_backend_component_v1_compile_static_package(package_pointer, package_size, @intCast(@intFromPtr(&component_result)));
    return publishComponent(result, component_result, status);
}

export fn luauc_backend_v1_free(result_pointer: u32) void {
    if (result_pointer == 0)
        return;
    const result: *CompileResult = @ptrFromInt(result_pointer);
    if (result.data != 0 and result.size != 0) {
        const bytes: [*]u8 = @ptrFromInt(result.data);
        allocator.free(bytes[0..result.size]);
    }
    result.* = .{
        .data = 0,
        .size = 0,
        .status = component.status_ok,
        .reserved = 0,
        .diagnostic = 0,
        .diagnostic_size = 0,
    };
}

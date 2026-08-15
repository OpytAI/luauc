// The public compiler ABI is implemented by the independently compiled compiler component.
// This root deliberately contains no semantic code; wasm-ld resolves the requested exports from
// that component and links it with the independently compiled backend component.
comptime {
    _ = @extern(*const fn (u32) callconv(.c) u32, .{ .name = "luauc_v1_describe" });
    _ = @extern(*const fn (u32) callconv(.c) u32, .{ .name = "luauc_v1_alloc" });
    _ = @extern(*const fn (u32, u32) callconv(.c) void, .{ .name = "luauc_v1_dealloc" });
    _ = @extern(*const fn (u32, u32, u32) callconv(.c) u32, .{ .name = "luauc_v1_context_create" });
    _ = @extern(*const fn (u32) callconv(.c) u32, .{ .name = "luauc_v1_context_destroy" });
    _ = @extern(*const fn (u32, u32, u32, u32) callconv(.c) u32, .{ .name = "luauc_v1_compile" });
    _ = @extern(*const fn (u32) callconv(.c) void, .{ .name = "luauc_v1_result_free" });
}

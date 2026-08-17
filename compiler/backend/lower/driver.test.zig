const std = @import("std");
const wasm = @import("luauc_wasm_object");
const driver = @import("luauc_backend_driver");

test "dispatchMode pages above 256 and fail-closes above 512 cases" {
    try std.testing.expectEqual(driver.DispatchMode.flat, try driver.dispatchMode(1, 1));
    try std.testing.expectEqual(driver.DispatchMode.flat, try driver.dispatchMode(256, 256));
    try std.testing.expectEqual(driver.DispatchMode.paged, try driver.dispatchMode(257, 257));
    try std.testing.expectEqual(driver.DispatchMode.paged, try driver.dispatchMode(512, 300));
    try std.testing.expectError(error.ResourceLimit, driver.dispatchMode(513, 1));
}

test "paged br_table emits i32.ge_u 256 and two br_table ops" {
    const allocator = std.testing.allocator;
    var body = try wasm.Body.init(allocator, &.{});
    defer body.deinit(allocator);

    var labels: [257]u32 = undefined;
    for (&labels, 0..) |*label, index|
        label.* = @intCast(index);
    try body.localGet(allocator, 0);
    try driver.emitPagedBrTable(allocator, &body, 0, &labels, 258);

    const bytes = body.bytes.items;
    try std.testing.expect(std.mem.indexOf(u8, bytes, &[_]u8{ 0x41, 0x80, 0x02, driver.i32_ge_u }) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, &[_]u8{ 0x41, 0x80, 0x02, 0x6b }) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, &[_]u8{ 0x6b, 0x0e }) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, &[_]u8{ 0x05, 0x20, 0x00, 0x0e }) != null);
}

test "function body over 256 KiB is a ResourceLimit" {
    try driver.checkFunctionBodyLimit(driver.function_body_limit);
    try std.testing.expectError(error.ResourceLimit, driver.checkFunctionBodyLimit(driver.function_body_limit + 1));
}

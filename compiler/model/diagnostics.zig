const std = @import("std");

var buffer: [192]u8 = undefined;
var length: usize = 0;
var function_id: u32 = 0;

pub fn reset() void {
    length = 0;
    function_id = 0;
}

pub fn enterFunction(next_function_id: u32) void {
    function_id = next_function_id;
}

pub fn recordInstruction(error_name: []const u8, instruction_id: u32, command: u32) void {
    if (length != 0)
        return;
    const rendered = std.fmt.bufPrint(
        &buffer,
        "{s} at function {d}, instruction {d}, command {d}",
        .{ error_name, function_id, instruction_id, command },
    ) catch return;
    length = rendered.len;
}

pub fn recordBlock(error_name: []const u8, block_id: u32) void {
    if (length != 0)
        return;
    const rendered = std.fmt.bufPrint(
        &buffer,
        "{s} at function {d}, block {d}",
        .{ error_name, function_id, block_id },
    ) catch return;
    length = rendered.len;
}

pub fn recordPhase(error_name: []const u8, phase: []const u8) void {
    if (length != 0)
        return;
    const rendered = std.fmt.bufPrint(
        &buffer,
        "{s} at function {d} during {s}",
        .{ error_name, function_id, phase },
    ) catch return;
    length = rendered.len;
}

pub fn message() []const u8 {
    return buffer[0..length];
}

const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");

const Error = model.Error;
const Capture = model.Capture;
const dupClosurePattern = model.dupClosurePattern;
const markerCapture = model.markerCapture;

pub noinline fn emitGetUpvalue(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const upvalue = try self.operand(instruction_value, 0);
    if (upvalue.kind != .vm_upvalue or upvalue.value >= self.proto.nups or
        instruction_id + 1 >= self.function.instruction_count)
        return Error.InvalidOperandType;
    const store = try self.instruction(instruction_id + 1);
    if (store.command != .store_tvalue or store.operand_count != 2)
        return Error.UnsupportedControlFlow;
    const store_source = try self.operand(store, 1);
    if (store_source.kind != .instruction or store_source.value != instruction_id)
        return Error.UnsupportedControlFlow;
}
pub noinline fn emitNewClosure(self: anytype, instruction_id: u32) Error!void {
    const pattern = try self.newClosurePattern(instruction_id);
    const child_id = std.math.add(u32, self.function_id_base, pattern.child_proto_id) catch return Error.ResourceLimit;
    if (pattern.capture_count == 0) {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(pattern.destination));
        try self.body.i32Const(self.allocator, @intCast(child_id));
        try self.body.i32Const(self.allocator, @intFromBool(pattern.check_gc));
        try self.body.call(self.allocator, self.newclosure_empty orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
        return;
    }
    var capture_index: u32 = 0;
    while (capture_index < pattern.capture_count) : (capture_index += 1) {
        const capture = try self.initializedCapture(capture_index, pattern.capture_ir_start);
        try self.emitCaptureCall(pattern.destination, child_id, capture_index, capture, pattern.check_gc and capture_index + 1 == pattern.capture_count);
    }
    try self.emitReloadBase();
}
pub noinline fn emitCaptureCall(self: anytype, destination: u32, child_id: u32, capture_index: u32, capture: Capture, check_gc: bool) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(destination));
    try self.body.i32Const(self.allocator, @intCast(child_id));
    try self.body.i32Const(self.allocator, @intCast(capture_index));
    try self.body.i32Const(self.allocator, @intCast(@intFromEnum(capture.kind)));
    try self.body.i32Const(self.allocator, @intCast(capture.source));
    try self.body.i32Const(self.allocator, @intFromBool(check_gc));
    try self.body.call(self.allocator, self.newclosure_capture orelse return Error.UnsupportedCommand);
}
pub noinline fn emitDupClosureCapture(
    self: anytype,
    destination: u32,
    child_id: u32,
    capture_index: u32,
    capture: Capture,
    check_gc: bool,
) Error!void {
    if (capture.kind == .reference)
        return Error.UnsupportedControlFlow;
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(destination));
    try self.body.i32Const(self.allocator, @intCast(child_id));
    try self.body.i32Const(self.allocator, @intCast(capture_index));
    try self.body.i32Const(self.allocator, @intCast(@intFromEnum(capture.kind)));
    try self.body.i32Const(self.allocator, @intCast(capture.source));
    try self.body.i32Const(self.allocator, @intFromBool(check_gc));
    try self.body.call(self.allocator, self.dupclosure_capture orelse return Error.UnsupportedCommand);
}
pub noinline fn emitSetUpvalue(self: anytype, instruction_id: u32) Error!void {
    const pattern = try self.setUpvaluePattern(instruction_id);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(pattern.upvalue_index));
    try self.body.i32Const(self.allocator, @intCast(pattern.source_register));
    try self.body.call(self.allocator, self.set_upvalue orelse return Error.UnsupportedCommand);
}
pub noinline fn emitCloseUpvalues(self: anytype, instruction_id: u32) Error!void {
    const instruction_value = try self.instruction(instruction_id);
    try self.requireOperandCount(instruction_value, 1);
    const source = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(source));
    try self.body.call(self.allocator, self.close_upvalues orelse return Error.UnsupportedCommand);
}
pub noinline fn emitDupClosure(self: anytype, instruction_id: u32) Error!void {
    const pattern = try dupClosurePattern(self.snapshot, self.function, self.proto, instruction_id);
    switch (pattern) {
        .closed => |closed| {
            const global_child_id = std.math.add(u32, self.function_id_base, closed.child_proto_id) catch
                return Error.ResourceLimit;
            try self.body.localGet(self.allocator, 0);
            try self.body.i32Const(self.allocator, @intCast(closed.destination));
            try self.body.i32Const(self.allocator, @intCast(global_child_id));
            try self.body.call(self.allocator, self.dupclosure orelse return Error.UnsupportedCommand);
        },
        .captured => |captured| {
            const global_child_id = std.math.add(u32, self.function_id_base, captured.child_proto_id) catch
                return Error.ResourceLimit;
            var capture_index: u32 = 0;
            while (capture_index < captured.capture_count) : (capture_index += 1) {
                const capture = try markerCapture(
                    self.snapshot,
                    self.function,
                    self.proto,
                    captured.marker_start + capture_index,
                    false,
                );
                try self.emitDupClosureCapture(
                    captured.destination,
                    global_child_id,
                    capture_index,
                    capture,
                    capture_index + 1 == captured.capture_count,
                );
            }
        },
    }
    try self.emitReloadBase();
}

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
pub const max_uniform_capture_run: u32 = 8;

/// One straight-line copy for a same-kind capture run. Index is 0..count-1.
/// `check_gc` applies only to the last capture. Mixed kinds stay on the single capture call.
pub fn emitUniformCaptureRun(
    allocator: std.mem.Allocator,
    object: *wasm.Object,
    dupclosure_capture: wasm.FunctionRef,
    count: u32,
) Error!wasm.FunctionRef {
    if (count < 2 or count > max_uniform_capture_run)
        return Error.UnsupportedControlFlow;
    var params: [13]wasm.ValueType = .{.i32} ** 13;
    const param_count: usize = 5 + @as(usize, count);
    const no_results = [_]wasm.ValueType{};
    const function_type = try object.addType(.{ .params = params[0..param_count], .results = &no_results });
    var body = try wasm.Body.init(allocator, &.{});
    defer body.deinit(allocator);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        try body.localGet(allocator, 0);
        try body.localGet(allocator, 1);
        try body.localGet(allocator, 2);
        try body.i32Const(allocator, @intCast(index));
        try body.localGet(allocator, 3);
        try body.localGet(allocator, 5 + index);
        if (index + 1 == count)
            try body.localGet(allocator, 4)
        else
            try body.i32Const(allocator, 0);
        try body.call(allocator, dupclosure_capture);
    }
    try body.finish(allocator);
    const name = switch (count) {
        2 => "luauc_runtime_v1_dupclosure_run_2",
        3 => "luauc_runtime_v1_dupclosure_run_3",
        4 => "luauc_runtime_v1_dupclosure_run_4",
        5 => "luauc_runtime_v1_dupclosure_run_5",
        6 => "luauc_runtime_v1_dupclosure_run_6",
        7 => "luauc_runtime_v1_dupclosure_run_7",
        8 => "luauc_runtime_v1_dupclosure_run_8",
        else => unreachable,
    };
    return object.defineFunction(name, function_type, wasm.symbol.visibility_hidden, body);
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
            if (captured.capture_count > 255)
                return Error.ResourceLimit;
            var captures: [255]Capture = undefined;
            var loaded: u32 = 0;
            while (loaded < captured.capture_count) : (loaded += 1) {
                captures[loaded] = try markerCapture(
                    self.snapshot,
                    self.function,
                    self.proto,
                    captured.marker_start + loaded,
                    false,
                );
            }
            var capture_index: u32 = 0;
            while (capture_index < captured.capture_count) {
                const kind = captures[capture_index].kind;
                if (kind == .reference)
                    return self.emitDupClosureCapture(
                        captured.destination,
                        global_child_id,
                        capture_index,
                        captures[capture_index],
                        capture_index + 1 == captured.capture_count,
                    );
                var run: u32 = 1;
                while (capture_index + run < captured.capture_count and
                    run < max_uniform_capture_run and
                    captures[capture_index + run].kind == kind)
                {
                    run += 1;
                }
                if (run >= 2) {
                    if (self.capture_run[run]) |helper| {
                        const check_gc: i32 = @intFromBool(capture_index + run == captured.capture_count);
                        try self.body.localGet(self.allocator, 0);
                        try self.body.i32Const(self.allocator, @intCast(captured.destination));
                        try self.body.i32Const(self.allocator, @intCast(global_child_id));
                        try self.body.i32Const(self.allocator, @intCast(@intFromEnum(kind)));
                        try self.body.i32Const(self.allocator, check_gc);
                        var source_index: u32 = 0;
                        while (source_index < run) : (source_index += 1)
                            try self.body.i32Const(self.allocator, @intCast(captures[capture_index + source_index].source));
                        try self.body.call(self.allocator, helper);
                        capture_index += run;
                        continue;
                    }
                }
                var single: u32 = 0;
                while (single < run) : (single += 1) {
                    const at = capture_index + single;
                    try self.emitDupClosureCapture(
                        captured.destination,
                        global_child_id,
                        at,
                        captures[at],
                        at + 1 == captured.capture_count,
                    );
                }
                capture_index += run;
            }
        },
    }
    try self.emitReloadBase();
}

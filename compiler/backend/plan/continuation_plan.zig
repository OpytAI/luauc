const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const model = @import("luauc_backend_model");
const FunctionPlan = @import("luauc_backend_plan").FunctionPlan;
const admission = @import("luauc_backend_admission");
const abi = @import("luauc_backend_runtime_abi");

const Error = model.Error;

/// Record snapshot-visible continuation sites after FunctionPlan.init. Region
/// validation still runs at emit time because it depends on emitBlock matchers
/// until PR 11. Does not import emit Context.
pub fn planContinuations(
    allocator: std.mem.Allocator,
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    proto: snapshot_v1.Proto,
    plan: *FunctionPlan,
) Error!void {
    _ = proto;
    _ = admission;
    if (plan.dominators.immediate.len == 0)
        return Error.UnsupportedControlFlow;

    var sites: std.ArrayList(u32) = .empty;
    errdefer sites.deinit(allocator);
    var instruction_id: u32 = 0;
    while (instruction_id < function.instruction_count) : (instruction_id += 1) {
        const command = (try snapshot.irInstruction(function, instruction_id)).command;
        switch (command) {
            .call, .interrupt => try sites.append(allocator, instruction_id),
            else => if (command == abi.ir_cmd_forgloop_fallback)
                try sites.append(allocator, instruction_id),
        }
    }
    if (plan.continuation_sites.len != 0)
        plan.allocator.free(plan.continuation_sites);
    plan.continuation_sites = try sites.toOwnedSlice(allocator);
}

const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");

const Error = model.Error;
const ArrayOperationPattern = model.ArrayOperationPattern;
const InlineArrayGetPattern = model.InlineArrayGetPattern;
const DynamicLengthPattern = model.DynamicLengthPattern;
const GenericTableOperation = model.GenericTableOperation;
const GenericTablePattern = model.GenericTablePattern;
const GenericTableFallback = model.GenericTableFallback;
const InlineGenericTablePattern = model.InlineGenericTablePattern;
const InlineConstantTableGetPattern = model.InlineConstantTableGetPattern;
const SemanticTableReloadPattern = model.SemanticTableReloadPattern;
const GlobalOperation = model.GlobalOperation;
const GlobalPattern = model.GlobalPattern;
const ir_cmd_table_len = abi.ir_cmd_table_len;
const ir_cmd_get_arr_addr = abi.ir_cmd_get_arr_addr;
const ir_cmd_get_slot_node_addr = abi.ir_cmd_get_slot_node_addr;
const ir_cmd_dup_table = abi.ir_cmd_dup_table;
const ir_cmd_do_len = abi.ir_cmd_do_len;
const ir_cmd_get_table = abi.ir_cmd_get_table;
const ir_cmd_set_table = abi.ir_cmd_set_table;
const ir_cmd_try_num_to_index = abi.ir_cmd_try_num_to_index;
const ir_cmd_check_readonly = abi.ir_cmd_check_readonly;
const ir_cmd_check_no_metatable = abi.ir_cmd_check_no_metatable;
const ir_cmd_check_array_size = abi.ir_cmd_check_array_size;
const ir_cmd_check_slot_match = abi.ir_cmd_check_slot_match;
const ir_cmd_barrier_table_forward = abi.ir_cmd_barrier_table_forward;
const ir_cmd_fallback_getglobal = abi.ir_cmd_fallback_getglobal;
const ir_cmd_fallback_setglobal = abi.ir_cmd_fallback_setglobal;
const tvalue_size = abi.tvalue_size;
const tvalue_tag_offset = abi.tvalue_tag_offset;
const tstring_len_offset = abi.tstring_len_offset;
const table_metatable_offset = abi.table_metatable_offset;
const lua_state_top_offset = abi.lua_state_top_offset;
const lua_tag_number = abi.lua_tag_number;
const lua_tag_string = abi.lua_tag_string;
const lua_tag_table = abi.lua_tag_table;
const lua_tag_vector = abi.lua_tag_vector;

pub const LengthSequence = struct {
    start: u32,
    finish: u32,
    destination: u32,
    source: u32,
    marker: snapshot_v1.IrInstruction,
};

pub noinline fn emitGeneralGetGlobal(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try emitGeneralGlobal(self, instruction_value, .get);
}

pub noinline fn emitGeneralSetGlobal(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try emitGeneralGlobal(self, instruction_value, .set);
}

fn emitGeneralGlobal(self: anytype, instruction_value: snapshot_v1.IrInstruction, operation: GlobalOperation) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    const pc = try self.uintConstant(try self.operand(instruction_value, 0));
    const value = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
    const key = (try self.stringKey(try self.operand(instruction_value, 2))) orelse
        return Error.UnsupportedControlFlow;
    const interned = try self.string_keys.intern(self.allocator, key);
    try self.emitPcLocation(pc);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(value));
    try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(interned.offset));
    try self.body.i32Const(self.allocator, @intCast(interned.length));
    try self.body.call(self.allocator, switch (operation) {
        .get => self.get_global orelse return Error.UnsupportedCommand,
        .set => self.set_global orelse return Error.UnsupportedCommand,
    });
    try self.emitReloadBase();
}

// Luau's GETTABLEKS fast path: a one-byte name x/y/z, ignoring case, reads that lane.
// name[1] == 0 is the terminator test, so a longer key matches only when its second byte is NUL.
fn vectorFieldLane(key: []const u8) ?u32 {
    if (key.len == 0 or (key.len > 1 and key[1] != 0))
        return null;
    const folded = @as(i32, key[0] | ' ') - 'x';
    if (folded < 0 or folded >= @as(i32, @intCast(abi.vector_lane_count)))
        return null;
    return @intCast(folded);
}

fn emitRegisterBelowTop(self: anytype, register: u32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, @intCast(register * tvalue_size));
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, lua_state_top_offset);
    try self.body.opcode(self.allocator, 0x49); // i32.lt_u
}

fn emitStringGetHelper(self: anytype, destination: u32, table: u32, key: []const u8) Error!void {
    const interned = try self.string_keys.intern(self.allocator, key);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(destination));
    try self.body.i32Const(self.allocator, @intCast(table));
    try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(interned.offset));
    try self.body.i32Const(self.allocator, @intCast(interned.length));
    try self.body.call(self.allocator, self.table_get_string orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
}

// The constant is already interned in Proto.k. The array pointer is stable for this
// activation, so the call-frame walk runs once. A miss, including a collision, stays on the helper.
fn emitProtoConstantString(self: anytype, index: u32) Error!void {
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.call_func_local);
    const index_i32 = std.math.cast(i32, index) orelse return;
    const slot_addend = std.math.cast(i32, std.math.mul(u32, index, tvalue_size) catch return) orelse return;

    try self.body.localGet(self.allocator, self.constant_array_local);
    try self.body.opcode(self.allocator, 0x45); // i32.eqz
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_func_offset);
    try self.body.i32Load(self.allocator, 2, 0);
    try self.body.localTee(self.allocator, self.call_meta_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load8U(self.allocator, 0, abi.closure_is_c_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.closure_l_proto_offset);
    try self.body.localTee(self.allocator, self.call_meta_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.proto_sizek_offset);
    try self.body.i32Const(self.allocator, 0);
    try self.body.opcode(self.allocator, 0x4a); // i32.gt_s
    try self.body.i32Const(self.allocator, index_i32);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.proto_sizek_offset);
    try self.body.opcode(self.allocator, 0x49); // i32.lt_u
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, abi.proto_constants_offset);
    try self.body.localSet(self.allocator, self.constant_array_local);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);

    try self.body.localGet(self.allocator, self.constant_array_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.constant_array_local);
    try self.body.i32Const(self.allocator, slot_addend);
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.localTee(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, tvalue_tag_offset);
    try self.body.i32Const(self.allocator, lua_tag_string);
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, 0);
    try self.body.localSet(self.allocator, self.call_func_local);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}

fn emitMainPositionNode(self: anytype) Error!void {
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Load(self.allocator, 2, abi.tstring_hash_offset);
    try self.body.i32Const(self.allocator, 1);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Load8U(self.allocator, 0, abi.table_lsizenode_offset);
    try self.body.opcode(self.allocator, 0x74); // i32.shl
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, 0x6b); // i32.sub
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.i32Const(self.allocator, 5); // sizeof(LuaNode) == 32
    try self.body.opcode(self.allocator, 0x74); // i32.shl
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Load(self.allocator, 2, abi.table_node_offset);
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.localSet(self.allocator, self.call_closure_local);
}

fn emitSlotNodeHelper(self: anytype, key_constant: u32) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Const(self.allocator, @intCast(key_constant));
    try self.body.call(self.allocator, self.slot_node_addr orelse return Error.UnsupportedCommand);
}

fn emitSlotMatchHelper(self: anytype, key_constant: u32) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Const(self.allocator, @intCast(key_constant));
    try self.body.call(self.allocator, self.node_slot_match orelse return Error.UnsupportedCommand);
}

// The table pointer is on the stack. The node pointer replaces it.
// A null pointer, a non-table, or a non-string constant keeps the runtime helper,
// which reports the same provenance error as the native slot lookup.
pub fn emitSlotNodeFromTable(self: anytype, key_constant: u32) Error!void {
    try self.body.localTee(self.allocator, self.call_aux_local);
    try self.body.ifI32(self.allocator);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Load8U(self.allocator, 0, 0);
    try self.body.i32Const(self.allocator, lua_tag_table);
    try self.body.i32Eq(self.allocator);
    try self.body.ifI32(self.allocator);
    try emitProtoConstantString(self, key_constant);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.ifI32(self.allocator);
    try emitMainPositionNode(self);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.else_(self.allocator);
    try emitSlotNodeHelper(self, key_constant);
    try self.body.end(self.allocator);
    try self.body.else_(self.allocator);
    try emitSlotNodeHelper(self, key_constant);
    try self.body.end(self.allocator);
    try self.body.else_(self.allocator);
    try emitSlotNodeHelper(self, key_constant);
    try self.body.end(self.allocator);
}

// The node pointer is on the stack. A non-zero result means the key matches and the value is not nil.
pub fn emitSlotMatchFromNode(self: anytype, key_constant: u32) Error!void {
    try self.body.localTee(self.allocator, self.call_closure_local);
    try self.body.ifI32(self.allocator);
    try emitProtoConstantString(self, key_constant);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.ifI32(self.allocator);
    try emitNodeKeyMatch(self);
    try self.body.else_(self.allocator);
    try emitSlotMatchHelper(self, key_constant);
    try self.body.end(self.allocator);
    try self.body.else_(self.allocator);
    try emitSlotMatchHelper(self, key_constant);
    try self.body.end(self.allocator);
}

fn emitNodeKeyMatch(self: anytype) Error!void {
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load(self.allocator, 2, abi.lua_node_key_tag_offset);
    try self.body.i32Const(self.allocator, abi.lua_node_key_tag_mask);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.i32Const(self.allocator, lua_tag_string);
    try self.body.i32Eq(self.allocator);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load(self.allocator, 2, abi.lua_node_key_offset);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Eq(self.allocator);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load(self.allocator, 2, tvalue_tag_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.i32Eqz(self.allocator);
    try self.body.opcode(self.allocator, 0x71); // i32.and
}

fn emitCopyNodeToRegister(self: anytype, destination: u32) Error!void {
    const offset = destination * tvalue_size;
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i64Load(self.allocator, 3, 0);
    try self.body.i64Store(self.allocator, 3, offset);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i64Load(self.allocator, 3, 8);
    try self.body.i64Store(self.allocator, 3, offset + 8);
}

fn emitKeyPointerMatch(self: anytype) Error!void {
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load(self.allocator, 2, abi.lua_node_key_tag_offset);
    try self.body.i32Const(self.allocator, abi.lua_node_key_tag_mask);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.i32Const(self.allocator, lua_tag_string);
    try self.body.i32Eq(self.allocator);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load(self.allocator, 2, abi.lua_node_key_offset);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Eq(self.allocator);
    try self.body.opcode(self.allocator, 0x71); // i32.and
}

fn emitValueNonNil(self: anytype) Error!void {
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load(self.allocator, 2, tvalue_tag_offset);
    try self.body.opcode(self.allocator, 0x45); // i32.eqz
    try self.body.opcode(self.allocator, 0x45); // i32.eqz
}

fn emitNextIsZero(self: anytype) Error!void {
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load(self.allocator, 2, abi.lua_node_key_tag_offset);
    try self.body.i32Const(self.allocator, ~@as(i32, abi.lua_node_key_tag_mask));
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.opcode(self.allocator, 0x45); // i32.eqz
}

fn emitFollowNext(self: anytype) Error!void {
    // gnext is the signed 28-bit field above the 4-bit key tag. The link is a LuaNode delta.
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load(self.allocator, 2, abi.lua_node_key_tag_offset);
    try self.body.i32Const(self.allocator, 4);
    try self.body.opcode(self.allocator, 0x75); // i32.shr_s
    try self.body.i32Const(self.allocator, @intCast(abi.lua_node_size));
    try self.body.opcode(self.allocator, 0x6c); // i32.mul
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.localSet(self.allocator, self.call_closure_local);
}

fn emitPublishRawNil(self: anytype, destination: u32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, abi.lua_tag_nil);
    try self.body.i32Store(self.allocator, 2, destination * tvalue_size + tvalue_tag_offset);
    try self.body.i32Const(self.allocator, 1);
    try self.body.localSet(self.allocator, self.call_proto_local);
}

fn emitRecordNonNil(self: anytype, destination: u32, publish_nil: bool) Error!void {
    if (publish_nil)
        try emitCopyNodeToRegister(self, destination);
    try self.body.i32Const(self.allocator, 1);
    try self.body.localSet(self.allocator, self.call_proto_local);
}

fn emitRecordRawNil(self: anytype) Error!void {
    try self.body.i32Const(self.allocator, 2);
    try self.body.localSet(self.allocator, self.call_meta_local);
}

// Walk gnext until the key is resolved. call_meta 2 means the key is absent or nil.
// A nil value does not follow. A different key with next == 0 is absent.
const ChainEnd = enum { raw_nil, leave };

fn emitLeaveChain(self: anytype, depth: u32) Error!void {
    try self.body.branch(self.allocator, depth);
}

fn emitChainWalk(self: anytype, destination: u32, publish_nil: bool, chain_end: ChainEnd) Error!void {
    // The exit block surrounds the loop. br 0 repeats the loop.
    // A match sits inside two ifs, so leaving that arm is br 3.
    try self.body.block(self.allocator);
    try self.body.loop(self.allocator);
    try emitKeyPointerMatch(self);
    try self.body.ifVoid(self.allocator);
    try emitValueNonNil(self);
    try self.body.ifVoid(self.allocator);
    try emitRecordNonNil(self, destination, publish_nil);
    try emitLeaveChain(self, 3);
    try self.body.else_(self.allocator);
    if (chain_end == .raw_nil)
        try emitRecordRawNil(self);
    try emitLeaveChain(self, 3);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try emitNextIsZero(self);
    try self.body.ifVoid(self.allocator);
    if (chain_end == .raw_nil)
        try emitRecordRawNil(self);
    try emitLeaveChain(self, 2);
    try self.body.end(self.allocator);
    try emitFollowNext(self);
    try self.body.branch(self.allocator, 0);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}

fn emitConsiderNode(self: anytype, destination: u32, publish_nil: bool) Error!void {
    try emitChainWalk(self, destination, publish_nil, .raw_nil);
}

fn emitFieldWalk(self: anytype, destination: u32, publish_nil: bool) Error!void {
    try emitChainWalk(self, destination, publish_nil, .leave);
}

fn emitIndexKeyWalk(self: anytype, destination: u32, publish_nil: bool) Error!void {
    try self.body.block(self.allocator);
    try self.body.loop(self.allocator);
    try emitKeyPointerMatch(self);
    try self.body.ifVoid(self.allocator);
    try emitValueNonNil(self);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load(self.allocator, 2, tvalue_tag_offset);
    try self.body.i32Const(self.allocator, lua_tag_table);
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load(self.allocator, 2, 0);
    try self.body.localTee(self.allocator, self.call_aux_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_cached_closure_local);
    try self.body.localSet(self.allocator, self.call_func_local);
    try emitMainPositionNode(self);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.ifVoid(self.allocator);
    try emitFieldWalk(self, destination, publish_nil);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try emitLeaveChain(self, 3);
    try self.body.else_(self.allocator);
    try emitLeaveChain(self, 3);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try emitNextIsZero(self);
    try self.body.ifVoid(self.allocator);
    try emitLeaveChain(self, 2);
    try self.body.end(self.allocator);
    try emitFollowNext(self);
    try self.body.branch(self.allocator, 0);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}

// call_aux is the table and call_func is the field. A table __index is one more slot walk.
// A function __index does not set the hit flag.
fn emitRawNil(self: anytype, destination: u32, publish_nil: bool) Error!void {
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Load(self.allocator, 2, table_metatable_offset);
    try self.body.localTee(self.allocator, self.call_meta_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load8U(self.allocator, 0, abi.table_tmcache_offset);
    try self.body.i32Const(self.allocator, @as(i32, 1) << @intCast(abi.upstream_tm_index));
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.opcode(self.allocator, 0x45); // i32.eqz
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_global_offset);
    try self.body.i32Load(self.allocator, 2, abi.global_tmname_offset);
    try self.body.localTee(self.allocator, self.call_func_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localSet(self.allocator, self.call_aux_local);
    try emitMainPositionNode(self);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.ifVoid(self.allocator);
    try emitIndexKeyWalk(self, destination, publish_nil);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    if (publish_nil) {
        try self.body.else_(self.allocator);
        try emitPublishRawNil(self, destination);
    }
    try self.body.end(self.allocator);
    if (publish_nil) {
        try self.body.else_(self.allocator);
        try emitPublishRawNil(self, destination);
    }
    try self.body.end(self.allocator);
}

fn emitAfterMainPositionMiss(self: anytype, destination: u32, publish_nil: bool) Error!void {
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.localSet(self.allocator, self.call_cached_closure_local);
    try emitConsiderNode(self, destination, publish_nil);
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.opcode(self.allocator, 0x45); // i32.eqz
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Const(self.allocator, 2);
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try emitRawNil(self, destination, publish_nil);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}

// Main-position hit copies the TValue. Every other outcome uses the string-key helper once.
fn emitStringSlotOrHelper(self: anytype, destination: u32, table: u32, key: []const u8, key_constant: ?u32) Error!void {
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.call_proto_local);
    if (key_constant) |index| {
        try emitRegisterBelowTop(self, table);
        try emitRegisterBelowTop(self, destination);
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.ifVoid(self.allocator);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Load(self.allocator, 2, table * tvalue_size + tvalue_tag_offset);
        try self.body.i32Const(self.allocator, lua_tag_table);
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Load(self.allocator, 2, table * tvalue_size);
        try self.body.localTee(self.allocator, self.call_aux_local);
        try self.body.ifVoid(self.allocator);
        try emitProtoConstantString(self, index);
        try self.body.localGet(self.allocator, self.call_func_local);
        try self.body.ifVoid(self.allocator);
        try emitMainPositionNode(self);
        try self.body.localGet(self.allocator, self.call_closure_local);
        try self.body.ifVoid(self.allocator);
        try emitNodeKeyMatch(self);
        try self.body.ifVoid(self.allocator);
        try emitCopyNodeToRegister(self, destination);
        try self.body.i32Const(self.allocator, 1);
        try self.body.localSet(self.allocator, self.call_proto_local);
        try self.body.else_(self.allocator);
        try emitAfterMainPositionMiss(self, destination, true);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
    }
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try emitStringGetHelper(self, destination, table, key);
    try self.body.end(self.allocator);
}

fn emitStringSetHelper(self: anytype, table: u32, value: u32, key: []const u8) Error!void {
    const interned = try self.string_keys.intern(self.allocator, key);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(table));
    try self.body.i32Const(self.allocator, @intCast(value));
    try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(interned.offset));
    try self.body.i32Const(self.allocator, @intCast(interned.length));
    try self.body.call(self.allocator, self.table_set_string orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
}

fn emitCopyRegisterToNode(self: anytype, register: u32) Error!void {
    const offset = register * tvalue_size;
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i64Load(self.allocator, 3, offset);
    try self.body.i64Store(self.allocator, 3, 0);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i64Load(self.allocator, 3, offset + 8);
    try self.body.i64Store(self.allocator, 3, 8);
}

fn emitCollectableValueBarrier(self: anytype, register: u32) Error!void {
    // A module with no collectable table store does not import the barrier.
    // Number writes are the common case and do not need one.
    const barrier = self.barrier_table_forward orelse return;
    const slot = snapshot_v1.IrOperand{ .kind = .vm_reg, .value = register };
    try self.emitTValueTag(slot);
    try self.body.i32Const(self.allocator, lua_tag_string);
    try self.body.opcode(self.allocator, 0x4e); // i32.ge_s
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Const(self.allocator, @intCast(register));
    try self.body.call(self.allocator, barrier);
    try self.emitReloadBase();
    try self.body.end(self.allocator);
}

fn emitWriteStringKey(self: anytype) Error!void {
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Store(self.allocator, 2, abi.lua_node_key_offset);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.i32Store(self.allocator, 2, abi.lua_node_key_offset + 4);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.i32Store(self.allocator, 2, abi.lua_node_key_offset + 8);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Load(self.allocator, 2, abi.lua_node_key_tag_offset);
    try self.body.i32Const(self.allocator, ~@as(i32, abi.lua_node_key_tag_mask));
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.i32Const(self.allocator, lua_tag_string);
    try self.body.opcode(self.allocator, 0x72); // i32.or
    try self.body.i32Store(self.allocator, 2, abi.lua_node_key_tag_offset);
}

fn emitKeyBarrierRequired(self: anytype) Error!void {
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Load8U(self.allocator, 0, 1);
    try self.body.i32Const(self.allocator, abi.lua_black_bit);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.opcode(self.allocator, 0x45); // i32.eqz
    try self.body.opcode(self.allocator, 0x45); // i32.eqz
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Load8U(self.allocator, 0, 1);
    try self.body.i32Const(self.allocator, 3);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.opcode(self.allocator, 0x45); // i32.eqz
    try self.body.opcode(self.allocator, 0x45); // i32.eqz
    try self.body.opcode(self.allocator, 0x71); // i32.and
}

// An existing main-position key is two stores. An empty main position of a plain table
// takes the same stores plus the key write. Collisions, metamethods, and a live barrier
// stay on table_set_string.
pub fn emitStringSlotSetOrHelper(
    self: anytype,
    table: u32,
    value: u32,
    key: []const u8,
    key_constant: ?u32,
) Error!void {
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.call_proto_local);
    if (key_constant) |index| {
        try emitRegisterBelowTop(self, table);
        try emitRegisterBelowTop(self, value);
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.ifVoid(self.allocator);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Load(self.allocator, 2, table * tvalue_size + tvalue_tag_offset);
        try self.body.i32Const(self.allocator, lua_tag_table);
        try self.body.i32Eq(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Load(self.allocator, 2, table * tvalue_size);
        try self.body.localTee(self.allocator, self.call_aux_local);
        try self.body.ifVoid(self.allocator);
        try self.body.localGet(self.allocator, self.call_aux_local);
        try self.body.i32Load8U(self.allocator, 0, abi.table_readonly_offset);
        try self.body.opcode(self.allocator, 0x45); // i32.eqz
        try self.body.ifVoid(self.allocator);
        try emitProtoConstantString(self, index);
        try self.body.localGet(self.allocator, self.call_func_local);
        try self.body.ifVoid(self.allocator);
        try emitMainPositionNode(self);
        try self.body.localGet(self.allocator, self.call_closure_local);
        try self.body.ifVoid(self.allocator);
        try emitNodeKeyMatch(self);
        try self.body.ifVoid(self.allocator);
        try emitCopyRegisterToNode(self, value);
        try emitCollectableValueBarrier(self, value);
        try self.body.i32Const(self.allocator, 1);
        try self.body.localSet(self.allocator, self.call_proto_local);
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, self.call_aux_local);
        try self.body.i32Load(self.allocator, 2, table_metatable_offset);
        try self.body.opcode(self.allocator, 0x45); // i32.eqz
        try self.body.ifVoid(self.allocator);
        try self.body.localGet(self.allocator, self.call_aux_local);
        try self.body.i32Load8U(self.allocator, 0, abi.table_lsizenode_offset);
        try self.body.ifVoid(self.allocator);
        try self.body.localGet(self.allocator, self.call_closure_local);
        try self.body.i32Load(self.allocator, 2, tvalue_tag_offset);
        try self.body.opcode(self.allocator, 0x45); // i32.eqz
        try self.body.ifVoid(self.allocator);
        try emitKeyBarrierRequired(self);
        try self.body.opcode(self.allocator, 0x45); // i32.eqz
        try self.body.ifVoid(self.allocator);
        try emitWriteStringKey(self);
        try emitCopyRegisterToNode(self, value);
        try emitCollectableValueBarrier(self, value);
        try self.body.i32Const(self.allocator, 1);
        try self.body.localSet(self.allocator, self.call_proto_local);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
        try self.body.end(self.allocator);
    }
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try emitStringSetHelper(self, table, value, key);
    try self.body.end(self.allocator);
}

// Hit flag in call_proto. On a hit, call_closure is the method node and the
// receiver is copied into destination+1 before the method overwrites destination.
pub fn emitInlineNamecallProbe(self: anytype, source: u32, destination: u32, key_constant: u32) Error!void {
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.call_proto_local);
    try emitRegisterBelowTop(self, source);
    try emitRegisterBelowTop(self, destination);
    try emitRegisterBelowTop(self, destination + 1);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, source * tvalue_size + tvalue_tag_offset);
    try self.body.i32Const(self.allocator, lua_tag_table);
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, source * tvalue_size);
    try self.body.localTee(self.allocator, self.call_aux_local);
    try self.body.ifVoid(self.allocator);
    try emitProtoConstantString(self, key_constant);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.ifVoid(self.allocator);
    try emitMainPositionNode(self);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.ifVoid(self.allocator);
    try emitNodeKeyMatch(self);
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, 1);
    try self.body.localSet(self.allocator, self.call_proto_local);
    try self.body.else_(self.allocator);
    try emitAfterMainPositionMiss(self, destination, false);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.ifVoid(self.allocator);
    try self.emitCopyTValueRegisters(destination + 1, source);
    try emitCopyNodeToRegister(self, destination);
    try self.body.end(self.allocator);
}

// A vector lane publishes a number. A table hit copies the main-position slot. Everything else uses the helper.
pub fn emitStringKeyGet(self: anytype, destination: u32, table: u32, key: []const u8, key_constant: ?u32) Error!void {
    const lane = vectorFieldLane(key) orelse return emitStringSlotOrHelper(self, destination, table, key, key_constant);
    try self.emitReloadBase();
    try emitRegisterBelowTop(self, table);
    try emitRegisterBelowTop(self, destination);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, table * tvalue_size + tvalue_tag_offset);
    try self.body.i32Const(self.allocator, @intCast(lua_tag_vector));
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, @intCast(destination * tvalue_size));
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.f32Load(self.allocator, 2, table * tvalue_size + lane * 4);
    try self.body.opcode(self.allocator, 0xbb); // f64.promote_f32
    try self.body.f64Store(self.allocator, 3, 0);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, lua_tag_number);
    try self.body.i32Store(self.allocator, 2, destination * tvalue_size + tvalue_tag_offset);
    try self.body.else_(self.allocator);
    try emitStringSlotOrHelper(self, destination, table, key, key_constant);
    try self.body.end(self.allocator);
    try self.body.else_(self.allocator);
    try emitStringSlotOrHelper(self, destination, table, key, key_constant);
    try self.body.end(self.allocator);
}

pub noinline fn emitGeneralGetTableKs(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try emitGeneralTableKs(self, instruction_value, .get);
}

pub noinline fn emitGeneralSetTableKs(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try emitGeneralTableKs(self, instruction_value, .set);
}

fn emitGeneralTableKs(
    self: anytype,
    instruction_value: snapshot_v1.IrInstruction,
    operation: model.StringTableOperation,
) Error!void {
    try self.requireOperandCount(instruction_value, 4);
    const pc = try self.uintConstant(try self.operand(instruction_value, 0));
    const value = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
    const table = try self.vmRegisterIndex(try self.operand(instruction_value, 2));
    const key_operand = try self.operand(instruction_value, 3);
    const key = (try self.stringKey(key_operand)) orelse
        return Error.UnsupportedControlFlow;
    try self.emitPcLocation(pc);
    switch (operation) {
        .set => try emitStringSlotSetOrHelper(self, table, value, key, key_operand.value),
        .get => try emitStringKeyGet(self, value, table, key, key_operand.value),
    }
}

pub noinline fn emitDirectGenericTableOperation(
    self: anytype,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    if ((instruction_value.command != ir_cmd_set_table and instruction_value.command != ir_cmd_get_table) or
        instruction_value.operand_count != 3)
        return Error.UnsupportedCommand;
    const value = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
    const table = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
    const key = try self.vmRegisterIndex(try self.operand(instruction_value, 2));

    try self.body.localGet(self.allocator, 0);
    if (instruction_value.command == ir_cmd_set_table) {
        try self.body.i32Const(self.allocator, @intCast(table));
        try self.body.i32Const(self.allocator, @intCast(key));
        try self.body.i32Const(self.allocator, @intCast(value));
        try self.body.call(self.allocator, self.table_set orelse return Error.UnsupportedCommand);
    } else {
        try self.body.i32Const(self.allocator, @intCast(value));
        try self.body.i32Const(self.allocator, @intCast(table));
        try self.body.i32Const(self.allocator, @intCast(key));
        try self.body.call(self.allocator, self.table_get orelse return Error.UnsupportedCommand);
    }
    try self.emitReloadBase();
}

pub fn globalFallback(
    self: anytype,
    fallback_id: u32,
    operation: GlobalOperation,
    pc: u32,
    value: u32,
    key_id: u32,
) Error!?u32 {
    if (fallback_id >= self.function.block_count)
        return null;
    const block = try self.snapshot.irBlock(self.function, fallback_id);
    if (block.kind != .fallback or block.isEmpty() or block.finish != block.start + 1)
        return null;
    const semantic = try self.instruction(block.start);
    const jump = try self.instruction(block.finish);
    const expected_command = if (operation == .get) ir_cmd_fallback_getglobal else ir_cmd_fallback_setglobal;
    if (semantic.command != expected_command or semantic.operand_count != 3 or
        jump.command != .jump or jump.operand_count != 1)
        return null;
    const semantic_pc = try self.operand(semantic, 0);
    const semantic_value = try self.operand(semantic, 1);
    const semantic_key = try self.operand(semantic, 2);
    if (!try self.uintOperandEquals(semantic_pc, pc) or semantic_value.kind != .vm_reg or semantic_value.value != value or
        semantic_key.kind != .vm_const or semantic_key.value != key_id)
        return null;
    return self.requireCompiledTarget(try self.operand(jump, 0)) catch return null;
}
pub noinline fn globalPatternFor(self: anytype, block: snapshot_v1.IrBlock, operation: GlobalOperation) Error!?GlobalPattern {
    if (!block.kind.isCompilable() or block.isEmpty())
        return null;
    const get_commands = [_]snapshot_v1.IrCommand{
        .load_env, ir_cmd_get_slot_node_addr, ir_cmd_check_slot_match, .load_tvalue, .store_tvalue, .jump,
    };
    const set_commands = [_]snapshot_v1.IrCommand{
        .load_env,    ir_cmd_get_slot_node_addr, ir_cmd_check_slot_match,      ir_cmd_check_readonly,
        .load_tvalue, .store_tvalue,             ir_cmd_barrier_table_forward, .jump,
    };
    const command_count = if (operation == .get) get_commands.len else set_commands.len;
    if (block.finish < block.start + command_count - 1)
        return null;
    const start = block.finish - @as(u32, @intCast(command_count - 1));
    if (operation == .get) {
        if (!try self.commandRangeMatches(start, &get_commands))
            return null;
    } else if (!try self.commandRangeMatches(start, &set_commands))
        return null;

    const env = try self.instruction(start);
    const slot = try self.instruction(start + 1);
    const match = try self.instruction(start + 2);
    const load_id = start + (if (operation == .get) @as(u32, 3) else 4);
    const store_id = load_id + 1;
    const load = try self.instruction(load_id);
    const store = try self.instruction(store_id);
    const jump = try self.instruction(block.finish);
    if (env.operand_count != 0 or slot.operand_count != 3 or match.operand_count != 3 or
        load.operand_count != (if (operation == .get) @as(u32, 2) else 1) or
        store.operand_count != (if (operation == .get) @as(u32, 2) else 3) or jump.operand_count != 1)
        return null;
    const slot_env = try self.operand(slot, 0);
    const pc_operand = try self.operand(slot, 1);
    const key_operand = try self.operand(slot, 2);
    const matched_slot = try self.operand(match, 0);
    const matched_key = try self.operand(match, 1);
    const fallback = try self.operand(match, 2);
    const fast_target = try self.operand(jump, 0);
    if (slot_env.kind != .instruction or slot_env.value != start or pc_operand.kind != .constant or
        key_operand.kind != .vm_const or matched_slot.kind != .instruction or matched_slot.value != start + 1 or
        matched_key.kind != .vm_const or matched_key.value != key_operand.value or fallback.kind != .block or
        fast_target.kind != .block)
        return null;
    const pc = (try self.constant(pc_operand.value)).uintValue() orelse return null;
    const key = (try self.stringKey(key_operand)) orelse return null;

    var value: u32 = undefined;
    if (operation == .get) {
        const loaded_slot = try self.operand(load, 0);
        const load_offset = try self.operand(load, 1);
        const destination = try self.operand(store, 0);
        const stored = try self.operand(store, 1);
        if (loaded_slot.kind != .instruction or loaded_slot.value != start + 1 or
            !try self.intOperandEquals(load_offset, 0) or destination.kind != .vm_reg or
            destination.value >= self.proto.max_stack_size or stored.kind != .instruction or stored.value != load_id)
            return null;
        value = destination.value;
    } else {
        const readonly = try self.instruction(start + 3);
        const source = try self.operand(load, 0);
        const store_slot = try self.operand(store, 0);
        const store_value = try self.operand(store, 1);
        const store_offset = try self.operand(store, 2);
        const barrier = try self.instruction(start + 6);
        if (readonly.operand_count != 2 or barrier.operand_count != 3 or source.kind != .vm_reg or
            source.value >= self.proto.max_stack_size or
            (try self.operand(readonly, 0)).kind != .instruction or (try self.operand(readonly, 0)).value != start or
            (try self.operand(readonly, 1)).kind != .block or (try self.operand(readonly, 1)).value != fallback.value or
            store_slot.kind != .instruction or store_slot.value != start + 1 or
            store_value.kind != .instruction or store_value.value != load_id or !try self.intOperandEquals(store_offset, 0) or
            (try self.operand(barrier, 0)).kind != .instruction or (try self.operand(barrier, 0)).value != start or
            (try self.operand(barrier, 1)).kind != .vm_reg or (try self.operand(barrier, 1)).value != source.value or
            (try self.operand(barrier, 2)).kind != .undef)
            return null;
        value = source.value;
    }
    const rejoin = (try self.globalFallback(fallback.value, operation, pc, value, key_operand.value)) orelse return null;
    return .{
        .operation = operation,
        .start = start,
        .value = value,
        .key = key,
        .pc = pc,
        .fast_target = try self.requireCompiledTarget(fast_target),
        .rejoin = rejoin,
    };
}
pub noinline fn globalPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?GlobalPattern {
    if (try self.globalPatternFor(block, .set)) |pattern|
        return pattern;
    return self.globalPatternFor(block, .get);
}
pub noinline fn globalHeadPatternAt(self: anytype, start: u32, block: snapshot_v1.IrBlock) Error!?GlobalPattern {
    if (!block.kind.isCompilable() or start < block.start or start + 2 > block.finish)
        return null;
    const env = try self.instruction(start);
    const slot = try self.instruction(start + 1);
    const match = try self.instruction(start + 2);
    if (env.command != .load_env or slot.command != ir_cmd_get_slot_node_addr or
        match.command != ir_cmd_check_slot_match or env.operand_count != 0 or
        slot.operand_count != 3 or match.operand_count != 3)
        return null;
    const slot_env = try self.operand(slot, 0);
    const pc_operand = try self.operand(slot, 1);
    const key_operand = try self.operand(slot, 2);
    const matched_slot = try self.operand(match, 0);
    const matched_key = try self.operand(match, 1);
    const fallback = try self.operand(match, 2);
    if (slot_env.kind != .instruction or slot_env.value != start or pc_operand.kind != .constant or
        key_operand.kind != .vm_const or matched_slot.kind != .instruction or matched_slot.value != start + 1 or
        matched_key.kind != .vm_const or matched_key.value != key_operand.value or fallback.kind != .block)
        return null;
    const pc = (try self.constant(pc_operand.value)).uintValue() orelse return null;
    const key = (try self.stringKey(key_operand)) orelse return null;
    const fallback_block = try self.snapshot.irBlock(self.function, fallback.value);
    if (fallback_block.kind != .fallback or fallback_block.isEmpty() or fallback_block.finish != fallback_block.start + 1)
        return null;
    const semantic = try self.instruction(fallback_block.start);
    const jump = try self.instruction(fallback_block.finish);
    if ((semantic.command != ir_cmd_fallback_getglobal and semantic.command != ir_cmd_fallback_setglobal) or
        semantic.operand_count != 3 or jump.command != .jump or jump.operand_count != 1)
        return null;
    const semantic_pc = try self.operand(semantic, 0);
    const value = try self.operand(semantic, 1);
    const semantic_key = try self.operand(semantic, 2);
    const rejoin = try self.operand(jump, 0);
    if (!try self.uintOperandEquals(semantic_pc, pc) or value.kind != .vm_reg or
        value.value >= self.proto.max_stack_size or semantic_key.kind != .vm_const or
        semantic_key.value != key_operand.value or rejoin.kind != .block)
        return null;
    return .{
        .operation = if (semantic.command == ir_cmd_fallback_getglobal) .get else .set,
        .start = start,
        .value = value.value,
        .key = key,
        .pc = pc,
        .fast_target = fallback.value,
        .rejoin = try self.requireCompiledTarget(rejoin),
    };
}
pub fn genericTableFallback(
    self: anytype,
    fallback_id: u32,
    operation: GenericTableOperation,
    value: u32,
    table: u32,
    key: snapshot_v1.IrOperand,
) Error!?GenericTableFallback {
    if (fallback_id >= self.function.block_count)
        return null;
    const block = try self.snapshot.irBlock(self.function, fallback_id);
    if (block.kind != .fallback or block.isEmpty() or block.finish != block.start + 2)
        return null;
    const marker = try self.instruction(block.start);
    const semantic = try self.instruction(block.start + 1);
    const jump = try self.instruction(block.finish);
    const expected_command = if (operation == .set) ir_cmd_set_table else ir_cmd_get_table;
    if (marker.command != .set_savedpc or marker.operand_count != 1 or
        semantic.command != expected_command or semantic.operand_count != 3 or
        jump.command != .jump or jump.operand_count != 1 or try self.savedPc(marker) == 0)
        return null;
    const semantic_value = try self.operand(semantic, 0);
    const semantic_table = try self.operand(semantic, 1);
    const semantic_key = try self.operand(semantic, 2);
    if (semantic_value.kind != .vm_reg or semantic_value.value != value or
        semantic_table.kind != .vm_reg or semantic_table.value != table or
        semantic_key.kind != key.kind or semantic_key.value != key.value)
        return null;
    return .{
        .marker = marker,
        .rejoin = self.requireCompiledTarget(try self.operand(jump, 0)) catch return null,
    };
}
pub noinline fn inlineGenericTableSetPatternAt(self: anytype, start: u32) Error!?InlineGenericTablePattern {
    const commands = [_]snapshot_v1.IrCommand{
        .load_tag,               .check_tag,                .nop,                         .nop,
        .load_pointer,           .nop,                      ir_cmd_try_num_to_index,      .sub_int,
        ir_cmd_check_array_size, ir_cmd_check_no_metatable, ir_cmd_check_readonly,        ir_cmd_get_arr_addr,
        .nop,                    .store_split_tvalue,       ir_cmd_barrier_table_forward,
    };
    if (!try self.commandRangeMatches(start, &commands))
        return null;
    const finish = start + @as(u32, @intCast(commands.len - 1));
    self.requireSingleCompilableBlockRange(start, finish) catch return null;

    {
        // Linearization reuses the earlier numeric key proof and the just-published literal value.
        // Anchor the fused operation in the semantic fallback registers first, then prove every
        // surviving fast-path pointer, index, guard, store, and barrier references those registers.
        const semantic_check = try self.instruction(start + 1);
        if (semantic_check.operand_count != 3)
            return null;
        const semantic_fallback = try self.operand(semantic_check, 2);
        if (semantic_fallback.kind != .block or semantic_fallback.value >= self.function.block_count)
            return null;
        const fallback_block = try self.snapshot.irBlock(self.function, semantic_fallback.value);
        if (fallback_block.kind != .fallback or fallback_block.isEmpty() or fallback_block.finish != fallback_block.start + 2)
            return null;
        const semantic = try self.instruction(fallback_block.start + 1);
        const marker = try self.instruction(fallback_block.start);
        const fallback_jump = try self.instruction(fallback_block.finish);
        if (marker.command != .set_savedpc or marker.operand_count != 1 or try self.savedPc(marker) == 0 or
            semantic.command != ir_cmd_set_table or semantic.operand_count != 3 or
            fallback_jump.command != .jump or fallback_jump.operand_count != 1)
            return null;
        const rejoin = try self.operand(fallback_jump, 0);
        if (rejoin.kind != .block or rejoin.value >= self.function.block_count)
            return null;
        const rejoin_block = try self.snapshot.irBlock(self.function, rejoin.value);
        if (!rejoin_block.kind.isCompilable() or rejoin_block.isEmpty())
            return null;
        const value = self.vmRegisterIndex(try self.operand(semantic, 0)) catch return null;
        const table = self.vmRegisterIndex(try self.operand(semantic, 1)) catch return null;
        const key = self.vmRegisterIndex(try self.operand(semantic, 2)) catch return null;

        const table_load = try self.instruction(start);
        const pointer = try self.instruction(start + 4);
        const index = try self.instruction(start + 6);
        const zero_index = try self.instruction(start + 7);
        const size_check = try self.instruction(start + 8);
        const metatable = try self.instruction(start + 9);
        const readonly = try self.instruction(start + 10);
        const address = try self.instruction(start + 11);
        const store = try self.instruction(start + 13);
        const barrier = try self.instruction(finish);
        const indexed_value = try self.operand(index, 0);
        if (table_load.operand_count != 1 or (try self.operand(table_load, 0)).kind != .vm_reg or
            (try self.operand(table_load, 0)).value != table or pointer.operand_count != 1 or
            (try self.operand(pointer, 0)).kind != .vm_reg or (try self.operand(pointer, 0)).value != table or
            index.operand_count != 2 or indexed_value.kind != .instruction or indexed_value.value >= start)
            return null;
        const key_load = try self.instruction(indexed_value.value);
        if (key_load.command != .load_double or key_load.operand_count != 1 or
            (try self.operand(key_load, 0)).kind != .vm_reg or (try self.operand(key_load, 0)).value != key or
            (try self.operand(index, 1)).kind != .block or
            (try self.operand(index, 1)).value != semantic_fallback.value or
            zero_index.operand_count != 2 or (try self.operand(zero_index, 0)).kind != .instruction or
            (try self.operand(zero_index, 0)).value != start + 6 or
            !try self.intOperandEquals(try self.operand(zero_index, 1), 1))
            return null;
        inline for (.{ size_check, metatable, readonly }) |guard| {
            const failure_index: u32 = if (guard.command == ir_cmd_check_array_size) 2 else 1;
            if ((try self.operand(guard, 0)).kind != .instruction or
                (try self.operand(guard, 0)).value != start + 4 or
                (try self.operand(guard, failure_index)).kind != .block or
                (try self.operand(guard, failure_index)).value != semantic_fallback.value)
                return null;
        }
        if ((try self.operand(size_check, 1)).kind != .instruction or
            (try self.operand(size_check, 1)).value != start + 7)
            return null;
        if ((try self.operand(address, 0)).kind != .instruction or (try self.operand(address, 0)).value != start + 4 or
            (try self.operand(address, 1)).kind != .instruction or (try self.operand(address, 1)).value != start + 7)
            return null;
        if ((store.operand_count != 3 and store.operand_count != 4) or
            (try self.operand(store, 0)).kind != .instruction or
            (try self.operand(store, 0)).value != start + 11 or
            (try self.operand(store, 1)).kind != .constant or
            (try self.constant((try self.operand(store, 1)).value)).tagValue() != lua_tag_table or
            (store.operand_count == 4 and !try self.intOperandEquals(try self.operand(store, 3), 0)))
            return null;
        if (barrier.operand_count != 3 or (try self.operand(barrier, 0)).kind != .instruction or
            (try self.operand(barrier, 0)).value != start + 4 or (try self.operand(barrier, 1)).kind != .vm_reg or
            (try self.operand(barrier, 1)).value != value or (try self.operand(barrier, 2)).kind != .constant or
            (try self.constant((try self.operand(barrier, 2)).value)).tagValue() != lua_tag_table)
            return null;
        const stored_value = try self.operand(store, 2);
        if (stored_value.kind != .instruction or stored_value.value + 2 >= self.function.instruction_count)
            return null;
        const producer = try self.instruction(stored_value.value);
        const publication = try self.instruction(stored_value.value + 1);
        const publication_tag = try self.instruction(stored_value.value + 2);
        if (producer.command != ir_cmd_dup_table or publication.command != .store_pointer or publication.operand_count != 2 or
            publication_tag.command != .store_tag or publication_tag.operand_count != 2 or
            (try self.operand(publication, 0)).kind != .vm_reg or (try self.operand(publication, 0)).value != value or
            (try self.operand(publication, 1)).kind != .instruction or
            (try self.operand(publication, 1)).value != stored_value.value or
            (try self.operand(publication_tag, 0)).kind != .vm_reg or
            (try self.operand(publication_tag, 0)).value != value or
            (try self.operand(publication_tag, 1)).kind != .constant or
            (try self.constant((try self.operand(publication_tag, 1)).value)).tagValue() != lua_tag_table)
            return null;
        return .{
            .pattern = .{
                .operation = .set,
                .start = start,
                .table = table,
                .key = try self.valueOperandEncoding(try self.operand(semantic, 2)),
                .register_key = key,
                .immediate_number_key = null,
                .value = value,
                .marker = marker,
                .fallback = semantic_fallback.value,
                .fast_target = 0,
                .rejoin = rejoin.value,
            },
            .finish = finish,
            .address = start + 11,
        };
    }
}

fn registerStableTo(self: anytype, register: u32, from_id: u32, to_id: u32) Error!bool {
    if (from_id >= to_id)
        return false;
    const origin = self.plan.instructionBlock(from_id) orelse return false;
    const consumer = self.plan.instructionBlock(to_id) orelse return false;
    var block_id = consumer;
    var guard: u32 = 0;
    while (guard < 8) : (guard += 1) {
        const block = try self.snapshot.irBlock(self.function, block_id);
        if (!block.kind.isCompilable() or block.isEmpty())
            return false;
        const begin: u32 = if (block_id == origin) from_id + 1 else block.start;
        const end: u32 = if (block_id == consumer) to_id else block.finish + 1;
        var cursor = begin;
        while (cursor < end) : (cursor += 1) {
            if (try self.instructionWritesRegister(cursor, register))
                return false;
        }
        if (block_id == origin)
            return true;
        const predecessors = self.plan.predecessorSlice(block_id) orelse return false;
        if (predecessors.len != 1)
            return false;
        block_id = predecessors[0];
    }
    return false;
}

fn numericValuePublished(
    self: anytype,
    register: u32,
    source_id: u32,
    tag_constant: u32,
    consumer_id: u32,
) Error!bool {
    var payload: ?u32 = null;
    var instruction_id: u32 = 0;
    while (instruction_id < consumer_id) : (instruction_id += 1) {
        if (!try self.instructionWritesRegister(instruction_id, register))
            continue;
        const instruction_value = try self.instruction(instruction_id);
        if ((instruction_value.command == .store_double or instruction_value.command == .store_tvalue) and
            instruction_value.operand_count == 2)
        {
            const source = try self.operand(instruction_value, 1);
            if (source.kind == .instruction and source.value == source_id)
                payload = instruction_id
            else
                payload = null;
        } else if (instruction_value.command != .store_tag)
            payload = null;
    }
    const published = payload orelse return false;
    const publication = try self.instruction(published);
    var cursor = published + 1;
    if (publication.command == .store_tvalue) {
        while (cursor < consumer_id) : (cursor += 1)
            if (try self.instructionWritesRegister(cursor, register))
                return false;
        return true;
    }
    const expected = (try self.constant(tag_constant)).tagValue() orelse return false;
    var saw_tag = false;
    while (cursor < consumer_id) : (cursor += 1) {
        if (!try self.instructionWritesRegister(cursor, register))
            continue;
        const instruction_value = try self.instruction(cursor);
        if (instruction_value.command != .store_tag or instruction_value.operand_count != 2)
            return false;
        const tag = try self.operand(instruction_value, 1);
        if (tag.kind != .constant or (try self.constant(tag.value)).tagValue() != expected)
            return false;
        saw_tag = true;
    }
    return saw_tag;
}

/// The bytecode numeric write owns the `SET_TABLE` fallback and removes it from dispatch.
/// This linearized copy still branches there. A missing target returns status 2.
/// Emit the owner's direct array write and generic set instead of that branch.
pub noinline fn linearizedNumericTableSetAt(self: anytype, start: u32) Error!?InlineGenericTablePattern {
    const commands = [_]snapshot_v1.IrCommand{
        .load_tag,               .check_tag,                .nop,                         .nop,
        .load_pointer,           .nop,                      ir_cmd_try_num_to_index,      .sub_int,
        ir_cmd_check_array_size, ir_cmd_check_no_metatable, ir_cmd_check_readonly,        ir_cmd_get_arr_addr,
        .nop,                    .store_split_tvalue,
    };
    if (!try self.commandRangeMatches(start, &commands))
        return null;
    const finish = start + @as(u32, @intCast(commands.len - 1));
    self.requireSingleCompilableBlockRange(start, finish) catch return null;

    const table_load = try self.instruction(start);
    const table_check = try self.instruction(start + 1);
    const pointer = try self.instruction(start + 4);
    const index = try self.instruction(start + 6);
    const zero_index = try self.instruction(start + 7);
    const size_check = try self.instruction(start + 8);
    const metatable = try self.instruction(start + 9);
    const readonly = try self.instruction(start + 10);
    const address = try self.instruction(start + 11);
    const store = try self.instruction(start + 13);
    if (table_load.operand_count != 1 or table_check.operand_count != 3 or pointer.operand_count != 1 or
        index.operand_count != 2 or zero_index.operand_count != 2 or size_check.operand_count != 3 or
        metatable.operand_count != 2 or readonly.operand_count != 2 or address.operand_count != 2 or
        store.operand_count != 3)
        return null;

    const table = self.vmRegisterIndex(try self.operand(table_load, 0)) catch return null;
    const checked = try self.operand(table_check, 0);
    const table_tag = try self.operand(table_check, 1);
    const fallback_operand = try self.operand(table_check, 2);
    if (checked.kind != .instruction or checked.value != start or table_tag.kind != .constant or
        (try self.constant(table_tag.value)).tagValue() != lua_tag_table or fallback_operand.kind != .block)
        return null;
    const fallback_id = fallback_operand.value;
    if ((try self.operand(pointer, 0)).kind != .vm_reg or (try self.operand(pointer, 0)).value != table)
        return null;

    const indexed = try self.operand(index, 0);
    const index_failure = try self.operand(index, 1);
    if (indexed.kind != .instruction or index_failure.kind != .block or index_failure.value != fallback_id)
        return null;
    const key_load = try self.instruction(indexed.value);
    if (key_load.command != .load_double or key_load.operand_count != 1)
        return null;
    const key = self.vmRegisterIndex(try self.operand(key_load, 0)) catch return null;
    if (!try registerStableTo(self, key, indexed.value, start))
        return null;
    if ((try self.operand(zero_index, 0)).kind != .instruction or
        (try self.operand(zero_index, 0)).value != start + 6 or
        !try self.intOperandEquals(try self.operand(zero_index, 1), 1))
        return null;
    if ((try self.operand(size_check, 0)).kind != .instruction or
        (try self.operand(size_check, 0)).value != start + 4 or
        (try self.operand(size_check, 1)).kind != .instruction or
        (try self.operand(size_check, 1)).value != start + 7 or
        (try self.operand(size_check, 2)).kind != .block or
        (try self.operand(size_check, 2)).value != fallback_id or
        (try self.operand(metatable, 0)).kind != .instruction or
        (try self.operand(metatable, 0)).value != start + 4 or
        (try self.operand(metatable, 1)).kind != .block or
        (try self.operand(metatable, 1)).value != fallback_id or
        (try self.operand(readonly, 0)).kind != .instruction or
        (try self.operand(readonly, 0)).value != start + 4 or
        (try self.operand(readonly, 1)).kind != .block or
        (try self.operand(readonly, 1)).value != fallback_id or
        (try self.operand(address, 0)).kind != .instruction or
        (try self.operand(address, 0)).value != start + 4 or
        (try self.operand(address, 1)).kind != .instruction or
        (try self.operand(address, 1)).value != start + 7)
        return null;

    const stored_address = try self.operand(store, 0);
    const stored_tag = try self.operand(store, 1);
    const stored_value = try self.operand(store, 2);
    if (stored_address.kind != .instruction or stored_address.value != start + 11 or
        stored_tag.kind != .constant or stored_value.kind != .instruction or
        fallback_id >= self.function.block_count)
        return null;
    const fallback_block = try self.snapshot.irBlock(self.function, fallback_id);
    if (fallback_block.kind != .fallback or fallback_block.isEmpty() or
        fallback_block.finish != fallback_block.start + 2)
        return null;
    const semantic = try self.instruction(fallback_block.start + 1);
    if (semantic.command != ir_cmd_set_table or semantic.operand_count != 3)
        return null;
    const value = self.vmRegisterIndex(try self.operand(semantic, 0)) catch return null;
    const semantic_table = self.vmRegisterIndex(try self.operand(semantic, 1)) catch return null;
    const semantic_key = try self.operand(semantic, 2);
    if (semantic_table != table or semantic_key.kind != .vm_reg or semantic_key.value != key)
        return null;
    if (!try numericValuePublished(self, value, stored_value.value, stored_tag.value, start))
        return null;
    const resolved = (try self.genericTableFallback(fallback_id, .set, value, table, semantic_key)) orelse
        return null;
    return .{
        .pattern = .{
            .operation = .set,
            .start = start,
            .table = table,
            .key = try self.valueOperandEncoding(semantic_key),
            .register_key = key,
            .immediate_number_key = null,
            .value = value,
            .marker = resolved.marker,
            .fallback = fallback_id,
            .fast_target = 0,
            .rejoin = resolved.rejoin,
        },
        .finish = finish,
        .address = start + 11,
    };
}

pub noinline fn semanticTableReloadPatternAt(self: anytype, start: u32) Error!?SemanticTableReloadPattern {
    if (start + 1 >= self.function.instruction_count)
        return null;
    const load = try self.instruction(start);
    const store = try self.instruction(start + 1);
    if (load.command != .load_tvalue or (load.operand_count != 1 and load.operand_count != 2) or
        store.command != .store_tvalue or store.operand_count != 2)
        return null;
    const address = try self.operand(load, 0);
    if (address.kind != .instruction)
        return null;
    if (load.operand_count == 2 and !try self.intOperandEquals(try self.operand(load, 1), 0))
        return null;
    const destination = self.vmRegisterIndex(try self.operand(store, 0)) catch return null;
    const stored = try self.operand(store, 1);
    if (stored.kind != .instruction or stored.value != start)
        return null;

    if (address.value >= 11)
        if (try self.inlineGenericTableSetPatternAt(address.value - 11)) |owner|
            if (owner.address == address.value)
                return .{
                    .start = start,
                    .finish = start + 1,
                    .destination = destination,
                    .table = owner.pattern.table,
                    .key = .{ .dynamic = .{ .register = owner.pattern.key, .marker = owner.pattern.marker } },
                };
    if (try self.literalFieldSetPatternAt(address.value)) |owner|
        return .{
            .start = start,
            .finish = start + 1,
            .destination = destination,
            .table = owner.table,
            .key = .{ .string = .{ .value = owner.key, .pc = owner.pc } },
        };
    return null;
}
pub noinline fn emitSemanticTableReload(self: anytype, pattern: SemanticTableReloadPattern) Error!void {
    switch (pattern.key) {
        .dynamic => |key| {
            try self.emitSavedPcLocation(key.marker);
            try self.body.localGet(self.allocator, 0);
            try self.body.i32Const(self.allocator, @intCast(pattern.destination));
            try self.body.i32Const(self.allocator, @intCast(pattern.table));
            try self.body.i32Const(self.allocator, @intCast(key.register));
            try self.body.call(self.allocator, self.table_get orelse return Error.UnsupportedCommand);
        },
        .string => |key| {
            try self.emitPcLocation(key.pc);
            try emitStringKeyGet(self, pattern.destination, pattern.table, key.value, null);
        },
    }
    if (pattern.key != .string)
        try self.emitReloadBase();
}
pub noinline fn genericTableSetPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?GenericTablePattern {
    if (!block.kind.isCompilable() or block.isEmpty())
        return null;
    const general = [_]snapshot_v1.IrCommand{
        .load_tag,               .check_tag,                .load_tag,                    .check_tag,
        .load_pointer,           .load_double,              ir_cmd_try_num_to_index,      .sub_int,
        ir_cmd_check_array_size, ir_cmd_check_no_metatable, ir_cmd_check_readonly,        ir_cmd_get_arr_addr,
        .load_tvalue,            .store_tvalue,             ir_cmd_barrier_table_forward, .jump,
    };
    const general_reused_value = [_]snapshot_v1.IrCommand{
        .load_tag,               .check_tag,                .load_tag,                    .check_tag,
        .load_pointer,           .load_double,              ir_cmd_try_num_to_index,      .sub_int,
        ir_cmd_check_array_size, ir_cmd_check_no_metatable, ir_cmd_check_readonly,        ir_cmd_get_arr_addr,
        .nop,                    .store_tvalue,             ir_cmd_barrier_table_forward, .jump,
    };
    const trusted = [_]snapshot_v1.IrCommand{
        .load_tag,                    .check_tag,          .nop,                    .load_double,
        ir_cmd_try_num_to_index,      .sub_int,            ir_cmd_check_array_size, .nop,
        .nop,                         ir_cmd_get_arr_addr, .load_tvalue,            .store_tvalue,
        ir_cmd_barrier_table_forward, .jump,
    };
    const trusted_reused_value = [_]snapshot_v1.IrCommand{
        .load_tag,                    .check_tag,          .nop,                    .load_double,
        ir_cmd_try_num_to_index,      .sub_int,            ir_cmd_check_array_size, .nop,
        .nop,                         ir_cmd_get_arr_addr, .nop,                    .store_tvalue,
        ir_cmd_barrier_table_forward, .jump,
    };
    const is_general_loaded = block.finish >= block.start + general.len - 1 and
        try self.commandRangeMatches(block.finish - @as(u32, @intCast(general.len - 1)), &general);
    const is_general_reused = !is_general_loaded and block.finish >= block.start + general_reused_value.len - 1 and
        try self.commandRangeMatches(block.finish - @as(u32, @intCast(general_reused_value.len - 1)), &general_reused_value);
    const is_trusted_loaded = !is_general_loaded and !is_general_reused and block.finish >= block.start + trusted.len - 1 and
        try self.commandRangeMatches(block.finish - @as(u32, @intCast(trusted.len - 1)), &trusted);
    const is_trusted_reused = !is_general_loaded and !is_general_reused and !is_trusted_loaded and
        block.finish >= block.start + trusted_reused_value.len - 1 and
        try self.commandRangeMatches(block.finish - @as(u32, @intCast(trusted_reused_value.len - 1)), &trusted_reused_value);
    const is_general = is_general_loaded or is_general_reused;
    const is_trusted = is_trusted_loaded or is_trusted_reused;
    const has_value_load = is_general_loaded or is_trusted_loaded;
    if (!is_general and !is_trusted)
        return null;
    const command_count = if (is_general) general.len else trusted.len;
    const start = block.finish - @as(u32, @intCast(command_count - 1));
    if (is_trusted and start < 6)
        return null;
    const key_load_id = start + (if (is_general) @as(u32, 2) else 0);
    const key_check_id = key_load_id + 1;
    const pointer_id = if (is_general) start + 4 else start - 6;
    const number_load_id = start + (if (is_general) @as(u32, 5) else 3);
    const index_id = number_load_id + 1;
    const zero_index_id = index_id + 1;
    const size_check_id = zero_index_id + 1;
    const address_id = start + (if (is_general) @as(u32, 11) else 9);
    const value_load_id = address_id + 1;
    const store_id = value_load_id + 1;
    const barrier_id = store_id + 1;

    const key_load = try self.instruction(key_load_id);
    const key_check = try self.instruction(key_check_id);
    const number_load = try self.instruction(number_load_id);
    const index = try self.instruction(index_id);
    const zero_index = try self.instruction(zero_index_id);
    const size_check = try self.instruction(size_check_id);
    const address = try self.instruction(address_id);
    const value_load = try self.instruction(value_load_id);
    const store = try self.instruction(store_id);
    const barrier = try self.instruction(barrier_id);
    const jump = try self.instruction(block.finish);
    if (key_load.operand_count != 1 or key_check.operand_count != 3 or number_load.operand_count != 1 or
        index.operand_count != 2 or zero_index.operand_count != 2 or size_check.operand_count != 3 or
        address.operand_count != 2 or value_load.operand_count != (if (has_value_load) @as(u32, 1) else 0) or
        store.operand_count != 2 or
        barrier.operand_count != 3 or jump.operand_count != 1)
        return null;
    const key = try self.vmRegisterIndex(try self.operand(key_load, 0));
    const checked_key = try self.operand(key_check, 0);
    const number_tag = try self.operand(key_check, 1);
    const fallback_target = try self.operand(key_check, 2);
    if (checked_key.kind != .instruction or checked_key.value != key_load_id or number_tag.kind != .constant or
        (try self.constant(number_tag.value)).tagValue() != lua_tag_number or fallback_target.kind != .block)
        return null;
    const loaded_key = try self.operand(number_load, 0);
    const indexed = try self.operand(index, 0);
    const index_fallback = try self.operand(index, 1);
    const zero_source = try self.operand(zero_index, 0);
    const size_pointer = try self.operand(size_check, 0);
    const size_index = try self.operand(size_check, 1);
    const size_fallback = try self.operand(size_check, 2);
    const address_pointer = try self.operand(address, 0);
    const address_index = try self.operand(address, 1);
    const store_address = try self.operand(store, 0);
    const store_value = try self.operand(store, 1);
    const barrier_pointer = try self.operand(barrier, 0);
    const barrier_source = try self.operand(barrier, 1);
    const barrier_tag = try self.operand(barrier, 2);
    const fast_target = try self.operand(jump, 0);
    if (loaded_key.kind != .vm_reg or loaded_key.value != key or indexed.kind != .instruction or indexed.value != number_load_id or
        index_fallback.kind != .block or index_fallback.value != fallback_target.value or
        zero_source.kind != .instruction or zero_source.value != index_id or
        !try self.intOperandEquals(try self.operand(zero_index, 1), 1) or
        size_pointer.kind != .instruction or size_pointer.value != pointer_id or
        size_index.kind != .instruction or size_index.value != zero_index_id or
        size_fallback.kind != .block or size_fallback.value != fallback_target.value or
        address_pointer.kind != .instruction or address_pointer.value != pointer_id or
        address_index.kind != .instruction or address_index.value != zero_index_id or
        store_address.kind != .instruction or store_address.value != address_id or store_value.kind != .instruction or
        barrier_pointer.kind != .instruction or barrier_pointer.value != pointer_id or
        barrier_source.kind != .vm_reg or barrier_tag.kind != .undef or
        fast_target.kind != .block)
        return null;

    const source = try self.vmRegisterIndex(barrier_source);
    if (has_value_load) {
        const loaded_source = try self.operand(value_load, 0);
        if (loaded_source.kind != .vm_reg or loaded_source.value != source or store_value.value != value_load_id)
            return null;
    } else {
        // Upstream can reuse a TValue SSA producer that it has just published to the source VM
        // register, leaving a NOP where the ordinary cluster reloads that register.  The fused
        // lowering consumes the VM register through the semantic helper, so admit this only when
        // the immediately preceding STORE_TVALUE proves both identities and the reused value is
        // a real TValue producer owned by the already executed prefix.
        if (start == block.start or store_value.value >= start)
            return null;
        const publication = try self.instruction(start - 1);
        if (publication.command != .store_tvalue or publication.operand_count != 2)
            return null;
        const published_register = try self.operand(publication, 0);
        const published_value = try self.operand(publication, 1);
        if (published_register.kind != .vm_reg or published_register.value != source or
            published_value.kind != .instruction or published_value.value != store_value.value)
            return null;
    }

    var table: u32 = undefined;
    if (is_general) {
        const table_load = try self.instruction(start);
        const table_check = try self.instruction(start + 1);
        const pointer = try self.instruction(pointer_id);
        if (table_load.operand_count != 1 or table_check.operand_count != 3 or pointer.operand_count != 1)
            return null;
        table = try self.vmRegisterIndex(try self.operand(table_load, 0));
        const checked_table = try self.operand(table_check, 0);
        const table_tag = try self.operand(table_check, 1);
        const table_failure = try self.operand(table_check, 2);
        const pointer_table = try self.operand(pointer, 0);
        const canonical_table_failure = table_failure.kind == .vm_exit or
            (table_failure.kind == .block and table_failure.value == fallback_target.value);
        if (checked_table.kind != .instruction or checked_table.value != start or table_tag.kind != .constant or
            (try self.constant(table_tag.value)).tagValue() != lua_tag_table or !canonical_table_failure or
            pointer_table.kind != .vm_reg or pointer_table.value != table)
            return null;
        const metatable = try self.instruction(start + 9);
        const readonly = try self.instruction(start + 10);
        if (metatable.operand_count != 2 or readonly.operand_count != 2 or
            (try self.operand(metatable, 0)).kind != .instruction or (try self.operand(metatable, 0)).value != pointer_id or
            (try self.operand(metatable, 1)).kind != .block or (try self.operand(metatable, 1)).value != fallback_target.value or
            (try self.operand(readonly, 0)).kind != .instruction or (try self.operand(readonly, 0)).value != pointer_id or
            (try self.operand(readonly, 1)).kind != .block or (try self.operand(readonly, 1)).value != fallback_target.value)
            return null;
    } else {
        const covering = self.plan.tableAllocCovering(pointer_id) orelse return null;
        const allocation = (try self.tableAllocationPatternAt(covering.start)) orelse return null;
        if (allocation.start != pointer_id or allocation.destination >= self.proto.max_stack_size)
            return null;
        table = allocation.destination;
        const pointer_nop = try self.instruction(start + 2);
        const metatable_nop = try self.instruction(start + 7);
        const readonly_nop = try self.instruction(start + 8);
        if (pointer_nop.operand_count != 0 or metatable_nop.operand_count != 0 or readonly_nop.operand_count != 0)
            return null;
    }
    const semantic_key = try self.operand(try self.instruction((try self.snapshot.irBlock(self.function, fallback_target.value)).start + 1), 2);
    const fallback = (try self.genericTableFallback(fallback_target.value, .set, source, table, semantic_key)) orelse return null;
    return .{
        .operation = .set,
        .start = start,
        .table = table,
        .key = try self.valueOperandEncoding(semantic_key),
        .register_key = key,
        .immediate_number_key = null,
        .value = source,
        .marker = fallback.marker,
        .fallback = fallback_target.value,
        .fast_target = try self.requireCompiledTarget(fast_target),
        .rejoin = fallback.rejoin,
    };
}
pub noinline fn genericTableGetPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?GenericTablePattern {
    const commands = [_]snapshot_v1.IrCommand{
        .load_tag,               .check_tag, .load_tag,               .check_tag,                .load_pointer,       .load_double,
        ir_cmd_try_num_to_index, .sub_int,   ir_cmd_check_array_size, ir_cmd_check_no_metatable, ir_cmd_get_arr_addr, .load_tvalue,
        .store_tvalue,           .jump,
    };
    if (!block.kind.isCompilable() or block.isEmpty() or block.finish < block.start + commands.len - 1)
        return null;
    const start = block.finish - @as(u32, @intCast(commands.len - 1));
    if (!try self.commandRangeMatches(start, &commands))
        return null;
    const table = try self.vmRegisterIndex(try self.operand(try self.instruction(start), 0));
    const table_check = try self.instruction(start + 1);
    const key = try self.vmRegisterIndex(try self.operand(try self.instruction(start + 2), 0));
    const key_check = try self.instruction(start + 3);
    const pointer = try self.instruction(start + 4);
    const number_load = try self.instruction(start + 5);
    const index = try self.instruction(start + 6);
    const zero_index = try self.instruction(start + 7);
    const size_check = try self.instruction(start + 8);
    const metatable = try self.instruction(start + 9);
    const address = try self.instruction(start + 10);
    const load = try self.instruction(start + 11);
    const store = try self.instruction(start + 12);
    const jump = try self.instruction(block.finish);
    if (table_check.operand_count != 3 or key_check.operand_count != 3 or pointer.operand_count != 1 or
        number_load.operand_count != 1 or index.operand_count != 2 or zero_index.operand_count != 2 or
        size_check.operand_count != 3 or metatable.operand_count != 2 or address.operand_count != 2 or
        load.operand_count != 1 or store.operand_count != 2 or jump.operand_count != 1)
        return null;
    const table_fallback = try self.operand(table_check, 2);
    const key_fallback = try self.operand(key_check, 2);
    if ((try self.operand(table_check, 0)).kind != .instruction or (try self.operand(table_check, 0)).value != start or
        (try self.operand(table_check, 1)).kind != .constant or
        (try self.constant((try self.operand(table_check, 1)).value)).tagValue() != lua_tag_table or
        table_fallback.kind != .block or
        (try self.operand(key_check, 0)).kind != .instruction or (try self.operand(key_check, 0)).value != start + 2 or
        (try self.operand(key_check, 1)).kind != .constant or
        (try self.constant((try self.operand(key_check, 1)).value)).tagValue() != lua_tag_number or
        key_fallback.kind != .block or key_fallback.value != table_fallback.value or
        (try self.operand(pointer, 0)).kind != .vm_reg or (try self.operand(pointer, 0)).value != table or
        (try self.operand(number_load, 0)).kind != .vm_reg or (try self.operand(number_load, 0)).value != key or
        (try self.operand(index, 0)).kind != .instruction or (try self.operand(index, 0)).value != start + 5 or
        (try self.operand(index, 1)).kind != .block or (try self.operand(index, 1)).value != table_fallback.value or
        (try self.operand(zero_index, 0)).kind != .instruction or (try self.operand(zero_index, 0)).value != start + 6 or
        !try self.intOperandEquals(try self.operand(zero_index, 1), 1) or
        (try self.operand(size_check, 0)).kind != .instruction or (try self.operand(size_check, 0)).value != start + 4 or
        (try self.operand(size_check, 1)).kind != .instruction or (try self.operand(size_check, 1)).value != start + 7 or
        (try self.operand(size_check, 2)).kind != .block or (try self.operand(size_check, 2)).value != table_fallback.value or
        (try self.operand(metatable, 0)).kind != .instruction or (try self.operand(metatable, 0)).value != start + 4 or
        (try self.operand(metatable, 1)).kind != .block or (try self.operand(metatable, 1)).value != table_fallback.value or
        (try self.operand(address, 0)).kind != .instruction or (try self.operand(address, 0)).value != start + 4 or
        (try self.operand(address, 1)).kind != .instruction or (try self.operand(address, 1)).value != start + 7 or
        (try self.operand(load, 0)).kind != .instruction or (try self.operand(load, 0)).value != start + 10)
        return null;
    const destination = try self.vmRegisterIndex(try self.operand(store, 0));
    const stored = try self.operand(store, 1);
    const fast_target = try self.operand(jump, 0);
    if (stored.kind != .instruction or stored.value != start + 11 or fast_target.kind != .block)
        return null;
    const semantic_key = try self.operand(try self.instruction((try self.snapshot.irBlock(self.function, table_fallback.value)).start + 1), 2);
    const fallback = (try self.genericTableFallback(table_fallback.value, .get, destination, table, semantic_key)) orelse return null;
    return .{
        .operation = .get,
        .start = start,
        .table = table,
        .key = try self.valueOperandEncoding(semantic_key),
        .register_key = key,
        .immediate_number_key = null,
        .value = destination,
        .marker = fallback.marker,
        .fallback = table_fallback.value,
        .fast_target = try self.requireCompiledTarget(fast_target),
        .rejoin = fallback.rejoin,
    };
}
pub noinline fn constantGenericTableGetPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?GenericTablePattern {
    const command_count: u32 = 9;
    if (block.isEmpty() or block.finish < block.start + command_count - 1)
        return null;
    const candidate_start = block.finish - (command_count - 1);
    const tag_check = try self.instruction(candidate_start + 1);
    if (tag_check.operand_count != 3)
        return null;
    const fallback_operand = try self.operand(tag_check, 2);
    if (fallback_operand.kind != .block or fallback_operand.value >= self.function.block_count)
        return null;
    const fallback_block = try self.snapshot.irBlock(self.function, fallback_operand.value);
    if (fallback_block.kind != .fallback or fallback_block.isEmpty() or fallback_block.finish != fallback_block.start + 2)
        return null;
    const semantic = try self.instruction(fallback_block.start + 1);
    if (semantic.command != ir_cmd_get_table or semantic.operand_count != 3)
        return null;
    const semantic_key = try self.operand(semantic, 2);
    if (semantic_key.kind != .constant)
        return null;
    const direct = (try self.arrayGetPattern(block)) orelse return null;
    const key_constant = try self.constant(semantic_key.value);
    const number: f64 = switch (key_constant.kind) {
        .int => @floatFromInt(key_constant.intValue() orelse return null),
        .uint => @floatFromInt(key_constant.uintValue() orelse return null),
        .int64 => @floatFromInt(key_constant.int64Value() orelse return null),
        .double => key_constant.doubleValue() orelse return null,
        .tag, .import => return null,
    };
    if (!std.math.isFinite(number) or number < 1 or number > std.math.maxInt(u32) or @trunc(number) != number)
        return null;
    const one_based_index: u32 = @intFromFloat(number);
    if (one_based_index != direct.index)
        return null;
    const fallback = (try self.genericTableFallback(
        fallback_operand.value,
        .get,
        direct.destination,
        direct.table,
        semantic_key,
    )) orelse return null;
    return .{
        .operation = .get,
        .start = direct.start,
        .table = direct.table,
        // Materialize the immutable IR immediate in the result register before calling the
        // existing TValue-key semantic helper. Destination/key overlap is valid for
        // luaV_gettable, which consumes the key before publishing its result.
        .key = direct.destination,
        .register_key = null,
        .immediate_number_key = number,
        .value = direct.destination,
        .marker = fallback.marker,
        .fallback = fallback_operand.value,
        .fast_target = direct.rejoin,
        .rejoin = fallback.rejoin,
    };
}
pub noinline fn inlineConstantTableGetPatternAt(self: anytype, start: u32) Error!?InlineConstantTableGetPattern {
    const commands = [_]snapshot_v1.IrCommand{
        .load_tag,
        .check_tag,
        .load_pointer,
        ir_cmd_check_array_size,
        ir_cmd_check_no_metatable,
        ir_cmd_get_arr_addr,
        .load_tvalue,
        .store_tvalue,
    };
    if (!try self.commandRangeMatches(start, &commands))
        return null;
    const finish = start + @as(u32, @intCast(commands.len - 1));
    self.requireSingleCompilableBlockRange(start, finish) catch return null;

    const table_load = try self.instruction(start);
    const tag_check = try self.instruction(start + 1);
    const pointer = try self.instruction(start + 2);
    const size_check = try self.instruction(start + 3);
    const metatable_check = try self.instruction(start + 4);
    const address = try self.instruction(start + 5);
    const load = try self.instruction(start + 6);
    const store = try self.instruction(finish);
    if (table_load.operand_count != 1 or tag_check.operand_count != 3 or pointer.operand_count != 1 or
        size_check.operand_count != 3 or metatable_check.operand_count != 2 or address.operand_count != 2 or
        load.operand_count != 2 or store.operand_count != 2)
        return null;

    const table = self.vmRegisterIndex(try self.operand(table_load, 0)) catch return null;
    const checked = try self.operand(tag_check, 0);
    const table_tag = try self.operand(tag_check, 1);
    const fallback_operand = try self.operand(tag_check, 2);
    if (checked.kind != .instruction or checked.value != start or table_tag.kind != .constant or
        (try self.constant(table_tag.value)).tagValue() != lua_tag_table or
        fallback_operand.kind != .block or fallback_operand.value >= self.function.block_count)
        return null;
    if ((try self.operand(pointer, 0)).kind != .vm_reg or (try self.operand(pointer, 0)).value != table)
        return null;

    const zero_based = self.intConstant(try self.operand(size_check, 1)) catch return null;
    if (zero_based < 0)
        return null;
    const index: u32 = std.math.add(u32, @intCast(zero_based), 1) catch return null;
    if ((try self.operand(size_check, 0)).kind != .instruction or
        (try self.operand(size_check, 0)).value != start + 2 or
        (try self.operand(size_check, 2)).kind != .block or
        (try self.operand(size_check, 2)).value != fallback_operand.value or
        (try self.operand(metatable_check, 0)).kind != .instruction or
        (try self.operand(metatable_check, 0)).value != start + 2 or
        (try self.operand(metatable_check, 1)).kind != .block or
        (try self.operand(metatable_check, 1)).value != fallback_operand.value)
        return null;

    const address_offset = self.nonnegativeConstant(try self.operand(address, 1)) catch return null;
    const load_offset = self.nonnegativeConstant(try self.operand(load, 1)) catch return null;
    const expected_offset = std.math.mul(u32, @intCast(zero_based), tvalue_size) catch return null;
    if ((try self.operand(address, 0)).kind != .instruction or
        (try self.operand(address, 0)).value != start + 2 or address_offset != 0 or
        (try self.operand(load, 0)).kind != .instruction or
        (try self.operand(load, 0)).value != start + 5 or load_offset != expected_offset)
        return null;
    const destination = self.vmRegisterIndex(try self.operand(store, 0)) catch return null;
    if ((try self.operand(store, 1)).kind != .instruction or (try self.operand(store, 1)).value != start + 6)
        return null;

    const fallback_block = try self.snapshot.irBlock(self.function, fallback_operand.value);
    if (fallback_block.kind != .fallback or fallback_block.isEmpty() or fallback_block.finish != fallback_block.start + 2)
        return null;
    const semantic = try self.instruction(fallback_block.start + 1);
    if (semantic.command != ir_cmd_get_table or semantic.operand_count != 3)
        return null;
    const semantic_key = try self.operand(semantic, 2);
    if (semantic_key.kind != .constant)
        return null;
    const key_constant = try self.constant(semantic_key.value);
    const number: f64 = switch (key_constant.kind) {
        .int => @floatFromInt(key_constant.intValue() orelse return null),
        .uint => @floatFromInt(key_constant.uintValue() orelse return null),
        .int64 => @floatFromInt(key_constant.int64Value() orelse return null),
        .double => key_constant.doubleValue() orelse return null,
        .tag, .import => return null,
    };
    if (!std.math.isFinite(number) or number != @as(f64, @floatFromInt(index)))
        return null;
    const fallback = (try self.genericTableFallback(
        fallback_operand.value,
        .get,
        destination,
        table,
        semantic_key,
    )) orelse return null;
    return .{
        .pattern = .{
            .operation = .get,
            .start = start,
            .table = table,
            .key = destination,
            .register_key = null,
            .immediate_number_key = number,
            .value = destination,
            .marker = fallback.marker,
            .fallback = fallback_operand.value,
            .fast_target = 0,
            .rejoin = fallback.rejoin,
        },
        .finish = finish,
    };
}
pub noinline fn genericTablePattern(self: anytype, block: snapshot_v1.IrBlock) Error!?GenericTablePattern {
    if (try self.genericTableSetPattern(block)) |pattern|
        return pattern;
    if (try self.genericTableGetPattern(block)) |pattern|
        return pattern;
    return self.constantGenericTableGetPattern(block);
}
pub noinline fn arraySetPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?ArrayOperationPattern {
    const commands = [_]snapshot_v1.IrCommand{
        .load_tag,             .check_tag,          .load_pointer, ir_cmd_check_array_size, ir_cmd_check_no_metatable,
        ir_cmd_check_readonly, ir_cmd_get_arr_addr, .load_tvalue,  .store_tvalue,           ir_cmd_barrier_table_forward,
        .jump,
    };
    if (block.isEmpty() or block.finish - block.start != commands.len - 1 or
        !try self.commandRangeMatches(block.start, &commands))
        return null;
    const table_operand = try self.operand(try self.instruction(block.start), 0);
    const tag_check = try self.instruction(block.start + 1);
    const table_pointer = try self.instruction(block.start + 2);
    const size_check = try self.instruction(block.start + 3);
    const metatable_check = try self.instruction(block.start + 4);
    const readonly_check = try self.instruction(block.start + 5);
    const array_address = try self.instruction(block.start + 6);
    const store = try self.instruction(block.start + 8);
    const barrier = try self.instruction(block.start + 9);
    const source_operand = try self.operand(try self.instruction(block.start + 7), 0);
    const jump = try self.instruction(block.finish);
    const target = try self.operand(jump, 0);
    if (table_operand.kind != .vm_reg or source_operand.kind != .vm_reg or target.kind != .block)
        return null;
    const index = try self.intConstant(try self.operand(size_check, 1));
    if (index < 0)
        return null;
    const pointer_source = try self.operand(table_pointer, 0);
    const checked_tag = try self.operand(tag_check, 0);
    const tag_value = try self.operand(tag_check, 1);
    const tag_failure = try self.operand(tag_check, 2);
    const size_pointer = try self.operand(size_check, 0);
    const fallback = try self.operand(size_check, 2);
    const meta_pointer = try self.operand(metatable_check, 0);
    const meta_fallback = try self.operand(metatable_check, 1);
    const readonly_pointer = try self.operand(readonly_check, 0);
    const readonly_fallback = try self.operand(readonly_check, 1);
    const address_pointer = try self.operand(array_address, 0);
    const address_offset = try self.nonnegativeConstant(try self.operand(array_address, 1));
    const store_address = try self.operand(store, 0);
    const store_value = try self.operand(store, 1);
    const store_offset = try self.nonnegativeConstant(try self.operand(store, 2));
    const barrier_pointer = try self.operand(barrier, 0);
    const barrier_source = try self.operand(barrier, 1);
    const barrier_tag = try self.operand(barrier, 2);
    if (checked_tag.kind != .instruction or checked_tag.value != block.start or
        pointer_source.kind != .vm_reg or pointer_source.value != table_operand.value or
        tag_value.kind != .constant or (try self.constant(tag_value.value)).tagValue() != lua_tag_table or
        tag_failure.kind != .vm_exit or
        size_pointer.kind != .instruction or size_pointer.value != block.start + 2 or fallback.kind != .block or
        meta_pointer.kind != .instruction or meta_pointer.value != block.start + 2 or
        meta_fallback.kind != .block or meta_fallback.value != fallback.value or
        readonly_pointer.kind != .instruction or readonly_pointer.value != block.start + 2 or
        readonly_fallback.kind != .block or readonly_fallback.value != fallback.value or
        address_pointer.kind != .instruction or address_pointer.value != block.start + 2 or address_offset != 0 or
        store_address.kind != .instruction or store_address.value != block.start + 6 or
        store_value.kind != .instruction or store_value.value != block.start + 7 or
        store_offset != @as(u32, @intCast(index)) * tvalue_size or
        barrier_pointer.kind != .instruction or barrier_pointer.value != block.start + 2 or
        barrier_source.kind != .vm_reg or barrier_source.value != source_operand.value or barrier_tag.kind != .undef)
        return null;
    return .{
        .start = block.start,
        .table = try self.vmRegisterIndex(table_operand),
        .source = try self.vmRegisterIndex(source_operand),
        .index = std.math.add(u32, @intCast(index), 1) catch return null,
        .rejoin = try self.requireDispatchTarget(target),
    };
}
pub noinline fn arrayGetPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?ArrayOperationPattern {
    const commands = [_]snapshot_v1.IrCommand{
        .load_tag,           .check_tag,   .load_pointer, ir_cmd_check_array_size, ir_cmd_check_no_metatable,
        ir_cmd_get_arr_addr, .load_tvalue, .store_tvalue, .jump,
    };
    if (block.isEmpty() or block.finish < block.start + commands.len - 1)
        return null;
    const start = block.finish - @as(u32, @intCast(commands.len - 1));
    if (!try self.commandRangeMatches(start, &commands))
        return null;
    const table_operand = try self.operand(try self.instruction(start), 0);
    const tag_check = try self.instruction(start + 1);
    const table_pointer = try self.instruction(start + 2);
    const size_check = try self.instruction(start + 3);
    const metatable_check = try self.instruction(start + 4);
    const array_address = try self.instruction(start + 5);
    const load_value = try self.instruction(start + 6);
    const store = try self.instruction(start + 7);
    const destination = try self.operand(store, 0);
    const target = try self.operand(try self.instruction(block.finish), 0);
    if (table_operand.kind != .vm_reg or destination.kind != .vm_reg or target.kind != .block)
        return null;
    const index = try self.intConstant(try self.operand(size_check, 1));
    if (index < 0)
        return null;
    const pointer_source = try self.operand(table_pointer, 0);
    const checked_tag = try self.operand(tag_check, 0);
    const tag_value = try self.operand(tag_check, 1);
    const tag_fallback = try self.operand(tag_check, 2);
    const size_pointer = try self.operand(size_check, 0);
    const fallback = try self.operand(size_check, 2);
    const meta_pointer = try self.operand(metatable_check, 0);
    const meta_fallback = try self.operand(metatable_check, 1);
    const address_pointer = try self.operand(array_address, 0);
    const address_offset = try self.nonnegativeConstant(try self.operand(array_address, 1));
    const load_address = try self.operand(load_value, 0);
    const load_offset = try self.nonnegativeConstant(try self.operand(load_value, 1));
    const stored_value = try self.operand(store, 1);
    if (checked_tag.kind != .instruction or checked_tag.value != start or
        pointer_source.kind != .vm_reg or pointer_source.value != table_operand.value or
        tag_value.kind != .constant or (try self.constant(tag_value.value)).tagValue() != lua_tag_table or
        tag_fallback.kind != .block or size_pointer.kind != .instruction or size_pointer.value != start + 2 or
        fallback.kind != .block or fallback.value != tag_fallback.value or
        meta_pointer.kind != .instruction or meta_pointer.value != start + 2 or
        meta_fallback.kind != .block or meta_fallback.value != fallback.value or
        address_pointer.kind != .instruction or address_pointer.value != start + 2 or address_offset != 0 or
        load_address.kind != .instruction or load_address.value != start + 5 or
        load_offset != @as(u32, @intCast(index)) * tvalue_size or
        stored_value.kind != .instruction or stored_value.value != start + 6)
        return null;
    return .{
        .start = start,
        .destination = try self.vmRegisterIndex(destination),
        .table = try self.vmRegisterIndex(table_operand),
        .index = std.math.add(u32, @intCast(index), 1) catch return null,
        .rejoin = try self.requireDispatchTarget(target),
    };
}
pub noinline fn trustedArrayGetPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?ArrayOperationPattern {
    if (block.isEmpty() or block.finish < block.start + 2)
        return null;
    const start = block.finish - 2;
    const load = try self.instruction(start);
    const store = try self.instruction(start + 1);
    const jump = try self.instruction(start + 2);
    if (load.command != .load_tvalue or load.operand_count != 2 or
        store.command != .store_tvalue or store.operand_count != 2 or jump.command != .jump)
        return null;
    const address_operand = try self.operand(load, 0);
    const destination = try self.operand(store, 0);
    const stored = try self.operand(store, 1);
    const target = try self.operand(jump, 0);
    if (address_operand.kind != .instruction or destination.kind != .vm_reg or
        stored.kind != .instruction or stored.value != start or target.kind != .block)
        return null;
    const address = try self.instruction(address_operand.value);
    if (address.command != ir_cmd_get_arr_addr or address.operand_count != 2)
        return null;
    const table_pointer_operand = try self.operand(address, 0);
    if (table_pointer_operand.kind != .instruction)
        return null;
    const table_pointer = try self.instruction(table_pointer_operand.value);
    if (table_pointer.command != .load_pointer or table_pointer.operand_count != 1)
        return null;
    const table = try self.operand(table_pointer, 0);
    if (table.kind != .vm_reg)
        return null;
    const load_offset = self.nonnegativeConstant(try self.operand(load, 1)) catch return null;
    const address_offset = self.nonnegativeConstant(try self.operand(address, 1)) catch return null;
    if (load_offset % tvalue_size != 0 or address_offset % tvalue_size != 0)
        return null;
    const zero_based = std.math.add(u32, address_offset / tvalue_size, load_offset / tvalue_size) catch return null;
    return .{
        .start = start,
        .destination = try self.vmRegisterIndex(destination),
        .table = try self.vmRegisterIndex(table),
        .index = std.math.add(u32, zero_based, 1) catch return null,
        .rejoin = try self.requireDispatchTarget(target),
    };
}
pub fn trustedArrayAddress(self: anytype, instruction_id: u32) Error!bool {
    const address = try self.instruction(instruction_id);
    if (address.command != ir_cmd_get_arr_addr or address.operand_count != 2)
        return false;
    const table_pointer_operand = try self.operand(address, 0);
    _ = try self.nonnegativeConstant(try self.operand(address, 1));
    if (table_pointer_operand.kind != .instruction)
        return false;
    const table_pointer = try self.instruction(table_pointer_operand.value);
    if (table_pointer.command != .load_pointer or table_pointer.operand_count != 1)
        return false;
    const table = try self.operand(table_pointer, 0);
    if (table.kind != .vm_reg)
        return false;
    return true;
}
pub noinline fn inlineArrayGetPatternAt(self: anytype, start: u32) Error!?InlineArrayGetPattern {
    const commands = [_]snapshot_v1.IrCommand{ ir_cmd_get_arr_addr, .load_tvalue, .store_tvalue };
    if (!try self.commandRangeMatches(start, &commands))
        return null;
    const finish = start + 2;
    self.requireSingleCompilableBlockRange(start, finish) catch return null;
    const address = try self.instruction(start);
    const load = try self.instruction(start + 1);
    const store = try self.instruction(finish);
    if (address.operand_count != 2 or load.operand_count != 2 or store.operand_count != 2)
        return null;
    const pointer_operand = try self.operand(address, 0);
    if (pointer_operand.kind != .instruction)
        return null;
    const pointer = try self.instruction(pointer_operand.value);
    if (pointer.command != .load_pointer or pointer.operand_count != 1)
        return null;
    const table = self.vmRegisterIndex(try self.operand(pointer, 0)) catch return null;
    if ((try self.operand(load, 0)).kind != .instruction or (try self.operand(load, 0)).value != start or
        (try self.operand(store, 1)).kind != .instruction or (try self.operand(store, 1)).value != start + 1)
        return null;
    const address_offset = self.nonnegativeConstant(try self.operand(address, 1)) catch return null;
    const load_offset = self.nonnegativeConstant(try self.operand(load, 1)) catch return null;
    if (address_offset % tvalue_size != 0 or load_offset % tvalue_size != 0)
        return null;
    const zero_based = std.math.add(u32, address_offset / tvalue_size, load_offset / tvalue_size) catch return null;
    return .{
        .start = start,
        .finish = finish,
        .destination = self.vmRegisterIndex(try self.operand(store, 0)) catch return null,
        .table = table,
        .index = std.math.add(u32, zero_based, 1) catch return null,
    };
}
pub noinline fn tableLenPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?ArrayOperationPattern {
    const commands = [_]snapshot_v1.IrCommand{
        .load_tag,   .check_tag,    .load_pointer, ir_cmd_check_no_metatable, ir_cmd_table_len,
        .int_to_num, .store_double, .store_tag,    .jump,
    };
    if (block.isEmpty() or block.finish < block.start + commands.len - 1)
        return null;
    const start = block.finish - @as(u32, @intCast(commands.len - 1));
    if (!try self.commandRangeMatches(start, &commands))
        return null;
    const table_operand = try self.operand(try self.instruction(start), 0);
    const tag_check = try self.instruction(start + 1);
    const table_pointer = try self.instruction(start + 2);
    const metatable_check = try self.instruction(start + 3);
    const length = try self.instruction(start + 4);
    const convert = try self.instruction(start + 5);
    const store = try self.instruction(start + 6);
    const store_tag = try self.instruction(start + 7);
    const destination = try self.operand(store, 0);
    const target = try self.operand(try self.instruction(block.finish), 0);
    if (table_operand.kind != .vm_reg or destination.kind != .vm_reg or target.kind != .block)
        return null;
    const pointer_source = try self.operand(table_pointer, 0);
    const checked_tag = try self.operand(tag_check, 0);
    const tag_value = try self.operand(tag_check, 1);
    const tag_fallback = try self.operand(tag_check, 2);
    const meta_pointer = try self.operand(metatable_check, 0);
    const meta_fallback = try self.operand(metatable_check, 1);
    const length_pointer = try self.operand(length, 0);
    const converted_length = try self.operand(convert, 0);
    const stored_length = try self.operand(store, 1);
    const tag_destination = try self.operand(store_tag, 0);
    const result_tag = try self.operand(store_tag, 1);
    if (checked_tag.kind != .instruction or checked_tag.value != start or
        pointer_source.kind != .vm_reg or pointer_source.value != table_operand.value or
        tag_value.kind != .constant or (try self.constant(tag_value.value)).tagValue() != lua_tag_table or
        tag_fallback.kind != .block or meta_pointer.kind != .instruction or meta_pointer.value != start + 2 or
        meta_fallback.kind != .block or meta_fallback.value != tag_fallback.value or
        length_pointer.kind != .instruction or length_pointer.value != start + 2 or
        converted_length.kind != .instruction or converted_length.value != start + 4 or
        stored_length.kind != .instruction or stored_length.value != start + 5 or
        tag_destination.kind != .vm_reg or tag_destination.value != destination.value or
        result_tag.kind != .constant or (try self.constant(result_tag.value)).tagValue() != lua_tag_number)
        return null;
    return .{
        .start = start,
        .destination = try self.vmRegisterIndex(destination),
        .table = try self.vmRegisterIndex(table_operand),
        .rejoin = try self.requireDispatchTarget(target),
    };
}
pub noinline fn dynamicLengthPattern(self: anytype, block: snapshot_v1.IrBlock) Error!?DynamicLengthPattern {
    const commands = [_]snapshot_v1.IrCommand{
        .load_tag,   .check_tag,    .load_pointer, ir_cmd_check_no_metatable, ir_cmd_table_len,
        .int_to_num, .store_double, .store_tag,    .jump,
    };
    if (block.isEmpty() or block.finish < block.start + commands.len - 1)
        return null;
    const start = block.finish - @as(u32, @intCast(commands.len - 1));
    if (!try self.commandRangeMatches(start, &commands))
        return null;

    const source = try self.vmRegisterIndex(try self.operand(try self.instruction(start), 0));
    const tag_check = try self.instruction(start + 1);
    const pointer = try self.instruction(start + 2);
    const metatable = try self.instruction(start + 3);
    const length = try self.instruction(start + 4);
    const convert = try self.instruction(start + 5);
    const store = try self.instruction(start + 6);
    const store_tag = try self.instruction(start + 7);
    const fast_jump = try self.instruction(start + 8);
    if ((try self.instruction(start)).operand_count != 1 or tag_check.operand_count != 3 or
        pointer.operand_count != 1 or metatable.operand_count != 2 or
        length.operand_count != 1 or convert.operand_count != 1 or store.operand_count != 2 or
        store_tag.operand_count != 2 or fast_jump.operand_count != 1)
        return null;
    const tag_input = try self.operand(tag_check, 0);
    const table_tag = try self.operand(tag_check, 1);
    const fallback_target = try self.operand(tag_check, 2);
    const pointer_input = try self.operand(pointer, 0);
    const metatable_pointer = try self.operand(metatable, 0);
    const metatable_fallback = try self.operand(metatable, 1);
    const length_pointer = try self.operand(length, 0);
    const converted = try self.operand(convert, 0);
    const destination = try self.vmRegisterIndex(try self.operand(store, 0));
    const stored = try self.operand(store, 1);
    const tag_destination = try self.operand(store_tag, 0);
    const result_tag = try self.operand(store_tag, 1);
    const fast_rejoin = try self.operand(fast_jump, 0);
    if (tag_input.kind != .instruction or tag_input.value != start or table_tag.kind != .constant or
        (try self.constant(table_tag.value)).tagValue() != lua_tag_table or fallback_target.kind != .block or
        pointer_input.kind != .vm_reg or pointer_input.value != source or
        metatable_pointer.kind != .instruction or metatable_pointer.value != start + 2 or
        metatable_fallback.kind != .block or metatable_fallback.value != fallback_target.value or
        length_pointer.kind != .instruction or length_pointer.value != start + 2 or
        converted.kind != .instruction or converted.value != start + 4 or
        stored.kind != .instruction or stored.value != start + 5 or
        tag_destination.kind != .vm_reg or tag_destination.value != destination or result_tag.kind != .constant or
        (try self.constant(result_tag.value)).tagValue() != lua_tag_number or fast_rejoin.kind != .block)
        return null;

    const fallback = try self.snapshot.irBlock(self.function, fallback_target.value);
    if (fallback.kind != .fallback or fallback.isEmpty() or fallback.finish - fallback.start != 2)
        return null;
    const marker = try self.instruction(fallback.start);
    const do_len = try self.instruction(fallback.start + 1);
    const fallback_jump = try self.instruction(fallback.start + 2);
    if (marker.command != .set_savedpc or do_len.command != ir_cmd_do_len or fallback_jump.command != .jump or
        marker.operand_count != 1 or do_len.operand_count != 2 or fallback_jump.operand_count != 1)
        return null;
    _ = try self.savedPc(marker);
    const fallback_destination = try self.vmRegisterIndex(try self.operand(do_len, 0));
    const fallback_source = try self.vmRegisterIndex(try self.operand(do_len, 1));
    const fallback_rejoin = try self.operand(fallback_jump, 0);
    if (fallback_destination != destination or fallback_source != source or fallback_rejoin.kind != .block or
        fallback_rejoin.value != fast_rejoin.value)
        return null;
    return .{
        .start = start,
        .destination = destination,
        .source = source,
        .fallback = fallback_target.value,
        .rejoin = try self.requireCompiledTarget(fast_rejoin),
        .marker = marker,
    };
}
pub noinline fn emitPlainTableLen(self: anytype, dest_reg: u32, table_reg: u32) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(dest_reg));
    try self.body.i32Const(self.allocator, @intCast(table_reg));
    try self.body.call(self.allocator, self.table_len orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
}

fn plainLenResultEscapes(self: anytype, convert_id: u32, finish: u32) Error!bool {
    if (convert_id == 0)
        return false;
    const table_len_id = convert_id - 1;
    var cursor: u32 = 0;
    while (cursor < self.function.instruction_count) : (cursor += 1) {
        if (cursor >= table_len_id and cursor <= finish)
            continue;
        const instruction_value = try self.instruction(cursor);
        var operand_index: u32 = 0;
        while (operand_index < instruction_value.operand_count) : (operand_index += 1) {
            const operand = try self.operand(instruction_value, operand_index);
            if (operand.kind == .instruction and operand.value == convert_id)
                return true;
        }
    }
    return false;
}

/// The plain-length helper writes the VM register. A later instruction that names the convert
/// result reads the wasm local, so publish that local only when such a use exists. A length whose
/// only consumer is the store inside this cluster keeps the helper call alone. An escaping length
/// reads the value tag in wasm: a string length is a load, and every other value still uses the
/// same helpers as the register-length sequence.
pub noinline fn emitPlainLenCluster(self: anytype, fact: anytype) Error!void {
    const convert_id = fact.table_len_id + 1;
    if (!try plainLenResultEscapes(self, convert_id, fact.finish)) {
        try self.emitPlainTableLen(fact.dest_reg, fact.table_reg);
        return;
    }
    try self.emitRegisterLength(fact.dest_reg, fact.table_reg);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.f64Load(self.allocator, 3, fact.dest_reg * tvalue_size);
    try self.emitInstructionResultSet(convert_id);
}

fn blockFailureIsBypassed(self: anytype, instruction_value: snapshot_v1.IrInstruction, operand_index: u32) Error!bool {
    if (operand_index >= instruction_value.operand_count)
        return false;
    const failure = try self.operand(instruction_value, operand_index);
    if (failure.kind != .block or failure.value >= self.function.block_count)
        return false;
    const block = try self.snapshot.irBlock(self.function, failure.value);
    return self.isBypassedEmissionBlock(failure.value, block);
}

/// A bytecode length block owns the `DO_LEN` fallback and removes it from the dispatch table.
/// The linearized copy still has the tag and metatable checks. Branching to that missing block
/// returns status 2. The plain-length helper already performs those checks, so skip the prefix.
pub fn bypassedPlainLenGuard(self: anytype, instruction_id: u32) Error!?u32 {
    const commands = [_]snapshot_v1.IrCommand{
        .load_tag, .check_tag, .load_pointer, ir_cmd_check_no_metatable, ir_cmd_table_len,
    };
    if (!try self.commandRangeMatches(instruction_id, &commands))
        return null;
    const table_len_id = instruction_id + @as(u32, @intCast(commands.len - 1));
    if (self.plan.plainLenAt(table_len_id) == null)
        return null;
    const block_id = self.plan.instructionBlock(instruction_id) orelse return null;
    if ((self.plan.instructionBlock(table_len_id) orelse return null) != block_id)
        return null;
    const tag_check = try self.instruction(instruction_id + 1);
    const metatable = try self.instruction(instruction_id + 3);
    if (!try blockFailureIsBypassed(self, tag_check, 2) or !try blockFailureIsBypassed(self, metatable, 1))
        return null;
    return table_len_id;
}

fn emitDoLenRegisters(self: anytype, destination: u32, source: u32) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(destination));
    try self.body.i32Const(self.allocator, @intCast(source));
    try self.body.call(self.allocator, self.do_len orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
}

fn emitInlineStringLength(self: anytype, destination: u32, source: u32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, source * tvalue_size);
    try self.body.i32Load(self.allocator, 2, tstring_len_offset);
    try self.body.opcode(self.allocator, 0xb7); // f64.convert_i32_s
    try self.body.f64Store(self.allocator, 3, destination * tvalue_size);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, lua_tag_number);
    try self.body.i32Store(self.allocator, 2, destination * tvalue_size + tvalue_tag_offset);
}

/// `#` reads the value tag in wasm. A string length is a load. A table with no
/// metatable uses the table-length helper. Every other value uses `do_len`.
pub noinline fn emitRegisterLength(self: anytype, destination: u32, source: u32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, source * tvalue_size + tvalue_tag_offset);
    try self.body.i32Const(self.allocator, lua_tag_string);
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try emitInlineStringLength(self, destination, source);
    try self.body.else_(self.allocator);

    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, source * tvalue_size + tvalue_tag_offset);
    try self.body.i32Const(self.allocator, lua_tag_table);
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);

    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, source * tvalue_size);
    try self.body.i32Load(self.allocator, 2, table_metatable_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.emitPlainTableLen(destination, source);
    try self.body.else_(self.allocator);
    try emitDoLenRegisters(self, destination, source);
    try self.body.end(self.allocator);

    try self.body.else_(self.allocator);
    try emitDoLenRegisters(self, destination, source);
    try self.body.end(self.allocator);

    try self.body.end(self.allocator);
}

pub noinline fn lengthSequenceAt(self: anytype, start: u32) Error!?LengthSequence {
    const commands = [_]snapshot_v1.IrCommand{
        .load_tag,   .check_tag,    .load_pointer, ir_cmd_check_no_metatable, ir_cmd_table_len,
        .int_to_num, .store_double, .store_tag,
    };
    if (!try self.commandRangeMatches(start, &commands))
        return null;
    const finish = start + @as(u32, @intCast(commands.len - 1));
    self.requireSingleCompilableBlockRange(start, finish) catch return null;

    const load_tag = try self.instruction(start);
    const tag_check = try self.instruction(start + 1);
    const pointer = try self.instruction(start + 2);
    const metatable = try self.instruction(start + 3);
    const length = try self.instruction(start + 4);
    const convert = try self.instruction(start + 5);
    const store = try self.instruction(start + 6);
    const store_tag = try self.instruction(start + 7);
    if (load_tag.operand_count != 1 or tag_check.operand_count != 3 or
        pointer.operand_count != 1 or metatable.operand_count != 2 or
        length.operand_count != 1 or convert.operand_count != 1 or store.operand_count != 2 or
        store_tag.operand_count != 2)
        return null;

    const source_operand = try self.operand(load_tag, 0);
    if (source_operand.kind != .vm_reg)
        return null;
    const source = self.vmRegisterIndex(source_operand) catch return null;
    const tag_input = try self.operand(tag_check, 0);
    const table_tag = try self.operand(tag_check, 1);
    const fallback_target = try self.operand(tag_check, 2);
    const pointer_input = try self.operand(pointer, 0);
    const metatable_pointer = try self.operand(metatable, 0);
    const metatable_fallback = try self.operand(metatable, 1);
    const length_pointer = try self.operand(length, 0);
    const converted = try self.operand(convert, 0);
    const destination_operand = try self.operand(store, 0);
    if (destination_operand.kind != .vm_reg)
        return null;
    const destination = self.vmRegisterIndex(destination_operand) catch return null;
    const stored = try self.operand(store, 1);
    const tag_destination = try self.operand(store_tag, 0);
    const result_tag = try self.operand(store_tag, 1);
    if (tag_input.kind != .instruction or tag_input.value != start or table_tag.kind != .constant or
        (try self.constant(table_tag.value)).tagValue() != lua_tag_table or fallback_target.kind != .block or
        pointer_input.kind != .vm_reg or pointer_input.value != source or
        metatable_pointer.kind != .instruction or metatable_pointer.value != start + 2 or
        metatable_fallback.kind != .block or metatable_fallback.value != fallback_target.value or
        length_pointer.kind != .instruction or length_pointer.value != start + 2 or
        converted.kind != .instruction or converted.value != start + 4 or
        stored.kind != .instruction or stored.value != start + 5 or
        tag_destination.kind != .vm_reg or tag_destination.value != destination or result_tag.kind != .constant or
        (try self.constant(result_tag.value)).tagValue() != lua_tag_number)
        return null;

    const fallback = try self.snapshot.irBlock(self.function, fallback_target.value);
    if (fallback.kind != .fallback or fallback.isEmpty() or fallback.finish - fallback.start != 2)
        return null;
    const marker = try self.instruction(fallback.start);
    const do_len = try self.instruction(fallback.start + 1);
    const fallback_jump = try self.instruction(fallback.start + 2);
    if (marker.command != .set_savedpc or do_len.command != ir_cmd_do_len or fallback_jump.command != .jump or
        marker.operand_count != 1 or do_len.operand_count != 2 or fallback_jump.operand_count != 1)
        return null;
    _ = self.savedPc(marker) catch return null;
    const fallback_destination = self.vmRegisterIndex(try self.operand(do_len, 0)) catch return null;
    const fallback_source = self.vmRegisterIndex(try self.operand(do_len, 1)) catch return null;
    if (fallback_destination != destination or fallback_source != source)
        return null;
    return .{
        .start = start,
        .finish = finish,
        .destination = destination,
        .source = source,
        .marker = marker,
    };
}
pub const FreshTableLen = struct {
    finish: u32,
    destination: u32,
    table: u32,
    converted: u32,
};

fn freshAllocationReaches(self: anytype, register: u32, published_id: u32, consumer_id: u32) Error!bool {
    if (published_id >= consumer_id)
        return false;
    if (try self.preservesRegisterToConsumer(register, published_id, consumer_id))
        return true;
    const origin = self.plan.instructionBlock(published_id) orelse return false;
    var block_id = self.plan.instructionBlock(consumer_id) orelse return false;
    var seen: u32 = 0;
    while (block_id != origin) {
        seen += 1;
        if (seen > 8)
            return false;
        const block = try self.snapshot.irBlock(self.function, block_id);
        if (!block.kind.isCompilable() or block.isEmpty())
            return false;
        var cursor = block.start;
        while (cursor <= block.finish and cursor < consumer_id) : (cursor += 1) {
            if (cursor > published_id and try self.instructionWritesRegister(cursor, register))
                return false;
        }
        const predecessors = self.plan.predecessorSlice(block_id) orelse return false;
        if (predecessors.len != 1)
            return false;
        block_id = predecessors[0];
    }
    const origin_block = try self.snapshot.irBlock(self.function, origin);
    var tail = published_id + 1;
    while (tail <= origin_block.finish and tail < consumer_id) : (tail += 1)
        if (try self.instructionWritesRegister(tail, register))
            return false;
    return true;
}

fn freshLengthTable(self: anytype, pointer: snapshot_v1.IrOperand, table_len_id: u32) Error!?u32 {
    if (try self.loadedPointerRegister(pointer)) |register| {
        if (self.plan.isProvenTablePointer(pointer.value))
            return null;
        if (!try self.preservedFreshTablePointer(pointer, table_len_id))
            return null;
        return register;
    }
    const allocation = (try self.tableAllocationPatternAt(pointer.value)) orelse return null;
    if (allocation.start != pointer.value)
        return null;
    if (!try freshAllocationReaches(self, allocation.destination, allocation.finish, table_len_id))
        return null;
    return allocation.destination;
}

/// `#` on a fresh table inside a linearized block has no proved-pointer cluster.
/// The following convert and store are the length result, so one table-length helper covers them.
pub fn freshTableLenPattern(self: anytype, table_len_id: u32) Error!?FreshTableLen {
    const length = try self.instruction(table_len_id);
    if (length.command != ir_cmd_table_len or length.operand_count != 1)
        return null;
    const pointer = try self.operand(length, 0);
    if (pointer.kind != .instruction or pointer.value >= table_len_id)
        return null;
    const table = (try freshLengthTable(self, pointer, table_len_id)) orelse return null;
    if (table_len_id + 2 >= self.function.instruction_count)
        return null;
    const convert = try self.instruction(table_len_id + 1);
    const store = try self.instruction(table_len_id + 2);
    if (convert.command != .int_to_num or convert.operand_count != 1 or
        store.command != .store_double or store.operand_count != 2)
        return null;
    const converted = try self.operand(convert, 0);
    const destination = try self.operand(store, 0);
    const stored = try self.operand(store, 1);
    if (converted.kind != .instruction or converted.value != table_len_id or
        stored.kind != .instruction or stored.value != table_len_id + 1 or
        destination.kind != .vm_reg)
        return null;
    const dest_reg = self.vmRegisterIndex(destination) catch return null;
    var finish = table_len_id + 2;
    if (table_len_id + 3 < self.function.instruction_count) {
        const store_tag = try self.instruction(table_len_id + 3);
        if (store_tag.command == .store_tag and store_tag.operand_count == 2) {
            const tag_destination = try self.operand(store_tag, 0);
            const tag = try self.operand(store_tag, 1);
            if (tag_destination.kind == .vm_reg and tag_destination.value == dest_reg and
                tag.kind == .constant and
                (try self.constant(tag.value)).tagValue() == lua_tag_number)
                finish = table_len_id + 3;
        }
    }
    self.requireSingleCompilableBlockRange(table_len_id, finish) catch return null;
    return .{
        .finish = finish,
        .destination = dest_reg,
        .table = table,
        .converted = table_len_id + 1,
    };
}

pub fn emitFreshTableLen(self: anytype, pattern: FreshTableLen) Error!void {
    try self.emitPlainTableLen(pattern.destination, pattern.table);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.f64Load(self.allocator, 3, pattern.destination * tvalue_size);
    try self.emitInstructionResultSet(pattern.converted);
}

pub noinline fn emitGeneralTableLen(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 1);
    const pointer = try self.operand(instruction_value, 0);
    const table_reg = (try self.loadedPointerRegister(pointer)) orelse
        ((try self.rootedTablePointerRegister(pointer)) orelse return Error.UnsupportedControlFlow);
    const dest_reg = (try tableLenDestination(self, instruction_id, table_reg)) orelse
        return Error.UnsupportedControlFlow;
    try self.emitPlainTableLen(dest_reg, table_reg);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.f64Load(self.allocator, 3, dest_reg * tvalue_size);
    try self.body.opcode(self.allocator, 0xaa); // i32.trunc_f64_s
    try self.emitInstructionResultSet(instruction_id);
}

fn storedLenRegister(self: anytype, store: snapshot_v1.IrInstruction, convert_id: u32) Error!?u32 {
    if (store.operand_count != 2)
        return null;
    if (store.command != .store_double and store.command != .store_tvalue and
        store.command != .store_split_tvalue)
        return null;
    const stored = try self.operand(store, 1);
    if (stored.kind != .instruction or stored.value != convert_id)
        return null;
    return self.vmRegisterIndex(try self.operand(store, 0)) catch return null;
}

fn tableLenDestination(self: anytype, table_len_id: u32, table_reg: u32) Error!?u32 {
    if (self.plan.plainLenAt(table_len_id)) |fact| {
        if (fact.dest_reg == table_reg)
            return null;
        return fact.dest_reg;
    }
    if (table_len_id + 1 >= self.function.instruction_count)
        return null;
    const convert = try self.instruction(table_len_id + 1);
    if (convert.command != .int_to_num or convert.operand_count != 1)
        return null;
    const converted = try self.operand(convert, 0);
    if (converted.kind != .instruction or converted.value != table_len_id)
        return null;
    var cursor = table_len_id + 2;
    const limit = @min(self.function.instruction_count, table_len_id + 8);
    while (cursor < limit) : (cursor += 1) {
        const dest = try storedLenRegister(self, try self.instruction(cursor), table_len_id + 1);
        if (dest) |register| {
            if (register == table_reg)
                return null;
            return register;
        }
    }
    return null;
}

const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");

const Error = model.Error;
const CallContinuation = model.CallContinuation;

const max_needle: usize = 64;
const max_elided_compares: u8 = 8;
// Not a Luau tag. The result slot holds a string pointer, a byte offset, and a length.
const elided_slice_tag: i32 = 0x100;
const i32_add: u8 = 0x6a;
const i32_sub: u8 = 0x6b;
const i32_and: u8 = 0x71;
const i32_or: u8 = 0x72;
const i32_lt_s: u8 = 0x48;
const i32_gt_s: u8 = 0x4a;
const i32_le_s: u8 = 0x4c;
const i32_le_u: u8 = 0x4d;
const i32_ge_u: u8 = 0x4f;
const i32_shr_u: u8 = 0x76;
const specials = "^$*+?.([%-";

pub const StringMethodKind = enum { plain, class, spaces, sub, match };

// Anchored patterns whose captures are a straight scan. Any other pattern stays on the helper.
pub const MatchForm = enum { qualified, token, leading, trim };

// A NAMECALL whose key constant is find, sub, or a proved match, followed by the shared CALL.
// The key and a constant pattern are IR operands. A miss emits nothing here.
pub const StringMethodShape = struct {
    kind: StringMethodKind,
    function_register: u32,
    parameter_count: u32,
    result_count: u32,
    match_form: MatchForm = .trim,
    pattern_constant: snapshot_v1.IrOperand = .{ .kind = .undef, .value = 0 },
    receiver: u32 = 0,
    key_constant: u32 = 0,
    needle_len: u32 = 0,
    needle: [max_needle]u8 = [_]u8{0} ** max_needle,
    class_bits: [32]u8 = [_]u8{0} ** 32,
    // Pattern bytes include Lua specials, so the hit is a literal search only when arg 4 is truthy.
    require_plain: bool = false,
    // The sub result is read only by one compare with this interned constant.
    // A byte match stores that constant. A miss stores nil. Neither allocates.
    compare_only: bool = false,
    compare_constant: snapshot_v1.IrOperand = .{ .kind = .undef, .value = 0 },
    call_id: u32 = 0,
    // Every read is a jump-form string compare. The call stores the slice bounds.
    // Each compare reads those bounds, so later writes of the index temps are safe.
    elide_slice: bool = false,
    elided_count: u8 = 0,
    elided: [max_elided_compares]ElidedCompare = [_]ElidedCompare{.{}} ** max_elided_compares,
};

pub const ElidedCompare = struct {
    tag_id: u32 = 0,
    needle_len: u8 = 0,
    needle: [max_needle]u8 = [_]u8{0} ** max_needle,
};

pub const ElidedSubSite = struct {
    tag_id: u32 = 0,
    call_id: u32 = 0,
    result: u32 = 0,
    receiver: u32 = 0,
    needle_len: u8 = 0,
    needle: [max_needle]u8 = [_]u8{0} ** max_needle,
};

pub fn stringMethodShape(
    self: anytype,
    call_id: u32,
    function_register: u32,
    parameter_count: i32,
    result_count: i32,
) Error!?StringMethodShape {
    if (parameter_count < 2 or parameter_count > 4 or result_count < 1)
        return null;
    const site = (try namecallSite(self, call_id, function_register)) orelse return null;
    const key = site.key;
    const params: u32 = @intCast(parameter_count);
    const results: u32 = @intCast(result_count);
    if (std.mem.eql(u8, key, "sub")) {
        if (params > 3 or results != 1)
            return null;
        var shape = StringMethodShape{
            .kind = .sub,
            .function_register = function_register,
            .parameter_count = params,
            .result_count = results,
            .receiver = site.receiver,
            .key_constant = site.key_constant,
            .call_id = call_id,
        };
        if (try subUse(self, call_id, function_register, site.receiver)) |use| {
            switch (use) {
                .one => |found| {
                    shape.compare_only = true;
                    shape.compare_constant = found.constant;
                    shape.needle_len = @intCast(found.bytes.len);
                    @memcpy(shape.needle[0..found.bytes.len], found.bytes);
                },
                .many => |found| {
                    shape.elide_slice = true;
                    shape.elided_count = found.count;
                    shape.elided = found.compares;
                },
            }
        }
        return shape;
    }
    if (std.mem.eql(u8, key, "match")) {
        // An init argument changes the anchor. More than two results is not one of these shapes.
        if (params != 2 or results > 2)
            return null;
        const pattern_register = std.math.add(u32, function_register, 2) catch return Error.ResourceLimit;
        const pattern = (try constantStringAt(self, call_id, pattern_register)) orelse return null;
        const form = matchForm(pattern.bytes) orelse return null;
        return .{
            .kind = .match,
            .function_register = function_register,
            .parameter_count = params,
            .result_count = results,
            .pattern_constant = pattern.constant,
            .receiver = site.receiver,
            .key_constant = site.key_constant,
            .match_form = form,
            .call_id = call_id,
        };
    }
    if (!std.mem.eql(u8, key, "find") or results > 2)
        return null;
    const pattern_register = std.math.add(u32, function_register, 2) catch return Error.ResourceLimit;
    const pattern = (try constantStringAt(self, call_id, pattern_register)) orelse return null;
    const classified = classify(pattern.bytes);
    var shape = StringMethodShape{
        .kind = .plain,
        .function_register = function_register,
        .parameter_count = params,
        .result_count = results,
        .pattern_constant = pattern.constant,
        .receiver = site.receiver,
        .key_constant = site.key_constant,
    };
    // find(pattern, init, plain) with specials is a literal search when plain is truthy.
    // A false or missing proof of that flag stays on the pinned finder.
    const literal_plain = blk: {
        if (params != 4)
            break :blk false;
        const known = classified orelse break :blk true;
        break :blk known != .plain;
    };
    if (literal_plain) {
        if (pattern.bytes.len > max_needle)
            return null;
        shape.needle_len = @intCast(pattern.bytes.len);
        @memcpy(shape.needle[0..pattern.bytes.len], pattern.bytes);
        shape.require_plain = true;
        return shape;
    }
    const known = classified orelse return null;
    switch (known) {
        .plain => |needle| {
            if (needle.len > max_needle)
                return null;
            shape.kind = .plain;
            shape.needle_len = @intCast(needle.len);
            @memcpy(shape.needle[0..needle.len], needle);
        },
        .class => |bits| {
            shape.kind = .class;
            shape.class_bits = bits;
        },
        .spaces => shape.kind = .spaces,
    }
    return shape;
}

fn matchForm(pattern: []const u8) ?MatchForm {
    if (std.mem.eql(u8, pattern, "^([^:]+):(.+)$"))
        return .qualified;
    if (std.mem.eql(u8, pattern, "^%s*([^%s]+)%s*$"))
        return .token;
    if (std.mem.eql(u8, pattern, "^([^%s]+)"))
        return .leading;
    if (std.mem.eql(u8, pattern, "^%s*(.-)%s*$"))
        return .trim;
    return null;
}

pub noinline fn emitStringMethodGuards(self: anytype, shape: StringMethodShape) Error!void {
    try self.body.i32Const(self.allocator, 1);
    try self.body.localSet(self.allocator, self.status_local);
    try emitCallerSafe(self);
    try emitAndStatus(self);
    try self.emitReloadBase();

    const self_register = std.math.add(u32, shape.function_register, 1) catch return Error.ResourceLimit;
    try emitStringObject(self, self_register, self.call_aux_local, self.call_func_local);
    try emitAndStatus(self);
    if (shape.kind != .sub) {
        const pattern_register = std.math.add(u32, shape.function_register, 2) catch return Error.ResourceLimit;
        try emitStringObject(self, pattern_register, self.call_proto_local, self.table_index_local);
        try emitAndStatus(self);
        // Interned TString*. A copied or overwritten pattern misses with no stack writes.
        try self.emitVmConstantAddress(shape.pattern_constant);
        try self.body.i32Load(self.allocator, 2, 0);
        try self.body.localGet(self.allocator, self.call_proto_local);
        try self.body.i32Eq(self.allocator);
        try emitAndStatus(self);
        if (shape.parameter_count >= 3)
            try emitExactInteger(self, pattern_register + 1, self.call_closure_local);
        if (shape.require_plain) {
            const plain_register = std.math.add(u32, pattern_register, 2) catch return Error.ResourceLimit;
            const plain = snapshot_v1.IrOperand{ .kind = .vm_reg, .value = plain_register };
            try self.emitTValueTruthy(plain);
            try emitAndStatus(self);
        }
    } else {
        const start_register = std.math.add(u32, shape.function_register, 2) catch return Error.ResourceLimit;
        try emitExactInteger(self, start_register, self.call_closure_local);
        if (shape.parameter_count == 3)
            try emitExactInteger(self, start_register + 1, self.call_meta_local);
    }
}

pub noinline fn emitStringMethodOperation(
    self: anytype,
    shape: StringMethodShape,
    continuation: ?CallContinuation,
) Error!void {
    if (shape.kind == .sub)
        try emitSub(self, shape, continuation)
    else if (shape.kind == .match)
        try emitMatch(self, shape, continuation)
    else
        try emitFind(self, shape, continuation);
}

const NamecallSite = struct {
    key: []const u8,
    receiver: u32,
    key_constant: u32,
};

fn namecallSite(self: anytype, call_id: u32, function_register: u32) Error!?NamecallSite {
    var cursor = call_id;
    while (cursor > 0) {
        cursor -= 1;
        const instruction = try self.instruction(cursor);
        if (try writesRegister(self, instruction, function_register))
            return null;
        if (instruction.command != abi.ir_cmd_fallback_namecall or instruction.operand_count != 4)
            continue;
        const destination = try self.operand(instruction, 1);
        if (destination.kind != .vm_reg or destination.value != function_register)
            continue;
        const source = try self.operand(instruction, 2);
        const key_operand = try self.operand(instruction, 3);
        if (source.kind != .vm_reg)
            return null;
        const key = (try self.stringKey(key_operand)) orelse return null;
        return .{ .key = key, .receiver = source.value, .key_constant = key_operand.value };
    }
    return null;
}

const ConstantString = struct {
    bytes: []const u8,
    constant: snapshot_v1.IrOperand,
};

fn constantStringAt(self: anytype, call_id: u32, register: u32) Error!?ConstantString {
    return constantStringBefore(self, call_id, register, 4);
}

// LOADK of a string is LOAD_TVALUE(vm_const, 0, tag) then STORE_TVALUE.
// MOVE is LOAD_TVALUE(vm_reg) then STORE_TVALUE. Follow that copy to the constant.
fn constantStringBefore(self: anytype, before_id: u32, register: u32, depth: u8) Error!?ConstantString {
    if (depth == 0)
        return null;
    var cursor = before_id;
    while (cursor > 0) {
        cursor -= 1;
        const instruction = try self.instruction(cursor);
        if (!try writesRegister(self, instruction, register))
            continue;
        if (instruction.command != .store_tvalue or instruction.operand_count != 2)
            return null;
        const stored = try self.operand(instruction, 1);
        if (stored.kind != .instruction or stored.value >= cursor)
            return null;
        const producer = try self.instruction(stored.value);
        if (producer.command != .load_tvalue or (producer.operand_count != 1 and producer.operand_count != 3))
            return null;
        if (producer.operand_count == 3) {
            const offset = self.tvalueByteOffset(producer, 1) catch return null;
            if (offset != 0)
                return null;
        }
        const source = try self.operand(producer, 0);
        if (try self.stringKey(source)) |bytes|
            return .{ .bytes = bytes, .constant = source };
        if (source.kind != .vm_reg)
            return null;
        const copied = self.vmRegisterIndex(source) catch return null;
        return constantStringBefore(self, stored.value, copied, depth - 1);
    }
    return null;
}

const ComparedConstant = struct {
    bytes: []const u8,
    constant: snapshot_v1.IrOperand,
};

fn readsRegister(self: anytype, instruction_value: snapshot_v1.IrInstruction, register: u32) Error!bool {
    var index: u32 = 0;
    while (index < instruction_value.operand_count) : (index += 1) {
        const operand = try self.operand(instruction_value, index);
        if (operand.kind != .vm_reg or operand.value != register)
            continue;
        if (index == 0 and try writesRegister(self, instruction_value, register))
            continue;
        return true;
    }
    return false;
}

// CALL A,B reads A through A+B. B is the IR parameter count. A negative B is
// MULTRET: the arguments are A and every register above it, not the locals below A.
fn callCoversRegister(self: anytype, instruction_value: snapshot_v1.IrInstruction, register: u32) Error!bool {
    if (instruction_value.command != .call or instruction_value.operand_count < 2)
        return false;
    const base = try self.operand(instruction_value, 0);
    const params = try self.operand(instruction_value, 1);
    if (base.kind != .vm_reg or params.kind != .constant)
        return true;
    const count = (try self.constant(params.value)).intValue() orelse return true;
    if (count < 0)
        return register >= base.value;
    const span: u32 = @intCast(count);
    const last = std.math.add(u32, base.value, span) catch return true;
    return register >= base.value and register <= last;
}

fn constantFromEncoded(encoded: u32) ?snapshot_v1.IrOperand {
    if ((encoded & 0x8000_0000) == 0)
        return null;
    return .{ .kind = .vm_const, .value = encoded & 0x7fff_ffff };
}

fn acceptComparedBytes(self: anytype, constant: snapshot_v1.IrOperand) Error!?ComparedConstant {
    const bytes = (try self.stringKey(constant)) orelse return null;
    if (bytes.len > max_needle)
        return null;
    return .{ .bytes = bytes, .constant = constant };
}

// Shortcut compare: LOAD_TAG, LOAD_POINTER, LOAD_POINTER(constant), CMP_SPLIT_TVALUE.
fn matchSplitCompare(
    self: anytype,
    tag_id: u32,
    ptr_id: u32,
    limit: u32,
) Error!?ComparedConstant {
    var cursor = @max(tag_id, ptr_id) + 1;
    while (cursor < limit) : (cursor += 1) {
        const instruction = try self.instruction(cursor);
        if (instruction.command != .cmp_split_tvalue or instruction.operand_count != 5)
            continue;
        const tag_operand = try self.operand(instruction, 0);
        const expected = try self.operand(instruction, 1);
        const lhs = try self.operand(instruction, 2);
        const rhs = try self.operand(instruction, 3);
        const references = tag_operand.kind == .instruction and tag_operand.value == tag_id and
            lhs.kind == .instruction and lhs.value == ptr_id;
        if (!references)
            continue;
        if (expected.kind != .constant)
            return null;
        if ((try self.constant(expected.value)).tagValue() != abi.lua_tag_string)
            return null;
        if (rhs.kind != .instruction)
            return null;
        const load = try self.instruction(rhs.value);
        if (load.command != .load_pointer or load.operand_count != 1)
            return null;
        return try acceptComparedBytes(self, try self.operand(load, 0));
    }
    return null;
}

fn matchJumpCompare(self: anytype, result: u32, tag_id: u32, ptr_id: u32) Error!?ComparedConstant {
    const block_id = self.plan.instructionBlock(tag_id) orelse return null;
    const block = try self.snapshot.irBlock(self.function, block_id);
    const pattern = (self.stringEqualityPattern(block) catch return null) orelse return null;
    if (pattern.lhs != result or pattern.start != tag_id)
        return null;
    const pointer_block = try self.snapshot.irBlock(self.function, pattern.pointer_block);
    if (pointer_block.start != ptr_id)
        return null;
    const constant = constantFromEncoded(pattern.rhs) orelse return null;
    return try acceptComparedBytes(self, constant);
}

const SubReads = struct {
    tags: [max_elided_compares]u32,
    ptrs: [max_elided_compares]u32,
    count: u8,
    limit: u32,
};

const SubUse = union(enum) {
    one: ComparedConstant,
    many: struct {
        count: u8,
        compares: [max_elided_compares]ElidedCompare,
    },
};

// Pairs of load_tag + load_pointer on the result, before that register is stored.
fn subReads(self: anytype, call_id: u32, result: u32) Error!?SubReads {
    var tags: [max_elided_compares]u32 = undefined;
    var ptrs: [max_elided_compares]u32 = undefined;
    var count: u8 = 0;
    var open: ?u32 = null;
    var limit = self.function.instruction_count;
    var cursor = call_id + 1;
    while (cursor < self.function.instruction_count) : (cursor += 1) {
        const instruction = try self.instruction(cursor);
        if (try writesRegister(self, instruction, result)) {
            limit = cursor;
            break;
        }
        if (try callCoversRegister(self, instruction, result))
            return null;
        if (try readsRegister(self, instruction, result)) {
            if (instruction.command == .load_tag and open == null) {
                open = cursor;
            } else if (instruction.command == .load_pointer and open != null) {
                if (count == max_elided_compares)
                    return null;
                tags[count] = open.?;
                ptrs[count] = cursor;
                count += 1;
                open = null;
            } else return null;
        }
    }
    if (open != null or count == 0)
        return null;
    return .{ .tags = tags, .ptrs = ptrs, .count = count, .limit = limit };
}

// A call writes its results over A .. A+N-1. An argument register is only read.
fn callWritesRegister(self: anytype, instruction_value: snapshot_v1.IrInstruction, register: u32) Error!bool {
    if (instruction_value.command != .call or instruction_value.operand_count < 3)
        return false;
    const base = try self.operand(instruction_value, 0);
    const results = try self.operand(instruction_value, 2);
    if (base.kind != .vm_reg or results.kind != .constant)
        return true;
    const count = (try self.constant(results.value)).intValue() orelse return true;
    // A negative result count is MULTRET. Results occupy A and every register above it.
    if (count < 0)
        return register >= base.value;
    if (count == 0)
        return false;
    const last = std.math.add(u32, base.value, @intCast(count - 1)) catch return true;
    return register >= base.value and register <= last;
}

// The source string has to stay rooted in its register until the last compare.
// Index temps may be reused. The slice bounds are already stored in the result.
fn receiverStaysLive(self: anytype, call_id: u32, receiver: u32, limit: u32) Error!bool {
    var cursor = call_id + 1;
    const end = @min(limit + 1, self.function.instruction_count);
    while (cursor < end) : (cursor += 1) {
        const instruction = try self.instruction(cursor);
        if (try writesRegister(self, instruction, receiver))
            return false;
        if (try callWritesRegister(self, instruction, receiver))
            return false;
    }
    return true;
}

fn subUse(self: anytype, call_id: u32, result: u32, receiver: u32) Error!?SubUse {
    const reads = (try subReads(self, call_id, result)) orelse return null;
    if (reads.count == 1) {
        const split = try matchSplitCompare(self, reads.tags[0], reads.ptrs[0], reads.limit);
        const jump = try matchJumpCompare(self, result, reads.tags[0], reads.ptrs[0]);
        if (split) |split_value| {
            if (jump) |jump_value| {
                if (split_value.constant.kind != jump_value.constant.kind or
                    split_value.constant.value != jump_value.constant.value)
                    return null;
            }
            return .{ .one = split_value };
        }
        if (jump) |jump_value|
            return .{ .one = jump_value };
        return null;
    }
    var compares = [_]ElidedCompare{.{}} ** max_elided_compares;
    var index: u8 = 0;
    while (index < reads.count) : (index += 1) {
        const jump = (try matchJumpCompare(self, result, reads.tags[index], reads.ptrs[index])) orelse
            return null;
        compares[index] = .{
            .tag_id = reads.tags[index],
            .needle_len = @intCast(jump.bytes.len),
        };
        @memcpy(compares[index].needle[0..jump.bytes.len], jump.bytes);
    }
    if (!try receiverStaysLive(self, call_id, receiver, reads.ptrs[reads.count - 1]))
        return null;
    return .{ .many = .{ .count = reads.count, .compares = compares } };
}

fn writesRegister(self: anytype, instruction_value: snapshot_v1.IrInstruction, register: u32) Error!bool {
    switch (instruction_value.command) {
        .store_tag, .store_extra, .store_pointer, .store_double, .store_int, .store_int64, .store_vector, .store_tvalue, .store_split_tvalue => {},
        else => return false,
    }
    if (instruction_value.operand_count == 0)
        return false;
    const destination = try self.operand(instruction_value, 0);
    return destination.kind == .vm_reg and destination.value == register;
}

const Classified = union(enum) {
    plain: []const u8,
    class: [32]u8,
    spaces,
};

fn classify(pattern: []const u8) ?Classified {
    if (std.mem.eql(u8, pattern, "^%s*"))
        return .spaces;
    if (classBitmap(pattern)) |bits|
        return .{ .class = bits };
    if (isPlainNeedle(pattern))
        return .{ .plain = pattern };
    return null;
}

fn isPlainNeedle(pattern: []const u8) bool {
    for (pattern) |byte| {
        if (std.mem.indexOfScalar(u8, specials, byte) != null)
            return false;
    }
    return true;
}

fn isLuaSpace(byte: u8) bool {
    return byte == ' ' or (byte >= 9 and byte <= 13);
}

fn setBit(bits: *[32]u8, byte: u8) void {
    bits[byte >> 3] |= @as(u8, 1) << @intCast(byte & 7);
}

fn classBitmap(pattern: []const u8) ?[32]u8 {
    var bits = [_]u8{0} ** 32;
    if (pattern.len == 2 and pattern[0] == '%' and (pattern[1] == 's' or pattern[1] == 'S')) {
        var byte: u16 = 0;
        while (byte < 256) : (byte += 1) {
            const space = isLuaSpace(@intCast(byte));
            if ((pattern[1] == 's' and space) or (pattern[1] == 'S' and !space))
                setBit(&bits, @intCast(byte));
        }
        return bits;
    }
    if (pattern.len < 3 or pattern[0] != '[' or pattern[pattern.len - 1] != ']' or pattern[1] == '^')
        return null;
    var index: usize = 1;
    const end = pattern.len - 1;
    while (index < end) {
        if (pattern[index] == '%') {
            if (index + 1 >= end)
                return null;
            const class = pattern[index + 1];
            if (class != 's' and class != 'S')
                return null;
            var byte: u16 = 0;
            while (byte < 256) : (byte += 1) {
                const space = isLuaSpace(@intCast(byte));
                if ((class == 's' and space) or (class == 'S' and !space))
                    setBit(&bits, @intCast(byte));
            }
            index += 2;
            continue;
        }
        if (index + 2 < end and pattern[index + 1] == '-') {
            const from = pattern[index];
            const to = pattern[index + 2];
            if (from == '%' or to == '%')
                return null;
            if (from <= to) {
                var byte: u16 = from;
                while (byte <= to) : (byte += 1)
                    setBit(&bits, @intCast(byte));
            }
            index += 3;
            continue;
        }
        setBit(&bits, pattern[index]);
        index += 1;
    }
    return bits;
}

fn emitAndStatus(self: anytype) Error!void {
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.opcode(self.allocator, i32_and);
    try self.body.localSet(self.allocator, self.status_local);
}

fn emitCallerSafe(self: anytype) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_func_offset);
    try self.body.i32Load(self.allocator, 2, 0);
    try self.body.i32Load(self.allocator, 2, abi.closure_env_offset);
    try self.body.localTee(self.allocator, self.call_aux_local);
    try self.body.ifI32(self.allocator);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Load8U(self.allocator, 0, abi.table_safeenv_offset);
    try self.body.i32Const(self.allocator, 0);
    try self.body.i32Ne(self.allocator);
    try self.body.else_(self.allocator);
    try self.body.i32Const(self.allocator, 0);
    try self.body.end(self.allocator);
}

fn slotOffset(register: u32, extra: u32) Error!u32 {
    const bytes = std.math.mul(u32, register, abi.tvalue_size) catch return Error.ResourceLimit;
    return std.math.add(u32, bytes, extra) catch return Error.ResourceLimit;
}

fn emitTagEquals(self: anytype, register: u32, tag: u8) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, try slotOffset(register, abi.tvalue_tag_offset));
    try self.body.i32Const(self.allocator, @intCast(tag));
    try self.body.i32Eq(self.allocator);
}

fn emitStringObject(self: anytype, register: u32, pointer_local: u32, length_local: u32) Error!void {
    try emitTagEquals(self, register, abi.lua_tag_string);
    try self.body.ifI32(self.allocator);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, try slotOffset(register, 0));
    try self.body.localSet(self.allocator, pointer_local);
    try self.body.localGet(self.allocator, pointer_local);
    try self.body.i32Load(self.allocator, 2, abi.tstring_len_offset);
    try self.body.localTee(self.allocator, length_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.opcode(self.allocator, i32_lt_s);
    try self.body.i32Eqz(self.allocator);
    try self.body.localGet(self.allocator, length_local);
    try self.body.i32Const(self.allocator, std.math.maxInt(i32));
    try self.body.i32Ne(self.allocator);
    try self.body.opcode(self.allocator, i32_and);
    try self.body.else_(self.allocator);
    try self.body.i32Const(self.allocator, 0);
    try self.body.end(self.allocator);
}

fn emitExactInteger(self: anytype, register: u32, dest_local: u32) Error!void {
    // (int)d matches only when the f64 survives a saturating trunc and the signed convert back.
    try emitTagEquals(self, register, abi.lua_tag_number);
    try self.body.ifI32(self.allocator);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.f64Load(self.allocator, 3, try slotOffset(register, 0));
    try self.body.opcode(self.allocator, 0xfc);
    try self.body.opcode(self.allocator, 0x02);
    try self.body.localTee(self.allocator, dest_local);
    try self.body.opcode(self.allocator, 0xb7);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.f64Load(self.allocator, 3, try slotOffset(register, 0));
    try self.body.f64Eq(self.allocator);
    try self.body.else_(self.allocator);
    try self.body.i32Const(self.allocator, 0);
    try self.body.end(self.allocator);
    try emitAndStatus(self);
}

fn emitStoreNil(self: anytype, register: u32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i64Const(self.allocator, 0);
    try self.body.i64Store(self.allocator, 3, try slotOffset(register, 0));
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i64Const(self.allocator, 0);
    try self.body.i64Store(self.allocator, 3, try slotOffset(register, 8));
}

fn emitStoreInteger(self: anytype, register: u32, local_index: u32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, @intCast(try slotOffset(register, 0)));
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localGet(self.allocator, local_index);
    try self.body.opcode(self.allocator, 0xb7);
    try self.body.f64Store(self.allocator, 3, 0);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, abi.lua_tag_number);
    try self.body.i32Store(self.allocator, 2, try slotOffset(register, abi.tvalue_tag_offset));
}

fn emitNilResults(self: anytype, shape: StringMethodShape) Error!void {
    try emitStoreNil(self, shape.function_register);
    if (shape.result_count >= 2)
        try emitStoreNil(self, shape.function_register + 1);
}

fn emitNumberResults(self: anytype, shape: StringMethodShape) Error!void {
    try emitStoreInteger(self, shape.function_register, self.call_closure_local);
    if (shape.result_count >= 2)
        try emitStoreInteger(self, shape.function_register + 1, self.table_index_local);
}

fn emitPosrelat(self: anytype, local_index: u32) Error!void {
    try self.body.localGet(self.allocator, local_index);
    try self.body.i32Const(self.allocator, 0);
    try self.body.opcode(self.allocator, i32_lt_s);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, local_index);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, local_index);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, local_index);
    try self.body.i32Const(self.allocator, 0);
    try self.body.opcode(self.allocator, i32_lt_s);
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, local_index);
    try self.body.end(self.allocator);
}

fn emitClampLow(self: anytype, local_index: u32, low: i32) Error!void {
    try self.body.localGet(self.allocator, local_index);
    try self.body.i32Const(self.allocator, low);
    try self.body.opcode(self.allocator, i32_lt_s);
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, low);
    try self.body.localSet(self.allocator, local_index);
    try self.body.end(self.allocator);
}

fn emitDataCursor(self: anytype) Error!void {
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Const(self.allocator, @intCast(abi.tstring_data_offset - 1));
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.call_meta_local);
}

fn emitExclusiveEnd(self: anytype, adjust: i32) Error!void {
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Const(self.allocator, adjust);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.table_index_local);
}

fn emitNeedleEquals(self: anytype, needle_len: usize) Error!void {
    try self.body.i32Const(self.allocator, 1);
    var index: usize = 0;
    while (index < needle_len) : (index += 1) {
        try self.body.localGet(self.allocator, self.call_meta_local);
        try self.body.i32Load8U(self.allocator, 0, @intCast(index));
        try self.body.localGet(self.allocator, self.call_proto_local);
        try self.body.i32Load8U(self.allocator, 0, @intCast(index));
        try self.body.i32Eq(self.allocator);
        try self.body.opcode(self.allocator, i32_and);
    }
}

fn emitPlainScan(self: anytype, needle: []const u8) Error!void {
    try emitDataCursor(self);
    if (needle.len == 0) {
        try self.body.i32Const(self.allocator, 1);
        try self.body.localSet(self.allocator, self.call_closure_local);
        return;
    }
    const adjust: i32 = @as(i32, @intCast(abi.tstring_data_offset)) + 1 - @as(i32, @intCast(needle.len));
    try emitExclusiveEnd(self, adjust);
    const entry = try self.string_keys.intern(self.allocator, needle);
    try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(entry.offset));
    try self.body.localSet(self.allocator, self.call_proto_local);
    try self.body.block(self.allocator);
    try self.body.loop(self.allocator);
    if (self.count_scan) |probe|
        try self.body.call(self.allocator, probe);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.opcode(self.allocator, i32_ge_u);
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.call_closure_local);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try emitNeedleEquals(self, needle.len);
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, 1);
    try self.body.localSet(self.allocator, self.call_closure_local);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.call_meta_local);
    try self.body.branch(self.allocator, 0);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}

fn emitClassBit(self: anytype) Error!void {
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load8U(self.allocator, 0, 0);
    try self.body.localTee(self.allocator, self.call_closure_local);
    try self.body.i32Const(self.allocator, 3);
    try self.body.opcode(self.allocator, i32_shr_u);
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.i32Load8U(self.allocator, 0, 0);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Const(self.allocator, 7);
    try self.body.opcode(self.allocator, i32_and);
    try self.body.opcode(self.allocator, i32_shr_u);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_and);
}

fn emitClassScan(self: anytype, bits: *const [32]u8) Error!void {
    try emitDataCursor(self);
    try emitExclusiveEnd(self, @intCast(abi.tstring_data_offset));
    const entry = try self.string_keys.intern(self.allocator, bits);
    try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(entry.offset));
    try self.body.localSet(self.allocator, self.call_proto_local);
    try self.body.block(self.allocator);
    try self.body.loop(self.allocator);
    if (self.count_scan) |probe|
        try self.body.call(self.allocator, probe);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.opcode(self.allocator, i32_ge_u);
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.call_closure_local);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try emitClassBit(self);
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, 1);
    try self.body.localSet(self.allocator, self.call_closure_local);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.call_meta_local);
    try self.body.branch(self.allocator, 0);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}

fn emitIsSpace(self: anytype) Error!void {
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load8U(self.allocator, 0, 0);
    try self.body.localTee(self.allocator, self.call_proto_local);
    try self.body.i32Const(self.allocator, ' ');
    try self.body.i32Eq(self.allocator);
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Const(self.allocator, 9);
    try self.body.opcode(self.allocator, i32_ge_u);
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Const(self.allocator, 13);
    try self.body.opcode(self.allocator, i32_le_u);
    try self.body.opcode(self.allocator, i32_and);
    try self.body.opcode(self.allocator, i32_or);
}

fn emitSpacesScan(self: anytype) Error!void {
    try emitDataCursor(self);
    try emitExclusiveEnd(self, @intCast(abi.tstring_data_offset));
    try self.body.block(self.allocator);
    try self.body.loop(self.allocator);
    if (self.count_scan) |probe|
        try self.body.call(self.allocator, probe);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.opcode(self.allocator, i32_ge_u);
    try self.body.ifVoid(self.allocator);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try emitIsSpace(self);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.call_meta_local);
    try self.body.branch(self.allocator, 0);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.i32Const(self.allocator, @intCast(abi.tstring_data_offset));
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.localSet(self.allocator, self.table_index_local);
}

fn emitFindIndexes(self: anytype, needle_len: u32) Error!void {
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.i32Const(self.allocator, @intCast(abi.tstring_data_offset - 1));
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.localSet(self.allocator, self.call_closure_local);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.i32Const(self.allocator, @as(i32, @intCast(abi.tstring_data_offset)) - @as(i32, @intCast(needle_len)));
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.localSet(self.allocator, self.table_index_local);
}

fn emitPastEnd(self: anytype) Error!void {
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.opcode(self.allocator, i32_gt_s);
}

fn emitFoundBody(self: anytype, shape: StringMethodShape, needle_len: u32) Error!void {
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.ifVoid(self.allocator);
    try emitFindIndexes(self, needle_len);
    try emitNumberResults(self, shape);
    try self.body.else_(self.allocator);
    try emitNilResults(self, shape);
    try self.body.end(self.allocator);
}

fn emitFinishResults(self: anytype, continuation: ?CallContinuation) Error!void {
    try self.emitGuardedCheckGc();
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_top_offset);
    try self.body.i32Store(self.allocator, 2, abi.lua_state_top_offset);
    if (continuation) |resumable|
        try self.emitClearContinuation(resumable.continuation_id);
}

fn emitMatchWindow(self: anytype) Error!void {
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Const(self.allocator, @intCast(abi.tstring_data_offset));
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.table_index_local);
}

fn emitOffsetFromData(self: anytype, pointer_local: u32) Error!void {
    try self.body.localGet(self.allocator, pointer_local);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Const(self.allocator, @intCast(abi.tstring_data_offset));
    try self.body.opcode(self.allocator, i32_add);
    try self.body.opcode(self.allocator, i32_sub);
}

// Stop at the end, or when the byte stops matching `want_space`. call_proto holds that byte.
fn emitAdvanceWhile(self: anytype, want_space: bool) Error!void {
    try self.body.block(self.allocator);
    try self.body.loop(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.opcode(self.allocator, i32_ge_u);
    try self.body.ifVoid(self.allocator);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try emitIsSpace(self);
    if (want_space)
        try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.call_meta_local);
    try self.body.branch(self.allocator, 0);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}

// `^([^:]+):(.+)$`. call_proto is the first capture length. call_closure is the second, or -1.
fn emitQualifiedBounds(self: anytype) Error!void {
    try self.body.i32Const(self.allocator, -1);
    try self.body.localSet(self.allocator, self.call_closure_local);
    try emitMatchWindow(self);
    try self.body.block(self.allocator);
    try self.body.loop(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.opcode(self.allocator, i32_ge_u);
    try self.body.ifVoid(self.allocator);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load8U(self.allocator, 0, 0);
    try self.body.i32Const(self.allocator, ':');
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try emitOffsetFromData(self, self.call_meta_local);
    try self.body.localTee(self.allocator, self.call_proto_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.opcode(self.allocator, i32_gt_s);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.localTee(self.allocator, self.call_cached_closure_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.opcode(self.allocator, i32_gt_s);
    try self.body.opcode(self.allocator, i32_and);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_cached_closure_local);
    try self.body.localSet(self.allocator, self.call_closure_local);
    try self.body.end(self.allocator);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.call_meta_local);
    try self.body.branch(self.allocator, 0);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}

// `^%s*([^%s]+)%s*$`. call_proto is the offset. call_closure is the length, or -1.
fn emitTokenBounds(self: anytype) Error!void {
    try self.body.i32Const(self.allocator, -1);
    try self.body.localSet(self.allocator, self.call_closure_local);
    try emitMatchWindow(self);
    try emitAdvanceWhile(self, true);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.opcode(self.allocator, i32_ge_u);
    try self.body.ifVoid(self.allocator);
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localSet(self.allocator, self.call_cached_closure_local);
    try emitAdvanceWhile(self, false);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localSet(self.allocator, self.call_closure_local);
    try emitAdvanceWhile(self, true);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try emitOffsetFromData(self, self.call_cached_closure_local);
    try self.body.localSet(self.allocator, self.call_proto_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.localGet(self.allocator, self.call_cached_closure_local);
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.localSet(self.allocator, self.call_closure_local);
    try self.body.else_(self.allocator);
    try self.body.i32Const(self.allocator, -1);
    try self.body.localSet(self.allocator, self.call_closure_local);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}

// `^([^%s]+)`. The offset is 0. call_closure is the length, or -1.
fn emitLeadingBounds(self: anytype) Error!void {
    try self.body.i32Const(self.allocator, -1);
    try self.body.localSet(self.allocator, self.call_closure_local);
    try emitMatchWindow(self);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.opcode(self.allocator, i32_ge_u);
    try self.body.ifVoid(self.allocator);
    try self.body.else_(self.allocator);
    try emitIsSpace(self);
    try self.body.ifVoid(self.allocator);
    try self.body.else_(self.allocator);
    try emitAdvanceWhile(self, false);
    try emitOffsetFromData(self, self.call_meta_local);
    try self.body.localSet(self.allocator, self.call_closure_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.call_proto_local);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}

// `^%s*(.-)%s*$` matches every string. call_proto is the offset. call_closure is the length.
fn emitTrimBounds(self: anytype) Error!void {
    try emitMatchWindow(self);
    try emitAdvanceWhile(self, true);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localSet(self.allocator, self.call_cached_closure_local);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.localSet(self.allocator, self.call_meta_local);
    try self.body.block(self.allocator);
    try self.body.loop(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.call_cached_closure_local);
    try self.body.opcode(self.allocator, i32_le_u);
    try self.body.ifVoid(self.allocator);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.localSet(self.allocator, self.call_meta_local);
    try emitIsSpace(self);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.call_meta_local);
    try self.body.branch(self.allocator, 2);
    try self.body.end(self.allocator);
    try self.body.branch(self.allocator, 0);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try emitOffsetFromData(self, self.call_cached_closure_local);
    try self.body.localSet(self.allocator, self.call_proto_local);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.call_cached_closure_local);
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.localSet(self.allocator, self.call_closure_local);
}

fn emitSliceLocals(
    self: anytype,
    destination: u32,
    source: u32,
    offset_local: u32,
    length_local: u32,
) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(destination));
    try self.body.i32Const(self.allocator, @intCast(source));
    try self.body.localGet(self.allocator, offset_local);
    try self.body.localGet(self.allocator, length_local);
    try self.body.call(self.allocator, self.slice_string orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
}

fn emitEmptyString(self: anytype, destination: u32, source: u32) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(destination));
    try self.body.i32Const(self.allocator, @intCast(source));
    try self.body.i32Const(self.allocator, 0);
    try self.body.i32Const(self.allocator, 0);
    try self.body.call(self.allocator, self.slice_string orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
}

// A capture of the whole receiver is the same interned string. Copy that slot.
fn emitCopyReceiver(self: anytype, destination: u32, source: u32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i64Load(self.allocator, 3, try slotOffset(source, 0));
    try self.body.i64Store(self.allocator, 3, try slotOffset(destination, 0));
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i64Load(self.allocator, 3, try slotOffset(source, 8));
    try self.body.i64Store(self.allocator, 3, try slotOffset(destination, 8));
}

fn emitPublishCapture(self: anytype, shape: StringMethodShape) Error!void {
    const destination = shape.function_register;
    const source = std.math.add(u32, destination, 1) catch return Error.ResourceLimit;
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    // Length 0 does not read bytes. The helper rejects an empty range past offset 0.
    try emitEmptyString(self, destination, source);
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Eq(self.allocator);
    try self.body.opcode(self.allocator, i32_and);
    try self.body.ifVoid(self.allocator);
    try emitCopyReceiver(self, destination, source);
    try self.body.else_(self.allocator);
    try emitSliceLocals(self, destination, source, self.call_proto_local, self.call_closure_local);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}

fn emitPublishQualified(self: anytype, shape: StringMethodShape) Error!void {
    const destination = shape.function_register;
    const source = std.math.add(u32, destination, 1) catch return Error.ResourceLimit;
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.call_cached_closure_local);
    try emitSliceLocals(self, destination, source, self.call_cached_closure_local, self.call_proto_local);
    if (shape.result_count >= 2) {
        try self.body.localGet(self.allocator, self.call_proto_local);
        try self.body.i32Const(self.allocator, 1);
        try self.body.opcode(self.allocator, i32_add);
        try self.body.localSet(self.allocator, self.call_cached_closure_local);
        const second = std.math.add(u32, destination, 1) catch return Error.ResourceLimit;
        try emitSliceLocals(self, second, source, self.call_cached_closure_local, self.call_closure_local);
    }
}

fn emitMatch(self: anytype, shape: StringMethodShape, continuation: ?CallContinuation) Error!void {
    switch (shape.match_form) {
        .qualified => try emitQualifiedBounds(self),
        .token => try emitTokenBounds(self),
        .leading => try emitLeadingBounds(self),
        .trim => try emitTrimBounds(self),
    }
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.opcode(self.allocator, i32_lt_s);
    try self.body.ifVoid(self.allocator);
    try emitNilResults(self, shape);
    try self.body.else_(self.allocator);
    if (shape.match_form == .qualified)
        try emitPublishQualified(self, shape)
    else
        try emitPublishCapture(self, shape);
    if (shape.match_form != .qualified and shape.result_count >= 2)
        try emitStoreNil(self, shape.function_register + 1);
    try self.body.end(self.allocator);
    try emitFinishResults(self, continuation);
}

fn emitFind(self: anytype, shape: StringMethodShape, continuation: ?CallContinuation) Error!void {
    if (shape.parameter_count == 2) {
        try self.body.i32Const(self.allocator, 1);
        try self.body.localSet(self.allocator, self.call_closure_local);
    }
    try emitPosrelat(self, self.call_closure_local);
    try emitClampLow(self, self.call_closure_local, 1);
    try emitPastEnd(self);
    try self.body.ifVoid(self.allocator);
    try emitNilResults(self, shape);
    try self.body.else_(self.allocator);
    switch (shape.kind) {
        .plain => {
            try emitPlainScan(self, shape.needle[0..@as(usize, shape.needle_len)]);
            try emitFoundBody(self, shape, shape.needle_len);
        },
        .class => {
            try emitClassScan(self, &shape.class_bits);
            try emitFoundBody(self, shape, 1);
        },
        .spaces => {
            try emitSpacesScan(self);
            try emitNumberResults(self, shape);
        },
        .sub, .match => return Error.UnsupportedCommand,
    }
    try self.body.end(self.allocator);
    try emitFinishResults(self, continuation);
}

fn emitSub(self: anytype, shape: StringMethodShape, continuation: ?CallContinuation) Error!void {
    if (shape.parameter_count == 2) {
        try self.body.i32Const(self.allocator, -1);
        try self.body.localSet(self.allocator, self.call_meta_local);
    }
    try emitPosrelat(self, self.call_closure_local);
    try emitPosrelat(self, self.call_meta_local);
    try emitClampLow(self, self.call_closure_local, 1);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.opcode(self.allocator, i32_gt_s);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.localSet(self.allocator, self.call_meta_local);
    try self.body.end(self.allocator);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.opcode(self.allocator, i32_le_s);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.localSet(self.allocator, self.call_proto_local);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.opcode(self.allocator, i32_sub);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, i32_add);
    try self.body.localSet(self.allocator, self.table_index_local);
    try self.body.else_(self.allocator);
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.call_proto_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.table_index_local);
    try self.body.end(self.allocator);

    if (shape.elide_slice and elidedCall(self, shape.call_id)) {
        try emitStoreElidedSlice(self, shape);
        try emitPublishTop(self);
    } else if (shape.compare_only) {
        try emitStoreComparedSlice(self, shape);
        try emitPublishTop(self);
    } else {
        const source = std.math.add(u32, shape.function_register, 1) catch return Error.ResourceLimit;
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(shape.function_register));
        try self.body.i32Const(self.allocator, @intCast(source));
        try self.body.localGet(self.allocator, self.call_proto_local);
        try self.body.localGet(self.allocator, self.table_index_local);
        try self.body.call(self.allocator, self.slice_string orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
    }
    if (continuation) |resumable|
        try self.emitClearContinuation(resumable.continuation_id);
}

fn emitPublishTop(self: anytype) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, abi.lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, abi.callinfo_top_offset);
    try self.body.i32Store(self.allocator, 2, abi.lua_state_top_offset);
}

fn emitStoreConstantString(self: anytype, shape: StringMethodShape) Error!void {
    const dest = shape.function_register;
    try self.body.localGet(self.allocator, self.base_local);
    try self.emitVmConstantAddress(shape.compare_constant);
    try self.body.i32Load(self.allocator, 2, 0);
    try self.body.i32Store(self.allocator, 2, try slotOffset(dest, 0));
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.i32Store(self.allocator, 2, try slotOffset(dest, 4));
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.i32Store(self.allocator, 2, try slotOffset(dest, abi.tvalue_extra_offset));
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, @intCast(abi.lua_tag_string));
    try self.body.i32Store(self.allocator, 2, try slotOffset(dest, abi.tvalue_tag_offset));
}

// Length and offset are already the slice the helper would allocate.
// Equal bytes are the interned constant. Anything else is nil, which both
// equality forms treat as not equal to that constant.
fn emitStoreComparedSlice(self: anytype, shape: StringMethodShape) Error!void {
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Const(self.allocator, @intCast(shape.needle_len));
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    if (shape.needle_len == 0) {
        try emitStoreConstantString(self, shape);
    } else {
        try self.body.localGet(self.allocator, self.call_aux_local);
        try self.body.i32Const(self.allocator, @intCast(abi.tstring_data_offset));
        try self.body.opcode(self.allocator, i32_add);
        try self.body.localGet(self.allocator, self.call_proto_local);
        try self.body.opcode(self.allocator, i32_add);
        try self.body.localSet(self.allocator, self.call_meta_local);
        try self.body.i32Const(self.allocator, 1);
        var index: u32 = 0;
        while (index < shape.needle_len) : (index += 1) {
            try self.body.localGet(self.allocator, self.call_meta_local);
            try self.body.i32Load8U(self.allocator, 0, index);
            try self.body.i32Const(self.allocator, shape.needle[index]);
            try self.body.i32Eq(self.allocator);
            try self.body.opcode(self.allocator, i32_and);
        }
        try self.body.ifVoid(self.allocator);
        try emitStoreConstantString(self, shape);
        try self.body.else_(self.allocator);
        try emitStoreNil(self, shape.function_register);
        try self.body.end(self.allocator);
    }
    try self.body.else_(self.allocator);
    try emitStoreNil(self, shape.function_register);
    try self.body.end(self.allocator);
}

fn elidedSiteIndex(self: anytype, tag_id: u32) ?u32 {
    var index: u32 = 0;
    while (index < self.elided_sub_count) : (index += 1) {
        if (self.elided_subs[index].tag_id == tag_id)
            return index;
    }
    return null;
}

fn elidedCall(self: anytype, call_id: u32) bool {
    var index: u32 = 0;
    while (index < self.elided_sub_count) : (index += 1) {
        if (self.elided_subs[index].call_id == call_id)
            return true;
    }
    return false;
}

// Record compare sites before blocks are emitted. A full table leaves that
// call on the allocating slice, and the equality blocks keep pointer identity.
pub fn noteElidedStringSubs(self: anytype) Error!void {
    var id: u32 = 0;
    while (id < self.function.instruction_count) : (id += 1) {
        const instruction = try self.instruction(id);
        if (instruction.command != .call or instruction.operand_count != 3)
            continue;
        const target = self.vmRegisterIndex(try self.operand(instruction, 0)) catch continue;
        const parameter_operand = try self.operand(instruction, 1);
        const result_operand = try self.operand(instruction, 2);
        if (parameter_operand.kind != .constant or result_operand.kind != .constant)
            continue;
        const parameter_count = (try self.constant(parameter_operand.value)).intValue() orelse continue;
        const result_count = (try self.constant(result_operand.value)).intValue() orelse continue;
        const shape = (try stringMethodShape(self, id, target, parameter_count, result_count)) orelse continue;
        if (!shape.elide_slice)
            continue;
        if (self.elided_sub_count + @as(u32, shape.elided_count) > self.elided_subs.len)
            continue;
        var index: u8 = 0;
        while (index < shape.elided_count) : (index += 1) {
            const compare = shape.elided[index];
            self.elided_subs[self.elided_sub_count] = .{
                .tag_id = compare.tag_id,
                .call_id = shape.call_id,
                .result = shape.function_register,
                .receiver = shape.receiver,
                .needle_len = compare.needle_len,
                .needle = compare.needle,
            };
            self.elided_sub_count += 1;
        }
    }
}

// Pointer, byte offset, and length occupy the result slot. The tag is not a Luau tag,
// so a compare that this fusion did not claim still takes the false edge.
fn emitStoreElidedSlice(self: anytype, shape: StringMethodShape) Error!void {
    const dest = shape.function_register;
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Store(self.allocator, 2, try slotOffset(dest, 0));
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Store(self.allocator, 2, try slotOffset(dest, 4));
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Store(self.allocator, 2, try slotOffset(dest, abi.tvalue_extra_offset));
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, elided_slice_tag);
    try self.body.i32Store(self.allocator, 2, try slotOffset(dest, abi.tvalue_tag_offset));
}

fn emitNeedleEqual(self: anytype, needle: []const u8) Error!void {
    try self.body.localGet(self.allocator, self.table_index_local);
    try self.body.i32Const(self.allocator, @intCast(needle.len));
    try self.body.i32Eq(self.allocator);
    try self.body.ifI32(self.allocator);
    if (needle.len == 0) {
        try self.body.i32Const(self.allocator, 1);
    } else {
        try self.body.localGet(self.allocator, self.call_aux_local);
        try self.body.i32Const(self.allocator, @intCast(abi.tstring_data_offset));
        try self.body.opcode(self.allocator, i32_add);
        try self.body.localGet(self.allocator, self.call_proto_local);
        try self.body.opcode(self.allocator, i32_add);
        try self.body.localSet(self.allocator, self.call_meta_local);
        try self.body.i32Const(self.allocator, 1);
        for (needle, 0..) |byte, index| {
            try self.body.localGet(self.allocator, self.call_meta_local);
            try self.body.i32Load8U(self.allocator, 0, @intCast(index));
            try self.body.i32Const(self.allocator, byte);
            try self.body.i32Eq(self.allocator);
            try self.body.opcode(self.allocator, i32_and);
        }
    }
    try self.body.else_(self.allocator);
    try self.body.i32Const(self.allocator, 0);
    try self.body.end(self.allocator);
}

fn emitStashedSliceEqual(self: anytype, site: ElidedSubSite) Error!void {
    const slot = try slotOffset(site.result, 0);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, slot);
    try self.body.localSet(self.allocator, self.call_aux_local);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, try slotOffset(site.result, 4));
    try self.body.localSet(self.allocator, self.call_proto_local);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, try slotOffset(site.result, abi.tvalue_extra_offset));
    try self.body.localSet(self.allocator, self.table_index_local);

    try emitTagEquals(self, site.receiver, abi.lua_tag_string);
    try self.body.ifI32(self.allocator);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, try slotOffset(site.receiver, 0));
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Eq(self.allocator);
    try self.body.else_(self.allocator);
    try self.body.i32Const(self.allocator, 0);
    try self.body.end(self.allocator);

    try self.body.ifI32(self.allocator);
    try emitNeedleEqual(self, site.needle[0..site.needle_len]);
    try self.body.else_(self.allocator);
    try self.body.i32Const(self.allocator, 0);
    try self.body.end(self.allocator);
}

fn emitPointerStringEqual(self: anytype, result: u32, rhs: u32) Error!void {
    if ((rhs & 0x8000_0000) == 0)
        return Error.InvalidOperandType;
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, try slotOffset(result, abi.tvalue_tag_offset));
    try self.body.i32Const(self.allocator, @intCast(abi.lua_tag_string));
    try self.body.i32Eq(self.allocator);
    try self.body.ifI32(self.allocator);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, try slotOffset(result, 0));
    try self.emitVmConstantAddress(.{
        .kind = .vm_const,
        .value = rhs & 0x7fff_ffff,
    });
    try self.body.i32Load(self.allocator, 2, 0);
    try self.body.i32Eq(self.allocator);
    try self.body.else_(self.allocator);
    try self.body.i32Const(self.allocator, 0);
    try self.body.end(self.allocator);
}

// Leaves one i32: 1 when the stashed slice matches this constant. A real string
// result, including the guard miss, uses pointer identity.
pub fn tryEmitElidedSubCondition(self: anytype, tag_id: u32, rhs: u32) Error!bool {
    const site_index = elidedSiteIndex(self, tag_id) orelse return false;
    const site = self.elided_subs[site_index];
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, try slotOffset(site.result, abi.tvalue_tag_offset));
    try self.body.i32Const(self.allocator, elided_slice_tag);
    try self.body.i32Eq(self.allocator);
    try self.body.ifI32(self.allocator);
    try emitStashedSliceEqual(self, site);
    try self.body.else_(self.allocator);
    try emitPointerStringEqual(self, site.result, rhs);
    try self.body.end(self.allocator);
    return true;
}

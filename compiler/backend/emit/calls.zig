const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");
const admission = @import("luauc_backend_admission");

const StringKeyPool = model.StringKeyPool;
const Error = model.Error;
const StaticRequirePattern = model.StaticRequirePattern;
const FastcallPattern = model.FastcallPattern;
const TypeNamePattern = model.TypeNamePattern;
const BuiltinFallback = model.BuiltinFallback;
const ir_cmd_adjust_stack_to_top = abi.ir_cmd_adjust_stack_to_top;
const lua_state_top_offset = abi.lua_state_top_offset;
const lua_state_ci_offset = abi.lua_state_ci_offset;
const callinfo_top_offset = abi.callinfo_top_offset;
const tvalue_size = abi.tvalue_size;
const tvalue_tag_offset = abi.tvalue_tag_offset;
const tstring_len_offset = abi.tstring_len_offset;
const tstring_data_offset = abi.tstring_data_offset;
const lua_tag_number = abi.lua_tag_number;
const lua_tag_string = abi.lua_tag_string;
const lua_tag_vector = abi.lua_tag_vector;
const callinfo_func_offset = abi.callinfo_func_offset;
const closure_env_offset = abi.closure_env_offset;
const closure_is_c_offset = abi.closure_is_c_offset;
const closure_l_proto_offset = abi.closure_l_proto_offset;
const proto_constants_offset = abi.proto_constants_offset;
const proto_sizek_offset = abi.proto_sizek_offset;
const table_safeenv_offset = abi.table_safeenv_offset;
const lua_tag_nil = abi.lua_tag_nil;
const status_ok = abi.status_ok;
const status_unsupported_type = abi.status_unsupported_type;
const status_internal_error = abi.status_internal_error;
const lbf_operand_none = abi.lbf_operand_none;
const lop_getimport = abi.lop_getimport;
const lop_call = abi.lop_call;
const lop_fastcall3 = abi.lop_fastcall3;
const lop_fastcall1 = abi.lop_fastcall1;
const lop_fastcall2 = abi.lop_fastcall2;
const lop_fastcall2k = abi.lop_fastcall2k;

pub noinline fn emitPrepVarargs(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 2);
    if (!self.function.variadic or !self.proto.is_vararg)
        return Error.UnsupportedVariadicFunction;

    const pc_operand = try self.operand(instruction_value, 0);
    const parameter_operand = try self.operand(instruction_value, 1);
    if (pc_operand.kind != .constant or parameter_operand.kind != .constant)
        return Error.InvalidOperandType;
    _ = (try self.constant(pc_operand.value)).uintValue() orelse return Error.InvalidOperandType;
    const parameter_count = (try self.constant(parameter_operand.value)).intValue() orelse return Error.InvalidOperandType;
    if (parameter_count < 0 or parameter_count != @as(i32, self.proto.num_params))
        return Error.UnsupportedVariadicFunction;

    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, parameter_count);
    try self.body.call(self.allocator, self.prep_varargs orelse return Error.UnsupportedCommand);
    // PREPVARARGS checks/grows the stack and always rewires the active frame base.
    try self.emitReloadBase();
}
pub noinline fn emitGetVarargs(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 3);
    if (!self.function.variadic or !self.proto.is_vararg)
        return Error.UnsupportedVariadicFunction;

    const pc_operand = try self.operand(instruction_value, 0);
    if (pc_operand.kind != .constant)
        return Error.InvalidOperandType;
    _ = (try self.constant(pc_operand.value)).uintValue() orelse return Error.InvalidOperandType;

    const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
    const count_operand = try self.operand(instruction_value, 2);
    if (count_operand.kind != .constant)
        return Error.InvalidOperandType;
    const count = (try self.constant(count_operand.value)).intValue() orelse return Error.InvalidOperandType;
    if (count < -1)
        return Error.UnsupportedVariadicFunction;

    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(destination));
    if (count == -1) {
        try self.body.call(self.allocator, self.get_varargs_multret orelse return Error.UnsupportedCommand);
        // The multret helper checks/grows the stack and updates L->top.
        try self.emitReloadBase();
    } else {
        const count_u32: u32 = @intCast(count);
        if (count_u32 > @as(u32, self.proto.max_stack_size) - destination)
            return Error.UnsupportedVariadicFunction;
        try self.body.i32Const(self.allocator, count);
        try self.body.call(self.allocator, self.get_varargs_fixed orelse return Error.UnsupportedCommand);
    }
}
pub fn vmString(self: anytype, operand_value: snapshot_v1.IrOperand) Error![]const u8 {
    if (operand_value.kind != .vm_const)
        return Error.InvalidOperandType;
    const value = try self.snapshot.vmConstant(self.proto, operand_value.value);
    if (value.kind != .string)
        return Error.InvalidOperandType;
    return self.snapshot.string(value.payload0);
}
pub fn builtinIdentityMatches(_: anytype, id: u32, object: []const u8, name: []const u8) bool {
    const expected_object: []const u8, const expected_name: []const u8 = switch (id) {
        1 => .{ "", "assert" },
        2 => .{ "math", "abs" },
        3 => .{ "math", "acos" },
        4 => .{ "math", "asin" },
        5 => .{ "math", "atan2" },
        6 => .{ "math", "atan" },
        7 => .{ "math", "ceil" },
        8 => .{ "math", "cosh" },
        9 => .{ "math", "cos" },
        10 => .{ "math", "deg" },
        11 => .{ "math", "exp" },
        12 => .{ "math", "floor" },
        13 => .{ "math", "fmod" },
        14 => .{ "math", "frexp" },
        15 => .{ "math", "ldexp" },
        16 => .{ "math", "log10" },
        17 => .{ "math", "log" },
        18 => .{ "math", "max" },
        19 => .{ "math", "min" },
        20 => .{ "math", "modf" },
        21 => .{ "math", "pow" },
        22 => .{ "math", "rad" },
        23 => .{ "math", "sinh" },
        24 => .{ "math", "sin" },
        25 => .{ "math", "sqrt" },
        26 => .{ "math", "tanh" },
        27 => .{ "math", "tan" },
        28 => .{ "bit32", "arshift" },
        29 => .{ "bit32", "band" },
        30 => .{ "bit32", "bnot" },
        31 => .{ "bit32", "bor" },
        32 => .{ "bit32", "bxor" },
        33 => .{ "bit32", "btest" },
        34 => .{ "bit32", "extract" },
        35 => .{ "bit32", "lrotate" },
        36 => .{ "bit32", "lshift" },
        37 => .{ "bit32", "replace" },
        38 => .{ "bit32", "rrotate" },
        39 => .{ "bit32", "rshift" },
        40 => .{ "", "type" },
        41 => .{ "string", "byte" },
        42 => .{ "string", "char" },
        43 => .{ "string", "len" },
        44 => .{ "", "typeof" },
        45 => .{ "string", "sub" },
        46 => .{ "math", "clamp" },
        47 => .{ "math", "sign" },
        48 => .{ "math", "round" },
        49 => .{ "", "rawset" },
        50 => .{ "", "rawget" },
        51 => .{ "", "rawequal" },
        52 => .{ "table", "insert" },
        53 => if (std.mem.eql(u8, object, "table")) .{ "table", "unpack" } else .{ "", "unpack" },
        54 => .{ "vector", "create" },
        55 => .{ "bit32", "countlz" },
        56 => .{ "bit32", "countrz" },
        57 => .{ "", "select" },
        58 => .{ "", "rawlen" },
        59 => .{ "bit32", "extract" },
        60 => .{ "", "getmetatable" },
        61 => .{ "", "setmetatable" },
        62 => .{ "", "tonumber" },
        63 => .{ "", "tostring" },
        64 => .{ "bit32", "byteswap" },
        65 => .{ "buffer", "readi8" },
        66 => .{ "buffer", "readu8" },
        67 => if (std.mem.eql(u8, name, "writeu8")) .{ "buffer", "writeu8" } else .{ "buffer", "writei8" },
        68 => .{ "buffer", "readi16" },
        69 => .{ "buffer", "readu16" },
        70 => if (std.mem.eql(u8, name, "writeu16")) .{ "buffer", "writeu16" } else .{ "buffer", "writei16" },
        71 => .{ "buffer", "readi32" },
        72 => .{ "buffer", "readu32" },
        73 => if (std.mem.eql(u8, name, "writeu32")) .{ "buffer", "writeu32" } else .{ "buffer", "writei32" },
        74 => .{ "buffer", "readf32" },
        75 => .{ "buffer", "writef32" },
        76 => .{ "buffer", "readf64" },
        77 => .{ "buffer", "writef64" },
        78 => .{ "vector", "magnitude" },
        79 => .{ "vector", "normalize" },
        80 => .{ "vector", "cross" },
        81 => .{ "vector", "dot" },
        82 => .{ "vector", "floor" },
        83 => .{ "vector", "ceil" },
        84 => .{ "vector", "abs" },
        85 => .{ "vector", "sign" },
        86 => .{ "vector", "clamp" },
        87 => .{ "vector", "min" },
        88 => .{ "vector", "max" },
        89 => .{ "math", "lerp" },
        90 => .{ "vector", "lerp" },
        91 => .{ "math", "isnan" },
        92 => .{ "math", "isinf" },
        93 => .{ "math", "isfinite" },
        94 => .{ "integer", "create" },
        95 => .{ "integer", "tonumber" },
        96 => .{ "integer", "neg" },
        97 => .{ "integer", "add" },
        98 => .{ "integer", "sub" },
        99 => .{ "integer", "mul" },
        100 => .{ "integer", "div" },
        101 => .{ "integer", "min" },
        102 => .{ "integer", "max" },
        103 => .{ "integer", "rem" },
        104 => .{ "integer", "idiv" },
        105 => .{ "integer", "udiv" },
        106 => .{ "integer", "urem" },
        107 => .{ "integer", "mod" },
        108 => .{ "integer", "clamp" },
        109 => .{ "integer", "band" },
        110 => .{ "integer", "bor" },
        111 => .{ "integer", "bnot" },
        112 => .{ "integer", "bxor" },
        113 => .{ "integer", "lt" },
        114 => .{ "integer", "le" },
        115 => .{ "integer", "ult" },
        116 => .{ "integer", "ule" },
        117 => .{ "integer", "gt" },
        118 => .{ "integer", "ge" },
        119 => .{ "integer", "ugt" },
        120 => .{ "integer", "uge" },
        121 => .{ "integer", "lshift" },
        122 => .{ "integer", "rshift" },
        123 => .{ "integer", "arshift" },
        124 => .{ "integer", "lrotate" },
        125 => .{ "integer", "rrotate" },
        126 => .{ "integer", "extract" },
        127 => .{ "integer", "btest" },
        128 => .{ "integer", "countrz" },
        129 => .{ "integer", "countlz" },
        130 => .{ "integer", "bswap" },
        131 => .{ "buffer", "readinteger" },
        132 => .{ "buffer", "writeinteger" },
        else => return false,
    };
    return std.mem.eql(u8, object, expected_object) and std.mem.eql(u8, name, expected_name);
}
pub fn builtinFallback(self: anytype, pc: u32) Error!?BuiltinFallback {
    var fast_pc: u32 = undefined;
    var word: u32 = undefined;
    var opcode: u8 = undefined;
    if (pc >= 1) {
        const candidate = try self.snapshot.bytecodeWord(self.proto, pc - 1);
        const candidate_opcode: u8 = @truncate(candidate);
        if (candidate_opcode == lop_fastcall1) {
            fast_pc = pc - 1;
            word = candidate;
            opcode = candidate_opcode;
        } else if (pc >= 2) {
            const two_word = try self.snapshot.bytecodeWord(self.proto, pc - 2);
            const two_word_opcode: u8 = @truncate(two_word);
            if (two_word_opcode != lop_fastcall2 and two_word_opcode != lop_fastcall2k and
                two_word_opcode != lop_fastcall3)
                return null;
            fast_pc = pc - 2;
            word = two_word;
            opcode = two_word_opcode;
        } else return null;
    } else return null;

    const id = (word >> 8) & 0xff;
    var registers = [_]u32{ snapshot_v1.no_id, snapshot_v1.no_id, snapshot_v1.no_id };
    registers[0] = (word >> 16) & 0xff;
    var argument_count: u8 = 1;
    if (opcode == lop_fastcall2 or opcode == lop_fastcall2k or opcode == lop_fastcall3) {
        const aux = try self.snapshot.bytecodeWord(self.proto, fast_pc + 1);
        argument_count = if (opcode == lop_fastcall3) 3 else 2;
        if (opcode != lop_fastcall2k)
            registers[1] = aux & 0xff;
        if (opcode == lop_fastcall3)
            registers[2] = (aux >> 8) & 0xff;
    }

    var import_id: ?u32 = null;
    var found_call = false;
    var cursor = pc;
    const limit = @min(self.proto.code_count, std.math.add(u32, pc, 12) catch self.proto.code_count);
    while (cursor < limit) : (cursor += 1) {
        const fallback_word = try self.snapshot.bytecodeWord(self.proto, cursor);
        const fallback_opcode: u8 = @truncate(fallback_word);
        if (fallback_opcode == lop_getimport)
            import_id = fallback_word >> 16;
        if (fallback_opcode == lop_call) {
            found_call = true;
            break;
        }
    }
    if (!found_call or import_id == null)
        return null;

    const import = try self.snapshot.vmConstant(self.proto, import_id.?);
    if (import.kind != .import or import.payload1 == 0 or import.payload1 > 2)
        return null;
    const object_item = try self.snapshot.vmConstantItem(import.payload0);
    const name_item = try self.snapshot.vmConstantItem(import.payload0 + import.payload1 - 1);
    if (object_item.value != snapshot_v1.no_id or name_item.value != snapshot_v1.no_id)
        return null;
    const object_constant = try self.snapshot.vmConstant(self.proto, object_item.key);
    const name_constant = try self.snapshot.vmConstant(self.proto, name_item.key);
    if (object_constant.kind != .string or name_constant.kind != .string)
        return null;
    const object = if (import.payload1 == 1) "" else try self.snapshot.string(object_constant.payload0);
    const name = try self.snapshot.string(name_constant.payload0);
    if (!self.builtinIdentityMatches(id, object, name))
        return null;
    return .{
        .id = id,
        .name = name,
        .pc = pc,
        .argument_registers = registers,
        .argument_count = argument_count,
    };
}
pub fn guardFailureBlock(self: anytype, failure: snapshot_v1.IrOperand) Error!?snapshot_v1.IrBlock {
    if (failure.kind != .block or failure.value >= self.function.block_count)
        return null;
    const block = try self.snapshot.irBlock(self.function, failure.value);
    if (block.kind != .fallback or block.isEmpty() or block.finish < block.start + 3)
        return null;
    const saved = try self.instruction(block.finish - 2);
    const call = try self.instruction(block.finish - 1);
    const jump = try self.instruction(block.finish);
    if (saved.command != .set_savedpc or call.command != .call or jump.command != .jump)
        return null;
    return block;
}
pub fn isGuardFailure(self: anytype, failure: snapshot_v1.IrOperand) Error!bool {
    return failure.kind == .vm_exit or try self.guardFailureBlock(failure) != null;
}
pub fn guardFailureIsBuiltin(
    self: anytype,
    failure: snapshot_v1.IrOperand,
    object: []const u8,
    name: []const u8,
) Error!bool {
    if (failure.kind == .vm_exit) {
        const fallback = (try self.builtinFallback(failure.value)) orelse return false;
        return self.builtinIdentityMatches(fallback.id, object, name);
    }
    const block = (try self.guardFailureBlock(failure)) orelse return false;
    var found = false;
    var instruction_id = block.start;
    while (instruction_id <= block.finish) : (instruction_id += 1) {
        const instruction_value = try self.instruction(instruction_id);
        if (instruction_value.command != .get_cached_import)
            continue;
        if (found or instruction_value.operand_count != 4)
            return false;
        const import_operand = try self.operand(instruction_value, 1);
        if (import_operand.kind != .vm_const)
            return false;
        const import = try self.snapshot.vmConstant(self.proto, import_operand.value);
        if (import.kind != .import or import.payload1 == 0 or import.payload1 > 2)
            return false;
        const object_item = try self.snapshot.vmConstantItem(import.payload0);
        const name_item = try self.snapshot.vmConstantItem(import.payload0 + import.payload1 - 1);
        if (object_item.value != snapshot_v1.no_id or name_item.value != snapshot_v1.no_id)
            return false;
        const object_constant = try self.snapshot.vmConstant(self.proto, object_item.key);
        const name_constant = try self.snapshot.vmConstant(self.proto, name_item.key);
        if (object_constant.kind != .string or name_constant.kind != .string)
            return false;
        const imported_object = if (import.payload1 == 1) "" else try self.snapshot.string(object_constant.payload0);
        const imported_name = try self.snapshot.string(name_constant.payload0);
        if (!std.mem.eql(u8, imported_object, object) or !std.mem.eql(u8, imported_name, name))
            return false;
        found = true;
    }
    return found;
}
pub noinline fn emitSingleGlobalImport(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 4);
    const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 0));
    const import_operand = try self.operand(instruction_value, 1);
    const descriptor = try self.operand(instruction_value, 2);
    const pc_operand = try self.operand(instruction_value, 3);
    if (import_operand.kind != .vm_const or descriptor.kind != .constant or pc_operand.kind != .constant)
        return Error.InvalidOperandType;

    const import = try self.snapshot.vmConstant(self.proto, import_operand.value);
    if (import.kind != .import or import.payload1 == 0 or import.payload1 > 3)
        return Error.UnsupportedControlFlow;
    const encoded = (try self.constant(descriptor.value)).importValue() orelse return Error.InvalidOperandType;
    const pc = (try self.constant(pc_operand.value)).uintValue() orelse return Error.InvalidOperandType;
    try self.emitDecodedGlobalImport(destination, import_operand.value, encoded, pc);
}
pub noinline fn emitDecodedGlobalImport(
    self: anytype,
    destination: u32,
    import_id: u32,
    encoded: u32,
    pc: u32,
) Error!void {
    if (destination >= self.proto.max_stack_size or import_id >= self.proto.vm_constant_count)
        return Error.InvalidOperandType;
    const import = try self.snapshot.vmConstant(self.proto, import_id);
    if (import.kind != .import or import.payload1 == 0 or import.payload1 > 3)
        return Error.UnsupportedControlFlow;
    var keys = [_]StringKeyPool.Entry{undefined} ** 3;
    var key_ids = [_]u32{0} ** 3;
    var expected = import.payload1 << 30;
    var index: u32 = 0;
    while (index < import.payload1) : (index += 1) {
        const item = try self.snapshot.vmConstantItem(import.payload0 + index);
        if (item.value != snapshot_v1.no_id or item.key >= (1 << 10))
            return Error.UnsupportedControlFlow;
        const shift: u5 = @intCast(20 - index * 10);
        expected |= item.key << shift;
        key_ids[index] = item.key;
        keys[index] = try self.string_keys.intern(
            self.allocator,
            try self.vmString(.{ .kind = .vm_const, .value = item.key }),
        );
    }
    if (encoded != expected)
        return Error.UnsupportedControlFlow;
    // A safe environment already resolved this import into Proto.k at load.
    // Nil and unsafe environments keep the semantic lookup.
    try self.emitPcLocation(pc);
    try emitCachedImportHit(self, destination, import_id);
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    // One-level imports are an environment string-key read. The constant is already
    // interned. A chain still uses get_global so a nil head keeps luaV_gettable's error.
    if (import.payload1 == 1)
        try self.emitInlineEnvGet(destination, key_ids[0]);
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(destination));
    try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(keys[0].offset));
    try self.body.i32Const(self.allocator, @intCast(keys[0].length));
    try self.body.call(self.allocator, self.get_global orelse return Error.UnsupportedCommand);
    try self.emitReloadBase();
    index = 1;
    while (index < import.payload1) : (index += 1) {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Const(self.allocator, @intCast(destination));
        try self.body.i32Const(self.allocator, @intCast(destination));
        try self.body.i32ConstDataAddress(self.allocator, 0, @intCast(keys[index].offset));
        try self.body.i32Const(self.allocator, @intCast(keys[index].length));
        try self.body.call(self.allocator, self.table_get_string orelse return Error.UnsupportedCommand);
        try self.emitReloadBase();
    }
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
}

// Copy Proto.k[import] when the active frame is a safe Lua closure and the slot is not nil.
// call_proto_local is 1 on that hit and 0 for every other outcome.
fn emitCachedImportHit(self: anytype, destination: u32, import_id: u32) Error!void {
    try self.body.i32Const(self.allocator, 0);
    try self.body.localSet(self.allocator, self.call_proto_local);
    const index_i32 = std.math.cast(i32, import_id) orelse return;
    const slot_addend = std.math.cast(i32, std.math.mul(u32, import_id, tvalue_size) catch return) orelse return;

    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, callinfo_func_offset);
    try self.body.i32Load(self.allocator, 2, 0);
    try self.body.localTee(self.allocator, self.call_meta_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load8U(self.allocator, 0, closure_is_c_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, closure_env_offset);
    try self.body.localTee(self.allocator, self.call_aux_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Load8U(self.allocator, 0, table_safeenv_offset);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, closure_l_proto_offset);
    try self.body.localTee(self.allocator, self.call_meta_local);
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, index_i32);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, proto_sizek_offset);
    try self.body.opcode(self.allocator, 0x49); // i32.lt_u
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Load(self.allocator, 2, proto_constants_offset);
    try self.body.localTee(self.allocator, self.call_func_local);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, slot_addend);
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.localTee(self.allocator, self.call_func_local);
    try self.body.i32Load(self.allocator, 2, tvalue_tag_offset);
    try self.body.i32Const(self.allocator, lua_tag_nil);
    try self.body.i32Eq(self.allocator);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.emitReloadBase();
    const offset = destination * tvalue_size;
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i64Load(self.allocator, 3, 0);
    try self.body.i64Store(self.allocator, 3, offset);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i64Load(self.allocator, 3, 8);
    try self.body.i64Store(self.allocator, 3, offset + 8);
    try self.body.i32Const(self.allocator, 1);
    try self.body.localSet(self.allocator, self.call_proto_local);
    try self.body.end(self.allocator); // resolved value
    try self.body.end(self.allocator); // constant array
    try self.body.end(self.allocator); // constant index
    try self.body.end(self.allocator); // proto
    try self.body.end(self.allocator); // safeenv
    try self.body.end(self.allocator); // environment
    try self.body.end(self.allocator); // Lua closure
    try self.body.end(self.allocator); // closure pointer
}
pub fn staticRequireTarget(self: anytype, start: u32, block: snapshot_v1.IrBlock) Error!?StaticRequirePattern {
    const package = self.static_package orelse return null;
    const first = try self.instruction(start);
    const has_marker = first.command == .nop or first.command == .check_safe_env;
    const get_id = std.math.add(u32, start, @intFromBool(has_marker)) catch return Error.ResourceLimit;
    const end = std.math.add(u32, get_id, 5) catch return Error.ResourceLimit;
    if (start < block.start or end > block.finish)
        return null;

    const get_import = try self.instruction(get_id);
    const load_path = try self.instruction(get_id + 1);
    const store_path = try self.instruction(get_id + 2);
    const interrupt = try self.instruction(get_id + 3);
    const saved_pc = try self.instruction(get_id + 4);
    const call = try self.instruction(get_id + 5);
    if (get_import.command != .get_cached_import or load_path.command != .load_tvalue or
        store_path.command != .store_tvalue or interrupt.command != .interrupt or
        saved_pc.command != .set_savedpc or call.command != .call)
        return null;
    if (!try admission.isRequireImportInstruction(self.snapshot, self.function, self.proto, get_import))
        return null;
    if (has_marker and first.command == .nop) {
        var prefix = block.start;
        if (prefix < start and (try self.instruction(prefix)).command == .fallback_prepvarargs)
            prefix += 1;
        while (prefix < start and (try self.instruction(prefix)).command == .coverage)
            prefix += 1;
        if (prefix != start or (block.flags & (1 << 0)) == 0 or first.operand_count != 0)
            return Error.UnsupportedControlFlow;
    } else if (has_marker) {
        try self.requireOperandCount(first, 1);
        const failure = try self.operand(first, 0);
        if (failure.kind != .vm_exit)
            return Error.UnsupportedControlFlow;
    }

    try self.requireOperandCount(get_import, 4);
    const destination = try self.vmRegisterIndex(try self.operand(get_import, 0));
    const import_pc = try self.operand(get_import, 3);
    if (import_pc.kind != .constant or (try self.constant(import_pc.value)).uintValue() == null)
        return Error.InvalidOperandType;

    try self.requireOperandCount(load_path, 3);
    const path_operand = try self.operand(load_path, 0);
    const path = try self.vmString(path_operand);
    const load_offset = try self.operand(load_path, 1);
    const load_tag = try self.operand(load_path, 2);
    if (load_offset.kind != .constant or (try self.constant(load_offset.value)).intValue() != 0 or
        load_tag.kind != .constant or (try self.constant(load_tag.value)).tagValue() != lua_tag_string)
        return Error.UnsupportedControlFlow;

    try self.requireOperandCount(store_path, 2);
    const argument = try self.vmRegisterIndex(try self.operand(store_path, 0));
    const stored = try self.operand(store_path, 1);
    if (argument != destination + 1 or stored.kind != .instruction or stored.value != get_id + 1)
        return Error.UnsupportedControlFlow;

    try self.requireOperandCount(interrupt, 1);
    const interrupt_pc = try self.operand(interrupt, 0);
    if (interrupt_pc.kind != .constant or (try self.constant(interrupt_pc.value)).uintValue() == null)
        return Error.InvalidOperandType;
    _ = try self.savedPc(saved_pc);

    try self.requireOperandCount(call, 3);
    if (try self.vmRegisterIndex(try self.operand(call, 0)) != destination)
        return Error.UnsupportedControlFlow;
    const parameter_count = try self.operand(call, 1);
    const result_count = try self.operand(call, 2);
    if (parameter_count.kind != .constant or result_count.kind != .constant or
        (try self.constant(parameter_count.value)).intValue() != 1 or
        (try self.constant(result_count.value)).intValue() != 1)
        return Error.UnsupportedControlFlow;

    const target = package.moduleByName(path) orelse return Error.UnsupportedControlFlow;
    return .{ .end = end, .interrupt_id = get_id + 3, .destination = destination, .module_id = target.id };
}
pub noinline fn emitStaticRequire(self: anytype, interrupt_id: u32, destination: u32, module_id: u32) Error!void {
    // The source CALL cluster carries its ordinary interrupt/fuel safepoint. Static resolution
    // replaces import lookup and dispatch, not the observable interrupt boundary.
    try self.emitInterrupt(interrupt_id, try self.instruction(interrupt_id));
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(destination));
    try self.body.i32Const(self.allocator, @intCast(module_id));
    try self.body.call(self.allocator, self.require_static orelse return Error.UnsupportedCommand);
    try self.body.localTee(self.allocator, self.status_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.emitReloadBase();
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.return_(self.allocator);
    try self.body.end(self.allocator);
}
pub fn isTableInsertAppendSafeEnv(self: anytype, instruction_id: u32) Error!bool {
    const commands = [_]snapshot_v1.IrCommand{
        .check_safe_env,
        .nop,
        .nop,
        .nop,
        .nop,
    };
    if (!try self.commandRangeMatches(instruction_id, &commands))
        return false;

    const guard = try self.instruction(instruction_id);
    if (guard.operand_count != 1 or !try self.isGuardFailure(try self.operand(guard, 0)))
        return false;

    const append_start = instruction_id + @as(u32, @intCast(commands.len));
    const append = (try self.tableInsertAppendPatternAt(append_start)) orelse return false;
    self.requireSingleCompilableBlockRange(instruction_id, append.finish) catch return false;
    return true;
}
pub noinline fn emitStatusCheckedCall(self: anytype, helper: wasm.FunctionRef) Error!void {
    try self.body.call(self.allocator, helper);
    try self.body.localTee(self.allocator, self.status_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.emitReloadBase();
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.return_(self.allocator);
    try self.body.end(self.allocator);
}
pub noinline fn emitSafeEnvCheck(self: anytype, instruction_id: u32) Error!void {
    const instruction_value = try self.instruction(instruction_id);
    try self.requireOperandCount(instruction_value, 1);
    const failure = try self.operand(instruction_value, 0);
    if (failure.kind != .block and failure.kind != .vm_exit)
        return Error.InvalidOperandType;
    // Same three results as luauc_runtime_v1_check_safe_env: internal error when the closure has
    // no environment, unsupported when safeenv is clear, OK otherwise. The active frame is this
    // function, so the check is the environment pointer and its safeenv byte.
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, callinfo_func_offset);
    try self.body.i32Load(self.allocator, 2, 0);
    try self.body.i32Load(self.allocator, 2, closure_env_offset);
    try self.body.localTee(self.allocator, self.status_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, status_internal_error);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.else_(self.allocator);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Load8U(self.allocator, 0, table_safeenv_offset);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, status_unsupported_type);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.else_(self.allocator);
    try self.body.i32Const(self.allocator, status_ok);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try self.emitReloadBase();

    // vm_exit has no compiled slow arm. An unsafe environment returns its status.
    // A safe environment falls through into the guarded IR.
    if (failure.kind == .vm_exit) {
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.return_(self.allocator);
        try self.body.end(self.allocator);
        return;
    }

    // The runtime returns only OK, UNSUPPORTED_TYPE (take the compiled slow arm), or a fatal
    // status. Preserve fatal statuses and route ordinary unsafe environments through the same
    // guard target produced by the pinned frontend.
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Const(self.allocator, status_unsupported_type);
    try self.body.i32Eq(self.allocator);
    try self.body.opcode(self.allocator, 0x72); // i32.or
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.return_(self.allocator);
    try self.body.end(self.allocator);

    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Const(self.allocator, status_unsupported_type);
    try self.body.i32Eq(self.allocator);
    try self.emitGuardFailure(failure);
}
pub noinline fn emitAdjustStackConstant(self: anytype, destination: u32, count: u32) Error!void {
    const end = std.math.add(u32, destination, count) catch return Error.ResourceLimit;
    if (end > self.proto.max_stack_size)
        return Error.ResourceLimit;
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, @intCast(end * tvalue_size));
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.i32Store(self.allocator, 2, lua_state_top_offset);
}
pub noinline fn emitAdjustStackDynamic(self: anytype, destination: u32) Error!void {
    if (destination >= self.proto.max_stack_size)
        return Error.ResourceLimit;
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, @intCast(destination * tvalue_size));
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Const(self.allocator, @intCast(tvalue_size));
    try self.body.opcode(self.allocator, 0x6c); // i32.mul
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.i32Store(self.allocator, 2, lua_state_top_offset);
}
pub noinline fn emitAdjustStackToTop(self: anytype) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, lua_state_ci_offset);
    try self.body.i32Load(self.allocator, 2, callinfo_top_offset);
    try self.body.i32Store(self.allocator, 2, lua_state_top_offset);
}
pub noinline fn emitGeneralInvokeFastcall(
    self: anytype,
    instruction_id: u32,
    instruction_value: snapshot_v1.IrInstruction,
) Error!void {
    try self.requireOperandCount(instruction_value, 7);
    if (instruction_id == 0 or (try self.instruction(instruction_id - 1)).command != .set_savedpc)
        return Error.UnsupportedControlFlow;
    try self.emitSavedPcLocation(try self.instruction(instruction_id - 1));
    const builtin_operand = try self.operand(instruction_value, 0);
    if (builtin_operand.kind != .constant)
        return Error.InvalidOperandType;
    const builtin_id = (try self.constant(builtin_operand.value)).uintValue() orelse return Error.InvalidOperandType;
    if (builtin_id >= 256)
        return Error.InvalidOperandType;
    const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
    const source = try self.vmRegisterIndex(try self.operand(instruction_value, 2));
    const argument_two = (try self.fastcallValueOperand(try self.operand(instruction_value, 3))) orelse
        return Error.UnsupportedControlFlow;
    const argument_three = (try self.fastcallValueOperand(try self.operand(instruction_value, 4))) orelse
        return Error.UnsupportedControlFlow;
    const parameter_count = try self.intConstant(try self.operand(instruction_value, 5));
    const result_count = try self.intConstant(try self.operand(instruction_value, 6));
    if (parameter_count < -1 or result_count < -1)
        return Error.UnsupportedControlFlow;
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(builtin_id));
    try self.body.i32Const(self.allocator, @intCast(destination));
    try self.body.i32Const(self.allocator, @intCast(source));
    try self.body.i32Const(self.allocator, @bitCast(argument_two));
    try self.body.i32Const(self.allocator, @bitCast(argument_three));
    try self.body.i32Const(self.allocator, result_count);
    try self.body.i32Const(self.allocator, parameter_count);
    try self.body.call(self.allocator, self.fastcall orelse return Error.UnsupportedCommand);
    try self.body.localTee(self.allocator, self.status_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.opcode(self.allocator, 0x48); // i32.lt_s
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.return_(self.allocator);
    try self.body.end(self.allocator);
    try self.emitReloadBase();
}

pub noinline fn emitDirectFastcall(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    try self.requireOperandCount(instruction_value, 4);
    const builtin_operand = try self.operand(instruction_value, 0);
    if (builtin_operand.kind != .constant)
        return Error.InvalidOperandType;
    const builtin_id = (try self.constant(builtin_operand.value)).uintValue() orelse return Error.InvalidOperandType;
    if (builtin_id >= 256)
        return Error.InvalidOperandType;
    const destination = try self.vmRegisterIndex(try self.operand(instruction_value, 1));
    const source = try self.vmRegisterIndex(try self.operand(instruction_value, 2));
    const result_count = try self.intConstant(try self.operand(instruction_value, 3));
    if (result_count < 0 or @as(u32, @intCast(result_count)) > @as(u32, self.proto.max_stack_size) - destination)
        return Error.InvalidOperandType;

    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(builtin_id));
    try self.body.i32Const(self.allocator, @intCast(destination));
    try self.body.i32Const(self.allocator, @intCast(source));
    try self.body.i32Const(self.allocator, @bitCast(lbf_operand_none));
    try self.body.i32Const(self.allocator, @bitCast(lbf_operand_none));
    try self.body.i32Const(self.allocator, result_count);
    try self.body.i32Const(self.allocator, 1);
    try self.body.call(self.allocator, self.fastcall orelse return Error.UnsupportedCommand);
    try self.body.localSet(self.allocator, self.status_local);
    try self.emitReloadBase();
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Const(self.allocator, result_count);
    try self.body.opcode(self.allocator, 0x47); // i32.ne
    try self.emitInternalErrorIf();
}
fn emitSlotBelowTop(self: anytype, register: u32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, @intCast(register * tvalue_size));
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Load(self.allocator, 2, lua_state_top_offset);
    try self.body.opcode(self.allocator, 0x49); // i32.lt_u
}

fn emitSlotTagEquals(self: anytype, register: u32, tag: u8) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, register * tvalue_size + tvalue_tag_offset);
    try self.body.i32Const(self.allocator, @intCast(tag));
    try self.body.i32Eq(self.allocator);
}

// Match luauF_byte for one register index. A miss leaves status negative so the CALL fallback runs.
// A fused numeric loop falls through on the hit and leaves only on the miss.
fn emitInlineStringByte(self: anytype, pattern: FastcallPattern) Error!void {
    const starts_at_guard = (try self.instruction(pattern.start)).command == .check_safe_env;
    const saved_id = pattern.start + @intFromBool(starts_at_guard);
    // The preceding check already returned on a null environment and left on an unsafe one.
    const guarded_before = !starts_at_guard and pattern.start > 0 and
        (try self.instruction(pattern.start - 1)).command == .check_safe_env;
    try self.emitSavedPcLocation(try self.instruction(saved_id));
    try self.body.i32Const(self.allocator, -1);
    try self.body.localSet(self.allocator, self.status_local);

    const index: u32 = pattern.argument_two;
    if (!guarded_before) {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Load(self.allocator, 2, lua_state_ci_offset);
        try self.body.i32Load(self.allocator, 2, callinfo_func_offset);
        try self.body.i32Load(self.allocator, 2, 0);
        try self.body.i32Load(self.allocator, 2, closure_env_offset);
        try self.body.localTee(self.allocator, self.call_aux_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, self.call_aux_local);
        try self.body.i32Load8U(self.allocator, 0, table_safeenv_offset);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.body.else_(self.allocator);
    }

    try self.emitReloadBase();
    try emitSlotBelowTop(self, pattern.source);
    try emitSlotBelowTop(self, index);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try emitSlotBelowTop(self, pattern.destination);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.ifVoid(self.allocator);
    try emitSlotTagEquals(self, pattern.source, lua_tag_string);
    try emitSlotTagEquals(self, index, lua_tag_number);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.ifVoid(self.allocator);

    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, pattern.source * tvalue_size);
    try self.body.localSet(self.allocator, self.call_aux_local);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.f64Load(self.allocator, 3, index * tvalue_size);
    try self.body.opcode(self.allocator, 0xfc);
    try self.body.opcode(self.allocator, 0x02); // i32.trunc_sat_f64_s
    try self.body.localSet(self.allocator, self.call_func_local);

    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, 0x48); // i32.lt_s
    try self.body.i32Eqz(self.allocator);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Load(self.allocator, 2, tstring_len_offset);
    try self.body.opcode(self.allocator, 0x4b); // i32.gt_u
    try self.body.i32Eqz(self.allocator);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.ifVoid(self.allocator);

    // Byte i is data[i - 1]. data begins at byte 20, so the address is string + 19 + i.
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, @intCast(pattern.destination * tvalue_size));
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, @intCast(tstring_data_offset - 1));
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.i32Load8U(self.allocator, 0, 0);
    try self.body.opcode(self.allocator, 0xb8); // f64.convert_i32_u
    try self.body.f64Store(self.allocator, 3, 0);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, lua_tag_number);
    try self.body.i32Store(self.allocator, 2, pattern.destination * tvalue_size + tvalue_tag_offset);
    try self.body.i32Const(self.allocator, 1);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.end(self.allocator); // index in range
    try self.body.end(self.allocator); // string and number tags
    try self.body.end(self.allocator); // live slots
    if (!guarded_before) {
        try self.body.end(self.allocator); // safeenv
        try self.body.end(self.allocator); // environment pointer
    }

    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.opcode(self.allocator, 0x48); // i32.lt_s
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, @intCast(pattern.fallback));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.else_(self.allocator);
    if (pattern.finish > pattern.start and
        (try self.instruction(pattern.finish - 1)).command == ir_cmd_adjust_stack_to_top)
        try self.emitAdjustStackToTop();
    try self.body.i32Const(self.allocator, @intCast(pattern.fast_target));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.end(self.allocator);

    if (!self.rejoin_fallthrough) {
        try self.body.branch(self.allocator, self.loop_branch_depth);
    } else {
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.i32Const(self.allocator, 0);
        try self.body.opcode(self.allocator, 0x48); // i32.lt_s
        try self.body.ifVoid(self.allocator);
        // 0 is this if. loop_branch_depth is the fused loop. The next label is the dispatcher.
        try self.body.branch(self.allocator, self.loop_branch_depth + 1);
        try self.body.end(self.allocator);
    }
}

fn emitDemotedLaneBits(self: anytype, register: u32, scratch: u32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.f64Load(self.allocator, 3, register * tvalue_size);
    try self.body.opcode(self.allocator, 0xb6); // f32.demote_f64
    try self.body.opcode(self.allocator, 0xbc); // i32.reinterpret_f32
    try self.body.localSet(self.allocator, scratch);
}

fn emitStoredLane(self: anytype, destination: u32, lane: u32, scratch: u32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, scratch);
    try self.body.opcode(self.allocator, 0xbe); // f32.reinterpret_i32
    try self.body.f32Store(self.allocator, 2, destination * tvalue_size + lane * 4);
}

// Match luauF_vector for two or three register numbers and one result.
// Lane 2 is TValue::extra. Read every lane before storing: the destination may alias a source.
// A miss leaves status negative so the CALL fallback runs.
fn emitInlineVectorCreate(self: anytype, pattern: FastcallPattern) Error!void {
    const three = pattern.parameter_count == 3;
    const starts_at_guard = (try self.instruction(pattern.start)).command == .check_safe_env;
    const saved_id = pattern.start + @intFromBool(starts_at_guard);
    const guarded_before = !starts_at_guard and pattern.start > 0 and
        (try self.instruction(pattern.start - 1)).command == .check_safe_env;
    try self.emitSavedPcLocation(try self.instruction(saved_id));
    try self.body.i32Const(self.allocator, -1);
    try self.body.localSet(self.allocator, self.status_local);

    if (!guarded_before) {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Load(self.allocator, 2, lua_state_ci_offset);
        try self.body.i32Load(self.allocator, 2, callinfo_func_offset);
        try self.body.i32Load(self.allocator, 2, 0);
        try self.body.i32Load(self.allocator, 2, closure_env_offset);
        try self.body.localTee(self.allocator, self.call_aux_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, self.call_aux_local);
        try self.body.i32Load8U(self.allocator, 0, table_safeenv_offset);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.body.else_(self.allocator);
    }

    try self.emitReloadBase();
    try emitSlotBelowTop(self, pattern.source);
    try emitSlotBelowTop(self, pattern.argument_two);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    if (three) {
        try emitSlotBelowTop(self, pattern.argument_three);
        try self.body.opcode(self.allocator, 0x71); // i32.and
    }
    try emitSlotBelowTop(self, pattern.destination);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.ifVoid(self.allocator);
    try emitSlotTagEquals(self, pattern.source, lua_tag_number);
    try emitSlotTagEquals(self, pattern.argument_two, lua_tag_number);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    if (three) {
        try emitSlotTagEquals(self, pattern.argument_three, lua_tag_number);
        try self.body.opcode(self.allocator, 0x71); // i32.and
    }
    try self.body.ifVoid(self.allocator);

    try emitDemotedLaneBits(self, pattern.source, self.call_func_local);
    try emitDemotedLaneBits(self, pattern.argument_two, self.call_closure_local);
    if (three)
        try emitDemotedLaneBits(self, pattern.argument_three, self.call_proto_local)
    else {
        try self.body.i32Const(self.allocator, 0); // +0.0f for the missing lane
        try self.body.localSet(self.allocator, self.call_proto_local);
    }
    try emitStoredLane(self, pattern.destination, 0, self.call_func_local);
    try emitStoredLane(self, pattern.destination, 1, self.call_closure_local);
    try emitStoredLane(self, pattern.destination, 2, self.call_proto_local);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, @intCast(lua_tag_vector));
    try self.body.i32Store(self.allocator, 2, pattern.destination * tvalue_size + tvalue_tag_offset);
    try self.body.i32Const(self.allocator, 1);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.end(self.allocator); // number tags
    try self.body.end(self.allocator); // live slots
    if (!guarded_before) {
        try self.body.end(self.allocator); // safeenv
        try self.body.end(self.allocator); // environment pointer
    }

    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.opcode(self.allocator, 0x48); // i32.lt_s
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, @intCast(pattern.fallback));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.else_(self.allocator);
    if (pattern.finish > pattern.start and
        (try self.instruction(pattern.finish - 1)).command == ir_cmd_adjust_stack_to_top)
        try self.emitAdjustStackToTop();
    try self.body.i32Const(self.allocator, @intCast(pattern.fast_target));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.end(self.allocator);

    if (!self.rejoin_fallthrough) {
        try self.body.branch(self.allocator, self.loop_branch_depth);
    } else {
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.i32Const(self.allocator, 0);
        try self.body.opcode(self.allocator, 0x48); // i32.lt_s
        try self.body.ifVoid(self.allocator);
        try self.body.branch(self.allocator, self.loop_branch_depth + 1);
        try self.body.end(self.allocator);
    }
}

fn numericOperandOk(self: anytype, encoded: u32) Error!bool {
    if (encoded == lbf_operand_none)
        return false;
    if (encoded < 0x8000_0000)
        return encoded < self.proto.max_stack_size;
    const index = encoded & 0x7fff_ffff;
    if (index >= self.proto.vm_constant_count)
        return false;
    const value = try self.snapshot.vmConstant(self.proto, index);
    return value.kind == .number;
}

fn numericFastcallCanInline(self: anytype, pattern: FastcallPattern) Error!bool {
    if (!try numericOperandOk(self, pattern.source))
        return false;
    if (pattern.parameter_count >= 2 and !try numericOperandOk(self, pattern.argument_two))
        return false;
    if (pattern.parameter_count >= 3 and !try numericOperandOk(self, pattern.argument_three))
        return false;
    // pow keeps the running product in the destination and reloads the base.
    if (pattern.builtin_id == 21 and pattern.destination == pattern.source)
        return false;
    return true;
}

fn emitEncodedF64(self: anytype, encoded: u32) Error!void {
    if (encoded >= 0x8000_0000) {
        const value = try self.snapshot.vmConstant(self.proto, encoded & 0x7fff_ffff);
        if (value.kind != .number)
            return Error.InvalidOperandType;
        try self.body.f64Const(self.allocator, @as(f64, @bitCast(value.bits0)));
        return;
    }
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.f64Load(self.allocator, 3, encoded * tvalue_size);
}

fn emitFastcallLiveGate(self: anytype, pattern: FastcallPattern) Error!void {
    // Constants are not stack slots. Destination is always a register.
    try emitSlotBelowTop(self, pattern.destination);
    if (pattern.source < 0x8000_0000) {
        try emitSlotBelowTop(self, pattern.source);
        try self.body.opcode(self.allocator, 0x71); // i32.and
    }
    if (pattern.argument_two < 0x8000_0000) {
        try emitSlotBelowTop(self, pattern.argument_two);
        try self.body.opcode(self.allocator, 0x71);
    }
    if (pattern.argument_three < 0x8000_0000) {
        try emitSlotBelowTop(self, pattern.argument_three);
        try self.body.opcode(self.allocator, 0x71);
    }
}

fn emitFastcallTagGate(self: anytype, pattern: FastcallPattern) Error!void {
    var emitted = false;
    if (pattern.source < 0x8000_0000) {
        try emitSlotTagEquals(self, pattern.source, lua_tag_number);
        emitted = true;
    }
    if (pattern.argument_two < 0x8000_0000) {
        try emitSlotTagEquals(self, pattern.argument_two, lua_tag_number);
        if (emitted)
            try self.body.opcode(self.allocator, 0x71); // i32.and
        emitted = true;
    }
    if (pattern.argument_three < 0x8000_0000) {
        try emitSlotTagEquals(self, pattern.argument_three, lua_tag_number);
        if (emitted)
            try self.body.opcode(self.allocator, 0x71);
        emitted = true;
    }
    if (!emitted)
        try self.body.i32Const(self.allocator, 1);
}

fn emitDestAddress(self: anytype, destination: u32) Error!void {
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, @intCast(destination * tvalue_size));
    try self.body.opcode(self.allocator, 0x6a); // i32.add
}

fn emitFinishNumber(self: anytype, destination: u32) Error!void {
    try self.body.f64Store(self.allocator, 3, 0);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, lua_tag_number);
    try self.body.i32Store(self.allocator, 2, destination * tvalue_size + tvalue_tag_offset);
    try self.body.i32Const(self.allocator, 1);
    try self.body.localSet(self.allocator, self.status_local);
}

fn emitF64InRange(self: anytype, encoded: u32, low: f64, high: f64) Error!void {
    try emitEncodedF64(self, encoded);
    try self.body.f64Const(self.allocator, low);
    try self.body.f64Ge(self.allocator);
    try emitEncodedF64(self, encoded);
    try self.body.f64Const(self.allocator, high);
    try self.body.f64Le(self.allocator);
    try self.body.opcode(self.allocator, 0x71); // i32.and
}

fn emitTruncSatI32(self: anytype, encoded: u32) Error!void {
    try emitEncodedF64(self, encoded);
    try self.body.opcode(self.allocator, 0x9d); // f64.trunc
    try self.body.opcode(self.allocator, 0xfc);
    try self.body.opcode(self.allocator, 0x02); // i32.trunc_sat_f64_s
}

fn emitTruncSatU32(self: anytype, encoded: u32) Error!void {
    try emitEncodedF64(self, encoded);
    try self.body.opcode(self.allocator, 0x9d); // f64.trunc
    try self.body.opcode(self.allocator, 0xfc);
    try self.body.opcode(self.allocator, 0x03); // i32.trunc_sat_f64_u
}

fn emitInlineFloor(self: anytype, pattern: FastcallPattern) Error!void {
    try emitDestAddress(self, pattern.destination);
    try emitEncodedF64(self, pattern.source);
    try self.body.opcode(self.allocator, 0x9c); // f64.floor
    try emitFinishNumber(self, pattern.destination);
}

fn emitInlineLerp(self: anytype, pattern: FastcallPattern) Error!void {
    // (t == 1) ? b : a + (b - a) * t. The address stays under the if.
    try emitDestAddress(self, pattern.destination);
    try emitEncodedF64(self, pattern.argument_three);
    try self.body.f64Const(self.allocator, 1);
    try self.body.f64Eq(self.allocator);
    try self.body.ifF64(self.allocator);
    try emitEncodedF64(self, pattern.argument_two);
    try self.body.else_(self.allocator);
    try emitEncodedF64(self, pattern.source);
    try emitEncodedF64(self, pattern.argument_two);
    try emitEncodedF64(self, pattern.source);
    try self.body.opcode(self.allocator, 0xa1); // f64.sub
    try emitEncodedF64(self, pattern.argument_three);
    try self.body.opcode(self.allocator, 0xa2); // f64.mul
    try self.body.f64Add(self.allocator);
    try self.body.end(self.allocator);
    try emitFinishNumber(self, pattern.destination);
}

fn emitInlineClamp(self: anytype, pattern: FastcallPattern) Error!void {
    // min <= max. NaN makes the compare fail, so the fastcall stores nothing.
    try emitEncodedF64(self, pattern.argument_two);
    try emitEncodedF64(self, pattern.argument_three);
    try self.body.f64Le(self.allocator);
    try self.body.ifVoid(self.allocator);
    // r = v < min ? min : v; then r = r > max ? max : r. NaN v stays NaN.
    try emitDestAddress(self, pattern.destination);
    try emitEncodedF64(self, pattern.source);
    try emitEncodedF64(self, pattern.argument_two);
    try self.body.f64Lt(self.allocator);
    try self.body.ifF64(self.allocator);
    try emitEncodedF64(self, pattern.argument_two);
    try self.body.else_(self.allocator);
    try emitEncodedF64(self, pattern.source);
    try emitEncodedF64(self, pattern.argument_three);
    try self.body.f64Gt(self.allocator);
    try self.body.ifF64(self.allocator);
    try emitEncodedF64(self, pattern.argument_three);
    try self.body.else_(self.allocator);
    try emitEncodedF64(self, pattern.source);
    try self.body.end(self.allocator);
    try self.body.end(self.allocator);
    try emitFinishNumber(self, pattern.destination);
    try self.body.end(self.allocator); // min <= max
}

fn emitInlinePow(self: anytype, pattern: FastcallPattern) Error!void {
    try emitF64InRange(self, pattern.argument_two, 0, 32);
    try emitEncodedF64(self, pattern.argument_two);
    try emitEncodedF64(self, pattern.argument_two);
    try self.body.opcode(self.allocator, 0x9d); // f64.trunc
    try self.body.f64Eq(self.allocator);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.ifVoid(self.allocator);
    try emitTruncSatU32(self, pattern.argument_two);
    try self.body.localSet(self.allocator, self.call_func_local);
    try emitDestAddress(self, pattern.destination);
    try self.body.f64Const(self.allocator, 1);
    try self.body.f64Store(self.allocator, 3, 0);
    try self.body.block(self.allocator);
    try self.body.loop(self.allocator);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.branchIf(self.allocator, 1);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.f64Load(self.allocator, 3, pattern.destination * tvalue_size);
    try emitEncodedF64(self, pattern.source);
    try self.body.opcode(self.allocator, 0xa2); // f64.mul
    try self.body.f64Store(self.allocator, 3, pattern.destination * tvalue_size);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, 0x6b); // i32.sub
    try self.body.localSet(self.allocator, self.call_func_local);
    try self.body.branch(self.allocator, 0);
    try self.body.end(self.allocator); // loop
    try self.body.end(self.allocator); // block
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, lua_tag_number);
    try self.body.i32Store(self.allocator, 2, pattern.destination * tvalue_size + tvalue_tag_offset);
    try self.body.i32Const(self.allocator, 1);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.end(self.allocator); // integer exponent 0..32
}

fn emitEncodedWord(self: anytype, encoded: u32, high: bool) Error!void {
    if (encoded >= 0x8000_0000) {
        const value = try self.snapshot.vmConstant(self.proto, encoded & 0x7fff_ffff);
        if (value.kind != .number)
            return Error.InvalidOperandType;
        const bits: u32 = @truncate(if (high) value.bits0 >> 32 else value.bits0);
        try self.body.i32Const(self.allocator, @as(i32, @bitCast(bits)));
        return;
    }
    try self.body.localGet(self.allocator, self.base_local);
    const field: u32 = if (high) 4 else 0;
    try self.body.i32Load(self.allocator, 2, encoded * tvalue_size + field);
}

fn emitInlineLdexp(self: anytype, pattern: FastcallPattern) Error!void {
    // int(exp) truncates toward 0. Values outside i32 stay on the helper.
    try emitF64InRange(self, pattern.argument_two, -2147483648.0, 2147483647.0);
    try self.body.ifVoid(self.allocator);
    try emitTruncSatI32(self, pattern.argument_two);
    try self.body.localSet(self.allocator, self.call_func_local);
    // exp_bits is at most 2046. Keep the add inside i32 so a wrapped exponent cannot look normal.
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, -2046);
    try self.body.opcode(self.allocator, 0x4e); // i32.ge_s
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.i32Const(self.allocator, 2046);
    try self.body.opcode(self.allocator, 0x4c); // i32.le_s
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.ifVoid(self.allocator);
    try emitEncodedWord(self, pattern.source, true);
    try self.body.localSet(self.allocator, self.call_aux_local);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Const(self.allocator, 20);
    try self.body.opcode(self.allocator, 0x76); // i32.shr_u
    try self.body.i32Const(self.allocator, 0x7ff);
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.localTee(self.allocator, self.call_closure_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.i32Eqz(self.allocator); // exponent field != 0
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Const(self.allocator, 0x7ff);
    try self.body.opcode(self.allocator, 0x47); // i32.ne
    try self.body.opcode(self.allocator, 0x71);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.localGet(self.allocator, self.call_func_local);
    try self.body.opcode(self.allocator, 0x6a); // i32.add
    try self.body.localSet(self.allocator, self.call_proto_local);
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.opcode(self.allocator, 0x4a); // i32.gt_s
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Const(self.allocator, 0x7ff);
    try self.body.opcode(self.allocator, 0x48); // i32.lt_s
    try self.body.opcode(self.allocator, 0x71);
    try self.body.ifVoid(self.allocator);
    try self.body.localGet(self.allocator, self.call_aux_local);
    try self.body.i32Const(self.allocator, @as(i32, @bitCast(@as(u32, 0x800f_ffff))));
    try self.body.opcode(self.allocator, 0x71); // i32.and
    try self.body.localGet(self.allocator, self.call_proto_local);
    try self.body.i32Const(self.allocator, 20);
    try self.body.opcode(self.allocator, 0x74); // i32.shl
    try self.body.opcode(self.allocator, 0x72); // i32.or
    try self.body.localSet(self.allocator, self.call_meta_local);
    try self.body.localGet(self.allocator, self.base_local);
    try emitEncodedWord(self, pattern.source, false);
    try self.body.i32Store(self.allocator, 2, pattern.destination * tvalue_size);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.localGet(self.allocator, self.call_meta_local);
    try self.body.i32Store(self.allocator, 2, pattern.destination * tvalue_size + 4);
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Const(self.allocator, lua_tag_number);
    try self.body.i32Store(self.allocator, 2, pattern.destination * tvalue_size + tvalue_tag_offset);
    try self.body.i32Const(self.allocator, 1);
    try self.body.localSet(self.allocator, self.status_local);
    try self.body.end(self.allocator); // normal result
    try self.body.end(self.allocator); // normal input
    try self.body.end(self.allocator); // exponent delta fits in the normal range
    try self.body.end(self.allocator); // exponent fits in i32
}

fn emitExtractMask(self: anytype) Error!void {
    // ~(0xfffffffe << (w - 1)), with w already in call_closure_local and in 1..32.
    try self.body.i32Const(self.allocator, @as(i32, @bitCast(@as(u32, 0xffff_fffe))));
    try self.body.localGet(self.allocator, self.call_closure_local);
    try self.body.i32Const(self.allocator, 1);
    try self.body.opcode(self.allocator, 0x6b); // i32.sub
    try self.body.opcode(self.allocator, 0x74); // i32.shl
    try self.body.i32Const(self.allocator, -1);
    try self.body.opcode(self.allocator, 0x73); // i32.xor
}

fn emitInlineExtract(self: anytype, pattern: FastcallPattern) Error!void {
    try emitEncodedF64(self, pattern.source);
    try self.body.f64Const(self.allocator, 0);
    try self.body.f64Ge(self.allocator);
    try emitEncodedF64(self, pattern.source);
    try self.body.f64Const(self.allocator, 4294967296.0);
    try self.body.f64Lt(self.allocator);
    try self.body.opcode(self.allocator, 0x71);
    try self.body.ifVoid(self.allocator);
    try emitTruncSatU32(self, pattern.source);
    try self.body.localSet(self.allocator, self.call_func_local);
    try emitF64InRange(self, pattern.argument_two, -2147483648.0, 2147483647.0);
    try self.body.ifVoid(self.allocator);
    try emitTruncSatI32(self, pattern.argument_two);
    try self.body.localSet(self.allocator, self.call_aux_local);
    if (pattern.parameter_count == 2) {
        try self.body.localGet(self.allocator, self.call_aux_local);
        try self.body.i32Const(self.allocator, 32);
        try self.body.opcode(self.allocator, 0x49); // i32.lt_u
        try self.body.ifVoid(self.allocator);
        try emitDestAddress(self, pattern.destination);
        try self.body.localGet(self.allocator, self.call_func_local);
        try self.body.localGet(self.allocator, self.call_aux_local);
        try self.body.opcode(self.allocator, 0x76); // i32.shr_u
        try self.body.i32Const(self.allocator, 1);
        try self.body.opcode(self.allocator, 0x71);
        try self.body.opcode(self.allocator, 0xb8); // f64.convert_i32_u
        try emitFinishNumber(self, pattern.destination);
        try self.body.end(self.allocator);
    } else {
        try emitF64InRange(self, pattern.argument_three, -2147483648.0, 2147483647.0);
        try self.body.ifVoid(self.allocator);
        try emitTruncSatI32(self, pattern.argument_three);
        try self.body.localSet(self.allocator, self.call_closure_local);
        try self.body.localGet(self.allocator, self.call_aux_local);
        try self.body.i32Const(self.allocator, 0);
        try self.body.opcode(self.allocator, 0x4e); // i32.ge_s
        try self.body.localGet(self.allocator, self.call_aux_local);
        try self.body.i32Const(self.allocator, 31);
        try self.body.opcode(self.allocator, 0x4c); // i32.le_s
        try self.body.opcode(self.allocator, 0x71);
        try self.body.localGet(self.allocator, self.call_closure_local);
        try self.body.i32Const(self.allocator, 1);
        try self.body.opcode(self.allocator, 0x4e); // i32.ge_s
        try self.body.opcode(self.allocator, 0x71);
        try self.body.localGet(self.allocator, self.call_closure_local);
        try self.body.i32Const(self.allocator, 32);
        try self.body.opcode(self.allocator, 0x4c); // i32.le_s
        try self.body.opcode(self.allocator, 0x71);
        try self.body.localGet(self.allocator, self.call_aux_local);
        try self.body.localGet(self.allocator, self.call_closure_local);
        try self.body.opcode(self.allocator, 0x6a); // i32.add
        try self.body.i32Const(self.allocator, 32);
        try self.body.opcode(self.allocator, 0x4c); // i32.le_s
        try self.body.opcode(self.allocator, 0x71);
        try self.body.ifVoid(self.allocator);
        try emitDestAddress(self, pattern.destination);
        try self.body.localGet(self.allocator, self.call_func_local);
        try self.body.localGet(self.allocator, self.call_aux_local);
        try self.body.opcode(self.allocator, 0x76); // i32.shr_u
        try emitExtractMask(self);
        try self.body.opcode(self.allocator, 0x71); // i32.and
        try self.body.opcode(self.allocator, 0xb8); // f64.convert_i32_u
        try emitFinishNumber(self, pattern.destination);
        try self.body.end(self.allocator); // field and width
        try self.body.end(self.allocator); // width fits in i32
    }
    try self.body.end(self.allocator); // field fits in i32
    try self.body.end(self.allocator); // value fits in u32
}

fn emitInlineNumericBody(self: anytype, pattern: FastcallPattern) Error!void {
    switch (pattern.builtin_id) {
        12 => try emitInlineFloor(self, pattern),
        15 => try emitInlineLdexp(self, pattern),
        21 => try emitInlinePow(self, pattern),
        34, 59 => try emitInlineExtract(self, pattern),
        46 => try emitInlineClamp(self, pattern),
        89 => try emitInlineLerp(self, pattern),
        else => return Error.UnsupportedCommand,
    }
}

// A fixed assert fastcall publishes min(results, arguments). MULTRET publishes every
// argument and the caller adjusts top from that count. A wider result count needs nil
// padding, and an open argument list has no proved count, so both stay on the helper.
fn assertPublishCount(pattern: FastcallPattern) ?u32 {
    if (pattern.builtin_id != 1 or pattern.parameter_count < 1 or pattern.parameter_count > 255)
        return null;
    const count: u32 = @intCast(pattern.parameter_count);
    if (pattern.result_count == 0)
        return 0;
    if (pattern.result_count == -1)
        return count;
    if (pattern.result_count > 0 and pattern.result_count <= pattern.parameter_count)
        return @intCast(pattern.result_count);
    return null;
}

fn assertArgument(pattern: FastcallPattern, index: u32) ?u32 {
    if (index == 0)
        return pattern.source;
    const contiguous = pattern.parameter_count >= 3 and
        pattern.argument_three == lbf_operand_none and
        pattern.argument_two == pattern.source + 1;
    if (contiguous)
        return std.math.add(u32, pattern.source, index) catch null;
    if (index == 1 and pattern.argument_two != lbf_operand_none)
        return pattern.argument_two;
    if (index == 2 and pattern.argument_three != lbf_operand_none)
        return pattern.argument_three;
    return null;
}

fn assertCopyFits(pattern: FastcallPattern, publish: u32) bool {
    if (publish <= 1)
        return true;
    const end = pattern.destination + publish;
    var index: u32 = 0;
    while (index < publish) : (index += 1) {
        const encoded = assertArgument(pattern, index) orelse return false;
        if (encoded >= 0x8000_0000)
            continue;
        if (encoded >= pattern.destination and encoded < end and index > encoded - pattern.destination)
            return false;
    }
    return true;
}

fn assertSuccessPublish(self: anytype, pattern: FastcallPattern) Error!?u32 {
    const publish = assertPublishCount(pattern) orelse return null;
    if (pattern.source >= 0x8000_0000 or pattern.source >= self.proto.max_stack_size or
        pattern.destination >= self.proto.max_stack_size)
        return null;
    if (publish > 0) {
        const end = std.math.add(u32, pattern.destination, publish) catch return null;
        if (end > self.proto.max_stack_size)
            return null;
    }
    if (!assertCopyFits(pattern, publish))
        return null;
    var index: u32 = 0;
    while (index < publish) : (index += 1) {
        const encoded = assertArgument(pattern, index) orelse return null;
        if (encoded >= 0x8000_0000) {
            const constant_id = encoded & 0x7fff_ffff;
            if (constant_id >= self.proto.vm_constant_count)
                return null;
            switch ((try self.snapshot.vmConstant(self.proto, constant_id)).kind) {
                .nil, .boolean, .number, .integer, .vector, .string => {},
                else => return null,
            }
        } else if (encoded >= self.proto.max_stack_size) {
            return null;
        }
    }
    return publish;
}

fn emitCopyAssertOperand(self: anytype, destination: u32, encoded: u32) Error!void {
    if (encoded < 0x8000_0000) {
        if (encoded != destination)
            try self.emitCopyTValueRegisters(destination, encoded);
        return;
    }
    const operand = snapshot_v1.IrOperand{ .kind = .vm_const, .value = encoded & 0x7fff_ffff };
    const offset = destination * tvalue_size;
    try self.body.localGet(self.allocator, self.base_local);
    try self.emitVmConstantAddress(operand);
    try self.body.i64Load(self.allocator, 3, 0);
    try self.body.i64Store(self.allocator, 3, offset);
    try self.body.localGet(self.allocator, self.base_local);
    try self.emitVmConstantAddress(operand);
    try self.body.i64Load(self.allocator, 3, 8);
    try self.body.i64Store(self.allocator, 3, offset + 8);
}

// luauF_assert only succeeds when the caller discards every result. A truthy value
// still returns its arguments from luaB_assert, so copy those registers here. False
// and nil leave status negative and the existing CALL fallback reports the error.
fn emitInlineAssert(self: anytype, pattern: FastcallPattern, publish: u32) Error!void {
    const starts_at_guard = (try self.instruction(pattern.start)).command == .check_safe_env;
    const saved_id = pattern.start + @intFromBool(starts_at_guard);
    const guarded_before = !starts_at_guard and pattern.start > 0 and
        (try self.instruction(pattern.start - 1)).command == .check_safe_env;
    try self.emitSavedPcLocation(try self.instruction(saved_id));
    try self.body.i32Const(self.allocator, -1);
    try self.body.localSet(self.allocator, self.status_local);

    if (!guarded_before) {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Load(self.allocator, 2, lua_state_ci_offset);
        try self.body.i32Load(self.allocator, 2, callinfo_func_offset);
        try self.body.i32Load(self.allocator, 2, 0);
        try self.body.i32Load(self.allocator, 2, closure_env_offset);
        try self.body.localTee(self.allocator, self.call_aux_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, self.call_aux_local);
        try self.body.i32Load8U(self.allocator, 0, table_safeenv_offset);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.body.else_(self.allocator);
    }

    try self.emitReloadBase();
    try emitFastcallLiveGate(self, pattern);
    var slot: u32 = 1;
    while (slot < publish) : (slot += 1) {
        try emitSlotBelowTop(self, pattern.destination + slot);
        try self.body.opcode(self.allocator, 0x71); // i32.and
    }
    var argument: u32 = 0;
    while (argument < publish) : (argument += 1) {
        const encoded = assertArgument(pattern, argument) orelse return Error.UnsupportedControlFlow;
        if (encoded >= 0x8000_0000 or encoded == pattern.source or
            encoded == pattern.argument_two or encoded == pattern.argument_three)
            continue;
        try emitSlotBelowTop(self, encoded);
        try self.body.opcode(self.allocator, 0x71); // i32.and
    }
    try self.body.ifVoid(self.allocator);
    try self.emitTValueTruthy(.{ .kind = .vm_reg, .value = pattern.source });
    try self.body.ifVoid(self.allocator);
    var index: u32 = 0;
    while (index < publish) : (index += 1) {
        const encoded = assertArgument(pattern, index) orelse return Error.UnsupportedControlFlow;
        try emitCopyAssertOperand(self, pattern.destination + index, encoded);
    }
    try self.body.i32Const(self.allocator, @intCast(publish));
    try self.body.localSet(self.allocator, self.status_local);
    if (pattern.result_count == -1)
        try self.emitAdjustStackDynamic(pattern.destination);
    try self.body.end(self.allocator); // truthy value
    try self.body.end(self.allocator); // live slots
    if (!guarded_before) {
        try self.body.end(self.allocator); // safeenv
        try self.body.end(self.allocator); // environment pointer
    }

    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.opcode(self.allocator, 0x48); // i32.lt_s
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, @intCast(pattern.fallback));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.else_(self.allocator);
    if (pattern.result_count != -1 and pattern.finish > pattern.start and
        (try self.instruction(pattern.finish - 1)).command == ir_cmd_adjust_stack_to_top)
        try self.emitAdjustStackToTop();
    try self.body.i32Const(self.allocator, @intCast(pattern.fast_target));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.end(self.allocator);

    if (!self.rejoin_fallthrough) {
        try self.body.branch(self.allocator, self.loop_branch_depth);
    } else {
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.i32Const(self.allocator, 0);
        try self.body.opcode(self.allocator, 0x48); // i32.lt_s
        try self.body.ifVoid(self.allocator);
        try self.body.branch(self.allocator, self.loop_branch_depth + 1);
        try self.body.end(self.allocator);
    }
}

fn emitInlineNumericFastcall(self: anytype, pattern: FastcallPattern) Error!void {
    const starts_at_guard = (try self.instruction(pattern.start)).command == .check_safe_env;
    const saved_id = pattern.start + @intFromBool(starts_at_guard);
    const guarded_before = !starts_at_guard and pattern.start > 0 and
        (try self.instruction(pattern.start - 1)).command == .check_safe_env;
    try self.emitSavedPcLocation(try self.instruction(saved_id));
    try self.body.i32Const(self.allocator, -1);
    try self.body.localSet(self.allocator, self.status_local);

    if (!guarded_before) {
        try self.body.localGet(self.allocator, 0);
        try self.body.i32Load(self.allocator, 2, lua_state_ci_offset);
        try self.body.i32Load(self.allocator, 2, callinfo_func_offset);
        try self.body.i32Load(self.allocator, 2, 0);
        try self.body.i32Load(self.allocator, 2, closure_env_offset);
        try self.body.localTee(self.allocator, self.call_aux_local);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.body.else_(self.allocator);
        try self.body.localGet(self.allocator, self.call_aux_local);
        try self.body.i32Load8U(self.allocator, 0, table_safeenv_offset);
        try self.body.i32Eqz(self.allocator);
        try self.body.ifVoid(self.allocator);
        try self.body.else_(self.allocator);
    }

    try self.emitReloadBase();
    try emitFastcallLiveGate(self, pattern);
    try self.body.ifVoid(self.allocator);
    try emitFastcallTagGate(self, pattern);
    try self.body.ifVoid(self.allocator);
    try emitInlineNumericBody(self, pattern);
    try self.body.end(self.allocator); // number tags
    try self.body.end(self.allocator); // live slots
    if (!guarded_before) {
        try self.body.end(self.allocator); // safeenv
        try self.body.end(self.allocator); // environment pointer
    }

    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.opcode(self.allocator, 0x48); // i32.lt_s
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, @intCast(pattern.fallback));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.else_(self.allocator);
    if (pattern.finish > pattern.start and
        (try self.instruction(pattern.finish - 1)).command == ir_cmd_adjust_stack_to_top)
        try self.emitAdjustStackToTop();
    try self.body.i32Const(self.allocator, @intCast(pattern.fast_target));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.end(self.allocator);

    if (!self.rejoin_fallthrough) {
        try self.body.branch(self.allocator, self.loop_branch_depth);
    } else {
        try self.body.localGet(self.allocator, self.status_local);
        try self.body.i32Const(self.allocator, 0);
        try self.body.opcode(self.allocator, 0x48); // i32.lt_s
        try self.body.ifVoid(self.allocator);
        try self.body.branch(self.allocator, self.loop_branch_depth + 1);
        try self.body.end(self.allocator);
    }
}

pub noinline fn emitFastcallCluster(self: anytype, pattern: FastcallPattern) Error!void {
    if (pattern.isStringByteRegister())
        return emitInlineStringByte(self, pattern);
    if (pattern.isVectorCreateRegister())
        return emitInlineVectorCreate(self, pattern);
    if (pattern.isInlineNumericFastcall() and try numericFastcallCanInline(self, pattern))
        return emitInlineNumericFastcall(self, pattern);
    if (try assertSuccessPublish(self, pattern)) |publish|
        return emitInlineAssert(self, pattern, publish);
    const saved_id = pattern.start + @intFromBool((try self.instruction(pattern.start)).command == .check_safe_env);
    try self.emitSavedPcLocation(try self.instruction(saved_id));
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(pattern.builtin_id));
    try self.body.i32Const(self.allocator, @intCast(pattern.destination));
    try self.body.i32Const(self.allocator, @intCast(pattern.source));
    try self.body.i32Const(self.allocator, @bitCast(pattern.argument_two));
    try self.body.i32Const(self.allocator, @bitCast(pattern.argument_three));
    try self.body.i32Const(self.allocator, pattern.result_count);
    try self.body.i32Const(self.allocator, pattern.parameter_count);
    try self.body.call(self.allocator, self.fastcall orelse return Error.UnsupportedCommand);
    try self.body.localSet(self.allocator, self.status_local);
    try self.emitReloadBase();
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Const(self.allocator, 0);
    try self.body.opcode(self.allocator, 0x48); // i32.lt_s
    try self.body.ifVoid(self.allocator);
    try self.body.i32Const(self.allocator, @intCast(pattern.fallback));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.else_(self.allocator);
    if (pattern.result_count == -1) {
        try self.emitAdjustStackDynamic(pattern.destination);
    } else if (pattern.finish > pattern.start and
        (try self.instruction(pattern.finish - 1)).command == ir_cmd_adjust_stack_to_top)
    {
        try self.emitAdjustStackToTop();
    }
    try self.body.i32Const(self.allocator, @intCast(pattern.fast_target));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try self.body.end(self.allocator);
    try self.body.branch(self.allocator, self.loop_branch_depth);
}
pub fn isFastcallFallback(self: anytype, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
    if (block.kind != .fallback or block.isEmpty())
        return false;
    var source_id: u32 = 0;
    while (source_id < self.function.block_count) : (source_id += 1) {
        const source = try self.snapshot.irBlock(self.function, source_id);
        if (!source.kind.isCompilable() or source.isEmpty())
            continue;
        var instruction_id = source.start;
        while (instruction_id <= source.finish) : (instruction_id += 1) {
            const fastcall_pattern = if (try self.fastcallPatternAt(instruction_id, source)) |found|
                found
            else
                try self.fixedContiguousFastcallPatternAt(instruction_id, source);
            if (fastcall_pattern) |pattern|
                if (pattern.fallback == block_id)
                    return true;
        }
    }
    return false;
}
pub noinline fn emitFastcallFallbackBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock) Error!void {
    _ = block_id;
    const terminated = try self.emitInstructionRange(block.start, block.finish, block);
    if (!terminated)
        return Error.InvalidBlockTermination;
}
pub noinline fn emitLibm(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    if (instruction_value.operand_count != 2 and instruction_value.operand_count != 3)
        return Error.InvalidOperandCount;
    const bfid = try self.operand(instruction_value, 0);
    if (bfid.kind != .constant)
        return Error.InvalidOperandType;
    const builtin_id = (try self.constant(bfid.value)).uintValue() orelse return Error.InvalidOperandType;
    const binary = switch (builtin_id) {
        5, 13, 15, 21 => true,
        3, 4, 6, 8, 9, 11, 16, 17, 23, 24, 26, 27, 256 => false,
        else => return Error.InvalidOperandType,
    };
    if (binary != (instruction_value.operand_count == 3))
        return Error.InvalidOperandCount;
    try self.body.i32Const(self.allocator, @intCast(builtin_id));
    try self.emitF64Value(try self.operand(instruction_value, 1));
    if (binary) {
        const second = try self.operand(instruction_value, 2);
        if (builtin_id == 15) {
            try self.emitI32Value(second);
            try self.body.opcode(self.allocator, 0xb7); // f64.convert_i32_s
        } else {
            try self.emitF64Value(second);
        }
    } else {
        try self.body.f64Const(self.allocator, 0);
    }
    try self.body.call(self.allocator, self.libm orelse return Error.UnsupportedCommand);
    try self.emitInstructionResultSet(instruction_id);
}
pub noinline fn emitStringLen(self: anytype, instruction_id: u32, instruction_value: snapshot_v1.IrInstruction) Error!void {
    const pattern = (try self.stringLengthPattern(instruction_id)) orelse return Error.UnsupportedControlFlow;
    try self.requireOperandCount(instruction_value, 1);
    const pointer = try self.operand(instruction_value, 0);
    if (pointer.kind != .instruction or
        (try self.instruction(pointer.value)).command != .load_pointer)
        return Error.InvalidOperandType;
    try self.body.localGet(self.allocator, self.base_local);
    try self.body.i32Load(self.allocator, 2, pattern.source * tvalue_size);
    try self.body.i32Load(self.allocator, 2, tstring_len_offset);
    try self.emitInstructionResultSet(instruction_id);
    if (pattern.materialize_tag) {
        try self.body.localGet(self.allocator, self.base_local);
        try self.body.i32Const(self.allocator, lua_tag_number);
        try self.body.i32Store(self.allocator, 2, pattern.destination * tvalue_size + tvalue_tag_offset);
    }
}
pub noinline fn emitTypeName(self: anytype, pattern: TypeNamePattern) Error!void {
    try self.body.localGet(self.allocator, 0);
    try self.body.i32Const(self.allocator, @intCast(pattern.destination));
    try self.body.i32Const(self.allocator, @intCast(pattern.source));
    try self.body.i32Const(self.allocator, @intCast(pattern.custom));
    try self.emitStatusCheckedCall(self.type_name orelse return Error.UnsupportedCommand);
}

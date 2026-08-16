const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");
const diagnostics = @import("luauc_backend_diagnostics");

const Error = model.Error;
const CallContinuation = model.CallContinuation;
const ir_cmd_get_arr_addr = abi.ir_cmd_get_arr_addr;
const ir_cmd_setlist = abi.ir_cmd_setlist;
const ir_cmd_fallback_forgprep = abi.ir_cmd_fallback_forgprep;
const ir_cmd_string_len = abi.ir_cmd_string_len;
const ir_cmd_adjust_stack_to_reg = abi.ir_cmd_adjust_stack_to_reg;
const ir_cmd_fastcall = abi.ir_cmd_fastcall;
const ir_cmd_invoke_libm = abi.ir_cmd_invoke_libm;
const ir_cmd_get_type = abi.ir_cmd_get_type;
const ir_cmd_get_typeof = abi.ir_cmd_get_typeof;
const ir_cmd_check_buffer_len = abi.ir_cmd_check_buffer_len;
const ir_cmd_check_userdata_tag = abi.ir_cmd_check_userdata_tag;
const ir_cmd_barrier_object = abi.ir_cmd_barrier_object;
const ir_cmd_barrier_table_back = abi.ir_cmd_barrier_table_back;
const ir_cmd_get_hash_node_addr = abi.ir_cmd_get_hash_node_addr;
const ir_cmd_get_slot_node_addr = abi.ir_cmd_get_slot_node_addr;
const ir_cmd_jump_slot_match = abi.ir_cmd_jump_slot_match;
const ir_cmd_try_call_fastgettm = abi.ir_cmd_try_call_fastgettm;
const ir_cmd_check_slot_match = abi.ir_cmd_check_slot_match;
const ir_cmd_check_node_no_next = abi.ir_cmd_check_node_no_next;
const ir_cmd_check_node_value = abi.ir_cmd_check_node_value;
const ir_cmd_check_readonly = abi.ir_cmd_check_readonly;
const ir_cmd_get_table = abi.ir_cmd_get_table;
const ir_cmd_set_table = abi.ir_cmd_set_table;
const ir_cmd_fallback_namecall = abi.ir_cmd_fallback_namecall;
const ir_cmd_buffer_readi8 = abi.ir_cmd_buffer_readi8;
const ir_cmd_buffer_readu8 = abi.ir_cmd_buffer_readu8;
const ir_cmd_buffer_writei8 = abi.ir_cmd_buffer_writei8;
const ir_cmd_buffer_readi16 = abi.ir_cmd_buffer_readi16;
const ir_cmd_buffer_readu16 = abi.ir_cmd_buffer_readu16;
const ir_cmd_buffer_writei16 = abi.ir_cmd_buffer_writei16;
const ir_cmd_buffer_readi32 = abi.ir_cmd_buffer_readi32;
const ir_cmd_buffer_writei32 = abi.ir_cmd_buffer_writei32;
const ir_cmd_buffer_readf32 = abi.ir_cmd_buffer_readf32;
const ir_cmd_buffer_writef32 = abi.ir_cmd_buffer_writef32;
const ir_cmd_buffer_readf64 = abi.ir_cmd_buffer_readf64;
const ir_cmd_buffer_writef64 = abi.ir_cmd_buffer_writef64;
const ir_cmd_buffer_readi64 = abi.ir_cmd_buffer_readi64;
const ir_cmd_buffer_writei64 = abi.ir_cmd_buffer_writei64;
const tvalue_extra_offset = abi.tvalue_extra_offset;

pub noinline fn emitInstruction(self: anytype, instruction_id: u32, block_kind: snapshot_v1.IrBlockKind) Error!bool {
    return emitInstructionInner(self, instruction_id, block_kind) catch |err| {
        const failed = self.instruction(instruction_id) catch return err;
        diagnostics.recordInstruction(@errorName(err), instruction_id, @intFromEnum(failed.command));
        return err;
    };
}

fn emitInstructionInner(self: anytype, instruction_id: u32, block_kind: snapshot_v1.IrBlockKind) Error!bool {
    const instruction_value = try self.instruction(instruction_id);
    if (try self.constantTruthyFallbackPatternContaining(instruction_id)) |pattern| {
        if (instruction_id == pattern.finish)
            try self.emitConstantTruthyFallback(pattern);
        return false;
    }
    if (try self.inlineConstantTableGetPatternContaining(instruction_id)) |pattern| {
        if (instruction_id == pattern.finish)
            try self.emitGenericTableFallbackCall(pattern.pattern);
        return false;
    }
    if (try self.inlineArrayGetPatternContaining(instruction_id)) |pattern| {
        if (instruction_id == pattern.finish)
            try self.emitInlineArrayGet(pattern);
        return false;
    }
    if (try self.semanticTableReloadPatternContaining(instruction_id)) |pattern| {
        if (instruction_id == pattern.finish)
            try self.emitSemanticTableReload(pattern);
        return false;
    }
    if (try self.inlineGenericTableSetPatternContaining(instruction_id)) |pattern| {
        if (instruction_id == pattern.finish)
            try self.emitInlineGenericTableSet(pattern.pattern);
        return false;
    }
    if (try self.userdataAllocationPatternContaining(instruction_id)) |pattern| {
        try self.emitUserdataAllocationInstruction(instruction_id, instruction_value, pattern);
        return false;
    }
    if (try self.literalFieldSetPatternContaining(instruction_id)) |pattern| {
        if (instruction_id == pattern.finish)
            try self.emitLiteralFieldSet(pattern);
        return false;
    }
    if (try self.constantLoadPatternContaining(instruction_id)) |pattern| {
        if (instruction_id == pattern.finish)
            try self.emitConstantLoad(pattern);
        return false;
    }
    if (try self.dupTablePatternContaining(instruction_id)) |pattern| {
        if (instruction_id == pattern.finish)
            try self.emitDupTable(pattern);
        return false;
    }
    if (try self.tableInsertAppendPatternContaining(instruction_id)) |pattern| {
        if (instruction_id == pattern.finish)
            try self.emitTableInsertAppend(pattern);
        return false;
    }
    if (try self.concatPatternContaining(instruction_id)) |pattern| {
        if (instruction_id == pattern.finish)
            try self.emitConcat(pattern);
        return false;
    }
    if (try self.tableAllocationPatternContaining(instruction_id)) |pattern| {
        if (instruction_id == pattern.finish)
            try self.emitTableAllocation(pattern);
        return false;
    }
    switch (instruction_value.command) {
        .nop, .substitute, .mark_used, .mark_dead => return false,
        .load_env => {
            if (instruction_id + 1 >= self.function.instruction_count or
                (try self.instruction(instruction_id + 1)).command != .newclosure)
                return Error.UnsupportedControlFlow;
            _ = try self.newClosurePattern(instruction_id + 1);
        },
        .get_closure_upval_addr => {
            if (try self.newClosurePatternContaining(instruction_id) == null)
                return Error.UnsupportedControlFlow;
        },
        .load_tag => try self.emitLoadTag(instruction_id, instruction_value),
        .load_pointer, .load_int => try self.emitLoadI32(instruction_id, instruction_value),
        .load_int64 => try self.emitLoadI64(instruction_id, instruction_value),
        .load_float => try self.emitLoadFloat(instruction_id, instruction_value),
        .load_double => try self.emitLoadDouble(instruction_id, instruction_value),
        .load_tvalue => try self.emitLoadTValue(instruction_id, instruction_value),
        .store_pointer => {
            if (try self.newClosurePatternContaining(instruction_id) == null)
                try self.emitStoreI32(instruction_value, 0);
        },
        .store_tag => try self.emitStoreTag(instruction_id, instruction_value),
        .store_extra => try self.emitStoreI32(instruction_value, tvalue_extra_offset),
        .store_split_tvalue => if (try self.newClosurePatternContaining(instruction_id) == null)
            try self.emitStoreSplitTValue(instruction_value),
        .store_double => try self.emitStoreDouble(instruction_value),
        .store_int => try self.emitStoreI32(instruction_value, 0),
        .store_int64 => try self.emitStoreI64(instruction_value),
        .store_vector => try self.emitStoreVector(instruction_value),
        .store_tvalue => try self.emitStoreTValue(instruction_id, instruction_value),
        .add_int => try self.emitBinaryI32(instruction_id, instruction_value, 0x6a),
        .sub_int => try self.emitBinaryI32(instruction_id, instruction_value, 0x6b),
        .add_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x7c),
        .sub_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x7d),
        .mul_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x7e),
        .div_int64 => try self.emitSignedDivisionI64(instruction_id, instruction_value, false),
        .idiv_int64 => try self.emitSignedDivisionI64(instruction_id, instruction_value, true),
        .udiv_int64 => try self.emitUnsignedDivisionI64(instruction_id, instruction_value, false),
        .rem_int64 => try self.emitSignedRemainderI64(instruction_id, instruction_value, false),
        .urem_int64 => try self.emitUnsignedDivisionI64(instruction_id, instruction_value, true),
        .mod_int64 => try self.emitSignedRemainderI64(instruction_id, instruction_value, true),
        .sexti8_int => try self.emitUnaryI32(instruction_id, instruction_value, 0xc0),
        .sexti16_int => try self.emitUnaryI32(instruction_id, instruction_value, 0xc1),
        .add_num => try self.emitAddNumber(instruction_id, instruction_value),
        .sub_num => try self.emitBinaryF64(instruction_id, instruction_value, 0xa1),
        .mul_num => try self.emitBinaryF64(instruction_id, instruction_value, 0xa2),
        .div_num => try self.emitBinaryF64(instruction_id, instruction_value, 0xa3),
        .idiv_num => try self.emitFloorDivisionNumber(instruction_id, instruction_value),
        .mod_num => try self.emitModNumber(instruction_id, instruction_value),
        .muladd_num => try self.emitMulAddNumber(instruction_id, instruction_value),
        .min_num => try self.emitMinMaxNumber(instruction_id, instruction_value, 0x63),
        .max_num => try self.emitMinMaxNumber(instruction_id, instruction_value, 0x64),
        .unm_num => try self.emitUnaryF64(instruction_id, instruction_value, 0x9a),
        .floor_num => try self.emitUnaryF64(instruction_id, instruction_value, 0x9c),
        .ceil_num => try self.emitUnaryF64(instruction_id, instruction_value, 0x9b),
        .round_num => try self.emitRoundNumber(instruction_id, instruction_value),
        .sqrt_num => try self.emitUnaryF64(instruction_id, instruction_value, 0x9f),
        .abs_num => try self.emitUnaryF64(instruction_id, instruction_value, 0x99),
        .sign_num => try self.emitSignNumber(instruction_id, instruction_value),
        .add_float => try self.emitBinaryF32(instruction_id, instruction_value, 0x92),
        .sub_float => try self.emitBinaryF32(instruction_id, instruction_value, 0x93),
        .mul_float => try self.emitBinaryF32(instruction_id, instruction_value, 0x94),
        .div_float => try self.emitBinaryF32(instruction_id, instruction_value, 0x95),
        .min_float => try self.emitMinMaxFloat(instruction_id, instruction_value, 0x5d),
        .max_float => try self.emitMinMaxFloat(instruction_id, instruction_value, 0x5e),
        .unm_float => try self.emitUnaryF32(instruction_id, instruction_value, 0x8c),
        .floor_float => try self.emitUnaryF32(instruction_id, instruction_value, 0x8e),
        .ceil_float => try self.emitUnaryF32(instruction_id, instruction_value, 0x8d),
        .sqrt_float => try self.emitUnaryF32(instruction_id, instruction_value, 0x91),
        .abs_float => try self.emitUnaryF32(instruction_id, instruction_value, 0x8b),
        .sign_float => try self.emitSignFloat(instruction_id, instruction_value),
        .select_num => try self.emitSelectNumber(instruction_id, instruction_value),
        .select_int64 => try self.emitSelectInt64(instruction_id, instruction_value),
        .select_vec => try self.emitSelectVector(instruction_id, instruction_value),
        .select_if_truthy => try self.emitSelectIfTruthy(instruction_id, instruction_value),
        .add_vec => try self.emitVectorBinary(instruction_id, instruction_value, 0x92),
        .sub_vec => try self.emitVectorBinary(instruction_id, instruction_value, 0x93),
        .mul_vec => try self.emitVectorBinary(instruction_id, instruction_value, 0x94),
        .div_vec => try self.emitVectorBinary(instruction_id, instruction_value, 0x95),
        .idiv_vec => try self.emitFloorDivisionVector(instruction_id, instruction_value),
        .muladd_vec => try self.emitMulAddVector(instruction_id, instruction_value),
        .unm_vec => try self.emitVectorUnary(instruction_id, instruction_value, 0x8c),
        .min_vec => try self.emitMinMaxVector(instruction_id, instruction_value, 0x5d),
        .max_vec => try self.emitMinMaxVector(instruction_id, instruction_value, 0x5e),
        .floor_vec => try self.emitVectorUnary(instruction_id, instruction_value, 0x8e),
        .ceil_vec => try self.emitVectorUnary(instruction_id, instruction_value, 0x8d),
        .abs_vec => try self.emitVectorUnary(instruction_id, instruction_value, 0x8b),
        .dot_vec => try self.emitDotVector(instruction_id, instruction_value),
        .extract_vec => try self.emitExtractVector(instruction_id, instruction_value),
        .float_to_vec => try self.emitFloatToVector(instruction_id, instruction_value),
        .tag_vector => try self.emitTagVector(instruction_id, instruction_value),
        .not_any => try self.emitNotAny(instruction_id, instruction_value),
        .cmp_any => {
            if (block_kind != .fallback)
                return Error.UnsupportedControlFlow;
            try self.emitCompareAny(instruction_id, instruction_value);
        },
        .cmp_int => try self.emitComparisonI32(instruction_id, instruction_value),
        .cmp_int64 => try self.emitComparisonI64(instruction_id, instruction_value),
        .cmp_tag => try self.emitComparisonTag(instruction_id, instruction_value),
        .cmp_split_tvalue => try self.emitSplitTValueComparison(instruction_id, instruction_value),
        .int_to_num => try self.emitUnaryI32(instruction_id, instruction_value, 0xb7), // f64.convert_i32_s
        .int64_to_num => try self.emitUnaryI64(instruction_id, instruction_value, 0xb9), // f64.convert_i64_s
        .uint_to_num => try self.emitUnaryI32(instruction_id, instruction_value, 0xb8), // f64.convert_i32_u
        .uint_to_float => try self.emitUnaryI32(instruction_id, instruction_value, 0xb3), // f32.convert_i32_u
        .float_to_num => try self.emitUnaryF32(instruction_id, instruction_value, 0xbb), // f64.promote_f32
        .num_to_float => try self.emitUnaryF64(instruction_id, instruction_value, 0xb6), // f32.demote_f64
        .num_to_int => try self.emitNumToInt(instruction_id, instruction_value),
        .num_to_int64 => try self.emitNumToInt64(instruction_id, instruction_value),
        .num_to_uint => try self.emitNumToUint(instruction_id, instruction_value),
        .truncate_uint => try self.emitCopyI32(instruction_id, instruction_value),
        .bitand_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x83),
        .bitxor_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x85),
        .bitor_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x84),
        .bitnot_int64 => try self.emitNotI64(instruction_id, instruction_value),
        .bitlshift_int64 => try self.emitSignedI64Shift(instruction_id, instruction_value, 0x86, 0x88, false),
        .bitrshift_int64 => try self.emitSignedI64Shift(instruction_id, instruction_value, 0x88, 0x86, false),
        .bitarshift_int64 => try self.emitSignedI64Shift(instruction_id, instruction_value, 0x87, 0x86, true),
        .bitlrotate_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x89),
        .bitrrotate_int64 => try self.emitBinaryI64(instruction_id, instruction_value, 0x8a),
        .bitcountlz_int64 => try self.emitUnaryI64(instruction_id, instruction_value, 0x79),
        .bitcountrz_int64 => try self.emitUnaryI64(instruction_id, instruction_value, 0x7a),
        .byteswap_int64 => try self.emitByteSwapI64(instruction_id, instruction_value),
        .bitand_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x71),
        .bitxor_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x73),
        .bitor_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x72),
        .bitnot_uint => try self.emitNotI32(instruction_id, instruction_value),
        .bitlshift_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x74),
        .bitrshift_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x76),
        .bitarshift_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x75),
        .bitlrotate_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x77),
        .bitrrotate_uint => try self.emitBinaryI32(instruction_id, instruction_value, 0x78),
        .bitcountlz_uint => try self.emitUnaryI32(instruction_id, instruction_value, 0x67),
        .bitcountrz_uint => try self.emitUnaryI32(instruction_id, instruction_value, 0x68),
        .byteswap_uint => try self.emitByteSwapI32(instruction_id, instruction_value),
        .get_upvalue => try self.emitGetUpvalue(instruction_id, instruction_value),
        .set_upvalue => try self.emitSetUpvalue(instruction_id),
        .check_div_int64 => try self.emitCheckDivInt64(instruction_value),
        .check_tag => try self.emitCheckTag(instruction_value),
        ir_cmd_check_buffer_len => try self.emitBufferLengthCheck(instruction_id, instruction_value),
        ir_cmd_check_userdata_tag => try self.emitCheckUserdataTag(instruction_value),
        .check_truthy => try self.emitCheckTruthy(instruction_value),
        .check_cmp_num => try self.emitCheckCompareNumber(instruction_value),
        .check_cmp_int => try self.emitCheckCompareInteger(instruction_value),
        .check_cmp_int64 => try self.emitCheckCompareInt64(instruction_value),
        .check_gc => {
            if (try self.newClosurePatternContaining(instruction_id) == null) {
                if (!try self.checkGcClosesDeferredTableAllocation(instruction_id))
                    return Error.UnsupportedControlFlow;
                try self.body.localGet(self.allocator, 0);
                try self.body.call(self.allocator, self.check_gc orelse return Error.UnsupportedCommand);
                try self.emitReloadBase();
            }
        },
        ir_cmd_barrier_object => try self.emitBarrierObject(instruction_value),
        ir_cmd_barrier_table_back => try self.emitBarrierTableBack(instruction_value),
        ir_cmd_get_hash_node_addr => try self.emitGetHashNodeAddr(instruction_id, instruction_value),
        ir_cmd_get_slot_node_addr => try self.emitGetSlotNodeAddr(instruction_id, instruction_value),
        ir_cmd_try_call_fastgettm => try self.emitTryCallFastGetTm(instruction_id, instruction_value),
        ir_cmd_check_slot_match => try self.emitCheckSlotMatch(instruction_id, instruction_value),
        ir_cmd_check_node_no_next => try self.emitCheckNodeNoNext(instruction_id, instruction_value),
        ir_cmd_check_node_value => try self.emitCheckNodeValue(instruction_id, instruction_value),
        ir_cmd_check_readonly => try self.emitCheckReadonly(instruction_value),
        ir_cmd_get_table, ir_cmd_set_table => {
            if (instruction_id == 0 or (try self.instruction(instruction_id - 1)).command != .set_savedpc)
                return Error.UnsupportedControlFlow;
            try self.emitDirectGenericTableOperation(instruction_value);
        },
        .set_savedpc => {
            try self.emitSavedPcLocation(instruction_value);
            if (block_kind != .fallback) {
                if (!block_kind.isCompilable())
                    return Error.UnsupportedControlFlow;
                if (instruction_id + 1 < self.function.instruction_count and
                    (try self.tableAllocationPatternAt(instruction_id + 1) != null or
                        try self.dupTablePatternAt(instruction_id + 1) != null))
                {} else if (instruction_id + 2 < self.function.instruction_count and
                    (try self.instruction(instruction_id + 2)).command == .newclosure)
                {
                    _ = try self.newClosurePattern(instruction_id + 2);
                } else if (instruction_id + 1 >= self.function.instruction_count or
                    ((try self.instruction(instruction_id + 1)).command != .call and
                        (try self.instruction(instruction_id + 1)).command != ir_cmd_get_table and
                        (try self.instruction(instruction_id + 1)).command != ir_cmd_set_table))
                    return Error.UnsupportedControlFlow;
            }
        },
        .capture => {
            if (try self.newClosurePatternContaining(instruction_id) == null and
                !try self.isDupClosureCapture(instruction_id))
                return Error.UnsupportedControlFlow;
        },
        .findupval => {
            if (try self.newClosurePatternContaining(instruction_id) == null)
                return Error.UnsupportedControlFlow;
        },
        .close_upvals => try self.emitCloseUpvalues(instruction_id),
        .do_arith => {
            if (block_kind != .fallback)
                return Error.UnsupportedControlFlow;
            try self.emitDoArith(instruction_id, instruction_value);
        },
        .check_safe_env => {
            const guards_dynamic_global = instruction_id + 1 < self.function.instruction_count and
                (try self.instruction(instruction_id + 1)).command == .get_cached_import;
            // Generic cached imports are lowered as real environment lookups, so they do not
            // consume the optimizer's cache or its safe-environment assumption. Pattern-owned
            // fastcall/static-package paths handle their guards before reaching this switch.
            if (!guards_dynamic_global)
                try self.emitSafeEnvCheck(instruction_id);
        },
        ir_cmd_invoke_libm => try self.emitLibm(instruction_id, instruction_value),
        ir_cmd_fastcall => try self.emitDirectFastcall(instruction_value),
        ir_cmd_string_len => try self.emitStringLen(instruction_id, instruction_value),
        .coverage => try self.emitCoverage(instruction_id, instruction_value),
        .interrupt => try self.emitInterrupt(instruction_id, instruction_value),
        .jump => {
            try self.emitJump(instruction_value);
            return true;
        },
        .jump_if_truthy => {
            try self.emitJumpIfTruthy(instruction_value, false);
            return true;
        },
        .jump_if_falsy => {
            try self.emitJumpIfTruthy(instruction_value, true);
            return true;
        },
        .jump_eq_tag => {
            try self.emitJumpEqualTag(instruction_value);
            return true;
        },
        .jump_cmp_int => {
            try self.emitJumpCompareInteger(instruction_value);
            return true;
        },
        .jump_eq_pointer => {
            try self.emitJumpEqualPointer(instruction_value);
            return true;
        },
        .jump_cmp_num => {
            try self.emitJumpCompareNumber(instruction_value);
            return true;
        },
        .jump_cmp_float => {
            try self.emitJumpCompareFloat(instruction_value);
            return true;
        },
        .jump_forn_loop_cond => {
            try self.emitJumpFornLoopCondition(instruction_value);
            return true;
        },
        ir_cmd_jump_slot_match => {
            try self.emitJumpSlotMatch(instruction_id, instruction_value);
            return true;
        },
        .return_ => {
            try self.emitReturn(instruction_value);
            return true;
        },
        .call => try self.emitCall(instruction_id, instruction_value),
        .get_cached_import => try self.emitSingleGlobalImport(instruction_value),
        ir_cmd_setlist => try self.emitSetList(instruction_value),
        ir_cmd_get_arr_addr => {
            if (!try self.trustedArrayAddress(instruction_id))
                return Error.UnsupportedControlFlow;
        },
        ir_cmd_fallback_forgprep => {
            try self.emitGenericIterationPrep(instruction_id, instruction_value);
            return true;
        },
        ir_cmd_fallback_namecall => try self.emitFallbackNamecall(instruction_value),
        .fallback_prepvarargs => try self.emitPrepVarargs(instruction_value),
        .fallback_getvarargs => try self.emitGetVarargs(instruction_value),
        .newclosure => try self.emitNewClosure(instruction_id),
        .fallback_dupclosure => try self.emitDupClosure(instruction_id),
        ir_cmd_buffer_readi8,
        ir_cmd_buffer_readu8,
        ir_cmd_buffer_readi16,
        ir_cmd_buffer_readu16,
        ir_cmd_buffer_readi32,
        ir_cmd_buffer_readf32,
        ir_cmd_buffer_readf64,
        ir_cmd_buffer_readi64,
        => try self.emitBufferRead(instruction_id, instruction_value),
        ir_cmd_buffer_writei8,
        ir_cmd_buffer_writei16,
        ir_cmd_buffer_writei32,
        ir_cmd_buffer_writef32,
        ir_cmd_buffer_writef64,
        ir_cmd_buffer_writei64,
        => try self.emitBufferWrite(instruction_id, instruction_value),
        ir_cmd_adjust_stack_to_reg => try self.emitBufferAdjustStack(instruction_id, instruction_value),
        else => return Error.UnsupportedCommand,
    }
    return false;
}
pub noinline fn emitInstructionRange(self: anytype, start: u32, finish: u32, block: snapshot_v1.IrBlock) Error!bool {
    var progress = start;
    return emitInstructionRangeInner(self, start, finish, block, &progress) catch |err| {
        const failed = self.instruction(progress) catch return err;
        diagnostics.recordInstruction(@errorName(err), progress, @intFromEnum(failed.command));
        return err;
    };
}

fn emitInstructionRangeInner(self: anytype, start: u32, finish: u32, block: snapshot_v1.IrBlock, progress: *u32) Error!bool {
    const dynamic_length = try self.dynamicLengthPattern(block);
    const semantic_array = try self.semanticArrayOperation(block);
    var terminated = false;
    var instruction_id = start;
    while (instruction_id <= finish) : (instruction_id += 1) {
        progress.* = instruction_id;
        if (terminated)
            return Error.InvalidBlockTermination;
        if (try self.integerCreatePatternAt(instruction_id)) |pattern| {
            try self.emitIntegerCreate(pattern);
            instruction_id = pattern.finish;
            continue;
        }
        if (try self.linearizedPowPattern(instruction_id, block)) |pattern| {
            try self.emitSavedPcLocation(pattern.marker);
            try self.emitDoArith(pattern.arithmetic_id, try self.instruction(pattern.arithmetic_id));
            instruction_id = pattern.finish;
            continue;
        }
        if (try self.globalHeadPatternAt(instruction_id, block)) |pattern| {
            try self.emitGlobalOperation(pattern);
            try self.body.branch(self.allocator, 1);
            instruction_id = block.finish;
            terminated = true;
            continue;
        }
        if (try self.fastcallPatternAt(instruction_id, block)) |pattern| {
            try self.emitFastcallCluster(pattern);
            instruction_id = block.finish;
            terminated = true;
            continue;
        }
        const command = (try self.instruction(instruction_id)).command;
        if (command == ir_cmd_get_type or command == ir_cmd_get_typeof) {
            const pattern = (try self.typeNamePattern(instruction_id, command == ir_cmd_get_typeof)) orelse
                return Error.UnsupportedControlFlow;
            try self.emitTypeName(pattern);
            instruction_id = pattern.finish;
            continue;
        }
        if (try self.staticRequireTarget(instruction_id, block)) |require| {
            try self.emitStaticRequire(require.interrupt_id, require.destination, require.module_id);
            instruction_id = require.end;
            continue;
        }
        if (try self.stringTablePattern(block)) |pattern| {
            if (instruction_id == pattern.start) {
                try self.emitStringTableOperation(pattern);
                instruction_id = block.finish;
                terminated = true;
                continue;
            }
        }
        if (try self.inlineStringGetPatternAt(instruction_id, block)) |pattern| {
            try self.emitStringTableHelper(pattern);
            instruction_id += 6;
            continue;
        }
        if (try self.inlineStringSetPatternAt(instruction_id, block)) |operation| {
            try self.emitStringTableHelper(operation.pattern);
            instruction_id = operation.finish;
            continue;
        }
        if (dynamic_length) |pattern| {
            if (instruction_id == pattern.start) {
                try self.emitDynamicLength(pattern);
                try self.body.branch(self.allocator, 1);
                instruction_id = block.finish;
                terminated = true;
                continue;
            }
        }
        if (semantic_array) |operation| {
            if (instruction_id == operation.pattern.start) {
                try self.emitArrayOperation(operation.pattern, operation.kind);
                try self.body.branch(self.allocator, 1);
                instruction_id = block.finish;
                terminated = true;
                continue;
            }
        }
        terminated = try self.emitInstruction(instruction_id, block.kind);
    }
    return terminated;
}
pub noinline fn emitBlock(self: anytype, block_id: u32, block: snapshot_v1.IrBlock) Error!void {
    if (try self.stringEqualityPattern(block)) |pattern|
        return self.emitStringEqualityBlock(block_id, block, pattern);
    if (try self.constantPowPattern(block)) |pattern|
        return self.emitConstantArithmeticBlock(block_id, block, pattern);
    if (try self.constantArithmeticPattern(block)) |pattern|
        return self.emitConstantArithmeticBlock(block_id, block, pattern);
    if (try self.powPattern(block)) |pattern|
        return self.emitPowBlock(block_id, block, pattern);
    if (try self.isFastcallFallback(block_id, block))
        return self.emitFastcallFallbackBlock(block_id, block);
    if (try self.specializedIpairsPattern(block)) |pattern|
        return self.emitGenericIterationBlock(block_id, pattern, true);
    if (try self.genericIterationPattern(block)) |pattern|
        return self.emitGenericIterationBlock(block_id, pattern, true);
    if (try self.genericIterationFallbackPattern(block)) |pattern|
        return self.emitGenericIterationBlock(block_id, pattern, false);
    if (try self.xnextFastPreparationPattern(block)) |pattern|
        return self.emitXnextFastPreparationBlock(block_id, block, pattern);
    if (try self.xnextPreparationPattern(block)) |pattern|
        return self.emitXnextPreparationBlock(block_id, pattern);
    if (try self.globalPattern(block)) |pattern|
        return self.emitGlobalOperationBlock(block_id, block, pattern);
    if (try self.genericTablePattern(block)) |pattern|
        return self.emitGenericTableOperationBlock(block_id, block, pattern);
    if (try self.stringTablePattern(block)) |pattern|
        return self.emitStringTableOperationBlock(block_id, block, pattern);
    if (try self.dynamicLengthPattern(block)) |pattern|
        return self.emitDynamicLengthBlock(block_id, block, pattern);
    if (try self.semanticArrayOperation(block)) |operation|
        return self.emitArrayOperationBlock(block_id, block, operation.pattern, operation.kind);
    if (block.kind == .fallback and !try self.supportsFallback(block))
        return Error.UnsupportedControlFlow;

    try self.body.localGet(self.allocator, self.dispatch_local);
    try self.body.i32Const(self.allocator, @intCast(block_id));
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);

    const terminated = try self.emitInstructionRange(block.start, block.finish, block);
    if (!terminated)
        return Error.InvalidBlockTermination;
    try self.body.end(self.allocator);
}
pub noinline fn emitCallContinuation(self: anytype, continuation: CallContinuation) Error!void {
    try self.body.localGet(self.allocator, self.dispatch_local);
    try self.body.i32Const(self.allocator, @intCast(continuation.dispatch_id));
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    switch (continuation.action) {
        .call_suffix => |suffix| {
            const block = try self.snapshot.irBlock(self.function, suffix.block_id);
            const terminated = try self.emitInstructionRange(suffix.suffix_start, suffix.block_finish, block);
            if (!terminated)
                return Error.InvalidBlockTermination;
        },
        .generic_iteration => |pattern| {
            try self.emitGenericIterationFinish(pattern);
            try self.body.branch(self.allocator, 1);
        },
        .interrupt_block_retry => |retry| {
            try self.body.i32Const(self.allocator, @intCast(retry.block_id));
            try self.body.localSet(self.allocator, self.dispatch_local);
            try self.body.branch(self.allocator, 1);
        },
        .interrupt_suffix => |suffix| {
            const block = try self.snapshot.irBlock(self.function, suffix.block_id);
            try self.emitInterrupt(suffix.interrupt_id, try self.instruction(suffix.interrupt_id));
            const terminated = try self.emitInstructionRange(suffix.suffix_start, suffix.block_finish, block);
            if (!terminated)
                return Error.InvalidBlockTermination;
        },
        .static_require_interrupt => |suffix| {
            const block = try self.snapshot.irBlock(self.function, suffix.block_id);
            try self.emitStaticRequire(
                suffix.require.interrupt_id,
                suffix.require.destination,
                suffix.require.module_id,
            );
            const terminated = try self.emitInstructionRange(suffix.suffix_start, suffix.block_finish, block);
            if (!terminated)
                return Error.InvalidBlockTermination;
        },
    }
    try self.body.end(self.allocator);
}

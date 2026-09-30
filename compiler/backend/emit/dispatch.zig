const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");
const diagnostics = @import("luauc_backend_diagnostics");
const admission = @import("luauc_backend_admission");

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
const ir_cmd_jump_cmp_protoid = abi.ir_cmd_jump_cmp_protoid;
const ir_cmd_try_call_fastgettm = abi.ir_cmd_try_call_fastgettm;
const ir_cmd_check_slot_match = abi.ir_cmd_check_slot_match;
const ir_cmd_check_node_no_next = abi.ir_cmd_check_node_no_next;
const ir_cmd_check_node_value = abi.ir_cmd_check_node_value;
const ir_cmd_check_readonly = abi.ir_cmd_check_readonly;
const ir_cmd_check_no_metatable = abi.ir_cmd_check_no_metatable;
const ir_cmd_check_array_size = abi.ir_cmd_check_array_size;
const ir_cmd_do_len = abi.ir_cmd_do_len;
const ir_cmd_new_userdata = abi.ir_cmd_new_userdata;
const ir_cmd_table_len = abi.ir_cmd_table_len;
const ir_cmd_concat = abi.ir_cmd_concat;
const ir_cmd_get_table = abi.ir_cmd_get_table;
const ir_cmd_set_table = abi.ir_cmd_set_table;
const ir_cmd_try_num_to_index = abi.ir_cmd_try_num_to_index;
const ir_cmd_barrier_table_forward = abi.ir_cmd_barrier_table_forward;
const ir_cmd_fallback_namecall = abi.ir_cmd_fallback_namecall;
const ir_cmd_forgloop = abi.ir_cmd_forgloop;
const ir_cmd_forgloop_fallback = abi.ir_cmd_forgloop_fallback;
const ir_cmd_fallback_gettableks = abi.ir_cmd_fallback_gettableks;
const ir_cmd_fallback_settableks = abi.ir_cmd_fallback_settableks;
const ir_cmd_fallback_getglobal = abi.ir_cmd_fallback_getglobal;
const ir_cmd_fallback_setglobal = abi.ir_cmd_fallback_setglobal;
const ir_cmd_invoke_fastcall = abi.ir_cmd_invoke_fastcall;
const ir_cmd_check_fastcall_res = abi.ir_cmd_check_fastcall_res;
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
    const result = emitInstructionInner(self, instruction_id, block_kind) catch |err| {
        const failed = self.instruction(instruction_id) catch return err;
        diagnostics.recordInstruction(@errorName(err), instruction_id, @intFromEnum(failed.command));
        return err;
    };
    if (self.plan.clusterAt(instruction_id) == null) {
        const instruction_value = self.instruction(instruction_id) catch return result;
        self.plan.noteLowered(instruction_value.command);
    }
    return result;
}

fn emitPlannedCluster(self: anytype, cluster: anytype) Error!void {
    switch (cluster.kind) {
        .constant_truthy => try self.emitConstantTruthyFallback(
            (try self.constantTruthyFallbackPatternAt(cluster.at)) orelse return Error.UnsupportedControlFlow,
        ),
        .inline_const_table_get => try self.emitGenericTableFallbackCall(
            ((try self.inlineConstantTableGetPatternAt(cluster.at)) orelse return Error.UnsupportedControlFlow).pattern,
        ),
        .inline_array_get => try self.emitInlineArrayGet(
            (try self.inlineArrayGetPatternAt(cluster.at)) orelse return Error.UnsupportedControlFlow,
        ),
        .semantic_table_reload => try self.emitSemanticTableReload(
            (try self.semanticTableReloadPatternAt(cluster.at)) orelse return Error.UnsupportedControlFlow,
        ),
        .inline_generic_table_set => try self.emitInlineGenericTableSet(
            ((try self.inlineGenericTableSetPatternAt(cluster.at)) orelse return Error.UnsupportedControlFlow).pattern,
        ),
        .userdata_alloc => {},
        .literal_field_set => try self.emitLiteralFieldSet(
            (try self.literalFieldSetPatternAt(cluster.at)) orelse return Error.UnsupportedControlFlow,
        ),
        .constant_load => try self.emitConstantLoad(
            (try self.constantLoadPatternAt(cluster.at)) orelse return Error.UnsupportedControlFlow,
        ),
        .dup_table => try self.emitDupTable(
            (try self.dupTablePatternAt(cluster.at)) orelse return Error.UnsupportedControlFlow,
        ),
        .table_insert_append => try self.emitTableInsertAppend(
            (try self.tableInsertAppendPatternAt(cluster.at)) orelse return Error.UnsupportedControlFlow,
        ),
        .plain_len => {
            const fact = self.plan.plainLenAt(cluster.at) orelse return Error.UnsupportedControlFlow;
            try self.emitPlainLenCluster(fact);
        },
        .concat => try self.emitConcat(
            (try self.concatPatternAt(cluster.at)) orelse return Error.UnsupportedControlFlow,
        ),
        .table_alloc => try self.emitTableAllocation(
            (try self.tableAllocationPatternAt(cluster.at)) orelse return Error.UnsupportedControlFlow,
        ),
        .integer_create => {
            const pattern = (try self.integerCreatePatternAt(cluster.at)) orelse
                return Error.UnsupportedControlFlow;
            try self.emitIntegerCreate(pattern);
        },
        .linearized_pow => {
            const block = try self.snapshot.irBlock(
                self.function,
                self.plan.instructionBlock(cluster.at) orelse return Error.UnsupportedControlFlow,
            );
            const pattern = (try self.linearizedPowPattern(cluster.at, block)) orelse
                return Error.UnsupportedControlFlow;
            try self.emitSavedPcLocation(pattern.marker);
            try self.emitDoArith(pattern.arithmetic_id, try self.instruction(pattern.arithmetic_id));
        },
        .type_name => {
            const command = (try self.instruction(cluster.at)).command;
            const pattern = (try self.typeNamePattern(cluster.at, command == ir_cmd_get_typeof)) orelse
                return Error.UnsupportedControlFlow;
            try self.emitTypeName(pattern);
        },
    }
}

fn emitInstructionInner(self: anytype, instruction_id: u32, block_kind: snapshot_v1.IrBlockKind) Error!bool {
    const instruction_value = try self.instruction(instruction_id);
    if (self.plan.clusterAt(instruction_id)) |cluster| {
        switch (cluster.kind) {
            .userdata_alloc => {
                const pattern = (try self.userdataAllocationPatternAt(cluster.at)) orelse
                    return Error.UnsupportedControlFlow;
                try self.emitUserdataAllocationInstruction(instruction_id, instruction_value, pattern);
            },
            .integer_create => if (instruction_id == cluster.at)
                try emitPlannedCluster(self, cluster),
            .linearized_pow => if (instruction_id == cluster.at)
                try emitPlannedCluster(self, cluster),
            .type_name => if (instruction_value.command == ir_cmd_get_type or
                instruction_value.command == ir_cmd_get_typeof)
                try emitPlannedCluster(self, cluster),
            else => if (instruction_id == cluster.finish) try emitPlannedCluster(self, cluster),
        }
        self.plan.noteLoweredRange(self.snapshot, self.function, cluster.start, cluster.finish);
        return false;
    }
    switch (instruction_value.command) {
        .nop, .substitute, .mark_used, .mark_dead => return false,
        .load_env => {
            if (self.plan.closureContaining(instruction_id) != null) {
                // Planned newclosure consumes LOAD_ENV.
            } else {
                try self.emitLoadEnv(instruction_id);
            }
        },
        .get_closure_upval_addr => {
            if (self.plan.closureContaining(instruction_id) == null)
                return Error.UnsupportedControlFlow;
        },
        .load_tag => try self.emitLoadTag(instruction_id, instruction_value),
        .load_pointer, .load_int => try self.emitLoadI32(instruction_id, instruction_value),
        .load_int64 => try self.emitLoadI64(instruction_id, instruction_value),
        .load_float => try self.emitLoadFloat(instruction_id, instruction_value),
        .load_double => try self.emitLoadDouble(instruction_id, instruction_value),
        .load_tvalue => try self.emitLoadTValue(instruction_id, instruction_value),
        .store_pointer => {
            if (self.plan.closureContaining(instruction_id) == null)
                try self.emitStoreI32(instruction_value, 0);
        },
        .store_tag => try self.emitStoreTag(instruction_id, instruction_value),
        .store_extra => try self.emitStoreI32(instruction_value, tvalue_extra_offset),
        .store_split_tvalue => if (self.plan.closureContaining(instruction_id) == null)
            try self.emitStoreSplitTValue(instruction_id, instruction_value),
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
            if (block_kind != .fallback) {
                if (instruction_id == 0 or (try self.instruction(instruction_id - 1)).command != .set_savedpc)
                    return Error.UnsupportedControlFlow;
            }
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
            if (self.plan.closureContaining(instruction_id) == null) {
                try self.body.localGet(self.allocator, 0);
                try self.body.call(self.allocator, self.check_gc orelse return Error.UnsupportedCommand);
                try self.emitReloadBase();
            }
        },
        ir_cmd_barrier_object => try self.emitBarrierObject(instruction_value),
        ir_cmd_barrier_table_back => try self.emitBarrierTableBack(instruction_value),
        ir_cmd_barrier_table_forward => try self.emitForwardTableBarrier(instruction_value),
        ir_cmd_get_hash_node_addr => try self.emitGetHashNodeAddr(instruction_id, instruction_value),
        ir_cmd_get_slot_node_addr => try self.emitGetSlotNodeAddr(instruction_id, instruction_value),
        ir_cmd_try_call_fastgettm => try self.emitTryCallFastGetTm(instruction_id, instruction_value),
        ir_cmd_check_slot_match => try self.emitCheckSlotMatch(instruction_id, instruction_value),
        ir_cmd_check_node_no_next => try self.emitCheckNodeNoNext(instruction_id, instruction_value),
        ir_cmd_check_node_value => try self.emitCheckNodeValue(instruction_id, instruction_value),
        ir_cmd_check_readonly => try self.emitCheckReadonly(instruction_value),
        ir_cmd_check_no_metatable, ir_cmd_check_array_size => try self.emitTableLayoutGuard(instruction_id, instruction_value),
        ir_cmd_try_num_to_index => try self.emitTryNumberToIndex(instruction_id, instruction_value),
        ir_cmd_get_table, ir_cmd_set_table => {
            if (instruction_id == 0 or (try self.instruction(instruction_id - 1)).command != .set_savedpc)
                return Error.UnsupportedControlFlow;
            try self.emitGeneralTableOperation(instruction_id, instruction_value);
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
                    (try self.instruction(instruction_id + 1)).command == .check_gc and
                    try self.tableAllocationPatternAt(instruction_id + 2) != null)
                {} else if (instruction_id + 2 < self.function.instruction_count and
                    (try self.instruction(instruction_id + 2)).command == .newclosure)
                {
                    if (self.plan.closureContaining(instruction_id + 2) == null)
                        return Error.UnsupportedControlFlow;
                } else if (instruction_id + 1 >= self.function.instruction_count or
                    ((try self.instruction(instruction_id + 1)).command != .call and
                        (try self.instruction(instruction_id + 1)).command != .cmp_any and
                        (try self.instruction(instruction_id + 1)).command != .do_arith and
                        (try self.instruction(instruction_id + 1)).command != ir_cmd_do_len and
                        (try self.instruction(instruction_id + 1)).command != ir_cmd_concat and
                        (try self.instruction(instruction_id + 1)).command != ir_cmd_get_table and
                        (try self.instruction(instruction_id + 1)).command != ir_cmd_set_table and
                        (try self.instruction(instruction_id + 1)).command != ir_cmd_invoke_fastcall and
                        (try self.instruction(instruction_id + 1)).command != ir_cmd_forgloop_fallback and
                        (try self.instruction(instruction_id + 1)).command != ir_cmd_fallback_gettableks and
                        (try self.instruction(instruction_id + 1)).command != ir_cmd_fallback_settableks and
                        (try self.instruction(instruction_id + 1)).command != ir_cmd_fallback_getglobal and
                        (try self.instruction(instruction_id + 1)).command != ir_cmd_fallback_setglobal))
                    return Error.UnsupportedControlFlow;
            }
        },
        .capture => {
            if (self.plan.closureContaining(instruction_id) == null and
                !self.plan.dupClosureCaptureContaining(instruction_id))
                return Error.UnsupportedControlFlow;
        },
        .findupval => {
            if (self.plan.closureContaining(instruction_id) == null)
                return Error.UnsupportedControlFlow;
        },
        .close_upvals => try self.emitCloseUpvalues(instruction_id),
        .do_arith => {
            if (block_kind != .fallback) {
                if (instruction_id == 0 or (try self.instruction(instruction_id - 1)).command != .set_savedpc)
                    return Error.UnsupportedControlFlow;
            }
            try self.emitDoArith(instruction_id, instruction_value);
        },
        ir_cmd_do_len => {
            if (block_kind != .fallback)
                return Error.UnsupportedControlFlow;
            try self.emitDoLen(instruction_id, instruction_value);
        },
        ir_cmd_concat => try self.emitGeneralConcat(instruction_id, instruction_value),
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
        ir_cmd_invoke_fastcall => try self.emitGeneralInvokeFastcall(instruction_id, instruction_value),
        ir_cmd_check_fastcall_res => return Error.UnsupportedControlFlow,
        ir_cmd_forgloop => {
            try self.emitGeneralForgLoop(instruction_value);
            return true;
        },
        ir_cmd_forgloop_fallback => {
            try self.emitGeneralForgLoopFallback(instruction_id, instruction_value);
            return true;
        },
        ir_cmd_fallback_gettableks => try self.emitGeneralGetTableKs(instruction_value),
        ir_cmd_fallback_settableks => try self.emitGeneralSetTableKs(instruction_value),
        ir_cmd_fallback_getglobal => try self.emitGeneralGetGlobal(instruction_value),
        ir_cmd_fallback_setglobal => try self.emitGeneralSetGlobal(instruction_value),
        ir_cmd_new_userdata => try self.emitNewUserdata(instruction_id, instruction_value),
        ir_cmd_table_len => try self.emitGeneralTableLen(instruction_id, instruction_value),
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
        ir_cmd_jump_cmp_protoid => {
            try self.emitJumpCompareProtoId(instruction_value);
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
            try self.emitGetArrayAddress(instruction_id, instruction_value);
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
    var terminated = false;
    var instruction_id = start;
    while (instruction_id <= finish) : (instruction_id += 1) {
        progress.* = instruction_id;
        if (terminated)
            return Error.InvalidBlockTermination;
        if (self.plan.clusterAt(instruction_id) == null) {
            if (try self.bypassedPlainLenGuard(instruction_id)) |table_len_id| {
                instruction_id = table_len_id - 1;
                continue;
            }
            if (try self.lengthSequenceAt(instruction_id)) |sequence| {
                // A planned cluster already owns this length. Keep that lowering.
                var occupied = false;
                var cursor = sequence.start;
                while (cursor <= sequence.finish) : (cursor += 1) {
                    if (self.plan.clusterAt(cursor) != null) {
                        occupied = true;
                        break;
                    }
                }
                if (!occupied) {
                    try self.emitSavedPcLocation(sequence.marker);
                    try self.emitRegisterLength(sequence.destination, sequence.source);
                    self.plan.noteLoweredRange(self.snapshot, self.function, sequence.start, sequence.finish);
                    instruction_id = sequence.finish;
                    continue;
                }
            }
            if (try self.freshTableLenPattern(instruction_id)) |pattern| {
                try self.emitFreshTableLen(pattern);
                self.plan.noteLoweredRange(self.snapshot, self.function, instruction_id, pattern.finish);
                instruction_id = pattern.finish;
                continue;
            }
            if (try self.linearizedNumericTableSetAt(instruction_id)) |pattern| {
                try self.emitInlineGenericTableSet(pattern.pattern);
                self.plan.noteLoweredRange(self.snapshot, self.function, pattern.pattern.start, pattern.finish);
                instruction_id = pattern.finish;
                continue;
            }
        }
        if (self.plan.clusterAt(instruction_id)) |_| {
            terminated = try self.emitInstruction(instruction_id, block.kind);
            continue;
        }
        if (try self.globalHeadPatternAt(instruction_id, block)) |pattern| {
            try self.emitGlobalOperation(pattern);
            try self.body.branch(self.allocator, self.loop_branch_depth);
            instruction_id = block.finish;
            terminated = true;
            continue;
        }
        const fastcall_pattern = if (try self.fastcallPatternAt(instruction_id, block)) |found|
            found
        else
            try self.fixedContiguousFastcallPatternAt(instruction_id, block);
        if (fastcall_pattern) |pattern| {
            try self.emitFastcallCluster(pattern);
            if (self.rejoin_fallthrough and pattern.isStringByteRegister() and pattern.finish == block.finish) {
                instruction_id = pattern.finish - 1;
                continue;
            }
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
                // Always rejoin. The fused loop suppresses only the block emitter's rejoin.
                try self.emitStringTableHelper(pattern);
                try self.body.i32Const(self.allocator, @intCast(pattern.rejoin));
                try self.body.localSet(self.allocator, self.dispatch_local);
                try self.body.branch(self.allocator, self.loop_branch_depth);
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
        if (try self.guardedLiteralFieldSetPatternAt(instruction_id)) |pattern| {
            try self.emitLiteralFieldSet(pattern);
            instruction_id = pattern.finish;
            continue;
        }
        if (try self.dynamicLengthPattern(block)) |pattern| {
            if (instruction_id == pattern.start) {
                try self.emitDynamicLength(pattern);
                try self.body.branch(self.allocator, self.loop_branch_depth);
                instruction_id = block.finish;
                terminated = true;
                continue;
            }
        }
        if (try self.semanticArrayOperation(block)) |operation| {
            if (instruction_id == operation.pattern.start) {
                try self.emitArrayOperation(operation.pattern, operation.kind);
                try self.body.branch(self.allocator, self.loop_branch_depth);
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
    if (try emitGenericForLoopBlock(self, block_id))
        return;
    if (try emitDirectLoopBlock(self, block_id))
        return;
    switch (self.plan.blockKind(block_id)) {
        .string_equality => {
            const pattern = (try self.stringEqualityPattern(block)) orelse return Error.UnsupportedControlFlow;
            return self.emitStringEqualityBlock(block_id, block, pattern);
        },
        .constant_pow => {
            const pattern = (try self.constantPowPattern(block)) orelse return Error.UnsupportedControlFlow;
            return self.emitConstantArithmeticBlock(block_id, block, pattern);
        },
        .constant_arith => {
            const pattern = (try self.constantArithmeticPattern(block)) orelse return Error.UnsupportedControlFlow;
            return self.emitConstantArithmeticBlock(block_id, block, pattern);
        },
        .pow => {
            const pattern = (try self.powPattern(block)) orelse return Error.UnsupportedControlFlow;
            return self.emitPowBlock(block_id, block, pattern);
        },
        .namecall => {
            const pattern = (try self.plainTableNamecallPattern(block)) orelse return Error.UnsupportedControlFlow;
            return self.emitPlainTableNamecallBlock(block_id, block, pattern);
        },
        .ordinary_call_fallback, .fastcall_fallback => {
            if (self.plan.blockKind(block_id) == .fastcall_fallback)
                return self.emitFastcallFallbackBlock(block_id, block);
            return emitDispatchBlock(self, block);
        },
        .specialized_ipairs => {
            const pattern = (try self.specializedIpairsPattern(block)) orelse return Error.UnsupportedControlFlow;
            return self.emitGenericIterationBlock(block_id, pattern, true);
        },
        .generic_iteration => {
            const pattern = (try self.genericIterationPattern(block)) orelse return Error.UnsupportedControlFlow;
            return self.emitGenericIterationBlock(block_id, pattern, true);
        },
        .generic_iteration_fallback => {
            const pattern = (try self.genericIterationFallbackPattern(block)) orelse return Error.UnsupportedControlFlow;
            return self.emitGenericIterationBlock(block_id, pattern, false);
        },
        .xnext_fast => {
            const pattern = (try self.xnextFastPreparationPattern(block)) orelse return Error.UnsupportedControlFlow;
            return self.emitXnextFastPreparationBlock(block_id, block, pattern);
        },
        .xnext_prep => {
            const pattern = (try self.xnextPreparationPattern(block)) orelse return Error.UnsupportedControlFlow;
            return self.emitXnextPreparationBlock(block_id, pattern);
        },
        .global => {
            const pattern = (try self.globalPattern(block)) orelse return Error.UnsupportedControlFlow;
            return self.emitGlobalOperationBlock(block_id, block, pattern);
        },
        .generic_table => {
            const pattern = (try self.genericTablePattern(block)) orelse return Error.UnsupportedControlFlow;
            return self.emitGenericTableOperationBlock(block_id, block, pattern);
        },
        .string_table => {
            const pattern = (try self.stringTablePattern(block)) orelse return Error.UnsupportedControlFlow;
            return self.emitStringTableOperationBlock(block_id, block, pattern);
        },
        .dynamic_length => {
            const pattern = (try self.dynamicLengthPattern(block)) orelse return Error.UnsupportedControlFlow;
            return self.emitDynamicLengthBlock(block_id, block, pattern);
        },
        .semantic_array => {
            const operation = (try self.semanticArrayOperation(block)) orelse return Error.UnsupportedControlFlow;
            return self.emitArrayOperationBlock(block_id, block, operation.pattern, operation.kind);
        },
        .dispatch, .none => {
            if (block.kind == .fallback and !try admission.supportsFallback(self, block))
                return Error.UnsupportedControlFlow;
            return emitDispatchBlock(self, block);
        },
    }
}
fn emitDispatchBlock(self: anytype, block: snapshot_v1.IrBlock) Error!void {
    const terminated = try self.emitInstructionRange(block.start, block.finish, block);
    if (!terminated)
        return Error.InvalidBlockTermination;
}
pub noinline fn emitCallContinuation(self: anytype, continuation: CallContinuation) Error!void {
    switch (continuation.action) {
        .call_suffix => |suffix| {
            const block = try self.snapshot.irBlock(self.function, suffix.block_id);
            const terminated = try self.emitInstructionRange(suffix.suffix_start, suffix.block_finish, block);
            if (!terminated)
                return Error.InvalidBlockTermination;
        },
        .generic_iteration => |pattern| {
            try self.emitGenericIterationFinish(pattern);
            try self.body.branch(self.allocator, self.loop_branch_depth);
        },
        .interrupt_block_retry => |retry| {
            try self.body.i32Const(self.allocator, @intCast(retry.block_id));
            try self.body.localSet(self.allocator, self.dispatch_local);
            try self.body.branch(self.allocator, self.loop_branch_depth);
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
}

const max_direct_loop_blocks: u8 = 8;

const DirectLoop = struct {
    blocks: [max_direct_loop_blocks]u32 = undefined,
    count: u8 = 0,
    exit_block: u32 = 0,
    continue_on_true: bool = false,
    unconditional: bool = false,

    fn contains(self: DirectLoop, block_id: u32) bool {
        var index: u8 = 0;
        while (index < self.count) : (index += 1) {
            if (self.blocks[index] == block_id)
                return true;
        }
        return false;
    }
};

const LoopStep = struct {
    next: u32,
    open_end: u32,
    specialized: bool,
};

const BackEdge = struct {
    exit_block: u32,
    continue_on_true: bool,
    unconditional: bool,
};

fn loopKindAdmitted(kind: anytype) bool {
    return switch (kind) {
        .dispatch, .generic_table, .string_table, .dynamic_length, .semantic_array, .pow, .constant_pow, .constant_arith, .global, .namecall => true,
        else => false,
    };
}

fn commandLeavesBlock(command: snapshot_v1.IrCommand) bool {
    return switch (command) {
        .jump, .jump_if_truthy, .jump_if_falsy, .jump_eq_tag, .jump_cmp_int, .jump_eq_pointer, .jump_cmp_num, .jump_cmp_float, .jump_forn_loop_cond, .return_ => true,
        else => command == abi.ir_cmd_forgloop or command == abi.ir_cmd_forgloop_fallback or
            command == abi.ir_cmd_fallback_forgprep or command == abi.ir_cmd_jump_slot_match or
            command == abi.ir_cmd_jump_cmp_protoid or command == abi.ir_cmd_invoke_fastcall or
            command == abi.ir_cmd_check_fastcall_res or command == abi.ir_cmd_fastcall,
    };
}

fn loopBlockAdmitted(self: anytype, block_id: u32, block: snapshot_v1.IrBlock) Error!bool {
    if (block.isEmpty() or !block.kind.isCompilable() or block.kind == .fallback)
        return false;
    return !self.plan.isPlannedBypass(block_id);
}

fn blockTarget(self: anytype, instruction_value: snapshot_v1.IrInstruction, index: u32, compiled_only: bool) Error!?u32 {
    if (index >= instruction_value.operand_count)
        return null;
    const operand_value = try self.operand(instruction_value, index);
    if (compiled_only)
        return self.requireCompiledTarget(operand_value) catch return null;
    return self.requireDispatchTarget(operand_value) catch return null;
}

fn backEdgeTo(self: anytype, block_id: u32, block: snapshot_v1.IrBlock, header_id: u32) Error!?BackEdge {
    if (self.plan.blockKind(block_id) != .dispatch)
        return null;
    const term = try self.instruction(block.finish);
    if (term.command == .jump) {
        if (term.operand_count != 1)
            return null;
        const target = (try blockTarget(self, term, 0, false)) orelse return null;
        if (target != header_id)
            return null;
        return .{ .exit_block = target, .continue_on_true = false, .unconditional = true };
    }
    const numeric = switch (term.command) {
        .jump_cmp_num, .jump_cmp_int, .jump_cmp_float, .jump_forn_loop_cond => true,
        else => false,
    };
    if (!numeric or term.operand_count < 5)
        return null;
    const compiled_only = term.command == .jump_forn_loop_cond;
    const true_target = (try blockTarget(self, term, 3, compiled_only)) orelse return null;
    const false_target = (try blockTarget(self, term, 4, compiled_only)) orelse return null;
    if (true_target == header_id and false_target != header_id)
        return .{ .exit_block = false_target, .continue_on_true = true, .unconditional = false };
    if (false_target == header_id and true_target != header_id)
        return .{ .exit_block = true_target, .continue_on_true = false, .unconditional = false };
    return null;
}

fn fallthroughStep(self: anytype, block_id: u32, block: snapshot_v1.IrBlock) Error!?LoopStep {
    switch (self.plan.blockKind(block_id)) {
        .dispatch => {
            const term = try self.instruction(block.finish);
            if (term.command != .jump or term.operand_count != 1)
                return null;
            const next = (try blockTarget(self, term, 0, false)) orelse return null;
            return .{ .next = next, .open_end = block.finish, .specialized = false };
        },
        .generic_table => {
            const pattern = (try self.genericTablePattern(block)) orelse return null;
            if (pattern.start < block.start or pattern.start > block.finish)
                return null;
            return .{ .next = pattern.rejoin, .open_end = pattern.start, .specialized = true };
        },
        .string_table => {
            const pattern = (try self.stringTablePattern(block)) orelse return null;
            if (pattern.start < block.start or pattern.start > block.finish)
                return null;
            return .{ .next = pattern.rejoin, .open_end = pattern.start, .specialized = true };
        },
        .dynamic_length => {
            const pattern = (try self.dynamicLengthPattern(block)) orelse return null;
            if (pattern.start < block.start or pattern.start > block.finish)
                return null;
            return .{ .next = pattern.rejoin, .open_end = pattern.start, .specialized = true };
        },
        .semantic_array => {
            const operation = (try self.semanticArrayOperation(block)) orelse return null;
            if (operation.pattern.start < block.start or operation.pattern.start > block.finish)
                return null;
            return .{ .next = operation.pattern.rejoin, .open_end = operation.pattern.start, .specialized = true };
        },
        .pow => {
            const pattern = (try self.powPattern(block)) orelse return null;
            if (pattern.start < block.start or pattern.start > block.finish)
                return null;
            return .{ .next = pattern.rejoin, .open_end = pattern.start, .specialized = true };
        },
        .constant_pow => {
            const pattern = (try self.constantPowPattern(block)) orelse return null;
            if (pattern.start < block.start or pattern.start > block.finish)
                return null;
            return .{ .next = pattern.rejoin, .open_end = pattern.start, .specialized = true };
        },
        .constant_arith => {
            const pattern = (try self.constantArithmeticPattern(block)) orelse return null;
            if (pattern.start < block.start or pattern.start > block.finish)
                return null;
            return .{ .next = pattern.rejoin, .open_end = pattern.start, .specialized = true };
        },
        .global => {
            const pattern = (try self.globalPattern(block)) orelse return null;
            if (pattern.start < block.start or pattern.start > block.finish)
                return null;
            return .{ .next = pattern.rejoin, .open_end = pattern.start, .specialized = true };
        },
        .namecall => {
            const pattern = (try self.plainTableNamecallPattern(block)) orelse return null;
            if (pattern.start < block.start or pattern.start > block.finish)
                return null;
            return .{ .next = pattern.rejoin, .open_end = pattern.start, .specialized = true };
        },
        else => return null,
    }
}

fn stringByteRegisterInvoke(self: anytype, instruction_id: u32) Error!bool {
    if (instruction_id >= self.function.instruction_count)
        return false;
    const invoke = try self.instruction(instruction_id);
    if (invoke.command != ir_cmd_invoke_fastcall or invoke.operand_count != 7)
        return false;
    const builtin = try self.operand(invoke, 0);
    if (builtin.kind != .constant or (try self.constant(builtin.value)).uintValue() != abi.lbf_string_byte)
        return false;
    const second = try self.operand(invoke, 3);
    const third = try self.operand(invoke, 4);
    if (second.kind != .vm_reg or third.kind != .undef)
        return false;
    return try self.intConstant(try self.operand(invoke, 5)) == 2 and
        try self.intConstant(try self.operand(invoke, 6)) == 1;
}

fn rangeStaysInside(self: anytype, block: snapshot_v1.IrBlock, open_end: u32) Error!bool {
    if (block.isEmpty() or open_end < block.start)
        return false;
    var instruction_id = block.start;
    while (instruction_id < open_end) : (instruction_id += 1) {
        if (instruction_id > block.finish)
            return false;
        const command = (try self.instruction(instruction_id)).command;
        if (command == ir_cmd_invoke_fastcall and try stringByteRegisterInvoke(self, instruction_id)) {
            // The inlined byte falls through on a hit. Its check and stack adjust stay in this block.
            while (instruction_id + 1 < open_end) {
                const next = (try self.instruction(instruction_id + 1)).command;
                if (next != ir_cmd_check_fastcall_res and next != abi.ir_cmd_adjust_stack_to_top)
                    break;
                instruction_id += 1;
            }
            continue;
        }
        if (commandLeavesBlock(command))
            return false;
        if (try self.globalHeadPatternAt(instruction_id, block)) |_|
            return false;
    }
    return true;
}

// A straight IR cycle becomes one wasm loop. The back edge is `br`. Other entries keep dispatch.
fn findDirectLoop(self: anytype, header_id: u32) Error!?DirectLoop {
    if (header_id >= self.function.block_count or !loopKindAdmitted(self.plan.blockKind(header_id)))
        return null;
    const header = try self.snapshot.irBlock(self.function, header_id);
    if (!try loopBlockAdmitted(self, header_id, header))
        return null;

    var loop = DirectLoop{};
    if (try backEdgeTo(self, header_id, header, header_id)) |edge| {
        if (!try rangeStaysInside(self, header, header.finish))
            return null;
        loop.blocks[0] = header_id;
        loop.count = 1;
        loop.exit_block = edge.exit_block;
        loop.continue_on_true = edge.continue_on_true;
        loop.unconditional = edge.unconditional;
        return loop;
    }

    const first = (try fallthroughStep(self, header_id, header)) orelse return null;
    if (!try rangeStaysInside(self, header, first.open_end))
        return null;
    loop.blocks[0] = header_id;
    loop.count = 1;
    if (first.next == header_id) {
        loop.unconditional = true;
        return loop;
    }

    var cursor = first.next;
    while (loop.count < max_direct_loop_blocks) {
        if (cursor >= self.function.block_count or loop.contains(cursor))
            return null;
        const block = try self.snapshot.irBlock(self.function, cursor);
        if (!try loopBlockAdmitted(self, cursor, block) or !loopKindAdmitted(self.plan.blockKind(cursor)))
            return null;
        if (try backEdgeTo(self, cursor, block, header_id)) |edge| {
            if (self.plan.blockKind(cursor) != .dispatch or !try rangeStaysInside(self, block, block.finish))
                return null;
            loop.blocks[loop.count] = cursor;
            loop.count += 1;
            if (!edge.unconditional and loop.contains(edge.exit_block))
                return null;
            loop.exit_block = edge.exit_block;
            loop.continue_on_true = edge.continue_on_true;
            loop.unconditional = edge.unconditional;
            return loop;
        }
        const step = (try fallthroughStep(self, cursor, block)) orelse return null;
        if (!try rangeStaysInside(self, block, step.open_end))
            return null;
        loop.blocks[loop.count] = cursor;
        loop.count += 1;
        if (step.next == header_id) {
            loop.unconditional = true;
            return loop;
        }
        cursor = step.next;
    }
    return null;
}

fn findReturnCycle(self: anytype, header_id: u32, start_id: u32) Error!?DirectLoop {
    if (start_id == header_id or start_id >= self.function.block_count)
        return null;
    var loop = DirectLoop{};
    var cursor = start_id;
    while (loop.count < max_direct_loop_blocks) {
        if (loop.contains(cursor))
            return null;
        const block = try self.snapshot.irBlock(self.function, cursor);
        if (!try loopBlockAdmitted(self, cursor, block) or !loopKindAdmitted(self.plan.blockKind(cursor)))
            return null;
        if (try backEdgeTo(self, cursor, block, header_id)) |edge| {
            if (!edge.unconditional or self.plan.blockKind(cursor) != .dispatch)
                return null;
            if (!try rangeStaysInside(self, block, block.finish))
                return null;
            loop.blocks[loop.count] = cursor;
            loop.count += 1;
            loop.unconditional = true;
            return loop;
        }
        const step = (try fallthroughStep(self, cursor, block)) orelse return null;
        if (!try rangeStaysInside(self, block, step.open_end))
            return null;
        loop.blocks[loop.count] = cursor;
        loop.count += 1;
        if (step.next == header_id) {
            loop.unconditional = true;
            return loop;
        }
        cursor = step.next;
    }
    return null;
}

fn emitGenericForLoopBlock(self: anytype, block_id: u32) Error!bool {
    if (self.plan.blockKind(block_id) != .generic_iteration)
        return false;
    const header = try self.snapshot.irBlock(self.function, block_id);
    const pattern = (try self.genericIterationPattern(header)) orelse return false;
    const fallback = pattern.fallback_target orelse return false;
    if (pattern.repeat_target == block_id or pattern.exit_target == block_id or pattern.repeat_target == pattern.exit_target)
        return false;
    const body = (try findReturnCycle(self, block_id, pattern.repeat_target)) orelse return false;
    if (body.contains(block_id) or body.contains(fallback) or body.contains(pattern.exit_target))
        return false;
    try lowerGenericForLoop(self, block_id, pattern, body);
    return true;
}

fn emitFusedGenericHeader(self: anytype, block_id: u32, pattern: model.GenericIterationPattern) Error!void {
    const fallback_id = pattern.fallback_target orelse return Error.UnsupportedControlFlow;
    const fallback = try self.snapshot.irBlock(self.function, fallback_id);
    const block = try self.snapshot.irBlock(self.function, block_id);
    try self.emitInterrupt(block.start, pattern.marker);
    try self.emitTValueTag(.{ .kind = .vm_reg, .value = pattern.base });
    try self.body.i32Const(self.allocator, abi.lua_tag_nil);
    try self.body.i32Eq(self.allocator);
    try self.body.ifVoid(self.allocator);
    try self.emitGenericIterationCall(pattern);
    try self.body.else_(self.allocator);
    // The fallback block stays available for a resumed entry. This arm is the taken path.
    try self.emitGenericIterationFallbackCall(fallback.finish, pattern, true);
    try self.body.end(self.allocator);
}

fn lowerGenericForLoop(self: anytype, block_id: u32, pattern: model.GenericIterationPattern, body: DirectLoop) Error!void {
    // One wasm loop for a straight generic-for body. Repeat falls through.
    // Stop, and every resumable exit, still leave through the outer dispatcher.
    try self.body.loop(self.allocator);
    const saved_depth = self.loop_branch_depth;
    self.loop_branch_depth = saved_depth + 1;
    defer self.loop_branch_depth = saved_depth;

    try emitFusedGenericHeader(self, block_id, pattern);
    try self.body.localGet(self.allocator, self.status_local);
    try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    // 0 is this if. saved_depth + 1 is the inner loop. The next label is the outer dispatcher.
    try self.body.branch(self.allocator, self.loop_branch_depth + 1);
    try self.body.end(self.allocator);

    var index: u8 = 0;
    while (index + 1 < body.count) : (index += 1)
        try emitLoopPredecessor(self, body.blocks[index]);
    const last_id = body.blocks[body.count - 1];
    const last = try self.snapshot.irBlock(self.function, last_id);
    if (self.plan.blockKind(last_id) == .dispatch)
        try emitDispatchOpen(self, last)
    else
        try emitSpecializedFallthrough(self, last_id, last);
    try self.body.branch(self.allocator, 0);
    try self.body.end(self.allocator);
}

fn emitDirectLoopBlock(self: anytype, block_id: u32) Error!bool {
    const loop = (try findDirectLoop(self, block_id)) orelse return false;
    try lowerDirectLoop(self, loop);
    return true;
}

fn emitDispatchOpen(self: anytype, block: snapshot_v1.IrBlock) Error!void {
    if (block.finish == block.start)
        return;
    if (block.finish < block.start)
        return Error.UnsupportedControlFlow;
    // Successors of this block are inlined after it. A miss still leaves through the dispatcher.
    self.rejoin_fallthrough = true;
    defer self.rejoin_fallthrough = false;
    const terminated = try self.emitInstructionRange(block.start, block.finish - 1, block);
    if (terminated)
        return Error.UnsupportedControlFlow;
}

fn emitSpecializedFallthrough(self: anytype, block_id: u32, block: snapshot_v1.IrBlock) Error!void {
    self.rejoin_fallthrough = true;
    defer self.rejoin_fallthrough = false;
    switch (self.plan.blockKind(block_id)) {
        .generic_table => {
            const pattern = (try self.genericTablePattern(block)) orelse return Error.UnsupportedControlFlow;
            try self.emitGenericTableOperationBlock(block_id, block, pattern);
        },
        .string_table => {
            const pattern = (try self.stringTablePattern(block)) orelse return Error.UnsupportedControlFlow;
            try self.emitStringTableOperationBlock(block_id, block, pattern);
        },
        .dynamic_length => {
            const pattern = (try self.dynamicLengthPattern(block)) orelse return Error.UnsupportedControlFlow;
            try self.emitDynamicLengthBlock(block_id, block, pattern);
        },
        .semantic_array => {
            const operation = (try self.semanticArrayOperation(block)) orelse return Error.UnsupportedControlFlow;
            try self.emitArrayOperationBlock(block_id, block, operation.pattern, operation.kind);
        },
        .pow => {
            const pattern = (try self.powPattern(block)) orelse return Error.UnsupportedControlFlow;
            try self.emitPowBlock(block_id, block, pattern);
        },
        .constant_pow => {
            const pattern = (try self.constantPowPattern(block)) orelse return Error.UnsupportedControlFlow;
            try self.emitConstantArithmeticBlock(block_id, block, pattern);
        },
        .constant_arith => {
            const pattern = (try self.constantArithmeticPattern(block)) orelse return Error.UnsupportedControlFlow;
            try self.emitConstantArithmeticBlock(block_id, block, pattern);
        },
        .global => {
            const pattern = (try self.globalPattern(block)) orelse return Error.UnsupportedControlFlow;
            try self.emitGlobalOperationBlock(block_id, block, pattern);
        },
        .namecall => {
            const pattern = (try self.plainTableNamecallPattern(block)) orelse return Error.UnsupportedControlFlow;
            try self.emitPlainTableNamecallBlock(block_id, block, pattern);
        },
        else => return Error.UnsupportedControlFlow,
    }
}

fn emitDirectLoopCondition(self: anytype, instruction_value: snapshot_v1.IrInstruction) Error!void {
    switch (instruction_value.command) {
        .jump_cmp_num => {
            try self.requireOperandCount(instruction_value, 5);
            try self.emitF64Value(try self.operand(instruction_value, 0));
            try self.emitF64Value(try self.operand(instruction_value, 1));
            try self.emitNumericCondition(try self.conditionOperand(instruction_value, 2));
        },
        .jump_cmp_int => {
            try self.requireOperandCount(instruction_value, 5);
            try self.emitI32Value(try self.operand(instruction_value, 0));
            try self.emitI32Value(try self.operand(instruction_value, 1));
            try self.emitIntegerCondition(try self.conditionOperand(instruction_value, 2));
        },
        .jump_cmp_float => {
            try self.requireOperandCount(instruction_value, 5);
            try self.emitF32Value(try self.operand(instruction_value, 0));
            try self.emitF32Value(try self.operand(instruction_value, 1));
            try self.emitFloatCondition(try self.conditionOperand(instruction_value, 2));
        },
        .jump_forn_loop_cond => {
            // step > 0 selects index <= limit. Otherwise limit <= index. NaN exits on the false arm.
            try self.requireOperandCount(instruction_value, 5);
            try self.emitF64Value(try self.operand(instruction_value, 0));
            try self.emitF64Value(try self.operand(instruction_value, 1));
            try self.body.f64Le(self.allocator);
            try self.emitF64Value(try self.operand(instruction_value, 1));
            try self.emitF64Value(try self.operand(instruction_value, 0));
            try self.body.f64Le(self.allocator);
            try self.emitF64Value(try self.operand(instruction_value, 2));
            try self.body.f64Const(self.allocator, 0.0);
            try self.body.f64Gt(self.allocator);
            try self.body.select(self.allocator);
        },
        else => return Error.UnsupportedControlFlow,
    }
}

fn emitDirectBackEdge(self: anytype, block: snapshot_v1.IrBlock, exit_block: u32, continue_on_true: bool) Error!void {
    try self.body.i32Const(self.allocator, @intCast(exit_block));
    try self.body.localSet(self.allocator, self.dispatch_local);
    try emitDirectLoopCondition(self, try self.instruction(block.finish));
    if (!continue_on_true)
        try self.body.i32Eqz(self.allocator);
    try self.body.ifVoid(self.allocator);
    // 0 is this if. 1 is the fused wasm loop.
    try self.body.branch(self.allocator, 1);
    try self.body.end(self.allocator);
    try self.body.branch(self.allocator, self.loop_branch_depth);
}

fn emitLoopPredecessor(self: anytype, block_id: u32) Error!void {
    const block = try self.snapshot.irBlock(self.function, block_id);
    if (self.plan.blockKind(block_id) == .dispatch)
        try emitDispatchOpen(self, block)
    else
        try emitSpecializedFallthrough(self, block_id, block);
}

fn lowerDirectLoop(self: anytype, loop: DirectLoop) Error!void {
    try self.body.loop(self.allocator);
    const saved_depth = self.loop_branch_depth;
    self.loop_branch_depth = saved_depth + 1;
    defer self.loop_branch_depth = saved_depth;

    var index: u8 = 0;
    while (index + 1 < loop.count) : (index += 1)
        try emitLoopPredecessor(self, loop.blocks[index]);

    const last_id = loop.blocks[loop.count - 1];
    const last = try self.snapshot.irBlock(self.function, last_id);
    if (self.plan.blockKind(last_id) == .dispatch) {
        try emitDispatchOpen(self, last);
        if (loop.unconditional)
            try self.body.branch(self.allocator, 0)
        else
            try emitDirectBackEdge(self, last, loop.exit_block, loop.continue_on_true);
    } else {
        if (!loop.unconditional)
            return Error.UnsupportedControlFlow;
        try emitSpecializedFallthrough(self, last_id, last);
        try self.body.branch(self.allocator, 0);
    }
    try self.body.end(self.allocator);
}

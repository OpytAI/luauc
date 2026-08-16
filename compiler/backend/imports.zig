const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");
const wasm = @import("luauc_wasm_object");
const model = @import("luauc_backend_model");
const abi = @import("luauc_backend_runtime_abi");

const Error = model.Error;
const dupClosurePattern = model.dupClosurePattern;
const return_symbol = abi.return_symbol;
const interrupt_symbol = abi.interrupt_symbol;
const coverage_hit_symbol = abi.coverage_hit_symbol;
const do_arith_symbol = abi.do_arith_symbol;
const compare_any_symbol = abi.compare_any_symbol;
const dupclosure_symbol = abi.dupclosure_symbol;
const newclosure_capture_symbol = abi.newclosure_capture_symbol;
const get_upvalue_symbol = abi.get_upvalue_symbol;
const set_upvalue_symbol = abi.set_upvalue_symbol;
const close_upvalues_symbol = abi.close_upvalues_symbol;
const call_symbol = abi.call_symbol;
const exchange_continuation_symbol = abi.exchange_continuation_symbol;
const set_location_symbol = abi.set_location_symbol;
const new_table_symbol = abi.new_table_symbol;
const new_table_deferred_symbol = abi.new_table_deferred_symbol;
const check_gc_symbol = abi.check_gc_symbol;
const load_constant_symbol = abi.load_constant_symbol;
const dup_table_symbol = abi.dup_table_symbol;
const table_insert_append_symbol = abi.table_insert_append_symbol;
const namecall_plain_symbol = abi.namecall_plain_symbol;
const set_list_symbol = abi.set_list_symbol;
const array_set_symbol = abi.array_set_symbol;
const array_get_symbol = abi.array_get_symbol;
const table_len_symbol = abi.table_len_symbol;
const concat_symbol = abi.concat_symbol;
const do_len_symbol = abi.do_len_symbol;
const forg_prep_symbol = abi.forg_prep_symbol;
const forg_loop_symbol = abi.forg_loop_symbol;
const forg_loop_call_symbol = abi.forg_loop_call_symbol;
const forg_loop_finish_symbol = abi.forg_loop_finish_symbol;
const forgprep_xnext_fallback_symbol = abi.forgprep_xnext_fallback_symbol;
const new_userdata_symbol = abi.new_userdata_symbol;
const check_userdata_tag_symbol = abi.check_userdata_tag_symbol;
const barrier_object_symbol = abi.barrier_object_symbol;
const barrier_table_back_symbol = abi.barrier_table_back_symbol;
const barrier_table_forward_symbol = abi.barrier_table_forward_symbol;
const hash_node_addr_symbol = abi.hash_node_addr_symbol;
const slot_node_addr_symbol = abi.slot_node_addr_symbol;
const node_slot_match_symbol = abi.node_slot_match_symbol;
const try_get_tm_symbol = abi.try_get_tm_symbol;
const check_node_no_next_symbol = abi.check_node_no_next_symbol;
const check_node_value_symbol = abi.check_node_value_symbol;
const closure_matches_proto_id_symbol = abi.closure_matches_proto_id_symbol;
const check_readonly_symbol = abi.check_readonly_symbol;
const table_set_string_symbol = abi.table_set_string_symbol;
const table_get_string_symbol = abi.table_get_string_symbol;
const table_set_symbol = abi.table_set_symbol;
const table_get_symbol = abi.table_get_symbol;
const table_set_number_symbol = abi.table_set_number_symbol;
const table_get_number_symbol = abi.table_get_number_symbol;
const table_array_set_symbol = abi.table_array_set_symbol;
const table_array_get_symbol = abi.table_array_get_symbol;
const get_global_symbol = abi.get_global_symbol;
const set_global_symbol = abi.set_global_symbol;
const fastcall_symbol = abi.fastcall_symbol;
const type_name_symbol = abi.type_name_symbol;
const libm_symbol = abi.libm_symbol;
const builtin_type_error_symbol = abi.builtin_type_error_symbol;
const builtin_number_symbol = abi.builtin_number_symbol;
const buffer_bounds_error_symbol = abi.buffer_bounds_error_symbol;
const check_safe_env_symbol = abi.check_safe_env_symbol;
const prep_varargs_symbol = abi.prep_varargs_symbol;
const get_varargs_fixed_symbol = abi.get_varargs_fixed_symbol;
const get_varargs_multret_symbol = abi.get_varargs_multret_symbol;
const require_static_symbol = abi.require_static_symbol;
const ir_cmd_table_len = abi.ir_cmd_table_len;
const ir_cmd_get_arr_addr = abi.ir_cmd_get_arr_addr;
const ir_cmd_new_table = abi.ir_cmd_new_table;
const ir_cmd_new_userdata = abi.ir_cmd_new_userdata;
const ir_cmd_dup_table = abi.ir_cmd_dup_table;
const ir_cmd_table_setnum = abi.ir_cmd_table_setnum;
const ir_cmd_do_len = abi.ir_cmd_do_len;
const ir_cmd_concat = abi.ir_cmd_concat;
const ir_cmd_get_table = abi.ir_cmd_get_table;
const ir_cmd_set_table = abi.ir_cmd_set_table;
const ir_cmd_setlist = abi.ir_cmd_setlist;
const ir_cmd_fallback_gettableks = abi.ir_cmd_fallback_gettableks;
const ir_cmd_fallback_settableks = abi.ir_cmd_fallback_settableks;
const ir_cmd_fallback_getglobal = abi.ir_cmd_fallback_getglobal;
const ir_cmd_fallback_setglobal = abi.ir_cmd_fallback_setglobal;
const ir_cmd_fallback_namecall = abi.ir_cmd_fallback_namecall;
const ir_cmd_forgloop = abi.ir_cmd_forgloop;
const ir_cmd_forgloop_fallback = abi.ir_cmd_forgloop_fallback;
const ir_cmd_forgprep_xnext_fallback = abi.ir_cmd_forgprep_xnext_fallback;
const ir_cmd_fallback_forgprep = abi.ir_cmd_fallback_forgprep;
const ir_cmd_fastcall = abi.ir_cmd_fastcall;
const ir_cmd_invoke_fastcall = abi.ir_cmd_invoke_fastcall;
const ir_cmd_invoke_libm = abi.ir_cmd_invoke_libm;
const ir_cmd_get_type = abi.ir_cmd_get_type;
const ir_cmd_get_typeof = abi.ir_cmd_get_typeof;
const ir_cmd_check_buffer_len = abi.ir_cmd_check_buffer_len;
const ir_cmd_check_userdata_tag = abi.ir_cmd_check_userdata_tag;
const ir_cmd_barrier_object = abi.ir_cmd_barrier_object;
const ir_cmd_barrier_table_back = abi.ir_cmd_barrier_table_back;
const ir_cmd_barrier_table_forward = abi.ir_cmd_barrier_table_forward;
const ir_cmd_get_hash_node_addr = abi.ir_cmd_get_hash_node_addr;
const ir_cmd_get_slot_node_addr = abi.ir_cmd_get_slot_node_addr;
const ir_cmd_jump_slot_match = abi.ir_cmd_jump_slot_match;
const ir_cmd_jump_cmp_protoid = abi.ir_cmd_jump_cmp_protoid;
const ir_cmd_try_call_fastgettm = abi.ir_cmd_try_call_fastgettm;
const ir_cmd_check_slot_match = abi.ir_cmd_check_slot_match;
const ir_cmd_check_node_no_next = abi.ir_cmd_check_node_no_next;
const ir_cmd_check_node_value = abi.ir_cmd_check_node_value;
const ir_cmd_check_readonly = abi.ir_cmd_check_readonly;
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

pub const ImportNeeds = struct {
    coverage_hit: bool = false,
    do_arith: bool = false,
    compare_any: bool = false,
    dupclosure: bool = false,
    newclosure_capture: bool = false,
    get_upvalue: bool = false,
    set_upvalue: bool = false,
    close_upvalues: bool = false,
    call: bool = false,
    exchange_continuation: bool = false,
    set_location: bool = false,
    new_table: bool = false,
    new_table_deferred: bool = false,
    check_gc: bool = false,
    new_userdata: bool = false,
    check_userdata_tag: bool = false,
    barrier_object: bool = false,
    barrier_table_back: bool = false,
    barrier_table_forward: bool = false,
    hash_node_addr: bool = false,
    slot_node_addr: bool = false,
    node_slot_match: bool = false,
    try_get_tm: bool = false,
    check_node_no_next: bool = false,
    check_node_value: bool = false,
    closure_matches_proto_id: bool = false,
    check_readonly: bool = false,
    load_constant: bool = false,
    dup_table: bool = false,
    table_insert_append: bool = false,
    namecall_plain: bool = false,
    set_list: bool = false,
    array_set: bool = false,
    array_get: bool = false,
    table_len: bool = false,
    concat: bool = false,
    do_len: bool = false,
    forg_prep: bool = false,
    forg_loop: bool = false,
    forg_loop_call: bool = false,
    forg_loop_finish: bool = false,
    forgprep_xnext_fallback: bool = false,
    table_set_string: bool = false,
    table_get_string: bool = false,
    table_set: bool = false,
    table_get: bool = false,
    table_set_number: bool = false,
    table_get_number: bool = false,
    table_array_set: bool = false,
    table_array_get: bool = false,
    get_global: bool = false,
    set_global: bool = false,
    check_safe_env: bool = false,
    fastcall: bool = false,
    type_name: bool = false,
    builtin_type_error: bool = false,
    builtin_number: bool = false,
    buffer_bounds_error: bool = false,
    libm: bool = false,
    prep_varargs: bool = false,
    get_varargs_fixed: bool = false,
    get_varargs_multret: bool = false,
    require_static: bool = false,
};

pub const RuntimeImports = struct {
    return_: wasm.FunctionRef,
    interrupt: wasm.FunctionRef,
    coverage_hit: ?wasm.FunctionRef,
    do_arith: ?wasm.FunctionRef,
    compare_any: ?wasm.FunctionRef,
    dupclosure: ?wasm.FunctionRef,
    newclosure_capture: ?wasm.FunctionRef,
    get_upvalue: ?wasm.FunctionRef,
    set_upvalue: ?wasm.FunctionRef,
    close_upvalues: ?wasm.FunctionRef,
    call: ?wasm.FunctionRef,
    exchange_continuation: ?wasm.FunctionRef,
    set_location: ?wasm.FunctionRef,
    new_table: ?wasm.FunctionRef,
    new_table_deferred: ?wasm.FunctionRef,
    check_gc: ?wasm.FunctionRef,
    new_userdata: ?wasm.FunctionRef,
    check_userdata_tag: ?wasm.FunctionRef,
    barrier_object: ?wasm.FunctionRef,
    barrier_table_back: ?wasm.FunctionRef,
    barrier_table_forward: ?wasm.FunctionRef,
    hash_node_addr: ?wasm.FunctionRef,
    slot_node_addr: ?wasm.FunctionRef,
    node_slot_match: ?wasm.FunctionRef,
    try_get_tm: ?wasm.FunctionRef,
    check_node_no_next: ?wasm.FunctionRef,
    check_node_value: ?wasm.FunctionRef,
    closure_matches_proto_id: ?wasm.FunctionRef,
    check_readonly: ?wasm.FunctionRef,
    load_constant: ?wasm.FunctionRef,
    dup_table: ?wasm.FunctionRef,
    table_insert_append: ?wasm.FunctionRef,
    namecall_plain: ?wasm.FunctionRef,
    set_list: ?wasm.FunctionRef,
    array_set: ?wasm.FunctionRef,
    array_get: ?wasm.FunctionRef,
    table_len: ?wasm.FunctionRef,
    concat: ?wasm.FunctionRef,
    do_len: ?wasm.FunctionRef,
    forg_prep: ?wasm.FunctionRef,
    forg_loop: ?wasm.FunctionRef,
    forg_loop_call: ?wasm.FunctionRef,
    forg_loop_finish: ?wasm.FunctionRef,
    forgprep_xnext_fallback: ?wasm.FunctionRef,
    table_set_string: ?wasm.FunctionRef,
    table_get_string: ?wasm.FunctionRef,
    table_set: ?wasm.FunctionRef,
    table_get: ?wasm.FunctionRef,
    table_set_number: ?wasm.FunctionRef,
    table_get_number: ?wasm.FunctionRef,
    table_array_set: ?wasm.FunctionRef,
    table_array_get: ?wasm.FunctionRef,
    get_global: ?wasm.FunctionRef,
    set_global: ?wasm.FunctionRef,
    check_safe_env: ?wasm.FunctionRef,
    fastcall: ?wasm.FunctionRef,
    type_name: ?wasm.FunctionRef,
    libm: ?wasm.FunctionRef,
    builtin_type_error: ?wasm.FunctionRef,
    builtin_number: ?wasm.FunctionRef,
    buffer_bounds_error: ?wasm.FunctionRef,
    prep_varargs: ?wasm.FunctionRef,
    get_varargs_fixed: ?wasm.FunctionRef,
    get_varargs_multret: ?wasm.FunctionRef,
    require_static: ?wasm.FunctionRef,
    generated_type: u32,
};

pub fn isRequireImportInstruction(
    snapshot: snapshot_v1.Snapshot,
    function: snapshot_v1.IrFunction,
    proto: snapshot_v1.Proto,
    instruction_value: snapshot_v1.IrInstruction,
) Error!bool {
    if (instruction_value.command != .get_cached_import or instruction_value.operand_count != 4)
        return false;
    const import_operand = try snapshot.irOperand(instruction_value, 1);
    const descriptor_operand = try snapshot.irOperand(instruction_value, 2);
    if (import_operand.kind != .vm_const or descriptor_operand.kind != .constant)
        return false;
    const import = try snapshot.vmConstant(proto, import_operand.value);
    if (import.kind != .import or import.payload1 != 1)
        return false;
    const item = try snapshot.vmConstantItem(import.payload0);
    if (item.value != snapshot_v1.no_id)
        return false;
    const name_constant = try snapshot.vmConstant(proto, item.key);
    if (name_constant.kind != .string or !std.mem.eql(u8, try snapshot.string(name_constant.payload0), "require"))
        return false;
    const descriptor = try snapshot.irConstant(function, descriptor_operand.value);
    const encoded = descriptor.importValue() orelse return false;
    const expected = (@as(u32, 1) << 30) | (item.key << 20);
    return encoded == expected;
}

fn isStaticRequireCall(snapshot: snapshot_v1.Snapshot, function: snapshot_v1.IrFunction, instruction_id: u32) Error!bool {
    if (instruction_id < 6)
        return false;
    const marker = try snapshot.irInstruction(function, instruction_id - 6);
    const get_import = try snapshot.irInstruction(function, instruction_id - 5);
    if (!((marker.command == .nop or marker.command == .check_safe_env) and
        (try snapshot.irInstruction(function, instruction_id - 4)).command == .load_tvalue and
        (try snapshot.irInstruction(function, instruction_id - 3)).command == .store_tvalue and
        (try snapshot.irInstruction(function, instruction_id - 2)).command == .interrupt and
        (try snapshot.irInstruction(function, instruction_id - 1)).command == .set_savedpc))
        return false;
    return isRequireImportInstruction(snapshot, function, try snapshot.proto(function.proto_id), get_import);
}

pub fn scanImportNeeds(snapshot: snapshot_v1.Snapshot, function_id: u32, static_package: bool, needs: *ImportNeeds) Error!void {
    const function = try snapshot.irFunction(function_id);
    const proto = try snapshot.proto(function.proto_id);
    var instruction_id: u32 = 0;
    while (instruction_id < function.instruction_count) : (instruction_id += 1) {
        const instruction_value = try snapshot.irInstruction(function, instruction_id);
        switch (instruction_value.command) {
            .coverage => needs.coverage_hit = true,
            .load_pointer => {
                if (instruction_value.operand_count == 1 and
                    (try snapshot.irOperand(instruction_value, 0)).kind == .vm_const)
                    needs.compare_any = true;
            },
            .do_arith => needs.do_arith = true,
            .cmp_any => needs.compare_any = true,
            .fallback_dupclosure => switch (try dupClosurePattern(snapshot, function, proto, instruction_id)) {
                .closed => needs.dupclosure = true,
                .captured => needs.newclosure_capture = true,
            },
            .newclosure => needs.newclosure_capture = true,
            .get_upvalue => needs.get_upvalue = true,
            .set_upvalue => needs.set_upvalue = true,
            .close_upvals => needs.close_upvalues = true,
            .call => {
                needs.call = true;
                if (!static_package or !try isStaticRequireCall(snapshot, function, instruction_id))
                    needs.exchange_continuation = true;
            },
            .interrupt => needs.exchange_continuation = true,
            .set_savedpc => needs.set_location = true,
            ir_cmd_new_table => {
                const owns_immediate_gc = instruction_id + 3 < function.instruction_count and
                    (try snapshot.irInstruction(function, instruction_id + 3)).command == .check_gc;
                if (owns_immediate_gc) {
                    needs.new_table = true;
                } else {
                    needs.new_table_deferred = true;
                }
            },
            .check_gc => needs.check_gc = true,
            ir_cmd_new_userdata => needs.new_userdata = true,
            ir_cmd_check_userdata_tag => needs.check_userdata_tag = true,
            ir_cmd_barrier_object => needs.barrier_object = true,
            ir_cmd_barrier_table_back => needs.barrier_table_back = true,
            ir_cmd_barrier_table_forward => needs.barrier_table_forward = true,
            ir_cmd_get_hash_node_addr => needs.hash_node_addr = true,
            ir_cmd_get_slot_node_addr => needs.slot_node_addr = true,
            ir_cmd_jump_slot_match, ir_cmd_check_slot_match => needs.node_slot_match = true,
            ir_cmd_try_call_fastgettm => needs.try_get_tm = true,
            ir_cmd_check_node_no_next => needs.check_node_no_next = true,
            ir_cmd_check_node_value => needs.check_node_value = true,
            ir_cmd_jump_cmp_protoid => needs.closure_matches_proto_id = true,
            ir_cmd_check_readonly => {
                needs.check_readonly = true;
                needs.set_location = true;
            },
            .load_tvalue => {
                if (instruction_value.operand_count >= 1) {
                    const source = try snapshot.irOperand(instruction_value, 0);
                    if (instruction_value.operand_count == 3 and instruction_id + 1 < function.instruction_count) {
                        const store = try snapshot.irInstruction(function, instruction_id + 1);
                        if (source.kind == .vm_const and store.command == .store_tvalue and store.operand_count == 2) {
                            const stored = try snapshot.irOperand(store, 1);
                            if (stored.kind == .instruction and stored.value == instruction_id)
                                needs.load_constant = true;
                        }
                    } else if (instruction_value.operand_count == 1 and source.kind == .vm_const and
                        source.value < proto.vm_constant_count and instruction_id + 2 < function.instruction_count)
                    {
                        const select = try snapshot.irInstruction(function, instruction_id + 1);
                        const store = try snapshot.irInstruction(function, instruction_id + 2);
                        if (select.command == .select_if_truthy and select.operand_count == 3 and
                            store.command == .store_tvalue and store.operand_count == 2)
                        {
                            const condition = try snapshot.irOperand(select, 0);
                            const true_value = try snapshot.irOperand(select, 1);
                            const false_value = try snapshot.irOperand(select, 2);
                            const stored = try snapshot.irOperand(store, 1);
                            const kind = (try snapshot.vmConstant(proto, source.value)).kind;
                            const materialized = switch (kind) {
                                .nil, .boolean, .number, .vector, .string, .integer, .table => true,
                                .import, .closure, .class_shape => false,
                            };
                            if (materialized and condition.kind == true_value.kind and
                                condition.value == true_value.value and false_value.kind == .instruction and
                                false_value.value == instruction_id and stored.kind == .instruction and
                                stored.value == instruction_id + 1)
                                needs.load_constant = true;
                        }
                    }
                }
            },
            ir_cmd_dup_table => needs.dup_table = true,
            ir_cmd_table_setnum => needs.table_insert_append = true,
            ir_cmd_fallback_namecall => {
                needs.namecall_plain = true;
                needs.set_location = true;
            },
            ir_cmd_setlist => needs.set_list = true,
            ir_cmd_set_table => {
                needs.array_set = true;
                needs.table_set = true;
                needs.table_array_set = true;
                needs.table_set_number = true;
            },
            ir_cmd_get_table => {
                needs.array_get = true;
                needs.table_get = true;
                needs.table_array_get = true;
                needs.table_get_number = true;
            },
            ir_cmd_get_arr_addr => needs.array_get = true,
            ir_cmd_table_len => needs.table_len = true,
            ir_cmd_do_len => needs.do_len = true,
            ir_cmd_concat => needs.concat = true,
            ir_cmd_fallback_forgprep => {
                needs.forg_prep = true;
                needs.set_location = true;
            },
            ir_cmd_forgloop => needs.forg_loop = true,
            ir_cmd_forgloop_fallback => {
                // Every emitted non-nil fallback is paired with a guarded loop arm.  Specialized
                // ipairs graphs encode the builtin arm as scalar IR rather than FORGLOOP, but the
                // semantic lowering still invokes the same builtin iterator helper there.
                needs.forg_loop = true;
                needs.forg_loop_call = true;
                needs.forg_loop_finish = true;
                needs.exchange_continuation = true;
            },
            ir_cmd_forgprep_xnext_fallback => {
                needs.forgprep_xnext_fallback = true;
                needs.set_location = true;
            },
            ir_cmd_fallback_settableks => {
                needs.table_set_string = true;
                needs.set_location = true;
            },
            ir_cmd_fallback_gettableks => {
                needs.table_get_string = true;
                needs.set_location = true;
            },
            .get_cached_import => {
                needs.get_global = true;
                needs.table_get_string = true;
                needs.set_location = true;
                needs.require_static = true;
            },
            ir_cmd_fallback_getglobal => {
                needs.get_global = true;
                needs.set_location = true;
            },
            ir_cmd_fallback_setglobal => {
                needs.set_global = true;
                needs.set_location = true;
            },
            ir_cmd_fastcall => needs.fastcall = true,
            ir_cmd_invoke_fastcall => {
                needs.fastcall = true;
                needs.check_safe_env = true;
            },
            ir_cmd_invoke_libm => needs.libm = true,
            .check_safe_env => needs.check_safe_env = true,
            .check_tag => if (instruction_value.operand_count == 3 and
                (try snapshot.irOperand(instruction_value, 2)).kind == .vm_exit)
            {
                needs.builtin_type_error = true;
                needs.set_location = true;
            },
            ir_cmd_get_type, ir_cmd_get_typeof => needs.type_name = true,
            .num_to_int64 => {
                needs.builtin_type_error = true;
                needs.builtin_number = true;
                needs.set_location = true;
            },
            ir_cmd_check_buffer_len => {
                needs.builtin_type_error = true;
                needs.builtin_number = true;
                needs.buffer_bounds_error = true;
                needs.set_location = true;
            },
            ir_cmd_buffer_readi8,
            ir_cmd_buffer_readu8,
            ir_cmd_buffer_writei8,
            ir_cmd_buffer_readi16,
            ir_cmd_buffer_readu16,
            ir_cmd_buffer_writei16,
            ir_cmd_buffer_readi32,
            ir_cmd_buffer_writei32,
            ir_cmd_buffer_readf32,
            ir_cmd_buffer_writef32,
            ir_cmd_buffer_readf64,
            ir_cmd_buffer_writef64,
            ir_cmd_buffer_readi64,
            ir_cmd_buffer_writei64,
            => {
                needs.builtin_type_error = true;
                needs.builtin_number = true;
                needs.buffer_bounds_error = true;
                needs.set_location = true;
            },
            .fallback_prepvarargs => needs.prep_varargs = true,
            .fallback_getvarargs => {
                needs.get_varargs_fixed = true;
                needs.get_varargs_multret = true;
            },
            else => {},
        }
    }
}

pub fn addRuntimeImports(object: *wasm.Object, needs: ImportNeeds) Error!RuntimeImports {
    const return_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const interrupt_params = [_]wasm.ValueType{ .i32, .i32 };
    const coverage_hit_params = [_]wasm.ValueType{ .i32, .i32 };
    const do_arith_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32, .i32 };
    const compare_any_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const dupclosure_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const newclosure_capture_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32 };
    const get_upvalue_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const set_upvalue_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const close_upvalues_params = [_]wasm.ValueType{ .i32, .i32 };
    const call_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const exchange_continuation_params = [_]wasm.ValueType{ .i32, .i32 };
    const set_location_params = [_]wasm.ValueType{ .i32, .i32 };
    const new_table_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const new_userdata_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const check_userdata_tag_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const barrier_object_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const barrier_table_back_params = [_]wasm.ValueType{ .i32, .i32 };
    const barrier_table_forward_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const register_pair_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const set_list_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32, .i32, .i32 };
    const array_operation_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const table_len_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const concat_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const do_len_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const forg_prep_params = [_]wasm.ValueType{ .i32, .i32 };
    const forg_loop_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const string_table_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32, .i32 };
    const generic_table_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const number_table_set_params = [_]wasm.ValueType{ .i32, .i32, .f64, .i32 };
    const number_table_get_params = [_]wasm.ValueType{ .i32, .i32, .i32, .f64 };
    const prep_varargs_params = [_]wasm.ValueType{ .i32, .i32 };
    const get_varargs_fixed_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const get_varargs_multret_params = [_]wasm.ValueType{ .i32, .i32 };
    const require_static_params = [_]wasm.ValueType{ .i32, .i32, .i32 };
    const fastcall_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 };
    const type_name_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32 };
    const builtin_type_error_params = [_]wasm.ValueType{ .i32, .i32, .i32, .i32, .i32, .i32 };
    const builtin_number_params = [_]wasm.ValueType{ .i32, .i32 };
    const state_params = [_]wasm.ValueType{.i32};
    const unary_f64_results = [_]wasm.ValueType{.f64};
    const libm_params = [_]wasm.ValueType{ .i32, .f64, .f64 };
    const generated_params = [_]wasm.ValueType{ .i32, .i32 };
    const no_results = [_]wasm.ValueType{};
    const status_result = [_]wasm.ValueType{.i32};

    const return_type = try object.addType(.{ .params = &return_params, .results = &no_results });
    const interrupt_type = try object.addType(.{ .params = &interrupt_params, .results = &status_result });
    const generated_type = try object.addType(.{ .params = &generated_params, .results = &status_result });
    const return_ = try object.importFunction("env", return_symbol, return_type);
    const interrupt = try object.importFunction("env", interrupt_symbol, interrupt_type);
    const coverage_hit = if (needs.coverage_hit) blk: {
        const helper_type = try object.addType(.{ .params = &coverage_hit_params, .results = &no_results });
        break :blk try object.importFunction("env", coverage_hit_symbol, helper_type);
    } else null;
    const do_arith = if (needs.do_arith) blk: {
        const helper_type = try object.addType(.{ .params = &do_arith_params, .results = &no_results });
        break :blk try object.importFunction("env", do_arith_symbol, helper_type);
    } else null;
    const compare_any = if (needs.compare_any) blk: {
        const helper_type = try object.addType(.{ .params = &compare_any_params, .results = &status_result });
        break :blk try object.importFunction("env", compare_any_symbol, helper_type);
    } else null;
    const dupclosure = if (needs.dupclosure) blk: {
        const helper_type = try object.addType(.{ .params = &dupclosure_params, .results = &no_results });
        break :blk try object.importFunction("env", dupclosure_symbol, helper_type);
    } else null;
    const newclosure_capture = if (needs.newclosure_capture) blk: {
        const helper_type = try object.addType(.{ .params = &newclosure_capture_params, .results = &no_results });
        break :blk try object.importFunction("env", newclosure_capture_symbol, helper_type);
    } else null;
    const get_upvalue = if (needs.get_upvalue) blk: {
        const helper_type = try object.addType(.{ .params = &get_upvalue_params, .results = &no_results });
        break :blk try object.importFunction("env", get_upvalue_symbol, helper_type);
    } else null;
    const set_upvalue = if (needs.set_upvalue) blk: {
        const helper_type = try object.addType(.{ .params = &set_upvalue_params, .results = &no_results });
        break :blk try object.importFunction("env", set_upvalue_symbol, helper_type);
    } else null;
    const close_upvalues = if (needs.close_upvalues) blk: {
        const helper_type = try object.addType(.{ .params = &close_upvalues_params, .results = &no_results });
        break :blk try object.importFunction("env", close_upvalues_symbol, helper_type);
    } else null;
    const call = if (needs.call) blk: {
        const helper_type = try object.addType(.{ .params = &call_params, .results = &status_result });
        break :blk try object.importFunction("env", call_symbol, helper_type);
    } else null;
    const exchange_continuation = if (needs.exchange_continuation) blk: {
        const helper_type = try object.addType(.{ .params = &exchange_continuation_params, .results = &status_result });
        break :blk try object.importFunction("env", exchange_continuation_symbol, helper_type);
    } else null;
    const set_location = if (needs.set_location) blk: {
        const helper_type = try object.addType(.{ .params = &set_location_params, .results = &no_results });
        break :blk try object.importFunction("env", set_location_symbol, helper_type);
    } else null;
    const new_table = if (needs.new_table) blk: {
        const helper_type = try object.addType(.{ .params = &new_table_params, .results = &no_results });
        break :blk try object.importFunction("env", new_table_symbol, helper_type);
    } else null;
    const new_table_deferred = if (needs.new_table_deferred) blk: {
        const helper_type = try object.addType(.{ .params = &new_table_params, .results = &no_results });
        break :blk try object.importFunction("env", new_table_deferred_symbol, helper_type);
    } else null;
    const check_gc = if (needs.check_gc) blk: {
        const helper_type = try object.addType(.{ .params = &state_params, .results = &no_results });
        break :blk try object.importFunction("env", check_gc_symbol, helper_type);
    } else null;
    const new_userdata = if (needs.new_userdata) blk: {
        const helper_type = try object.addType(.{ .params = &new_userdata_params, .results = &status_result });
        break :blk try object.importFunction("env", new_userdata_symbol, helper_type);
    } else null;
    const check_userdata_tag = if (needs.check_userdata_tag) blk: {
        const helper_type = try object.addType(.{ .params = &check_userdata_tag_params, .results = &status_result });
        break :blk try object.importFunction("env", check_userdata_tag_symbol, helper_type);
    } else null;
    const barrier_object = if (needs.barrier_object) blk: {
        const helper_type = try object.addType(.{ .params = &barrier_object_params, .results = &no_results });
        break :blk try object.importFunction("env", barrier_object_symbol, helper_type);
    } else null;
    const barrier_table_back = if (needs.barrier_table_back) blk: {
        const helper_type = try object.addType(.{ .params = &barrier_table_back_params, .results = &no_results });
        break :blk try object.importFunction("env", barrier_table_back_symbol, helper_type);
    } else null;
    const barrier_table_forward = if (needs.barrier_table_forward) blk: {
        const helper_type = try object.addType(.{ .params = &barrier_table_forward_params, .results = &no_results });
        break :blk try object.importFunction("env", barrier_table_forward_symbol, helper_type);
    } else null;
    const hash_node_addr = if (needs.hash_node_addr) blk: {
        const helper_type = try object.addType(.{ .params = &register_pair_params, .results = &status_result });
        break :blk try object.importFunction("env", hash_node_addr_symbol, helper_type);
    } else null;
    const slot_node_addr = if (needs.slot_node_addr) blk: {
        const helper_type = try object.addType(.{ .params = &register_pair_params, .results = &status_result });
        break :blk try object.importFunction("env", slot_node_addr_symbol, helper_type);
    } else null;
    const node_slot_match = if (needs.node_slot_match) blk: {
        const helper_type = try object.addType(.{ .params = &register_pair_params, .results = &status_result });
        break :blk try object.importFunction("env", node_slot_match_symbol, helper_type);
    } else null;
    const try_get_tm = if (needs.try_get_tm) blk: {
        const helper_type = try object.addType(.{ .params = &register_pair_params, .results = &status_result });
        break :blk try object.importFunction("env", try_get_tm_symbol, helper_type);
    } else null;
    const check_node_no_next = if (needs.check_node_no_next) blk: {
        const helper_type = try object.addType(.{ .params = &generated_params, .results = &status_result });
        break :blk try object.importFunction("env", check_node_no_next_symbol, helper_type);
    } else null;
    const check_node_value = if (needs.check_node_value) blk: {
        const helper_type = try object.addType(.{ .params = &generated_params, .results = &status_result });
        break :blk try object.importFunction("env", check_node_value_symbol, helper_type);
    } else null;
    const closure_matches_proto_id = if (needs.closure_matches_proto_id) blk: {
        const helper_type = try object.addType(.{ .params = &register_pair_params, .results = &status_result });
        break :blk try object.importFunction("env", closure_matches_proto_id_symbol, helper_type);
    } else null;
    const check_readonly = if (needs.check_readonly) blk: {
        const helper_type = try object.addType(.{ .params = &forg_loop_params, .results = &status_result });
        break :blk try object.importFunction("env", check_readonly_symbol, helper_type);
    } else null;
    const load_constant = if (needs.load_constant) blk: {
        const helper_type = try object.addType(.{ .params = &register_pair_params, .results = &no_results });
        break :blk try object.importFunction("env", load_constant_symbol, helper_type);
    } else null;
    const dup_table = if (needs.dup_table) blk: {
        const helper_type = try object.addType(.{ .params = &register_pair_params, .results = &no_results });
        break :blk try object.importFunction("env", dup_table_symbol, helper_type);
    } else null;
    const table_insert_append = if (needs.table_insert_append) blk: {
        const helper_type = try object.addType(.{ .params = &register_pair_params, .results = &no_results });
        break :blk try object.importFunction("env", table_insert_append_symbol, helper_type);
    } else null;
    const namecall_plain = if (needs.namecall_plain) blk: {
        const helper_type = try object.addType(.{ .params = &string_table_params, .results = &no_results });
        break :blk try object.importFunction("env", namecall_plain_symbol, helper_type);
    } else null;
    const set_list = if (needs.set_list) blk: {
        const helper_type = try object.addType(.{ .params = &set_list_params, .results = &no_results });
        break :blk try object.importFunction("env", set_list_symbol, helper_type);
    } else null;
    const array_set = if (needs.array_set) blk: {
        const helper_type = try object.addType(.{ .params = &array_operation_params, .results = &no_results });
        break :blk try object.importFunction("env", array_set_symbol, helper_type);
    } else null;
    const array_get = if (needs.array_get) blk: {
        const helper_type = try object.addType(.{ .params = &array_operation_params, .results = &no_results });
        break :blk try object.importFunction("env", array_get_symbol, helper_type);
    } else null;
    const table_len = if (needs.table_len) blk: {
        const helper_type = try object.addType(.{ .params = &table_len_params, .results = &no_results });
        break :blk try object.importFunction("env", table_len_symbol, helper_type);
    } else null;
    const concat = if (needs.concat) blk: {
        const helper_type = try object.addType(.{ .params = &concat_params, .results = &no_results });
        break :blk try object.importFunction("env", concat_symbol, helper_type);
    } else null;
    const do_len = if (needs.do_len) blk: {
        const helper_type = try object.addType(.{ .params = &do_len_params, .results = &no_results });
        break :blk try object.importFunction("env", do_len_symbol, helper_type);
    } else null;
    const forg_prep = if (needs.forg_prep) blk: {
        const helper_type = try object.addType(.{ .params = &forg_prep_params, .results = &no_results });
        break :blk try object.importFunction("env", forg_prep_symbol, helper_type);
    } else null;
    const forg_loop = if (needs.forg_loop) blk: {
        const helper_type = try object.addType(.{ .params = &forg_loop_params, .results = &status_result });
        break :blk try object.importFunction("env", forg_loop_symbol, helper_type);
    } else null;
    const forg_loop_call = if (needs.forg_loop_call) blk: {
        const helper_type = try object.addType(.{ .params = &forg_loop_params, .results = &status_result });
        break :blk try object.importFunction("env", forg_loop_call_symbol, helper_type);
    } else null;
    const forg_loop_finish = if (needs.forg_loop_finish) blk: {
        const helper_type = try object.addType(.{ .params = &forg_loop_params, .results = &status_result });
        break :blk try object.importFunction("env", forg_loop_finish_symbol, helper_type);
    } else null;
    const forgprep_xnext_fallback = if (needs.forgprep_xnext_fallback) blk: {
        const helper_type = try object.addType(.{ .params = &forg_prep_params, .results = &no_results });
        break :blk try object.importFunction("env", forgprep_xnext_fallback_symbol, helper_type);
    } else null;
    const table_set_string = if (needs.table_set_string) blk: {
        const helper_type = try object.addType(.{ .params = &string_table_params, .results = &no_results });
        break :blk try object.importFunction("env", table_set_string_symbol, helper_type);
    } else null;
    const table_get_string = if (needs.table_get_string) blk: {
        const helper_type = try object.addType(.{ .params = &string_table_params, .results = &no_results });
        break :blk try object.importFunction("env", table_get_string_symbol, helper_type);
    } else null;
    const table_set = if (needs.table_set) blk: {
        const helper_type = try object.addType(.{ .params = &generic_table_params, .results = &no_results });
        break :blk try object.importFunction("env", table_set_symbol, helper_type);
    } else null;
    const table_get = if (needs.table_get) blk: {
        const helper_type = try object.addType(.{ .params = &generic_table_params, .results = &no_results });
        break :blk try object.importFunction("env", table_get_symbol, helper_type);
    } else null;
    const table_set_number = if (needs.table_set_number) blk: {
        const helper_type = try object.addType(.{ .params = &number_table_set_params, .results = &no_results });
        break :blk try object.importFunction("env", table_set_number_symbol, helper_type);
    } else null;
    const table_get_number = if (needs.table_get_number) blk: {
        const helper_type = try object.addType(.{ .params = &number_table_get_params, .results = &no_results });
        break :blk try object.importFunction("env", table_get_number_symbol, helper_type);
    } else null;
    const table_array_set = if (needs.table_array_set) blk: {
        const helper_type = try object.addType(.{ .params = &generic_table_params, .results = &status_result });
        break :blk try object.importFunction("env", table_array_set_symbol, helper_type);
    } else null;
    const table_array_get = if (needs.table_array_get) blk: {
        const helper_type = try object.addType(.{ .params = &generic_table_params, .results = &status_result });
        break :blk try object.importFunction("env", table_array_get_symbol, helper_type);
    } else null;
    const get_global = if (needs.get_global) blk: {
        const helper_type = try object.addType(.{ .params = &generic_table_params, .results = &no_results });
        break :blk try object.importFunction("env", get_global_symbol, helper_type);
    } else null;
    const set_global = if (needs.set_global) blk: {
        const helper_type = try object.addType(.{ .params = &generic_table_params, .results = &no_results });
        break :blk try object.importFunction("env", set_global_symbol, helper_type);
    } else null;
    const prep_varargs = if (needs.prep_varargs) blk: {
        const helper_type = try object.addType(.{ .params = &prep_varargs_params, .results = &no_results });
        break :blk try object.importFunction("env", prep_varargs_symbol, helper_type);
    } else null;
    const get_varargs_fixed = if (needs.get_varargs_fixed) blk: {
        const helper_type = try object.addType(.{ .params = &get_varargs_fixed_params, .results = &no_results });
        break :blk try object.importFunction("env", get_varargs_fixed_symbol, helper_type);
    } else null;
    const get_varargs_multret = if (needs.get_varargs_multret) blk: {
        const helper_type = try object.addType(.{ .params = &get_varargs_multret_params, .results = &no_results });
        break :blk try object.importFunction("env", get_varargs_multret_symbol, helper_type);
    } else null;
    const require_static = if (needs.require_static) blk: {
        const helper_type = try object.addType(.{ .params = &require_static_params, .results = &status_result });
        break :blk try object.importFunction("env", require_static_symbol, helper_type);
    } else null;
    const check_safe_env = if (needs.check_safe_env) blk: {
        const helper_type = try object.addType(.{ .params = &state_params, .results = &status_result });
        break :blk try object.importFunction("env", check_safe_env_symbol, helper_type);
    } else null;
    const fastcall = if (needs.fastcall) blk: {
        const helper_type = try object.addType(.{ .params = &fastcall_params, .results = &status_result });
        break :blk try object.importFunction("env", fastcall_symbol, helper_type);
    } else null;
    const type_name = if (needs.type_name) blk: {
        const helper_type = try object.addType(.{ .params = &type_name_params, .results = &status_result });
        break :blk try object.importFunction("env", type_name_symbol, helper_type);
    } else null;
    const libm = if (needs.libm) blk: {
        const helper_type = try object.addType(.{ .params = &libm_params, .results = &unary_f64_results });
        break :blk try object.importFunction("env", libm_symbol, helper_type);
    } else null;
    const builtin_type_error = if (needs.builtin_type_error) blk: {
        const helper_type = try object.addType(.{ .params = &builtin_type_error_params, .results = &status_result });
        break :blk try object.importFunction("env", builtin_type_error_symbol, helper_type);
    } else null;
    const builtin_number = if (needs.builtin_number) blk: {
        const helper_type = try object.addType(.{ .params = &builtin_number_params, .results = &unary_f64_results });
        break :blk try object.importFunction("env", builtin_number_symbol, helper_type);
    } else null;
    const buffer_bounds_error = if (needs.buffer_bounds_error) blk: {
        const helper_type = try object.addType(.{ .params = &state_params, .results = &no_results });
        break :blk try object.importFunction("env", buffer_bounds_error_symbol, helper_type);
    } else null;
    return .{
        .return_ = return_,
        .interrupt = interrupt,
        .coverage_hit = coverage_hit,
        .do_arith = do_arith,
        .compare_any = compare_any,
        .dupclosure = dupclosure,
        .newclosure_capture = newclosure_capture,
        .get_upvalue = get_upvalue,
        .set_upvalue = set_upvalue,
        .close_upvalues = close_upvalues,
        .call = call,
        .exchange_continuation = exchange_continuation,
        .set_location = set_location,
        .new_table = new_table,
        .new_table_deferred = new_table_deferred,
        .check_gc = check_gc,
        .new_userdata = new_userdata,
        .check_userdata_tag = check_userdata_tag,
        .barrier_object = barrier_object,
        .barrier_table_back = barrier_table_back,
        .barrier_table_forward = barrier_table_forward,
        .hash_node_addr = hash_node_addr,
        .slot_node_addr = slot_node_addr,
        .node_slot_match = node_slot_match,
        .try_get_tm = try_get_tm,
        .check_node_no_next = check_node_no_next,
        .check_node_value = check_node_value,
        .closure_matches_proto_id = closure_matches_proto_id,
        .check_readonly = check_readonly,
        .load_constant = load_constant,
        .dup_table = dup_table,
        .table_insert_append = table_insert_append,
        .namecall_plain = namecall_plain,
        .set_list = set_list,
        .array_set = array_set,
        .array_get = array_get,
        .table_len = table_len,
        .concat = concat,
        .do_len = do_len,
        .forg_prep = forg_prep,
        .forg_loop = forg_loop,
        .forg_loop_call = forg_loop_call,
        .forg_loop_finish = forg_loop_finish,
        .forgprep_xnext_fallback = forgprep_xnext_fallback,
        .table_set_string = table_set_string,
        .table_get_string = table_get_string,
        .table_set = table_set,
        .table_get = table_get,
        .table_set_number = table_set_number,
        .table_get_number = table_get_number,
        .table_array_set = table_array_set,
        .table_array_get = table_array_get,
        .get_global = get_global,
        .set_global = set_global,
        .check_safe_env = check_safe_env,
        .fastcall = fastcall,
        .type_name = type_name,
        .libm = libm,
        .builtin_type_error = builtin_type_error,
        .builtin_number = builtin_number,
        .buffer_bounds_error = buffer_bounds_error,
        .prep_varargs = prep_varargs,
        .get_varargs_fixed = get_varargs_fixed,
        .get_varargs_multret = get_varargs_multret,
        .require_static = require_static,
        .generated_type = generated_type,
    };
}

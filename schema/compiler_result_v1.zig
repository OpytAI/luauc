pub const size: usize = 320;
pub const diagnostic_record_size: u32 = 24;
pub const no_module: u32 = 0xffff_ffff;

pub const DiagnosticRecord = extern struct {
    code: u32 = 0,
    module_id: u32 = no_module,
    source_start: u32 = 0,
    source_end: u32 = 0,
    ir_command: u32 = 0,
    reserved: u32 = 0,
};

pub const CompileResultV1 = extern struct {
    data: u32 = 0,
    size: u32 = 0,
    diagnostic: u32 = 0,
    diagnostic_size: u32 = 0,
    status: u32 = 0,
    reserved0: u32 = 0,
    request_id: [16]u8 = .{0} ** 16,
    compiler_build_sha256: [32]u8 = .{0} ** 32,
    luau_pin_sha256: [32]u8 = .{0} ** 32,
    runtime_profile_sha256: [32]u8 = .{0} ** 32,
    runtime_pack_sha256: [32]u8 = .{0} ** 32,
    manifest_sha256: [32]u8 = .{0} ** 32,
    generated_object_sha256: [32]u8 = .{0} ** 32,
    artifact_sha256: [32]u8 = .{0} ** 32,
    generated_function_count: u32 = 0,
    generated_data_bytes: u32 = 0,
    diagnostic_records_ptr: u32 = 0,
    diagnostic_records_count: u32 = 0,
    diagnostic_records_bytes: u32 = 0,
    import_count: u32 = 0,
    export_count: u32 = 0,
    resource_usage_arena_used: u32 = 0,
    resource_usage_table_entries: u32 = 0,
    resource_usage_output_bytes: u32 = 0,
    resource_usage_compile_instructions: u32 = 0,
    resource_usage_compile_functions: u32 = 0,
    resource_usage_compile_bytes: u32 = 0,
    reserved1: u32 = 0,
};

comptime {
    if (@sizeOf(CompileResultV1) != size or @sizeOf(DiagnosticRecord) != diagnostic_record_size)
        @compileError("CompileResultV1 ABI layout drift");
}

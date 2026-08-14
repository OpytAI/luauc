//! Generated-code-to-runtime ABI shared by strict runtime executables.
//!
//! Keep this binding small and pin-sized. C++ owns the implementation and the canonical C header;
//! Zig entrypoints use this module instead of cloning offsets, status values, or the layout digest.

const std = @import("std");

pub const State = opaque {};

pub const VmConstantKind = enum(u8) {
    nil = 0,
    boolean = 1,
    number = 2,
    vector = 3,
    string = 4,
    integer = 5,
    import = 6,
    table = 7,
    closure = 8,
    class_shape = 9,
};

pub const AotVmConstant = extern struct {
    kind: VmConstantKind,
    reserved: [3]u8 = .{ 0, 0, 0 },
    payload0: u32 = 0,
    payload1: u32 = 0,
    payload2: u32 = 0,
};

pub const AotVmConstantItem = extern struct {
    key: u32,
    value: u32,
};

pub const AotCoverageSite = extern struct {
    line: u32,
    reserved: u32 = 0,
};

pub const AotProto = extern struct {
    abi_version: u32,
    struct_size: u32,
    layout_sha256: [32]u8,
    entry: *const fn (?*State, *const AotProto) callconv(.c) u32,
    function_id: u32,
    parent_id: u32,
    flags: u32,
    num_params: u8,
    nups: u8,
    is_vararg: u8,
    max_stack_size: u8,
    constants: ?[*]const AotVmConstant = null,
    constant_count: u32 = 0,
    constant_items: ?[*]const AotVmConstantItem = null,
    constant_item_count: u32 = 0,
    coverage_sites: ?[*]const AotCoverageSite = null,
    coverage_site_count: u32 = 0,
    coverage_line_count: u32 = 0,
};

pub const AotModule = extern struct {
    abi_version: u32,
    struct_size: u32,
    layout_sha256: [32]u8,
    module_id: u32,
    root_proto_id: u32,
    source_name: [*]const u8,
    source_name_size: u32,
};

pub const AotProgram = extern struct {
    abi_version: u32,
    struct_size: u32,
    layout_sha256: [32]u8,
    protos: [*]const AotProto,
    proto_count: u32,
    root_proto_id: u32,
    flags: u32,
    modules: ?[*]const AotModule = null,
    module_count: u32 = 0,
    entry_module_id: u32 = 0,
};

comptime {
    if (@sizeOf(AotVmConstant) != 16 or @sizeOf(AotVmConstantItem) != 8)
        @compileError("LuaucRuntimeVmConstantV1 Zig layout drift");
    if (@sizeOf(AotCoverageSite) != 8)
        @compileError("LuaucRuntimeCoverageSiteV1 Zig layout drift");
    if (@sizeOf(AotProto) != 88 or @offsetOf(AotProto, "entry") != 40 or
        @offsetOf(AotProto, "num_params") != 56 or @offsetOf(AotProto, "constants") != 60 or
        @offsetOf(AotProto, "constant_items") != 68 or @offsetOf(AotProto, "coverage_sites") != 76)
        @compileError("LuaucRuntimeProtoV1 Zig layout drift");
    if (@sizeOf(AotModule) != 56 or @offsetOf(AotModule, "source_name") != 48)
        @compileError("LuaucRuntimeModuleV1 Zig layout drift");
    if (@sizeOf(AotProgram) != 68 or @offsetOf(AotProgram, "protos") != 40 or @offsetOf(AotProgram, "modules") != 56)
        @compileError("LuaucRuntimeProgramV1 Zig layout drift");
}

pub const abi_version: u32 = 1;
pub const vm_constant_size: u32 = 16;
pub const vm_constant_item_size: u32 = 8;
pub const proto_size: u32 = 88;
pub const coverage_site_size: u32 = 8;
pub const module_size: u32 = 56;
pub const legacy_program_size: u32 = 56;
pub const program_size: u32 = 68;
pub const no_id: u32 = std.math.maxInt(u32);
pub const flag_root: u32 = 1;
pub const multret: i32 = -1;

pub const layout_sha256 = [_]u8{
    0x42, 0x5d, 0x38, 0xd7, 0x5e, 0xf9, 0xf4, 0xe2, 0x66, 0x93, 0xa6, 0x90, 0xe0, 0x85, 0x7f, 0x90,
    0x2a, 0xa7, 0x6f, 0x1c, 0x18, 0x56, 0x19, 0x6a, 0xc3, 0x0d, 0xc6, 0x23, 0x6e, 0xa4, 0xc4, 0x96,
};

pub extern fn luauc_runtime_v1_push_root(
    state: ?*State,
    metadata: *const AotProto,
    source: [*]const u8,
    source_size: usize,
) u32;

pub extern fn luauc_runtime_v1_push_program(
    state: ?*State,
    program: *const AotProgram,
    source: [*]const u8,
    source_size: usize,
) u32;

pub extern fn luauc_runtime_v1_load_constant(
    state: ?*State,
    destination_register: u32,
    constant_id: u32,
) void;

pub extern fn luauc_runtime_v1_namecall_plain(
    state: ?*State,
    destination_register: u32,
    source_register: u32,
    key_pointer: [*]const u8,
    key_length: usize,
) void;

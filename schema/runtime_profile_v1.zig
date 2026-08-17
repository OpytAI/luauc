const std = @import("std");

pub const magic = "LUACRP1\x00".*;
pub const version: u16 = 1;
pub const header_size: u16 = 320;
pub const import_record_size: u32 = 24;
pub const export_record_size: u32 = 16;
pub const runtime_symbol_record_size: u32 = 24;
pub const binding_record_size: u32 = 16;
pub const custom_section_name = "luauc.runtime.v1";

pub const Error = error{
    Truncated,
    InvalidMagic,
    UnsupportedVersion,
    InvalidHeader,
    ResourceLimit,
    IntegerOverflow,
    NonCanonicalLayout,
    InvalidString,
    NonCanonicalOrder,
    DuplicateRole,
    InvalidKind,
    InvalidBinding,
    InvalidPack,
    MissingPackManifest,
    DuplicatePackManifest,
    PackManifestMismatch,
};

pub const Kind = enum(u8) { function = 0, table = 1, memory = 2, global = 3 };
pub const Role = enum(u16) {
    program_pointer = 1,
    generated_data_arena = 2,
    generated_data_capacity = 3,
    memory = 4,
    stack_pointer = 5,
    protected_dispatch = 6,
    alloc = 7,
    dealloc = 8,
    context_create = 9,
    context_destroy = 10,
    invoke = 11,
    initialize = 12,
    coverage = 13,
};

pub const HostImport = struct { module: []const u8, name: []const u8, type_index: u32, kind: Kind };
pub const RetainedExport = struct { name: []const u8, kind: Kind, role: ?Role };
pub const RuntimeSymbol = struct { name: []const u8, type_index: u32, kind: Kind };
pub const Binding = struct { name: []const u8, role: Role, kind: Kind };

pub const Profile = struct {
    bytes: []const u8,
    feature_mask: u32,
    memory_minimum: u32,
    memory_maximum: u32,
    table_minimum: u32,
    table_maximum: u32,
    profile_id: []const u8,
    luau_pin_sha256: [32]u8,
    runtime_abi_sha256: [32]u8,
    object_contract_sha256: [32]u8,
    pack_build_sha256: [32]u8,
    license_inventory_sha256: [32]u8,
    string_offset: u32,
    string_size: u32,
    import_offset: u32,
    import_count: u32,
    export_offset: u32,
    export_count: u32,
    runtime_symbol_offset: u32,
    runtime_symbol_count: u32,
    binding_offset: u32,
    binding_count: u32,

    pub fn hostImport(self: Profile, index: u32) Error!HostImport {
        if (index >= self.import_count) return Error.ResourceLimit;
        const record = try self.recordAt(self.import_offset, index, import_record_size);
        return .{ .module = try self.stringAt(readU32(record, 0), readU32(record, 4)), .name = try self.stringAt(readU32(record, 8), readU32(record, 12)), .type_index = readU32(record, 16), .kind = try kind(record[20]) };
    }

    pub fn retainedExport(self: Profile, index: u32) Error!RetainedExport {
        if (index >= self.export_count) return Error.ResourceLimit;
        const record = try self.recordAt(self.export_offset, index, export_record_size);
        return .{ .name = try self.stringAt(readU32(record, 0), readU32(record, 4)), .kind = try kind(record[8]), .role = if (record[9] == 0) null else try role(record[9]) };
    }

    pub fn runtimeSymbol(self: Profile, index: u32) Error!RuntimeSymbol {
        if (index >= self.runtime_symbol_count) return Error.ResourceLimit;
        const record = try self.recordAt(self.runtime_symbol_offset, index, runtime_symbol_record_size);
        return .{ .name = try self.stringAt(readU32(record, 0), readU32(record, 4)), .type_index = readU32(record, 8), .kind = try kind(record[12]) };
    }

    fn runtimeSymbolModule(self: Profile, index: u32) Error!?[]const u8 {
        if (index >= self.runtime_symbol_count) return Error.ResourceLimit;
        const record = try self.recordAt(self.runtime_symbol_offset, index, runtime_symbol_record_size);
        const offset = readU32(record, 16);
        const size = readU32(record, 20);
        if (size == 0) return null;
        return try self.stringAt(offset, size);
    }

    pub fn binding(self: Profile, index: u32) Error!Binding {
        if (index >= self.binding_count) return Error.ResourceLimit;
        const record = try self.recordAt(self.binding_offset, index, binding_record_size);
        return .{ .name = try self.stringAt(readU32(record, 0), readU32(record, 4)), .role = try role(readU16(record, 8)), .kind = try kind(record[10]) };
    }

    /// Generated-runtime helpers are imported from this module. Objects emit `"env"`;
    /// the linker rewrites those module strings to this name before `findExport`.
    pub fn generatedRuntimeModule(self: Profile) []const u8 {
        var found: ?[]const u8 = null;
        var index: u32 = 0;
        while (index < self.runtime_symbol_count) : (index += 1) {
            const module = (self.runtimeSymbolModule(index) catch continue) orelse continue;
            if (found) |previous| {
                if (!std.mem.eql(u8, previous, module))
                    return "env";
            } else found = module;
        }
        return found orelse "env";
    }

    pub fn bindingName(self: Profile, wanted: Role, wanted_kind: Kind) Error![]const u8 {
        var index: u32 = 0;
        while (index < self.binding_count) : (index += 1) {
            const item = try self.binding(index);
            if (item.role == wanted) {
                if (item.kind != wanted_kind) return Error.InvalidBinding;
                return item.name;
            }
        }
        return Error.InvalidBinding;
    }

    pub fn allowsHostImport(self: Profile, module: []const u8, name: []const u8, item_kind: u8, type_index: u32) bool {
        var index: u32 = 0;
        while (index < self.import_count) : (index += 1) {
            const item = self.hostImport(index) catch return false;
            if (@intFromEnum(item.kind) == item_kind and item.type_index == type_index and std.mem.eql(u8, item.module, module) and std.mem.eql(u8, item.name, name)) return true;
        }
        return false;
    }

    fn recordAt(self: Profile, offset: u32, index: u32, size: u32) Error![]const u8 {
        const start = try add(offset, try mul(index, size));
        const finish = try add(start, size);
        if (finish > self.bytes.len) return Error.Truncated;
        return self.bytes[start..finish];
    }

    fn stringAt(self: Profile, offset: u32, size: u32) Error![]const u8 {
        if (size == 0) return Error.InvalidString;
        const finish = try add(offset, size);
        if (finish > self.string_size) return Error.InvalidString;
        const start = try add(self.string_offset, offset);
        const value = self.bytes[start..][0..size];
        if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return Error.InvalidString;
        for (value) |byte| if (byte < 0x20 or byte == 0x7f) return Error.InvalidString;
        return value;
    }
};

pub fn parse(bytes: []const u8) Error!Profile {
    if (bytes.len < header_size) return Error.Truncated;
    if (bytes.len > 256 * 1024) return Error.ResourceLimit;
    if (!std.mem.eql(u8, bytes[0..8], &magic)) return Error.InvalidMagic;
    if (readU16(bytes, 8) != version) return Error.UnsupportedVersion;
    if (readU16(bytes, 10) != header_size or readU32(bytes, 12) != bytes.len) return Error.InvalidHeader;
    if (readU32(bytes, 76) != import_record_size or readU32(bytes, 80) != export_record_size or readU32(bytes, 84) != runtime_symbol_record_size or readU32(bytes, 88) != binding_record_size) return Error.InvalidHeader;
    for (bytes[92..104]) |byte| if (byte != 0) return Error.InvalidHeader;
    for (bytes[112..128]) |byte| if (byte != 0) return Error.InvalidHeader;
    for (bytes[288..320]) |byte| if (byte != 0) return Error.InvalidHeader;

    const import_count = readU32(bytes, 48);
    const export_count = readU32(bytes, 56);
    const runtime_count = readU32(bytes, 64);
    const binding_count = readU32(bytes, 72);
    if (import_count > 64 or export_count == 0 or export_count > 256 or runtime_count == 0 or runtime_count > 256 or binding_count == 0 or binding_count > 32) return Error.ResourceLimit;
    const import_offset: u32 = header_size;
    const export_offset = try add(import_offset, try mul(import_count, import_record_size));
    const runtime_offset = try add(export_offset, try mul(export_count, export_record_size));
    const binding_offset = try add(runtime_offset, try mul(runtime_count, runtime_symbol_record_size));
    const string_offset = try add(binding_offset, try mul(binding_count, binding_record_size));
    if (readU32(bytes, 44) != import_offset or readU32(bytes, 52) != export_offset or readU32(bytes, 60) != runtime_offset or readU32(bytes, 68) != binding_offset or readU32(bytes, 36) != string_offset or try add(string_offset, readU32(bytes, 40)) != bytes.len) return Error.NonCanonicalLayout;
    if (readU32(bytes, 20) == 0 or readU32(bytes, 24) < readU32(bytes, 20) or readU32(bytes, 28) == 0 or readU32(bytes, 32) < readU32(bytes, 28)) return Error.InvalidHeader;

    var profile = Profile{
        .bytes = bytes,
        .feature_mask = readU32(bytes, 16),
        .memory_minimum = readU32(bytes, 20),
        .memory_maximum = readU32(bytes, 24),
        .table_minimum = readU32(bytes, 28),
        .table_maximum = readU32(bytes, 32),
        .profile_id = undefined,
        .luau_pin_sha256 = bytes[128..160].*,
        .runtime_abi_sha256 = bytes[160..192].*,
        .object_contract_sha256 = bytes[192..224].*,
        .pack_build_sha256 = bytes[224..256].*,
        .license_inventory_sha256 = bytes[256..288].*,
        .string_offset = string_offset,
        .string_size = readU32(bytes, 40),
        .import_offset = import_offset,
        .import_count = import_count,
        .export_offset = export_offset,
        .export_count = export_count,
        .runtime_symbol_offset = runtime_offset,
        .runtime_symbol_count = runtime_count,
        .binding_offset = binding_offset,
        .binding_count = binding_count,
    };
    profile.profile_id = try profile.stringAt(readU32(bytes, 104), readU32(bytes, 108));

    var previous_module: ?[]const u8 = null;
    var previous_name: ?[]const u8 = null;
    var index: u32 = 0;
    while (index < import_count) : (index += 1) {
        const item = try profile.hostImport(index);
        if (item.kind != .function) return Error.InvalidKind;
        if (previous_module) |module| {
            const module_order = std.mem.order(u8, module, item.module);
            if (module_order == .gt or (module_order == .eq and std.mem.order(u8, previous_name.?, item.name) != .lt)) return Error.NonCanonicalOrder;
        }
        previous_module = item.module;
        previous_name = item.name;
    }
    previous_name = null;
    index = 0;
    while (index < export_count) : (index += 1) {
        const item = try profile.retainedExport(index);
        if (previous_name) |name| if (std.mem.order(u8, name, item.name) != .lt) return Error.NonCanonicalOrder;
        previous_name = item.name;
    }
    previous_name = null;
    index = 0;
    while (index < runtime_count) : (index += 1) {
        const item = try profile.runtimeSymbol(index);
        if (item.kind != .function) return Error.InvalidKind;
        if (previous_name) |name| if (std.mem.order(u8, name, item.name) != .lt) return Error.NonCanonicalOrder;
        previous_name = item.name;
    }
    var previous_role: u16 = 0;
    index = 0;
    while (index < binding_count) : (index += 1) {
        const item = try profile.binding(index);
        const role_value = @intFromEnum(item.role);
        if (role_value <= previous_role) return if (role_value == previous_role) Error.DuplicateRole else Error.NonCanonicalOrder;
        previous_role = role_value;
    }
    inline for (.{ .{ Role.program_pointer, Kind.global }, .{ Role.generated_data_arena, Kind.global }, .{ Role.generated_data_capacity, Kind.global }, .{ Role.memory, Kind.memory }, .{ Role.protected_dispatch, Kind.function }, .{ Role.alloc, Kind.function }, .{ Role.dealloc, Kind.function }, .{ Role.context_create, Kind.function }, .{ Role.context_destroy, Kind.function }, .{ Role.invoke, Kind.function }, .{ Role.initialize, Kind.function } }) |required| _ = try profile.bindingName(required[0], required[1]);
    return profile;
}

pub fn validatePackManifest(pack: []const u8, profile_bytes: []const u8) Error!void {
    if (pack.len < 8 or !std.mem.eql(u8, pack[0..8], &[_]u8{ 0, 0x61, 0x73, 0x6d, 1, 0, 0, 0 })) return Error.InvalidPack;
    var cursor: usize = 8;
    var found: u32 = 0;
    while (cursor < pack.len) {
        const section_id = pack[cursor];
        cursor += 1;
        const size = try readUleb(pack, &cursor);
        const finish = std.math.add(usize, cursor, size) catch return Error.IntegerOverflow;
        if (finish > pack.len) return Error.InvalidPack;
        if (section_id == 0) {
            var custom_cursor = cursor;
            const name_size = try readUleb(pack, &custom_cursor);
            const name_finish = std.math.add(usize, custom_cursor, name_size) catch return Error.IntegerOverflow;
            if (name_finish > finish) return Error.InvalidPack;
            if (std.mem.eql(u8, pack[custom_cursor..name_finish], custom_section_name)) {
                found += 1;
                if (found > 1) return Error.DuplicatePackManifest;
                if (!std.mem.eql(u8, pack[name_finish..finish], profile_bytes)) return Error.PackManifestMismatch;
            }
        }
        cursor = finish;
    }
    if (found == 0) return Error.MissingPackManifest;
}

fn kind(value: u8) Error!Kind {
    return switch (value) {
        0 => .function,
        1 => .table,
        2 => .memory,
        3 => .global,
        else => Error.InvalidKind,
    };
}
fn role(value: u16) Error!Role {
    return switch (value) {
        1 => .program_pointer,
        2 => .generated_data_arena,
        3 => .generated_data_capacity,
        4 => .memory,
        5 => .stack_pointer,
        6 => .protected_dispatch,
        7 => .alloc,
        8 => .dealloc,
        9 => .context_create,
        10 => .context_destroy,
        11 => .invoke,
        12 => .initialize,
        13 => .coverage,
        else => Error.InvalidBinding,
    };
}
fn readU16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}
fn readU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) | (@as(u32, bytes[offset + 1]) << 8) | (@as(u32, bytes[offset + 2]) << 16) | (@as(u32, bytes[offset + 3]) << 24);
}
fn readUleb(bytes: []const u8, cursor: *usize) Error!usize {
    var value: usize = 0;
    var shift: u5 = 0;
    var count: u8 = 0;
    while (count < 5) : (count += 1) {
        if (cursor.* >= bytes.len) return Error.InvalidPack;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        value |= @as(usize, byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) return value;
        shift += 7;
    }
    return Error.InvalidPack;
}
fn add(lhs: anytype, rhs: anytype) Error!u32 {
    return std.math.add(u32, @intCast(lhs), @intCast(rhs)) catch Error.IntegerOverflow;
}
fn mul(lhs: u32, rhs: u32) Error!u32 {
    return std.math.mul(u32, lhs, rhs) catch Error.IntegerOverflow;
}

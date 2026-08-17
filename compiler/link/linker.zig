//! Bounded production linker for strict Luau AOT packages.
//!
//! The repository build resolves the selected VM/libc/provider universe into a normalized final-module
//! pack.  This linker consumes that pack plus the standard linking-v2 object emitted by the backend,
//! resolves the generated runtime imports against the pack's explicit symbol exports, relocates the
//! generated functions and data into the pack's bounded arena/table, strips the temporary symbol
//! exports, and emits a deterministic final core Wasm module.

const std = @import("std");
const runtime_profile = @import("luauc_runtime_profile_v1");

pub const Error = error{
    InvalidMagic,
    UnsupportedVersion,
    Truncated,
    IntegerOverflow,
    ResourceLimit,
    InvalidSectionOrder,
    DuplicateSection,
    UnsupportedSection,
    InvalidType,
    InvalidImport,
    InvalidFunction,
    InvalidTable,
    InvalidMemory,
    InvalidGlobal,
    InvalidExport,
    InvalidElement,
    InvalidCode,
    InvalidData,
    MissingLinkingSection,
    InvalidLinkingSection,
    MissingRelocationSection,
    InvalidRelocation,
    UnsupportedRelocation,
    UndefinedSymbol,
    DuplicateSymbol,
    TypeMismatch,
    MissingRuntimeSymbol,
    MissingRuntimeArena,
    ArenaOverflow,
    TableOverflow,
    InvalidFinalModule,
    OutOfMemory,
};

pub const Limits = struct {
    max_input_bytes: usize = 32 * 1024 * 1024,
    max_output_bytes: usize = 32 * 1024 * 1024,
    max_types: u32 = 4096,
    max_imports: u32 = 512,
    max_functions: u32 = 16_384,
    max_globals: u32 = 256,
    max_exports: u32 = 512,
    max_elements: u32 = 16_384,
    max_data_segments: u32 = 4096,
    max_symbols: u32 = 65_536,
    max_relocations: u32 = 1_000_000,
    max_table_entries: u32 = 10_000,
};

pub const LinkReport = struct {
    runtime_profile_sha256: [32]u8,
    runtime_pack_sha256: [32]u8,
    package_object_sha256: [32]u8,
    output_sha256: [32]u8,
    runtime_import_count: u32,
    runtime_function_count: u32,
    generated_function_count: u32,
    generated_data_bytes: u32,
    final_table_size: u32,
};

pub const Result = struct {
    bytes: []u8,
    report: LinkReport,
};

pub const LinkIdentity = struct {
    compiler_build_sha256: [32]u8 = .{0} ** 32,
    package_manifest_sha256: [32]u8 = .{0} ** 32,
};

const wasm_magic = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
const page_size: u64 = 65536;
const max_name_bytes: usize = 1024;

const section = struct {
    const custom: u8 = 0;
    const type_: u8 = 1;
    const import: u8 = 2;
    const function: u8 = 3;
    const table: u8 = 4;
    const memory: u8 = 5;
    const global: u8 = 6;
    const export_: u8 = 7;
    const start: u8 = 8;
    const element: u8 = 9;
    const code: u8 = 10;
    const data: u8 = 11;
    const data_count: u8 = 12;
};

const external_kind = struct {
    const function: u8 = 0;
    const table: u8 = 1;
    const memory: u8 = 2;
    const global: u8 = 3;
};

const relocation = struct {
    const function_index_leb: u8 = 0;
    const table_index_i32: u8 = 2;
    const memory_addr_sleb: u8 = 4;
    const memory_addr_i32: u8 = 5;
};

const symbol_flag_undefined: u32 = 0x10;

const Reader = struct {
    bytes: []const u8,
    cursor: usize = 0,

    fn done(self: *const Reader) bool {
        return self.cursor == self.bytes.len;
    }

    fn remaining(self: *const Reader) usize {
        return self.bytes.len - self.cursor;
    }

    fn readByte(self: *Reader) Error!u8 {
        if (self.cursor >= self.bytes.len)
            return Error.Truncated;
        defer self.cursor += 1;
        return self.bytes[self.cursor];
    }

    fn readBytes(self: *Reader, count: usize) Error![]const u8 {
        const finish = std.math.add(usize, self.cursor, count) catch return Error.IntegerOverflow;
        if (finish > self.bytes.len)
            return Error.Truncated;
        defer self.cursor = finish;
        return self.bytes[self.cursor..finish];
    }

    fn readSub(self: *Reader, count: usize) Error!Reader {
        return .{ .bytes = try self.readBytes(count) };
    }

    fn readUleb32(self: *Reader) Error!u32 {
        var result: u32 = 0;
        var shift: u6 = 0;
        var count: u8 = 0;
        while (count < 5) : (count += 1) {
            const byte = try self.readByte();
            if (shift == 28 and byte & 0x70 != 0)
                return Error.IntegerOverflow;
            result |= @as(u32, byte & 0x7f) << @intCast(shift);
            if (byte & 0x80 == 0)
                return result;
            shift += 7;
        }
        return Error.IntegerOverflow;
    }

    fn readSleb32(self: *Reader) Error!i32 {
        var result: u32 = 0;
        var shift: u6 = 0;
        var byte: u8 = 0;
        var count: u8 = 0;
        while (count < 5) : (count += 1) {
            byte = try self.readByte();
            result |= @as(u32, byte & 0x7f) << @intCast(shift);
            shift += 7;
            if (byte & 0x80 == 0) {
                if (shift < 32 and byte & 0x40 != 0)
                    result |= @as(u32, std.math.maxInt(u32)) << @as(u5, @intCast(shift));
                return @bitCast(result);
            }
        }
        if (byte & 0x80 != 0)
            return Error.IntegerOverflow;
        return @bitCast(result);
    }

    fn readName(self: *Reader) Error![]const u8 {
        const length = try self.readUleb32();
        if (length > max_name_bytes)
            return Error.ResourceLimit;
        const value = try self.readBytes(length);
        if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null)
            return Error.InvalidLinkingSection;
        return value;
    }
};

const RawSection = struct {
    id: u8,
    ordinal: u32,
    payload: []const u8,
    custom_name: ?[]const u8 = null,
    custom_payload: ?[]const u8 = null,
};

const CoreModule = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    sections: std.ArrayList(RawSection) = .empty,
    standard: [13]?usize = .{null} ** 13,

    fn parse(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!CoreModule {
        if (bytes.len > limits.max_input_bytes)
            return Error.ResourceLimit;
        if (bytes.len < wasm_magic.len or !std.mem.eql(u8, bytes[0..wasm_magic.len], &wasm_magic))
            return Error.InvalidMagic;

        var result = CoreModule{ .allocator = allocator, .bytes = bytes };
        errdefer result.deinit();
        var reader = Reader{ .bytes = bytes, .cursor = wasm_magic.len };
        var last_standard: u8 = 0;
        var ordinal: u32 = 0;
        while (!reader.done()) {
            const id = try reader.readByte();
            if (id > section.data_count)
                return Error.UnsupportedSection;
            const size = try reader.readUleb32();
            var section_reader = try reader.readSub(size);
            var raw = RawSection{ .id = id, .ordinal = ordinal, .payload = section_reader.bytes };
            if (id == section.custom) {
                raw.custom_name = try section_reader.readName();
                raw.custom_payload = section_reader.bytes[section_reader.cursor..];
            } else {
                if (result.standard[id] != null)
                    return Error.DuplicateSection;
                // Data-count is ordered before code/data even though its numeric id is 12.
                const order: u8 = if (id == section.data_count) 9 else if (id >= section.code) id + 1 else id;
                if (order < last_standard)
                    return Error.InvalidSectionOrder;
                last_standard = order;
                result.standard[id] = result.sections.items.len;
            }
            try result.sections.append(allocator, raw);
            ordinal = std.math.add(u32, ordinal, 1) catch return Error.IntegerOverflow;
        }
        return result;
    }

    fn deinit(self: *CoreModule) void {
        self.sections.deinit(self.allocator);
        self.* = undefined;
    }

    fn payload(self: *const CoreModule, id: u8) ?[]const u8 {
        const index = self.standard[id] orelse return null;
        return self.sections.items[index].payload;
    }

    fn custom(self: *const CoreModule, name: []const u8) ?[]const u8 {
        for (self.sections.items) |item|
            if (item.custom_name) |candidate|
                if (std.mem.eql(u8, candidate, name))
                    return item.custom_payload;
        return null;
    }
};

const TypeTable = struct {
    allocator: std.mem.Allocator,
    encodings: std.ArrayList([]const u8) = .empty,

    fn parse(allocator: std.mem.Allocator, payload: []const u8, limit: u32) Error!TypeTable {
        var result = TypeTable{ .allocator = allocator };
        errdefer result.deinit();
        var reader = Reader{ .bytes = payload };
        const count = try reader.readUleb32();
        if (count > limit)
            return Error.ResourceLimit;
        try result.encodings.ensureTotalCapacity(allocator, count);
        for (0..count) |_| {
            const start = reader.cursor;
            if (try reader.readByte() != 0x60)
                return Error.InvalidType;
            const params = try reader.readUleb32();
            if (params > 255)
                return Error.ResourceLimit;
            for (0..params) |_|
                try validateValueType(try reader.readByte());
            const results = try reader.readUleb32();
            if (results > 1)
                return Error.InvalidType;
            for (0..results) |_|
                try validateValueType(try reader.readByte());
            try result.encodings.append(allocator, payload[start..reader.cursor]);
        }
        if (!reader.done())
            return Error.InvalidType;
        return result;
    }

    fn deinit(self: *TypeTable) void {
        self.encodings.deinit(self.allocator);
        self.* = undefined;
    }
};

fn validateValueType(value: u8) Error!void {
    switch (value) {
        0x7f, 0x7e, 0x7d, 0x7c => {},
        else => return Error.InvalidType,
    }
}

const Import = struct {
    module: []const u8,
    name: []const u8,
    kind: u8,
    type_index: u32 = 0,
};

const Imports = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Import) = .empty,
    functions: std.ArrayList(Import) = .empty,
    memory_count: u32 = 0,
    table_count: u32 = 0,
    global_count: u32 = 0,

    fn parse(allocator: std.mem.Allocator, payload: []const u8, limit: u32) Error!Imports {
        var result = Imports{ .allocator = allocator };
        errdefer result.deinit();
        var reader = Reader{ .bytes = payload };
        const count = try reader.readUleb32();
        if (count > limit)
            return Error.ResourceLimit;
        for (0..count) |_| {
            var item = Import{
                .module = try reader.readName(),
                .name = try reader.readName(),
                .kind = try reader.readByte(),
            };
            switch (item.kind) {
                external_kind.function => {
                    item.type_index = try reader.readUleb32();
                    try result.functions.append(allocator, item);
                },
                external_kind.table => {
                    if (try reader.readByte() != 0x70)
                        return Error.InvalidImport;
                    _ = try readLimits(&reader);
                    result.table_count += 1;
                },
                external_kind.memory => {
                    _ = try readLimits(&reader);
                    result.memory_count += 1;
                },
                external_kind.global => {
                    try validateValueType(try reader.readByte());
                    const mutable = try reader.readByte();
                    if (mutable > 1)
                        return Error.InvalidImport;
                    result.global_count += 1;
                },
                else => return Error.InvalidImport,
            }
            try result.items.append(allocator, item);
        }
        if (!reader.done())
            return Error.InvalidImport;
        return result;
    }

    fn deinit(self: *Imports) void {
        self.items.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.* = undefined;
    }
};

const LimitsValue = struct {
    minimum: u32,
    maximum: ?u32,
};

fn readLimits(reader: *Reader) Error!LimitsValue {
    const flags = try reader.readUleb32();
    if (flags > 1)
        return Error.InvalidMemory;
    const minimum = try reader.readUleb32();
    const maximum = if (flags == 1) try reader.readUleb32() else null;
    if (maximum) |value|
        if (value < minimum)
            return Error.InvalidMemory;
    return .{ .minimum = minimum, .maximum = maximum };
}

fn parseIndexVector(allocator: std.mem.Allocator, payload: []const u8, limit: u32, comptime invalid: Error) Error!std.ArrayList(u32) {
    var result: std.ArrayList(u32) = .empty;
    errdefer result.deinit(allocator);
    var reader = Reader{ .bytes = payload };
    const count = try reader.readUleb32();
    if (count > limit)
        return Error.ResourceLimit;
    try result.ensureTotalCapacity(allocator, count);
    for (0..count) |_|
        try result.append(allocator, try reader.readUleb32());
    if (!reader.done())
        return invalid;
    return result;
}

const Export = struct {
    name: []const u8,
    kind: u8,
    index: u32,
};

fn parseExports(allocator: std.mem.Allocator, payload: []const u8, limit: u32) Error!std.ArrayList(Export) {
    var result: std.ArrayList(Export) = .empty;
    errdefer result.deinit(allocator);
    var reader = Reader{ .bytes = payload };
    const count = try reader.readUleb32();
    if (count > limit)
        return Error.ResourceLimit;
    for (0..count) |_| {
        const item = Export{ .name = try reader.readName(), .kind = try reader.readByte(), .index = try reader.readUleb32() };
        if (item.kind > external_kind.global)
            return Error.InvalidExport;
        for (result.items) |prior|
            if (std.mem.eql(u8, prior.name, item.name))
                return Error.DuplicateSymbol;
        try result.append(allocator, item);
    }
    if (!reader.done())
        return Error.InvalidExport;
    return result;
}

const Global = struct {
    value_type: u8,
    mutable: bool,
    i32_value: ?i32,
    raw: []const u8,
};

fn parseGlobals(allocator: std.mem.Allocator, payload: []const u8, limit: u32) Error!std.ArrayList(Global) {
    var result: std.ArrayList(Global) = .empty;
    errdefer result.deinit(allocator);
    var reader = Reader{ .bytes = payload };
    const count = try reader.readUleb32();
    if (count > limit)
        return Error.ResourceLimit;
    for (0..count) |_| {
        const start = reader.cursor;
        const value_type = try reader.readByte();
        try validateValueType(value_type);
        const mutable_byte = try reader.readByte();
        if (mutable_byte > 1)
            return Error.InvalidGlobal;
        var i32_value: ?i32 = null;
        const opcode = try reader.readByte();
        if (opcode == 0x41)
            i32_value = try reader.readSleb32()
        else
            return Error.InvalidGlobal;
        if (try reader.readByte() != 0x0b)
            return Error.InvalidGlobal;
        try result.append(allocator, .{
            .value_type = value_type,
            .mutable = mutable_byte == 1,
            .i32_value = i32_value,
            .raw = payload[start..reader.cursor],
        });
    }
    if (!reader.done())
        return Error.InvalidGlobal;
    return result;
}

const Table = struct {
    minimum: u32,
    maximum: ?u32,
};

fn parseSingleTable(payload: []const u8) Error!Table {
    var reader = Reader{ .bytes = payload };
    if (try reader.readUleb32() != 1 or try reader.readByte() != 0x70)
        return Error.InvalidTable;
    const limits = try readLimits(&reader);
    if (!reader.done())
        return Error.InvalidTable;
    return .{ .minimum = limits.minimum, .maximum = limits.maximum };
}

fn parseSingleMemory(payload: []const u8) Error!LimitsValue {
    var reader = Reader{ .bytes = payload };
    if (try reader.readUleb32() != 1)
        return Error.InvalidMemory;
    const limits = try readLimits(&reader);
    if (!reader.done())
        return Error.InvalidMemory;
    return limits;
}

const Body = struct {
    payload_offset: u32,
    bytes: []u8,
};

fn parseBodies(allocator: std.mem.Allocator, payload: []const u8, limit: u32) Error!std.ArrayList(Body) {
    var result: std.ArrayList(Body) = .empty;
    errdefer {
        for (result.items) |item| allocator.free(item.bytes);
        result.deinit(allocator);
    }
    var reader = Reader{ .bytes = payload };
    const count = try reader.readUleb32();
    if (count > limit)
        return Error.ResourceLimit;
    for (0..count) |_| {
        const size = try reader.readUleb32();
        const start: u32 = @intCast(reader.cursor);
        const bytes = try allocator.dupe(u8, try reader.readBytes(size));
        try result.append(allocator, .{ .payload_offset = start, .bytes = bytes });
    }
    if (!reader.done())
        return Error.InvalidCode;
    return result;
}

fn deinitBodies(allocator: std.mem.Allocator, bodies: *std.ArrayList(Body)) void {
    for (bodies.items) |item| allocator.free(item.bytes);
    bodies.deinit(allocator);
}

const DataSegment = struct {
    memory_offset: u32,
    payload_offset: u32,
    bytes: []u8,
};

fn parseData(allocator: std.mem.Allocator, payload: []const u8, limit: u32) Error!std.ArrayList(DataSegment) {
    var result: std.ArrayList(DataSegment) = .empty;
    errdefer deinitData(allocator, &result);
    var reader = Reader{ .bytes = payload };
    const count = try reader.readUleb32();
    if (count > limit)
        return Error.ResourceLimit;
    for (0..count) |_| {
        const flags = try reader.readUleb32();
        var memory_index: u32 = 0;
        if (flags == 2)
            memory_index = try reader.readUleb32()
        else if (flags != 0)
            return Error.InvalidData;
        if (memory_index != 0 or try reader.readByte() != 0x41)
            return Error.InvalidData;
        const signed_offset = try reader.readSleb32();
        if (signed_offset < 0 or try reader.readByte() != 0x0b)
            return Error.InvalidData;
        const size = try reader.readUleb32();
        const bytes_start: u32 = @intCast(reader.cursor);
        const bytes = try allocator.dupe(u8, try reader.readBytes(size));
        try result.append(allocator, .{
            .memory_offset = @intCast(signed_offset),
            .payload_offset = bytes_start,
            .bytes = bytes,
        });
    }
    if (!reader.done())
        return Error.InvalidData;
    return result;
}

fn deinitData(allocator: std.mem.Allocator, segments: *std.ArrayList(DataSegment)) void {
    for (segments.items) |item| allocator.free(item.bytes);
    segments.deinit(allocator);
}

const Symbol = union(enum) {
    function: struct {
        flags: u32,
        object_index: u32,
        name: []const u8,
    },
    data: struct {
        flags: u32,
        name: []const u8,
        segment_index: u32,
        offset: u32,
        size: u32,
    },
};

const SegmentInfo = struct {
    name: []const u8,
    alignment_log2: u32,
    flags: u32,
};

const Linking = struct {
    allocator: std.mem.Allocator,
    symbols: std.ArrayList(Symbol) = .empty,
    segments: std.ArrayList(SegmentInfo) = .empty,

    fn parse(allocator: std.mem.Allocator, payload: []const u8, imports: *const Imports, limits: Limits) Error!Linking {
        var result = Linking{ .allocator = allocator };
        errdefer result.deinit();
        var reader = Reader{ .bytes = payload };
        if (try reader.readUleb32() != 2)
            return Error.UnsupportedVersion;
        var saw_symbols = false;
        while (!reader.done()) {
            const id = try reader.readByte();
            const size = try reader.readUleb32();
            var subsection = try reader.readSub(size);
            switch (id) {
                8 => {
                    if (saw_symbols)
                        return Error.InvalidLinkingSection;
                    saw_symbols = true;
                    const count = try subsection.readUleb32();
                    if (count > limits.max_symbols)
                        return Error.ResourceLimit;
                    for (0..count) |_| {
                        const kind = try subsection.readByte();
                        const flags = try subsection.readUleb32();
                        switch (kind) {
                            0 => {
                                const index = try subsection.readUleb32();
                                const is_undefined = flags & symbol_flag_undefined != 0;
                                const name = if (is_undefined) blk: {
                                    if (index >= imports.functions.items.len)
                                        return Error.InvalidLinkingSection;
                                    break :blk imports.functions.items[index].name;
                                } else try subsection.readName();
                                try result.symbols.append(allocator, .{ .function = .{
                                    .flags = flags,
                                    .object_index = index,
                                    .name = name,
                                } });
                            },
                            1 => {
                                const name = try subsection.readName();
                                if (flags & symbol_flag_undefined != 0)
                                    return Error.InvalidLinkingSection;
                                try result.symbols.append(allocator, .{ .data = .{
                                    .flags = flags,
                                    .name = name,
                                    .segment_index = try subsection.readUleb32(),
                                    .offset = try subsection.readUleb32(),
                                    .size = try subsection.readUleb32(),
                                } });
                            },
                            else => return Error.InvalidLinkingSection,
                        }
                    }
                },
                5 => {
                    const count = try subsection.readUleb32();
                    if (count > limits.max_data_segments)
                        return Error.ResourceLimit;
                    for (0..count) |_|
                        try result.segments.append(allocator, .{
                            .name = try subsection.readName(),
                            .alignment_log2 = try subsection.readUleb32(),
                            .flags = try subsection.readUleb32(),
                        });
                },
                else => return Error.InvalidLinkingSection,
            }
            if (!subsection.done())
                return Error.InvalidLinkingSection;
        }
        if (!saw_symbols)
            return Error.MissingLinkingSection;
        return result;
    }

    fn deinit(self: *Linking) void {
        self.symbols.deinit(self.allocator);
        self.segments.deinit(self.allocator);
        self.* = undefined;
    }
};

const Relocation = struct {
    kind: u8,
    offset: u32,
    index: u32,
    addend: i32,
};

fn parseRelocations(allocator: std.mem.Allocator, payload: []const u8, expected_section_ordinal: u32, limits: Limits) Error!std.ArrayList(Relocation) {
    var result: std.ArrayList(Relocation) = .empty;
    errdefer result.deinit(allocator);
    var reader = Reader{ .bytes = payload };
    if (try reader.readUleb32() != expected_section_ordinal)
        return Error.InvalidRelocation;
    const count = try reader.readUleb32();
    if (count > limits.max_relocations)
        return Error.ResourceLimit;
    for (0..count) |_| {
        const kind = try reader.readByte();
        const offset = try reader.readUleb32();
        const index = try reader.readUleb32();
        const addend = switch (kind) {
            relocation.function_index_leb, relocation.table_index_i32 => 0,
            relocation.memory_addr_sleb, relocation.memory_addr_i32 => try reader.readSleb32(),
            else => return Error.UnsupportedRelocation,
        };
        try result.append(allocator, .{ .kind = kind, .offset = offset, .index = index, .addend = addend });
    }
    if (!reader.done())
        return Error.InvalidRelocation;
    return result;
}

const ObjectModel = struct {
    allocator: std.mem.Allocator,
    module: CoreModule,
    types: TypeTable,
    imports: Imports,
    function_types: std.ArrayList(u32),
    bodies: std.ArrayList(Body),
    data: std.ArrayList(DataSegment),
    linking: Linking,
    code_relocations: std.ArrayList(Relocation),
    data_relocations: std.ArrayList(Relocation),
    element_functions: std.ArrayList(u32),

    fn parse(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!ObjectModel {
        var module = try CoreModule.parse(allocator, bytes, limits);
        errdefer module.deinit();
        const type_payload = module.payload(section.type_) orelse return Error.InvalidType;
        var types = try TypeTable.parse(allocator, type_payload, limits.max_types);
        errdefer types.deinit();
        const import_payload = module.payload(section.import) orelse return Error.InvalidImport;
        var imports = try Imports.parse(allocator, import_payload, limits.max_imports);
        errdefer imports.deinit();
        var function_types = try parseIndexVector(allocator, module.payload(section.function) orelse return Error.InvalidFunction, limits.max_functions, Error.InvalidFunction);
        errdefer function_types.deinit(allocator);
        var bodies = try parseBodies(allocator, module.payload(section.code) orelse return Error.InvalidCode, limits.max_functions);
        errdefer deinitBodies(allocator, &bodies);
        if (bodies.items.len != function_types.items.len)
            return Error.InvalidCode;
        var data = try parseData(allocator, module.payload(section.data) orelse return Error.InvalidData, limits.max_data_segments);
        errdefer deinitData(allocator, &data);
        var linking = try Linking.parse(allocator, module.custom("linking") orelse return Error.MissingLinkingSection, &imports, limits);
        errdefer linking.deinit();
        const code_index = module.sections.items[module.standard[section.code].?].ordinal;
        const data_index = module.sections.items[module.standard[section.data].?].ordinal;
        var code_relocations = try parseRelocations(allocator, module.custom("reloc.CODE") orelse return Error.MissingRelocationSection, code_index, limits);
        errdefer code_relocations.deinit(allocator);
        var data_relocations = try parseRelocations(allocator, module.custom("reloc.DATA") orelse return Error.MissingRelocationSection, data_index, limits);
        errdefer data_relocations.deinit(allocator);
        var element_functions = try parseObjectElement(allocator, module.payload(section.element), imports.functions.items.len, function_types.items.len, limits);
        errdefer element_functions.deinit(allocator);

        if (imports.memory_count != 1 or imports.table_count != 1 or imports.global_count != 0)
            return Error.InvalidImport;
        if (module.payload(section.table) != null or module.payload(section.memory) != null or module.payload(section.global) != null or
            module.payload(section.export_) != null or module.payload(section.start) != null)
            return Error.UnsupportedSection;
        if (linking.segments.items.len != data.items.len)
            return Error.InvalidLinkingSection;
        for (function_types.items) |type_index|
            if (type_index >= types.encodings.items.len)
                return Error.InvalidType;
        for (linking.symbols.items) |symbol_value| switch (symbol_value) {
            .function => |function_symbol| {
                if (function_symbol.object_index >= imports.functions.items.len + function_types.items.len)
                    return Error.InvalidLinkingSection;
            },
            .data => |data_symbol| {
                if (data_symbol.segment_index >= data.items.len)
                    return Error.InvalidLinkingSection;
                const finish = std.math.add(u32, data_symbol.offset, data_symbol.size) catch return Error.IntegerOverflow;
                if (finish > data.items[data_symbol.segment_index].bytes.len)
                    return Error.InvalidLinkingSection;
            },
        };
        return .{
            .allocator = allocator,
            .module = module,
            .types = types,
            .imports = imports,
            .function_types = function_types,
            .bodies = bodies,
            .data = data,
            .linking = linking,
            .code_relocations = code_relocations,
            .data_relocations = data_relocations,
            .element_functions = element_functions,
        };
    }

    fn deinit(self: *ObjectModel) void {
        self.element_functions.deinit(self.allocator);
        self.data_relocations.deinit(self.allocator);
        self.code_relocations.deinit(self.allocator);
        self.linking.deinit();
        deinitData(self.allocator, &self.data);
        deinitBodies(self.allocator, &self.bodies);
        self.function_types.deinit(self.allocator);
        self.imports.deinit();
        self.types.deinit();
        self.module.deinit();
        self.* = undefined;
    }
};

fn parseObjectElement(allocator: std.mem.Allocator, payload_optional: ?[]const u8, import_count: usize, defined_count: usize, limits: Limits) Error!std.ArrayList(u32) {
    var result: std.ArrayList(u32) = .empty;
    errdefer result.deinit(allocator);
    const payload = payload_optional orelse {
        if (defined_count != 0)
            return result;
        return result;
    };
    var reader = Reader{ .bytes = payload };
    if (try reader.readUleb32() != 1 or try reader.readUleb32() != 0 or try reader.readByte() != 0x41 or try reader.readSleb32() != 1 or try reader.readByte() != 0x0b)
        return Error.InvalidElement;
    const count = try reader.readUleb32();
    if (count > limits.max_elements or count != defined_count)
        return Error.InvalidElement;
    for (0..count) |index| {
        const function_index = try reader.readUleb32();
        const expected = std.math.add(usize, import_count, index) catch return Error.IntegerOverflow;
        if (function_index != expected)
            return Error.InvalidElement;
        try result.append(allocator, function_index);
    }
    if (!reader.done())
        return Error.InvalidElement;
    return result;
}

const PackModel = struct {
    allocator: std.mem.Allocator,
    module: CoreModule,
    types: TypeTable,
    imports: Imports,
    function_types: std.ArrayList(u32),
    globals: std.ArrayList(Global),
    exports: std.ArrayList(Export),
    table: Table,
    memory: LimitsValue,
    bodies: std.ArrayList(Body),
    data: std.ArrayList(DataSegment),
    element_payload: []const u8,
    element_count: u32,

    fn parse(allocator: std.mem.Allocator, bytes: []const u8, profile: runtime_profile.Profile, limits: Limits) Error!PackModel {
        var module = try CoreModule.parse(allocator, bytes, limits);
        errdefer module.deinit();
        var types = try TypeTable.parse(allocator, module.payload(section.type_) orelse return Error.InvalidType, limits.max_types);
        errdefer types.deinit();
        var imports = try Imports.parse(allocator, module.payload(section.import) orelse return Error.InvalidImport, limits.max_imports);
        errdefer imports.deinit();
        var function_types = try parseIndexVector(allocator, module.payload(section.function) orelse return Error.InvalidFunction, limits.max_functions, Error.InvalidFunction);
        errdefer function_types.deinit(allocator);
        var globals = try parseGlobals(allocator, module.payload(section.global) orelse return Error.InvalidGlobal, limits.max_globals);
        errdefer globals.deinit(allocator);
        var exports = try parseExports(allocator, module.payload(section.export_) orelse return Error.InvalidExport, limits.max_exports);
        errdefer exports.deinit(allocator);
        const table = try parseSingleTable(module.payload(section.table) orelse return Error.InvalidTable);
        const memory = try parseSingleMemory(module.payload(section.memory) orelse return Error.InvalidMemory);
        var bodies = try parseBodies(allocator, module.payload(section.code) orelse return Error.InvalidCode, limits.max_functions);
        errdefer deinitBodies(allocator, &bodies);
        if (bodies.items.len != function_types.items.len)
            return Error.InvalidCode;
        var data = try parseData(allocator, module.payload(section.data) orelse return Error.InvalidData, limits.max_data_segments);
        errdefer deinitData(allocator, &data);
        const element_payload = module.payload(section.element) orelse return Error.InvalidElement;
        var element_reader = Reader{ .bytes = element_payload };
        const element_count = try element_reader.readUleb32();
        if (element_count == 0 or element_count > limits.max_elements)
            return Error.InvalidElement;

        if (imports.memory_count != 0 or imports.table_count != 0 or imports.global_count != 0)
            return Error.InvalidImport;
        if (imports.items.items.len != profile.import_count)
            return Error.InvalidImport;
        for (imports.items.items) |item|
            if (!profile.allowsHostImport(item.module, item.name, item.kind, item.type_index))
                return Error.InvalidImport;
        for (function_types.items) |type_index|
            if (type_index >= types.encodings.items.len)
                return Error.InvalidType;
        if (module.payload(section.start) != null or module.payload(section.data_count) != null)
            return Error.UnsupportedSection;
        if (profile.feature_mask != 0 or memory.minimum != profile.memory_minimum or
            (memory.maximum orelse memory.minimum) != profile.memory_maximum or
            table.minimum != profile.table_minimum or (table.maximum orelse table.minimum) != profile.table_maximum)
            return Error.InvalidMemory;
        var profile_index: u32 = 0;
        while (profile_index < profile.runtime_symbol_count) : (profile_index += 1) {
            const symbol_value = profile.runtimeSymbol(profile_index) catch return Error.InvalidExport;
            const exported = findExport(exports.items, symbol_value.name, @intFromEnum(symbol_value.kind)) catch return Error.MissingRuntimeSymbol;
            if (exported.index < imports.functions.items.len) {
                if (imports.functions.items[exported.index].type_index != symbol_value.type_index) return Error.TypeMismatch;
            } else {
                const defined = exported.index - @as(u32, @intCast(imports.functions.items.len));
                if (defined >= function_types.items.len or function_types.items[defined] != symbol_value.type_index) return Error.TypeMismatch;
            }
        }
        profile_index = 0;
        while (profile_index < profile.export_count) : (profile_index += 1) {
            const retained = profile.retainedExport(profile_index) catch return Error.InvalidExport;
            _ = findExport(exports.items, retained.name, @intFromEnum(retained.kind)) catch return Error.MissingRuntimeSymbol;
        }
        return .{
            .allocator = allocator,
            .module = module,
            .types = types,
            .imports = imports,
            .function_types = function_types,
            .globals = globals,
            .exports = exports,
            .table = table,
            .memory = memory,
            .bodies = bodies,
            .data = data,
            .element_payload = element_payload,
            .element_count = element_count,
        };
    }

    fn deinit(self: *PackModel) void {
        deinitData(self.allocator, &self.data);
        deinitBodies(self.allocator, &self.bodies);
        self.exports.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        self.function_types.deinit(self.allocator);
        self.imports.deinit();
        self.types.deinit();
        self.module.deinit();
        self.* = undefined;
    }
};

fn functionType(types: *const TypeTable, imports: *const Imports, defined_types: []const u32, function_index: u32) Error![]const u8 {
    const type_index = if (function_index < imports.functions.items.len)
        imports.functions.items[function_index].type_index
    else blk: {
        const defined_index = function_index - @as(u32, @intCast(imports.functions.items.len));
        if (defined_index >= defined_types.len)
            return Error.InvalidFunction;
        break :blk defined_types[defined_index];
    };
    if (type_index >= types.encodings.items.len)
        return Error.InvalidType;
    return types.encodings.items[type_index];
}

fn findExport(exports: []const Export, name: []const u8, kind: u8) Error!Export {
    for (exports) |item|
        if (item.kind == kind and std.mem.eql(u8, item.name, name))
            return item;
    return Error.MissingRuntimeSymbol;
}

fn globalAddress(pack: *const PackModel, name: []const u8) Error!u32 {
    const item = try findExport(pack.exports.items, name, external_kind.global);
    if (item.index >= pack.globals.items.len)
        return Error.InvalidExport;
    const value = pack.globals.items[item.index].i32_value orelse return Error.InvalidGlobal;
    if (value < 0)
        return Error.InvalidGlobal;
    return @intCast(value);
}

fn memorySliceAt(segments: []DataSegment, address: u32, size: u32) Error![]u8 {
    const finish = std.math.add(u32, address, size) catch return Error.IntegerOverflow;
    for (segments) |segment| {
        const segment_finish = std.math.add(u32, segment.memory_offset, @intCast(segment.bytes.len)) catch return Error.IntegerOverflow;
        if (address >= segment.memory_offset and finish <= segment_finish) {
            const start = address - segment.memory_offset;
            return segment.bytes[start .. start + size];
        }
    }
    return Error.MissingRuntimeArena;
}

fn readMemoryU32(segments: []DataSegment, address: u32) Error!u32 {
    return readU32Little(try memorySliceAt(segments, address, 4));
}

fn readU32Little(bytes: []const u8) u32 {
    std.debug.assert(bytes.len == 4);
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn writeU32Little(bytes: []u8, value: u32) void {
    std.debug.assert(bytes.len == 4);
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
    bytes[2] = @truncate(value >> 16);
    bytes[3] = @truncate(value >> 24);
}

const Resolved = struct {
    allocator: std.mem.Allocator,
    type_map: []u32,
    function_map: []u32,
    table_map: []u32,
    data_addresses: []u32,
    appended_types: std.ArrayList([]const u8) = .empty,
    table_base: u32,
    arena_base: u32,
    arena_used: u32,
    program_address: u32,

    fn deinit(self: *Resolved) void {
        self.appended_types.deinit(self.allocator);
        self.allocator.free(self.data_addresses);
        self.allocator.free(self.table_map);
        self.allocator.free(self.function_map);
        self.allocator.free(self.type_map);
        self.* = undefined;
    }
};

fn rewriteObjectImportModules(object: *ObjectModel, generated_module: []const u8) void {
    for (object.imports.items.items) |*item|
        item.module = generated_module;
    for (object.imports.functions.items) |*item|
        item.module = generated_module;
}

fn resolve(allocator: std.mem.Allocator, pack: *const PackModel, object: *ObjectModel, profile: runtime_profile.Profile, limits: Limits) Error!Resolved {
    rewriteObjectImportModules(object, profile.generatedRuntimeModule());
    const arena_base = try globalAddress(pack, profile.bindingName(.generated_data_arena, .global) catch return Error.MissingRuntimeArena);
    const capacity_address = try globalAddress(pack, profile.bindingName(.generated_data_capacity, .global) catch return Error.MissingRuntimeArena);
    const arena_capacity = try readMemoryU32(pack.data.items, capacity_address);
    if (arena_capacity == 0)
        return Error.MissingRuntimeArena;
    const arena_finish = std.math.add(u64, arena_base, arena_capacity) catch return Error.IntegerOverflow;
    if (arena_finish > @as(u64, pack.memory.minimum) * page_size)
        return Error.MissingRuntimeArena;

    const type_map = try allocator.alloc(u32, object.types.encodings.items.len);
    errdefer allocator.free(type_map);
    var appended_types: std.ArrayList([]const u8) = .empty;
    errdefer appended_types.deinit(allocator);
    for (object.types.encodings.items, 0..) |encoding, object_index| {
        var mapped: ?u32 = null;
        for (pack.types.encodings.items, 0..) |candidate, index|
            if (std.mem.eql(u8, encoding, candidate)) {
                mapped = @intCast(index);
                break;
            };
        if (mapped == null)
            for (appended_types.items, 0..) |candidate, index|
                if (std.mem.eql(u8, encoding, candidate)) {
                    mapped = @intCast(pack.types.encodings.items.len + index);
                    break;
                };
        if (mapped == null) {
            const total = std.math.add(usize, pack.types.encodings.items.len, appended_types.items.len) catch return Error.IntegerOverflow;
            if (total >= limits.max_types)
                return Error.ResourceLimit;
            mapped = @intCast(total);
            try appended_types.append(allocator, encoding);
        }
        type_map[object_index] = mapped.?;
    }

    const object_function_count = std.math.add(usize, object.imports.functions.items.len, object.function_types.items.len) catch return Error.IntegerOverflow;
    const function_map = try allocator.alloc(u32, object_function_count);
    errdefer allocator.free(function_map);
    for (object.imports.functions.items, 0..) |item, index| {
        const pack_export = try findExport(pack.exports.items, item.name, external_kind.function);
        const object_signature = try functionType(&object.types, &object.imports, object.function_types.items, @intCast(index));
        const pack_signature = try functionType(&pack.types, &pack.imports, pack.function_types.items, pack_export.index);
        if (!std.mem.eql(u8, object_signature, pack_signature))
            return Error.TypeMismatch;
        function_map[index] = pack_export.index;
    }
    const pack_function_count = std.math.add(usize, pack.imports.functions.items.len, pack.function_types.items.len) catch return Error.IntegerOverflow;
    const final_function_count = std.math.add(usize, pack_function_count, object.function_types.items.len) catch return Error.IntegerOverflow;
    if (final_function_count > limits.max_functions)
        return Error.ResourceLimit;
    for (object.function_types.items, 0..) |_, index|
        function_map[object.imports.functions.items.len + index] = @intCast(pack_function_count + index);

    const table_map = try allocator.alloc(u32, object_function_count);
    errdefer allocator.free(table_map);
    @memset(table_map, std.math.maxInt(u32));
    const table_base = pack.table.minimum;
    const table_finish = std.math.add(u32, table_base, @intCast(object.element_functions.items.len)) catch return Error.IntegerOverflow;
    if (table_finish > limits.max_table_entries)
        return Error.TableOverflow;
    for (object.element_functions.items, 0..) |object_index, slot|
        table_map[object_index] = std.math.add(u32, table_base, @intCast(slot)) catch return Error.IntegerOverflow;

    const data_addresses = try allocator.alloc(u32, object.data.items.len);
    errdefer allocator.free(data_addresses);
    var arena_used: u32 = 0;
    for (object.data.items, 0..) |segment_value, index| {
        const end = std.math.add(u32, segment_value.memory_offset, @intCast(segment_value.bytes.len)) catch return Error.IntegerOverflow;
        arena_used = @max(arena_used, end);
        data_addresses[index] = std.math.add(u32, arena_base, segment_value.memory_offset) catch return Error.IntegerOverflow;
    }
    if (arena_used > arena_capacity)
        return Error.ArenaOverflow;

    var program_address: ?u32 = null;
    for (object.linking.symbols.items) |symbol_value| switch (symbol_value) {
        .data => |data_symbol| if (std.mem.eql(u8, data_symbol.name, "luauc_runtime_v1_program")) {
            if (program_address != null or data_symbol.segment_index >= data_addresses.len)
                return Error.DuplicateSymbol;
            program_address = std.math.add(u32, data_addresses[data_symbol.segment_index], data_symbol.offset) catch return Error.IntegerOverflow;
        },
        else => {},
    };
    return .{
        .allocator = allocator,
        .type_map = type_map,
        .function_map = function_map,
        .table_map = table_map,
        .data_addresses = data_addresses,
        .appended_types = appended_types,
        .table_base = table_base,
        .arena_base = arena_base,
        .arena_used = arena_used,
        .program_address = program_address orelse return Error.UndefinedSymbol,
    };
}

fn symbolFunction(object: *const ObjectModel, resolved: *const Resolved, index: u32) Error!u32 {
    if (index >= object.linking.symbols.items.len)
        return Error.InvalidRelocation;
    return switch (object.linking.symbols.items[index]) {
        .function => |item| if (item.object_index < resolved.function_map.len) resolved.function_map[item.object_index] else Error.InvalidRelocation,
        else => Error.InvalidRelocation,
    };
}

fn symbolTableSlot(object: *const ObjectModel, resolved: *const Resolved, index: u32) Error!u32 {
    if (index >= object.linking.symbols.items.len)
        return Error.InvalidRelocation;
    return switch (object.linking.symbols.items[index]) {
        .function => |item| blk: {
            if (item.object_index >= resolved.table_map.len)
                return Error.InvalidRelocation;
            const value = resolved.table_map[item.object_index];
            if (value == std.math.maxInt(u32))
                return Error.UndefinedSymbol;
            break :blk value;
        },
        else => Error.InvalidRelocation,
    };
}

fn symbolMemoryAddress(object: *const ObjectModel, resolved: *const Resolved, index: u32, addend: i32) Error!u32 {
    if (index >= object.linking.symbols.items.len)
        return Error.InvalidRelocation;
    return switch (object.linking.symbols.items[index]) {
        .data => |item| blk: {
            if (item.segment_index >= resolved.data_addresses.len)
                return Error.InvalidRelocation;
            const base = std.math.add(u32, resolved.data_addresses[item.segment_index], item.offset) catch return Error.IntegerOverflow;
            const signed = std.math.add(i64, base, addend) catch return Error.IntegerOverflow;
            if (signed < 0 or signed > std.math.maxInt(u32))
                return Error.IntegerOverflow;
            break :blk @intCast(signed);
        },
        else => Error.InvalidRelocation,
    };
}

fn locateBody(bodies: []Body, offset: u32, width: u32) Error![]u8 {
    const finish = std.math.add(u32, offset, width) catch return Error.IntegerOverflow;
    for (bodies) |body| {
        const body_finish = std.math.add(u32, body.payload_offset, @intCast(body.bytes.len)) catch return Error.IntegerOverflow;
        if (offset >= body.payload_offset and finish <= body_finish) {
            const local = offset - body.payload_offset;
            return body.bytes[local .. local + width];
        }
    }
    return Error.InvalidRelocation;
}

fn locateData(data: []DataSegment, offset: u32, width: u32) Error![]u8 {
    const finish = std.math.add(u32, offset, width) catch return Error.IntegerOverflow;
    for (data) |segment_value| {
        const segment_finish = std.math.add(u32, segment_value.payload_offset, @intCast(segment_value.bytes.len)) catch return Error.IntegerOverflow;
        if (offset >= segment_value.payload_offset and finish <= segment_finish) {
            const local = offset - segment_value.payload_offset;
            return segment_value.bytes[local .. local + width];
        }
    }
    return Error.InvalidRelocation;
}

fn writePaddedUleb32(destination: []u8, value: u32) Error!void {
    if (destination.len != 5)
        return Error.InvalidRelocation;
    destination[0] = @truncate(value | 0x80);
    destination[1] = @truncate((value >> 7) | 0x80);
    destination[2] = @truncate((value >> 14) | 0x80);
    destination[3] = @truncate((value >> 21) | 0x80);
    destination[4] = @truncate(value >> 28);
}

fn writePaddedSleb32(destination: []u8, value: i32) Error!void {
    if (destination.len != 5)
        return Error.InvalidRelocation;
    const bits: u32 = @bitCast(value);
    destination[0] = @truncate(bits | 0x80);
    destination[1] = @truncate((bits >> 7) | 0x80);
    destination[2] = @truncate((bits >> 14) | 0x80);
    destination[3] = @truncate((bits >> 21) | 0x80);
    destination[4] = @truncate(((bits >> 28) & 0x0f) | if (value < 0) @as(u32, 0x70) else 0);
}

fn applyRelocations(object: *ObjectModel, resolved: *const Resolved) Error!void {
    for (object.code_relocations.items) |item| switch (item.kind) {
        relocation.function_index_leb => try writePaddedUleb32(try locateBody(object.bodies.items, item.offset, 5), try symbolFunction(object, resolved, item.index)),
        relocation.memory_addr_sleb => {
            const address = try symbolMemoryAddress(object, resolved, item.index, item.addend);
            try writePaddedSleb32(try locateBody(object.bodies.items, item.offset, 5), @bitCast(address));
        },
        else => return Error.UnsupportedRelocation,
    };
    for (object.data_relocations.items) |item| switch (item.kind) {
        relocation.table_index_i32 => writeU32Little(try locateData(object.data.items, item.offset, 4), try symbolTableSlot(object, resolved, item.index)),
        relocation.memory_addr_i32 => writeU32Little(try locateData(object.data.items, item.offset, 4), try symbolMemoryAddress(object, resolved, item.index, item.addend)),
        else => return Error.UnsupportedRelocation,
    };
}

fn appendUleb(output: *std.ArrayList(u8), allocator: std.mem.Allocator, input: anytype) !void {
    var value: u64 = @intCast(input);
    while (true) {
        const byte: u8 = @truncate(value & 0x7f);
        value >>= 7;
        try output.append(allocator, if (value == 0) byte else byte | 0x80);
        if (value == 0)
            return;
    }
}

fn appendSleb(output: *std.ArrayList(u8), allocator: std.mem.Allocator, input: i32) !void {
    var value = input;
    while (true) {
        const byte: u8 = @truncate(@as(u32, @bitCast(value)) & 0x7f);
        value >>= 7;
        const done = (value == 0 and byte & 0x40 == 0) or (value == -1 and byte & 0x40 != 0);
        try output.append(allocator, if (done) byte else byte | 0x80);
        if (done)
            return;
    }
}

fn appendName(output: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8) !void {
    try appendUleb(output, allocator, name.len);
    try output.appendSlice(allocator, name);
}

fn appendSection(output: *std.ArrayList(u8), allocator: std.mem.Allocator, id: u8, payload: []const u8) !void {
    try output.append(allocator, id);
    try appendUleb(output, allocator, payload.len);
    try output.appendSlice(allocator, payload);
}

fn appendCustomSection(output: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, payload: []const u8) !void {
    var custom: std.ArrayList(u8) = .empty;
    defer custom.deinit(allocator);
    try appendName(&custom, allocator, name);
    try custom.appendSlice(allocator, payload);
    try appendSection(output, allocator, section.custom, custom.items);
}

fn emit(allocator: std.mem.Allocator, pack: *PackModel, object: *const ObjectModel, resolved: *const Resolved, profile: runtime_profile.Profile, identity: LinkIdentity, profile_digest: [32]u8, pack_digest: [32]u8, object_digest: [32]u8, limits: Limits) Error![]u8 {
    const pointer_address = try globalAddress(pack, profile.bindingName(.program_pointer, .global) catch return Error.MissingRuntimeSymbol);
    writeU32Little(try memorySliceAt(pack.data.items, pointer_address, 4), resolved.program_address);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, &wasm_magic);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    // Types: preserve every pack index and append only genuinely new generated signatures.
    try appendUleb(&payload, allocator, pack.types.encodings.items.len + resolved.appended_types.items.len);
    for (pack.types.encodings.items) |encoding| try payload.appendSlice(allocator, encoding);
    for (resolved.appended_types.items) |encoding| try payload.appendSlice(allocator, encoding);
    try appendSection(&output, allocator, section.type_, payload.items);
    payload.clearRetainingCapacity();

    // The profile-declared host imports remain byte-for-byte and in the same function-index order.
    try appendSection(&output, allocator, section.import, pack.module.payload(section.import).?);

    try appendUleb(&payload, allocator, pack.function_types.items.len + object.function_types.items.len);
    for (pack.function_types.items) |type_index| try appendUleb(&payload, allocator, type_index);
    for (object.function_types.items) |type_index| try appendUleb(&payload, allocator, resolved.type_map[type_index]);
    try appendSection(&output, allocator, section.function, payload.items);
    payload.clearRetainingCapacity();

    const table_size = std.math.add(u32, pack.table.minimum, @intCast(object.element_functions.items.len)) catch return Error.IntegerOverflow;
    try appendUleb(&payload, allocator, 1);
    try payload.append(allocator, 0x70);
    try appendUleb(&payload, allocator, 1);
    try appendUleb(&payload, allocator, table_size);
    try appendUleb(&payload, allocator, table_size);
    try appendSection(&output, allocator, section.table, payload.items);
    payload.clearRetainingCapacity();

    try appendSection(&output, allocator, section.memory, pack.module.payload(section.memory).?);
    try appendSection(&output, allocator, section.global, pack.module.payload(section.global).?);

    try appendUleb(&payload, allocator, profile.export_count);
    var export_index: u32 = 0;
    while (export_index < profile.export_count) : (export_index += 1) {
        const retained = profile.retainedExport(export_index) catch return Error.InvalidExport;
        var found: ?Export = null;
        for (pack.exports.items) |item|
            if (item.kind == @intFromEnum(retained.kind) and std.mem.eql(u8, item.name, retained.name)) {
                found = item;
                break;
            };
        const item = found orelse return Error.MissingRuntimeSymbol;
        try appendName(&payload, allocator, item.name);
        try payload.append(allocator, item.kind);
        try appendUleb(&payload, allocator, item.index);
    }
    try appendSection(&output, allocator, section.export_, payload.items);
    payload.clearRetainingCapacity();

    // Preserve the pack's active element entries, then append the generated AOT entries.
    var pack_elements = Reader{ .bytes = pack.element_payload };
    _ = try pack_elements.readUleb32();
    try appendUleb(&payload, allocator, pack.element_count + @as(u32, @intFromBool(object.element_functions.items.len != 0)));
    try payload.appendSlice(allocator, pack.element_payload[pack_elements.cursor..]);
    if (object.element_functions.items.len != 0) {
        try appendUleb(&payload, allocator, 0);
        try payload.append(allocator, 0x41);
        try appendSleb(&payload, allocator, @intCast(resolved.table_base));
        try payload.append(allocator, 0x0b);
        try appendUleb(&payload, allocator, object.element_functions.items.len);
        for (object.element_functions.items) |function_index|
            try appendUleb(&payload, allocator, resolved.function_map[function_index]);
    }
    try appendSection(&output, allocator, section.element, payload.items);
    payload.clearRetainingCapacity();

    try appendUleb(&payload, allocator, pack.bodies.items.len + object.bodies.items.len);
    for (pack.bodies.items) |body| {
        try appendUleb(&payload, allocator, body.bytes.len);
        try payload.appendSlice(allocator, body.bytes);
    }
    for (object.bodies.items) |body| {
        try appendUleb(&payload, allocator, body.bytes.len);
        try payload.appendSlice(allocator, body.bytes);
    }
    try appendSection(&output, allocator, section.code, payload.items);
    payload.clearRetainingCapacity();

    try appendUleb(&payload, allocator, pack.data.items.len + object.data.items.len);
    for (pack.data.items) |segment_value| {
        try appendUleb(&payload, allocator, 0);
        try payload.append(allocator, 0x41);
        try appendSleb(&payload, allocator, @bitCast(segment_value.memory_offset));
        try payload.append(allocator, 0x0b);
        try appendUleb(&payload, allocator, segment_value.bytes.len);
        try payload.appendSlice(allocator, segment_value.bytes);
    }
    for (object.data.items, 0..) |segment_value, index| {
        try appendUleb(&payload, allocator, 0);
        try payload.append(allocator, 0x41);
        try appendSleb(&payload, allocator, @bitCast(resolved.data_addresses[index]));
        try payload.append(allocator, 0x0b);
        try appendUleb(&payload, allocator, segment_value.bytes.len);
        try payload.appendSlice(allocator, segment_value.bytes);
    }
    try appendSection(&output, allocator, section.data, payload.items);
    payload.clearRetainingCapacity();

    var output_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output.items, &output_digest, .{});
    try payload.appendSlice(allocator, &identity.compiler_build_sha256);
    try payload.appendSlice(allocator, &identity.package_manifest_sha256);
    try payload.appendSlice(allocator, &profile_digest);
    try payload.appendSlice(allocator, &pack_digest);
    try payload.appendSlice(allocator, &object_digest);
    try payload.appendSlice(allocator, &output_digest);
    try appendUleb(&payload, allocator, resolved.arena_used);
    try appendUleb(&payload, allocator, object.function_types.items.len);
    try appendCustomSection(&output, allocator, "luauc.link.v1", payload.items);

    if (output.items.len > limits.max_output_bytes)
        return Error.ResourceLimit;
    return output.toOwnedSlice(allocator);
}

pub fn link(allocator: std.mem.Allocator, runtime_pack: []const u8, package_object: []const u8, profile: runtime_profile.Profile, limits: Limits, identity: LinkIdentity) Error!Result {
    var pack = try PackModel.parse(allocator, runtime_pack, profile, limits);
    defer pack.deinit();
    var object = try ObjectModel.parse(allocator, package_object, limits);
    defer object.deinit();
    var resolved = try resolve(allocator, &pack, &object, profile, limits);
    defer resolved.deinit();
    try applyRelocations(&object, &resolved);

    var profile_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(profile.bytes, &profile_digest, .{});
    var pack_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(runtime_pack, &pack_digest, .{});
    var object_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(package_object, &object_digest, .{});
    const bytes = try emit(allocator, &pack, &object, &resolved, profile, identity, profile_digest, pack_digest, object_digest, limits);
    errdefer allocator.free(bytes);
    try validateFinal(allocator, bytes, profile, limits);
    var output_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &output_digest, .{});
    return .{
        .bytes = bytes,
        .report = .{
            .runtime_profile_sha256 = profile_digest,
            .runtime_pack_sha256 = pack_digest,
            .package_object_sha256 = object_digest,
            .output_sha256 = output_digest,
            .runtime_import_count = @intCast(pack.imports.functions.items.len),
            .runtime_function_count = @intCast(pack.function_types.items.len),
            .generated_function_count = @intCast(object.function_types.items.len),
            .generated_data_bytes = resolved.arena_used,
            .final_table_size = std.math.add(u32, pack.table.minimum, @intCast(object.element_functions.items.len)) catch return Error.IntegerOverflow,
        },
    };
}

pub fn validateRuntimePack(allocator: std.mem.Allocator, runtime_pack: []const u8, profile: runtime_profile.Profile, limits: Limits) Error!void {
    var pack = try PackModel.parse(allocator, runtime_pack, profile, limits);
    defer pack.deinit();
}

const LinkV1 = struct {
    compiler_build: [32]u8,
    package_manifest: [32]u8,
    profile: [32]u8,
    pack: [32]u8,
    object: [32]u8,
    output: [32]u8,
    arena_used: u32,
    generated_function_count: u32,
};

fn parseLinkV1(payload: []const u8) Error!LinkV1 {
    if (payload.len < 192)
        return Error.InvalidFinalModule;
    var result: LinkV1 = undefined;
    @memcpy(&result.compiler_build, payload[0..32]);
    @memcpy(&result.package_manifest, payload[32..64]);
    @memcpy(&result.profile, payload[64..96]);
    @memcpy(&result.pack, payload[96..128]);
    @memcpy(&result.object, payload[128..160]);
    @memcpy(&result.output, payload[160..192]);
    var reader = Reader{ .bytes = payload[192..] };
    result.arena_used = reader.readUleb32() catch return Error.InvalidFinalModule;
    result.generated_function_count = reader.readUleb32() catch return Error.InvalidFinalModule;
    if (!reader.done())
        return Error.InvalidFinalModule;
    return result;
}

fn encodeModuleWithLinkSection(allocator: std.mem.Allocator, payload: []const u8) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, &wasm_magic);
    appendCustomSection(&output, allocator, "luauc.link.v1", payload) catch return Error.OutOfMemory;
    return output.toOwnedSlice(allocator);
}

pub fn validateFinal(allocator: std.mem.Allocator, bytes: []const u8, profile: runtime_profile.Profile, limits: Limits) Error!void {
    var module = CoreModule.parse(allocator, bytes, limits) catch return Error.InvalidFinalModule;
    defer module.deinit();
    const link_payload = module.custom("luauc.link.v1") orelse return Error.InvalidFinalModule;
    _ = parseLinkV1(link_payload) catch return Error.InvalidFinalModule;
    inline for (.{ section.type_, section.import, section.function, section.table, section.memory, section.global, section.export_, section.element, section.code, section.data }) |id|
        if (module.payload(id) == null)
            return Error.InvalidFinalModule;
    if (module.payload(section.start) != null or module.payload(section.data_count) != null or module.custom("linking") != null or module.custom("reloc.CODE") != null or module.custom("reloc.DATA") != null)
        return Error.InvalidFinalModule;

    var types = TypeTable.parse(allocator, module.payload(section.type_).?, limits.max_types) catch return Error.InvalidFinalModule;
    defer types.deinit();
    var imports = Imports.parse(allocator, module.payload(section.import).?, limits.max_imports) catch return Error.InvalidFinalModule;
    defer imports.deinit();
    if (imports.items.items.len != profile.import_count)
        return Error.InvalidFinalModule;
    for (imports.items.items) |item|
        if (!profile.allowsHostImport(item.module, item.name, item.kind, item.type_index) or item.type_index >= types.encodings.items.len)
            return Error.InvalidFinalModule;
    var function_types = parseIndexVector(allocator, module.payload(section.function).?, limits.max_functions, Error.InvalidFinalModule) catch return Error.InvalidFinalModule;
    defer function_types.deinit(allocator);
    var bodies = parseBodies(allocator, module.payload(section.code).?, limits.max_functions) catch return Error.InvalidFinalModule;
    defer deinitBodies(allocator, &bodies);
    if (function_types.items.len != bodies.items.len)
        return Error.InvalidFinalModule;
    for (function_types.items) |type_index|
        if (type_index >= types.encodings.items.len)
            return Error.InvalidFinalModule;
    _ = parseSingleTable(module.payload(section.table).?) catch return Error.InvalidFinalModule;
    _ = parseSingleMemory(module.payload(section.memory).?) catch return Error.InvalidFinalModule;
    var globals = parseGlobals(allocator, module.payload(section.global).?, limits.max_globals) catch return Error.InvalidFinalModule;
    defer globals.deinit(allocator);
    var exports = parseExports(allocator, module.payload(section.export_).?, limits.max_exports) catch return Error.InvalidFinalModule;
    defer exports.deinit(allocator);
    if (exports.items.len != profile.export_count)
        return Error.InvalidFinalModule;
    var retained_index: u32 = 0;
    while (retained_index < profile.export_count) : (retained_index += 1) {
        const retained = profile.retainedExport(retained_index) catch return Error.InvalidFinalModule;
        if (!std.mem.eql(u8, exports.items[retained_index].name, retained.name) or exports.items[retained_index].kind != @intFromEnum(retained.kind))
            return Error.InvalidFinalModule;
    }
    var data = parseData(allocator, module.payload(section.data).?, limits.max_data_segments) catch return Error.InvalidFinalModule;
    defer deinitData(allocator, &data);
}

test "rejects malformed modules and oversized inputs deterministically" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(Error.InvalidMagic, CoreModule.parse(allocator, "not wasm", .{}));
    var limits = Limits{};
    limits.max_input_bytes = 4;
    try std.testing.expectError(Error.ResourceLimit, CoreModule.parse(allocator, &wasm_magic, limits));
}

fn dummyProfile() runtime_profile.Profile {
    return .{
        .bytes = &.{},
        .feature_mask = 0,
        .memory_minimum = 1,
        .memory_maximum = 1,
        .table_minimum = 1,
        .table_maximum = 1,
        .profile_id = "test",
        .luau_pin_sha256 = .{0} ** 32,
        .runtime_abi_sha256 = .{0} ** 32,
        .object_contract_sha256 = .{0} ** 32,
        .pack_build_sha256 = .{0} ** 32,
        .license_inventory_sha256 = .{0} ** 32,
        .string_offset = 0,
        .string_size = 0,
        .import_offset = 0,
        .import_count = 0,
        .export_offset = 0,
        .export_count = 0,
        .runtime_symbol_offset = 0,
        .runtime_symbol_count = 0,
        .binding_offset = 0,
        .binding_count = 0,
    };
}

test "parseLinkV1 binds six digests and two ulebs" {
    var payload: [194]u8 = undefined;
    @memset(&payload, 0);
    payload[0] = 0x11;
    payload[32] = 0x22;
    payload[64] = 0x33;
    payload[96] = 0x44;
    payload[128] = 0x55;
    payload[160] = 0x66;
    payload[192] = 5;
    payload[193] = 3;
    const parsed = try parseLinkV1(&payload);
    try std.testing.expectEqual(@as(u8, 0x11), parsed.compiler_build[0]);
    try std.testing.expectEqual(@as(u8, 0x22), parsed.package_manifest[0]);
    try std.testing.expectEqual(@as(u8, 0x33), parsed.profile[0]);
    try std.testing.expectEqual(@as(u8, 0x44), parsed.pack[0]);
    try std.testing.expectEqual(@as(u8, 0x55), parsed.object[0]);
    try std.testing.expectEqual(@as(u8, 0x66), parsed.output[0]);
    try std.testing.expectEqual(@as(u32, 5), parsed.arena_used);
    try std.testing.expectEqual(@as(u32, 3), parsed.generated_function_count);
}

test "validateFinal rejects a historical three-digest luauc.link.v1 payload" {
    const allocator = std.testing.allocator;
    const three_digest = [_]u8{1} ++ [_]u8{0xaa} ** 96 ++ [_]u8{ 1, 1 };
    try std.testing.expectEqual(@as(usize, 99), three_digest.len);
    try std.testing.expectError(Error.InvalidFinalModule, parseLinkV1(&three_digest));
    const bytes = try encodeModuleWithLinkSection(allocator, &three_digest);
    defer allocator.free(bytes);
    try std.testing.expectError(Error.InvalidFinalModule, validateFinal(allocator, bytes, dummyProfile(), .{}));
}

test "generated-runtime import modules rewrite to the profile module" {
    var object = ObjectModel{
        .allocator = std.testing.allocator,
        .module = undefined,
        .types = undefined,
        .imports = .{ .allocator = std.testing.allocator },
        .function_types = .empty,
        .bodies = .empty,
        .data = .empty,
        .linking = undefined,
        .code_relocations = .empty,
        .data_relocations = .empty,
        .element_functions = .empty,
    };
    try object.imports.items.append(std.testing.allocator, .{
        .module = "env",
        .name = "luauc_runtime_v1_call",
        .kind = external_kind.function,
        .type_index = 0,
    });
    try object.imports.functions.append(std.testing.allocator, object.imports.items.items[0]);
    defer object.imports.deinit();
    rewriteObjectImportModules(&object, dummyProfile().generatedRuntimeModule());
    try std.testing.expectEqualStrings("env", object.imports.functions.items[0].module);
    try std.testing.expectEqualStrings("env", object.imports.items.items[0].module);
}

test "padded relocation encodings retain fixed width" {
    var unsigned = [_]u8{0} ** 5;
    try writePaddedUleb32(&unsigned, 0xfedcba98);
    var unsigned_reader = Reader{ .bytes = &unsigned };
    try std.testing.expectEqual(@as(u32, 0xfedcba98), try unsigned_reader.readUleb32());
    try std.testing.expect(unsigned_reader.done());

    var signed = [_]u8{0} ** 5;
    try writePaddedSleb32(&signed, -1234567);
    var signed_reader = Reader{ .bytes = &signed };
    try std.testing.expectEqual(@as(i32, -1234567), try signed_reader.readSleb32());
    try std.testing.expect(signed_reader.done());
}

const std = @import("std");

pub const magic = "LUAUCS1\x00".*;
pub const version: u16 = 1;
pub const header_size: u16 = 160;
pub const record_size: u32 = 64;
pub const max_modules: u32 = 128;
pub const max_request_bytes: u32 = 16 * 1024 * 1024;
pub const max_module_name_bytes: u32 = 1024;
pub const max_source_name_bytes: u32 = 4096;
pub const inline_plan_size: u32 = 16;
pub const max_inline_plans_per_module: u32 = 4096;
pub const feature_inline_plan: u32 = 1 << 0;
pub const supported_features: u32 = feature_inline_plan;

pub const Error = error{
    InvalidMagic,
    UnsupportedVersion,
    InvalidHeader,
    ResourceLimit,
    InvalidEntryModule,
    InvalidModuleName,
    InvalidSourceName,
    InvalidUtf8,
    InvalidContentDigest,
    InvalidManifestDigest,
    InvalidRequestDigest,
    RuntimeProfileMismatch,
    RuntimePackMismatch,
    NonCanonicalModuleOrder,
    NonCanonicalLayout,
    IntegerOverflow,
    InvalidInlinePlan,
};

pub const InlinePlan = extern struct {
    caller_function_id: u32,
    feedback_slot: u32,
    target_function_id: u32,
    reserved: u32,
};

pub const Module = struct {
    id: u32,
    name: []const u8,
    source_name: []const u8,
    content: []const u8,
    content_sha256: [32]u8,
    inline_plan_bytes: []const u8,
    inline_plan_count: u32,

    pub fn inlinePlan(self: Module, id: u32) Error!InlinePlan {
        if (id >= self.inline_plan_count)
            return Error.InvalidInlinePlan;
        const bytes = self.inline_plan_bytes[id * inline_plan_size ..][0..inline_plan_size];
        return .{
            .caller_function_id = readU32(bytes, 0),
            .feedback_slot = readU32(bytes, 4),
            .target_function_id = readU32(bytes, 8),
            .reserved = readU32(bytes, 12),
        };
    }
};

pub const Package = struct {
    bytes: []const u8,
    module_count: u32,
    entry_module_id: u32,
    coverage_level: u32,
    feature_flags: u32,
    request_id: [16]u8,
    runtime_profile_sha256: [32]u8,
    runtime_pack_sha256: [32]u8,
    manifest_sha256: [32]u8,

    pub fn module(self: Package, id: u32) Error!Module {
        if (id >= self.module_count)
            return Error.InvalidEntryModule;
        const record_offset = try add(header_size, try mul(id, record_size));
        const record = self.bytes[record_offset..][0..record_size];
        var digest: [32]u8 = undefined;
        @memcpy(&digest, record[24..56]);
        const plan_offset = readU32(record, 56);
        const plan_count = readU32(record, 60);
        return .{
            .id = id,
            .name = self.bytes[readU32(record, 0)..][0..readU32(record, 4)],
            .source_name = self.bytes[readU32(record, 8)..][0..readU32(record, 12)],
            .content = self.bytes[readU32(record, 16)..][0..readU32(record, 20)],
            .content_sha256 = digest,
            .inline_plan_bytes = if (plan_count == 0)
                &.{}
            else
                self.bytes[plan_offset..][0 .. plan_count * inline_plan_size],
            .inline_plan_count = plan_count,
        };
    }
};

pub fn parse(bytes: []const u8, expected_runtime_profile_sha256: [32]u8, expected_runtime_pack_sha256: [32]u8) Error!Package {
    if (bytes.len < header_size or bytes.len > max_request_bytes)
        return Error.InvalidHeader;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic))
        return Error.InvalidMagic;
    if (readU16(bytes, 8) != version)
        return Error.UnsupportedVersion;
    const coverage_level = readU32(bytes, 28);
    if (readU16(bytes, 10) != header_size or readU32(bytes, 12) != bytes.len or
        readU32(bytes, 24) != record_size or coverage_level > 2)
        return Error.InvalidHeader;
    const feature_flags = readU32(bytes, 144);
    if (feature_flags & ~supported_features != 0)
        return Error.InvalidHeader;
    for (bytes[148..160]) |reserved|
        if (reserved != 0)
            return Error.InvalidHeader;

    const module_count = readU32(bytes, 16);
    const entry_module_id = readU32(bytes, 20);
    if (module_count == 0 or module_count > max_modules)
        return Error.ResourceLimit;
    if (entry_module_id >= module_count)
        return Error.InvalidEntryModule;
    var request_id: [16]u8 = undefined;
    @memcpy(&request_id, bytes[32..48]);
    var profile_digest: [32]u8 = undefined;
    @memcpy(&profile_digest, bytes[48..80]);
    if (!std.mem.eql(u8, &profile_digest, &expected_runtime_profile_sha256))
        return Error.RuntimeProfileMismatch;
    var runtime_digest: [32]u8 = undefined;
    @memcpy(&runtime_digest, bytes[80..112]);
    if (!std.mem.eql(u8, &runtime_digest, &expected_runtime_pack_sha256))
        return Error.RuntimePackMismatch;
    var manifest_digest: [32]u8 = undefined;
    @memcpy(&manifest_digest, bytes[112..144]);

    var cursor = try add(header_size, try mul(module_count, record_size));
    if (cursor > bytes.len)
        return Error.NonCanonicalLayout;
    var previous_name: ?[]const u8 = null;
    var total_inline_plans: u32 = 0;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var header_fields: [8]u8 = undefined;
    writeU32(&header_fields, 0, module_count);
    writeU32(&header_fields, 4, entry_module_id);
    hasher.update(&header_fields);

    var id: u32 = 0;
    while (id < module_count) : (id += 1) {
        const record_offset = try add(header_size, try mul(id, record_size));
        const record = bytes[record_offset..][0..record_size];
        const name_offset = readU32(record, 0);
        const name_size = readU32(record, 4);
        const source_offset = readU32(record, 8);
        const source_size = readU32(record, 12);
        const content_offset = readU32(record, 16);
        const content_size = readU32(record, 20);
        const plan_offset = readU32(record, 56);
        const plan_count = readU32(record, 60);
        if (name_size == 0 or name_size > max_module_name_bytes or name_offset != cursor)
            return Error.NonCanonicalLayout;
        const name_end = try add(name_offset, name_size);
        if (name_end > bytes.len or source_size == 0 or source_size > max_source_name_bytes or source_offset != name_end)
            return Error.NonCanonicalLayout;
        const source_end = try add(source_offset, source_size);
        if (source_end > bytes.len or content_offset != source_end or content_size == 0)
            return Error.NonCanonicalLayout;
        const content_end = try add(content_offset, content_size);
        if (content_end > bytes.len or plan_count > max_inline_plans_per_module)
            return Error.NonCanonicalLayout;
        total_inline_plans = std.math.add(u32, total_inline_plans, plan_count) catch
            return Error.IntegerOverflow;
        const plan_bytes = try mul(plan_count, inline_plan_size);
        if ((feature_flags & feature_inline_plan == 0 and (plan_offset != 0 or plan_count != 0)) or
            (plan_count == 0 and plan_offset != 0) or
            (plan_count != 0 and plan_offset != content_end))
            return Error.NonCanonicalLayout;
        const plan_end = if (plan_count == 0) content_end else try add(plan_offset, plan_bytes);
        if (plan_end > bytes.len)
            return Error.NonCanonicalLayout;

        const name = bytes[name_offset..name_end];
        const source_name = bytes[source_offset..source_end];
        const content = bytes[content_offset..content_end];
        if (!std.unicode.utf8ValidateSlice(name) or !std.unicode.utf8ValidateSlice(source_name) or !std.unicode.utf8ValidateSlice(content))
            return Error.InvalidUtf8;
        if (!validModuleName(name))
            return Error.InvalidModuleName;
        if (!validSourceName(name, source_name))
            return Error.InvalidSourceName;
        if (previous_name) |previous|
            if (std.mem.order(u8, previous, name) != .lt)
                return Error.NonCanonicalModuleOrder;
        previous_name = name;

        var content_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &content_digest, .{});
        if (!std.mem.eql(u8, &content_digest, record[24..56]))
            return Error.InvalidContentDigest;
        var plan_index: u32 = 0;
        while (plan_index < plan_count) : (plan_index += 1) {
            const plan = bytes[plan_offset + plan_index * inline_plan_size ..][0..inline_plan_size];
            if (readU32(plan, 12) != 0)
                return Error.InvalidInlinePlan;
            if (plan_index != 0) {
                const previous = bytes[plan_offset + (plan_index - 1) * inline_plan_size ..][0..inline_plan_size];
                if (readU32(previous, 0) > readU32(plan, 0) or
                    (readU32(previous, 0) == readU32(plan, 0) and
                        readU32(previous, 4) >= readU32(plan, 4)))
                    return Error.InvalidInlinePlan;
            }
        }
        hashSized(&hasher, name);
        hashSized(&hasher, source_name);
        hasher.update(&content_digest);
        if (feature_flags & feature_inline_plan != 0) {
            var plan_count_bytes: [4]u8 = undefined;
            writeU32(&plan_count_bytes, 0, plan_count);
            hasher.update(&plan_count_bytes);
            if (plan_count != 0)
                hasher.update(bytes[plan_offset..plan_end]);
        }
        cursor = plan_end;
    }
    if (feature_flags & feature_inline_plan != 0 and total_inline_plans == 0)
        return Error.InvalidInlinePlan;
    if (cursor != bytes.len)
        return Error.NonCanonicalLayout;
    var actual_manifest: [32]u8 = undefined;
    hasher.final(&actual_manifest);
    if (!std.mem.eql(u8, &actual_manifest, &manifest_digest))
        return Error.InvalidManifestDigest;
    var request_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    request_hasher.update(if (feature_flags & feature_inline_plan != 0)
        "luauc-source-request-v1-inline-plan\x00"
    else
        "luauc-source-request-v1\x00");
    var coverage_bytes: [4]u8 = undefined;
    writeU32(&coverage_bytes, 0, coverage_level);
    request_hasher.update(&coverage_bytes);
    request_hasher.update(&profile_digest);
    request_hasher.update(&runtime_digest);
    request_hasher.update(&manifest_digest);
    var actual_request_digest: [32]u8 = undefined;
    request_hasher.final(&actual_request_digest);
    if (!std.mem.eql(u8, &request_id, actual_request_digest[0..request_id.len]))
        return Error.InvalidRequestDigest;
    return .{
        .bytes = bytes,
        .module_count = module_count,
        .entry_module_id = entry_module_id,
        .coverage_level = coverage_level,
        .feature_flags = feature_flags,
        .request_id = request_id,
        .runtime_profile_sha256 = profile_digest,
        .runtime_pack_sha256 = runtime_digest,
        .manifest_sha256 = manifest_digest,
    };
}

fn validModuleName(name: []const u8) bool {
    if (name[0] == '/' or name[name.len - 1] == '/' or std.mem.indexOf(u8, name, "..") != null)
        return false;
    for (name) |byte| switch (byte) {
        'a'...'z', '0'...'9', '_', '-', '.', '/' => {},
        else => return false,
    };
    return true;
}

fn validSourceName(module_name: []const u8, source_name: []const u8) bool {
    const prefix = "@";
    const suffix = ".luau";
    return source_name.len == prefix.len + module_name.len + suffix.len and
        std.mem.eql(u8, source_name[0..prefix.len], prefix) and
        std.mem.eql(u8, source_name[prefix.len..][0..module_name.len], module_name) and
        std.mem.eql(u8, source_name[source_name.len - suffix.len ..], suffix);
}

fn hashSized(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var size: [4]u8 = undefined;
    writeU32(&size, 0, @intCast(bytes.len));
    hasher.update(&size);
    hasher.update(bytes);
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}

fn add(lhs: anytype, rhs: anytype) Error!u32 {
    return std.math.add(u32, @intCast(lhs), @intCast(rhs)) catch Error.IntegerOverflow;
}

fn mul(lhs: u32, rhs: u32) Error!u32 {
    return std.math.mul(u32, lhs, rhs) catch Error.IntegerOverflow;
}

test "rejects a request whose runtime identity is not exact" {
    var bytes = [_]u8{0} ** header_size;
    @memcpy(bytes[0..magic.len], &magic);
    bytes[8] = 1;
    bytes[10] = header_size;
    writeU32(&bytes, 12, bytes.len);
    writeU32(&bytes, 16, 1);
    writeU32(&bytes, 24, record_size);
    const expected = [_]u8{0xaa} ** 32;
    try std.testing.expectError(Error.RuntimeProfileMismatch, parse(&bytes, expected, expected));
}

test "parses canonical source package and verifies every identity" {
    const names = [_][]const u8{ "counter", "main" };
    const source_names = [_][]const u8{ "@counter.luau", "@main.luau" };
    const contents = [_][]const u8{
        "return function(value) return value + 1 end",
        "local counter = require(\"counter\") return counter(41)",
    };
    const records_end: usize = header_size + names.len * record_size;
    const total_size = records_end + names[0].len + source_names[0].len + contents[0].len +
        names[1].len + source_names[1].len + contents[1].len;
    var bytes = [_]u8{0} ** total_size;
    @memcpy(bytes[0..magic.len], &magic);
    writeU32(&bytes, 12, @intCast(bytes.len));
    writeU32(&bytes, 16, @intCast(names.len));
    writeU32(&bytes, 20, 1);
    writeU32(&bytes, 24, record_size);
    writeU32(&bytes, 28, 2);
    bytes[8] = @truncate(version);
    bytes[9] = @truncate(version >> 8);
    bytes[10] = @truncate(header_size);
    bytes[11] = @truncate(header_size >> 8);

    const runtime_digest = [_]u8{0xa5} ** 32;
    const profile_digest = [_]u8{0xb6} ** 32;
    @memcpy(bytes[48..80], &profile_digest);
    @memcpy(bytes[80..112], &runtime_digest);

    var manifest = std.crypto.hash.sha2.Sha256.init(.{});
    var manifest_header: [8]u8 = undefined;
    writeU32(&manifest_header, 0, @intCast(names.len));
    writeU32(&manifest_header, 4, 1);
    manifest.update(&manifest_header);

    var cursor: usize = records_end;
    for (names, source_names, contents, 0..) |name, source_name, content, id| {
        const record = header_size + id * record_size;
        writeU32(&bytes, record, @intCast(cursor));
        writeU32(&bytes, record + 4, @intCast(name.len));
        @memcpy(bytes[cursor..][0..name.len], name);
        cursor += name.len;
        writeU32(&bytes, record + 8, @intCast(cursor));
        writeU32(&bytes, record + 12, @intCast(source_name.len));
        @memcpy(bytes[cursor..][0..source_name.len], source_name);
        cursor += source_name.len;
        writeU32(&bytes, record + 16, @intCast(cursor));
        writeU32(&bytes, record + 20, @intCast(content.len));
        @memcpy(bytes[cursor..][0..content.len], content);
        cursor += content.len;

        var content_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &content_digest, .{});
        @memcpy(bytes[record + 24 ..][0..32], &content_digest);
        hashSized(&manifest, name);
        hashSized(&manifest, source_name);
        manifest.update(&content_digest);
    }
    var manifest_digest: [32]u8 = undefined;
    manifest.final(&manifest_digest);
    @memcpy(bytes[112..144], &manifest_digest);

    var request = std.crypto.hash.sha2.Sha256.init(.{});
    request.update("luauc-source-request-v1\x00");
    const coverage_bytes = [_]u8{ 2, 0, 0, 0 };
    request.update(&coverage_bytes);
    request.update(&profile_digest);
    request.update(&runtime_digest);
    request.update(&manifest_digest);
    var request_digest: [32]u8 = undefined;
    request.final(&request_digest);
    @memcpy(bytes[32..48], request_digest[0..16]);

    const package = try parse(&bytes, profile_digest, runtime_digest);
    try std.testing.expectEqual(@as(u32, 2), package.module_count);
    try std.testing.expectEqual(@as(u32, 1), package.entry_module_id);
    try std.testing.expectEqual(@as(u32, 2), package.coverage_level);
    try std.testing.expectEqualSlices(u8, request_digest[0..16], &package.request_id);
    try std.testing.expectEqualSlices(u8, &manifest_digest, &package.manifest_sha256);
    try std.testing.expectEqualStrings("counter", (try package.module(0)).name);
    try std.testing.expectEqualStrings(contents[1], (try package.module(1)).content);
}

test "parses the canonical inline-plan extension without changing ordinary V1" {
    const name = "main";
    const source_name = "@main.luau";
    const content = "return function(f, a, b) return f(a, b) end";
    const records_end: usize = header_size + record_size;
    const plan_bytes = [_]u8{0} ** inline_plan_size;
    const total_size = records_end + name.len + source_name.len + content.len + plan_bytes.len;
    var bytes = [_]u8{0} ** total_size;
    @memcpy(bytes[0..magic.len], &magic);
    bytes[8] = @truncate(version);
    bytes[10] = @truncate(header_size);
    writeU32(&bytes, 12, @intCast(bytes.len));
    writeU32(&bytes, 16, 1);
    writeU32(&bytes, 24, record_size);
    writeU32(&bytes, 144, feature_inline_plan);
    const profile_digest = [_]u8{0x12} ** 32;
    const runtime_digest = [_]u8{0x34} ** 32;
    @memcpy(bytes[48..80], &profile_digest);
    @memcpy(bytes[80..112], &runtime_digest);

    var cursor: usize = records_end;
    writeU32(&bytes, header_size, @intCast(cursor));
    writeU32(&bytes, header_size + 4, name.len);
    @memcpy(bytes[cursor..][0..name.len], name);
    cursor += name.len;
    writeU32(&bytes, header_size + 8, @intCast(cursor));
    writeU32(&bytes, header_size + 12, source_name.len);
    @memcpy(bytes[cursor..][0..source_name.len], source_name);
    cursor += source_name.len;
    writeU32(&bytes, header_size + 16, @intCast(cursor));
    writeU32(&bytes, header_size + 20, content.len);
    @memcpy(bytes[cursor..][0..content.len], content);
    cursor += content.len;
    var content_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &content_digest, .{});
    @memcpy(bytes[header_size + 24 ..][0..32], &content_digest);
    writeU32(&bytes, header_size + 56, @intCast(cursor));
    writeU32(&bytes, header_size + 60, 1);
    @memcpy(bytes[cursor..][0..plan_bytes.len], &plan_bytes);

    var manifest = std.crypto.hash.sha2.Sha256.init(.{});
    const manifest_header = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 };
    manifest.update(&manifest_header);
    hashSized(&manifest, name);
    hashSized(&manifest, source_name);
    manifest.update(&content_digest);
    manifest.update(&[_]u8{ 1, 0, 0, 0 });
    manifest.update(&plan_bytes);
    var manifest_digest: [32]u8 = undefined;
    manifest.final(&manifest_digest);
    @memcpy(bytes[112..144], &manifest_digest);

    var request = std.crypto.hash.sha2.Sha256.init(.{});
    request.update("luauc-source-request-v1-inline-plan\x00");
    request.update(&[_]u8{0} ** 4);
    request.update(&profile_digest);
    request.update(&runtime_digest);
    request.update(&manifest_digest);
    var request_digest: [32]u8 = undefined;
    request.final(&request_digest);
    @memcpy(bytes[32..48], request_digest[0..16]);

    const package = try parse(&bytes, profile_digest, runtime_digest);
    try std.testing.expectEqual(feature_inline_plan, package.feature_flags);
    const module = try package.module(0);
    try std.testing.expectEqual(@as(u32, 1), module.inline_plan_count);
    try std.testing.expectEqual(@as(u32, 0), (try module.inlinePlan(0)).target_function_id);
}

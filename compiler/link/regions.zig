const std = @import("std");
const Op = @import("control_flow.zig").Op;

pub const Signature = struct { params: []const u8, results: []const u8 };
pub const Input = struct { bytes: []const u8, ops: []const Op, locals: []const u8 };
pub const Error = std.mem.Allocator.Error;
const absent = std.math.maxInt(u32);
const max_locals = 16;
const max_constants = 64;
const max_window = 160;
const max_shapes = 150_000;
const max_occurrences = 500_000;

const Site = struct { body: u32, start: u32, count: u32, next: u32 = absent };
const Shape = struct {
    first: u32,
    last: u32,
    count: u32 = 1,
    variants: u64 = 0,
    saving: i64 = 0,
};
const Binding = struct {
    locals: [max_locals]u32 = undefined,
    types: [max_locals]u8 = undefined,
    local_count: u8 = 0,
    live: u16 = 0,
    written: u16 = 0,
    constants: [max_constants]i32 = undefined,
    constant_count: u8 = 0,

    fn step(self: *Binding, input: Input, op: Op) ?u8 {
        if (op.class == 1) {
            if (self.constant_count == max_constants) return null;
            self.constants[self.constant_count] = op.imm;
            self.constant_count += 1;
        }
        if (op.class != 2) return 0;
        if (op.imm < 0 or op.imm >= input.locals.len) return null;
        const local: u32 = @intCast(op.imm);
        const ordinal: u8 = @intCast(std.mem.indexOfScalar(u32, self.locals[0..self.local_count], local) orelse self.local_count);
        if (ordinal == max_locals) return null;
        if (ordinal == self.local_count) {
            self.locals[ordinal] = local;
            self.types[ordinal] = input.locals[local];
            self.local_count += 1;
        }
        const mask = @as(u16, 1) << @intCast(ordinal);
        if (op.op == 0x20) {
            if (self.written & mask == 0) self.live |= mask;
        } else self.written |= mask;
        if (@popCount(self.written) > 1 or @popCount(self.live) > 12) return null;
        return ordinal;
    }
};

fn binding(input: Input, site: Site) Binding {
    var result = Binding{};
    for (input.ops[site.start..][0..site.count]) |op| _ = result.step(input, op).?;
    return result;
}

fn effect(op: Op, signatures: []const Signature) ?struct { take: u32, give: u32 } {
    return switch (op.op) {
        0x01 => .{ .take = 0, .give = 0 },
        0x20, 0x23, 0x41...0x44, 0x3f => .{ .take = 0, .give = 1 },
        0x21, 0x24, 0x1a => .{ .take = 1, .give = 0 },
        0x22, 0x28...0x35, 0x40, 0x45, 0x50, 0x67...0x69, 0x79...0x7b, 0x8b...0x91, 0x99...0x9f, 0xa7...0xc4 => .{ .take = 1, .give = 1 },
        0x36...0x3e => .{ .take = 2, .give = 0 },
        0x46...0x4f, 0x51...0x66, 0x6a...0x78, 0x7c...0x8a, 0x92...0x98, 0xa0...0xa6 => .{ .take = 2, .give = 1 },
        0x1b => .{ .take = 3, .give = 1 },
        0x10 => if (op.imm >= 0 and op.imm < signatures.len)
            .{ .take = @intCast(signatures[@intCast(op.imm)].params.len), .give = @intCast(signatures[@intCast(op.imm)].results.len) }
        else
            null,
        else => null,
    };
}

fn equal(left: Input, lhs: Site, right: Input, rhs: Site) bool {
    if (lhs.count != rhs.count) return false;
    var left_binding = Binding{};
    var right_binding = Binding{};
    for (left.ops[lhs.start..][0..lhs.count], right.ops[rhs.start..][0..rhs.count]) |first, second| {
        if (first.op != second.op or first.class != second.class) return false;
        const left_local = left_binding.step(left, first) orelse return false;
        const right_local = right_binding.step(right, second) orelse return false;
        if (first.class == 1) continue;
        if (first.class == 2) {
            if (left_local != right_local or left_binding.types[left_local] != right_binding.types[right_local]) return false;
        } else if (!std.mem.eql(u8, left.bytes[first.at..][0..first.len], right.bytes[second.at..][0..second.len])) return false;
    }
    return true;
}

fn uleb(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) Error!void {
    var remaining = value;
    while (true) {
        const byte: u8 = @truncate(remaining & 127);
        remaining >>= 7;
        try output.append(allocator, byte | @as(u8, if (remaining != 0) 128 else 0));
        if (remaining == 0) return;
    }
}

fn localOp(output: *std.ArrayList(u8), allocator: std.mem.Allocator, opcode: u8, local: u32) Error!void {
    try output.append(allocator, opcode);
    try uleb(output, allocator, local);
}

fn has(mask: anytype, index: usize) bool {
    return mask & (@as(@TypeOf(mask), 1) << @intCast(index)) != 0;
}

const Arguments = struct {
    variants: u64,
    minimum: [max_constants]i32 = .{0} ** max_constants,
    bits: [max_constants]u8 = .{32} ** max_constants,
    word: [max_constants]u8 = undefined,
    shift: [max_constants]u5 = .{0} ** max_constants,
    count: u8 = 0,

    fn plain(variants: u64) Arguments {
        var result = Arguments{ .variants = variants };
        for (0..max_constants) |index| {
            if (!has(variants, index)) continue;
            result.word[index] = result.count;
            result.count += 1;
        }
        return result;
    }
};

fn sleb(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i32) Error!void {
    var remaining = value;
    while (true) {
        const byte: u8 = @truncate(@as(u32, @bitCast(remaining)) & 127);
        remaining >>= 7;
        const done = (remaining == 0 and byte & 64 == 0) or (remaining == -1 and byte & 64 != 0);
        try output.append(allocator, byte | @as(u8, if (done) 0 else 128));
        if (done) return;
    }
}

fn constantOp(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i32) Error!void {
    try output.append(allocator, 0x41);
    try sleb(output, allocator, value);
}

fn siteBytes(output: *std.ArrayList(u8), allocator: std.mem.Allocator, input: Input, site: Site, args: *const Arguments, helper: u32) Error!void {
    const values = binding(input, site);
    for (values.locals[0..values.local_count], 0..) |local, index| {
        if (has(values.live, index)) try localOp(output, allocator, 0x20, local);
    }
    var words = [_]u32{0} ** max_constants;
    for (values.constants[0..values.constant_count], 0..) |value, ordinal| {
        if (!has(args.variants, ordinal)) continue;
        const delta = @as(u32, @bitCast(value)) -% @as(u32, @bitCast(args.minimum[ordinal]));
        words[args.word[ordinal]] |= delta << args.shift[ordinal];
    }
    for (words[0..args.count]) |word| try constantOp(output, allocator, @bitCast(word));
    try localOp(output, allocator, 0x10, helper);
    for (values.locals[0..values.local_count], 0..) |local, index| {
        if (has(values.written, index)) try localOp(output, allocator, 0x21, local);
    }
}

fn helperBytes(output: *std.ArrayList(u8), encoding: *std.ArrayList(u8), allocator: std.mem.Allocator, input: Input, site: Site, args: *const Arguments) Error!void {
    const values = binding(input, site);
    var mapping: [max_locals]u32 = undefined;
    const live_count = @popCount(values.live);
    const param_count: u32 = live_count + args.count;
    try encoding.append(allocator, 0x60);
    try uleb(encoding, allocator, param_count);
    var next: u32 = 0;
    for (values.types[0..values.local_count], 0..) |value_type, index| {
        if (!has(values.live, index)) continue;
        mapping[index] = next;
        next += 1;
        try encoding.append(allocator, value_type);
    }
    try encoding.appendNTimes(allocator, 0x7f, args.count);
    try uleb(encoding, allocator, @popCount(values.written));
    for (values.types[0..values.local_count], 0..) |value_type, index| {
        if (has(values.written, index)) try encoding.append(allocator, value_type);
    }
    try uleb(output, allocator, values.local_count - live_count);
    next = param_count;
    for (values.types[0..values.local_count], 0..) |value_type, index| {
        if (has(values.live, index)) continue;
        mapping[index] = next;
        next += 1;
        try output.appendSlice(allocator, &.{ 1, value_type });
    }
    var seen = Binding{};
    var constant_ordinal: usize = 0;
    for (input.ops[site.start..][0..site.count]) |op| {
        const local = seen.step(input, op).?;
        if (op.class == 2) {
            try localOp(output, allocator, op.op, mapping[local]);
        } else if (op.class == 1) {
            if (has(args.variants, constant_ordinal)) {
                try localOp(output, allocator, 0x20, @as(u32, live_count) + args.word[constant_ordinal]);
                if (args.shift[constant_ordinal] != 0) {
                    try constantOp(output, allocator, args.shift[constant_ordinal]);
                    try output.append(allocator, 0x76);
                }
                if (args.bits[constant_ordinal] != 32) {
                    const mask = (@as(u32, 1) << @intCast(args.bits[constant_ordinal])) - 1;
                    try constantOp(output, allocator, @bitCast(mask));
                    try output.append(allocator, 0x71);
                }
                if (args.minimum[constant_ordinal] != 0) {
                    try constantOp(output, allocator, args.minimum[constant_ordinal]);
                    try output.append(allocator, 0x6a);
                }
            } else try output.appendSlice(allocator, input.bytes[op.at..][0..op.len]);
            constant_ordinal += 1;
        } else try output.appendSlice(allocator, input.bytes[op.at..][0..op.len]);
    }
    for (mapping[0..values.local_count], 0..) |local, index| {
        if (has(values.written, index)) try localOp(output, allocator, 0x20, local);
    }
    try output.append(allocator, 0x0b);
}

pub const Result = struct {
    bodies: std.ArrayList([]u8) = .empty,
    helpers: std.ArrayList([]u8) = .empty,
    types: std.ArrayList([]u8) = .empty,
    helper_types: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.bodies.items) |bytes| allocator.free(bytes);
        for (self.helpers.items) |bytes| allocator.free(bytes);
        for (self.types.items) |bytes| allocator.free(bytes);
        self.bodies.deinit(allocator);
        self.helpers.deinit(allocator);
        self.types.deinit(allocator);
        self.helper_types.deinit(allocator);
    }
};

const Replacement = struct { site: Site, helper: u32, plan: u32 };

fn packedArguments(inputs: []const Input, sites: []const Replacement, variants: u64) Arguments {
    var result = Arguments.plain(variants);
    var maximum = [_]i32{std.math.minInt(i32)} ** max_constants;
    @memset(&result.minimum, std.math.maxInt(i32));
    for (sites) |replacement| {
        const values = binding(inputs[replacement.site.body], replacement.site);
        for (values.constants[0..values.constant_count], 0..) |value, index| {
            if (!has(variants, index)) continue;
            result.minimum[index] = @min(result.minimum[index], value);
            maximum[index] = @max(maximum[index], value);
        }
    }
    result.count = 0;
    var used: u8 = 32;
    for (0..max_constants) |index| {
        if (!has(variants, index)) continue;
        const range: u32 = @intCast(@as(i64, maximum[index]) - result.minimum[index]);
        const bits: u8 = @intCast(@max(1, 32 - @clz(range)));
        result.bits[index] = if (bits > 24) 32 else bits;
        if (result.bits[index] == 32) result.minimum[index] = 0;
        if (used + result.bits[index] > 32) {
            result.count += 1;
            used = 0;
        }
        result.word[index] = result.count - 1;
        result.shift[index] = @intCast(used);
        used += result.bits[index];
    }
    return result;
}

fn bounds(input: Input, site: Site) struct { start: usize, end: usize } {
    const last = input.ops[site.start + site.count - 1];
    return .{ .start = input.ops[site.start].at, .end = last.at + last.len };
}

pub fn share(allocator: std.mem.Allocator, inputs: []const Input, signatures: []const Signature, type_base: u32, first_helper: u32, max_types: u32, max_functions: u32) Error!Result {
    var result = Result{};
    errdefer result.deinit(allocator);
    var shapes: std.ArrayList(Shape) = .empty;
    defer shapes.deinit(allocator);
    var sites: std.ArrayList(Site) = .empty;
    defer sites.deinit(allocator);
    var hashes = std.AutoHashMap(u64, u32).init(allocator);
    defer hashes.deinit();
    discovery: for (inputs, 0..) |input, body_id| {
        for (input.ops, 0..) |_, start| {
            var values = Binding{};
            var height: u32 = 0;
            var hash = std.hash.Wyhash.init(0);
            for (input.ops[start..@min(input.ops.len, start + max_window)], 0..) |op, offset| {
                const stack = effect(op, signatures) orelse break;
                if (height < stack.take) break;
                height = height - stack.take + stack.give;
                const local = values.step(input, op) orelse break;
                if (op.class == 1) hash.update(&.{op.op}) else if (op.class == 2)
                    hash.update(&.{ op.op, local, values.types[local] })
                else
                    hash.update(input.bytes[op.at..][0..op.len]);
                if (height != 0 or offset < 11 or op.at + op.len - input.ops[start].at < 48) continue;
                const site = Site{ .body = @intCast(body_id), .start = @intCast(start), .count = @intCast(offset + 1) };
                var saved_hash = hash;
                const key = saved_hash.final();
                if (hashes.get(key)) |shape_id| {
                    const shape = &shapes.items[shape_id];
                    const first = sites.items[shape.first];
                    if (!equal(inputs[first.body], first, input, site)) continue;
                    const reference = binding(inputs[first.body], first);
                    for (values.constants[0..values.constant_count], 0..) |value, index| {
                        if (reference.constants[index] != value) shape.variants |= @as(u64, 1) << @intCast(index);
                    }
                    sites.items[shape.last].next = @intCast(sites.items.len);
                    shape.last = @intCast(sites.items.len);
                    shape.count += 1;
                    try sites.append(allocator, site);
                } else {
                    if (shapes.items.len == max_shapes) continue;
                    try hashes.put(key, @intCast(shapes.items.len));
                    try shapes.append(allocator, .{ .first = @intCast(sites.items.len), .last = @intCast(sites.items.len) });
                    try sites.append(allocator, site);
                }
                if (sites.items.len == max_occurrences) break :discovery;
            }
        }
    }
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(allocator);
    for (shapes.items) |*shape| {
        if (shape.count < 3) continue;
        const args = Arguments.plain(shape.variants);
        var site_id = shape.first;
        while (site_id != absent) : (site_id = sites.items[site_id].next) {
            const site = sites.items[site_id];
            const range = bounds(inputs[site.body], site);
            scratch.clearRetainingCapacity();
            try siteBytes(&scratch, allocator, inputs[site.body], site, &args, max_functions -| 1);
            shape.saving += @as(i64, @intCast(range.end - range.start)) - @as(i64, @intCast(scratch.items.len));
        }
        const first = sites.items[shape.first];
        const range = bounds(inputs[first.body], first);
        shape.saving -= @intCast(range.end - range.start + 100);
    }
    std.mem.sort(Shape, shapes.items, {}, struct {
        fn less(_: void, lhs: Shape, rhs: Shape) bool {
            return if (lhs.saving == rhs.saving) lhs.first < rhs.first else lhs.saving > rhs.saving;
        }
    }.less);
    var selected: std.ArrayList(Replacement) = .empty;
    defer selected.deinit(allocator);
    var plans: std.ArrayList(Arguments) = .empty;
    defer plans.deinit(allocator);
    var pending: std.ArrayList(Replacement) = .empty;
    defer pending.deinit(allocator);
    const offsets = try allocator.alloc(usize, inputs.len + 1);
    defer allocator.free(offsets);
    offsets[0] = 0;
    for (inputs, 0..) |input, index| offsets[index + 1] = offsets[index] + input.ops.len;
    const used = try allocator.alloc(bool, offsets[inputs.len]);
    defer allocator.free(used);
    @memset(used, false);
    var helper: std.ArrayList(u8) = .empty;
    defer helper.deinit(allocator);
    var encoding: std.ArrayList(u8) = .empty;
    defer encoding.deinit(allocator);
    for (shapes.items) |shape| {
        if (shape.saving < 64) break;
        if (first_helper + result.helpers.items.len >= max_functions or type_base + result.types.items.len >= max_types) break;
        const helper_id = first_helper + @as(u32, @intCast(result.helpers.items.len));
        pending.clearRetainingCapacity();
        var site_id = shape.first;
        while (site_id != absent) : (site_id = sites.items[site_id].next) {
            const site = sites.items[site_id];
            if (std.mem.indexOfScalar(bool, used[offsets[site.body] + site.start ..][0..site.count], true) != null) continue;
            if (pending.items.len != 0) {
                const previous = pending.items[pending.items.len - 1].site;
                if (previous.body == site.body and previous.start + previous.count > site.start) continue;
            }
            try pending.append(allocator, .{ .site = site, .helper = helper_id, .plan = @intCast(plans.items.len) });
        }
        if (pending.items.len < 3) continue;
        const first = pending.items[0].site;
        var best_saving: i64 = 63;
        var best_args: ?Arguments = null;
        for ([_]Arguments{ Arguments.plain(shape.variants), packedArguments(inputs, pending.items, shape.variants) }) |args| {
            var saving: i64 = 0;
            for (pending.items) |replacement| {
                const site = replacement.site;
                scratch.clearRetainingCapacity();
                try siteBytes(&scratch, allocator, inputs[site.body], site, &args, helper_id);
                const range = bounds(inputs[site.body], site);
                saving += @as(i64, @intCast(range.end - range.start)) - @as(i64, @intCast(scratch.items.len));
            }
            helper.clearRetainingCapacity();
            encoding.clearRetainingCapacity();
            try helperBytes(&helper, &encoding, allocator, inputs[first.body], first, &args);
            saving -= @intCast(helper.items.len + encoding.items.len + 16);
            if (saving <= best_saving) continue;
            best_saving = saving;
            best_args = args;
        }
        const args = best_args orelse continue;
        helper.clearRetainingCapacity();
        encoding.clearRetainingCapacity();
        try helperBytes(&helper, &encoding, allocator, inputs[first.body], first, &args);
        try result.helper_types.append(allocator, type_base + @as(u32, @intCast(result.types.items.len)));
        try result.helpers.ensureUnusedCapacity(allocator, 1);
        try result.types.ensureUnusedCapacity(allocator, 1);
        result.helpers.appendAssumeCapacity(try allocator.dupe(u8, helper.items));
        result.types.appendAssumeCapacity(try allocator.dupe(u8, encoding.items));
        try plans.append(allocator, args);
        try selected.appendSlice(allocator, pending.items);
        for (pending.items) |replacement| {
            const site = replacement.site;
            @memset(used[offsets[site.body] + site.start ..][0..site.count], true);
        }
    }
    std.mem.sort(Replacement, selected.items, {}, struct {
        fn less(_: void, lhs: Replacement, rhs: Replacement) bool {
            return if (lhs.site.body == rhs.site.body) lhs.site.start < rhs.site.start else lhs.site.body < rhs.site.body;
        }
    }.less);
    var next: usize = 0;
    for (inputs, 0..) |input, body_id| {
        scratch.clearRetainingCapacity();
        var cursor: usize = 0;
        while (next < selected.items.len and selected.items[next].site.body == body_id) : (next += 1) {
            const replacement = selected.items[next];
            const range = bounds(input, replacement.site);
            try scratch.appendSlice(allocator, input.bytes[cursor..range.start]);
            try siteBytes(&scratch, allocator, input, replacement.site, &plans.items[replacement.plan], replacement.helper);
            cursor = range.end;
        }
        try scratch.appendSlice(allocator, input.bytes[cursor..]);
        try result.bodies.ensureUnusedCapacity(allocator, 1);
        result.bodies.appendAssumeCapacity(try allocator.dupe(u8, scratch.items));
    }
    return result;
}

test "constant argument packing preserves signed endpoints and narrow fields" {
    const values = [_][4]i32{
        .{ std.math.minInt(i32), -1001, 7, 9000 },
        .{ std.math.maxInt(i32), -1000, 8, 9001 },
        .{ 0, -999, 9, 9002 },
    };
    var ops: [3][4]Op = undefined;
    var inputs: [3]Input = undefined;
    var replacements: [3]Replacement = undefined;
    for (values, &ops, &inputs, &replacements, 0..) |row, *instructions, *input, *replacement, body| {
        for (row, instructions) |value, *op| op.* = .{ .at = 0, .len = 1, .class = 1, .op = 0x41, .imm = value };
        input.* = .{ .bytes = &.{}, .ops = instructions, .locals = &.{} };
        replacement.* = .{ .site = .{ .body = @intCast(body), .start = 0, .count = 4 }, .helper = 0, .plan = 0 };
    }
    const args = packedArguments(&inputs, &replacements, 15);
    try std.testing.expectEqual(@as(u8, 2), args.count);
    try std.testing.expectEqual(@as(u8, 32), args.bits[0]);
    for (values) |row| {
        var words = [_]u32{0} ** max_constants;
        for (row, 0..) |value, index| {
            words[args.word[index]] |= (@as(u32, @bitCast(value)) -% @as(u32, @bitCast(args.minimum[index]))) << args.shift[index];
        }
        for (row, 0..) |value, index| {
            const mask: u32 = if (args.bits[index] == 32) std.math.maxInt(u32) else (@as(u32, 1) << @intCast(args.bits[index])) - 1;
            const restored = ((words[args.word[index]] >> args.shift[index]) & mask) +% @as(u32, @bitCast(args.minimum[index]));
            try std.testing.expectEqual(@as(u32, @bitCast(value)), restored);
        }
    }
}

test "region boundaries reject control transfers and stack underflow" {
    const signatures = [_]Signature{.{ .params = &.{ 0x7c, 0x7f }, .results = &.{0x7e} }};
    const ordinary = Op{ .at = 0, .len = 1, .class = 0, .op = 0x10, .imm = 0 };
    const call = effect(ordinary, &signatures).?;
    try std.testing.expectEqual(@as(u32, 2), call.take);
    try std.testing.expectEqual(@as(u32, 1), call.give);
    for ([_]u8{ 0x02, 0x03, 0x04, 0x05, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x11 }) |opcode| {
        var op = ordinary;
        op.op = opcode;
        try std.testing.expect(effect(op, &signatures) == null);
    }
    const allocator = std.testing.allocator;
    const bytes = [_]u8{ 0x21, 0 } ** 20;
    var operations: [20]Op = undefined;
    for (&operations, 0..) |*op, index| op.* = .{ .at = @intCast(index * 2), .len = 2, .class = 2, .op = 0x21, .imm = 0 };
    const input = Input{ .bytes = &bytes, .ops = &operations, .locals = &.{0x7f} };
    var result = try share(allocator, &.{ input, input, input }, &signatures, 1, 1, 10, 10);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), result.helpers.items.len);
}

const std = @import("std");

pub const Error = std.mem.Allocator.Error || error{InvalidCode};
pub const Op = struct { at: u32, len: u16, class: u8, op: u8, imm: i32 };
const absent = std.math.maxInt(u32);
const Edge = struct { source: u32, next: u32 };
const Replacement = struct { start: u32, finish: u32, depth: u32 };

fn readIndex(bytes: []const u8, cursor: *usize) Error!u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    for (0..5) |ordinal| {
        if (cursor.* >= bytes.len) return Error.InvalidCode;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        if (ordinal == 4 and byte > 15) return Error.InvalidCode;
        result |= @as(u32, byte & 127) << shift;
        if (byte & 128 == 0) return result;
        if (ordinal < 4) shift += 7;
    }
    return Error.InvalidCode;
}

fn appendIndex(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) Error!void {
    var remaining = value;
    while (true) {
        const byte: u8 = @intCast(remaining & 127);
        remaining >>= 7;
        try output.append(allocator, byte | @as(u8, if (remaining != 0) 128 else 0));
        if (remaining == 0) return;
    }
}

fn addEdge(allocator: std.mem.Allocator, edges: *std.ArrayList(Edge), heads: []u32, source: u32, target: u32) Error!void {
    if (target >= heads.len) return;
    const next = heads[target];
    heads[target] = @intCast(edges.items.len);
    try edges.append(allocator, .{ .source = source, .next = next });
}

fn branchLabel(stack: []const u32, depth: u32) Error!u32 {
    if (depth > stack.len) return Error.InvalidCode;
    return if (depth == stack.len) absent else stack[stack.len - 1 - depth];
}

fn destination(ops: []const Op, ends: []const u32, label: u32) u32 {
    if (label == absent) return @intCast(ops.len);
    return if (ops[label].op == 0x03) label + 1 else ends[label] + 1;
}

fn selectorBase(ops: []const Op, index: usize) ?u32 {
    if (index > 0 and ops[index - 1].op == 0x20 and ops[index - 1].imm == 3) return 0;
    if (index < 7 or index + 4 >= ops.len) return null;
    const window = ops[index - 7 .. index + 5];
    if (window[0].op != 0x20 or window[0].imm != 3 or window[1].op != 0x41 or
        window[1].imm <= 0 or window[2].op != 0x4f or window[3].op != 0x04 or
        window[4].op != 0x20 or window[4].imm != 3 or window[5].op != 0x41 or
        window[5].imm != window[1].imm or window[6].op != 0x6b or window[8].op != 0x05 or
        window[9].op != 0x20 or window[9].imm != 3 or window[10].op != 0x0e or window[11].op != 0x0b)
        return null;
    return @intCast(window[1].imm);
}

pub fn threadDispatch(allocator: std.mem.Allocator, body: []const u8, ops: []const Op) Error![]u8 {
    const ends = try allocator.alloc(u32, ops.len);
    defer allocator.free(ends);
    @memset(ends, absent);
    const alternatives = try allocator.alloc(u32, ops.len);
    defer allocator.free(alternatives);
    @memset(alternatives, absent);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(allocator);
    for (ops, 0..) |item, index| {
        switch (item.op) {
            0x02, 0x03, 0x04 => try stack.append(allocator, @intCast(index)),
            0x05 => {
                if (stack.items.len == 0) return Error.InvalidCode;
                const label = stack.items[stack.items.len - 1];
                if (ops[label].op != 0x04 or alternatives[label] != absent) return Error.InvalidCode;
                alternatives[label] = @intCast(index);
            },
            0x0b => if (stack.pop()) |label| {
                ends[label] = @intCast(index);
                if (alternatives[label] != absent) ends[alternatives[label]] = @intCast(index);
            } else if (index + 1 != ops.len) return Error.InvalidCode,
            else => {},
        }
    }
    if (stack.items.len != 0) return Error.InvalidCode;

    const heads = try allocator.alloc(u32, ops.len);
    defer allocator.free(heads);
    @memset(heads, absent);
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(allocator);
    var dispatch_labels: std.ArrayList(u32) = .empty;
    defer dispatch_labels.deinit(allocator);
    var dispatch_loop: u32 = absent;
    var page_if: u32 = absent;
    const branch_labels = try allocator.alloc(u32, ops.len);
    defer allocator.free(branch_labels);
    @memset(branch_labels, absent);
    for (ops, 0..) |item, index| {
        const source: u32 = @intCast(index);
        switch (item.op) {
            0x02, 0x03, 0x04 => {
                try stack.append(allocator, source);
                try addEdge(allocator, &edges, heads, source, source + 1);
                if (item.op == 0x04) try addEdge(allocator, &edges, heads, source, if (alternatives[index] == absent) ends[index] + 1 else alternatives[index] + 1);
            },
            0x05 => try addEdge(allocator, &edges, heads, source, ends[index] + 1),
            0x0b => {
                _ = stack.pop();
                try addEdge(allocator, &edges, heads, source, source + 1);
            },
            0x0c, 0x0d => {
                const label = try branchLabel(stack.items, @bitCast(item.imm));
                branch_labels[index] = label;
                try addEdge(allocator, &edges, heads, source, destination(ops, ends, label));
                if (item.op == 0x0d) try addEdge(allocator, &edges, heads, source, source + 1);
            },
            0x0e => {
                var cursor: usize = item.at + 1;
                const count = try readIndex(body, &cursor);
                const base = selectorBase(ops, index);
                var loop_label: u32 = absent;
                var suitable = base != null;
                for (stack.items) |label| {
                    if (ops[label].op == 0x03) loop_label = label;
                    if (ops[label].op == 0x04 and label != page_if and (base == null or base.? == 0 or label != index - 4)) suitable = false;
                }
                suitable = suitable and loop_label != absent and (dispatch_loop == absent or dispatch_loop == loop_label);
                if (suitable) {
                    const selector_start = if (base.? != 0) index - 7 else if (page_if != absent and std.mem.indexOfScalar(u32, stack.items, page_if) != null) page_if - 3 else index - 1;
                    if (body[ops[loop_label].at + 1] != 0x40) suitable = false;
                    for (ops[loop_label + 1 .. selector_start]) |header| {
                        if (header.op != 0x02 or body[header.at + 1] != 0x40) suitable = false;
                    }
                }
                if (suitable) {
                    const size = std.math.add(u32, base.?, count) catch return Error.InvalidCode;
                    if (size > body.len) return Error.InvalidCode;
                    if (size > dispatch_labels.items.len) {
                        const old_len = dispatch_labels.items.len;
                        try dispatch_labels.resize(allocator, size);
                        @memset(dispatch_labels.items[old_len..], absent);
                    }
                    dispatch_loop = loop_label;
                    if (base.? != 0) page_if = @intCast(index - 4);
                }
                for (0..@as(usize, count) + 1) |entry| {
                    const label = try branchLabel(stack.items, try readIndex(body, &cursor));
                    try addEdge(allocator, &edges, heads, source, destination(ops, ends, label));
                    if (suitable and entry < count) {
                        if (label == absent or ops[label].op != 0x02 or body[ops[label].at + 1] != 0x40) return Error.InvalidCode;
                        dispatch_labels.items[base.? + entry] = label;
                    }
                }
            },
            0x00, 0x0f => {},
            else => try addEdge(allocator, &edges, heads, source, source + 1),
        }
    }
    if (dispatch_loop == absent) return allocator.dupe(u8, body);

    const live = try allocator.alloc(bool, ops.len);
    defer allocator.free(live);
    @memset(live, false);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(allocator);
    for (ops, 0..) |item, index| {
        if (item.op == 0x20 and item.imm == 3) {
            live[index] = true;
            try work.append(allocator, @intCast(index));
        }
    }
    while (work.pop()) |index| {
        var edge_index = heads[index];
        while (edge_index != absent) {
            const edge = edges.items[edge_index];
            const item = ops[edge.source];
            if (!live[edge.source] and !((item.op == 0x21 or item.op == 0x22) and item.imm == 3)) {
                live[edge.source] = true;
                try work.append(allocator, edge.source);
            }
            edge_index = edge.next;
        }
    }
    var replacements: std.ArrayList(Replacement) = .empty;
    defer replacements.deinit(allocator);
    const active_depth = alternatives;
    @memset(active_depth, absent);
    for (ops, 0..) |item, index| {
        if (item.op == 0x02 or item.op == 0x03 or item.op == 0x04) {
            active_depth[index] = @intCast(stack.items.len);
            try stack.append(allocator, @intCast(index));
        }
        if (item.op == 0x0b) {
            if (stack.pop()) |label| active_depth[label] = absent;
        }
        if (item.op != 0x0c or branch_labels[index] != dispatch_loop or index < 2) continue;
        const store = ops[index - 1];
        const value = ops[index - 2];
        if (store.op != 0x21 or store.imm != 3 or value.op != 0x41 or value.imm < 0 or value.imm >= dispatch_labels.items.len) continue;
        const label = dispatch_labels.items[@intCast(value.imm)];
        if (label == absent) continue;
        const target = destination(ops, ends, label);
        if (target < live.len and live[target]) continue;
        if (active_depth[label] == absent) continue;
        try replacements.append(allocator, .{ .start = value.at, .finish = item.at + item.len, .depth = @intCast(stack.items.len - 1 - active_depth[label]) });
    }
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var cursor: usize = 0;
    for (replacements.items) |replacement| {
        try output.appendSlice(allocator, body[cursor..replacement.start]);
        try output.append(allocator, 0x0c);
        try appendIndex(&output, allocator, replacement.depth);
        cursor = replacement.finish;
    }
    try output.appendSlice(allocator, body[cursor..]);
    return output.toOwnedSlice(allocator);
}

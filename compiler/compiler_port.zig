const std = @import("std");
const host = @import("luauc_compiler_host");
const source_package = @import("luauc_source_package_v1");

// The supervising host owns the 120 second request deadline. This process does not arm a timer.

const allocator = std.heap.c_allocator;

fn readLength(reader: *std.Io.Reader) !?u32 {
    var bytes: [4]u8 = undefined;
    var index: usize = 0;
    while (index < 4) {
        bytes[index] = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (index == 0) return null;
                return error.Truncated;
            },
            else => return err,
        };
        index += 1;
    }
    return std.mem.readInt(u32, &bytes, .little);
}

fn writeResponse(writer: *std.Io.Writer, status: u32, diagnostic: []const u8, artifact: []const u8) !void {
    try writer.writeInt(u32, status, .little);
    try writer.writeInt(u32, @intCast(diagnostic.len), .little);
    try writer.writeAll(diagnostic);
    try writer.writeInt(u32, @intCast(artifact.len), .little);
    try writer.writeAll(artifact);
    try writer.flush();
}

fn reject(writer: *std.Io.Writer) !void {
    try writeResponse(writer, 1, "InvalidArgument", &.{});
}

pub fn main(init: std.process.Init) u8 {
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const profile_path = arguments.next() orelse return 1;
    const pack_path = arguments.next() orelse return 1;
    if (arguments.next() != null) return 1;

    const profile_bytes = std.Io.Dir.cwd().readFileAlloc(init.io, profile_path, allocator, .limited(256 * 1024)) catch return 1;
    defer allocator.free(profile_bytes);
    const pack_bytes = std.Io.Dir.cwd().readFileAlloc(init.io, pack_path, allocator, .limited(32 * 1024 * 1024)) catch return 1;
    defer allocator.free(pack_bytes);

    const created = host.contextCreate(profile_bytes, pack_bytes);
    if (created.status != 0) return @intCast(created.status);
    defer _ = host.contextDestroy(created.handle);

    var in_buffer: [4096]u8 = undefined;
    var file_reader = std.Io.File.stdin().readerStreaming(init.io, &in_buffer);
    const reader = &file_reader.interface;
    var out_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &out_buffer);
    const writer = &file_writer.interface;

    while (true) {
        const length = readLength(reader) catch |err| switch (err) {
            error.Truncated => {
                reject(writer) catch return 1;
                return 0;
            },
            else => return 1,
        } orelse return 0;
        if (length > source_package.max_request_bytes) {
            reject(writer) catch return 1;
            return 0;
        }
        const request = allocator.alloc(u8, length) catch return 1;
        defer allocator.free(request);
        reader.readSliceAll(request) catch {
            reject(writer) catch return 1;
            return 0;
        };
        var guest = host.compile(created.handle, request);
        defer host.freeGuest(&guest);
        const artifact = if (guest.status == 0) guest.artifact else &.{};
        writeResponse(writer, guest.status, guest.diagnostic, artifact) catch return 1;
    }
}

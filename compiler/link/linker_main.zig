const std = @import("std");
const linker = @import("luauc_linker");
const runtime_profile = @import("luauc_runtime_profile_v1");

pub fn main(init: std.process.Init) !void {
    var arguments = try init.minimal.args.iterateAllocator(init.gpa);
    defer arguments.deinit();
    _ = arguments.next();
    const profile_path = arguments.next() orelse return error.MissingRuntimeProfile;
    const runtime_path = arguments.next() orelse return error.MissingRuntimePack;
    const object_path = arguments.next() orelse return error.MissingPackageObject;
    if (arguments.next() != null)
        return error.UnexpectedArgument;

    const profile_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, profile_path, init.gpa, .limited(256 * 1024));
    defer init.gpa.free(profile_bytes);
    const profile = try runtime_profile.parse(profile_bytes);
    const runtime_pack = try std.Io.Dir.cwd().readFileAlloc(init.io, runtime_path, init.gpa, .limited(32 * 1024 * 1024));
    defer init.gpa.free(runtime_pack);
    try runtime_profile.validatePackManifest(runtime_pack, profile_bytes);
    const package_object = try std.Io.Dir.cwd().readFileAlloc(init.io, object_path, init.gpa, .limited(32 * 1024 * 1024));
    defer init.gpa.free(package_object);
    const result = try linker.link(init.gpa, runtime_pack, package_object, profile, .{});
    defer init.gpa.free(result.bytes);
    try std.Io.File.writeStreamingAll(.stdout(), init.io, result.bytes);
}

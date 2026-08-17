const std = @import("std");
const compiler_result = @import("luauc_compiler_result_v1");

test "CompileResultV1 offsets and diagnostic record size" {
    try std.testing.expectEqual(@as(usize, 320), @sizeOf(compiler_result.CompileResultV1));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(compiler_result.DiagnosticRecord));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(compiler_result.CompileResultV1, "data"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(compiler_result.CompileResultV1, "status"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(compiler_result.CompileResultV1, "request_id"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(compiler_result.CompileResultV1, "compiler_build_sha256"));
    try std.testing.expectEqual(@as(usize, 232), @offsetOf(compiler_result.CompileResultV1, "artifact_sha256"));
    try std.testing.expectEqual(@as(usize, 264), @offsetOf(compiler_result.CompileResultV1, "generated_function_count"));
    try std.testing.expectEqual(@as(usize, 272), @offsetOf(compiler_result.CompileResultV1, "diagnostic_records_ptr"));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), compiler_result.no_module);
}

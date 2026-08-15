pub const status_ok: u32 = 0;
pub const status_invalid_argument: u32 = 1;
pub const status_compile_failure: u32 = 2;
pub const status_resource_limit: u32 = 3;

pub const Result = extern struct {
    data: u32 = 0,
    size: u32 = 0,
    status: u32 = status_compile_failure,
    reserved: u32 = 0,
    diagnostic: u32 = 0,
    diagnostic_size: u32 = 0,
};

comptime {
    if (@sizeOf(Result) != 24)
        @compileError("backend component ABI layout drift");
}

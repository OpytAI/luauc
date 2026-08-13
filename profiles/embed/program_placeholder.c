#include <stdint.h>

__attribute__((weak, aligned(16))) unsigned char luauc_runtime_v1_program[68];
const void *luauc_runtime_v1_program_pointer = luauc_runtime_v1_program;

__attribute__((aligned(16))) unsigned char luauc_runtime_v1_program_arena[8 * 1024 * 1024];
const uint32_t luauc_runtime_v1_program_arena_capacity = sizeof(luauc_runtime_v1_program_arena);

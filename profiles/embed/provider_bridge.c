#include <stdint.h>

#ifndef LUAUC_EMBED_HOST_MODULE
#define LUAUC_EMBED_HOST_MODULE "luauc_embed_v1"
#endif

typedef void (*LuaucProtectedThunk)(void *);

__attribute__((import_module(LUAUC_EMBED_HOST_MODULE), import_name("protected_call")))
extern uint32_t luauc_embed_host_protected_call(void);

__attribute__((import_module(LUAUC_EMBED_HOST_MODULE), import_name("set_throw")))
extern void luauc_embed_host_set_throw(uint32_t code);

static LuaucProtectedThunk active_thunk;
static void *active_context;

int luauc_runtime_v1_protected_call(LuaucProtectedThunk thunk, void *context) {
    LuaucProtectedThunk saved_thunk = active_thunk;
    void *saved_context = active_context;
    active_thunk = thunk;
    active_context = context;
    uint32_t status = luauc_embed_host_protected_call();
    active_thunk = saved_thunk;
    active_context = saved_context;
    return (int)status;
}

void luauc_embed_v1_protected_call_run(void) {
    if (active_thunk)
        active_thunk(active_context);
}

__attribute__((noreturn)) void luauc_runtime_v1_raise(int code) {
    luauc_embed_host_set_throw((uint32_t)code);
    __builtin_trap();
}

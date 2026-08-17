#include "aot_runtime_v1.h"
#include "lua.h"
#include "lualib.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct LuaucEmbedContext {
    lua_State *state;
} LuaucEmbedContext;

typedef struct LuaucEmbedInvokeRequestV1 {
    uint32_t version;
    uint32_t struct_size;
    int64_t number;
    uint32_t text_pointer;
    uint32_t text_size;
    uint32_t output_pointer;
    uint32_t output_capacity;
} LuaucEmbedInvokeRequestV1;

typedef struct LuaucEmbedInvokeResultV1 {
    uint32_t status;
    uint32_t flags;
    int64_t number;
    uint32_t output_size;
    uint32_t reserved0;
    uint64_t reserved1;
} LuaucEmbedInvokeResultV1;

typedef struct LuaucEmbedCoverageRecordV1 {
    uint32_t function_index;
    uint32_t depth;
    uint32_t line;
    uint32_t hits;
} LuaucEmbedCoverageRecordV1;

typedef struct LuaucEmbedCoverageResultV1 {
    uint32_t status;
    uint32_t record_count;
    uint32_t required_capacity;
    uint32_t reserved;
} LuaucEmbedCoverageResultV1;

typedef struct LuaucEmbedCoverageCollector {
    LuaucEmbedCoverageRecordV1 *records;
    uint32_t capacity;
    uint32_t count;
    uint32_t function_index;
    uint32_t overflow;
    uint32_t truncated;
} LuaucEmbedCoverageCollector;

static char context_error[512];
static uint32_t context_error_size;

static int embedStamp(lua_State *L) {
    lua_pushinteger(L, 1);
    return 1;
}

static int embedIterNext(lua_State *L) {
    const int control = lua_tointeger(L, 2);
    if (control != 0) {
        lua_pushnil(L);
        return 1;
    }
    int *seed = (int *)lua_touserdatatagged(L, 1, 0);
    lua_pushinteger(L, 1);
    lua_pushinteger(L, seed ? *seed : 0);
    return 2;
}

static int embedIter(lua_State *L) {
    lua_pushcfunction(L, embedIterNext, "next");
    lua_pushvalue(L, 1);
    lua_pushinteger(L, 0);
    return 3;
}

static int embedNewIter(lua_State *L) {
    const int seed = (int)luaL_checkinteger(L, 1);
    int *payload = (int *)lua_newuserdatatagged(L, sizeof(int), 0);
    *payload = seed;
    lua_createtable(L, 0, 1);
    lua_pushcfunction(L, embedIter, "__iter");
    lua_setfield(L, -2, "__iter");
    lua_setreadonly(L, -1, 1);
    lua_setmetatable(L, -2);
    return 1;
}

enum { kEmbedVec2Tag = 12 };

// embed.vec2 contract: Unit = normalize; Mark returns payload[0].
// Keep frontend_adapter.cpp, interpreter/main.cpp, provider_entry.c identical.
static void embedVec2Normalize(float *dst, const float *src) {
    const float x = src ? src[0] : 0;
    const float y = src ? src[1] : 0;
    const float len = sqrtf(x * x + y * y);
    if (len == 0) {
        dst[0] = 0;
        dst[1] = 0;
        return;
    }
    dst[0] = x / len;
    dst[1] = y / len;
}

static int embedVec2Mark(lua_State *L) {
    luaL_checktype(L, 2, LUA_TTABLE);
    lua_pushvalue(L, 1);
    lua_rawseti(L, 2, 1);
    float *src = (float *)lua_touserdatatagged(L, 1, kEmbedVec2Tag);
    lua_pushnumber(L, src ? src[0] : 0);
    return 1;
}

static int embedVec2Index(lua_State *L) {
    size_t key_size = 0;
    const char *key = luaL_checklstring(L, 2, &key_size);
    if (key_size == 4 && memcmp(key, "Unit", 4) == 0) {
        float *src = (float *)lua_touserdatatagged(L, 1, kEmbedVec2Tag);
        float *payload = (float *)lua_newuserdatataggedwithmetatable(L, sizeof(float) * 2, kEmbedVec2Tag);
        embedVec2Normalize(payload, src);
        return 1;
    }
    if (key_size == 4 && memcmp(key, "Mark", 4) == 0) {
        lua_pushcfunction(L, embedVec2Mark, "Mark");
        return 1;
    }
    luaL_error(L, "invalid vec2 index");
    return 0;
}

static int embedVec2Namecall(lua_State *L) {
    const char *name = lua_namecallatom(L, NULL);
    if (name && strcmp(name, "Mark") == 0)
        return embedVec2Mark(L);
    luaL_error(L, "invalid vec2 namecall");
    return 0;
}

static int embedNewVec2(lua_State *L) {
    const float seed = (float)luaL_checknumber(L, 1);
    float *payload = (float *)lua_newuserdatataggedwithmetatable(L, sizeof(float) * 2, kEmbedVec2Tag);
    payload[0] = seed;
    payload[1] = seed;
    return 1;
}

static void publishVec2Metatable(lua_State *L) {
    lua_createtable(L, 0, 2);
    lua_pushcfunction(L, embedVec2Index, "__index");
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, embedVec2Namecall, "__namecall");
    lua_setfield(L, -2, "__namecall");
    lua_setreadonly(L, -1, 1);
    lua_setuserdatametatable(L, kEmbedVec2Tag);
}

static void publishEmbedImport(lua_State *L) {
    publishVec2Metatable(L);
    lua_createtable(L, 0, 3);
    lua_createtable(L, 0, 1);
    lua_pushcfunction(L, embedStamp, "stamp");
    lua_setfield(L, -2, "stamp");
    lua_setfield(L, -2, "util");
    lua_pushcfunction(L, embedNewIter, "iter");
    lua_setfield(L, -2, "iter");
    lua_pushcfunction(L, embedNewVec2, "vec2");
    lua_setfield(L, -2, "vec2");
    lua_setglobal(L, "embed");
}

static void setContextError(const char *message, size_t size) {
    if (!message) {
        context_error_size = 0;
        return;
    }
    if (size > sizeof(context_error))
        size = sizeof(context_error);
    memcpy(context_error, message, size);
    context_error_size = (uint32_t)size;
}

static void collectCoverage(void *context, const char *, int, int depth, const int *hits,
                            size_t size) {
    LuaucEmbedCoverageCollector *collector = (LuaucEmbedCoverageCollector *)context;
    for (size_t line = 0; line < size; ++line) {
        if (hits[line] < 0)
            continue;
        if (collector->count == UINT32_MAX) {
            collector->overflow = 1;
            continue;
        }
        if (collector->count < collector->capacity) {
            LuaucEmbedCoverageRecordV1 *record = &collector->records[collector->count];
            record->function_index = collector->function_index;
            record->depth = (uint32_t)depth;
            record->line = (uint32_t)line;
            record->hits = (uint32_t)hits[line];
        } else {
            collector->truncated = 1;
        }
        ++collector->count;
    }
    ++collector->function_index;
}

extern const LuaucRuntimeProgramV1 *luauc_runtime_v1_program_pointer;

uint32_t luauc_embed_v1_alloc(uint32_t size) {
    return size == 0 ? 0 : (uint32_t)(uintptr_t)malloc(size);
}

uint32_t luauc_embed_v1_last_error(void) {
    return (uint32_t)(uintptr_t)context_error;
}

uint32_t luauc_embed_v1_last_error_size(void) {
    return context_error_size;
}

void luauc_embed_v1_dealloc(uint32_t pointer) {
    free((void *)(uintptr_t)pointer);
}

uint32_t luauc_embed_v1_context_create(void) {
    context_error_size = 0;
    LuaucEmbedContext *context = (LuaucEmbedContext *)calloc(1, sizeof(LuaucEmbedContext));
    if (!context) {
        static const char message[] = "embed context allocation failed";
        setContextError(message, sizeof(message) - 1);
        return 0;
    }
    context->state = luaL_newstate();
    if (!context->state) {
        static const char message[] = "Luau state allocation failed";
        setContextError(message, sizeof(message) - 1);
        free(context);
        return 0;
    }
    luaL_openlibs(context->state);
    publishEmbedImport(context->state);
    luaL_sandbox(context->state);
    static const char source_name[] = "@main.luau";
    const int push_status = luauc_runtime_v1_push_program(
        context->state, luauc_runtime_v1_program_pointer, source_name, sizeof(source_name) - 1);
    const int call_status = push_status == 0 ? lua_pcall(context->state, 0, 1, 0) : LUA_ERRRUN;
    if (push_status != 0 || call_status != 0 || !lua_isfunction(context->state, -1)) {
        size_t error_size = 0;
        const char *error = lua_gettop(context->state) > 0
                                ? lua_tolstring(context->state, -1, &error_size)
                                : NULL;
        if (error) {
            setContextError(error, error_size);
        } else {
            const int length = snprintf(
                context_error, sizeof(context_error),
                "Luau initialization failed: push=%d call=%d top=%d type=%s", push_status,
                call_status, lua_gettop(context->state),
                lua_typename(context->state, lua_type(context->state, -1)));
            context_error_size = length < 0 ? 0 : (uint32_t)length;
            if (context_error_size >= sizeof(context_error))
                context_error_size = sizeof(context_error) - 1;
        }
        lua_close(context->state);
        free(context);
        return 0;
    }
    return (uint32_t)(uintptr_t)context;
}

void luauc_embed_v1_context_destroy(uint32_t handle) {
    LuaucEmbedContext *context = (LuaucEmbedContext *)(uintptr_t)handle;
    if (!context)
        return;
    lua_close(context->state);
    free(context);
}

uint32_t luauc_embed_v1_coverage(uint32_t handle, uint32_t output_pointer,
                                 uint32_t output_capacity, uint32_t result_pointer) {
    LuaucEmbedContext *context = (LuaucEmbedContext *)(uintptr_t)handle;
    LuaucEmbedCoverageResultV1 *result =
        (LuaucEmbedCoverageResultV1 *)(uintptr_t)result_pointer;
    if (!context || !result || (output_capacity != 0 && !output_pointer))
        return 1;
    memset(result, 0, sizeof(*result));
    LuaucEmbedCoverageCollector collector = {
        (LuaucEmbedCoverageRecordV1 *)(uintptr_t)output_pointer,
        output_capacity / sizeof(LuaucEmbedCoverageRecordV1), 0, 0, 0, 0,
    };
    if (luauc_runtime_v1_get_program_coverage(context->state, &collector, collectCoverage) != 0) {
        result->status = 1;
        return 1;
    }
    result->record_count = collector.count;
    if (collector.overflow || collector.count > UINT32_MAX / sizeof(LuaucEmbedCoverageRecordV1)) {
        result->required_capacity = UINT32_MAX;
        result->status = 2;
        return 2;
    }
    result->required_capacity = collector.count * sizeof(LuaucEmbedCoverageRecordV1);
    if (collector.truncated) {
        result->status = 2;
        return 2;
    }
    return 0;
}

uint32_t luauc_embed_v1_invoke(uint32_t handle, uint32_t request_pointer,
                               uint32_t request_size, uint32_t result_pointer) {
    LuaucEmbedContext *context = (LuaucEmbedContext *)(uintptr_t)handle;
    LuaucEmbedInvokeResultV1 *result = (LuaucEmbedInvokeResultV1 *)(uintptr_t)result_pointer;
    if (!context || !request_pointer || request_size != sizeof(LuaucEmbedInvokeRequestV1) || !result)
        return 1;
    const LuaucEmbedInvokeRequestV1 *request =
        (const LuaucEmbedInvokeRequestV1 *)(uintptr_t)request_pointer;
    memset(result, 0, sizeof(*result));
    if (request->version != 1 || request->struct_size != sizeof(*request) ||
        (!request->text_pointer && request->text_size) ||
        (!request->output_pointer && request->output_capacity)) {
        result->status = 1;
        return 1;
    }

    lua_State *state = context->state;
    lua_settop(state, 1);
    lua_State *thread = lua_newthread(state);
    lua_pushvalue(state, 1);
    lua_xmove(state, thread, 1);
    lua_pushinteger(thread, request->number);
    lua_pushlstring(thread, (const char *)(uintptr_t)request->text_pointer, request->text_size);

    int status = lua_resume(thread, state, 2);
    static const char gc_boundary[] = "gc-boundary";
    size_t yielded_size = 0;
    uint32_t suspension_count = 0;
    while (status == LUA_YIELD && suspension_count < 64) {
        const char *yielded = lua_gettop(thread) == 1 ? lua_tolstring(thread, -1, &yielded_size) : NULL;
        if (!yielded || yielded_size != sizeof(gc_boundary) - 1 ||
            memcmp(yielded, gc_boundary, sizeof(gc_boundary) - 1) != 0) {
            result->status = 3;
            lua_settop(state, 1);
            return 3;
        }

        // The suspended AOT thread remains rooted by the thread object on the main state's stack.
        // Collect the complete VM heap before every generated continuation re-enters the function.
        lua_settop(thread, 0);
        lua_gc(state, LUA_GCCOLLECT, 0);
        status = lua_resume(thread, state, 0);
        suspension_count++;
    }
    if (status != LUA_OK) {
        char diagnostic[128];
        const int top = lua_gettop(thread);
        const char *yielded = top > 0 ? lua_tolstring(thread, -1, &yielded_size) : NULL;
        const char *failure = yielded;
        if (!failure) {
            const int value_type = top == 0 ? LUA_TNONE : lua_type(thread, -1);
            const int length = snprintf(diagnostic, sizeof(diagnostic),
                                        "Luau suspension failure: status=%d top=%d type=%s", status,
                                        top, lua_typename(thread, value_type));
            failure = diagnostic;
            yielded_size = length < 0 ? 0 : (size_t)length;
            if (yielded_size >= sizeof(diagnostic))
                yielded_size = sizeof(diagnostic) - 1;
        }
        if (yielded_size <= request->output_capacity) {
            memcpy((void *)(uintptr_t)request->output_pointer, failure, yielded_size);
            result->output_size = (uint32_t)yielded_size;
        }
        result->flags = 1;
        result->status = 3;
        lua_settop(state, 1);
        return 3;
    }
    size_t output_size = 0;
    const char *output = lua_tolstring(thread, -1, &output_size);
    if (!output)
        output = "non-string Luau result", output_size = sizeof("non-string Luau result") - 1;
    if (output_size > request->output_capacity) {
        lua_settop(state, 1);
        result->status = 2;
        return 2;
    }
    memcpy((void *)(uintptr_t)request->output_pointer, output, output_size);
    result->output_size = (uint32_t)output_size;
    result->flags = status == 0 ? 0 : 1;
    if (status == LUA_OK && lua_isnumber(thread, -2))
        result->number = (int64_t)lua_tonumber(thread, -2);
    result->status = status == LUA_OK ? 0 : 3;
    lua_settop(state, 1);
    return result->status;
}

#include "aot_runtime_v1.h"
#include "lua.h"
#include "lualib.h"

#include <stdint.h>
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

void luauc_embed_v1_dealloc(uint32_t pointer) {
    free((void *)(uintptr_t)pointer);
}

uint32_t luauc_embed_v1_context_create(void) {
    LuaucEmbedContext *context = (LuaucEmbedContext *)calloc(1, sizeof(LuaucEmbedContext));
    if (!context)
        return 0;
    context->state = luaL_newstate();
    if (!context->state) {
        free(context);
        return 0;
    }
    luaL_openlibs(context->state);
    luaL_sandbox(context->state);
    static const char source_name[] = "@main.luau";
    if (luauc_runtime_v1_push_program(context->state, luauc_runtime_v1_program_pointer,
                                      source_name, sizeof(source_name) - 1) != 0 ||
        lua_pcall(context->state, 0, 1, 0) != 0 || !lua_isfunction(context->state, -1)) {
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
    const char *yielded = lua_gettop(thread) == 1 ? lua_tolstring(thread, -1, &yielded_size) : NULL;
    if (status != LUA_YIELD || !yielded || yielded_size != sizeof(gc_boundary) - 1 ||
        memcmp(yielded, gc_boundary, sizeof(gc_boundary) - 1) != 0) {
        const char *failure = status == LUA_OK ? "compiled entry did not yield at the GC boundary"
                                               : lua_tolstring(thread, -1, &yielded_size);
        if (!failure)
            failure = "non-string Luau suspension failure",
            yielded_size = sizeof("non-string Luau suspension failure") - 1;
        else if (status == LUA_OK)
            yielded_size = sizeof("compiled entry did not yield at the GC boundary") - 1;
        if (yielded_size <= request->output_capacity) {
            memcpy((void *)(uintptr_t)request->output_pointer, failure, yielded_size);
            result->output_size = (uint32_t)yielded_size;
        }
        result->flags = 1;
        result->status = 3;
        lua_settop(state, 1);
        return 3;
    }

    // The suspended AOT thread remains rooted by the thread object on the main state's stack.
    // Collect the complete VM heap before resuming through generated CALL continuations.
    lua_settop(thread, 0);
    lua_gc(state, LUA_GCCOLLECT, 0);
    status = lua_resume(thread, state, 0);
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

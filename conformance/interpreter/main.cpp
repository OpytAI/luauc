#include "lua.h"
#include "luacode.h"
#include "lualib.h"

#include "lapi.h"
#include "lgc.h"
#include "lobject.h"
#include "lstate.h"
#include "ltable.h"
#include "ludata.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>

#include <fstream>
#include <string>

namespace {

std::string readFile(const char *path) {
    std::ifstream input(path, std::ios::binary);
    if (!input)
        return {};
    return std::string(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
}

int embedStamp(lua_State *L) {
    lua_pushinteger(L, 1);
    return 1;
}

int embedIterNext(lua_State *L) {
    const int control = lua_tointeger(L, 2);
    if (control != 0) {
        lua_pushnil(L);
        return 1;
    }
    int *seed = static_cast<int *>(lua_touserdatatagged(L, 1, 0));
    lua_pushinteger(L, 1);
    lua_pushinteger(L, seed ? *seed : 0);
    return 2;
}

int embedIter(lua_State *L) {
    lua_pushcfunction(L, embedIterNext, "next");
    lua_pushvalue(L, 1);
    lua_pushinteger(L, 0);
    return 3;
}

int embedNewIter(lua_State *L) {
    const int seed = int(luaL_checkinteger(L, 1));
    int *payload = static_cast<int *>(lua_newuserdatatagged(L, sizeof(int), 0));
    *payload = seed;
    lua_createtable(L, 0, 1);
    lua_pushcfunction(L, embedIter, "__iter");
    lua_setfield(L, -2, "__iter");
    lua_setreadonly(L, -1, true);
    lua_setmetatable(L, -2);
    return 1;
}

constexpr int kEmbedVec2Tag = 12;

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

int embedVec2Mark(lua_State *L) {
    luaL_checktype(L, 2, LUA_TTABLE);
    lua_pushvalue(L, 1);
    lua_rawseti(L, 2, 1);
    auto *src = static_cast<float *>(lua_touserdatatagged(L, 1, kEmbedVec2Tag));
    lua_pushnumber(L, src ? src[0] : 0);
    return 1;
}

int embedVec2Index(lua_State *L) {
    size_t keySize = 0;
    const char *key = luaL_checklstring(L, 2, &keySize);
    if (keySize == 4 && memcmp(key, "Unit", 4) == 0) {
        auto *src = static_cast<float *>(lua_touserdatatagged(L, 1, kEmbedVec2Tag));
        auto *payload = static_cast<float *>(lua_newuserdatataggedwithmetatable(L, sizeof(float) * 2, kEmbedVec2Tag));
        embedVec2Normalize(payload, src);
        return 1;
    }
    if (keySize == 4 && memcmp(key, "Hold", 4) == 0) {
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setmetatable(L, 1);
        return 1;
    }
    if (keySize == 4 && memcmp(key, "Mark", 4) == 0) {
        lua_pushcfunction(L, embedVec2Mark, "Mark");
        return 1;
    }
    luaL_error(L, "invalid vec2 index");
    return 0;
}

int embedVec2Namecall(lua_State *L) {
    const char *name = lua_namecallatom(L, nullptr);
    if (name && strcmp(name, "Mark") == 0)
        return embedVec2Mark(L);
    if (name && strcmp(name, "Store") == 0) {
        luaL_checktype(L, 2, LUA_TTABLE);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_rawseti(L, 2, 1);
        return 1;
    }
    luaL_error(L, "invalid vec2 namecall");
    return 0;
}

int embedNewVec2(lua_State *L) {
    const float seed = float(luaL_checknumber(L, 1));
    auto *payload = static_cast<float *>(lua_newuserdatataggedwithmetatable(L, sizeof(float) * 2, kEmbedVec2Tag));
    payload[0] = seed;
    payload[1] = seed;
    return 1;
}

void publishVec2Metatable(lua_State *state) {
    lua_createtable(state, 0, 2);
    lua_pushcfunction(state, embedVec2Index, "__index");
    lua_setfield(state, -2, "__index");
    lua_pushcfunction(state, embedVec2Namecall, "__namecall");
    lua_setfield(state, -2, "__namecall");
    lua_setreadonly(state, -1, true);
    lua_setuserdatametatable(state, kEmbedVec2Tag);
}

void publishEmbedImport(lua_State *state) {
    publishVec2Metatable(state);
    lua_createtable(state, 0, 3);
    lua_createtable(state, 0, 1);
    lua_pushcfunction(state, embedStamp, "stamp");
    lua_setfield(state, -2, "stamp");
    lua_setfield(state, -2, "util");
    lua_pushcfunction(state, embedNewIter, "iter");
    lua_setfield(state, -2, "iter");
    lua_pushcfunction(state, embedNewVec2, "vec2");
    lua_setfield(state, -2, "vec2");
    lua_setglobal(state, "embed");
}

void installWritableProxyGlobals(lua_State *state) {
    lua_newtable(state);
    lua_newtable(state);
    lua_pushvalue(state, LUA_GLOBALSINDEX);
    lua_setfield(state, -2, "__index");
    lua_setreadonly(state, -1, true);
    lua_setmetatable(state, -2);
    lua_replace(state, LUA_GLOBALSINDEX);
}

bool pushChunk(lua_State *state, const std::string &source, const char *sourceName) {
    size_t bytecodeSize = 0;
    char *bytecode = luau_compile(source.data(), source.size(), nullptr, &bytecodeSize);
    if (!bytecode)
        return false;
    int status = luau_load(state, sourceName, bytecode, bytecodeSize, 0);
    free(bytecode);
    return status == LUA_OK;
}

int requireModule(lua_State *state) {
    size_t nameSize = 0;
    const char *name = luaL_checklstring(state, 1, &nameSize);
    const char *global = nullptr;
    if (nameSize == 3 && memcmp(name, "lib", 3) == 0)
        global = "__luauc_embed_lib";
    else if (nameSize == sizeof("proto_identity") - 1 &&
             memcmp(name, "proto_identity", sizeof("proto_identity") - 1) == 0)
        global = "__luauc_proto_identity";
    else if (nameSize == sizeof("userdata_hooks") - 1 &&
             memcmp(name, "userdata_hooks", sizeof("userdata_hooks") - 1) == 0)
        global = "__luauc_userdata_hooks";
    if (!global) {
        luaL_error(state, "unknown module '%s'", name);
        return 0;
    }
    lua_getglobal(state, global);
    if (!lua_isfunction(state, -1)) {
        luaL_error(state, "module '%s' is unavailable", name);
        return 0;
    }
    return 1;
}

bool reportStackError(lua_State *state, const char *stage) {
    size_t size = 0;
    const char *message = lua_tolstring(state, -1, &size);
    fprintf(stderr, "%s: %.*s\n", stage, int(size), message ? message : "non-string Luau error");
    return false;
}

// Hook-only entry: userdata_hooks(seed: vec2) → seed:Mark + unit:Mark as a float.
// Distinct from the four-module product, which adds embed_main's seed and truncates to int64.
bool invokeHookOnly(lua_State *state, double input, const char *label) {
    lua_getglobal(state, "embed");
    lua_getfield(state, -1, "vec2");
    lua_remove(state, -2);
    lua_pushnumber(state, input);
    if (lua_pcall(state, 1, 1, 0) != LUA_OK)
        return reportStackError(state, "hook-only embed.vec2");

    lua_pushvalue(state, 1);
    lua_insert(state, -2);
    if (lua_pcall(state, 1, 1, 0) != LUA_OK)
        return reportStackError(state, "hook-only Unit/Mark");
    if (!lua_isnumber(state, -1))
        return reportStackError(state, "hook-only result is not a number");

    const double number = lua_tonumber(state, -1);
    printf("hook=%.17g|%s|%.17g\n", input, label, number);
    lua_settop(state, 1);
    return true;
}

bool invoke(lua_State *state, int64_t input, const char *label) {
    lua_State *thread = lua_newthread(state);
    lua_pushvalue(state, 1);
    lua_xmove(state, thread, 1);
    lua_pushinteger(thread, input);
    lua_pushstring(thread, label);

    int status = lua_resume(thread, state, 2);
    size_t yieldedSize = 0;
    uint32_t suspensionCount = 0;
    while (status == LUA_YIELD && suspensionCount < 64) {
        const char *yielded = lua_gettop(thread) == 1 ? lua_tolstring(thread, -1, &yieldedSize) : nullptr;
        if (!yielded || yieldedSize != sizeof("gc-boundary") - 1 ||
            memcmp(yielded, "gc-boundary", sizeof("gc-boundary") - 1) != 0)
            return reportStackError(thread, "interpreter yielded outside the GC boundary");
        lua_settop(thread, 0);
        lua_gc(state, LUA_GCCOLLECT, 0);
        status = lua_resume(thread, state, 0);
        suspensionCount++;
    }
    if (status != LUA_OK || lua_gettop(thread) != 2 || !lua_isnumber(thread, -2) || !lua_isstring(thread, -1))
        return reportStackError(thread, "interpreter resume failed");

    size_t textSize = 0;
    const char *text = lua_tolstring(thread, -1, &textSize);
    int64_t number = int64_t(lua_tonumber(thread, -2));
    printf("result=%lld|%s|%lld|%.*s\n", (long long)input, label, (long long)number, int(textSize), text);
    lua_settop(state, 1);
    return true;
}

bool invokeQuiet(lua_State *state, int64_t input, const char *label) {
    lua_State *thread = lua_newthread(state);
    lua_pushvalue(state, 1);
    lua_xmove(state, thread, 1);
    lua_pushinteger(thread, input);
    lua_pushstring(thread, label);

    int status = lua_resume(thread, state, 2);
    size_t yieldedSize = 0;
    uint32_t suspensionCount = 0;
    while (status == LUA_YIELD && suspensionCount < 64) {
        const char *yielded = lua_gettop(thread) == 1 ? lua_tolstring(thread, -1, &yieldedSize) : nullptr;
        if (!yielded || yieldedSize != sizeof("gc-boundary") - 1 ||
            memcmp(yielded, "gc-boundary", sizeof("gc-boundary") - 1) != 0)
            return false;
        lua_settop(thread, 0);
        lua_gc(state, LUA_GCCOLLECT, 0);
        status = lua_resume(thread, state, 0);
        suspensionCount++;
    }
    if (status != LUA_OK || lua_gettop(thread) != 2 || !lua_isnumber(thread, -2) || !lua_isstring(thread, -1))
        return false;
    lua_settop(state, 1);
    return true;
}

uint64_t monotonicNanos() {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return uint64_t(now.tv_sec) * 1000000000ull + uint64_t(now.tv_nsec);
}

int compareU64(const void *lhs, const void *rhs) {
    const uint64_t a = *static_cast<const uint64_t *>(lhs);
    const uint64_t b = *static_cast<const uint64_t *>(rhs);
    return a < b ? -1 : a > b ? 1 : 0;
}

int runMeasure(lua_State *state, int64_t input, const char *label, uint32_t warmup, uint32_t samples) {
    for (uint32_t index = 0; index < warmup; ++index) {
        if (!invokeQuiet(state, input, label))
            return 1;
    }
    if (samples == 0 || samples > 4096)
        return 2;
    uint64_t times[4096];
    for (uint32_t index = 0; index < samples; ++index) {
        const uint64_t start = monotonicNanos();
        if (!invokeQuiet(state, input, label))
            return 1;
        times[index] = monotonicNanos() - start;
    }
    qsort(times, samples, sizeof(uint64_t), compareU64);
    const uint32_t p50 = samples / 2;
    const uint32_t p90 = (samples * 9) / 10;
    printf("measure=p50_ns=%llu p90_ns=%llu samples=%u\n",
           (unsigned long long)times[p50], (unsigned long long)times[p90 < samples ? p90 : samples - 1],
           samples);
    return 0;
}

} // namespace

static GCObject *stackCollectable(lua_State *L, int index) {
    const TValue *value = luaA_toobject(L, index);
    if (!value || !iscollectable(value))
        return nullptr;
    return gcvalue(value);
}

static uint32_t forceGcStep(lua_State *L) {
    L->global->GCthreshold = 0;
    luaC_step(L, false);
    return L->global->gcstate;
}

static bool paintSeedAndBagBlack(lua_State *L, int seedIndex, int bagIndex) {
    for (int attempt = 0; attempt < 24; ++attempt) {
        lua_gc(L, LUA_GCRESTART, 0);
        if (L->global->gcstate == GCSpause)
            forceGcStep(L);
        uint32_t steps = 0;
        while (steps++ < 512) {
            GCObject *seed = stackCollectable(L, seedIndex);
            GCObject *bag = stackCollectable(L, bagIndex);
            if (!seed || !bag)
                return false;
            if (isblack(seed) && isblack(bag)) {
                lua_gc(L, LUA_GCSTOP, 0);
                const int stopped = L->global->gcstate;
                if (stopped == GCSatomic || stopped == GCSsweep || stopped == GCSpause)
                    break;
                return true;
            }
            const int state = L->global->gcstate;
            if (state == GCSatomic || state == GCSsweep || state == GCSpause)
                break;
            forceGcStep(L);
        }
        while (L->global->gcstate != GCSpause && steps++ < 2048)
            forceGcStep(L);
    }
    return false;
}

static bool finishMark(lua_State *L) {
    uint32_t steps = 0;
    while (L->global->gcstate != GCSsweep && steps < 4096) {
        forceGcStep(L);
        steps++;
    }
    return L->global->gcstate == GCSsweep;
}

static int runColorStrip(bool hold, bool applyBarrier) {
    lua_State *state = luaL_newstate();
    if (!state)
        return 2;
    luaL_openlibs(state);
    publishEmbedImport(state);
    luaL_sandbox(state);

    lua_getglobal(state, "embed");
    lua_getfield(state, -1, "vec2");
    lua_remove(state, -2);
    lua_pushnumber(state, 1.0);
    if (lua_pcall(state, 1, 1, 0) != LUA_OK) {
        lua_close(state);
        return 2;
    }
    lua_createtable(state, 1, 0);
    lua_pushnumber(state, 0);
    lua_rawseti(state, -2, 1);
    if (!paintSeedAndBagBlack(state, 1, 2)) {
        lua_close(state);
        return 2;
    }

    lua_newtable(state);
    GCObject *white = stackCollectable(state, -1);
    if (!white) {
        lua_close(state);
        return 2;
    }
    if (hold) {
        const TValue *seedValue = luaA_toobject(state, 1);
        if (!seedValue || !ttisuserdata(seedValue)) {
            lua_close(state);
            return 2;
        }
        Udata *seed = uvalue(seedValue);
        seed->metatable = hvalue(luaA_toobject(state, -1));
        if (applyBarrier)
            luaC_objbarrier(state, seed, seed->metatable);
    } else {
        LuaTable *bag = hvalue(luaA_toobject(state, 2));
        TValue *slot = luaH_setnum(state, bag, 1);
        setobj2t(state, slot, luaA_toobject(state, -1));
        white = gcvalue(slot);
        if (applyBarrier)
            luaC_barrierfast(state, bag);
    }
    lua_pop(state, 1);
    if (!finishMark(state)) {
        lua_close(state);
        return 2;
    }
    const int dead = isdead(state->global, white) ? 1 : 0;
    lua_close(state);
    printf("strip=%s barrier=%s dead=%d\n", hold ? "hold" : "store", applyBarrier ? "on" : "off",
           dead);
    return applyBarrier ? dead : !dead;
}

int runBarrierStrip() {
    return runColorStrip(true, true) == 0 && runColorStrip(true, false) == 0 &&
                   runColorStrip(false, true) == 0 && runColorStrip(false, false) == 0
               ? 0
               : 1;
}

int runHookOnly(const char *hooksPath) {
    std::string userdataHooksSource = readFile(hooksPath);
    if (userdataHooksSource.empty()) {
        fprintf(stderr, "failed to read userdata_hooks source\n");
        return 2;
    }

    lua_State *state = luaL_newstate();
    if (!state)
        return 2;
    luaL_openlibs(state);
    publishEmbedImport(state);
    luaL_sandbox(state);
    installWritableProxyGlobals(state);
    if (!pushChunk(state, userdataHooksSource, "@userdata_hooks.luau") ||
        lua_pcall(state, 0, 1, 0) != LUA_OK || !lua_isfunction(state, -1)) {
        reportStackError(state, "load userdata hooks");
        lua_close(state);
        return 1;
    }

    const bool ok = invokeHookOnly(state, 1, "alpha") && invokeHookOnly(state, 7, "beta") &&
                    invokeHookOnly(state, -4, "gamma") && invokeHookOnly(state, 0, "zero");
    lua_close(state);
    return ok ? 0 : 1;
}

int runSingleSource(const char *path) {
    std::string source = readFile(path);
    if (source.empty()) {
        fprintf(stderr, "failed to read source\n");
        return 2;
    }
    lua_State *state = luaL_newstate();
    if (!state)
        return 2;
    luaL_openlibs(state);
    publishEmbedImport(state);
    luaL_sandbox(state);
    installWritableProxyGlobals(state);
    if (!pushChunk(state, source, "@source.luau") || lua_pcall(state, 0, 1, 0) != LUA_OK ||
        !lua_isfunction(state, -1)) {
        reportStackError(state, "load source");
        lua_close(state);
        return 1;
    }
    const bool ok = invoke(state, 1, "alpha") && invoke(state, 7, "beta") && invoke(state, -4, "gamma");
    lua_close(state);
    return ok ? 0 : 1;
}

int runMeasureSource(const char *path, int64_t input, const char *label, uint32_t warmup,
                     uint32_t samples) {
    std::string source = readFile(path);
    if (source.empty())
        return 2;
    lua_State *state = luaL_newstate();
    if (!state)
        return 2;
    luaL_openlibs(state);
    publishEmbedImport(state);
    luaL_sandbox(state);
    installWritableProxyGlobals(state);
    if (!pushChunk(state, source, "@source.luau") || lua_pcall(state, 0, 1, 0) != LUA_OK ||
        !lua_isfunction(state, -1)) {
        reportStackError(state, "load source");
        lua_close(state);
        return 1;
    }
    const int status = runMeasure(state, input, label, warmup, samples);
    lua_close(state);
    return status;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--barrier-strip") == 0)
        return runBarrierStrip();
    if (argc == 3 && strcmp(argv[1], "--hook-only") == 0)
        return runHookOnly(argv[2]);
    if (argc == 3 && strcmp(argv[1], "--source") == 0)
        return runSingleSource(argv[2]);
    if (argc == 7 && strcmp(argv[1], "--measure") == 0)
        return runMeasureSource(argv[2], atoll(argv[3]), argv[4], uint32_t(atoi(argv[5])),
                                uint32_t(atoi(argv[6])));
    const bool measureProduct = argc == 10 && strcmp(argv[1], "--measure-product") == 0;
    if (!measureProduct && argc != 5) {
        fprintf(stderr,
                "usage: luauc-pinned-interpreter <lib.luau> <main.luau> <proto_identity.luau> "
                "<userdata_hooks.luau>\n"
                "       luauc-pinned-interpreter --hook-only <userdata_hooks.luau>\n"
                "       luauc-pinned-interpreter --source <file.luau>\n");
        return 2;
    }
    const int fileBase = measureProduct ? 2 : 1;
    std::string libSource = readFile(argv[fileBase]);
    std::string mainSource = readFile(argv[fileBase + 1]);
    std::string protoIdentitySource = readFile(argv[fileBase + 2]);
    std::string userdataHooksSource = readFile(argv[fileBase + 3]);
    if (libSource.empty() || mainSource.empty() || protoIdentitySource.empty() ||
        userdataHooksSource.empty()) {
        fprintf(stderr, "failed to read source corpus\n");
        return 2;
    }

    lua_State *state = luaL_newstate();
    if (!state)
        return 2;
    luaL_openlibs(state);
    publishEmbedImport(state);
    luaL_sandbox(state);
    installWritableProxyGlobals(state);
    if (!pushChunk(state, libSource, "@lib.luau") || lua_pcall(state, 0, 1, 0) != LUA_OK || !lua_isfunction(state, -1)) {
        reportStackError(state, "load lib");
        lua_close(state);
        return 1;
    }
    lua_setglobal(state, "__luauc_embed_lib");
    if (!pushChunk(state, protoIdentitySource, "@proto_identity.luau") ||
        lua_pcall(state, 0, 1, 0) != LUA_OK || !lua_isfunction(state, -1)) {
        reportStackError(state, "load Proto identity module");
        lua_close(state);
        return 1;
    }
    lua_setglobal(state, "__luauc_proto_identity");
    if (!pushChunk(state, userdataHooksSource, "@userdata_hooks.luau") ||
        lua_pcall(state, 0, 1, 0) != LUA_OK || !lua_isfunction(state, -1)) {
        reportStackError(state, "load userdata hooks module");
        lua_close(state);
        return 1;
    }
    lua_setglobal(state, "__luauc_userdata_hooks");
    lua_pushcfunction(state, requireModule, "require");
    lua_setglobal(state, "require");
    if (!pushChunk(state, mainSource, "@main.luau") || lua_pcall(state, 0, 1, 0) != LUA_OK || !lua_isfunction(state, -1)) {
        reportStackError(state, "load main");
        lua_close(state);
        return 1;
    }

    if (measureProduct) {
        const int status = runMeasure(state, atoll(argv[6]), argv[7], uint32_t(atoi(argv[8])),
                                      uint32_t(atoi(argv[9])));
        lua_close(state);
        return status;
    }
    bool ok = invoke(state, 1, "alpha") && invoke(state, 7, "beta") && invoke(state, -4, "gamma");
    lua_close(state);
    return ok ? 0 : 1;
}

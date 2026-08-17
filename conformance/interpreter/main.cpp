#include "lua.h"
#include "luacode.h"
#include "lualib.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
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

} // namespace

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr,
                "usage: luauc-pinned-interpreter <lib.luau> <main.luau> <proto_identity.luau> "
                "<userdata_hooks.luau>\n");
        return 2;
    }
    std::string libSource = readFile(argv[1]);
    std::string mainSource = readFile(argv[2]);
    std::string protoIdentitySource = readFile(argv[3]);
    std::string userdataHooksSource = readFile(argv[4]);
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

    bool ok = invoke(state, 1, "alpha") && invoke(state, 7, "beta") && invoke(state, -4, "gamma");
    lua_close(state);
    return ok ? 0 : 1;
}

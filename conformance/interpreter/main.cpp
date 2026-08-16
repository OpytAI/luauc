#include "lua.h"
#include "luacode.h"
#include "lualib.h"

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
    const char *yielded = lua_gettop(thread) == 1 ? lua_tolstring(thread, -1, &yieldedSize) : nullptr;
    if (status != LUA_YIELD || !yielded || yieldedSize != sizeof("gc-boundary") - 1 ||
        memcmp(yielded, "gc-boundary", sizeof("gc-boundary") - 1) != 0)
        return reportStackError(thread, "interpreter did not reach the GC boundary");

    lua_settop(thread, 0);
    lua_gc(state, LUA_GCCOLLECT, 0);
    status = lua_resume(thread, state, 0);
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
    if (argc != 4) {
        fprintf(stderr,
                "usage: luauc-pinned-interpreter <lib.luau> <main.luau> <proto_identity.luau>\n");
        return 2;
    }
    std::string libSource = readFile(argv[1]);
    std::string mainSource = readFile(argv[2]);
    std::string protoIdentitySource = readFile(argv[3]);
    if (libSource.empty() || mainSource.empty() || protoIdentitySource.empty()) {
        fprintf(stderr, "failed to read source corpus\n");
        return 2;
    }

    lua_State *state = luaL_newstate();
    if (!state)
        return 2;
    luaL_openlibs(state);
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
    lua_pushcfunction(state, requireModule, "require");
    lua_setglobal(state, "require");
    luaL_sandbox(state);
    if (!pushChunk(state, mainSource, "@main.luau") || lua_pcall(state, 0, 1, 0) != LUA_OK || !lua_isfunction(state, -1)) {
        reportStackError(state, "load main");
        lua_close(state);
        return 1;
    }

    bool ok = invoke(state, 1, "alpha") && invoke(state, 7, "beta") && invoke(state, -4, "gamma");
    lua_close(state);
    return ok ? 0 : 1;
}

#include <stdlib.h>

#include "Luau/Common.h"
#include "lvm.h"

LUAU_FASTFLAGVARIABLE(LuauDirectFieldGet)
LUAU_FLAGVERSION(LuauDirectFieldGet, 2)
LUAU_FASTFLAGVARIABLE(LuauClosureUsageCounter)
LUAU_FASTFLAGVARIABLE(DebugLuauUserDefinedClassesRuntime)
LUAU_FASTFLAGVARIABLE(LuauCallFeedback)
LUAU_FASTFLAGVARIABLE(LuauYieldIter2)

// The frontend archive omits lvmexecute.cpp. These abort if a compiler TU
// accidentally enters the bytecode dispatcher.
void luau_execute(lua_State* L)
{
    (void)L;
    abort();
}

void luau_finishop(lua_State* L)
{
    (void)L;
    abort();
}

int luau_precall(lua_State* L, StkId func, int nresults)
{
    (void)L;
    (void)func;
    (void)nresults;
    abort();
}

void luau_poscall(lua_State* L, StkId first)
{
    (void)L;
    (void)first;
    abort();
}

void luau_callhook(lua_State* L, lua_Hook hook, void* userdata)
{
    (void)L;
    (void)hook;
    (void)userdata;
    abort();
}

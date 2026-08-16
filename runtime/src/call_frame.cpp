// Strict-AOT replacement for the generic call-frame operations currently co-located with Luau's
// bytecode dispatch loop in lvmexecute.cpp. Keep this file pin-sized and mechanically comparable
// with upstream 0.725; generated execution and continuations belong to the Zig runtime/backend.

#include "aot_runtime_v1.h"

#include "lbuiltins.h"
#include "lvm.h"

#include "ldebug.h"
#include "ldo.h"
#include "lfunc.h"
#include "lgc.h"
#include "lmem.h"
#include "lstate.h"
#include "lstring.h"
#include "ltable.h"
#include "ltm.h"
#include "ludata.h"
#include "lualib.h"

#include <limits.h>
#include <math.h>
#include <string.h>

static_assert(LUAUC_RUNTIME_V1_MULTRET == LUA_MULTRET, "Luau MULTRET sentinel drift");

static constexpr uint32_t AOT_FASTCALL_NO_OPERAND = UINT32_MAX;
static constexpr uint64_t AOT_COVERAGE_MAX_HITS = (UINT64_C(1) << 23) - 1;

struct AotCoverageRecord {
    uint32_t line;
    uint32_t reserved;
    uint64_t hits;
};

static_assert(sizeof(AotCoverageRecord) == 16, "AOT coverage record layout drift");

// These flag definitions live in lvmexecute.cpp upstream even though retained runtime sources use
// them. The strict archive excludes that translation unit, so the pin adapter owns the definitions.
LUAU_FASTFLAGVARIABLE(LuauDirectFieldGet)
LUAU_FLAGVERSION(LuauDirectFieldGet, 2)
LUAU_FASTFLAGVARIABLE(LuauClosureUsageCounter)
LUAU_FASTFLAGVARIABLE(LuauUdataDirectAccess6)
LUAU_FASTFLAGVARIABLE(DebugLuauUserDefinedClassesRuntime)
LUAU_FASTFLAGVARIABLE(LuauYieldIter2)
LUAU_FASTFLAG(LuauCustomYieldablePcalls)

LUAU_NOINLINE void luau_callhook(lua_State *L, lua_Hook hook, void *userdata) {
    ptrdiff_t base = savestack(L, L->base);
    ptrdiff_t top = savestack(L, L->top);
    ptrdiff_t ci_top = savestack(L, L->ci->top);
    int status = L->status;

    // A hook invoked externally on a paused thread must be able to make ordinary Luau calls.
    if (status == LUA_YIELD || status == LUA_BREAK) {
        L->status = 0;
        L->base = L->ci->base;
    }

    // AOT frames deliberately have no bytecode pc to advance or translate into a source line.
    // Source IDs enter this ABI with the generated-function continuation protocol; until then the
    // hook receives -1, never a fabricated or dereferenced bytecode location.
    luaD_checkstack(L, LUA_MINSTACK);
    L->ci->top = L->top + LUA_MINSTACK;
    LUAU_ASSERT(L->ci->top <= L->stack_last);

    lua_Debug ar;
    ar.currentline = -1;
    ar.userdata = userdata;

    hook(L, &ar);

    L->ci->top = restorestack(L, ci_top);
    L->top = restorestack(L, top);

    // Restore a pre-existing paused state only when the hook did not establish the same state.
    if (status == LUA_YIELD && L->status != LUA_YIELD) {
        L->status = LUA_YIELD;
        L->base = restorestack(L, base);
    } else if (status == LUA_BREAK) {
        LUAU_ASSERT(L->status != LUA_BREAK);
        L->status = LUA_BREAK;
        L->base = restorestack(L, base);
    }
}

int luau_precall(lua_State *L, StkId func, int nresults) {
    if (!ttisfunction(func)) {
        luaV_tryfuncTM(L, func);
        // L->top is incremented by tryfuncTM.
    }

    Closure *ccl = clvalue(func);

    // The generated-code boundary uses a layout-compatible Proto as immutable AOT metadata. Reject both
    // bytecode-bearing closures and missing AOT metadata before installing a Lua CallInfo: the
    // ordinary Luau error formatter may inspect the active caller's savedpc while raising.
    if (!ccl->isC) {
        Proto *p = ccl->l.p;

        if (p->code != nullptr || p->codeentry != nullptr || p->sizecode != 0)
            luaG_runerror(L, "strict AOT runtime rejected a bytecode-bearing Luau closure");

        if (p->execdata == nullptr)
            luaG_runerror(L, "strict AOT runtime has no compiled entry for Luau closure");

        if (p->source == nullptr)
            luaG_runerror(L, "strict AOT runtime has no source metadata for Luau closure");
    }

    CallInfo *ci = incr_ci(L);
    ci->func = func;
    ci->base = func + 1;
    ci->top = L->top + ccl->stacksize;
    ci->savedpc = nullptr;
    ci->flags = 0;
    ci->nresults = nresults;
    if (FFlag::LuauClosureUsageCounter)
        ccl->usage++;

    L->base = ci->base;
    // Note: L->top is assigned externally.

    luaD_checkstackfornewci(L, ccl->stacksize);
    LUAU_ASSERT(ci->top <= L->stack_last);

    if (!ccl->isC) {
        Proto *p = ccl->l.p;

        // Fill unused parameters with nil exactly as the interpreter does. Proto is retained only
        // for non-executable frame metadata at this stage (parameters, varargs, stack size, etc.).
        StkId argi = L->top;
        StkId argend = L->base + p->numparams;
        while (argi < argend)
            setnilvalue(argi++);
        L->top = p->is_vararg ? argi : ci->top;

        // AOT frames have no bytecode program counter. Native marks the frame as opaque to APIs
        // that would otherwise expose or mutate interpreter registers and locals. The same union
        // carries a packed source line and generated-code continuation while this frame is active.
        ci->aotstate = 0;
        ci->flags = LUA_CALLINFO_NATIVE;

        return PCRLUA;
    } else {
        lua_CFunction cfunc = ccl->c.f;
        int n = cfunc(L);

        // A negative C result is Luau's yield convention; leave the frame installed for resume.
        if (n < 0)
            return PCRYIELD;

        // ci is our callinfo, cip is our parent.
        CallInfo *ci = L->ci;
        CallInfo *cip = ci - 1;

        if (FFlag::LuauClosureUsageCounter) {
            LUAU_ASSERT(ccl->usage > 0);
            ccl->usage--;
        }

        // Copy return values into the parent stack, bounded by its requested result count, and
        // fill any missing fixed results with nil. LUA_MULTRET is represented by a negative count.
        StkId res = ci->func;
        StkId vali = L->top - n;
        StkId valend = L->top;

        int i;
        for (i = nresults; i != 0 && vali < valend; i--)
            setobj2s(L, res++, vali++);
        while (i-- > 0)
            setnilvalue(res++);

        L->ci = cip;
        L->base = cip->base;
        L->top = res;

        return PCRC;
    }
}

void luau_poscall(lua_State *L, StkId first) {
    // Finish a compiled Luau call. This body is the generic result/frame portion of upstream
    // luau_poscall; it contains no instruction decode or interpreter re-entry.
    CallInfo *ci = L->ci;
    CallInfo *cip = ci - 1;

    if (FFlag::LuauClosureUsageCounter) {
        LUAU_ASSERT(clvalue(ci->func)->usage > 0);
        clvalue(ci->func)->usage--;
    }

    StkId res = ci->func;
    StkId vali = first;
    StkId valend = L->top;

    int i;
    for (i = ci->nresults; i != 0 && vali < valend; i--)
        setobj2s(L, res++, vali++);
    while (i-- > 0)
        setnilvalue(res++);

    L->ci = cip;
    L->base = cip->base;
    L->top = (ci->nresults == LUA_MULTRET) ? res : cip->top;
}

extern "C" const uint8_t luauc_runtime_v1_layout_sha256[32] = {
    0x42, 0x5d, 0x38, 0xd7, 0x5e, 0xf9, 0xf4, 0xe2, 0x66, 0x93, 0xa6, 0x90, 0xe0, 0x85, 0x7f, 0x90,
    0x2a, 0xa7, 0x6f, 0x1c, 0x18, 0x56, 0x19, 0x6a, 0xc3, 0x0d, 0xc6, 0x23, 0x6e, 0xa4, 0xc4, 0x96,
};

static bool materializableScalarConstantKind(uint8_t kind);
static bool validAotProto(const LuaucRuntimeProtoV1 *metadata);

static char *getAotCoverageData(lua_State *, Proto *proto, size_t *count, size_t *lineCount) {
    if (!count || !lineCount)
        return nullptr;
    *count = 0;
    *lineCount = 0;
    const LuaucRuntimeProtoV1 *metadata =
        proto ? static_cast<const LuaucRuntimeProtoV1 *>(proto->execdata) : nullptr;
    if (!validAotProto(metadata) ||
        (metadata->coverage_site_count != 0 && proto->userdata == nullptr))
        return nullptr;
    *count = metadata->coverage_site_count;
    *lineCount = metadata->coverage_line_count;
    return static_cast<char *>(proto->userdata);
}
static char moduleRegistryKey;

enum ModuleRegistrySlot {
    MODULE_REGISTRY_COUNT_SLOT = 0,
    MODULE_REGISTRY_ENTRY_ID_SLOT = -1,
};

enum ModuleInitializationState {
    MODULE_UNINITIALIZED = 0,
    MODULE_INITIALIZING = 1,
    MODULE_INITIALIZED = 2,
    MODULE_FAILED = 3,
};

static uint32_t aotContinuationId(const CallInfo *ci) {
    return ci ? (ci->aotstate >> LUA_CALLINFO_AOT_CONTINUATION_SHIFT) &
                    LUA_CALLINFO_AOT_CONTINUATION_MASK
              : 0;
}

static bool validNativeSuspensionFrame(const CallInfo *ci) {
    return ci && isLua(ci) && (ci->flags & LUA_CALLINFO_NATIVE) && aotContinuationId(ci) != 0;
}

static bool validCallSuspension(lua_State *L) {
    if (!L || !isyielded(L) || !L->ci || L->ci <= L->base_ci || !ttisfunction(L->ci->func) ||
        !clvalue(L->ci->func)->isC)
        return false;

    for (CallInfo *ci = L->ci - 1; ci > L->base_ci; --ci) {
        if (isLua(ci))
            return validNativeSuspensionFrame(ci);
    }
    return false;
}

static bool validScheduledReentrySuspension(lua_State *L) {
    if (!L || L->status != SCHEDULED_REENTRY || !L->ci || L->ci <= L->base_ci + 1)
        return false;

    // A yieldable protected C call schedules a fresh Luau child instead of entering it on the
    // current native stack. The child is therefore the top frame, is marked for bounded return by
    // performcall, and still has the zero AOT state installed by luau_precall because generated
    // code has not run yet.
    CallInfo *child = L->ci;
    if (!isLua(child) || !(child->flags & LUA_CALLINFO_NATIVE) ||
        !(child->flags & LUA_CALLINFO_RETURN) || child->aotstate != 0 || L->base != child->base)
        return false;

    Closure *childClosure = clvalue(child->func);
    Proto *childProto = childClosure->l.p;
    const LuaucRuntimeProtoV1 *childMetadata =
        childProto ? static_cast<const LuaucRuntimeProtoV1 *>(childProto->execdata) : nullptr;
    if (!childProto || childProto->code != nullptr || childProto->codeentry != nullptr ||
        childProto->sizecode != 0 || childProto->source == nullptr ||
        !validAotProto(childMetadata) || childClosure->nupvalues != childMetadata->nups ||
        childClosure->stacksize != childMetadata->max_stack_size ||
        childProto->maxstacksize != childMetadata->max_stack_size ||
        childProto->numparams != childMetadata->num_params ||
        childProto->nups != childMetadata->nups ||
        childProto->is_vararg != childMetadata->is_vararg)
        return false;

    // luaL_pcallyieldable leaves its protected C continuation immediately below the scheduled
    // child. LUA_CALLINFO_HANDLE is the real resume/error ownership marker; accepting an arbitrary
    // C frame here would turn malformed PCRYIELD state into compiled re-entry.
    CallInfo *protectedFrame = child - 1;
    if (!ttisfunction(protectedFrame->func) || !clvalue(protectedFrame->func)->isC ||
        !clvalue(protectedFrame->func)->c.cont || !(protectedFrame->flags & LUA_CALLINFO_HANDLE))
        return false;

    // Every intervening C frame must itself be continuation-capable. The nearest Luau parent owns
    // the already-published generated continuation that resumes after the protected call returns.
    for (CallInfo *ci = protectedFrame - 1; ci > L->base_ci; --ci) {
        if (!ttisfunction(ci->func))
            return false;
        Closure *closure = clvalue(ci->func);
        if (!closure->isC)
            return validNativeSuspensionFrame(ci);
        if (!closure->c.cont)
            return false;
    }
    return false;
}

static bool validAotSuspension(lua_State *L) {
    if (!L || !isyielded(L) || !L->ci || L->ci <= L->base_ci)
        return false;
    if (validNativeSuspensionFrame(L->ci))
        return true;
    return validCallSuspension(L) || validScheduledReentrySuspension(L);
}

static void configurePinnedRuntimeFlags(lua_State *L) {
    // These flags control the two heap-frame continuation paths retained by strict AOT: yieldable
    // pcall/xpcall C frames and yielded generic-iterator completion. Pin them explicitly instead of
    // inheriting process defaults; the product E2E validates both continuation protocols directly.
    FFlag::LuauCustomYieldablePcalls.value = true;
    FFlag::LuauYieldIter2.value = true;
    L->global->ecb.getcoveragedata = getAotCoverageData;
}

static Proto *activeAotFrameProto(lua_State *L, const char *operation) {
    if (!L || !L->ci || L->ci <= L->base_ci || !isLua(L->ci) ||
        !(L->ci->flags & LUA_CALLINFO_NATIVE))
        luaG_runerror(L, "strict AOT %s requires an active native Luau frame", operation);

    Closure *closure = clvalue(L->ci->func);
    Proto *proto = closure->l.p;
    const LuaucRuntimeProtoV1 *metadata =
        proto ? static_cast<const LuaucRuntimeProtoV1 *>(proto->execdata) : nullptr;
    if (!validAotProto(metadata))
        luaG_runerror(L, "strict AOT %s rejected invalid frame metadata", operation);
    if (proto->maxstacksize != metadata->max_stack_size ||
        proto->numparams != metadata->num_params || proto->nups != metadata->nups ||
        proto->is_vararg != metadata->is_vararg || closure->stacksize != proto->maxstacksize ||
        closure->nupvalues != metadata->nups)
        luaG_runerror(L, "strict AOT %s rejected inconsistent frame metadata", operation);
    return proto;
}

static void validateActiveAotEntry(lua_State *L, const LuaucRuntimeProtoV1 *expectedMetadata,
                                   const char *operation) {
    Proto *proto = activeAotFrameProto(L, operation);
    CallInfo *ci = L->ci;
    const LuaucRuntimeProtoV1 *metadata = static_cast<const LuaucRuntimeProtoV1 *>(proto->execdata);
    if (metadata != expectedMetadata || L->base != ci->base || ci->top < ci->base ||
        ci->top > L->stack_last)
        luaG_runerror(L, "strict AOT %s rejected inconsistent entry frame state", operation);

    // A continuation enters from ldo.cpp::resume_continue without another luau_precall. Its top is
    // semantic state: yielded CALL results, iterator results, or explicit resume values can occupy
    // a strict prefix of the frame or extend past ci->top for MULTRET. Preserve it exactly; the
    // generated continuation owns any opcode-specific adjustment.
    if (aotContinuationId(ci) != 0) {
        if (L->top < ci->base || L->top > L->stack_last)
            luaG_runerror(L, "strict AOT %s rejected an invalid continuation top", operation);
        return;
    }

    // Fresh fixed-arity frames arrive directly from pinned luau_precall, which has already
    // published ci->top. Validate that invariant instead of fabricating it here.
    if (!proto->is_vararg) {
        if (L->top != ci->top)
            luaG_runerror(L, "strict AOT %s rejected an incomplete fixed-arity frame", operation);
        return;
    }

    // Fresh variadic frames deliberately retain the actual argument end. PREPVARARGS uses it to
    // derive the extra-argument count, relocates fixed parameters, and then publishes its new
    // ci->top. If that prepared frame later yields, the continuation arm above preserves the exact
    // resumed result top regardless of whether relocation happened to leave base == func + 1.
    if (ci->base == ci->func + 1) {
        if (L->top < ci->base + proto->numparams || L->top > ci->top)
            luaG_runerror(L, "strict AOT %s rejected an unprepared variadic frame", operation);
        return;
    }
    luaG_runerror(L, "strict AOT %s rejected a prepared variadic frame without a continuation",
                  operation);
}

static TValue *activeAotRegister(lua_State *L, Proto *proto, uint32_t index,
                                 const char *operation) {
    if (index >= proto->maxstacksize)
        luaG_runerror(L, "strict AOT %s register is outside the compiled frame", operation);
    return L->base + index;
}

static const TValue *activeAotValueOperand(lua_State *L, Proto *proto, uint32_t encoded,
                                           const char *operation) {
    if ((encoded & LUAUC_AOT_OPERAND_V1_CONSTANT_FLAG) == 0) {
        TValue *value = activeAotRegister(L, proto, encoded, operation);
        if (value >= L->top)
            luaG_runerror(L, "strict AOT %s requires a published live register operand", operation);
        return value;
    }

    const uint32_t constantId = encoded & LUAUC_AOT_OPERAND_V1_INDEX_MASK;
    const LuaucRuntimeProtoV1 *metadata = static_cast<const LuaucRuntimeProtoV1 *>(proto->execdata);
    if (proto->sizek < 0 || uint32_t(proto->sizek) != metadata->constant_count ||
        (proto->k == nullptr) != (proto->sizek == 0) || constantId >= uint32_t(proto->sizek))
        luaG_runerror(L, "strict AOT %s rejected constant operand %u", operation, constantId);

    // IMPORT/CLOSURE/CLASS_SHAPE records intentionally remain nil placeholders in this runtime,
    // and TABLE records are templates consumed only by DUP_TABLE. Reject them by metadata kind so
    // an unmaterialized record can never masquerade as a source-level nil operand.
    if (!materializableScalarConstantKind(metadata->constants[constantId].kind))
        luaG_runerror(L, "strict AOT %s rejected non-scalar constant operand %u", operation,
                      constantId);
    return &proto->k[constantId];
}

static LuaTable *activeAotTable(lua_State *L, Proto *proto, uint32_t tableRegister, bool write,
                                const char *operation) {
    TValue *value = activeAotRegister(L, proto, tableRegister, operation);
    if (!ttistable(value))
        luaG_runerror(L, "strict AOT %s requires a table value", operation);

    LuaTable *table = hvalue(value);
    if (write && table->readonly)
        luaG_runerror(L, "strict AOT %s rejected a readonly table", operation);
    return table;
}

static LuaTable *activeAotPlainTable(lua_State *L, Proto *proto, uint32_t tableRegister, bool write,
                                     const char *operation) {
    LuaTable *table = activeAotTable(L, proto, tableRegister, write, operation);
    if (table->metatable)
        luaG_runerror(L, "strict AOT %s rejected a table with a metatable", operation);
    return table;
}

static TString *activeAotStringKey(lua_State *L, const char *keyPointer, size_t keyLength,
                                   const char *operation) {
    if (!keyPointer || keyLength > MAXSSIZE)
        luaG_runerror(L, "strict AOT %s rejected invalid string key bytes", operation);
    return luaS_newlstr(L, keyPointer, keyLength);
}

extern "C" uint32_t luauc_runtime_v1_builtin_type_error(lua_State *L, const char *builtinName,
                                                      size_t builtinNameLength,
                                                      uint32_t argumentIndex, uint32_t expectedTag,
                                                      uint32_t sourceRegister) {
    Proto *proto = activeAotFrameProto(L, "builtin argument type error");
    if (!builtinName || builtinNameLength == 0 || builtinNameLength > 64 ||
        memchr(builtinName, '\0', builtinNameLength) != nullptr || argumentIndex == 0 ||
        expectedTag >= LUA_T_COUNT)
        luaG_runerror(L, "strict AOT builtin argument type error rejected its metadata");

    TValue *source = activeAotRegister(L, proto, sourceRegister, "builtin argument type error");
    if (source >= L->top)
        luaG_runerror(L, "strict AOT builtin argument type error requires a published register");

    if (ttype(source) == int(expectedTag))
        return 1;
    if (expectedTag == LUA_TNUMBER) {
        TValue converted;
        if (luaV_tonumber(source, &converted))
            return 1;
    }

    luaG_runerror(L, "invalid argument #%u to '%.*s' (%s expected, got %s)", argumentIndex,
                  int(builtinNameLength), builtinName, getstr(L->global->ttname[expectedTag]),
                  luaT_objtypename(L, source));
}

extern "C" double luauc_runtime_v1_builtin_number(lua_State *L, uint32_t sourceRegister) {
    Proto *proto = activeAotFrameProto(L, "builtin numeric argument");
    TValue *source = activeAotRegister(L, proto, sourceRegister, "builtin numeric argument");
    if (source >= L->top)
        luaG_runerror(L, "strict AOT builtin numeric argument requires a published register");

    TValue converted;
    const TValue *number = luaV_tonumber(source, &converted);
    if (!number)
        luaG_runerror(L, "strict AOT builtin numeric argument was not convertible");
    return nvalue(number);
}

extern "C" void luauc_runtime_v1_buffer_bounds_error(lua_State *L) {
    activeAotFrameProto(L, "buffer bounds error");
    luaG_runerror(L, "buffer access out of bounds");
}

extern "C" void luauc_runtime_v1_set_location(lua_State *L, uint32_t line) {
    if (!L || !L->ci || !isLua(L->ci) || !(L->ci->flags & LUA_CALLINFO_NATIVE))
        luaG_runerror(L, "strict AOT location update requires an active native Luau frame");

    Closure *closure = clvalue(L->ci->func);
    const LuaucRuntimeProtoV1 *metadata =
        closure->l.p ? static_cast<const LuaucRuntimeProtoV1 *>(closure->l.p->execdata) : nullptr;
    if (!validAotProto(metadata))
        luaG_runerror(L, "strict AOT location update rejected invalid frame metadata");
    if (line > LUA_CALLINFO_AOT_LINE_MASK)
        luaG_runerror(L, "strict AOT location update rejected line %u", line);

    L->ci->aotstate = (L->ci->aotstate & ~LUA_CALLINFO_AOT_LINE_MASK) | line;
}

extern "C" uint32_t luauc_runtime_v1_exchange_continuation(lua_State *L, uint32_t next) {
    if (!L || !L->ci || !isLua(L->ci) || !(L->ci->flags & LUA_CALLINFO_NATIVE))
        luaG_runerror(L, "strict AOT continuation exchange requires an active native Luau frame");

    Closure *closure = clvalue(L->ci->func);
    const LuaucRuntimeProtoV1 *metadata =
        closure->l.p ? static_cast<const LuaucRuntimeProtoV1 *>(closure->l.p->execdata) : nullptr;
    if (!validAotProto(metadata))
        luaG_runerror(L, "strict AOT continuation exchange rejected invalid frame metadata");
    if (next > LUA_CALLINFO_AOT_CONTINUATION_MASK)
        luaG_runerror(L, "strict AOT continuation exchange rejected ID %u", next);

    const uint32_t previous = (L->ci->aotstate >> LUA_CALLINFO_AOT_CONTINUATION_SHIFT) &
                              LUA_CALLINFO_AOT_CONTINUATION_MASK;
    L->ci->aotstate = (L->ci->aotstate & LUA_CALLINFO_AOT_LINE_MASK) |
                      (next << LUA_CALLINFO_AOT_CONTINUATION_SHIFT);
    return previous;
}

static void newAotTable(lua_State *L, uint32_t destinationRegister, uint32_t arrayCount,
                        uint32_t nodeCount, bool assist) {
    Proto *proto = activeAotFrameProto(L, "table allocation");
    TValue *destination = activeAotRegister(L, proto, destinationRegister, "table allocation");
    if (arrayCount > INT_MAX || nodeCount > INT_MAX)
        luaG_runerror(L, "strict AOT table allocation rejected array/hash sizes %u/%u", arrayCount,
                      nodeCount);
    if (destination >= L->top)
        luaG_runerror(L, "strict AOT table allocation destination is outside the live stack");

    // Generated execution enters through a thread barrier, but repeat it here so this allocation
    // also remains correct if a preceding GC step has blackened the active thread. luaH_new does
    // not run GC while the new table is temporarily unrooted; publication precedes the assist.
    luaC_threadbarrier(L);
    LuaTable *table = luaH_new(L, int(arrayCount), int(nodeCount));
    sethvalue(L, destination, table);
    if (assist)
        luaC_checkGC(L);
}

extern "C" void luauc_runtime_v1_new_table(lua_State *L, uint32_t destinationRegister,
                                         uint32_t arrayCount, uint32_t nodeCount) {
    newAotTable(L, destinationRegister, arrayCount, nodeCount, true);
}

extern "C" void luauc_runtime_v1_new_table_deferred(lua_State *L, uint32_t destinationRegister,
                                                  uint32_t arrayCount, uint32_t nodeCount) {
    // Optimized literal graphs can coalesce their CHECK_GC after several published allocations and
    // non-safepoint initialization stores. Preserve that exact marker position rather than adding
    // an observably earlier collector assist.
    newAotTable(L, destinationRegister, arrayCount, nodeCount, false);
}

extern "C" void luauc_runtime_v1_check_gc(lua_State *L) {
    activeAotFrameProto(L, "collector assist");
    luaC_checkGC(L);
}

extern "C" void luauc_runtime_v1_coverage_hit(lua_State *L, uint32_t siteId) {
    Proto *proto = activeAotFrameProto(L, "coverage update");
    const LuaucRuntimeProtoV1 *metadata =
        static_cast<const LuaucRuntimeProtoV1 *>(proto->execdata);
    if (siteId >= metadata->coverage_site_count || !proto->userdata)
        luaG_runerror(L, "strict AOT coverage update rejected invalid site metadata");
    AotCoverageRecord &record = static_cast<AotCoverageRecord *>(proto->userdata)[siteId];
    if (record.hits < AOT_COVERAGE_MAX_HITS)
        ++record.hits;
}

extern "C" void luauc_runtime_v1_dup_table(lua_State *L, uint32_t destinationRegister,
                                         uint32_t constantId) {
    Proto *proto = activeAotFrameProto(L, "table template clone");
    TValue *destination = activeAotRegister(L, proto, destinationRegister, "table template clone");
    if (destination >= L->top)
        luaG_runerror(L, "strict AOT table template clone requires a live destination");
    if (constantId >= uint32_t(proto->sizek) || !ttistable(&proto->k[constantId]))
        luaG_runerror(L, "strict AOT table template clone rejected constant %u", constantId);

    LuaTable *prototype = hvalue(&proto->k[constantId]);
    if (prototype->metatable)
        luaG_runerror(L, "strict AOT table template clone rejected a metatable");

    // Proto::k roots the immutable template throughout allocation. DUP_TABLE only allocates and
    // publishes; a distinct CHECK_GC IR command owns any collector assist.
    luaC_threadbarrier(L);
    LuaTable *clone = luaH_clone(L, prototype);
    sethvalue(L, destination, clone);
}

extern "C" void luauc_runtime_v1_load_constant(lua_State *L, uint32_t destinationRegister,
                                             uint32_t constantId) {
    Proto *proto = activeAotFrameProto(L, "constant load");
    const LuaucRuntimeProtoV1 *metadata = static_cast<const LuaucRuntimeProtoV1 *>(proto->execdata);
    TValue *destination = activeAotRegister(L, proto, destinationRegister, "constant load");
    if (destination >= L->top)
        luaG_runerror(L, "strict AOT constant load requires a live destination");
    if (proto->sizek < 0 || uint32_t(proto->sizek) != metadata->constant_count ||
        (proto->k == nullptr) != (proto->sizek == 0) || constantId >= uint32_t(proto->sizek))
        luaG_runerror(L, "strict AOT constant load rejected constant %u", constantId);

    // Proto::k is traced through the active closure's Proto. Gray the active thread before
    // publishing a possibly collectable constant into its stack, then perform the real TValue
    // copy without decoding, re-interning, or constructing a parallel representation.
    luaC_threadbarrier(L);
    setobj2s(L, destination, &proto->k[constantId]);
}

extern "C" void luauc_runtime_v1_table_insert_append(lua_State *L, uint32_t tableRegister,
                                                   uint32_t sourceRegister) {
    Proto *proto = activeAotFrameProto(L, "table.insert append");
    LuaTable *table = activeAotPlainTable(L, proto, tableRegister, true, "table.insert append");
    TValue *tableValue = activeAotRegister(L, proto, tableRegister, "table.insert append");
    TValue *source = activeAotRegister(L, proto, sourceRegister, "table.insert append");
    if (tableValue >= L->top || source >= L->top)
        luaG_runerror(L, "strict AOT table.insert append requires published live registers");

    const int length = luaH_getn(table);
    if (length == INT_MAX)
        luaG_runerror(L, "strict AOT table.insert append overflow");

    // luaH_setnum owns real array growth/hash fallback. The source stays rooted in the frame, but
    // growth can invalidate transient table storage, so recompute its stack address afterward.
    TValue *destination = luaH_setnum(L, table, length + 1);
    source = L->base + sourceRegister;
    setobj2t(L, destination, source);
    luaC_barriert(L, table, source);
}

extern "C" void luauc_runtime_v1_table_set_string(lua_State *L, uint32_t tableRegister,
                                                uint32_t sourceRegister, const char *keyPointer,
                                                size_t keyLength) {
    Proto *proto = activeAotFrameProto(L, "string table set");
    TValue *tableValue = activeAotRegister(L, proto, tableRegister, "string table set");
    TValue *source = activeAotRegister(L, proto, sourceRegister, "string table set");
    if (tableValue >= L->top || source >= L->top)
        luaG_runerror(L, "strict AOT string table set requires published live registers");

    // Linked literal bytes are not a collector root. Reserve a temporary stack slot before
    // interning, publish the TString there, and reload every register after luaD_checkstack because
    // it may relocate the complete stack. The temporary key remains live through table growth and
    // any __newindex call; luaV_settable copies all call operands before its own stack checks.
    const ptrdiff_t liveTop = savestack(L, L->top);
    luaD_checkstack(L, 1);
    luaC_threadbarrier(L);
    TString *key = activeAotStringKey(L, keyPointer, keyLength, "string table set");
    setsvalue(L, L->top, key);
    TValue *keyValue = L->top++;

    tableValue = L->base + tableRegister;
    source = L->base + sourceRegister;
    luaV_settable(L, tableValue, keyValue, source);

    L->top = restorestack(L, liveTop);
    luaC_checkGC(L);
    L->top = restorestack(L, liveTop);
}

extern "C" void luauc_runtime_v1_table_get_string(lua_State *L, uint32_t destinationRegister,
                                                uint32_t tableRegister, const char *keyPointer,
                                                size_t keyLength) {
    Proto *proto = activeAotFrameProto(L, "string table get");
    TValue *destination = activeAotRegister(L, proto, destinationRegister, "string table get");
    TValue *tableValue = activeAotRegister(L, proto, tableRegister, "string table get");
    if (destination >= L->top || tableValue >= L->top)
        luaG_runerror(L, "strict AOT string table get requires published live registers");

    // Root the decoded literal exactly as for SETTABLEKS. Destination/receiver overlap is valid:
    // luaV_gettable performs the primitive lookup before publication and callTMres copies the
    // receiver and key to call slots before writing the saved destination after a metamethod call.
    const ptrdiff_t liveTop = savestack(L, L->top);
    luaD_checkstack(L, 1);
    luaC_threadbarrier(L);
    TString *key = activeAotStringKey(L, keyPointer, keyLength, "string table get");
    setsvalue(L, L->top, key);
    TValue *keyValue = L->top++;

    destination = L->base + destinationRegister;
    tableValue = L->base + tableRegister;
    luaV_gettable(L, tableValue, keyValue, destination);

    L->top = restorestack(L, liveTop);
    luaC_checkGC(L);
    L->top = restorestack(L, liveTop);
}

extern "C" void luauc_runtime_v1_namecall_plain(lua_State *L, uint32_t destinationRegister,
                                              uint32_t sourceRegister, const char *keyPointer,
                                              size_t keyLength) {
    Proto *proto = activeAotFrameProto(L, "namecall");
    if (destinationRegister == UINT32_MAX)
        luaG_runerror(L, "strict AOT namecall destination pair overflow");

    TValue *destination = activeAotRegister(L, proto, destinationRegister, "namecall");
    TValue *receiverDestination = activeAotRegister(L, proto, destinationRegister + 1, "namecall");
    TValue *source = activeAotRegister(L, proto, sourceRegister, "namecall");
    if (destination >= L->top || receiverDestination >= L->top || source >= L->top)
        luaG_runerror(L, "strict AOT namecall requires published live registers");

    // The linked key bytes are not a GC root. Reserve two temporary stack slots before interning:
    // one preserves the receiver when either result overlaps its source register, and the other
    // roots the interned key. luaD_checkstack can relocate every register pointer, so retain only
    // register indices and the live-top offset across it.
    const ptrdiff_t liveTop = savestack(L, L->top);
    luaD_checkstack(L, 2);
    luaC_threadbarrier(L);

    source = L->base + sourceRegister;
    setobj2s(L, L->top, source);
    TValue *rootedReceiver = L->top++;

    TString *key = activeAotStringKey(L, keyPointer, keyLength, "namecall");
    setsvalue(L, L->top, key);
    TValue *keyValue = L->top++;

    // Pinned NAMECALL gives __namecall precedence only for non-table receivers. It publishes the
    // atom on the state and returns that metamethod as the ordinary CALL target. Tables and every
    // receiver without __namecall use the complete luaV_gettable path, including nested/table and
    // callable __index, userdata/type metatables, user-defined objects, canonical errors, and hash
    // cache publication. Lookup metamethods are non-yieldable through luaD_call; invoking the
    // method returned here remains the generated CALL command's independently yieldable operation.
    const TValue *namecall = nullptr;
    if (!ttistable(rootedReceiver)) {
        LuaTable *metatable = ttisuserdata(rootedReceiver) ? uvalue(rootedReceiver)->metatable
                                                           : L->global->mt[ttype(rootedReceiver)];
        namecall = fasttm(L, metatable, TM_NAMECALL);
    }

    destination = L->base + destinationRegister;
    receiverDestination = destination + 1;
    setobj2s(L, receiverDestination, rootedReceiver);
    if (namecall) {
        setobj2s(L, destination, namecall);
        L->namecall = key;
    } else {
        luaV_gettable(L, rootedReceiver, keyValue, destination);
        destination = L->base + destinationRegister;
        receiverDestination = destination + 1;
        if (ttisnil(destination))
            luaG_methoderror(L, receiverDestination, key);
    }

    L->top = restorestack(L, liveTop);
    luaC_checkGC(L);
    L->top = restorestack(L, liveTop);
}

extern "C" void luauc_runtime_v1_table_set(lua_State *L, uint32_t tableRegister, uint32_t keyOperand,
                                         uint32_t sourceRegister) {
    Proto *proto = activeAotFrameProto(L, "generic table set");
    TValue *tableValue = activeAotRegister(L, proto, tableRegister, "generic table set");
    TValue *keyValue =
        const_cast<TValue *>(activeAotValueOperand(L, proto, keyOperand, "generic table set"));
    TValue *sourceValue = activeAotRegister(L, proto, sourceRegister, "generic table set");
    if (tableValue >= L->top || sourceValue >= L->top)
        luaG_runerror(L, "strict AOT generic table set requires published live registers");

    // Use the pinned VM semantic boundary, not a second AOT table implementation. luaV_settable
    // owns the complete TValue key universe, canonical nil/NaN-key and readonly errors, array/hash
    // growth and deletion, cached-slot publication, the collector barrier, and __newindex chains
    // through tables, functions, userdata/type metatables, and the pin's user-defined objects.
    // Metamethod invocation deliberately remains non-yieldable because upstream calls it through
    // luaD_call. Register operands are published frame roots and constant operands are rooted by
    // the active Proto; luaV_settable copies call operands before any stack growth.
    luaV_settable(L, tableValue, keyValue, sourceValue);
}

extern "C" void luauc_runtime_v1_table_get(lua_State *L, uint32_t destinationRegister,
                                         uint32_t tableRegister, uint32_t keyOperand) {
    Proto *proto = activeAotFrameProto(L, "generic table get");
    TValue *destination = activeAotRegister(L, proto, destinationRegister, "generic table get");
    TValue *tableValue = activeAotRegister(L, proto, tableRegister, "generic table get");
    TValue *keyValue =
        const_cast<TValue *>(activeAotValueOperand(L, proto, keyOperand, "generic table get"));
    if (destination >= L->top || tableValue >= L->top)
        luaG_runerror(L, "strict AOT generic table get requires published live registers");

    // luaV_gettable is the corresponding pinned semantic boundary: it performs raw lookup over
    // every supported TValue key, publishes the real hash cache, follows table-valued __index
    // chains, invokes function-valued __index non-yieldably, and raises Luau's canonical receiver
    // and chain errors. callTMres saves the destination as a stack offset before possible growth,
    // so the generated caller only needs to reload L->base after this helper returns.
    luaV_gettable(L, tableValue, keyValue, destination);
}

extern "C" uint32_t luauc_runtime_v1_table_array_set(lua_State *L, uint32_t tableRegister,
                                                   uint32_t oneBasedIndex,
                                                   uint32_t sourceRegister) {
    Proto *proto = activeAotFrameProto(L, "direct numeric table set");
    TValue *tableValue = activeAotRegister(L, proto, tableRegister, "direct numeric table set");
    TValue *sourceValue = activeAotRegister(L, proto, sourceRegister, "direct numeric table set");
    if (tableValue >= L->top || sourceValue >= L->top)
        luaG_runerror(L, "strict AOT direct numeric table set requires live registers");

    // Every eligibility failure is transactional: generated code can invoke the generic helper
    // with the original numeric key and observe ordinary Luau growth, hash, or error semantics.
    if (!ttistable(tableValue))
        return 0;
    LuaTable *table = hvalue(tableValue);
    if (table->metatable || table->readonly || oneBasedIndex == 0 ||
        oneBasedIndex > uint32_t(table->sizearray))
        return 0;

    TValue *destination = &table->array[oneBasedIndex - 1];
    setobj2t(L, destination, sourceValue);
    luaC_barriert(L, table, sourceValue);
    return 1;
}

extern "C" uint32_t luauc_runtime_v1_table_array_get(lua_State *L, uint32_t destinationRegister,
                                                   uint32_t tableRegister, uint32_t oneBasedIndex) {
    Proto *proto = activeAotFrameProto(L, "direct numeric table get");
    TValue *destination =
        activeAotRegister(L, proto, destinationRegister, "direct numeric table get");
    TValue *tableValue = activeAotRegister(L, proto, tableRegister, "direct numeric table get");
    if (destination >= L->top || tableValue >= L->top)
        luaG_runerror(L, "strict AOT direct numeric table get requires live registers");

    if (!ttistable(tableValue))
        return 0;
    LuaTable *table = hvalue(tableValue);
    if (table->metatable || oneBasedIndex == 0 || oneBasedIndex > uint32_t(table->sizearray))
        return 0;

    setobj2s(L, destination, &table->array[oneBasedIndex - 1]);
    return 1;
}

extern "C" void luauc_runtime_v1_get_global(lua_State *L, uint32_t destinationRegister,
                                          const char *keyPointer, size_t keyLength) {
    Proto *proto = activeAotFrameProto(L, "global get");
    TValue *destination = activeAotRegister(L, proto, destinationRegister, "global get");
    if (destination >= L->top)
        luaG_runerror(L, "strict AOT global get requires a published live destination");

    Closure *closure = clvalue(L->ci->func);
    LuaTable *environment = closure->env;
    if (!environment)
        luaG_runerror(L, "strict AOT global get requires a closure environment");

    // Unlike bytecode constants, decoded object bytes are not already a GC root. Reserve a
    // temporary stack slot before interning, then publish the TString there before any subsequent
    // operation or collector assist. luaD_checkstack can relocate the stack, so retain no register
    // pointer and restore the exact live top by offset on return.
    const ptrdiff_t liveTop = savestack(L, L->top);
    luaD_checkstack(L, 1);
    luaC_threadbarrier(L);
    TString *key = activeAotStringKey(L, keyPointer, keyLength, "global get");
    setsvalue(L, L->top, key);
    TValue *keyValue = L->top++;

    // The active closure roots the environment while this local TValue presents the exact
    // receiver shape expected by the pinned GETGLOBAL slow path. luaV_gettable owns raw lookup,
    // __index chains/calls, cachedslot publication, and canonical receiver/chain errors.
    TValue environmentValue;
    sethvalue(L, &environmentValue, environment);
    destination = L->base + destinationRegister;
    luaV_gettable(L, &environmentValue, keyValue, destination);

    L->top = restorestack(L, liveTop);
    luaC_checkGC(L);
    L->top = restorestack(L, liveTop);
}

extern "C" void luauc_runtime_v1_set_global(lua_State *L, uint32_t sourceRegister,
                                          const char *keyPointer, size_t keyLength) {
    Proto *proto = activeAotFrameProto(L, "global set");
    TValue *source = activeAotRegister(L, proto, sourceRegister, "global set");
    if (source >= L->top)
        luaG_runerror(L, "strict AOT global set requires a published live source");

    Closure *closure = clvalue(L->ci->func);
    LuaTable *environment = closure->env;
    if (!environment)
        luaG_runerror(L, "strict AOT global set requires a closure environment");

    // Root the decoded key throughout raw insertion or a possible __newindex call. The source and
    // environment remain rooted in the active frame and closure; reload the source after possible
    // stack relocation before entering the pinned table operation.
    const ptrdiff_t liveTop = savestack(L, L->top);
    luaD_checkstack(L, 1);
    luaC_threadbarrier(L);
    TString *key = activeAotStringKey(L, keyPointer, keyLength, "global set");
    setsvalue(L, L->top, key);
    TValue *keyValue = L->top++;

    // Match SETGLOBAL's pinned slow path. luaV_settable decides whether readonly applies to a real
    // write or whether __newindex handles an absent field, then owns rehashing, cachedslot,
    // barriers, table/function chains, and canonical errors.
    TValue environmentValue;
    sethvalue(L, &environmentValue, environment);
    source = L->base + sourceRegister;
    luaV_settable(L, &environmentValue, keyValue, source);

    L->top = restorestack(L, liveTop);
    luaC_checkGC(L);
    L->top = restorestack(L, liveTop);
}

extern "C" uint32_t luauc_runtime_v1_check_safe_env(lua_State *L) {
    activeAotFrameProto(L, "safe environment check");
    LuaTable *environment = clvalue(L->ci->func)->env;
    if (!environment)
        return LUAUC_RUNTIME_V1_INTERNAL_ERROR;
    return environment->safeenv ? LUAUC_RUNTIME_V1_OK : LUAUC_RUNTIME_V1_UNSUPPORTED_TYPE;
}

extern "C" int32_t luauc_runtime_v1_fastcall(lua_State *L, uint32_t builtinId,
                                           uint32_t destinationRegister, uint32_t sourceRegister,
                                           uint32_t argumentTwo, uint32_t argumentThree,
                                           int32_t resultCount, int32_t parameterCount) {
    Proto *proto = activeAotFrameProto(L, "fastcall");
    TValue *destination = activeAotRegister(L, proto, destinationRegister, "fastcall");
    TValue *source = activeAotRegister(L, proto, sourceRegister, "fastcall");
    if (destination >= L->top || source >= L->top)
        luaG_runerror(L, "strict AOT fastcall requires published live registers");

    if (builtinId >= 256 || resultCount < LUA_MULTRET ||
        (resultCount >= 0 && (uint32_t(resultCount) > proto->maxstacksize - destinationRegister ||
                              L->base + destinationRegister + resultCount > L->top)))
        luaG_runerror(L, "strict AOT fastcall rejected decoded builtin operands");

    int actualParameterCount = parameterCount;
    if (parameterCount == LUAUC_RUNTIME_V1_MULTRET) {
        TValue *firstArgument = L->base + destinationRegister + 1;
        const ptrdiff_t count = L->top - firstArgument;
        if (count < 0 || count > INT_MAX)
            luaG_runerror(L, "strict AOT fastcall rejected dynamic parameter range");
        actualParameterCount = int(count);
    } else if (parameterCount < 0) {
        luaG_runerror(L, "strict AOT fastcall rejected parameter count %d", parameterCount);
    }

    if (actualParameterCount < 1)
        return -1;
    if (parameterCount == LUAUC_RUNTIME_V1_MULTRET &&
        (sourceRegister != destinationRegister + 1 || argumentTwo != destinationRegister + 2 ||
         argumentThree != AOT_FASTCALL_NO_OPERAND))
        luaG_runerror(L, "strict AOT fastcall rejected multret argument layout");
    if (argumentThree != AOT_FASTCALL_NO_OPERAND && argumentTwo == AOT_FASTCALL_NO_OPERAND)
        luaG_runerror(L, "strict AOT fastcall rejected sparse optional arguments");
    if (parameterCount != LUAUC_RUNTIME_V1_MULTRET) {
        const int encodedParameterCount = argumentThree != AOT_FASTCALL_NO_OPERAND ? 3
                                          : argumentTwo != AOT_FASTCALL_NO_OPERAND ? 2
                                                                                   : 1;
        if (actualParameterCount != encodedParameterCount)
            luaG_runerror(L, "strict AOT fastcall rejected fixed argument layout");
    }
    if (parameterCount == LUAUC_RUNTIME_V1_MULTRET &&
        (uint32_t(actualParameterCount) > proto->maxstacksize - sourceRegister ||
         L->base + sourceRegister + actualParameterCount > L->top))
        luaG_runerror(L, "strict AOT fastcall parameters exceed the live compiled frame");

    LuaTable *environment = clvalue(L->ci->func)->env;
    if (!environment || !environment->safeenv)
        return -1;

    luau_FastFunction fastFunction = luauF_table[builtinId];
    if (!fastFunction)
        luaG_runerror(L, "strict AOT fastcall resolved a missing runtime builtin");

    TValue *additionalArguments = nullptr;
    if (parameterCount == LUAUC_RUNTIME_V1_MULTRET) {
        // FASTCALL/FASTCALL1 encode destination+2 as the open argument-range boundary. For a
        // single live argument this is exactly L->top: a valid one-past pointer that the pinned
        // fastfunction receives together with nparams=1 and therefore does not dereference. Larger
        // ranges are proven live by the bounds check above.
        additionalArguments = L->base + destinationRegister + 2;
    } else if (argumentTwo != AOT_FASTCALL_NO_OPERAND) {
        const TValue *second = activeAotValueOperand(L, proto, argumentTwo, "fastcall");
        if (argumentThree == AOT_FASTCALL_NO_OPERAND) {
            additionalArguments = const_cast<TValue *>(second);
        } else {
            // FASTCALL3 encodes two live registers. Constant operands live in Proto::k rather than
            // the active stack, so they cannot participate in the offset/reload protocol below.
            if ((argumentTwo & LUAUC_AOT_OPERAND_V1_CONSTANT_FLAG) != 0 ||
                (argumentThree & LUAUC_AOT_OPERAND_V1_CONSTANT_FLAG) != 0)
                luaG_runerror(L, "strict AOT fastcall rejected constant FASTCALL3 operands");
            const TValue *third = activeAotValueOperand(L, proto, argumentThree, "fastcall");
            const ptrdiff_t secondOffset = second - L->base;
            const ptrdiff_t thirdOffset = third - L->base;
            const ptrdiff_t liveTop = savestack(L, L->top);
            luaD_checkstack(L, 2);
            source = L->base + sourceRegister;
            destination = L->base + destinationRegister;
            second = L->base + secondOffset;
            third = L->base + thirdOffset;
            setobj2s(L, L->top, second);
            setobj2s(L, L->top + 1, third);
            additionalArguments = L->top;
            luaC_threadbarrier(L);
            const int produced = fastFunction(L, destination, source, resultCount,
                                              additionalArguments, actualParameterCount);
            L->top = restorestack(L, liveTop);
            return produced;
        }
    }

    // The pinned fastfunction table owns all builtin-specific result and failure semantics.
    // Negative results are transactional and route generated code into the exact ordinary CALL
    // fallback. Nonnegative results are published in the active frame; no AOT builtin duplicate
    // is maintained here.
    luaC_threadbarrier(L);
    return fastFunction(L, destination, source, resultCount, additionalArguments,
                        actualParameterCount);
}

extern "C" double luauc_runtime_v1_libm(uint32_t builtinId, double first, double second) {
    switch (builtinId) {
    case 3:
        return acos(first);
    case 4:
        return asin(first);
    case 5:
        return atan2(first, second);
    case 6:
        return atan(first);
    case 8:
        return cosh(first);
    case 9:
        return cos(first);
    case 11:
        return exp(first);
    case 13:
        return fmod(first, second);
    case 15:
        return ldexp(first, int(second));
    case 16:
        return log10(first);
    case 17:
        return log(first);
    case 21:
        return pow(first, second);
    case 23:
        return sinh(first);
    case 24:
        return sin(first);
    case 26:
        return tanh(first);
    case 27:
        return tan(first);
    case 256:
        return log2(first);
    default:
        return NAN;
    }
}

extern "C" uint32_t luauc_runtime_v1_type_name(lua_State *L, uint32_t destinationRegister,
                                             uint32_t sourceRegister, uint32_t customName) {
    Proto *proto = activeAotFrameProto(L, customName ? "typeof" : "type");
    TValue *destination =
        activeAotRegister(L, proto, destinationRegister, customName ? "typeof" : "type");
    TValue *source = activeAotRegister(L, proto, sourceRegister, customName ? "typeof" : "type");
    if (destination >= L->top || source >= L->top)
        luaG_runerror(L, "strict AOT type name requires published live registers");
    if (customName > 1)
        luaG_runerror(L, "strict AOT type name rejected mode %u", customName);

    // TValue tags at or beyond LUA_T_COUNT are GC-only implementation tags and are never legal in
    // user registers. Validate before indexing global type metadata or entering the pinned typeof
    // machinery, both of which rely on that invariant.
    const int tag = ttype(source);
    if (unsigned(tag) >= unsigned(LUA_T_COUNT))
        luaG_runerror(L, "strict AOT type name rejected internal tag %d", tag);

    // type() deliberately ignores custom names and uses the canonical global tag-name array.
    // typeof() performs the complete pinned raw lookup: per-userdata __type, tagged-lightuserdata
    // names, and global metatable __type overrides. luaT_objtypenamestr cannot call Luau, allocate,
    // yield, or relocate the stack; every returned TString is already rooted by global/type
    // metadata. Gray the active thread before publishing that collectable pointer into its stack.
    const TString *name = customName ? luaT_objtypenamestr(L, source) : L->global->ttname[tag];
    if (!name)
        luaG_runerror(L, "strict AOT type name resolved missing runtime metadata");
    luaC_threadbarrier(L);
    setsvalue(L, destination, name);
    return LUAUC_RUNTIME_V1_OK;
}

extern "C" void luauc_runtime_v1_set_list(lua_State *L, uint32_t tableRegister, uint32_t sourceStart,
                                        uint32_t count, uint32_t startIndex, uint32_t knownSize) {
    Proto *proto = activeAotFrameProto(L, "SETLIST");
    LuaTable *table = activeAotTable(L, proto, tableRegister, false, "SETLIST");
    if (count == 0 || sourceStart >= proto->maxstacksize ||
        count > uint32_t(proto->maxstacksize) - sourceStart || startIndex == 0 ||
        L->base + sourceStart + count > L->top)
        luaG_runerror(L, "strict AOT SETLIST rejected the validated array range");

    const uint64_t last = uint64_t(startIndex) + count - 1;
    if (last > INT_MAX)
        luaG_runerror(L, "strict AOT SETLIST exceeds the supported array size");

    if (knownSize == UINT32_MAX) {
        // A natural SETLIST can carry undef for the optimizer's known table size. Match the pinned
        // fallback by growing only when the live array part cannot hold the last written element.
        // The table and every source remain published frame roots throughout the allocation.
        if (uint32_t(table->sizearray) < uint32_t(last))
            luaH_resizearray(L, table, int(last));
    } else if (knownSize > INT_MAX || table->sizearray != int(knownSize) || last > knownSize) {
        luaG_runerror(L, "strict AOT SETLIST exceeds the validated array size");
    }

    table = activeAotTable(L, proto, tableRegister, false, "SETLIST");
    TValue *source = L->base + sourceStart;
    for (uint32_t offset = 0; offset < count; ++offset)
        setobj2t(L, &table->array[startIndex + offset - 1], source + offset);
    luaC_barrierfast(L, table);
}

extern "C" void luauc_runtime_v1_array_set(lua_State *L, uint32_t tableRegister,
                                         uint32_t sourceRegister, uint32_t index) {
    Proto *proto = activeAotFrameProto(L, "array set");
    LuaTable *table = activeAotTable(L, proto, tableRegister, true, "array set");
    TValue *source = activeAotRegister(L, proto, sourceRegister, "array set");
    if (index == 0 || index > uint32_t(table->sizearray))
        luaG_runerror(L, "strict AOT array set index %u is outside the array part", index);

    setobj2t(L, &table->array[index - 1], source);
    luaC_barriert(L, table, source);
}

extern "C" void luauc_runtime_v1_array_get(lua_State *L, uint32_t destinationRegister,
                                         uint32_t tableRegister, uint32_t index) {
    Proto *proto = activeAotFrameProto(L, "array get");
    LuaTable *table = activeAotTable(L, proto, tableRegister, false, "array get");
    TValue *destination = activeAotRegister(L, proto, destinationRegister, "array get");
    if (index == 0 || index > uint32_t(table->sizearray))
        luaG_runerror(L, "strict AOT array get index %u is outside the array part", index);

    setobj2s(L, destination, &table->array[index - 1]);
}

extern "C" void luauc_runtime_v1_table_len(lua_State *L, uint32_t destinationRegister,
                                         uint32_t tableRegister) {
    Proto *proto = activeAotFrameProto(L, "table length");
    LuaTable *table = activeAotPlainTable(L, proto, tableRegister, false, "table length");
    TValue *destination = activeAotRegister(L, proto, destinationRegister, "table length");
    setnvalue(destination, double(luaH_getn(table)));
}

extern "C" void luauc_runtime_v1_concat(lua_State *L, uint32_t destinationRegister,
                                      uint32_t sourceStart, uint32_t count) {
    Proto *proto = activeAotFrameProto(L, "concatenation");
    if (count < 2 || sourceStart >= proto->maxstacksize ||
        count > uint32_t(proto->maxstacksize) - sourceStart)
        luaG_runerror(L, "strict AOT concatenation rejected the compiled register range");

    TValue *destination = activeAotRegister(L, proto, destinationRegister, "concatenation");
    TValue *source = L->base + sourceStart;
    if (destination >= L->top || source + count > L->top)
        luaG_runerror(L, "strict AOT concatenation requires a published live register range");

    // luaV_concat can call __concat and reallocate the stack. Preserve top as an offset, gray a
    // black thread before the operation publishes new strings into its register range, and carry no
    // stack pointer across the call.
    ptrdiff_t liveTop = savestack(L, L->top);
    luaC_threadbarrier(L);
    luaV_concat(L, int(count), int(sourceStart + count - 1));
    L->top = restorestack(L, liveTop);

    // Match LOP_CONCAT by copying the collapsed result from the first source register before the
    // collector assist. Recompute both addresses after luaV_concat, and retain only the saved stack
    // offset across luaC_checkGC in case collection relocates the stack.
    destination = L->base + destinationRegister;
    source = L->base + sourceStart;
    setobj2s(L, destination, source);
    luaC_checkGC(L);
    L->top = restorestack(L, liveTop);
}

extern "C" void luauc_runtime_v1_do_len(lua_State *L, uint32_t destinationRegister,
                                      uint32_t sourceRegister) {
    Proto *proto = activeAotFrameProto(L, "length");
    activeAotRegister(L, proto, destinationRegister, "length");
    activeAotRegister(L, proto, sourceRegister, "length");
    if (L->base + destinationRegister >= L->top || L->base + sourceRegister >= L->top)
        luaG_runerror(L, "strict AOT length requires published live registers");

    // luaV_dolen can invoke __len and relocate the stack. Gray a black thread before its temporary
    // call arguments become visible, retain top only as an offset, and pass freshly computed
    // register addresses that are never used after the call.
    ptrdiff_t liveTop = savestack(L, L->top);
    luaC_threadbarrier(L);
    luaV_dolen(L, L->base + destinationRegister, L->base + sourceRegister);
    L->top = restorestack(L, liveTop);
}

extern "C" void luauc_runtime_v1_forg_prep(lua_State *L, uint32_t baseRegister) {
    Proto *proto = activeAotFrameProto(L, "generic iteration preparation");
    const uint32_t frameSize = proto->maxstacksize;
    if (baseRegister > frameSize || frameSize - baseRegister < 3)
        luaG_runerror(L, "strict AOT generic iteration preparation exceeds the compiled frame");
    if (L->base + baseRegister + 3 > L->top)
        luaG_runerror(L,
                      "strict AOT generic iteration preparation requires live iterator registers");

    TValue *iterator = L->base + baseRegister;
    if (ttisfunction(iterator))
        return;

    LuaTable *metatable = ttistable(iterator)      ? hvalue(iterator)->metatable
                          : ttisuserdata(iterator) ? uvalue(iterator)->metatable
                                                   : nullptr;
    const TValue *iterMethod = fasttm(L, metatable, TM_ITER);
    if (FFlag::DebugLuauUserDefinedClassesRuntime && !iterMethod && ttisobject(iterator)) {
        iterMethod = luaT_gettmbyobj(L, iterator, TM_ITER);
        if (ttisnil(iterMethod))
            luaG_typeerror(L, iterator, "iterate over");
    }

    if (iterMethod) {
        // Match LOP_FORGPREP exactly: __iter is a non-yieldable metamethod call that receives self
        // and returns the iterator/state/control triple in place. luaD_call may relocate the stack,
        // so retain only the register index and restore the generated frame top afterwards.
        setobj2s(L, iterator + 1, iterator);
        setobj2s(L, iterator, iterMethod);
        L->top = iterator + 2;
        luaD_call(L, iterator, 3);
        L->top = L->ci->top;
        iterator = L->base + baseRegister;
        if (ttisnil(iterator))
            luaG_typeerror(L, iterator, "call");
        return;
    }

    if (fasttm(L, metatable, TM_CALL))
        return;

    if (!ttistable(iterator))
        luaG_typeerror(L, iterator, "iterate over");

    // A table without __iter or __call, including a table carrying unrelated metamethods, uses the
    // pinned builtin array/hash traversal state.
    setobj2s(L, iterator + 1, iterator);
    setpvalue(iterator + 2, reinterpret_cast<void *>(uintptr_t(0)), LU_TAG_ITERATOR);
    setnilvalue(iterator);
}

extern "C" void luauc_runtime_v1_forgprep_xnext_fallback(lua_State *L, uint32_t baseRegister) {
    Proto *proto = activeAotFrameProto(L, "next iteration preparation");
    if (baseRegister > proto->maxstacksize || proto->maxstacksize - baseRegister < 3 ||
        L->base + baseRegister + 3 > L->top)
        luaG_runerror(L, "strict AOT next iteration preparation exceeds the live frame");

    TValue *iterator = L->base + baseRegister;
    TValue *state = iterator + 1;
    TValue *control = iterator + 2;
    LuaTable *environment = clvalue(L->ci->func)->env;
    if (!environment)
        luaG_runerror(L, "strict AOT next iteration preparation requires a closure environment");

    // This helper owns the complete pinned FORGPREP_NEXT/FORGPREP_INEXT decision, including the
    // CHECK_SAFE_ENV that upstream may optimize to NOP in the serialized IR. These specialized
    // bytecodes are emitted only for pairs/next (nil control) or ipairs/inext (numeric-zero
    // control), so the live control value identifies their canonical fast state without a second
    // ABI discriminator. An unsafe environment or mismatched state preserves a function iterator;
    // every other iterator raises the canonical VM type error.
    const bool builtinNext = environment->safeenv && ttistable(state) && ttisnil(control);
    const bool builtinInext =
        environment->safeenv && ttistable(state) && ttisnumber(control) && nvalue(control) == 0.0;
    if (builtinNext || builtinInext) {
        setnilvalue(iterator);
        setpvalue(control, reinterpret_cast<void *>(uintptr_t(0)), LU_TAG_ITERATOR);
        return;
    }

    if (!ttisfunction(iterator))
        luaG_typeerror(L, iterator, "iterate over");
}

static uint32_t forgLoopVariableCount(lua_State *L, uint32_t aux, const char *operation) {
    const uint32_t variableCount = aux & 0xff;
    if ((aux & 0x7fffff00) != 0 || variableCount == 0 ||
        ((aux & 0x80000000) != 0 && variableCount != 2))
        luaG_runerror(L, "strict AOT %s rejected FORGLOOP aux 0x%08x", operation, aux);
    return variableCount;
}

extern "C" uint32_t luauc_runtime_v1_forg_loop(lua_State *L, uint32_t baseRegister, uint32_t aux) {
    Proto *proto = activeAotFrameProto(L, "generic iteration");
    const uint32_t frameSize = proto->maxstacksize;
    const uint32_t variableCount = forgLoopVariableCount(L, aux, "generic iteration");
    const uint32_t requiredRegisters = variableCount + 3 > 5 ? variableCount + 3 : 5;
    if (baseRegister > frameSize || requiredRegisters > frameSize - baseRegister)
        luaG_runerror(L, "strict AOT generic iteration exceeds the compiled frame");
    if (L->base + baseRegister + requiredRegisters > L->top)
        luaG_runerror(L, "strict AOT generic iteration requires live result registers");

    TValue *iterator = L->base + baseRegister;
    if (!ttisnil(iterator) || !ttistable(iterator + 1) || !ttislightuserdata(iterator + 2) ||
        lightuserdatatag(iterator + 2) != LU_TAG_ITERATOR)
        luaG_runerror(L, "strict AOT generic iteration rejected invalid builtin iterator state");

    const uintptr_t cursor = reinterpret_cast<uintptr_t>(pvalue(iterator + 2));
    if (cursor > uintptr_t(INT_MAX))
        luaG_runerror(L, "strict AOT generic iteration rejected an invalid iterator cursor");

    // FORGLOOP guarantees that variables beyond the key/value pair are nil on both body and exit.
    for (uint32_t index = 2; index < variableCount; ++index)
        setnilvalue(iterator + 3 + index);

    // This is the canonical pinned forgLoopTableIter traversal: array indices first, followed by
    // live hash nodes. It directly uses Luau's table representation and iterator cursor, and does
    // not call an interpreter or decode bytecode.
    LuaTable *table = hvalue(iterator + 1);
    int index = int(cursor);
    const int arraySize = table->sizearray;
    if ((aux & 0x80000000) != 0 &&
        (unsigned(index) >= unsigned(arraySize) || ttisnil(&table->array[index])))
        return 0;

    while (unsigned(index) < unsigned(arraySize)) {
        TValue *element = &table->array[index];
        if (!ttisnil(element)) {
            setpvalue(iterator + 2, reinterpret_cast<void *>(uintptr_t(index + 1)),
                      LU_TAG_ITERATOR);
            setnvalue(iterator + 3, double(index + 1));
            setobj2s(L, iterator + 4, element);
            return 1;
        }
        ++index;
    }

    const int nodeSize = 1 << table->lsizenode;
    while (unsigned(index - arraySize) < unsigned(nodeSize)) {
        LuaNode *node = &table->node[index - arraySize];
        if (!ttisnil(gval(node))) {
            setpvalue(iterator + 2, reinterpret_cast<void *>(uintptr_t(index + 1)),
                      LU_TAG_ITERATOR);
            getnodekey(L, iterator + 3, node);
            setobj2s(L, iterator + 4, gval(node));
            return 1;
        }
        ++index;
    }

    return 0;
}

extern "C" void luauc_runtime_v1_return(lua_State *L, uint32_t sourceRegister, int32_t resultCount) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT return helper entered without an active Luau frame");
    if (resultCount < LUAUC_RUNTIME_V1_MULTRET)
        luaG_runerror(L, "strict AOT return helper rejected result count %d", resultCount);

    Closure *closure = clvalue(L->ci->func);
    Proto *proto = closure->l.p;
    if (sourceRegister > proto->maxstacksize)
        luaG_runerror(L, "strict AOT return source is outside the compiled frame");

    uint32_t actualResultCount;
    if (resultCount == LUAUC_RUNTIME_V1_MULTRET) {
        StkId first = L->base + sourceRegister;
        if (first > L->top)
            luaG_runerror(L, "strict AOT dynamic return starts above the live stack top");
        ptrdiff_t count = L->top - first;
        if (uint64_t(count) > UINT32_MAX)
            luaG_runerror(L, "strict AOT dynamic return count exceeds the ABI limit");
        actualResultCount = uint32_t(count);
    } else {
        actualResultCount = uint32_t(resultCount);
        if (actualResultCount > uint32_t(proto->maxstacksize) - sourceRegister)
            luaG_runerror(L, "strict AOT fixed return exceeds the compiled frame");
    }

    // A compiled return must never leave UpVal::v pointing into the frame that poscall will pop.
    // Exact CLOSE_UPVALS commands still lower independently for lexical scopes that end earlier.
    if (L->openupval && L->openupval->v >= L->base)
        luaF_close(L, L->base);

    // Poscall consumes results from frame base. Copy low-to-high: the destination never starts
    // above the source, so this also has correct memmove semantics for overlapping register ranges.
    for (uint32_t index = 0; index < actualResultCount; ++index)
        setobj2s(L, L->base + index, L->base + sourceRegister + index);
    L->top = L->base + actualResultCount;
}

extern "C" uint32_t luauc_runtime_v1_interrupt(lua_State *L, uint32_t line) {
    // Publish the actual 1-based source line without fabricating a bytecode pointer. The callback
    // can reallocate the stack, so generated code reloads L->base after every successful return.
    if (!L || !L->ci || !isLua(L->ci))
        return LUAUC_RUNTIME_V1_INTERNAL_ERROR;
    luauc_runtime_v1_set_location(L, line);

    void (*interrupt)(lua_State *, int) = L->global->cb.interrupt;
    if (!interrupt)
        return LUAUC_RUNTIME_V1_OK;

    // Normal execution callbacks receive the pinned GC discriminator -1. The generated source
    // line is published independently through CallInfo::aotstate above.
    interrupt(L, -1);
    return L->status == 0 ? LUAUC_RUNTIME_V1_OK : LUAUC_RUNTIME_V1_YIELDED;
}

extern "C" void luauc_runtime_v1_do_arith(lua_State *L, uint32_t destinationRegister,
                                        uint32_t lhsRegister, uint32_t rhsRegister,
                                        uint32_t operation) {
    Proto *proto = activeAotFrameProto(L, "arithmetic");
    TValue *destination = activeAotRegister(L, proto, destinationRegister, "arithmetic");
    const TValue *lhs = activeAotValueOperand(L, proto, lhsRegister, "arithmetic");
    const TValue *rhs = activeAotValueOperand(L, proto, rhsRegister, "arithmetic");
    if (destination >= L->top)
        luaG_runerror(L, "strict AOT arithmetic requires a published live destination");

    // All pinned arithmetic implementations either finish synchronously or invoke their
    // metamethod through non-yieldable luaD_call. Preserve the caller's live top and gray a black
    // thread before a metamethod result is published; luaV_doarithimpl saves the result offset and
    // copies aliased operands before any stack relocation.
    const ptrdiff_t liveTop = savestack(L, L->top);
    luaC_threadbarrier(L);

    switch (operation) {
    case LUAUC_AOT_ARITH_V1_ADD:
        luaV_doarithimpl<TM_ADD>(L, destination, lhs, rhs);
        break;
    case LUAUC_AOT_ARITH_V1_SUB:
        luaV_doarithimpl<TM_SUB>(L, destination, lhs, rhs);
        break;
    case LUAUC_AOT_ARITH_V1_MUL:
        luaV_doarithimpl<TM_MUL>(L, destination, lhs, rhs);
        break;
    case LUAUC_AOT_ARITH_V1_DIV:
        luaV_doarithimpl<TM_DIV>(L, destination, lhs, rhs);
        break;
    case LUAUC_AOT_ARITH_V1_IDIV:
        luaV_doarithimpl<TM_IDIV>(L, destination, lhs, rhs);
        break;
    case LUAUC_AOT_ARITH_V1_MOD:
        luaV_doarithimpl<TM_MOD>(L, destination, lhs, rhs);
        break;
    case LUAUC_AOT_ARITH_V1_POW:
        luaV_doarithimpl<TM_POW>(L, destination, lhs, rhs);
        break;
    case LUAUC_AOT_ARITH_V1_UNM:
        luaV_doarithimpl<TM_UNM>(L, destination, lhs, rhs);
        break;
    default:
        luaG_runerror(L, "strict AOT arithmetic helper rejected operation %u", operation);
    }

    L->top = restorestack(L, liveTop);
}

extern "C" uint32_t luauc_runtime_v1_compare_any(lua_State *L, uint32_t lhsRegister,
                                               uint32_t rhsRegister, uint32_t operation) {
    Proto *proto = activeAotFrameProto(L, "comparison");
    const TValue *lhs = activeAotValueOperand(L, proto, lhsRegister, "comparison");
    const TValue *rhs = activeAotValueOperand(L, proto, rhsRegister, "comparison");

    // Equality and ordering metamethods use the pinned non-yieldable call boundary and may
    // relocate the stack. Capture the boolean before restoring the exact generated live top; no
    // operand pointer is reused by this adapter after the luaV call.
    const ptrdiff_t liveTop = savestack(L, L->top);
    luaC_threadbarrier(L);
    uint32_t result;
    switch (operation) {
    case LUAUC_AOT_COMPARE_V1_EQUAL:
        result = ttype(lhs) == ttype(rhs) && luaV_equalval(L, lhs, rhs);
        break;
    case LUAUC_AOT_COMPARE_V1_LESS:
        result = luaV_lessthan(L, lhs, rhs);
        break;
    case LUAUC_AOT_COMPARE_V1_LESS_EQUAL:
        result = luaV_lessequal(L, lhs, rhs);
        break;
    default:
        luaG_runerror(L, "strict AOT comparison helper rejected operation %u", operation);
    }

    L->top = restorestack(L, liveTop);
    return result;
}

static Proto *findDirectAotChild(Proto *parent, uint32_t childProtoId) {
    for (int index = 0; index < parent->sizep; ++index) {
        Proto *candidate = parent->p[index];
        const LuaucRuntimeProtoV1 *metadata =
            candidate ? static_cast<const LuaucRuntimeProtoV1 *>(candidate->execdata) : nullptr;
        if (metadata && metadata->function_id == childProtoId)
            return candidate;
    }
    return nullptr;
}

extern "C" void luauc_runtime_v1_dupclosure(lua_State *L, uint32_t destinationRegister,
                                          uint32_t childProtoId) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT closure helper entered without an active Luau frame");

    Closure *parentClosure = clvalue(L->ci->func);
    Proto *parent = parentClosure->l.p;
    if (destinationRegister >= parent->maxstacksize)
        luaG_runerror(L, "strict AOT closure destination is outside the compiled frame");

    Proto *child = findDirectAotChild(parent, childProtoId);
    if (!child)
        luaG_runerror(L, "strict AOT closure helper rejected non-child Proto %u", childProtoId);
    if (child->nups != 0)
        luaG_runerror(L, "strict AOT DUPCLOSURE does not support captured upvalues");

    // The active parent closure roots the published Proto graph. Run incremental GC before the
    // allocation, gray a black thread, then make the new white Closure visible in its VM register.
    luaC_checkGC(L);
    luaC_threadbarrier(L);
    Closure *closure = luaF_newLclosure(L, 0, parentClosure->env, child);
    setclvalue(L, L->base + destinationRegister, closure);
    if (L->top <= L->base + destinationRegister)
        L->top = L->base + destinationRegister + 1;
}

extern "C" void luauc_runtime_v1_newclosure_capture(lua_State *L, uint32_t destinationRegister,
                                                  uint32_t childProtoId, uint32_t captureIndex,
                                                  uint32_t captureKind, uint32_t sourceIndex,
                                                  uint32_t checkGc) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT NEWCLOSURE entered without an active Luau frame");

    Closure *parentClosure = clvalue(L->ci->func);
    Proto *parent = parentClosure->l.p;
    if (destinationRegister >= parent->maxstacksize)
        luaG_runerror(L, "strict AOT NEWCLOSURE destination is outside the compiled frame");
    if (checkGc > 1)
        luaG_runerror(L, "strict AOT NEWCLOSURE rejected invalid GC marker %u", checkGc);

    Proto *child = findDirectAotChild(parent, childProtoId);
    if (!child)
        luaG_runerror(L, "strict AOT NEWCLOSURE rejected non-child Proto %u", childProtoId);
    if (child->nups == 0 || captureIndex >= child->nups)
        luaG_runerror(L, "strict AOT NEWCLOSURE capture is outside the child closure");
    if (checkGc != 0 && captureIndex + 1 != child->nups)
        luaG_runerror(L, "strict AOT NEWCLOSURE GC marker precedes the final capture");

    switch (captureKind) {
    case LUAUC_AOT_CAPTURE_V1_VAL:
    case LUAUC_AOT_CAPTURE_V1_REF:
        if (sourceIndex >= parent->maxstacksize)
            luaG_runerror(L, "strict AOT NEWCLOSURE capture register is outside the parent frame");
        break;
    case LUAUC_AOT_CAPTURE_V1_UPVAL:
        if (sourceIndex >= parent->nups || sourceIndex >= parentClosure->nupvalues)
            luaG_runerror(L, "strict AOT NEWCLOSURE source upvalue is outside the parent closure");
        break;
    default:
        luaG_runerror(L, "strict AOT NEWCLOSURE rejected capture kind %u", captureKind);
    }

    Closure *closure;
    if (captureIndex == 0) {
        // Match pinned NEWCLOSURE: allocate the entire nil-initialized shape, publish it before
        // reading any source (which permits a value capture of the destination itself), and keep
        // the destination in the live stack range across the remaining helper calls.
        closure = luaF_newLclosure(L, child->nups, parentClosure->env, child);
        setclvalue(L, L->base + destinationRegister, closure);
        if (L->top <= L->base + destinationRegister)
            L->top = L->base + destinationRegister + 1;
    } else {
        TValue *destination = L->base + destinationRegister;
        if (L->top <= destination || !isLfunction(destination))
            luaG_runerror(L, "strict AOT NEWCLOSURE lost its published closure");

        closure = clvalue(destination);
        if (closure->l.p != child || closure->nupvalues != child->nups ||
            closure->stacksize != child->maxstacksize || closure->env != parentClosure->env)
            luaG_runerror(L, "strict AOT NEWCLOSURE resumed with a different child closure");
        // A fresh NEWCLOSURE never uses DUPCLOSURE's preload state. Borrow the byte only while the
        // closure is unreachable to user code so even a captured nil cannot disguise a skipped or
        // repeated continuation capture, then restore its ordinary zero value after the final slot.
        if (closure->preload != captureIndex)
            luaG_runerror(L, "strict AOT NEWCLOSURE captures are not sequential");
    }

    switch (captureKind) {
    case LUAUC_AOT_CAPTURE_V1_VAL:
        setobj(L, &closure->l.uprefs[captureIndex], L->base + sourceIndex);
        break;
    case LUAUC_AOT_CAPTURE_V1_REF:
        setupvalue(L, &closure->l.uprefs[captureIndex], luaF_findupval(L, L->base + sourceIndex));
        break;
    case LUAUC_AOT_CAPTURE_V1_UPVAL:
        setobj(L, &closure->l.uprefs[captureIndex], &parentClosure->l.uprefs[sourceIndex]);
        break;
    }

    const bool lastCapture = captureIndex + 1 == child->nups;
    closure->preload = lastCapture ? 0 : uint8_t(captureIndex + 1);
    if (lastCapture && checkGc != 0)
        luaC_checkGC(L);
}

extern "C" void luauc_runtime_v1_get_upvalue(lua_State *L, uint32_t destinationRegister,
                                           uint32_t upvalueIndex) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT upvalue helper entered without an active Luau frame");

    Closure *closure = clvalue(L->ci->func);
    Proto *proto = closure->l.p;
    if (destinationRegister >= proto->maxstacksize || upvalueIndex >= proto->nups ||
        upvalueIndex >= closure->nupvalues)
        luaG_runerror(L, "strict AOT upvalue access is outside the compiled closure");
    TValue *upvalueRef = &closure->l.uprefs[upvalueIndex];
    const TValue *value = upvalueRef;
    if (ttype(upvalueRef) == LUA_TUPVAL)
        value = upvalue(upvalueRef)->v;

    setobj2s(L, L->base + destinationRegister, value);
}

extern "C" void luauc_runtime_v1_set_upvalue(lua_State *L, uint32_t upvalueIndex,
                                           uint32_t sourceRegister) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT upvalue mutation entered without an active Luau frame");

    Closure *closure = clvalue(L->ci->func);
    Proto *proto = closure->l.p;
    if (sourceRegister >= proto->maxstacksize || upvalueIndex >= proto->nups ||
        upvalueIndex >= closure->nupvalues)
        luaG_runerror(L, "strict AOT upvalue mutation is outside the compiled closure");
    TValue *upvalueRef = &closure->l.uprefs[upvalueIndex];
    if (ttype(upvalueRef) != LUA_TUPVAL)
        luaG_runerror(L, "strict AOT upvalue mutation requires a reference capture");

    UpVal *cell = upvalue(upvalueRef);
    setobj(L, cell->v, L->base + sourceRegister);
    luaC_barrier(L, cell, L->base + sourceRegister);
}

extern "C" void luauc_runtime_v1_close_upvalues(lua_State *L, uint32_t firstRegister) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT upvalue close entered without an active Luau frame");

    Closure *closure = clvalue(L->ci->func);
    Proto *proto = closure->l.p;
    if (firstRegister >= proto->maxstacksize)
        luaG_runerror(L, "strict AOT upvalue close is outside the compiled frame");

    StkId first = L->base + firstRegister;
    if (L->openupval && L->openupval->v >= first)
        luaF_close(L, first);
}

static uint32_t callAotFunction(lua_State *L, StkId function, int32_t resultCount) {
    const int precallStatus = luau_precall(L, function, resultCount);
    if (precallStatus == PCRC) {
        // luau_precall leaves a synchronous C call at the end of its adjusted results. Pinned
        // LOP_CALL restores the parent frame top for fixed-result calls before executing the next
        // instruction; without that restoration a later register publication in the same block is
        // incorrectly outside the live stack range.
        if (resultCount != LUA_MULTRET)
            L->top = L->ci->top;
        luaC_checkGC(L);
        return LUAUC_RUNTIME_V1_OK;
    }
    if (precallStatus == PCRYIELD) {
        if (!validCallSuspension(L) && !validScheduledReentrySuspension(L))
            luaG_runerror(L,
                          "strict AOT C call returned PCRYIELD without an installed C suspension");
        return LUAUC_RUNTIME_V1_YIELDED;
    }
    if (precallStatus != PCRLUA)
        luaG_runerror(L, "strict AOT call received invalid precall status %d", precallStatus);

    // luau_precall can reallocate the stack and can replace the original target through __call.
    // Validate the closure from the active installed frame, never the stale caller register.
    CallInfo *calleeFrame = L->ci;
    if (!calleeFrame || !ttisfunction(calleeFrame->func) || clvalue(calleeFrame->func)->isC)
        luaG_runerror(L, "strict AOT call did not install a Luau callee frame");

    Closure *callee = clvalue(calleeFrame->func);
    const LuaucRuntimeProtoV1 *metadata =
        callee->l.p ? static_cast<const LuaucRuntimeProtoV1 *>(callee->l.p->execdata) : nullptr;
    if (!validAotProto(metadata))
        luaG_runerror(L, "strict AOT call rejected missing callee metadata");
    if (callee->nupvalues != metadata->nups)
        luaG_runerror(L, "strict AOT call rejected callee closure shape");

    validateActiveAotEntry(L, metadata, "nested entry");
    const uint32_t status = metadata->entry(L, metadata);
    switch (status) {
    case LUAUC_RUNTIME_V1_OK:
        luau_poscall(L, L->base);
        luaC_checkGC(L);
        return LUAUC_RUNTIME_V1_OK;
    case LUAUC_RUNTIME_V1_UNSUPPORTED_TYPE:
        luaG_runerror(L, "strict AOT nested numeric tier received an unsupported value type");
    case LUAUC_RUNTIME_V1_YIELDED:
        if (!validAotSuspension(L))
            luaG_runerror(
                L, "strict AOT nested call reported yield without an installed continuation");
        return LUAUC_RUNTIME_V1_YIELDED;
    default:
        luaG_runerror(L, "strict AOT nested function returned invalid status %u", status);
    }
}

extern "C" uint32_t luauc_runtime_v1_call(lua_State *L, uint32_t functionRegister,
                                        int32_t parameterCount, int32_t resultCount) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT call helper entered without an active Luau frame");
    if (parameterCount < LUAUC_RUNTIME_V1_MULTRET || resultCount < LUAUC_RUNTIME_V1_MULTRET)
        luaG_runerror(L, "strict AOT call rejected %d parameters and %d results", parameterCount,
                      resultCount);

    Closure *caller = clvalue(L->ci->func);
    Proto *callerProto = caller->l.p;
    if (functionRegister >= callerProto->maxstacksize)
        luaG_runerror(L, "strict AOT call target is outside the compiled caller frame");

    StkId function = L->base + functionRegister;
    if (parameterCount == LUAUC_RUNTIME_V1_MULTRET) {
        if (L->top < function + 1)
            luaG_runerror(L, "strict AOT dynamic call starts above the live stack top");
    } else if (uint32_t(parameterCount) >= uint32_t(callerProto->maxstacksize) - functionRegister) {
        luaG_runerror(L, "strict AOT fixed call arguments exceed the compiled caller frame");
    }
    if (resultCount != LUAUC_RUNTIME_V1_MULTRET &&
        uint32_t(resultCount) > uint32_t(callerProto->maxstacksize) - functionRegister)
        luaG_runerror(L, "strict AOT fixed call results exceed the compiled caller frame");

    // A dynamic call consumes the exact live range established by a preceding multi-return
    // operation. Fixed calls cut L->top back to their declared arguments so unrelated registers do
    // not become accidental arguments. luau_precall resolves __call, fills missing fixed Luau
    // parameters with nil, executes C closures synchronously, and installs compiled Luau frames.
    if (parameterCount != LUAUC_RUNTIME_V1_MULTRET)
        L->top = function + parameterCount + 1;
    return callAotFunction(L, function, resultCount);
}

extern "C" uint32_t luauc_runtime_v1_forg_loop_call(lua_State *L, uint32_t baseRegister,
                                                  uint32_t aux) {
    Proto *proto = activeAotFrameProto(L, "generic iterator call");
    const uint32_t frameSize = proto->maxstacksize;
    const uint32_t variableCount = forgLoopVariableCount(L, aux, "generic iterator call");
    const uint32_t requiredRegisters = variableCount + 3 > 5 ? variableCount + 3 : 5;
    if (baseRegister > frameSize || requiredRegisters > frameSize - baseRegister)
        luaG_runerror(L, "strict AOT generic iterator call exceeds the compiled frame");
    if (L->base + baseRegister + requiredRegisters > L->top)
        luaG_runerror(L, "strict AOT generic iterator call requires live result registers");

    TValue *iterator = L->base + baseRegister;

    // Pinned FORGLOOP uses ra+3 as both the temporary function slot and first-result slot, with
    // state/control in ra+4/ra+5. For two loop variables the last argument can be one slot beyond
    // the logical Proto frame, so reserve real stack capacity instead of weakening frame bounds.
    // luaD_checkstack can relocate every stack address; retain only register indices across it.
    luaD_checkstack(L, 3);
    luaC_threadbarrier(L);
    iterator = L->base + baseRegister;
    TValue *function = iterator + 3;
    setobj2s(L, function, iterator);
    setobj2s(L, function + 1, iterator + 1);
    setobj2s(L, function + 2, iterator + 2);
    L->top = function + 3;

    // This is the real non-call-op protocol for every iterator kind. luau_precall resolves callable
    // tables/userdata, enters C or strict compiled Luau closures, adjusts the exact fixed result
    // count, and marks the native caller OPYIELD on suspension. A bytecode Luau closure cannot
    // enter because the patched execute boundary requires valid AOT metadata.
    const ptrdiff_t callerOffset = saveci(L, L->ci);
    const bool yielded = luaD_performcally(L, function, uint8_t(variableCount));
    CallInfo *caller = restoreci(L, callerOffset);

    if (yielded) {
        if (!(caller->flags & LUA_CALLINFO_OPYIELD) || !validNativeSuspensionFrame(caller) ||
            !validAotSuspension(L))
            luaG_runerror(L, "strict AOT iterator yielded without a resumable OPYIELD frame");
        return LUAUC_RUNTIME_V1_YIELDED;
    }

    if (L->status != LUA_OK || L->ci != caller || (caller->flags & LUA_CALLINFO_OPYIELD))
        luaG_runerror(L, "strict AOT iterator returned with inconsistent call state");
    return LUAUC_RUNTIME_V1_OK;
}

extern "C" uint32_t luauc_runtime_v1_forg_loop_finish(lua_State *L, uint32_t baseRegister,
                                                    uint32_t aux) {
    Proto *proto = activeAotFrameProto(L, "generic iterator finish");
    const uint32_t frameSize = proto->maxstacksize;
    const uint32_t variableCount = forgLoopVariableCount(L, aux, "generic iterator finish");
    const uint32_t requiredRegisters = variableCount + 3 > 5 ? variableCount + 3 : 5;
    if (baseRegister > frameSize || requiredRegisters > frameSize - baseRegister)
        luaG_runerror(L, "strict AOT generic iterator finish exceeds the compiled frame");

    // A synchronous fixed-result call has restored the caller frame. Reset its canonical live top,
    // then derive every address from the possibly relocated base before publishing result one as
    // the next control value. Nil terminates; every other Luau value, including false, repeats.
    L->top = L->ci->top;
    TValue *iterator = L->base + baseRegister;
    if (iterator + requiredRegisters > L->top)
        luaG_runerror(L, "strict AOT generic iterator finish lost its result registers");
    setobj2s(L, iterator + 2, iterator + 3);
    return ttisnil(iterator + 3) ? 0 : 1;
}

extern "C" void *luauc_runtime_v1_new_userdata(lua_State *L, uint32_t byteSize, uint32_t userTag) {
    activeAotFrameProto(L, "userdata allocation");
    if (userTag >= LUA_UTAG_LIMIT)
        luaG_runerror(L, "strict AOT userdata allocation rejected tag %u", userTag);

    // The backend fuses the exact preceding CHECK_GC into this boundary so no raw allocation
    // pointer can exist across a collector assist. After the assist, perform the pinned allocation
    // and attach the globally rooted tag metatable while the object is still white; generated code
    // must publish the returned Udata pointer before another safepoint.
    luaC_checkGC(L);
    Udata *userdata = luaU_newudata(L, size_t(byteSize), int(userTag));
    if (LuaTable *metatable = L->global->udatamt[userTag]) {
        LUAU_ASSERT(!isblack(obj2gco(userdata)));
        userdata->metatable = metatable;
    }
    return userdata;
}

extern "C" uint32_t luauc_runtime_v1_check_userdata_tag(lua_State *L, const void *userdataObject,
                                                      uint32_t expectedTag) {
    activeAotFrameProto(L, "userdata tag guard");
    if (expectedTag >= LUA_UTAG_LIMIT)
        luaG_runerror(L, "strict AOT userdata tag guard rejected tag %u", expectedTag);
    const Udata *userdata = static_cast<const Udata *>(userdataObject);
    if (!userdata || userdata->tt != LUA_TUSERDATA)
        luaG_runerror(L, "strict AOT userdata tag guard lost validated pointer provenance");
    return userdata->tag == expectedTag;
}

extern "C" void luauc_runtime_v1_barrier_object(lua_State *L, void *ownerPointer,
                                              uint32_t sourceRegister) {
    Proto *proto = activeAotFrameProto(L, "object barrier");
    TValue *source = activeAotRegister(L, proto, sourceRegister, "object barrier");
    if (source >= L->top)
        luaG_runerror(L, "strict AOT object barrier requires a published source register");

    GCObject *owner = static_cast<GCObject *>(ownerPointer);
    if (!owner || owner->gch.tt < LUA_TSTRING)
        luaG_runerror(L, "strict AOT object barrier lost validated owner provenance");
    if (iscollectable(source) && isblack(owner) && iswhite(gcvalue(source)))
        luaC_barrierf(L, owner, gcvalue(source));
}

extern "C" void luauc_runtime_v1_barrier_table_back(lua_State *L, void *tablePointer) {
    activeAotFrameProto(L, "table backward barrier");
    LuaTable *table = static_cast<LuaTable *>(tablePointer);
    if (!table || table->tt != LUA_TTABLE)
        luaG_runerror(L, "strict AOT table backward barrier lost validated table provenance");
    luaC_barrierfast(L, table);
}

extern "C" void *luauc_runtime_v1_hash_node_addr(lua_State *L, void *tablePointer,
                                                 uint32_t hash) {
    activeAotFrameProto(L, "hash node address");
    LuaTable *table = static_cast<LuaTable *>(tablePointer);
    if (!table || table->tt != LUA_TTABLE)
        luaG_runerror(L, "strict AOT hash node address lost table provenance");
    return gnode(table, hash & (sizenode(table) - 1));
}

extern "C" void *luauc_runtime_v1_slot_node_addr(lua_State *L, void *tablePointer,
                                                 uint32_t keyConstant) {
    Proto *proto = activeAotFrameProto(L, "slot node address");
    LuaTable *table = static_cast<LuaTable *>(tablePointer);
    if (!table || table->tt != LUA_TTABLE)
        luaG_runerror(L, "strict AOT slot node address lost table provenance");
    if (proto->sizek < 0 || keyConstant >= uint32_t(proto->sizek) ||
        !ttisstring(&proto->k[keyConstant]))
        luaG_runerror(L, "strict AOT slot node address rejected key constant %u", keyConstant);

    // The native backend reads the mutable bytecode cache. AOT Protos deliberately have no
    // bytecode, so start at the string's deterministic main position. CHECK_SLOT_MATCH preserves
    // the exact fast/slow decision: collisions and missing values enter the compiled semantic
    // slow path, while a hit returns the same LuaNode value slot.
    TString *key = tsvalue(&proto->k[keyConstant]);
    return gnode(table, key->hash & (sizenode(table) - 1));
}

extern "C" uint32_t luauc_runtime_v1_node_slot_match(lua_State *L, void *nodePointer,
                                                     uint32_t keyConstant) {
    Proto *proto = activeAotFrameProto(L, "node slot match");
    LuaNode *node = static_cast<LuaNode *>(nodePointer);
    if (!node)
        luaG_runerror(L, "strict AOT node slot match lost node provenance");
    if (proto->sizek < 0 || keyConstant >= uint32_t(proto->sizek) ||
        !ttisstring(&proto->k[keyConstant]))
        luaG_runerror(L, "strict AOT node slot match rejected key constant %u", keyConstant);
    TString *key = tsvalue(&proto->k[keyConstant]);
    return ttisstring(gkey(node)) && tsvalue(gkey(node)) == key && !ttisnil(gval(node));
}

extern "C" void *luauc_runtime_v1_try_get_tm(lua_State *L, void *tablePointer, uint32_t event) {
    activeAotFrameProto(L, "tag method probe");
    LuaTable *table = static_cast<LuaTable *>(tablePointer);
    if (!table || table->tt != LUA_TTABLE)
        luaG_runerror(L, "strict AOT tag method probe lost table provenance");
    if (event >= uint32_t(TM_N))
        luaG_runerror(L, "strict AOT tag method probe rejected event %u", event);
    return const_cast<TValue *>(fasttm(L, table->metatable, TMS(event)));
}

extern "C" uint32_t luauc_runtime_v1_check_node_no_next(lua_State *L, void *nodePointer) {
    activeAotFrameProto(L, "node no-next guard");
    LuaNode *node = static_cast<LuaNode *>(nodePointer);
    if (!node)
        luaG_runerror(L, "strict AOT node no-next guard lost node provenance");
    return gnext(node) != 0;
}

extern "C" uint32_t luauc_runtime_v1_check_node_value(lua_State *L, void *nodePointer) {
    activeAotFrameProto(L, "node value guard");
    LuaNode *node = static_cast<LuaNode *>(nodePointer);
    if (!node)
        luaG_runerror(L, "strict AOT node value guard lost node provenance");
    return ttisnil(gval(node));
}

extern "C" uint32_t luauc_runtime_v1_closure_matches_proto_id(lua_State *L,
                                                               uint32_t closureRegister,
                                                               uint32_t functionId) {
    Proto *proto = activeAotFrameProto(L, "closure Proto identity guard");
    TValue *value = activeAotRegister(L, proto, closureRegister,
                                      "closure Proto identity guard");
    if (value >= L->top)
        luaG_runerror(L, "strict AOT closure Proto identity guard requires a published register");
    if (!ttisfunction(value))
        return 0;
    Closure *closure = clvalue(value);
    return !closure->isC && closure->l.p && closure->l.p->funid == functionId;
}

extern "C" uint32_t luauc_runtime_v1_check_readonly(lua_State *L, void *tablePointer,
                                                       uint32_t raise) {
    activeAotFrameProto(L, "readonly guard");
    LuaTable *table = static_cast<LuaTable *>(tablePointer);
    if (!table || table->tt != LUA_TTABLE)
        luaG_runerror(L, "strict AOT readonly guard lost table provenance");
    if (table->readonly && raise != 0)
        luaG_readonlyerror(L);
    return table->readonly ? 1u : 0u;
}

extern "C" void luauc_runtime_v1_prep_varargs(lua_State *L, uint32_t fixedParameterCount) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT PREPVARARGS entered without an active Luau frame");

    CallInfo *ci = L->ci;
    Closure *closure = clvalue(ci->func);
    Proto *proto = closure->l.p;
    if (!proto->is_vararg || fixedParameterCount != proto->numparams || ci->base != ci->func + 1 ||
        L->top < ci->base + fixedParameterCount)
        luaG_runerror(L, "strict AOT PREPVARARGS rejected the active frame shape");

    // Match LOP_PREPVARARGS: reserve the relocated frame first, then reload every stack pointer
    // because luaD_checkstack may move the stack. The original argument range remains rooted.
    luaD_checkstack(L, int(closure->stacksize) + int(fixedParameterCount));
    ci = L->ci;
    StkId fixed = ci->base;
    StkId relocated = L->top;
    for (uint32_t index = 0; index < fixedParameterCount; ++index) {
        setobj2s(L, relocated + index, fixed + index);
        setnilvalue(fixed + index);
    }

    ci->base = relocated;
    ci->top = relocated + closure->stacksize;
    L->base = relocated;
    L->top = ci->top;
}

static uint32_t varargCount(lua_State *L, Proto *proto) {
    ptrdiff_t count = L->base - L->ci->func - proto->numparams - 1;
    if (count < 0 || uint64_t(count) > UINT32_MAX)
        luaG_runerror(L, "strict AOT GETVARARGS rejected the active frame shape");
    return uint32_t(count);
}

extern "C" void luauc_runtime_v1_get_varargs_fixed(lua_State *L, uint32_t destinationRegister,
                                                 uint32_t resultCount) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT GETVARARGS entered without an active Luau frame");

    Closure *closure = clvalue(L->ci->func);
    Proto *proto = closure->l.p;
    if (!proto->is_vararg || destinationRegister > proto->maxstacksize ||
        resultCount > uint32_t(proto->maxstacksize) - destinationRegister)
        luaG_runerror(L, "strict AOT fixed GETVARARGS exceeds the compiled frame");

    uint32_t count = varargCount(L, proto);
    uint32_t copied = count < resultCount ? count : resultCount;
    StkId source = L->base - count;
    for (uint32_t index = 0; index < copied; ++index)
        setobj2s(L, L->base + destinationRegister + index, source + index);
    for (uint32_t index = copied; index < resultCount; ++index)
        setnilvalue(L->base + destinationRegister + index);
}

extern "C" void luauc_runtime_v1_get_varargs_multret(lua_State *L, uint32_t destinationRegister) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT GETVARARGS entered without an active Luau frame");

    Closure *closure = clvalue(L->ci->func);
    Proto *proto = closure->l.p;
    if (!proto->is_vararg || destinationRegister > proto->maxstacksize)
        luaG_runerror(L, "strict AOT dynamic GETVARARGS starts outside the compiled frame");

    uint32_t count = varargCount(L, proto);
    if (count > INT_MAX)
        luaG_runerror(L, "strict AOT dynamic GETVARARGS count exceeds the runtime limit");

    // Match LOP_GETVARARGS B=0. Stack growth can relocate both the vararg source and destination,
    // so compute the count first and reload all pointers afterward.
    luaD_checkstack(L, int(count));
    StkId source = L->base - count;
    StkId destination = L->base + destinationRegister;
    for (uint32_t index = 0; index < count; ++index)
        setobj2s(L, destination + index, source + index);
    L->top = destination + count;
}

static bool pushModuleRecord(lua_State *L, uint32_t moduleId) {
    lua_pushlightuserdata(L, &moduleRegistryKey);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        return false;
    }

    lua_rawgeti(L, -1, MODULE_REGISTRY_COUNT_SLOT);
    int moduleCount = lua_tointeger(L, -1);
    lua_pop(L, 1);
    if (moduleCount < 0 || moduleId >= uint32_t(moduleCount)) {
        lua_pop(L, 1);
        return false;
    }

    lua_rawgeti(L, -1, int(moduleId) + 1);
    lua_remove(L, -2);
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        return false;
    }
    return true;
}

static int moduleRecordStatus(lua_State *L, int recordIndex) {
    lua_rawgeti(L, recordIndex, 2);
    int isNumber = 0;
    int status = lua_tointegerx(L, -1, &isNumber);
    lua_pop(L, 1);
    return isNumber ? status : -1;
}

static void setModuleRecordStatus(lua_State *L, int recordIndex, int status) {
    lua_pushinteger(L, status);
    lua_rawseti(L, recordIndex, 2);
}

static void setModuleRecordValue(lua_State *L, int recordIndex, int valueIndex) {
    lua_pushvalue(L, valueIndex);
    lua_rawseti(L, recordIndex, 3);
}

static void raiseCachedModuleFailure(lua_State *L, int originalTop, int recordIndex,
                                     uint32_t moduleId, bool resetForRetry) {
    lua_rawgeti(L, recordIndex, 3);
    const char *message = lua_tostring(L, -1);
    if (resetForRetry)
        setModuleRecordStatus(L, recordIndex, MODULE_UNINITIALIZED);
    lua_settop(L, originalTop);
    luaG_runerror(L, "strict AOT module %u initialization failed: %s", moduleId,
                  message ? message : "unknown error");
}

static void cacheAndRaiseModuleFailure(lua_State *L, int originalTop, int recordIndex,
                                       uint32_t moduleId, int messageIndex,
                                       bool preserveActiveFailure) {
    setModuleRecordValue(L, recordIndex, messageIndex);
    setModuleRecordStatus(L, recordIndex,
                          preserveActiveFailure ? MODULE_FAILED : MODULE_UNINITIALIZED);
    raiseCachedModuleFailure(L, originalTop, recordIndex, moduleId, false);
}

static bool pushEntryModuleRecord(lua_State *L, Proto *entryProto, uint32_t *entryModuleId) {
    lua_pushlightuserdata(L, &moduleRegistryKey);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        return false;
    }

    lua_rawgeti(L, -1, MODULE_REGISTRY_ENTRY_ID_SLOT);
    int isNumber = 0;
    int id = lua_tointegerx(L, -1, &isNumber);
    lua_pop(L, 1);
    if (!isNumber || id < 0) {
        lua_pop(L, 1);
        return false;
    }

    lua_rawgeti(L, -1, id + 1);
    lua_remove(L, -2);
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        return false;
    }

    lua_rawgeti(L, -1, 1);
    const bool matchesEntry = lua_isfunction(L, -1) && !clvalue(L->top - 1)->isC &&
                              clvalue(L->top - 1)->l.p == entryProto;
    lua_pop(L, 1);
    if (!matchesEntry) {
        lua_pop(L, 1);
        return false;
    }

    *entryModuleId = uint32_t(id);
    return true;
}

extern "C" uint32_t luauc_runtime_v1_require_static(lua_State *L, uint32_t destinationRegister,
                                                  uint32_t targetModuleId) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT static require entered without an active Luau frame");

    Closure *caller = clvalue(L->ci->func);
    Proto *callerProto = caller->l.p;
    if (destinationRegister >= callerProto->maxstacksize)
        luaG_runerror(L, "strict AOT static require destination is outside the compiled frame");
    if (!lua_checkstack(L, 8))
        luaG_runerror(L, "strict AOT static require could not reserve runtime stack space");

    const int originalTop = lua_gettop(L);
    if (!pushModuleRecord(L, targetModuleId))
        luaG_runerror(L, "strict AOT static require rejected module %u", targetModuleId);
    const int recordIndex = lua_gettop(L);
    int status = moduleRecordStatus(L, recordIndex);

    if (status == MODULE_INITIALIZED) {
        lua_rawgeti(L, recordIndex, 3);
        setobj2s(L, L->base + destinationRegister, L->top - 1);
        lua_settop(L, originalTop);
        return LUAUC_RUNTIME_V1_OK;
    }
    if (status == MODULE_FAILED) {
        raiseCachedModuleFailure(L, originalTop, recordIndex, targetModuleId, true);
    }
    if (status == MODULE_INITIALIZING) {
        lua_pushliteral(L, "static require cycle");
        cacheAndRaiseModuleFailure(L, originalTop, recordIndex, targetModuleId, -1, true);
    }
    if (status != MODULE_UNINITIALIZED) {
        lua_settop(L, originalTop);
        luaG_runerror(L, "strict AOT module %u has invalid initialization state", targetModuleId);
    }

    lua_rawgeti(L, recordIndex, 1);
    if (!lua_isfunction(L, -1) || clvalue(L->top - 1)->isC) {
        lua_settop(L, originalTop);
        luaG_runerror(L, "strict AOT module %u has no compiled root closure", targetModuleId);
    }
    Proto *moduleProto = clvalue(L->top - 1)->l.p;
    const LuaucRuntimeProtoV1 *metadata =
        moduleProto ? static_cast<const LuaucRuntimeProtoV1 *>(moduleProto->execdata) : nullptr;
    if (!validAotProto(metadata)) {
        lua_settop(L, originalTop);
        luaG_runerror(L, "strict AOT module %u root metadata is invalid", targetModuleId);
    }

    // Static require caches only successful initializers. Discard a stale error from a previous
    // attempt just before this real initializer begins again.
    lua_pushnil(L);
    lua_rawseti(L, recordIndex, 3);
    setModuleRecordStatus(L, recordIndex, MODULE_INITIALIZING);

    // Match the pinned module loader's isolation without loading source or bytecode. The thread is
    // rooted on the requiring state while the module closure executes through ldo's strict AOT
    // gate.
    lua_State *globalThread = lua_mainthread(L);
    lua_State *moduleThread = lua_newthread(globalThread);
    lua_xmove(globalThread, L, 1);
    luaL_sandboxthread(moduleThread);
    if (!lua_checkstack(moduleThread, 1)) {
        lua_pushliteral(L, "could not reserve module thread stack space");
        cacheAndRaiseModuleFailure(L, originalTop, recordIndex, targetModuleId, -1, false);
    }

    luaC_threadbarrier(moduleThread);
    Closure *moduleClosure = luaF_newLclosure(moduleThread, 0, moduleThread->gt, moduleProto);
    setclvalue(moduleThread, moduleThread->top, moduleClosure);
    moduleThread->top++;

    int resumeStatus = lua_resume(moduleThread, L, 0);
    if (resumeStatus != LUA_OK || lua_gettop(moduleThread) != 1) {
        // A nested cycle may already have atomically failed this record. Preserve that first
        // failure instead of replacing it while the initializer stack unwinds.
        if (moduleRecordStatus(L, recordIndex) == MODULE_FAILED)
            raiseCachedModuleFailure(L, originalTop, recordIndex, targetModuleId, true);

        const char *message = resumeStatus == LUA_YIELD
                                  ? "module yielded without a continuation contract"
                              : resumeStatus == LUA_OK ? "module must return a single value"
                                                       : lua_tostring(moduleThread, -1);
        lua_pushstring(L, message ? message : "unknown module error");
        cacheAndRaiseModuleFailure(L, originalTop, recordIndex, targetModuleId, -1, false);
    }

    if (moduleRecordStatus(L, recordIndex) == MODULE_FAILED)
        raiseCachedModuleFailure(L, originalTop, recordIndex, targetModuleId, true);
    if (moduleRecordStatus(L, recordIndex) != MODULE_INITIALIZING) {
        lua_settop(L, originalTop);
        luaG_runerror(L, "strict AOT module %u changed initialization state while executing",
                      targetModuleId);
    }

    lua_xmove(moduleThread, L, 1);
    setModuleRecordValue(L, recordIndex, -1);
    setModuleRecordStatus(L, recordIndex, MODULE_INITIALIZED);
    setobj2s(L, L->base + destinationRegister, L->top - 1);
    lua_settop(L, originalTop);
    return LUAUC_RUNTIME_V1_OK;
}

static void destroyAotProto(lua_State *L, Proto *proto) {
    // AOT metadata is immutable linker-owned data, not a heap allocation owned by Proto.
    const LuaucRuntimeProtoV1 *metadata =
        static_cast<const LuaucRuntimeProtoV1 *>(proto->execdata);
    if (metadata && proto->userdata)
        luaM_freearray(L, static_cast<AotCoverageRecord *>(proto->userdata),
                       metadata->coverage_site_count, AotCoverageRecord, proto->memcat);
    proto->userdata = nullptr;
    proto->execdata = nullptr;
}

static bool materializableScalarConstantKind(uint8_t kind) {
    return kind == LUAUC_AOT_VM_CONSTANT_V1_NIL || kind == LUAUC_AOT_VM_CONSTANT_V1_BOOLEAN ||
           kind == LUAUC_AOT_VM_CONSTANT_V1_NUMBER || kind == LUAUC_AOT_VM_CONSTANT_V1_VECTOR ||
           kind == LUAUC_AOT_VM_CONSTANT_V1_STRING || kind == LUAUC_AOT_VM_CONSTANT_V1_INTEGER;
}

static bool validAotConstants(const LuaucRuntimeProtoV1 *metadata) {
    if ((metadata->constants == nullptr) != (metadata->constant_count == 0) ||
        (metadata->constant_items == nullptr) != (metadata->constant_item_count == 0) ||
        metadata->constant_count > uint32_t(INT_MAX) ||
        metadata->constant_item_count > uint32_t(INT_MAX))
        return false;

    for (uint32_t id = 0; id < metadata->constant_count; ++id) {
        const LuaucRuntimeVmConstantV1 &constant = metadata->constants[id];
        if (constant.reserved[0] != 0 || constant.reserved[1] != 0 || constant.reserved[2] != 0 ||
            constant.kind > LUAUC_AOT_VM_CONSTANT_V1_CLASS_SHAPE)
            return false;

        if (constant.kind == LUAUC_AOT_VM_CONSTANT_V1_BOOLEAN && constant.payload0 > 1)
            return false;
        if (constant.kind == LUAUC_AOT_VM_CONSTANT_V1_STRING &&
            (constant.payload1 > MAXSSIZE || (constant.payload1 != 0 && constant.payload0 == 0)))
            return false;
        if (constant.kind != LUAUC_AOT_VM_CONSTANT_V1_TABLE)
            continue;

        if (constant.payload1 > uint32_t(INT_MAX) ||
            constant.payload0 > metadata->constant_item_count ||
            constant.payload1 > metadata->constant_item_count - constant.payload0)
            return false;

        for (uint32_t offset = 0; offset < constant.payload1; ++offset) {
            const LuaucRuntimeVmConstantItemV1 &item =
                metadata->constant_items[constant.payload0 + offset];
            if (item.key >= metadata->constant_count ||
                metadata->constants[item.key].kind != LUAUC_AOT_VM_CONSTANT_V1_STRING)
                return false;
            if (item.value != LUAUC_RUNTIME_V1_NO_ID &&
                (item.value >= metadata->constant_count ||
                 !materializableScalarConstantKind(metadata->constants[item.value].kind)))
                return false;
        }
    }
    return true;
}

static bool validAotProto(const LuaucRuntimeProtoV1 *metadata) {
    if (!metadata || metadata->abi_version != LUAUC_AOT_ABI_V1 ||
        metadata->struct_size != LUAUC_AOT_PROTO_V1_SIZE || !metadata->entry ||
        metadata->max_stack_size < metadata->num_params || metadata->is_vararg > 1 ||
        !validAotConstants(metadata) ||
        memcmp(metadata->layout_sha256, luauc_runtime_v1_layout_sha256,
               sizeof(metadata->layout_sha256)) != 0)
        return false;
    if ((metadata->coverage_sites == nullptr) != (metadata->coverage_site_count == 0) ||
        (metadata->coverage_site_count == 0) != (metadata->coverage_line_count == 0) ||
        metadata->coverage_site_count > uint32_t(INT_MAX) ||
        metadata->coverage_line_count > uint32_t(INT_MAX))
        return false;
    for (uint32_t id = 0; id < metadata->coverage_site_count; ++id) {
        const LuaucRuntimeCoverageSiteV1 &site = metadata->coverage_sites[id];
        if (site.reserved != 0 || site.line >= metadata->coverage_line_count)
            return false;
    }
    return true;
}

static bool validAotModule(const LuaucRuntimeModuleV1 *module) {
    return module && module->abi_version == LUAUC_AOT_ABI_V1 &&
           module->struct_size == LUAUC_AOT_MODULE_V1_SIZE && module->source_name &&
           module->source_name_size > 1 && module->source_name_size <= uint32_t(INT_MAX) &&
           (module->source_name[0] == '@' || module->source_name[0] == '=') &&
           memcmp(module->layout_sha256, luauc_runtime_v1_layout_sha256,
                  sizeof(module->layout_sha256)) == 0;
}

static void materializeAotConstants(lua_State *L, Proto *proto, const LuaucRuntimeProtoV1 *metadata) {
    if (metadata->constant_count == 0)
        return;

    proto->sizek = int(metadata->constant_count);
    proto->k = luaM_newarray(L, proto->sizek, TValue, proto->memcat);
    for (int id = 0; id < proto->sizek; ++id)
        setnilvalue(&proto->k[id]);

    // Materialize every scalar first, so table descriptors can refer to constants in either local
    // ID direction. Import/closure/class-shape records intentionally remain nil in this subset.
    for (uint32_t id = 0; id < metadata->constant_count; ++id) {
        const LuaucRuntimeVmConstantV1 &constant = metadata->constants[id];
        TValue *destination = &proto->k[id];
        switch (constant.kind) {
        case LUAUC_AOT_VM_CONSTANT_V1_NIL:
            break;
        case LUAUC_AOT_VM_CONSTANT_V1_BOOLEAN:
            setbvalue(destination, constant.payload0 != 0);
            break;
        case LUAUC_AOT_VM_CONSTANT_V1_NUMBER: {
            const uint64_t bits = uint64_t(constant.payload0) | (uint64_t(constant.payload1) << 32);
            double value;
            memcpy(&value, &bits, sizeof(value));
            setnvalue(destination, value);
            break;
        }
        case LUAUC_AOT_VM_CONSTANT_V1_VECTOR: {
            float lanes[3];
            const uint32_t bits[3] = {constant.payload0, constant.payload1, constant.payload2};
            memcpy(lanes, bits, sizeof(lanes));
            setvvalue(destination, lanes[0], lanes[1], lanes[2], 0.0f);
            break;
        }
        case LUAUC_AOT_VM_CONSTANT_V1_STRING: {
            const char *bytes = constant.payload1 == 0
                                    ? ""
                                    : reinterpret_cast<const char *>(uintptr_t(constant.payload0));
            TString *string = luaS_newlstr(L, bytes, constant.payload1);
            setsvalue(L, destination, string);
            break;
        }
        case LUAUC_AOT_VM_CONSTANT_V1_INTEGER: {
            const uint64_t bits = uint64_t(constant.payload0) | (uint64_t(constant.payload1) << 32);
            int64_t value;
            memcpy(&value, &bits, sizeof(value));
            setlvalue(destination, value);
            break;
        }
        default:
            break;
        }
    }

    // Table templates use the pinned loader's real shape construction. Nil-valued entries are
    // cleared only after all keys have been inserted, preserving the collision/shape behavior of
    // LBC_CONSTANT_TABLE_WITH_CONSTANTS; NO_ID retains its numeric-zero shape placeholder.
    for (uint32_t id = 0; id < metadata->constant_count; ++id) {
        const LuaucRuntimeVmConstantV1 &constant = metadata->constants[id];
        if (constant.kind != LUAUC_AOT_VM_CONSTANT_V1_TABLE)
            continue;

        LuaTable *table = luaH_new(L, 0, int(constant.payload1));
        for (uint32_t offset = 0; offset < constant.payload1; ++offset) {
            const LuaucRuntimeVmConstantItemV1 &item =
                metadata->constant_items[constant.payload0 + offset];
            TValue *slot = luaH_set(L, table, &proto->k[item.key]);
            if (item.value == LUAUC_RUNTIME_V1_NO_ID || ttisnil(&proto->k[item.value])) {
                setnvalue(slot, 0.0);
            } else {
                setobj2t(L, slot, &proto->k[item.value]);
                luaC_barriert(L, table, &proto->k[item.value]);
            }
        }
        for (uint32_t offset = 0; offset < constant.payload1; ++offset) {
            const LuaucRuntimeVmConstantItemV1 &item =
                metadata->constant_items[constant.payload0 + offset];
            if (item.value != LUAUC_RUNTIME_V1_NO_ID && ttisnil(&proto->k[item.value]))
                setnilvalue(luaH_set(L, table, &proto->k[item.key]));
        }
        sethvalue(L, &proto->k[id], table);
    }
}

static void initializeAotProto(lua_State *L, Proto *proto, const LuaucRuntimeProtoV1 *metadata,
                               TString *sourceName) {
    proto->source = sourceName;
    proto->debugname = sourceName;
    proto->maxstacksize = metadata->max_stack_size;
    proto->numparams = metadata->num_params;
    proto->nups = metadata->nups;
    proto->is_vararg = metadata->is_vararg;
    proto->funid = metadata->function_id;
    proto->execdata = const_cast<LuaucRuntimeProtoV1 *>(metadata);
    if (metadata->coverage_site_count != 0) {
        AotCoverageRecord *records = luaM_newarray(
            L, metadata->coverage_site_count, AotCoverageRecord, proto->memcat);
        for (uint32_t id = 0; id < metadata->coverage_site_count; ++id) {
            records[id].line = metadata->coverage_sites[id].line;
            records[id].reserved = 0;
            records[id].hits = 0;
        }
        proto->userdata = records;
    }
    materializeAotConstants(L, proto, metadata);
}

static void publishRootClosure(lua_State *L, Proto *proto) {
    Closure *closure = luaF_newLclosure(L, 0, L->gt, proto);
    setclvalue(L, L->top, closure);
    LUAU_ASSERT(L->top < L->ci->top);
    L->top++;
}

static void publishModuleRegistry(lua_State *L, const LuaucRuntimeProgramV1 *program, Proto **protos) {
    const int originalTop = lua_gettop(L);
    const int anchorBase = originalTop + 1;

    // Root every independent Proto tree before any table allocation can advance GC.
    luaC_threadbarrier(L);
    for (uint32_t id = 0; id < program->module_count; ++id) {
        Proto *root = protos[program->modules[id].root_proto_id];
        Closure *anchor = luaF_newLclosure(L, 0, L->gt, root);
        setclvalue(L, L->top, anchor);
        L->top++;
    }

    lua_createtable(L, int(program->module_count), 0);
    const int registryIndex = lua_gettop(L);
    lua_pushinteger(L, int(program->module_count));
    lua_rawseti(L, registryIndex, MODULE_REGISTRY_COUNT_SLOT);
    lua_pushinteger(L, int(program->entry_module_id));
    lua_rawseti(L, registryIndex, MODULE_REGISTRY_ENTRY_ID_SLOT);

    for (uint32_t id = 0; id < program->module_count; ++id) {
        lua_createtable(L, 3, 0);
        const int recordIndex = lua_gettop(L);
        lua_pushvalue(L, anchorBase + int(id));
        lua_rawseti(L, recordIndex, 1);
        // The entry chunk is executed by the existing push_program caller, not require_static.
        // Mark it active up front so a dependency that reaches back to the entry fails as a cycle
        // instead of starting a duplicate initializer. luauc_runtime_v1_enter completes this same
        // record after successful execution; unlike required modules, an executable entry may
        // return any number of values because the script-runner contract discards them.
        lua_pushinteger(L, id == program->entry_module_id ? MODULE_INITIALIZING
                                                          : MODULE_UNINITIALIZED);
        lua_rawseti(L, recordIndex, 2);
        lua_rawseti(L, registryIndex, int(id) + 1);
    }

    lua_pushlightuserdata(L, &moduleRegistryKey);
    lua_pushvalue(L, registryIndex);
    lua_rawset(L, LUA_REGISTRYINDEX);

    // Preserve push_program's existing contract: leave exactly the entry root closure on top.
    lua_pushvalue(L, anchorBase + int(program->entry_module_id));
    lua_replace(L, anchorBase);
    lua_settop(L, anchorBase);
}

extern "C" uint32_t luauc_runtime_v1_get_program_coverage(
    lua_State *L, void *context, LuaucRuntimeCoverageCallbackV1 callback) {
    if (!L || !callback)
        return LUAUC_RUNTIME_V1_INTERNAL_ERROR;
    if (!lua_checkstack(L, 3))
        return LUAUC_RUNTIME_V1_INTERNAL_ERROR;

    const int originalTop = lua_gettop(L);
    lua_pushlightuserdata(L, &moduleRegistryKey);
    lua_rawget(L, LUA_REGISTRYINDEX);
    const int registryIndex = lua_gettop(L);
    if (!lua_istable(L, registryIndex)) {
        lua_settop(L, originalTop);
        return LUAUC_RUNTIME_V1_INTERNAL_ERROR;
    }
    lua_rawgeti(L, registryIndex, MODULE_REGISTRY_COUNT_SLOT);
    if (!lua_isnumber(L, -1)) {
        lua_settop(L, originalTop);
        return LUAUC_RUNTIME_V1_INTERNAL_ERROR;
    }
    const int moduleCount = lua_tointeger(L, -1);
    lua_pop(L, 1);
    if (moduleCount <= 0) {
        lua_settop(L, originalTop);
        return LUAUC_RUNTIME_V1_INTERNAL_ERROR;
    }

    for (int id = 0; id < moduleCount; ++id) {
        lua_rawgeti(L, registryIndex, id + 1);
        const int recordIndex = lua_gettop(L);
        if (!lua_istable(L, recordIndex)) {
            lua_settop(L, originalTop);
            return LUAUC_RUNTIME_V1_INTERNAL_ERROR;
        }
        lua_rawgeti(L, recordIndex, 1);
        if (!lua_isfunction(L, -1) || clvalue(L->top - 1)->isC) {
            lua_settop(L, originalTop);
            return LUAUC_RUNTIME_V1_INTERNAL_ERROR;
        }
        lua_getcoverage(L, -1, context, callback);
        lua_pop(L, 2);
    }
    lua_settop(L, originalTop);
    return LUAUC_RUNTIME_V1_OK;
}

extern "C" uint32_t luauc_runtime_v1_push_root(lua_State *L, const LuaucRuntimeProtoV1 *metadata,
                                             const char *source, size_t sourceSize) {
    if (!L || !source || sourceSize == 0 || !validAotProto(metadata) ||
        metadata->parent_id != LUAUC_RUNTIME_V1_NO_ID ||
        metadata->flags != LUAUC_AOT_PROTO_V1_ROOT || metadata->nups != 0)
        return LUAUC_RUNTIME_V1_INTERNAL_ERROR;

    if (L->global->ecb.destroy && L->global->ecb.destroy != destroyAotProto)
        return LUAUC_RUNTIME_V1_INTERNAL_ERROR;
    configurePinnedRuntimeFlags(L);
    L->global->ecb.destroy = destroyAotProto;

    // Match the public API publication contract for newly-created collectables: reserve the stack
    // slot, advance incremental GC, then gray a black inactive thread before installing a white
    // Closure into its stack. GC does not run inside the allocations below.
    if (!lua_checkstack(L, 1))
        return LUAUC_RUNTIME_V1_INTERNAL_ERROR;
    luaC_checkGC(L);
    luaC_threadbarrier(L);

    TString *sourceName = luaS_newlstr(L, source, sourceSize);
    Proto *proto = luaF_newproto(L);
    initializeAotProto(L, proto, metadata, sourceName);
    publishRootClosure(L, proto);
    return LUAUC_RUNTIME_V1_OK;
}

extern "C" uint32_t luauc_runtime_v1_push_program(lua_State *L, const LuaucRuntimeProgramV1 *program,
                                                const char *source, size_t sourceSize) {
    const bool hasExtendedProgram = program && program->struct_size == LUAUC_AOT_PROGRAM_V1_SIZE;
    const bool hasLegacyProgram =
        program && program->struct_size == LUAUC_AOT_PROGRAM_V1_LEGACY_SIZE;
    if (!L || !program || !source || sourceSize == 0 || !program->protos ||
        program->abi_version != LUAUC_AOT_ABI_V1 || (!hasExtendedProgram && !hasLegacyProgram) ||
        program->proto_count == 0 || program->proto_count > INT_MAX ||
        program->root_proto_id >= program->proto_count || program->flags != 0 ||
        memcmp(program->layout_sha256, luauc_runtime_v1_layout_sha256,
               sizeof(program->layout_sha256)) != 0)
        return LUAUC_RUNTIME_V1_INTERNAL_ERROR;

    const uint32_t moduleCount = hasExtendedProgram ? program->module_count : 0;
    if ((moduleCount == 0 && hasExtendedProgram &&
         (program->modules != nullptr || program->entry_module_id != 0)) ||
        (moduleCount != 0 && (!program->modules || moduleCount > uint32_t(INT_MAX - 8) ||
                              program->entry_module_id >= moduleCount)))
        return LUAUC_RUNTIME_V1_INTERNAL_ERROR;

    if (moduleCount != 0) {
        for (uint32_t id = 0; id < moduleCount; ++id) {
            const LuaucRuntimeModuleV1 *module = &program->modules[id];
            if (!validAotModule(module) || module->module_id != id ||
                module->root_proto_id >= program->proto_count)
                return LUAUC_RUNTIME_V1_INTERNAL_ERROR;
            if ((id == 0 && module->root_proto_id != 0) ||
                (id != 0 && module->root_proto_id <= program->modules[id - 1].root_proto_id))
                return LUAUC_RUNTIME_V1_INTERNAL_ERROR;
        }
        if (program->root_proto_id != program->modules[program->entry_module_id].root_proto_id)
            return LUAUC_RUNTIME_V1_INTERNAL_ERROR;
    }

    for (uint32_t id = 0; id < program->proto_count; ++id) {
        const LuaucRuntimeProtoV1 *metadata = &program->protos[id];
        bool isRoot = id == program->root_proto_id;
        if (moduleCount != 0) {
            isRoot = false;
            for (uint32_t moduleId = 0; moduleId < moduleCount; ++moduleId)
                isRoot = isRoot || program->modules[moduleId].root_proto_id == id;
        }
        if (!validAotProto(metadata) || metadata->function_id != id ||
            metadata->flags != (isRoot ? LUAUC_AOT_PROTO_V1_ROOT : 0) ||
            (isRoot && metadata->nups != 0) ||
            (isRoot ? metadata->parent_id != LUAUC_RUNTIME_V1_NO_ID : metadata->parent_id >= id))
            return LUAUC_RUNTIME_V1_INTERNAL_ERROR;
    }

    if (L->global->ecb.destroy && L->global->ecb.destroy != destroyAotProto)
        return LUAUC_RUNTIME_V1_INTERNAL_ERROR;
    configurePinnedRuntimeFlags(L);
    L->global->ecb.destroy = destroyAotProto;

    if (!lua_checkstack(L, moduleCount == 0 ? 1 : int(moduleCount) + 8))
        return LUAUC_RUNTIME_V1_INTERNAL_ERROR;
    if (moduleCount != 0) {
        lua_pushlightuserdata(L, &moduleRegistryKey);
        lua_rawget(L, LUA_REGISTRYINDEX);
        const bool alreadyPublished = !lua_isnil(L, -1);
        lua_pop(L, 1);
        if (alreadyPublished)
            return LUAUC_RUNTIME_V1_INTERNAL_ERROR;
    }
    luaC_checkGC(L);
    luaC_threadbarrier(L);

    const int protoCount = int(program->proto_count);
    const uint8_t memoryCategory = L->activememcat;
    Proto **protos = luaM_newarray(L, protoCount, Proto *, memoryCategory);
    uint32_t *childCounts = luaM_newarray(L, protoCount, uint32_t, memoryCategory);
    memset(childCounts, 0, sizeof(uint32_t) * protoCount);

    TString *sourceName = moduleCount == 0 ? luaS_newlstr(L, source, sourceSize) : nullptr;
    uint32_t sourceModuleId = 0;
    for (int id = 0; id < protoCount; ++id) {
        if (moduleCount != 0 && sourceModuleId < moduleCount &&
            program->modules[sourceModuleId].root_proto_id == uint32_t(id)) {
            const LuaucRuntimeModuleV1 *module = &program->modules[sourceModuleId++];
            sourceName = luaS_newlstr(L, module->source_name, module->source_name_size);
        }
        if (!sourceName)
            luaG_runerror(L, "strict AOT Proto %d has no owning module source", id);
        protos[id] = luaF_newproto(L);
        initializeAotProto(L, protos[id], &program->protos[id], sourceName);
        if (program->protos[id].parent_id != LUAUC_RUNTIME_V1_NO_ID)
            childCounts[program->protos[id].parent_id]++;
    }
    if (sourceModuleId != moduleCount)
        luaG_runerror(L, "strict AOT program did not publish every module source");

    for (int id = 0; id < protoCount; ++id) {
        const uint32_t count = childCounts[id];
        if (count > INT_MAX)
            luaG_runerror(L, "strict AOT Proto child count exceeds runtime limit");
        if (count != 0) {
            protos[id]->p = luaM_newarray(L, int(count), Proto *, protos[id]->memcat);
            protos[id]->sizep = int(count);
        }
        childCounts[id] = 0;
    }
    for (int id = 0; id < protoCount; ++id) {
        if (program->protos[id].parent_id == LUAUC_RUNTIME_V1_NO_ID)
            continue;
        const uint32_t parent = program->protos[id].parent_id;
        protos[parent]->p[childCounts[parent]++] = protos[id];
    }

    if (moduleCount == 0)
        publishRootClosure(L, protos[program->root_proto_id]);
    else
        publishModuleRegistry(L, program, protos);
    luaM_freearray(L, childCounts, protoCount, uint32_t, memoryCategory);
    luaM_freearray(L, protos, protoCount, Proto *, memoryCategory);
    return LUAUC_RUNTIME_V1_OK;
}

extern "C" void luauc_runtime_v1_enter(lua_State *L) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT entered without an active Luau frame");

    Closure *closure = clvalue(L->ci->func);
    Proto *proto = closure->l.p;
    const LuaucRuntimeProtoV1 *metadata = static_cast<const LuaucRuntimeProtoV1 *>(proto->execdata);
    if (!validAotProto(metadata))
        luaG_runerror(L, "strict AOT metadata ABI/layout mismatch");

    validateActiveAotEntry(L, metadata, "runtime entry");
    uint32_t status = metadata->entry(L, metadata);
    switch (status) {
    case LUAUC_RUNTIME_V1_OK: {
        const int resultCount = lua_gettop(L);
        const int resultIndex = resultCount == 1 ? lua_absindex(L, -1) : 0;
        const int originalTop = resultCount;
        uint32_t entryModuleId = 0;

        if (!lua_checkstack(L, 4))
            luaG_runerror(L, "strict AOT entry completion could not reserve runtime stack space");

        if (pushEntryModuleRecord(L, proto, &entryModuleId)) {
            const int recordIndex = lua_gettop(L);
            const int moduleStatus = moduleRecordStatus(L, recordIndex);
            if (moduleStatus == MODULE_FAILED)
                raiseCachedModuleFailure(L, originalTop, recordIndex, entryModuleId, true);
            if (moduleStatus != MODULE_INITIALIZING) {
                lua_settop(L, originalTop);
                luaG_runerror(L, "strict AOT entry module %u has invalid completion state",
                              entryModuleId);
            }
            if (resultCount == 1) {
                setModuleRecordValue(L, recordIndex, resultIndex);
            } else {
                // Preserve the entry record solely for cycle detection and deterministic later
                // lookup. Required module initializers remain strict in require_static; a top-level
                // executable is allowed to return zero or many values and those values are silent.
                lua_pushnil(L);
                setModuleRecordValue(L, recordIndex, -1);
            }
            setModuleRecordStatus(L, recordIndex, MODULE_INITIALIZED);
            lua_settop(L, originalTop);
        }

        luau_poscall(L, L->base);
        return;
    }
    case LUAUC_RUNTIME_V1_UNSUPPORTED_TYPE:
        luaG_runerror(L, "strict AOT numeric tier received an unsupported value type");
    case LUAUC_RUNTIME_V1_YIELDED:
        if (!validAotSuspension(L))
            luaG_runerror(L, "strict AOT entry reported yield without an installed continuation");
        return;
    default:
        luaG_runerror(L, "strict AOT generated function returned invalid status %u", status);
    }
}

extern "C" void luauc_runtime_v1_finish_yielded_op(lua_State *L) {
    activeAotFrameProto(L, "yielded operation finish");
    if (!(L->ci->flags & LUA_CALLINFO_OPYIELD))
        luaG_runerror(L, "strict AOT yielded operation finish requires OPYIELD state");
    if (aotContinuationId(L->ci) == 0)
        luaG_runerror(L, "strict AOT yielded operation finish requires a continuation");

    // Generated code owns the bounded continuation and operation-specific finish. This bridge
    // clears only upstream's scheduling flag; it never decodes a bytecode opcode or saved PC.
    L->ci->flags &= ~LUA_CALLINFO_OPYIELD;
}

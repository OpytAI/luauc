#include "trap.h"

namespace {
struct NativeRaise {
    int code;
};
} // namespace

extern "C" int luauc_runtime_v1_protected_call(void (*callback)(void *), void *context) {
    try {
        callback(context);
        return 0;
    } catch (const NativeRaise &raised) {
        return raised.code;
    }
}

extern "C" [[noreturn]] void luauc_runtime_v1_raise(int code) {
    throw NativeRaise{code};
}

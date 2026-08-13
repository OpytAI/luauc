// Provider-defined protected-call + raise primitives that stand in for C++ exceptions and
// setjmp/longjmp in a strict runtime pack. The guest is built `-fno-exceptions -fno-rtti`;
// each runtime profile supplies and declares its chosen unwind mechanism:
//
//   luauc_runtime_v1_protected_call(fn, ud)  runs fn(ud) as a NESTED guest call — a trap boundary. Returns 0 if
//                              fn returned normally, or the code passed to luauc_runtime_v1_raise() if it
//                              "threw".
//   luauc_runtime_v1_raise(code)             records `code` then transfers control to the
//                              nearest luauc_runtime_v1_protected_call boundary. Never returns.
//
// Consumers: the patched VM `ldo.cpp` (luaD_rawrunprotected → luauc_runtime_v1_protected_call, luaD_throw →
// luauc_runtime_v1_raise) and error_channel.h's Channel<T>. See the runtime profile contract.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

int luauc_runtime_v1_protected_call(void (*fn)(void *), void *ud);

__attribute__((noreturn)) void luauc_runtime_v1_raise(int code);

#ifdef __cplusplus
}
#endif
